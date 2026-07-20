import SwiftUI

struct BranchListView: View {
    @Bindable var appState: AppState

    var body: some View {
        Group {
            if appState.selectedRepoURL == nil {
                ContentUnavailableView("No Repo Selected", systemImage: "folder")
            } else if appState.branches.isEmpty {
                ContentUnavailableView("No Branches", systemImage: "arrow.triangle.branch")
            } else {
                List(appState.branches, selection: branchSelection) { branch in
                    Label(branch.name, systemImage: branch.isCurrent ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(branch.isCurrent ? Color.accentColor : .primary)
                        .tag(branch)
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 160, idealWidth: 180)
    }

    private var branchSelection: Binding<GitBranch?> {
        Binding(
            get: { appState.selectedBranch },
            set: { appState.selectedBranch = $0 }
        )
    }
}
