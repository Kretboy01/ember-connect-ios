import ReplayKit
import CoreMedia

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

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        encoder.onFormat = { [weak self] sets, width, height in
            guard let self else { return }
            // Only republish when the sets actually change; they are emitted
            // on every keyframe.
            self.parameterSets = sets
            self.frameWidth = width
            self.frameHeight = height
            self.server.send(type: .config,
                             payload: sets,
                             width: width,
                             height: height,
                             timestampMicros: 0)
        }

        encoder.onEncodedFrame = { [weak self] frame, isKeyframe, pts in
            guard let self else { return }
            let micros = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000)) : 0
            self.server.send(type: isKeyframe ? .keyframe : .frame,
                             payload: frame,
                             width: self.frameWidth,
                             height: self.frameHeight,
                             timestampMicros: micros)
        }

        // A client that attaches mid-broadcast needs its parameter sets and an
        // IDR before it can show anything.
        server.onClientConnected = { [weak self] in
            guard let self else { return }
            if let sets = self.parameterSets {
                self.server.send(type: .config,
                                 payload: sets,
                                 width: self.frameWidth,
                                 height: self.frameHeight,
                                 timestampMicros: 0)
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
            encoder.encode(sampleBuffer: sampleBuffer)
        case .audioApp, .audioMic:
            if let audio = extractAudioData(from: sampleBuffer) {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let micros = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000)) : 0
                server.send(type: .audio,
                            payload: audio.data,
                            width: Int(audio.sampleRate),
                            height: Int(audio.channels),
                            timestampMicros: micros)
            }
        @unknown default:
            break
        }
    }

    private func extractAudioData(from sampleBuffer: CMSampleBuffer) -> (data: Data, sampleRate: UInt16, channels: UInt16)? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return nil
        }

        var blockBuffer: CMBlockBuffer?
        var bufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, bufferList.mNumberBuffers > 0 else { return nil }

        let audioBuffer = bufferList.mBuffers
        guard let mData = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { return nil }

        let data = Data(bytes: mData, count: Int(audioBuffer.mDataByteSize))
        let sampleRate = UInt16(min(max(asbd.mSampleRate, 1), 65535))
        let channels = UInt16(min(max(asbd.mChannelsPerFrame, 1), 8))
        return (data, sampleRate, channels)
    }

    override func broadcastPaused() {
        // Held rather than torn down — the session resumes with the same
        // encoder, and a fresh IDR on resume keeps clients in sync.
    }

    override func broadcastResumed() {
        encoder.requestKeyframe()
    }

    override func broadcastFinished() {
        encoder.invalidate()
        server.stop()
    }
}
