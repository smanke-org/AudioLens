import AVKit
import SwiftUI

/// Apple's AirPlay picker: lists HomePods, Apple TVs and other AirPlay speakers on the network,
/// and connecting one makes it the Mac's output. macOS offers no public way to list AirPlay
/// speakers before one is chosen (they only become audio devices once connected), so this
/// is the route that keeps working across macOS updates.
struct AirPlayButton: NSViewRepresentable {
    /// Set by the view to a closure that opens the picker, for a "Connect" button elsewhere.
    var opener: ((@escaping () -> Void) -> Void)?

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(.secondaryLabelColor, for: .normal)
        picker.toolTip = "AirPlay speakers"
        opener?({ [weak picker] in picker.map(AirPlayButton.open) })
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context: Context) {}

    /// Clicks the picker's own button, which shows the speaker list under it.
    static func open(_ picker: AVRoutePickerView) {
        func button(in view: NSView) -> NSButton? {
            if let b = view as? NSButton { return b }
            for sub in view.subviews { if let b = button(in: sub) { return b } }
            return nil
        }
        button(in: picker)?.performClick(nil)
    }
}

/// The AirPlay icon, sized for a toolbar row.
struct AirPlayIcon: View {
    var body: some View {
        AirPlayButton()
            .frame(width: 24, height: 22)
            .help("AirPlay: connect a HomePod, Apple TV or other AirPlay speaker")
            .accessibilityLabel("AirPlay speakers")
    }
}

/// "Connect…" for an AirPlay speaker AudioLens remembers but that isn't connected: opens the
/// AirPlay picker, where the speaker is chosen.
struct AirPlayConnectButton: View {
    @State private var open: (() -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            Button("Connect…") { open?() }
                .controlSize(.small)
                .help("Opens the AirPlay list; choose the speaker there")
            AirPlayButton(opener: { action in DispatchQueue.main.async { open = action } })
                .frame(width: 22, height: 20)
        }
    }
}
