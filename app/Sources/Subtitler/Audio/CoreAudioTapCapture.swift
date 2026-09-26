import AVFoundation
import CoreAudio

/// Something that delivers the Mac's playing audio as 16 kHz mono Float32.
protocol AudioCapture: AnyObject {
    /// Called on a background queue.
    var onSamples: (([Float]) -> Void)? { get set }
    var onStop: ((Error?) -> Void)? { get set }
    func start() async throws
    func stop() async
}

extension SystemAudioCapture: AudioCapture {}

enum AudioCaptureFactory {
    /// Core Audio taps need only the "System Audio Recording" permission; older macOS
    /// versions fall back to ScreenCaptureKit, which needs Screen Recording.
    static func make() -> AudioCapture {
        if #available(macOS 14.2, *) { CoreAudioTapCapture() } else { SystemAudioCapture() }
    }

    static var usesScreenRecording: Bool {
        if #available(macOS 14.2, *) { false } else { true }
    }
}

enum CoreAudioTapError: LocalizedError {
    case status(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let step, let code): "Could not capture system audio (\(step), error \(code))."
        }
    }
}

/// Taps the system output mix with a Core Audio process tap (macOS 14.2+) and reads it
/// through a private aggregate device. Our own process is excluded. If the default output
/// device changes (e.g. AirPods connect), the tap is rebuilt on the new device.
@available(macOS 14.2, *)
final class CoreAudioTapCapture: AudioCapture {
    var onSamples: (([Float]) -> Void)?
    var onStop: ((Error?) -> Void)?

    private let queue = DispatchQueue(label: "subtitler.audio-tap")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: SystemAudioCapture.sampleRate, channels: 1, interleaved: false)!

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    func start() async throws {
        try queue.sync { try build() }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuild() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, listener)
        deviceListener = listener
    }

    func stop() async {
        if let listener = deviceListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, listener)
            deviceListener = nil
        }
        queue.sync { teardown() }
    }

    private func rebuild() {
        teardown()
        do {
            try build()
        } catch {
            onStop?(error)
        }
    }

    private func build() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check("create tap", AudioHardwareCreateProcessTap(description, &tapID))

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check("read tap format", AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &format))
        guard let tapFormat = AVAudioFormat(streamDescription: &format) else {
            throw CoreAudioTapError.status("tap format", -1)
        }
        inputFormat = tapFormat
        converter = AVAudioConverter(from: tapFormat, to: targetFormat)

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Subtitler Audio Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check("create aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        try check("create IO proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, input, _, _, _ in
            self?.receive(input)
        })
        try check("start", AudioDeviceStart(aggregateID, procID))
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func receive(_ bufferList: UnsafePointer<AudioBufferList>) {
        guard let inputFormat, let converter,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: bufferList, deallocator: nil),
              input.frameLength > 0
        else { return }
        let ratio = SystemAudioCapture.sampleRate / inputFormat.sampleRate
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 32)
        else { return }
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
        guard error == nil, output.frameLength > 0, let data = output.floatChannelData else { return }
        onSamples?(Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength))))
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw CoreAudioTapError.status(step, status) }
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, 0, nil, &size, &device)
        guard status == noErr else { throw CoreAudioTapError.status("find output device", status) }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw CoreAudioTapError.status("read output device", status) }
        return uid.takeRetainedValue() as String
    }

    /// Our own Core Audio process object, so any sound we play is not captured.
    private static func ownProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? [object] : []
    }
}
