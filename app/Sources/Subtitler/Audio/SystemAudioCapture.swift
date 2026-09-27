import AVFoundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display available for audio capture."
        }
    }
}

/// Captures everything the Mac is playing via ScreenCaptureKit and delivers 16 kHz mono
/// Float32 samples. Needs the Screen Recording permission; our own audio is excluded.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    static let sampleRate: Double = 16_000

    /// Called on the capture queue.
    var onSamples: (([Float]) -> Void)?
    var onStop: ((Error?) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "subtitler.audio-capture")
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(Self.sampleRate)
        config.channelCount = 1
        // Video is required by the API but unused: keep it tiny and slow.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Without a screen output ScreenCaptureKit logs a warning for every dropped frame.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let samples = convert(sampleBuffer), !samples.isEmpty else { return }
        onSamples?(samples)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?(error)
    }

    /// ScreenCaptureKit usually honours the requested 16 kHz mono, but resample when it doesn't.
    private func convert(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: description.mSampleRate,
                  channels: description.mChannelsPerFrame)
        else { return nil }

        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        input.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList) == noErr
        else { return nil }

        if format.sampleRate == Self.sampleRate, format.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: input.floatChannelData![0], count: Int(frames)))
        }

        if converter?.inputFormat != format {
            converter = AVAudioConverter(from: format, to: targetFormat)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(frames) * Self.sampleRate / format.sampleRate) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil else { return nil }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
