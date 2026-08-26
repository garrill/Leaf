import AppKit

/// Creates and owns the app's single AppKit-managed window. `LeafApp`'s `Scene` is an empty
/// `Settings` scene (no `WindowGroup`) — see its comment for why.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        resetStateIfRequestedForUITesting()
        _ = UpdaterHolder.shared

        showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock icon click when the window was closed (last-window-close no longer quits the app,
    /// see above) — with no visible windows, AppKit still has nothing to bring forward on its
    /// own, so build a fresh `MainWindowController` the same way launch does.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        showMainWindow()
        return true
    }

    /// Backs the File menu's "New Window" (⌘N) — same "no window to bring forward" gap as the
    /// Dock reopen handler above, since with the last-window-close quit disabled there can be a
    /// live app with zero windows for ⌘N to target.
    func showMainWindow() {
        if let window = mainWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = MainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// UI tests launch with `-uiTestReset` so every run starts from a clean, repo-less sidebar
    /// instead of whatever state a previous run left behind — otherwise assertions on the empty
    /// state / a freshly-added repo would be order-dependent and machine-dependent. This clears
    /// `LeafSettings.uiTestSuiteName` specifically, never `Bundle.main.bundleIdentifier` —
    /// Debug and Release builds share one bundle id (`garrill.Leaf`), so wiping that domain here
    /// would also wipe the sidebar/settings of whichever build of Leaf someone actually uses day
    /// to day, since there's no separate "test build" for UI tests to launch instead.
    private func resetStateIfRequestedForUITesting() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestReset") else { return }
        UserDefaults.standard.removePersistentDomain(forName: LeafSettings.uiTestSuiteName)
    }
}
