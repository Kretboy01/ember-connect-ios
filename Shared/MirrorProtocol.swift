import Foundation

/// Wire format shared by the broadcast extension (producer) and the desktop
/// receiver (consumer).
///
/// The phone *listens* and the desktop connects in. That direction is forced
/// by usbmux: the USB multiplexer can open a connection to a port listening
/// on the device, but the device cannot dial out to the host over the cable.
/// The same listener also serves Wi-Fi clients, so one code path covers both
/// transports.
///
/// Every packet is a fixed 24-byte little-endian header followed by its
/// payload. Framing is explicit rather than relying on NAL start-code scanning
/// so the receiver never has to buffer-and-search across TCP segment
/// boundaries.
///
///     offset  size  field
///     0       4     magic 'ECMV'
///     4       1     packet type
///     5       1     flags
///     6       2     reserved (0)
///     8       2     width  in pixels
///     10      2     height in pixels
///     12      8     presentation timestamp, microseconds
///     20      4     payload length
///     24      n     payload
///
/// `width` and `height` describe *video* and are zero on every non-video
/// packet. Audio used to smuggle its sample rate and channel count through
/// those two fields, which meant the receiver — whose only job is to relay,
/// and which reports the stream resolution from the last header it saw —
/// reported the session as "44100 × 2". Audio now carries its own descriptor
/// in the payload, where a sample rate above 65535 also still fits.
enum MirrorProtocol {
    static let magic: UInt32 = 0x564D_4345  // 'ECMV' little-endian
    static let headerSize = 24
    static let defaultPort: UInt16 = 7878
    /// Bonjour type the desktop browses for when no host is configured.
    static let bonjourType = "_ember-mirror._tcp"
    static let bonjourName = "EmberConnectMirror"

    enum PacketType: UInt8 {
        /// SPS/PPS in Annex-B form. Sent before the first frame and again
        /// whenever the encoder's format description changes.
        case config = 0
        /// An IDR frame — a decoder can start here.
        case keyframe = 1
        /// A non-IDR frame.
        case frame = 2
        /// A JSON blob describing the session.
        case meta = 3
        /// Linear PCM, prefixed by an `AudioDescriptor`.
        case audio = 4
    }

    /// Display orientation of the frames that follow, carried in the `flags`
    /// byte of every video packet.
    ///
    /// ReplayKit reports rotation out-of-band as a sample attachment. Whether
    /// it *also* swaps the pixel buffer's dimensions is not contractual and
    /// differs between devices, so the receiver is told the orientation and
    /// compares it against the shape of the decoded frame rather than
    /// assuming either behaviour.
    enum Orientation: UInt8 {
        case up = 0
        case down = 1
        case left = 2
        case right = 3

        /// Maps the `CGImagePropertyOrientation` raw value ReplayKit attaches
        /// as `RPVideoSampleOrientation`.
        init(cgImagePropertyOrientation raw: UInt32) {
            switch raw {
            case 3: self = .down    // .down
            case 6: self = .right   // .right  (home button on the left)
            case 8: self = .left    // .left   (home button on the right)
            default: self = .up
            }
        }

        var isLandscape: Bool { self == .left || self == .right }
    }

    /// Leads the payload of every `.audio` packet.
    ///
    ///     offset  size  field
    ///     0       4     sample rate, Hz
    ///     4       2     channel count
    ///     6       1     sample format (`AudioFormat`)
    ///     7       1     reserved (0)
    struct AudioDescriptor {
        static let size = 8

        var sampleRate: UInt32
        var channels: UInt16
        var format: AudioFormat

        func encoded() -> Data {
            var data = Data(capacity: AudioDescriptor.size)
            data.appendLE(sampleRate)
            data.appendLE(channels)
            data.append(format.rawValue)
            data.append(0)
            return data
        }
    }

    /// Only one format is ever put on the wire. The extension converts
    /// whatever ReplayKit hands it — which is Float32 on current devices, but
    /// is not documented to stay that way — into this, because the browser
    /// cannot ask what it is being sent after the fact.
    enum AudioFormat: UInt8 {
        /// Signed 16-bit, little-endian, interleaved.
        case pcmS16LEInterleaved = 1
    }

    struct Header {
        var type: PacketType
        var flags: UInt8 = 0
        var width: UInt16
        var height: UInt16
        var timestampMicros: UInt64
        var length: UInt32

        /// Serialises the header. Written byte by byte rather than by
        /// overlaying a struct, because Swift gives no layout guarantees and
        /// the receiver is not Swift.
        func encoded() -> Data {
            var data = Data(capacity: MirrorProtocol.headerSize)
            data.appendLE(MirrorProtocol.magic)
            data.append(type.rawValue)
            data.append(flags)
            data.appendLE(UInt16(0))
            data.appendLE(width)
            data.appendLE(height)
            data.appendLE(timestampMicros)
            data.appendLE(length)
            return data
        }
    }
}

extension Data {
    // `Swift.` qualified deliberately: inside an extension on Data, a bare
    // `withUnsafeBytes` binds to Data's own instance method rather than the
    // global `withUnsafeBytes(of:_:)`, which does not compile.
    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
