import AppKit

/// Creates and owns the app's single AppKit-managed window. `LeafApp`'s `Scene` is an empty
/// `Settings` scene (no `WindowGroup`) — see its comment for why.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        resetStateIfRequestedForUITesting()

        let controller = MainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// UI tests launch with `-uiTestReset` so every run starts from a clean, repo-less sidebar
    /// instead of whatever state a previous run (or the developer's own usage) left in
    /// `UserDefaults` — otherwise assertions on the empty state / a freshly-added repo would be
    /// order-dependent and machine-dependent.
    private func resetStateIfRequestedForUITesting() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestReset") else { return }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
    }
}
