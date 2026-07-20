import SwiftUI

struct ChangedFilesView: View {
    @Bindable var appState: AppState

    var body: some View {
        ZStack {
            List(appState.changedFiles, selection: fileSelection) { file in
                HStack {
                    Text(statusSymbol(for: file.status))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(statusColor(for: file.status))
                        .frame(width: 16)
                    Text((file.path as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
