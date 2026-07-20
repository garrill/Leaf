import SwiftUI

struct ChangedFilesView: View {
    @Bindable var appState: AppState

    var body: some View {
        ZStack {
            List(appState.changedFiles, selection: fileSelection) { file in
                HStack {
                    if isWorkingChanges {
                        Toggle("", isOn: checkedBinding(for: file))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                    }
                    Text((file.path as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(statusSymbol(for: file.status))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(statusColor(for: file.status))
                        .frame(width: 16)
                }
                .tag(file)
            }
            .listStyle(.sidebar)
            .opacity(showsList ? 1 : 0)

            if appState.selectedRepoURL == nil {
                ContentUnavailableView("No Repo Selected", systemImage: "folder")
            } else if appState.selectedSource == nil {
                ContentUnavailableView("Select Uncommitted Changes or a Commit", systemImage: "sidebar.left")
            } else if appState.changedFiles.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "checkmark.circle")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            if isWorkingChanges && !appState.changedFiles.isEmpty {
                commitFooter
            }
        }
    }

    private var commitFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            TextField("Commit message", text: $appState.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))

            Button {
                appState.commitCheckedChanges()
            } label: {
                Text(commitButtonTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(!canCommit)
        }
        .padding(10)
    }

    private var checkedCount: Int {
        appState.checkedFilePaths.count
    }

    private var canCommit: Bool {
        checkedCount > 0 && !appState.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var commitButtonTitle: String {
        let branchName = appState.selectedBranch?.name ?? "…"
        return "Commit \(checkedCount) file\(checkedCount == 1 ? "" : "s") to \(branchName)"
    }

    private var isWorkingChanges: Bool {
        appState.selectedSource == .workingChanges
    }

    private var showsList: Bool {
        appState.selectedRepoURL != nil && appState.selectedSource != nil && !appState.changedFiles.isEmpty
    }

    private var fileSelection: Binding<ChangedFile?> {
        Binding(
            get: { appState.selectedFile },
            set: { appState.selectFile($0) }
        )
    }

    private func checkedBinding(for file: ChangedFile) -> Binding<Bool> {
        Binding(
            get: { appState.checkedFilePaths.contains(file.path) },
            set: { appState.setChecked($0, for: file.path) }
        )
    }

    private func statusSymbol(for status: FileChangeStatus) -> String {
        switch status {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        case .unknown: return "?"
        }
    }

    private func statusColor(for status: FileChangeStatus) -> Color {
        switch status {
        case .modified: return .yellow
        case .added, .untracked: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .unknown: return .secondary
        }
    }
}
