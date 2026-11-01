import Foundation

/// Tells ToolHUD which of this app's ToolHUD actions are on right now, so its buttons can
/// light up while "Show which features are on" is turned on in ToolHUD.
///
/// The keys are the action ids this app answers (`clicklens://spotlight` → "spotlight"),
/// and only on/off actions belong here. ToolHUD asks with a distributed notification when
/// its HUD opens; the app answers with every state, and posts again by itself whenever one
/// changes. Nothing is sent if nobody asked and nothing changed, and an app that never
/// adopts this simply shows no lights.
///
/// The same file is copied into every app that has on/off actions (the master copy is in
/// ToolHUD/Shared/).
@MainActor
enum ToolHUDFeatureStates {
    static let changed = Notification.Name("com.smanke.ToolHUD.featureStates")
    static let request = Notification.Name("com.smanke.ToolHUD.featureStatesRequest")

    private static var provider: (@MainActor () -> [String: Bool])?
    private static var observer: NSObjectProtocol?
    private static var last: [String: Bool]?

    /// Starts answering ToolHUD. `states` reports every on/off action's current state.
    static func start(_ states: @escaping @MainActor () -> [String: Bool]) {
        provider = states
        if observer == nil {
            observer = DistributedNotificationCenter.default().addObserver(forName: request, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ToolHUDFeatureStates.publish(force: true) }
            }
        }
        publish(force: true)
    }

    /// Call whenever one of the features turns on or off. Repeats of the same states are
    /// skipped unless `force`.
    static func publish(force: Bool = false) {
        guard let provider, let id = Bundle.main.bundleIdentifier else { return }
        let states = provider()
        guard force || states != last else { return }
        last = states
        DistributedNotificationCenter.default().postNotificationName(changed, object: id, userInfo: ["states": states],
                                                                     deliverImmediately: true)
    }
}
