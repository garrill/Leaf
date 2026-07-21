import AppKit
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .tag(file)
                .listRowSeparator(.visible)
                .contextMenu {
                    contextMenuItems(for: file)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .controlBackgroundColor))
            .environment(\.controlActiveState, .key)
            .opacity(showsList ? 1 : 0)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .safeAreaBar(edge: .top, spacing: 0) { header }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if isWorkingChanges && !appState.changedFiles.isEmpty {
                    commitFooter
                }
            }

            if appState.selectedRepoURL == nil {
                // Blank — column 2 already communicates "no repository selected".
            } else if appState.selectedSource == nil {
                ContentUnavailableView("Select Uncommitted Changes or a Commit", systemImage: "sidebar.left")
            } else if appState.changedFiles.isEmpty {
                Text("No Changes")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            Text(headerTitle)
                .font(.headline)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: MainWindowView.columnHeaderHeight)
    }

    private var headerTitle: String {
        switch appState.selectedSource {
        case .none: return ""
        case .workingChanges: return "Uncommitted Changes"
        case .commit(let commit): return commit.summary
        }
    }

    @ViewBuilder
    private func contextMenuItems(for file: ChangedFile) -> some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([fullURL(for: file)])
        }
        Button("Open in Default Program") {
            NSWorkspace.shared.open(fullURL(for: file))
        }
        Divider()
        Button("Copy File Path") {
            copyToPasteboard(fullURL(for: file).path)
        }
        Button("Copy Relative Path") {
            copyToPasteboard(file.path)
        }
        if isWorkingChanges {
            Divider()
            Button("Discard Changes", role: .destructive) {
                appState.discardChanges(for: file)
            }
            Button("Ignore File") {
                appState.ignoreFile(file)
            }
        }
    }

    private func fullURL(for file: ChangedFile) -> URL {
        guard let repoURL = appState.selectedRepoURL else {
            return URL(fileURLWithPath: file.path)
        }
        return repoURL.appendingPathComponent(file.path)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
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
            // Same List(selection:) deselect-then-select quirk as BranchListView's source list —
            // ignore the transient nil so the diff view never flashes empty between files.
            set: { newValue in
                if let newValue {
                    appState.selectFile(newValue)
                }
            }
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
