import AppKit
import Observation

private extension NSToolbarItem.Identifier {
    static let addItem = NSToolbarItem.Identifier("addItem")
    static let sidebarTrackingSeparator = NSToolbarItem.Identifier("sidebarTrackingSeparator")
    static let branchMenu = NSToolbarItem.Identifier("branchMenu")
    static let branchTrackingSeparator = NSToolbarItem.Identifier("branchTrackingSeparator")
    static let fetchButton = NSToolbarItem.Identifier("fetchButton")
    static let pullPushGroup = NSToolbarItem.Identifier("pullPushGroup")
}

/// Builds the window's `NSToolbar`. Step 2: the branch-selector menu is pinned to the trailing
/// edge of the branches column via an `NSTrackingSeparatorToolbarItem` bound to divider index 1
/// (branches | files) — its x-position is kept in sync with the live divider position by AppKit
/// as the window/columns resize, and the ordinary `branchMenu` item placed immediately before it
/// in `toolbarDefaultItemIdentifiers` rides along with it. This is the Mail.app/Notes.app
/// "column-aligned toolbar item" pattern (see the reference project's `listTrailingButton`), and
/// the reason the window is AppKit-owned instead of a `WindowGroup`.
final class MainToolbarDelegate: NSObject, NSToolbarDelegate {
    weak var splitViewController: NSSplitViewController?
    private let appState: AppState
    private weak var branchItem: NSMenuToolbarItem?
    private weak var fetchButton: NSButton?
    private weak var fetchSpinner: NSProgressIndicator?
    private var fetchSizeConstraints: [NSLayoutConstraint] = []
    private weak var pullPushControl: NSSegmentedControl?

    init(appState: AppState) {
        self.appState = appState
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let splitView = splitViewController?.splitView else { return nil }

        switch itemIdentifier {
        case .addItem:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Add"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
            item.showsIndicator = true
            item.menu = makeAddMenu()
            return item

        case .toggleSidebar:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Toggle Sidebar"
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
            item.target = nil
            item.action = #selector(NSSplitViewController.toggleSidebar(_:))
            return item

        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: itemIdentifier, splitView: splitView, dividerIndex: 0)

        case .branchTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: itemIdentifier, splitView: splitView, dividerIndex: 1)

        case .branchMenu:
            // Native `NSMenuToolbarItem` (same as Add) for the system button chrome/hover. The
            // menu itself is rebuilt from `AppState` each time it opens (`menuNeedsUpdate`), and
            // the title/enabled state are pushed in `updateToolbarItems()`.
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Branch"
            item.image = NSImage(systemSymbolName: "arrow.trianglehead.branch", accessibilityDescription: "Branch")
            item.showsIndicator = true
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            item.menu = menu
            branchItem = item
            observeToolbarState()
            return item

