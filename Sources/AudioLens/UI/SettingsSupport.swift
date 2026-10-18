import AppKit
import SwiftUI

/// Sets up, enters or changes the sync passphrase.
struct SyncPassphraseForm: View {
    enum Mode { case create, enter, change, startOver }

    @State var mode: Mode
    @State private var sync = SettingsSync.shared
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?
    @State private var changing = false
    @State private var confirmStartOver = false

    private var needsConfirm: Bool { mode != .enter }
    private var valid: Bool {
        mode == .enter ? !passphrase.isEmpty : passphrase.count >= 8 && confirm == passphrase
    }

    var body: some View {
        if mode == .change && !changing {
            LabeledContent("Encrypted with your sync passphrase") {
                Button("Change Passphrase…") { changing = true }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(prompt).fixedSize(horizontal: false, vertical: true)
                SecureField("", text: $passphrase, prompt: Text(mode == .enter ? "Passphrase" : "New passphrase"))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .textContentType(mode == .enter ? .password : .newPassword)
                    .onSubmit { if valid && !needsConfirm { submit() } }
                if needsConfirm {
                    SecureField("", text: $confirm, prompt: Text("Confirm passphrase"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .textContentType(.newPassword)
                        .onSubmit { if valid { submit() } }
                    if !passphrase.isEmpty && passphrase.count < 8 {
                        Text("At least 8 characters.").font(.caption).foregroundStyle(.secondary)
                    } else if !confirm.isEmpty && confirm != passphrase {
                        Text("The passphrases don't match.").font(.caption).foregroundStyle(.red)
                    }
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
                HStack {
                    if mode == .enter {
                        Button("Forgot It? Start Over…") { confirmStartOver = true }
                    }
                    if mode == .change || mode == .startOver {
                        Button("Cancel") { reset(to: mode == .startOver ? .enter : .change) }
                    }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button(buttonTitle) { submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!valid || working)
                }
            }
            .padding(.vertical, 4)
            .confirmationDialog("Start over with a new passphrase?", isPresented: $confirmStartOver) {
                Button("Start Over", role: .destructive) { reset(to: .startOver) }
            } message: {
                Text("The encrypted settings in iCloud Drive are replaced with this Mac's, and your other Macs will ask for the new passphrase.")
            }
        }
    }

    private var prompt: String {
        switch mode {
        case .create: "Choose a sync passphrase. Your settings are encrypted with it before they go to iCloud Drive, and you'll enter the same passphrase on your other Macs. It never leaves your Macs and can't be recovered, so keep it somewhere safe."
        case .enter: "Your synced settings are encrypted. Enter the sync passphrase you chose on your other Mac."
        case .change: "Choose a new sync passphrase. Your other Macs keep syncing; you'll only need the new one when you set up another Mac."
        case .startOver: "Choose a new sync passphrase. Enter it on your other Macs when they ask."
        }
    }

    private var buttonTitle: String {
        switch mode {
        case .create: "Turn On Encrypted Sync"
        case .enter: "Unlock"
        case .change: "Change Passphrase"
        case .startOver: "Start Over"
        }
    }

    private func reset(to newMode: Mode) {
        mode = newMode
        passphrase = ""
        confirm = ""
        error = nil
        changing = false
    }

    private func submit() {
        guard valid, !working else { return }
        working = true
        error = nil
        let entered = passphrase
        Task {
            defer { working = false }
            do {
                switch mode {
                case .create: try await sync.createPassphrase(entered)
                case .enter: try await sync.enterPassphrase(entered)
                case .change: try await sync.changePassphrase(entered)
                case .startOver: try await sync.createPassphrase(entered, replacing: true)
                }
                reset(to: .change)
            } catch {
                if case SettingsSync.SyncError.alreadySetUp = error { reset(to: .enter) }
                self.error = error.localizedDescription
            }
        }
    }
}

/// `AppPresence` values as observable state for Settings.
@Observable
@MainActor
final class PresenceSettings {
    static let shared = PresenceSettings()

    var showInDock = AppPresence.showInDock {
        didSet {
            AppPresence.showInDock = showInDock
            AppPresence.applyDock(keepInFront: NSApp.keyWindow)
        }
    }

    var showInMenuBar = AppPresence.showInMenuBar {
        didSet { AppPresence.showInMenuBar = showInMenuBar }
    }

    /// Follows choices that arrived from another Mac.
    func reload() {
        if showInDock != AppPresence.showInDock { showInDock = AppPresence.showInDock }
        if showInMenuBar != AppPresence.showInMenuBar { showInMenuBar = AppPresence.showInMenuBar }
        // The status item follows the notification, which the setter only posts on a change.
        NotificationCenter.default.post(name: AppPresence.menuBarDidChange, object: nil)
    }
}
