import AppKit
import SwiftUI

/// Step 4 of the incremental rebuild: all four columns (sidebar, branches, files, diff). The
/// branch-menu toolbar item stays pinned to the branches column's trailing edge (divider index
/// 1) — see `MainToolbarDelegate`. Cross-column arrow-key focus navigation (previously shared via
/// one `@FocusState` in the old `MainWindowView`) isn't wired back up yet — each pane is hosted in
/// its own `NSHostingController` now, so that'll need its own follow-up step.
final class MainSplitViewController: NSSplitViewController {
    private let appState: AppState
    /// The sidebar and branches columns' target default widths — applied once, in
    /// `viewDidAppear()`. A hosting controller's initial `view.frame` isn't used by
    /// `NSSplitViewController` as a sizing hint, so the only reliable way to set an initial width
    /// (as opposed to `minimumThickness`, which is just a floor) is to explicitly position the
    /// divider — and it has to happen after the window is actually on screen: doing this in
    /// `viewDidLayout()` fires too early, while the split view still has stale/zero geometry, so
    /// the computed position was wrong. Both dividers are pinned from fixed constants rather than
    /// one being derived from the other's *current* frame — reading `arrangedSubviews[0].frame`
    /// at this point isn't reliably settled yet (SwiftUI/AppKit layout timing), so a branches
    /// width computed as "sidebar's current width + 320" would silently drift whenever the
    /// sidebar's own default width came out different than expected.
    private var hasAppliedInitialLayout = false
    private let defaultSidebarWidth: CGFloat = 280
    private let defaultBranchesWidth: CGFloat = 320

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin

        let sidebarHost = NSHostingController(rootView: RepoListView(appState: appState))
        sidebarHost.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true

        let branchesHost = NSHostingController(rootView: BranchListView(appState: appState))
        branchesHost.sizingOptions = []
        let branchesItem = NSSplitViewItem(contentListWithViewController: branchesHost)
        branchesItem.minimumThickness = 240
        branchesItem.maximumThickness = 500

        let filesHost = NSHostingController(rootView: ChangedFilesView(appState: appState))
        filesHost.sizingOptions = []
        let filesItem = NSSplitViewItem(viewController: filesHost)
        filesItem.minimumThickness = 200
        filesItem.maximumThickness = 500

        let diffHost = NSHostingController(rootView: DiffPaneHost(appState: appState))
        diffHost.sizingOptions = []
        let diffItem = NSSplitViewItem(viewController: diffHost)
        diffItem.minimumThickness = 320

        addSplitViewItem(sidebarItem)
        addSplitViewItem(branchesItem)
        addSplitViewItem(filesItem)
        addSplitViewItem(diffItem)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasAppliedInitialLayout else { return }
        hasAppliedInitialLayout = true
        splitView.setPosition(defaultSidebarWidth, ofDividerAt: 0)
        splitView.setPosition(defaultSidebarWidth + defaultBranchesWidth, ofDividerAt: 1)
    }
}

/// `DiffView` still takes an externally-owned `FocusState<MainColumn?>.Binding` from the old
/// single-`NavigationSplitView` days (for its left-arrow-back-to-files handling) — this just gives
/// it a local one to satisfy that until cross-column focus is wired back up as its own step.
private struct DiffPaneHost: View {
    @Bindable var appState: AppState
    @FocusState private var focusedColumn: MainColumn?

    var body: some View {
        DiffView(appState: appState, focusedColumn: $focusedColumn)
    }
}
