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
enum MirrorProtocol {
    static let magic: UInt32 = 0x564D_4345  // 'ECMV' little-endian
    static let headerSize = 24
    static let defaultPort: UInt16 = 7878

    enum PacketType: UInt8 {
        /// SPS/PPS in Annex-B form. Sent before the first frame and again
        /// whenever the encoder's format description changes.
        case config = 0
        /// An IDR frame — a decoder can start here.
        case keyframe = 1
        /// A non-IDR frame.
        case frame = 2
        /// A JSON blob describing the session (scale, orientation).
        case meta = 3
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
    mutating func appendLE(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
