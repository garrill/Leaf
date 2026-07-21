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
                    .focused($focusedColumn, equals: .diff)
                    .onKeyPress(.leftArrow) { moveFocus(by: -1) }
            }
            .frame(minWidth: branchColumnWidth + filesColumnWidth + diffMinWidth, minHeight: 500)
        }
        .navigationSplitViewStyle(.balanced)
        .background(WindowAccessor())
        .toolbar {
            if appState.isSyncing {
                ToolbarItem(placement: .primaryAction) {
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appState.fetchRemote()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .help("Fetch")
                    .disabled(appState.selectedRepoURL == nil)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.pullCurrentBranch()
                } label: {
                    Image(systemName: "arrow.down")
                        .overlay(alignment: .topTrailing) {
                            syncBadge(isVisible: appState.behindCount > 0)
                        }
                }
                .help("Pull")
                .disabled(appState.selectedRepoURL == nil || !appState.hasUpstream || appState.isSyncing)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.pushCurrentBranch()
                } label: {
                    Image(systemName: "arrow.up")
                        .overlay(alignment: .topTrailing) {
                            syncBadge(isVisible: appState.aheadCount > 0)
                        }
                }
                .help("Push")
                .disabled(appState.selectedRepoURL == nil || appState.selectedBranch == nil || appState.isSyncing)
            }
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