        case .fetchButton:
            // One permanent toolbar-bezel `NSButton` with a spinner laid over it. Swapping the
            // item's `view` for a spinner mid-sync made the toolbar re-measure the item (it went
            // narrow), and clearing `view` back to nil afterwards didn't restore the native image
            // rendering. Here, when a sync starts, the button's current on-screen size is pinned and
            // the icon hidden (`imagePosition = .noImage`) so the spinner shows in its place; both
            // are undone when it ends (see `updateToolbarItems()`). The size has to be read live —
            // `intrinsicContentSize` at creation is smaller than the toolbar ends up rendering
            // it — and tinting the icon `.clear` instead doesn't work, the toolbar's glass
            // rendering ignores `contentTintColor`.
            let button = NSButton(
                image: NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Fetch")!,
                target: self,
                action: #selector(fetch)
            )
            button.bezelStyle = .toolbar
            button.toolTip = "Fetch"
            // Otherwise AppKit's default "Button" title shows once the image is hidden.
            button.title = ""

            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])

            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Fetch"
            item.view = button
            fetchButton = button
            fetchSpinner = spinner
            observeToolbarState()
            return item

        case .pullPushGroup:
            // A momentary `NSSegmentedControl` is what draws the joined pill *with* a hairline
            // divider that disappears while either half shows its hover highlight (Xcode's
            // Run/Stop). A plain group of image subitems only shares the glass pill — no divider.
            // The control is built here rather than via `NSToolbarItemGroup`'s convenience
            // constructor because that keeps its control internal (`view` stays nil), leaving
            // nothing to attach the ahead/behind dots to (see `syncDots(on:)`).
            let images = zip(Self.pullPushSymbols, Self.pullPushLabels).map {
                NSImage(systemSymbolName: $0, accessibilityDescription: $1)!
            }
            let control = NSSegmentedControl(
                images: images,
                trackingMode: .momentary,
                target: self,
                action: #selector(pullOrPush(_:))
            )
            for (index, label) in Self.pullPushLabels.enumerated() {
                control.setToolTip(label, forSegment: index)
            }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Pull / Push"
            item.view = control
            pullPushControl = control
            observeToolbarState()
            return item

        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            .addItem,
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            .branchMenu,
            .branchTrackingSeparator,
            .flexibleSpace,
            .fetchButton,
            .space,
            .pullPushGroup
        ]
    }

    /// Native `NSMenu` for the Add toolbar item — using `NSMenuToolbarItem` (rather than a
    /// SwiftUI `Menu` hosted in a custom view) gets us the system's native button chrome for free:
    /// correct dimming when the window is inactive, native hover highlight, and a built-in chevron
    /// indicator, none of which a hosted SwiftUI `Menu`/`Button` reproduces exactly.
    private func makeAddMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Add Repository", action: #selector(addRepository), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Clone Repository…", action: #selector(cloneRepository), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Add Group", action: #selector(addGroup), keyEquivalent: "")
            .target = self
        return menu
    }

    /// Same `withObservationTracking` re-arm pattern as `MainWindowController.observeTitle()`.
    /// Called once per item the toolbar creates; each call arms its own tracking chain, which is
    /// harmless since every chain just reapplies the same state to whichever items exist.
    private func observeToolbarState() {
        withObservationTracking {
            updateToolbarItems()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.observeToolbarState()
            }
        }
    }

    private func updateToolbarItems() {
        if let branchItem {
            branchItem.title = branchTitle
            branchItem.isEnabled = !(appState.branches.isEmpty || appState.isRepositoryBusy)
        }

        let blocked = appState.selectedRepoURL == nil || appState.isSyncing || appState.isRepositoryBusy

        if let fetchButton, let fetchSpinner {
            fetchButton.isEnabled = !(appState.selectedRepoURL == nil || appState.isRepositoryBusy || appState.isSyncing)
            if appState.isSyncing {
                // Skipped if the button hasn't been laid out yet (a sync already running when the
                // toolbar is built) — pinning a zero frame would collapse it.
                let size = fetchButton.frame.size
                if fetchSizeConstraints.isEmpty, size.width > 0, size.height > 0 {
                    fetchSizeConstraints = [
                        fetchButton.widthAnchor.constraint(equalToConstant: size.width),
                        fetchButton.heightAnchor.constraint(equalToConstant: size.height)
                    ]
                    NSLayoutConstraint.activate(fetchSizeConstraints)
                }
                fetchButton.imagePosition = .noImage
                fetchSpinner.startAnimation(nil)
            } else {
                NSLayoutConstraint.deactivate(fetchSizeConstraints)
                fetchSizeConstraints = []
                fetchButton.imagePosition = .imageOnly
                fetchSpinner.stopAnimation(nil)
            }
        }

        if let pullPushControl {
            let enabled = [
                !blocked && appState.hasUpstream,
                !blocked && appState.selectedBranch != nil
            ]
            let badged = [appState.behindCount > 0, appState.aheadCount > 0]
            for (index, dot) in syncDots(on: pullPushControl).enumerated() {
                pullPushControl.setEnabled(enabled[index], forSegment: index)
                dot.isHidden = !badged[index]
                dot.alphaValue = enabled[index] ? 1 : 0.4
            }
        }
    }

    private static let pullPushSymbols = ["arrow.down", "arrow.up"]
    private static let pullPushLabels = ["Pull", "Push"]

    /// The ahead/behind dots for the Pull/Push segments. `NSItemBadge` isn't drawn on a segmented
    /// control's segments, and drawing the dot into the segment image doesn't work either — the
    /// control scales the image to fit, shrinking the arrow. So each dot is a small layer-backed
    /// subview of the control, pinned near its segment's symbol's top-trailing corner (each
    /// segment's centre sits at 1/4 and 3/4 of the control's width). Created once, then just
    /// shown/hidden.
    private var syncDotViews: [NSView] = []

    private func syncDots(on segmented: NSSegmentedControl) -> [NSView] {
        if !syncDotViews.isEmpty { return syncDotViews }
        let dotSize: CGFloat = 6
        syncDotViews = (0..<segmented.segmentCount).map { index in
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            dot.layer?.cornerRadius = dotSize / 2
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.isHidden = true
            segmented.addSubview(dot)
            let multiplier = CGFloat(2 * index + 1) / CGFloat(segmented.segmentCount)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: dotSize),
                dot.heightAnchor.constraint(equalToConstant: dotSize),
                NSLayoutConstraint(
                    item: dot, attribute: .centerX, relatedBy: .equal,
                    toItem: segmented, attribute: .centerX, multiplier: multiplier, constant: 9
                ),
                dot.centerYAnchor.constraint(equalTo: segmented.centerYAnchor, constant: -9)
            ])
            return dot
        }
        return syncDotViews
    }

    @objc private func fetch() {
        appState.fetchRemote()
    }

    @objc private func pullOrPush(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: appState.pullCurrentBranch()
        case 1: appState.pushCurrentBranch()
        default: break
        }
    }

    @objc private func addRepository() {
        appState.addRepoViaPicker()
    }

    @objc private func cloneRepository() {
        appState.isCloneSheetPresented = true
    }

    @objc private func addGroup() {
        let id = appState.sidebarStore.addFolder()
        appState.renamingFolderID = id
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
}

