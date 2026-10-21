import AppKit
import CryptoKit
import Foundation
import Observation
import Security
import AudioLensKit

/// Keeps settings in step across the Macs on one iCloud account, end-to-end encrypted,
/// through files in iCloud Drive (`iCloud Drive/AudioLens/`):
///
///     Keyring.json      the data key, wrapped by the sync passphrase (see `SyncCrypto`)
///     Settings.sealed   every synced setting, sealed with AES-256-GCM under the data key
///
/// Whole-document, last-writer-wins: each change rewrites the file, and a newer file from
/// another Mac replaces this Mac's settings. The passphrase never leaves the Mac; each Mac
/// keeps the unwrapped key in its login keychain. A plain file needs no iCloud entitlement or
/// provisioning profile, which works only because the app is not sandboxed. Left on each
/// Mac: open at login (a per-Mac login item), each device's last volume and the window layout.
@Observable
@MainActor
final class SettingsSync {
    static let shared = SettingsSync()

    enum KeyState: Equatable {
        /// Sync is off, or iCloud Drive isn't available.
        case inactive
        /// Nothing is set up in iCloud yet: choose a passphrase.
        case needsNewPassphrase
        /// Another Mac set up encryption: enter its passphrase.
        case needsPassphrase
        case ready
    }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            if isEnabled {
                // Turning sync on adopts what other Macs share; this Mac's settings are
                // uploaded only if nothing is there yet.
                localModified = nil
                start()
            } else {
                stop()
            }
        }
    }
    private(set) var keyState = KeyState.inactive
    private(set) var lastSynced: Date?
    private(set) var lastSource: String?
    private(set) var lastError: String?

    /// When settings last changed on this Mac, or were adopted from iCloud.
    private var localModified: Date? {
        get { defaults.object(forKey: Keys.localModified) as? Date }
        set { defaults.set(newValue, forKey: Keys.localModified) }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var key: SymmetricKey?
    @ObservationIgnored private var keyring: SyncCrypto.Keyring?
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastSeenFileDate: Date?
    @ObservationIgnored private var lastSeenKeyringDate: Date?

    private enum Keys {
        static let enabled = "sync.enabled"
        static let localModified = "sync.localModified"
    }

    /// Settings that follow the user between Macs.
    static var syncedKeys: [String] {
        SettingsStore.syncedKeys + ["showInDock", "showInMenuBar", MenuHub.foldKey, UpdatePolicy.key,
         UpdateInterval.valueKey, UpdateInterval.unitKey]
    }

    nonisolated static var folder: URL {
        if let override = ProcessInfo.processInfo.environment["AUDIOLENS_SYNC_FOLDER"] {
            return URL(fileURLWithPath: override).appending(path: "AudioLens")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs/AudioLens")
    }
    nonisolated static var settingsFile: URL { folder.appending(path: "Settings.sealed") }
    nonisolated static var keyringFile: URL { folder.appending(path: "Keyring.json") }

    var iCloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath: Self.folder.deletingLastPathComponent().path)
    }

    /// Must not touch SettingsStore: its initializer can report changes here.
    private init() {
        isEnabled = defaults.bool(forKey: Keys.enabled)
        key = SyncKeychain.loadKey()
    }

    // MARK: - Lifecycle

    /// On a brand-new install, a keyring already in iCloud Drive means this user has AudioLens
    /// on another Mac: turn sync on (it then asks for the passphrase) rather than starting
    /// from the defaults.
    func adoptOnNewInstall() {
        guard !isEnabled, FileManager.default.fileExists(atPath: Self.keyringFile.path) else { return }
        NSLog("AudioLens: new install found synced settings in iCloud Drive; turning sync on")
        isEnabled = true
    }

    func start() {
        guard isEnabled, !started else { return }
        guard iCloudDriveAvailable else {
            keyState = .inactive
            lastError = "iCloud Drive isn't turned on for this Mac. Turn it on in System Settings › Apple Account › iCloud."
            return
        }
        started = true
        lastError = nil
        refreshKeyState()
        if keyState == .ready { pull() }
        // iCloud delivers other Macs' edits in the background; look for them periodically.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { SettingsSync.shared.checkForRemoteChange() }
        }
    }

    private func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        writeTask?.cancel()
        lastError = nil
        keyState = .inactive
    }

    func syncNow() {
        guard isEnabled else { return }
        if !started { start() } else { checkForRemoteChange(force: true) }
    }

    /// Called whenever a synced setting really changes on this Mac.
    func localDidChange() {
        guard !applying else { return }
        localModified = Self.now
        guard started, keyState == .ready else { return }
        writeTask?.cancel()
        // Debounced, so dragging a slider writes once rather than for every step.
        writeTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            write()
        }
    }

    // MARK: - Passphrase and key

    /// Works out whether this Mac's key opens what's in iCloud Drive.
    private func refreshKeyState() {
        guard let remote = readKeyring() else {
            keyring = nil
            if key != nil { forgetKey() }
            keyState = .needsNewPassphrase
            return
        }
        keyring = remote
        if let key, SyncCrypto.keyID(for: key) == remote.keyID {
            keyState = .ready
        } else {
            // No key yet, or another Mac started over with a new passphrase.
            if key != nil { forgetKey() }
            keyState = .needsPassphrase
        }
    }

    /// Sets up encryption with a new passphrase: a fresh key, wrapped into the keyring.
    /// `replacing` starts over, replacing what was sealed with the old key.
    func createPassphrase(_ passphrase: String, replacing: Bool = false) async throws {
        let (newKeyring, newKey) = try await Task.detached { try SyncCrypto.createKeyring(passphrase: passphrase) }.value
        if !replacing, readKeyring() != nil {
            // Another Mac set up encryption meanwhile: join it instead.
            refreshKeyState()
            throw SyncError.alreadySetUp
        }
        try writeKeyring(newKeyring)
        keyring = newKeyring
        // This Mac's settings become the shared copy.
        localModified = localModified ?? Self.now
        adopt(newKey)
        write()
        NSLog("AudioLens: set up encrypted sync (key \(newKeyring.keyID))")
    }

    /// Unlocks the key another Mac set up. Throws `SyncCrypto.CryptoError.wrongPassphrase`.
    func enterPassphrase(_ passphrase: String) async throws {
        if keyring == nil { keyring = readKeyring() }
        guard let keyring else { throw SyncError.noKeyring }
        let unlocked = try await Task.detached { try SyncCrypto.unwrap(keyring, passphrase: passphrase) }.value
        // Adopt what the other Macs share rather than overwriting it.
        localModified = nil
        adopt(unlocked)
        pull()
    }

    /// Rewraps the same key with a new passphrase, so other Macs keep working.
    func changePassphrase(_ passphrase: String) async throws {
        guard let key else { throw SyncError.noKeyring }
        let rewrapped = try await Task.detached { try SyncCrypto.wrap(key, passphrase: passphrase) }.value
        try writeKeyring(rewrapped)
        keyring = rewrapped
    }

    private func adopt(_ newKey: SymmetricKey) {
        key = newKey
        SyncKeychain.saveKey(newKey)
        keyState = .ready
        lastError = nil
    }

    private func forgetKey() {
        key = nil
        SyncKeychain.deleteKey()
    }

    enum SyncError: LocalizedError {
        case noKeyring, alreadySetUp
        var errorDescription: String? {
            switch self {
            case .noKeyring: "The sync keyring isn't in iCloud Drive yet. Try again in a moment."
            case .alreadySetUp: "Another Mac has just set up encrypted sync. Enter the passphrase you chose there."
            }
        }
    }

    // MARK: - Reading and writing

    private struct Document {
        var updatedAt: Date
        var updatedBy: String
        var settings: [String: Any]
    }

    private func checkForRemoteChange(force: Bool = false) {
        guard started else { return }
        let keyringDate = Self.modificationDate(Self.keyringFile)
        if force || keyringDate != lastSeenKeyringDate {
            let before = keyState
            refreshKeyState()
            if before == .ready, keyState != .ready { NSLog("AudioLens: the sync key changed on another Mac") }
        }
        guard keyState == .ready else { return }
        if force || Self.modificationDate(Self.settingsFile) != lastSeenFileDate { pull() }
    }

    private func pull() {
        guard keyState == .ready else { return }
        guard let remote = readRemote() else {
            // Nothing in iCloud yet: this Mac's settings become the shared copy.
            if lastError == nil { write() }
            return
        }
        if let local = localModified, local > remote.updatedAt {
            write()
        } else if localModified == nil || remote.updatedAt > localModified! {
            apply(remote)
        } else {
            noteSynced(remote)
        }
    }

    private func readKeyring() -> SyncCrypto.Keyring? {
        let url = Self.keyringFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Evicted to save space: ask for it back for next time.
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        lastSeenKeyringDate = Self.modificationDate(url)
        guard let data = coordinatedRead(url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SyncCrypto.Keyring.self, from: data)
    }

    private func writeKeyring(_ keyring: SyncCrypto.Keyring) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try coordinatedWrite(try encoder.encode(keyring), to: Self.keyringFile)
        lastSeenKeyringDate = Self.modificationDate(Self.keyringFile)
    }

    private func readRemote() -> Document? {
        let url = Self.settingsFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        lastSeenFileDate = Self.modificationDate(url)
        guard let key, let sealed = coordinatedRead(url) else { return nil }
        guard let data = try? SyncCrypto.open(sealed, using: key),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let updatedAt = plist["updatedAt"] as? Date,
              let settings = plist["settings"] as? [String: Any] else {
            lastError = "The synced settings couldn't be read. If another Mac changed the passphrase, enter the new one."
            return nil
        }
        lastError = nil
        return Document(updatedAt: updatedAt, updatedBy: plist["updatedBy"] as? String ?? "another Mac", settings: settings)
    }

    private func write() {
        guard isEnabled, iCloudDriveAvailable, keyState == .ready, let key else { return }
        let updatedAt = localModified ?? Self.now
        // The whole set, defaults included (see SettingsStore.snapshot).
        var settings = SettingsStore.shared.snapshot
        settings["showInDock"] = AppPresence.showInDock
        settings["showInMenuBar"] = AppPresence.showInMenuBar
        settings[MenuHub.foldKey] = MenuHub.shared.foldIntoToolHUD
        settings[UpdatePolicy.key] = UpdatePolicy.current.rawValue
        settings[UpdateInterval.valueKey] = UpdateInterval.current.value
        settings[UpdateInterval.unitKey] = UpdateInterval.current.unit.rawValue
        let plist: [String: Any] = ["version": 1, "updatedAt": updatedAt, "updatedBy": Self.deviceName, "settings": settings]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            try coordinatedWrite(try SyncCrypto.seal(data, using: key), to: Self.settingsFile)
            if localModified == nil { localModified = updatedAt }
            lastSeenFileDate = Self.modificationDate(Self.settingsFile)
            noteSynced(Document(updatedAt: updatedAt, updatedBy: Self.deviceName, settings: settings))
        } catch {
            lastError = "Settings couldn't be saved to iCloud Drive: \(error.localizedDescription)"
        }
    }

    private func apply(_ remote: Document) {
        applying = true
        defer { applying = false }
        // Only what the file holds: a missing setting keeps this Mac's value.
        for key in Self.syncedKeys {
            if let value = remote.settings[key] { defaults.set(value, forKey: key) }
        }
        SettingsStore.shared.reload()
        AudioEngine.shared.settingsChanged(appID: nil)
        AudioEngine.shared.eqChanged(deviceUID: nil)
        AutoUpdater.shared.policy = UpdatePolicy.current
        AutoUpdater.shared.interval = UpdateInterval.current
        HotKeys.shared.apply()
        PresenceSettings.shared.reload()
        localModified = remote.updatedAt
        noteSynced(remote)
        NSLog("AudioLens: adopted settings from \(remote.updatedBy) (\(remote.updatedAt))")
    }

    private func noteSynced(_ document: Document) {
        lastSynced = Date()
        lastSource = document.updatedBy
        lastError = nil
    }

    // MARK: - Files

    private func coordinatedRead(_ url: URL) -> Data? {
        var result: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = try? Data(contentsOf: target)
        }
        if let coordinationError { lastError = coordinationError.localizedDescription }
        return result
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Whole seconds, so a date read back from the file compares equal to the one written.
    private static var now: Date {
        Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))
    }

    static var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}

/// The sync data key, kept in this Mac's login keychain.
enum SyncKeychain {
    static let service = "com.smanke.AudioLens.sync"
    static let account = "data-key"

    static func saveKey(_ key: SymmetricKey) {
        deleteKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "AudioLens sync key",
            kSecValueData as String: key.withUnsafeBytes { Data($0) },
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { NSLog("AudioLens: couldn't save the sync key (\(status))") }
    }

    static func loadKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func deleteKey() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
