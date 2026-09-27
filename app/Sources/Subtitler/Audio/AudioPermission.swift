import CoreGraphics
import Foundation

/// The permission audio capture needs: "System Audio Recording" for Core Audio taps, or
/// Screen Recording on macOS before 14.2.
///
/// macOS has no public API to check or request System Audio Recording, so this uses the
/// TCC framework's `TCCAccessPreflight` / `TCCAccessRequest` when present (as Apple's
/// own tools and open-source recorders do) and reports `.unknown` otherwise.
enum AudioPermission {
    enum Status: Equatable {
        case granted, denied, unknown
    }

    static var settingsURL: URL {
        let pane = AudioCaptureFactory.usesScreenRecording ? "Privacy_ScreenCapture" : "Privacy_AudioCapture"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    static var name: String {
        AudioCaptureFactory.usesScreenRecording ? "Screen Recording" : "System Audio Recording"
    }

    static func status() -> Status {
        if AudioCaptureFactory.usesScreenRecording {
            return CGPreflightScreenCaptureAccess() ? .granted : .unknown
        }
        guard let preflight = TCC.preflight else { return .unknown }
        switch preflight(TCC.audioCapture, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if macOS hasn't asked yet.
    static func request() async -> Status {
        if AudioCaptureFactory.usesScreenRecording {
            return CGRequestScreenCaptureAccess() ? .granted : .denied
        }
        guard let request = TCC.request else { return .unknown }
        return await withCheckedContinuation { continuation in
            request(TCC.audioCapture, nil) { granted in
                continuation.resume(returning: granted ? .granted : .denied)
            }
        }
    }
}

private enum TCC {
    typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static let audioCapture = "kTCCServiceAudioCapture" as CFString

    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static let preflight: Preflight? = handle.flatMap { dlsym($0, "TCCAccessPreflight") }
        .map { unsafeBitCast($0, to: Preflight.self) }

    static let request: Request? = handle.flatMap { dlsym($0, "TCCAccessRequest") }
        .map { unsafeBitCast($0, to: Request.self) }
}
