import AppKit
import AudioLensKit
import Observation
import UniformTypeIdentifiers

/// The AutoEQ list of measured headphones, fetched once and cached on disk, and applying a
/// chosen model's correction to a device.
@Observable
@MainActor
final class CorrectionCatalog {
    static let shared = CorrectionCatalog()

    private(set) var entries: [AutoEQ.Entry] = []
    private(set) var loading = false
    private(set) var lastError: String?

    private static var cacheFile: URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "AudioLens")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "AutoEQ-INDEX.md")
    }

    /// Loads the list, from the cache if it's less than two weeks old.
    func load() {
        guard entries.isEmpty, !loading else { return }
        let cache = Self.cacheFile
        if let date = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(date) < 14 * 86400, let text = try? String(contentsOf: cache, encoding: .utf8) {
            entries = AutoEQ.parseIndex(text)
            if !entries.isEmpty { return }
        }
        loading = true
        lastError = nil
        Task {
            defer { loading = false }
            do {
                let (data, response) = try await URLSession.shared.data(from: AutoEQ.indexURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
                    throw URLError(.badServerResponse)
                }
                try? data.write(to: cache, options: .atomic)
                entries = AutoEQ.parseIndex(text)
            } catch {
                // An old cache beats nothing.
                if let text = try? String(contentsOf: cache, encoding: .utf8) { entries = AutoEQ.parseIndex(text) }
                if entries.isEmpty { lastError = "The headphone list couldn't be downloaded. Check your internet connection and try again." }
            }
        }
    }

    func retry() {
        entries = []
        load()
    }

    /// Downloads a model's correction and turns it on for a device.
    func apply(_ entry: AutoEQ.Entry, to deviceUID: String) async throws {
        guard let url = entry.parametricURL else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "AudioLens", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The correction for \(entry.name) couldn't be downloaded."])
        }
        let correction = try AutoEQ.parseParametric(text, name: entry.name, source: entry.source)
        SettingsStore.shared.updateDevice(deviceUID) { $0.correction = correction }
    }

    /// Lets the user pick a ParametricEQ.txt file for a device.
    func importFile(for deviceUID: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a parametric EQ file (EqualizerAPO or AutoEQ ParametricEQ.txt)."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ParametricEQ", with: "")
            let correction = try AutoEQ.parseParametric(text, name: name, source: "Imported file")
            SettingsStore.shared.updateDevice(deviceUID) { $0.correction = correction }
        } catch {
            let alert = NSAlert()
            alert.messageText = "That file couldn't be used"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
