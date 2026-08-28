import Foundation
import VideoToolbox
import CoreMedia

/// Hardware H.264 encoder built on VideoToolbox.
///
/// ReplayKit hands us `CMSampleBuffer`s backed by IOSurfaces that the encoder
/// can read directly, so a frame never touches the CPU on its way from the
/// compositor to the network. That is what makes 60 fps affordable inside an
/// extension with a ~50 MB memory ceiling.
///
/// Output is Annex-B (start-code delimited). VideoToolbox emits AVCC (4-byte
/// length prefixes), so `convertToAnnexB` rewrites the prefixes in place.
final class H264Encoder {
    /// Called for every encoded frame. `isKeyframe` lets the caller tag the
    /// packet so a late-joining decoder knows where it may start.
    var onEncodedFrame: ((Data, Bool, CMTime) -> Void)?
    /// Called whenever the parameter sets change, including once before the
    /// first frame.
    var onFormat: ((Data, Int, Int) -> Void)?

    private var session: VTCompressionSession?
    private var width: Int = 0
    private var height: Int = 0
    /// Consumed by the next `encode` call — see `requestKeyframe`.
    private var forceNextKeyframe = false
    private let targetFrameRate: Int32
    /// Serialises encoder access. ReplayKit may deliver on more than one
    /// queue and VTCompressionSession is not re-entrant.
    private let queue = DispatchQueue(label: "com.emberwave.mirror.encoder")

    init(frameRate: Int32 = 60) {
        self.targetFrameRate = frameRate
    }

    deinit {
        invalidate()
    }

    // MARK: - Session lifecycle

    /// (Re)creates the compression session. Called on the first frame and any
    /// time the source dimensions change — a device rotation produces a
    /// differently shaped buffer and the session is bound to its dimensions.
    private func prepare(width: Int, height: Int) -> Bool {
        if session != nil, self.width == width, self.height == height {
            return true
        }

        invalidate()

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )

        guard status == noErr, let created = newSession else {
            NSLog("[Mirror] VTCompressionSessionCreate failed: \(status)")
            return false
        }

        // Latency matters more than compression ratio here: the frame is on
        // screen ~16 ms from now or it is useless.
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        // B-frames would reorder output and add at least one frame of delay.
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: targetFrameRate))
        // A keyframe every two seconds bounds how long a client that joins
        // mid-stream waits for its first picture.
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: targetFrameRate * 2))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: NSNumber(value: 2))
        // Scale the bitrate with pixel count so a Pro Max does not look worse
        // than an SE.
        //
        // 0.28 bits per pixel per frame is generous for screen content, which
        // compresses far better than camera video — but the stream crosses a
        // USB cable, not a network, so there is no reason to ration it. At the
        // earlier 0.12 the panel's fine detail (small text, thin icon strokes)
        // was visibly softened by the encoder rather than by any scaling.
        let bitrate = min(Int(Double(width * height) * 0.28 * Double(targetFrameRate)), 40_000_000)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrate))

        VTCompressionSessionPrepareToEncodeFrames(created)

        session = created
        self.width = width
        self.height = height
        return true
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        width = 0
        height = 0
    }

    // MARK: - Encoding

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let bufferWidth = CVPixelBufferGetWidth(imageBuffer)
        let bufferHeight = CVPixelBufferGetHeight(imageBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        queue.sync {
            guard prepare(width: bufferWidth, height: bufferHeight),
                  let session else { return }

            var frameProperties: CFDictionary?
            if forceNextKeyframe {
                frameProperties = [
                    kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any
                ] as CFDictionary
                forceNextKeyframe = false
            }

            VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: imageBuffer,
                presentationTimeStamp: pts,
                duration: .invalid,
                frameProperties: frameProperties,
                infoFlagsOut: nil
            ) { [weak self] status, _, encoded in
                guard status == noErr, let encoded else { return }
                self?.handleEncoded(encoded)
            }
        }
    }

    /// Forces the next frame to be an IDR. Used when a new client connects so
    /// it does not wait up to two seconds for the periodic keyframe.
    ///
    /// `kVTEncodeFrameOptionKey_ForceKeyFrame` is a *frame* property, not a
    /// session one — it has to travel in the `frameProperties` dictionary of a
    /// specific `VTCompressionSessionEncodeFrame` call, so all this can do is
    /// raise a flag the next encode consumes.
    func requestKeyframe() {
        queue.async { [weak self] in
            self?.forceNextKeyframe = true
        }
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let isKeyframe = Self.isKeyframe(sampleBuffer)

        // Parameter sets live in the format description, not the bitstream, so
        // they have to be pulled out and sent separately. Do it on every
        // keyframe: it is a few dozen bytes and it means a client that joins
        // late is never stuck without an SPS.
        if isKeyframe,
           let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let parameterSets = Self.annexBParameterSets(from: format) {
            onFormat?(parameterSets, width, height)
        }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer,
                                          atOffset: 0,
                                          lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPointer) == noErr,
              let dataPointer else { return }

        let avcc = Data(bytes: dataPointer, count: totalLength)
        guard let annexB = Self.convertToAnnexB(avcc) else { return }

        onEncodedFrame?(annexB, isKeyframe, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // MARK: - Bitstream helpers

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                       createIfNecessary: false)
                as? [[CFString: Any]],
              let first = attachments.first else {
            // No attachments at all means nothing was marked "not sync", so
            // treat it as a sync sample.
            return true
        }
        // Present *and* true means this frame depends on others.
        if let dependsOnOthers = first[kCMSampleAttachmentKey_DependsOnOthers] as? Bool {
            return !dependsOnOthers
        }
        return true
    }

    /// Extracts SPS/PPS from a format description as one Annex-B blob.
    private static func annexBParameterSets(from format: CMFormatDescription) -> Data? {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr else { return nil }

        var output = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                  let pointer else { continue }
            output.append(contentsOf: startCode)
            output.append(pointer, count: size)
        }

        return output.isEmpty ? nil : output
    }

    /// Rewrites AVCC 4-byte length prefixes as Annex-B start codes.
    ///
    /// Both are 4 bytes wide, so this could be done in place, but the input
    /// buffer is owned by the sample buffer and must not be mutated.
    private static func convertToAnnexB(_ avcc: Data) -> Data? {
        var output = Data(capacity: avcc.count)
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var offset = 0

        avcc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset + 4 <= avcc.count {
                // Length prefix is big-endian regardless of host order.
                let length = Int(UInt32(bigEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                offset += 4
                guard length > 0, offset + length <= avcc.count else { break }
                output.append(contentsOf: startCode)
                let nal = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                output.append(nal, count: length)
                offset += length
            }
        }

        return output.isEmpty ? nil : output
    }
}
