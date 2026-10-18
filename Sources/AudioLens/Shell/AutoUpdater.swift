import AppKit
import IOKit.pwr_mgt
import Observation
import UserNotifications

/// What AudioLens does when a newer release appears.
enum UpdatePolicy: String, CaseIterable {
    /// Download, verify and install on its own, at a moment it can't interrupt anything.
    case automatic
    /// Say so (menu item and notification) and wait for the user to choose.
    case ask
    /// Don't look for updates; "Check Now" still works.
    case off

    var title: String {
        switch self {
        case .automatic: "Install automatically"
        case .ask: "Ask me first"
        case .off: "Don't check"
        }
    }

    static let key = "updatePolicy"

    static var current: UpdatePolicy {
        if let raw = UserDefaults.standard.string(forKey: key), let policy = UpdatePolicy(rawValue: raw) { return policy }
        return .ask
    }
}

/// Looks for updates as often as the user chose (once a day unless they change it) and,
/// depending on the policy, notifies or installs.
///
/// An automatic install relaunches AudioLens, and while it's down every app plays at its normal
/// level and without EQ. So a downloaded update waits until all of these hold:
/// - no app that AudioLens adjusts is playing, and none has for 5 minutes;
/// - no app is holding the display awake (Keynote, PowerPoint, screen sharing and video
///   players do this while they present or play);
/// - there has been no keyboard or mouse input for 2 minutes.
@Observable
@MainActor
final class AutoUpdater: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AutoUpdater()

    var policy = UpdatePolicy.current {
        didSet {
            guard policy != oldValue else { return }
            UserDefaults.standard.set(policy.rawValue, forKey: UpdatePolicy.key)
            SettingsSync.shared.localDidChange()
            if policy != .off { requestNotificationPermission(); check() }
            if policy != .automatic { staged = nil }
        }
    }

    /// How often to look for updates on its own.
    var interval = UpdateInterval.current {
        didSet {
            guard interval != oldValue else { return }
            // Only a real change: a value read from another Mac before its unit has arrived must not
            // be stored back clamped to the old unit.
            if UpdateInterval.current != interval { UpdateInterval.current = interval }
            SettingsSync.shared.localDidChange()
            scheduleChecks()
            checkIfDue()
        }
    }

    /// A verified update waiting for a quiet moment, with its version.
    private(set) var staged: (version: String, app: URL)?
    private(set) var lastError: String?
    private(set) var lastChecked: Date?
    /// Whether macOS lets AudioLens post notifications; without them "Ask me first" can only
    /// use the menu, and the note after an automatic update never appears.
    private(set) var notificationsAllowed = true

    @ObservationIgnored private var checkTimer: Timer?
    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var checking = false

    // Overridable for testing, so a run doesn't take half an hour.
    /// When set, the number of seconds between checks, in place of the chosen interval.
    private let testCheckInterval = ProcessInfo.processInfo.environment["AUDIOLENS_UPDATE_CHECK_SECONDS"].flatMap(Double.init)
    private var checkInterval: TimeInterval { testCheckInterval ?? interval.seconds }
    private let audioQuiet = TimeInterval(ProcessInfo.processInfo.environment["AUDIOLENS_UPDATE_AUDIO_QUIET_SECONDS"].flatMap(Double.init) ?? 5 * 60)
    private let userIdle = TimeInterval(ProcessInfo.processInfo.environment["AUDIOLENS_UPDATE_USER_IDLE_SECONDS"].flatMap(Double.init) ?? 2 * 60)

    private static let installedFromKey = "update.autoInstalledFrom"
    private static let notifiedVersionKey = "update.notifiedVersion"
    /// When this Mac last asked GitHub; not synced, so each Mac keeps its own schedule.
    private static let lastCheckKey = "update.lastCheck"
    nonisolated private static let category = "update"
    private static let installAction = "install"

    func start() {
        UNUserNotificationCenter.current().delegate = self
        let install = UNNotificationAction(identifier: Self.installAction, title: "Install", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [install], intentIdentifiers: []),
        ])
        if policy != .off { requestNotificationPermission() }
        announceIfJustUpdated()

        checkIfDue()
        scheduleChecks()
    }

    /// Install a waiting (or available) update now, because the user asked to.
    func installNow() {
        if let staged {
            install(staged.app, version: staged.version)
        } else {
            UpdateController.checkForUpdates()
        }
    }

    /// Ticks every 15 minutes (or sooner, for a shorter interval) and compares the clock with
    /// the last check, because a Timer stops counting while the Mac sleeps: a day-long one
    /// could otherwise wait for days.
    private func scheduleChecks() {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: min(checkInterval, 15 * 60), repeats: true) { _ in
            MainActor.assumeIsolated { AutoUpdater.shared.checkIfDue() }
        }
    }

    /// Checks if the chosen interval has passed since this Mac last asked.
    func checkIfDue() {
        if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < checkInterval - 1 { return }
        check()
    }

    // MARK: - Checking

    func check() {
        guard policy != .off, !checking, staged == nil else { return }
        checking = true
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        Task {
            defer { checking = false }
            var reachedGitHub = false
            lastChecked = Date()
            do {
                let latest = try await UpdateController.fetchLatestRelease()
                reachedGitHub = true
                guard let release = latest,
                      UpdateController.isNewer(release.version, than: AppInfo.version) else {
                    UpdateAvailability.shared.pending = nil
                    return
                }
                UpdateAvailability.shared.pending = release.version
                switch policy {
                case .off:
                    return
                case .ask:
                    guard UserDefaults.standard.string(forKey: "skippedUpdateVersion") != release.version else { return }
                    notifyAvailable(release.version)
                case .automatic:
                    let app = try await UpdateController.downloadAndStage(release)
                    try UpdateController.verifyCandidate(app, version: release.version)
                    staged = (release.version, app)
                    lastError = nil
                    NSLog("AudioLens: update \(release.version) verified; waiting for a quiet moment to install")
                    waitForQuietMoment()
                }
            } catch {
                lastError = error.localizedDescription
                if !reachedGitHub { UserDefaults.standard.removeObject(forKey: Self.lastCheckKey) }
                NSLog("AudioLens: update check failed: \(error.localizedDescription)")
                // An automatic install that failed falls back to asking, once per version.
                if policy == .automatic, let version = UpdateAvailability.shared.pending {
                    notify(id: "update-failed-\(version)", title: "AudioLens couldn't update itself",
                           body: "\(error.localizedDescription) You can install \(version) from the AudioLens menu.", installable: true)
                }
            }
        }
    }

    // MARK: - Waiting for a quiet moment

    private func waitForQuietMoment() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { AutoUpdater.shared.installIfQuiet() }
        }
        installIfQuiet()
    }

    private func installIfQuiet() {
        guard policy == .automatic, let staged else {
            idleTimer?.invalidate()
            return
        }
        guard let reason = busyReason() else {
            idleTimer?.invalidate()
            install(staged.app, version: staged.version)
            return
        }
        NSLog("AudioLens: holding update \(staged.version): \(reason)")
    }

    /// Why now would be a bad time to restart, or nil if it's fine.
    func busyReason() -> String? {
        let engine = AudioEngine.shared
        let adjusted = engine.running.values.filter { engine.isTapped($0.id) }
        if adjusted.contains(where: \.isPlaying) { return "an app AudioLens adjusts is playing" }
        if adjusted.contains(where: { Date().timeIntervalSince(engine.lastPlayed[$0.id] ?? .distantPast) < audioQuiet }) {
            return "an app AudioLens adjusts played recently"
        }
        if let app = Self.appKeepingDisplayAwake() { return "\(app) is keeping the display awake" }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle < userIdle { return "the Mac is in use" }
        return nil
    }

    /// The name of a process asking macOS not to dim or sleep the display, as presentation
    /// apps, screen sharing and video players do while they run.
    nonisolated static func appKeepingDisplayAwake() -> String? {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let dict = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return nil }
        for (pid, assertions) in dict {
            for assertion in assertions where assertion["AssertType"] as? String == "PreventUserIdleDisplaySleep" {
                return assertion["Process Name"] as? String
                    ?? NSRunningApplication(processIdentifier: pid.int32Value)?.localizedName ?? "An app"
            }
        }
        return nil
    }

    private func install(_ app: URL, version: String) {
        do {
            // Checked again now: the staged copy may have waited hours in a folder that other
            // processes of this user can write to.
            try UpdateController.verifyCandidate(app, version: version)
            UserDefaults.standard.set(AppInfo.version, forKey: Self.installedFromKey)
            NSLog("AudioLens: installing update \(version)")
            try UpdateController.installAndRelaunch(from: app)
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.installedFromKey)
            NSLog("AudioLens: update \(version) not installed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            staged = nil
        }
    }

    // MARK: - Notifications

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { MainActor.assumeIsolated { AutoUpdater.shared.notificationsAllowed = allowed } }
        }
    }

    static func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "com.smanke.AudioLens")") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            NSLog("AudioLens: notification permission granted=\(granted) error=\(error?.localizedDescription ?? "none")")
            DispatchQueue.main.async { MainActor.assumeIsolated { AutoUpdater.shared.refreshNotificationStatus() } }
        }
    }

    /// After an automatic install, the relaunched app says what changed.
    private func announceIfJustUpdated() {
        guard let from = UserDefaults.standard.string(forKey: Self.installedFromKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.installedFromKey)
        guard from != AppInfo.version else { return }
        notify(id: "updated-\(AppInfo.version)", title: "AudioLens updated to \(AppInfo.version)",
               body: "It installed itself while your Mac wasn't in use.", installable: false)
    }

    private func notifyAvailable(_ version: String) {
        guard UserDefaults.standard.string(forKey: Self.notifiedVersionKey) != version else { return }
        UserDefaults.standard.set(version, forKey: Self.notifiedVersionKey)
        notify(id: "available-\(version)", title: "AudioLens \(version) is available",
               body: "Click to review and install it. You're on \(AppInfo.version).", installable: true)
    }

    private func notify(id: String, title: String, body: String, installable: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if installable { content.categoryIdentifier = Self.category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            NSLog("AudioLens: notification \(id) posted, error=\(error?.localizedDescription ?? "none")")
        }
    }

    // The completion-handler forms: the async ones compiled but were never called in
    // NetworkToggle, so clicking a banner silently did nothing.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let installable = response.notification.request.content.categoryIdentifier == Self.category
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // Clicking the banner or its Install button opens the usual confirmation,
                // so the user still sees what they're agreeing to.
                if installable { UpdateController.checkForUpdates() }
            }
        }
        completionHandler()
    }
}
