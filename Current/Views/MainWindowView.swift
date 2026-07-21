import SwiftUI

enum MainColumn: Int, CaseIterable {
    case repos, branches, files, diff
}

struct MainWindowView: View {
    /// Shared height for the top bar of the branch, files, and diff columns, so they align.
    static let columnHeaderHeight: CGFloat = 37

    @State private var appState = AppState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @State private var branchColumnWidth: CGFloat = 220
    @State private var filesColumnWidth: CGFloat = 260

    @FocusState private var focusedColumn: MainColumn?

    private let branchColumnRange: ClosedRange<CGFloat> = 160...400
    private let filesColumnRange: ClosedRange<CGFloat> = 160...500
    private let diffMinWidth: CGFloat = 320

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            RepoListView(appState: appState)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 400)
                .focused($focusedColumn, equals: .repos)
                .onKeyPress(.rightArrow) { moveFocus(by: 1) }
        } detail: {
            HStack(spacing: 0) {
                BranchListView(appState: appState)
                    .frame(width: branchColumnWidth)
                    .focused($focusedColumn, equals: .branches)
                    .onKeyPress(.leftArrow) { moveFocus(by: -1) }
                    .onKeyPress(.rightArrow) { moveFocus(by: 1) }

                ResizableDivider(width: $branchColumnWidth, minWidth: branchColumnRange.lowerBound, maxWidth: branchColumnRange.upperBound)

                ChangedFilesView(appState: appState)
                    .frame(width: filesColumnWidth)
                    .focused($focusedColumn, equals: .files)
                    .onKeyPress(.leftArrow) { moveFocus(by: -1) }
                    .onKeyPress(.rightArrow) { moveFocus(by: 1) }

                ResizableDivider(width: $filesColumnWidth, minWidth: filesColumnRange.lowerBound, maxWidth: filesColumnRange.upperBound)

                DiffView(appState: appState)
                    .frame(minWidth: diffMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focusedColumn, equals: .diff)
                    .onKeyPress(.leftArrow) { moveFocus(by: -1) }
            }
            .frame(minWidth: branchColumnWidth + filesColumnWidth + diffMinWidth, minHeight: 500)
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
                ToolbarItem(placement: .navigation){
                    branchMenu
                }
                
            }


            // One flexible-width group filling the space after the native window title: the
            // branch dropdown at its leading edge (so it lands immediately after the title, as
            // far left as the toolbar allows) and a `Spacer()` pushing the sync buttons to the
            // trailing edge — `.navigation`-placed items always render after AppKit's own
            // title with no supported way to reorder that, so this is the only way to get the
            // dropdown to sit beside the title instead of at the toolbar's far right.
            ToolbarItem(placement: .primaryAction) {
                
                HStack {
                    

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
                    .disabled(appState.selectedRepoURL == nil || !appState.hasUpstream || appState.isSyncing)

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
                    .disabled(appState.selectedRepoURL == nil || appState.selectedBranch == nil || appState.isSyncing)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var branchMenu: some View {
        Menu {
            ForEach(appState.branches) { branch in
                Button(branch.name) { appState.selectBranch(branch) }
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
        let current = focusedColumn?.rawValue ?? MainColumn.repos.rawValue
        guard let next = MainColumn(rawValue: current + offset) else { return .ignored }
        focusedColumn = next
        return .handled
    }
}

#Preview {
    MainWindowView()
}
