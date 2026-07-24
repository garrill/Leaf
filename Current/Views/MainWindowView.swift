import AppKit
import SwiftUI

enum MainColumn: Int, CaseIterable {
    case repos, branches, files, diff
}

struct MainWindowView: View {
    /// Shared height for the top bar of the branch, files, and diff columns, so they align.
    static let columnHeaderHeight: CGFloat = 37

    @State private var appState = AppState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @FocusState private var focusedColumn: MainColumn?

    private let diffMinWidth: CGFloat = 320

    var body: some View {
        // A real three-column split view (Mail's shape: sidebar | list | detail), so the
        // sidebar and branch/history columns resize with native dividers and the system
        // partitions the toolbar with tracking separators. Only the files|diff divider
        // inside `detail` is an extra split (`HSplitView`) — NavigationSplitView tops out
        // at three columns.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            RepoListView(appState: appState)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 400)
                .focused($focusedColumn, equals: .repos)
                .onKeyPress(.rightArrow) { moveFocus(by: 1) }
        } content: {
            BranchListView(appState: appState)
                .navigationSplitViewColumnWidth(min: 160, ideal: 260, max: 400)
                .focused($focusedColumn, equals: .branches)
                .onKeyPress(.leftArrow) { moveFocus(by: -1) }
                .onKeyPress(.rightArrow) { moveFocus(by: 1) }
        } detail: {
            HSplitView {
                ChangedFilesView(appState: appState)
                    .frame(minWidth: 160, idealWidth: 300, maxWidth: 500)
                    .focused($focusedColumn, equals: .files)
                    .onKeyPress(.leftArrow) { moveFocus(by: -1) }
                    .onKeyPress(.rightArrow) { moveFocus(by: 1) }

                DiffView(appState: appState, focusedColumn: $focusedColumn)
                    .frame(minWidth: diffMinWidth, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 160 + diffMinWidth, minHeight: 500)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(windowTitle)
        .background(WindowAccessor())
        .onKeyPress(.escape) {
            appState.deselectRepo()
            return .handled
        }
        .toolbar {

            if appState.selectedRepoURL != nil {
                ToolbarItem(placement: .navigation) {
                    branchMenu
                }
            }

            // Fetch, Pull, and Push all live in `.primaryAction` (the toolbar's trailing group)
            // so they sit together on the right. Adjacent `.primaryAction` items with the
            // default Liquid Glass style still automatically share one capsule background —
            // `ToolbarSpacer` doesn't prevent that on macOS — so Pull and Push are wrapped in
            // a `ControlGroup` inside a single `ToolbarItem`, which renders as one pill by
            // design, while Fetch sits in its own separate `ToolbarItem` right next to it with
            // its own capsule. (`.principal` was tried first but centers the item in the
            // toolbar instead of anchoring it to the trailing edge.)
            ToolbarItem(placement: .primaryAction) {
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
                        .help("Fetch")
                        .disabled(appState.selectedRepoURL == nil)
                    }
                }
                .frame(width: 36, height: 36)
            }

            ToolbarItem(placement: .primaryAction) {
                ControlGroup {
                    Button {
                        appState.pullCurrentBranch()
                    } label: {
                        Label {
                            Text("Pull")
                        } icon: {
                            Image(systemName: "arrow.down")
                                .overlay(alignment: .topTrailing) {
                                    syncBadge(isVisible: appState.behindCount > 0)
                                }
                        }
                    }
                    .help("Pull")
                    .disabled(appState.selectedRepoURL == nil ||
                              !appState.hasUpstream ||
                              appState.isSyncing)

                    Button {
                        appState.pushCurrentBranch()
                    } label: {
                        Label {
                            Text("Push")
                        } icon: {
                            Image(systemName: "arrow.up")
                                .overlay(alignment: .topTrailing) {
                                    syncBadge(isVisible: appState.aheadCount > 0)
                                }
                        }
                    }
                    .help("Push")
                    .disabled(appState.selectedRepoURL == nil ||
                              appState.selectedBranch == nil ||
                              appState.isSyncing)
                }
            }
        }
    }

    private var branchMenu: some View {
        Menu {
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
                    .truncationTooltip(branchLabelText)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .fixedSize()
        .disabled(appState.branches.isEmpty)
    }

    private var branchLabelText: String {
        if appState.isDetachedHead {
            return "Detached (\(appState.detachedHeadShortSHA ?? "HEAD"))"
        }
        return appState.selectedBranch?.name ?? "Branch"
    }

    private var windowTitle: String {
        guard let url = appState.selectedRepoURL else { return "Current" }
        return appState.sidebarStore.repos.first(where: { $0.url == url })?.displayName ?? url.lastPathComponent
    }

    private func syncBadge(isVisible: Bool) -> some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .offset(x: 2, y: -2)
            .opacity(isVisible ? 1 : 0)
            .animation(.default, value: isVisible)
    }

    private func moveFocus(by offset: Int) -> KeyPress.Result {
        // Let arrow keys move the cursor normally while editing text (e.g. renaming a sidebar
        // item) instead of hijacking them to switch columns.
        if NSApp.keyWindow?.firstResponder is NSTextView { return .ignored }
        let current = focusedColumn?.rawValue ?? MainColumn.repos.rawValue
        guard let next = MainColumn(rawValue: current + offset) else { return .ignored }
        focusedColumn = next
        return .handled
    }
}

#Preview {
    MainWindowView()
}
