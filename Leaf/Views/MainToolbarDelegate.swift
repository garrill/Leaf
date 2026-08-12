import AppKit
import SwiftUI

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
            // No `.fixedSize()` on the SwiftUI content (see `BranchMenuToolbarView`) plus an
            // explicit compressible `minSize`/`maxSize` here: without this, the item always
            // claims its full natural width, so when it doesn't fit in the branches column's
            // tracking-separator-bound region it has to pop out of that region entirely (no way
            // for NSToolbar to shrink a fixed-size view) — it "detaches" from the divider far
            // earlier than necessary. Letting it truncate its text in place instead keeps it
            // pinned at much narrower column widths, the same way the native window title
            // truncates rather than disappearing.
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Branch"
            item.view = hostingView(BranchMenuToolbarView(appState: appState))
            return item

        case .fetchButton:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Fetch"
            item.view = hostingView(FetchToolbarView(appState: appState))
            return item

        case .pullPushGroup:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Pull/Push"
            item.view = hostingView(PullPushToolbarView(appState: appState))
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

    /// Unlike the split view's pane-hosting controllers (where `sizingOptions = []` is needed to
    /// stop SwiftUI's intrinsic size from fighting Auto Layout), a toolbar item's custom view
    /// needs the opposite: it must size itself to fit its SwiftUI content, or it collapses down
    /// to a near-zero default frame — leaving the default `sizingOptions` in place does that.
    private func hostingView<V: View>(_ view: V) -> NSHostingView<V> {
        NSHostingView(rootView: view)
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

/// The branch-selector dropdown pinned to the branches column's trailing edge (see
/// `MainToolbarDelegate`).
private struct BranchMenuToolbarView: View {
    @Bindable var appState: AppState

    var body: some View {
        Menu {
            Button("New Branch…") { appState.isNewBranchSheetPresented = true }
                .disabled(appState.selectedRepoURL == nil)

            Divider()

            ForEach(appState.branches) { branch in
                if branch.isCurrent {
                    Label(branch.name, systemImage: "checkmark")
                } else {
                    Menu(branch.name) {
                        Button("Checkout") { appState.selectBranch(branch) }
                        Button("Merge into \(branchLabelText)") { appState.mergeBranch(branch) }
                            .disabled(appState.isSyncing || appState.isMergeInProgress)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.trianglehead.branch")
                Text(branchLabelText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .fontWeight(.semibold)
            }

        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .disabled(appState.branches.isEmpty)
    }

    private var branchLabelText: String {
        if appState.isDetachedHead {
            return "Detached (\(appState.detachedHeadShortSHA ?? "HEAD"))"
        }
        return appState.selectedBranch?.name ?? "Branch"
    }
}

private struct FetchToolbarView: View {
    @Bindable var appState: AppState

    var body: some View {
        Group {
            if appState.isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    appState.fetchRemote()
                } label: {
                    Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.glass)
                .help("Fetch")
                .disabled(appState.selectedRepoURL == nil)
            }
        }
        .frame(width: 36, height: 36)
    }
}

/// `ControlGroup`'s merged-pill look was an artifact of SwiftUI's own toolbar-building pipeline —
/// hosted standalone in an `NSHostingView`, it renders as two separate round buttons instead.
/// `.buttonStyle(.glass)` has the same problem: applied to the `HStack` it still propagates down
/// to each `Button` individually, so each draws its own capsule rather than the pair sharing one.
/// The single shared pill is built by hand instead: plain (chromeless) buttons inside, with one
/// capsule background behind the whole `HStack`.
private struct PullPushToolbarView: View {
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            Button {
                appState.pullCurrentBranch()
            } label: {
                Image(systemName: "arrow.down")
                    .frame(width: 28, height: 28)
                    .overlay(alignment: .topTrailing) {
                        syncBadge(isVisible: appState.behindCount > 0)
                    }
            }
            .help("Pull")
            .disabled(appState.selectedRepoURL == nil ||
                      !appState.hasUpstream ||
                      appState.isSyncing)

            Button {
                appState.pushCurrentBranch()
            } label: {
                Image(systemName: "arrow.up")
                    .frame(width: 28, height: 28)
                    .overlay(alignment: .topTrailing) {
                        syncBadge(isVisible: appState.aheadCount > 0)
                    }
            }
            .help("Push")
            .disabled(appState.selectedRepoURL == nil ||
                      appState.selectedBranch == nil ||
                      appState.isSyncing)
        }
    }

    private func syncBadge(isVisible: Bool) -> some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .offset(x: 2, y: -2)
            .opacity(isVisible ? 1 : 0)
            .animation(.default, value: isVisible)
    }
}
