import AppKit
import Observation

/// Whether macOS lets AudioLens capture other apps' audio ("System Audio Recording Only" under
/// Privacy & Security › Screen & System Audio Recording).
///
/// This matters for safety, not just features: a tap mutes the app it captures, and without
/// permission the captured audio is silence. So no tap is created until this says yes, or an
/// app would go quiet the moment AudioLens touched it.
///
/// macOS has no public call to ask about this permission, so it uses the TCC framework's
/// preflight and request functions, looked up at run time.
@Observable
@MainActor
final class CapturePermission {
    static let shared = CapturePermission()

    enum Status { case unknown, authorized, denied }

    private(set) var status: Status = .unknown
    var isAuthorized: Bool { status == .authorized }

    private init() {
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CapturePermission.shared.refresh() }
        }
        // Granting it in System Settings doesn't activate AudioLens, so look now and then.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated {
                if CapturePermission.shared.status != .authorized { CapturePermission.shared.refresh() }
            }
        }
    }

    func refresh() {
        let before = status
        switch TCC.preflight() {
        case 0: status = .authorized
        case 1: status = .denied
        default: status = .unknown
        }
        if status != before {
            NSLog("AudioLens: audio capture permission \(status)")
            if status == .authorized { AudioEngine.shared.permissionChanged() }
        }
    }

    /// Shows the system prompt. macOS shows it once; after that only System Settings can change it.
    func request() {
        guard status != .authorized else { return }
        TCC.request { granted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    CapturePermission.shared.refresh()
                    if granted, CapturePermission.shared.status != .authorized {
                        CapturePermission.shared.status = .authorized
                        AudioEngine.shared.permissionChanged()
                    }
                }
            }
        }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private enum TCC {
        nonisolated(unsafe) static let service = "kTCCServiceAudioCapture" as CFString
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

        nonisolated(unsafe) static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

        /// 0 granted, 1 denied, anything else not decided yet (or the function is missing).
        static func preflight() -> Int {
            guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return -1 }
            return unsafeBitCast(symbol, to: Preflight.self)(service, nil)
        }

        static func request(_ completion: @escaping (Bool) -> Void) {
            guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return completion(false) }
            unsafeBitCast(symbol, to: Request.self)(service, nil, completion)
        }
    }
}
