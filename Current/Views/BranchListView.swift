import SwiftUI

struct BranchListView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: branchSelection) {
                ForEach(appState.branches) { branch in
                    Text(branch.name).tag(Optional(branch))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .padding(8)
            .disabled(appState.branches.isEmpty)

            Divider()

            ZStack {
                List(selection: sourceSelection) {
                    Label("Uncommitted Changes", systemImage: "pencil.circle")
                        .tag(ChangeSource.workingChanges)

                    Section("History") {
                        ForEach(appState.commits) { commit in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(commit.summary)
                                    .lineLimit(1)
                                Text("\(commit.shortSha) · \(commit.date)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(ChangeSource.commit(commit))
                        }
                    }
                }
                .listStyle(.sidebar)
                .opacity(appState.selectedRepoURL == nil ? 0 : 1)

                if appState.selectedRepoURL == nil {
                    ContentUnavailableView("No Repo Selected", systemImage: "folder")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var branchSelection: Binding<GitBranch?> {
        Binding(
            get: { appState.selectedBranch },
            set: { newValue in
                if let newValue {
                    appState.selectBranch(newValue)
                }
            }
        )
    }

    private var sourceSelection: Binding<ChangeSource?> {
        Binding(
            get: { appState.selectedSource },
            set: { appState.selectSource($0) }
        )
    }
}
