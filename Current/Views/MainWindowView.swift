import SwiftUI

struct MainWindowView: View {
    @State private var appState = AppState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @State private var branchColumnWidth: CGFloat = 220
    @State private var filesColumnWidth: CGFloat = 260

    private let branchColumnRange: ClosedRange<CGFloat> = 160...400
    private let filesColumnRange: ClosedRange<CGFloat> = 160...500
    private let diffMinWidth: CGFloat = 320

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            RepoListView(appState: appState)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 400)
        } detail: {
            HStack(spacing: 0) {
                BranchListView(appState: appState)
                    .frame(width: branchColumnWidth)

                ResizableDivider(width: $branchColumnWidth, minWidth: branchColumnRange.lowerBound, maxWidth: branchColumnRange.upperBound)

                ChangedFilesView(appState: appState)
                    .frame(width: filesColumnWidth)

                ResizableDivider(width: $filesColumnWidth, minWidth: filesColumnRange.lowerBound, maxWidth: filesColumnRange.upperBound)

                DiffView(appState: appState)
                    .frame(minWidth: diffMinWidth, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: branchColumnWidth + filesColumnWidth + diffMinWidth, minHeight: 500)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

#Preview {
    MainWindowView()
}
