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
                    pathAndFileName(for: file)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .truncationTooltip(file.path)
                    Spacer()
                    if file.status == .conflicted {
                        Button("Mark Resolved") {
                            appState.markResolved(file)
                        }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                    } else {
                        Text(statusSymbol(for: file.status))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(statusColor(for: file.status))
                            .frame(width: 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tag(file.path)
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
            .safeAreaBar(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    header
                    if isWorkingChanges && appState.isMergeInProgress {
                        mergeBanner
                    }
                }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if isWorkingChanges && !appState.changedFiles.isEmpty {
                    CommitFooterView(appState: appState)
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
                .truncationTooltip(headerTitle)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: ColumnLayout.headerHeight)
    }

    private var headerTitle: String {
        switch appState.selectedSource {
        case .none: return ""
        case .workingChanges: return "Uncommitted Changes"
        case .commit(let commit): return commit.summary
        }
    }

    private var mergeConflictCount: Int {
        appState.changedFiles.count { $0.status == .conflicted }
    }

    private var mergeBanner: some View {
        HStack {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(.orange)
            Text(mergeConflictCount > 0 ? "Merging — \(mergeConflictCount) conflict\(mergeConflictCount == 1 ? "" : "s") remaining" : "Merging — ready to commit")
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Button("Abort", role: .destructive) {
                appState.abortMerge()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    /// The files a context-menu action should apply to: the full multi-selection if the
    /// right-clicked file is part of it, otherwise just the right-clicked file on its own
    /// (matching Finder's behavior for right-clicking outside the current selection).
    private func targetFiles(for file: ChangedFile) -> [ChangedFile] {
        guard appState.selectedFilePaths.contains(file.path), appState.selectedFilePaths.count > 1 else {
            return [file]
        }
        return appState.changedFiles.filter { appState.selectedFilePaths.contains($0.path) }
    }

    @ViewBuilder
    private func contextMenuItems(for file: ChangedFile) -> some View {
        let files = targetFiles(for: file)
        if files.count == 1 {
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
            if isWorkingChanges, file.status != .conflicted {
                Divider()
                Button("Discard Changes", role: .destructive) {
                    appState.discardChanges(for: file)
                }
                Button("Ignore File") {
                    appState.ignoreFile(file)
                }
            }
        } else {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(files.map(fullURL(for:)))
            }
            Divider()
            Button("Copy Relative Paths") {
                copyToPasteboard(files.map(\.path).joined(separator: "\n"))
            }
            if isWorkingChanges {
                let discardableFiles = files.filter { $0.status != .conflicted }
                if !discardableFiles.isEmpty {
                    Divider()
                    Button("Discard Changes in \(discardableFiles.count) Files", role: .destructive) {
                        appState.discardChanges(for: discardableFiles)
                    }
                    Button("Add \(discardableFiles.count) Files to .gitignore") {
                        appState.ignoreFiles(discardableFiles)
                    }
                }
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

    private var isWorkingChanges: Bool {
        appState.selectedSource == .workingChanges
    }

    private var showsList: Bool {
        appState.selectedRepoURL != nil && appState.selectedSource != nil && !appState.changedFiles.isEmpty
    }

    /// Backed by a `Set<String>` (file paths) rather than `Set<ChangedFile>` so native
    /// shift/cmd-click multi-selection works, tagging rows with `file.path` above.
    private var fileSelection: Binding<Set<String>> {
        Binding(
            get: { appState.selectedFilePaths },
            set: { newValue in appState.updateFileSelection(newValue) }
        )
    }

    /// Directory in secondary/grey, file name in primary color, on one line — matching
    /// `DiffView`'s header treatment, with `.truncationMode(.head)` so a long path truncates
    /// from the front and the file name (the most useful part) always stays visible.
    private func pathAndFileName(for file: ChangedFile) -> Text {
        let name = Text((file.path as NSString).lastPathComponent).foregroundColor(.primary)
        let directory = (file.path as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return name }
        return Text("\(Text(directory + "/").foregroundColor(.secondary))\(name)")
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
        case .conflicted: return "!"
        case .unknown: return "?"
        }
    }

    private func statusColor(for status: FileChangeStatus) -> Color {
        switch status {
        case .modified: return .yellow
        case .added, .untracked: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .conflicted: return .orange
        case .unknown: return .secondary
        }
    }
}

/// Split out from `ChangedFilesView` so typing in the commit message field only invalidates
/// this small view's `body` — `@Observable` tracks dependencies per `body` call, so keeping the
/// text field inline in `ChangedFilesView.body` meant every keystroke re-ran the whole parent
/// body, including reconstructing the entire changed-files `List`, which is what made typing feel
/// laggy on repos with many changed files.
private struct CommitFooterView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            TextField("Commit message", text: $appState.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))

            Button {
                appState.commitOrCompleteMerge()
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

    private var hasUnresolvedConflicts: Bool {
        appState.changedFiles.contains { $0.status == .conflicted }
    }

    private var canCommit: Bool {
        let hasMessage = !appState.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if appState.isMergeInProgress {
            return hasMessage && !hasUnresolvedConflicts
        }
        return checkedCount > 0 && hasMessage
    }

    private var commitButtonTitle: String {
        if appState.isMergeInProgress {
            return "Complete Merge"
        }
        let branchName = appState.selectedBranch?.name ?? "…"
        return "Commit \(checkedCount) file\(checkedCount == 1 ? "" : "s") to \(branchName)"
    }
}