// MARK: - Branch menu

extension MainToolbarDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // The default branch (`origin/HEAD`) resolved against the local branch list gets its
        // own section; when it isn't known or has no local branch, every local branch just goes
        // in the main section.
        let defaultBranch = appState.defaultBranchName.flatMap { name in
            appState.branches.first { $0.name == name }
        }
        if let defaultBranch {
            menu.addItem(.sectionHeader(title: "Default Branch"))
            menu.addItem(branchMenuItem(defaultBranch))
            menu.addItem(.separator())
        }
        for branch in appState.branches where branch.name != defaultBranch?.name {
            menu.addItem(branchMenuItem(branch))
        }

        if !appState.remoteOnlyBranches.isEmpty {
            menu.addItem(.separator())
            let remotes = NSMenu()
            remotes.autoenablesItems = false
            for branch in appState.remoteOnlyBranches {
                remotes.addItem(menuItem(branch.name, action: #selector(checkoutRemoteBranch(_:)), object: branch))
            }
            let remotesItem = NSMenuItem(title: "Remote Branches", action: nil, keyEquivalent: "")
            remotesItem.submenu = remotes
            menu.addItem(remotesItem)
        }

        menu.addItem(.separator())
        let newBranch = menuItem("New Branch…", action: #selector(newBranch), symbol: "plus")
        newBranch.isEnabled = appState.selectedRepoURL != nil
        menu.addItem(newBranch)

        let prune = menuItem("Prune Deleted Branches…", action: #selector(pruneGoneBranches), symbol: "trash")
        prune.isEnabled = appState.selectedRepoURL != nil && !appState.isSyncing
        prune.toolTip = "Fetch from the remote, then delete local branches that no longer exist there"
        menu.addItem(prune)
    }

    /// One branch entry: a checkmarked item when it's the checked-out branch, otherwise a submenu
    /// with the checkout/merge/delete actions.
    private func branchMenuItem(_ branch: GitBranch) -> NSMenuItem {
        let item = NSMenuItem(title: branch.name, action: nil, keyEquivalent: "")
        if branch.isCurrent {
            item.state = .on
            return item
        }

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(menuItem("Checkout", action: #selector(checkoutBranch(_:)), object: branch))
        let merge = menuItem("Merge into \(currentBranchName)", action: #selector(mergeBranch(_:)), object: branch)
        merge.isEnabled = !appState.isSyncing && !appState.isMergeInProgress
        submenu.addItem(merge)
        submenu.addItem(.separator())
        submenu.addItem(menuItem("Delete", action: #selector(deleteBranch(_:)), object: branch))
        item.submenu = submenu
        return item
    }

    private func menuItem(_ title: String, action: Selector, object: Any? = nil, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    private var currentBranchName: String {
        if appState.isDetachedHead {
            return "Detached (\(appState.detachedHeadShortSHA ?? "HEAD"))"
        }
        return appState.selectedBranch?.name ?? "Branch"
    }

    fileprivate var branchTitle: String {
        guard appState.isSwitchingBranch else { return currentBranchName }
        guard let progress = appState.branchSwitchProgressText else { return "Switching\u{2026}" }
        return "Switching\u{2026} \(progress)"
    }

    @objc private func checkoutBranch(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? GitBranch else { return }
        appState.selectBranch(branch)
    }

    @objc private func mergeBranch(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? GitBranch else { return }
        appState.mergeBranch(branch)
    }

    @objc private func deleteBranch(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? GitBranch else { return }
        appState.deleteBranch(branch)
    }

    @objc private func checkoutRemoteBranch(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? GitRemoteBranch else { return }
        appState.checkoutRemoteBranch(branch)
    }

    @objc private func newBranch() {
        appState.isNewBranchSheetPresented = true
    }

    @objc private func pruneGoneBranches() {
        appState.pruneGoneBranches()
    }
}
