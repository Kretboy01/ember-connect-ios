import ReplayKit
import CoreMedia
import CoreAudio
// UnsafeMutableAudioBufferListPointer lives in the AudioToolbox overlay, not
// in CoreAudioTypes, which is all CoreMedia re-exports.
import AudioToolbox

/// ReplayKit broadcast extension: the capture end of Ember Connect's screen
/// mirror.
///
/// ReplayKit delivers the *system* framebuffer — every app, the home screen,
/// Control Center — at the display's native rate, already on the GPU. Feeding
/// those buffers straight into VideoToolbox means no pixel is ever copied
/// through the CPU, which is what keeps 60 fps inside an extension capped at
/// roughly 50 MB of memory.
///
/// The alternative the desktop used to rely on — pulling whole PNG
/// screenshots over the DVT channel — is bounded by a per-frame device-side
/// PNG encode and cannot reach these rates at any resolution.
class SampleHandler: RPBroadcastSampleHandler {
    private let server = MirrorServer()
    private let encoder = H264Encoder(frameRate: 60)

    /// Latest parameter sets, resent to each client that attaches.
    private var parameterSets: Data?
    private var frameWidth = 0
    private var frameHeight = 0
    /// Orientation of the most recent video sample, published in the `flags`
    /// byte of every video packet. Written on ReplayKit's video queue and read
    /// from the encoder callback, so it stays behind `stateLock` along with
    /// the parameter sets.
    private var orientation: MirrorProtocol.Orientation = .up
    private let stateLock = NSLock()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        encoder.onFormat = { [weak self] sets, width, height in
            guard let self else { return }
            self.stateLock.lock()
            self.parameterSets = sets
            self.frameWidth = width
            self.frameHeight = height
            let flags = self.orientation.rawValue
            self.stateLock.unlock()

            self.server.send(type: .config,
                             payload: sets,
                             width: width,
                             height: height,
                             flags: flags)
        }

