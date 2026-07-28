import AppKit
import SwiftUI

/// Owns the app's single window and its `AppState`. Built by hand in AppKit (rather than a
/// SwiftUI `WindowGroup`) so a toolbar item can eventually be pinned to the trailing edge of an
/// interior column via `NSTrackingSeparatorToolbarItem` — see `MainToolbarDelegate` and
/// `MainSplitViewController`.
final class MainWindowController: NSWindowController {
    let appState = AppState()
    private let toolbarDelegate: MainToolbarDelegate

    init() {
        let splitViewController = MainSplitViewController(appState: appState)
        let delegate = MainToolbarDelegate(appState: appState)
        toolbarDelegate = delegate

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1520, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = splitViewController
        window.title = "Current"
        window.minSize = NSSize(width: 900, height: 500)
        window.toolbarStyle = .unified

        // Must be set before the toolbar is attached to the window: assigning `window.toolbar`
        // synchronously asks the delegate for every default item, including tracking separators,
        // which need a live `splitView` to bind to.
        delegate.splitViewController = splitViewController
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        // Assigning `contentViewController` above (and then the toolbar) makes AppKit re-derive
        // the window's size from the split view's Auto Layout constraints — before
        // `MainSplitViewController.viewDidAppear()` has positioned its dividers, that collapses to
        // the sum of every column's `minimumThickness`, silently discarding the 1520×900
        // `contentRect` the window was constructed with. Re-asserting the size (and re-centering,
        // since centering earlier would've centered the since-discarded size) after both are set
        // is what actually makes the requested size stick.
        window.setContentSize(NSSize(width: 1520, height: 900))
        window.center()

        super.init(window: window)

        observeTitle()
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The window's native title is left visible and bound to the selected repo — AppKit's own
    /// unified-toolbar layout places it in the leading free space right after the sidebar's
    /// tracking separator, which lands it at the top-left of column 2, right next to the branch
    /// menu pinned at that column's trailing edge. `.navigationTitle` no longer applies now the
    /// window isn't SwiftUI-managed, so this is tracked by hand: the standard
    /// `withObservationTracking` pattern for `@Observable`, re-armed on every change.
    private func observeTitle() {
        withObservationTracking {
            _ = appState.selectedRepoURL
            _ = appState.repoOwner
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateTitle()
                self?.observeTitle()
            }
        }
    }

    private func updateTitle() {
        guard let url = appState.selectedRepoURL else {
            window?.title = "Current"
            window?.subtitle = ""
            return
        }
        window?.title = appState.sidebarStore.repos.first(where: { $0.url == url })?.displayName ?? url.lastPathComponent
        window?.subtitle = appState.repoOwner ?? ""
    }
}