        encoder.onEncodedFrame = { [weak self] frame, isKeyframe, pts, width, height in
            guard let self else { return }
            let micros = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000)) : 0
            self.stateLock.lock()
            let flags = self.orientation.rawValue
            self.stateLock.unlock()

            self.server.send(type: isKeyframe ? .keyframe : .frame,
                             payload: frame,
                             width: width,
                             height: height,
                             flags: flags,
                             timestampMicros: micros)
        }

        // A client that attaches mid-broadcast needs its parameter sets and an
        // IDR before it can show anything.
        server.onClientConnected = { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let sets = self.parameterSets
            let width = self.frameWidth
            let height = self.frameHeight
            let flags = self.orientation.rawValue
            self.stateLock.unlock()

            if let sets {
                self.server.send(type: .config,
                                 payload: sets,
                                 width: width,
                                 height: height,
                                 flags: flags)
            }
            self.encoder.requestKeyframe()
        }

        server.start()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard server.hasClients else { return }

        switch sampleBufferType {
        case .video:
            updateOrientation(from: sampleBuffer)
            encoder.encode(sampleBuffer: sampleBuffer)
        case .audioApp:
            guard let audio = pcmS16(from: sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let micros = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000)) : 0
            server.send(type: .audio, payload: audio, timestampMicros: micros)
        case .audioMic:
            // Deliberately dropped. The picker is configured with
            // showsMicrophoneButton = false, so mic samples only arrive if the
            // user enabled the mic elsewhere — and mixing two unsynchronised
            // sources into one PCM stream is worse than carrying just one.
            break
        @unknown default:
            break
        }
    }

    // MARK: - Orientation

    /// ReplayKit signals rotation with a sample attachment rather than by
    /// changing the buffer, so a frame that arrives after the user turns the
    /// phone can be either shape depending on the device. The value is
    /// forwarded and the receiver compares it against the shape of the frame
    /// it actually decoded — see `MirrorProtocol.Orientation`.
    private func updateOrientation(from sampleBuffer: CMSampleBuffer) {
        // CMGetAttachment returns CFTypeRef? here, so the cast has to happen
        // after the call rather than through the binding's type.
        let attachment: CFTypeRef? = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        )
        guard let raw = attachment as? NSNumber else { return }

        let next = MirrorProtocol.Orientation(cgImagePropertyOrientation: raw.uint32Value)
        stateLock.lock()
        let changed = next != orientation
        orientation = next
        stateLock.unlock()

        if changed {
            // The new flags byte only reaches a client on the next packet, and
            // a decoder mid-GOP would keep painting the old shape until then.
            // An IDR makes the switch immediate.
            encoder.requestKeyframe()
        }
    }

    // MARK: - Audio

    /// Converts a ReplayKit audio buffer to the one format the wire carries:
    /// signed 16-bit little-endian, interleaved, prefixed by its descriptor.
    ///
    /// The previous version shipped the raw bytes and told the browser to read
    /// them as `Int16` — but `.audioApp` arrives as **32-bit float,
    /// non-interleaved** on current devices, so what reached Web Audio was
    /// float bit patterns reinterpreted as PCM: full-scale noise. Converting
    /// here rather than negotiating a format keeps the receiver, which relays
    /// bytes and understands none of them, out of it.
    private func pcmS16(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mChannelsPerFrame > 0 else {
            return nil
        }

        let channels = Int(asbd.mChannelsPerFrame)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isBigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        // Non-interleaved means one buffer per channel; interleaved means one
        // buffer holding frames of `channels` samples.
        let isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let bytesPerSample = Int(asbd.mBitsPerChannel) / 8

        guard !isBigEndian else { return nil }
        guard isFloat ? bytesPerSample == 4 : bytesPerSample == 2 else { return nil }

        // AudioBufferList is a variable-length struct: it declares one
        // AudioBuffer and any others follow it in memory. A non-interleaved
        // stereo stream needs two, so the list is allocated at the size
        // CoreMedia asks for rather than at MemoryLayout<AudioBufferList>.
        var listSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil) == noErr, listSize > 0 else {
            return nil
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer) == noErr, blockBuffer != nil else {
            return nil
        }

        // The samples belong to `blockBuffer`; every read below has to happen
        // while it is still alive, which `withExtendedLifetime` guarantees and
        // a trailing `_ = blockBuffer` does not.
        return withExtendedLifetime(blockBuffer) { () -> Data? in
            let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
            guard buffers.count > 0 else { return nil }

            var interleaved: [Int16] = []
            var outputChannels = channels

            if isInterleaved {
                let buffer = buffers[0]
                guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return nil }
                let sampleCount = Int(buffer.mDataByteSize) / bytesPerSample
                guard sampleCount >= channels else { return nil }
                interleaved = [Int16](repeating: 0, count: sampleCount)
                if isFloat {
                    let source = data.bindMemory(to: Float32.self, capacity: sampleCount)
                    for index in 0..<sampleCount {
                        interleaved[index] = Self.clampToInt16(source[index])
                    }
                } else {
                    let source = data.bindMemory(to: Int16.self, capacity: sampleCount)
                    for index in 0..<sampleCount {
                        interleaved[index] = source[index]
                    }
                }
            } else {
                let planes = min(channels, buffers.count)
                guard planes > 0 else { return nil }
                let framesPerPlane = Int(buffers[0].mDataByteSize) / bytesPerSample
                guard framesPerPlane > 0 else { return nil }
                outputChannels = planes
                interleaved = [Int16](repeating: 0, count: framesPerPlane * planes)
                for plane in 0..<planes {
                    guard let data = buffers[plane].mData,
                          Int(buffers[plane].mDataByteSize) / bytesPerSample >= framesPerPlane else {
                        continue
                    }
                    if isFloat {
                        let source = data.bindMemory(to: Float32.self, capacity: framesPerPlane)
                        for frame in 0..<framesPerPlane {
                            interleaved[frame * planes + plane] = Self.clampToInt16(source[frame])
                        }
                    } else {
                        let source = data.bindMemory(to: Int16.self, capacity: framesPerPlane)
                        for frame in 0..<framesPerPlane {
                            interleaved[frame * planes + plane] = source[frame]
                        }
                    }
                }
            }

            guard !interleaved.isEmpty else { return nil }

            var payload = MirrorProtocol.AudioDescriptor(
                sampleRate: UInt32(max(1, asbd.mSampleRate)),
                channels: UInt16(max(1, outputChannels)),
                format: .pcmS16LEInterleaved
            ).encoded()

            interleaved.withUnsafeBufferPointer { samples in
                guard let base = samples.baseAddress else { return }
                base.withMemoryRebound(to: UInt8.self, capacity: samples.count * 2) { bytes in
                    payload.append(bytes, count: samples.count * 2)
                }
            }

            return payload
        }
    }

    private static func clampToInt16(_ value: Float32) -> Int16 {
        // NaN compares false against both bounds, so it would fall through to
        // the conversion and trap — hence the explicit check first.
        guard value.isFinite else { return 0 }
        let scaled = value * 32767.0
        if scaled >= 32767.0 { return Int16.max }
        if scaled <= -32768.0 { return Int16.min }
        return Int16(scaled)
    }

    override func broadcastPaused() {
        // Held rather than torn down — the session resumes with the same
        // encoder, and a fresh IDR on resume keeps clients in sync.
    }

    override func broadcastResumed() {
        encoder.requestKeyframe()
    }

    override func broadcastFinished() {
        // Server first: with no client attached `processSampleBuffer` returns
        // immediately, so nothing can be mid-encode when the session goes.
        server.stop()
        encoder.invalidate()
    }
}
