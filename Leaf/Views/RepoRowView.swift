import AppKit
import SwiftUI

struct RepoRowView: View {
    let repo: SidebarRepo
    let appState: AppState
    let sidebarStore: SidebarStore
    let isRenaming: Bool
    let isLastInGroup: Bool
    let onStartRename: () -> Void
    let onCommitRename: (String) -> Void

    @AppStorage(LeafSettings.showRepoStatusKey) private var showRepoStatus = LeafSettings.defaultShowRepoStatus

    @State private var draftName: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            iconView
                .frame(width: 16, height: 16)
            if isRenaming {
                TextField(repo.displayName, text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { commitRename() }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(repo.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .truncationTooltip(repo.displayName)
            }

            Spacer(minLength: 4)

            if !isRenaming {
                statusIndicators
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.bottom, isLastInGroup ? SidebarLayout.groupSpacing : 0)
        .onAppear { beginRenamingIfNeeded() }
        .onChange(of: isRenaming) { _, renaming in
            if renaming { beginRenamingIfNeeded() }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename") { onStartRename() }
            Button("Choose Icon…") { pickIcon() }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([repo.url])
            }
            if !sidebarStore.folders.isEmpty || repo.folderID != nil {
                Divider()
                Menu("Move to Group") {
                    if repo.folderID != nil {
                        Button("Top Level") {
                            sidebarStore.moveRepoToTopLevel(id: repo.id, before: nil)
                        }
                        if !sidebarStore.folders.isEmpty {
                            Divider()
                        }
                    }
                    ForEach(sidebarStore.folders.filter { $0.id != repo.folderID }) { folder in
                        Button(folder.name) {
                            sidebarStore.moveRepo(id: repo.id, intoFolder: folder.id, before: nil)
                        }
                    }
                }
            }
            Divider()
            // Not a real "delete" — it only removes the sidebar entry, so this skips the
            // confirm-dialog treatment given to the actually-destructive actions elsewhere
            // (discard/clean/merge-abort/stash-drop). The label spells that out since the
            // repo icon otherwise makes this read like it could touch the repo on disk.
            Button("Remove from Sidebar") {
                sidebarStore.removeRepo(id: repo.id)
                if appState.selectedRepoURL == repo.url {
                    appState.deselectRepo()
                }
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let iconPath = repo.iconPath, let nsImage = IconComposerRenderer.image(forIconPath: iconPath, size: 32) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "book.closed.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        }
    }

    /// Always reads `repoStatusStore`'s cache, even for the selected repo — `appState.selectedRepoURL`
    /// updates synchronously on click, but `appState.aheadCount`/`hasUpstream`/etc. lag behind
    /// until the async refresh for the newly selected repo actually completes, so mirroring those
    /// fields directly briefly showed the *previous* repo's status on the newly selected row.
    /// `AppState.refreshRepositoryState()`/`refreshSyncStatus()` only write into the store once a
    /// fetch for the right repo lands, so this can't show stale data from another repo.
    private var effectiveSyncStatus: GitRepository.SidebarSyncStatus? {
        guard showRepoStatus else { return nil }
        return appState.repoStatusStore.statuses[repo.path]
    }

    @ViewBuilder
    private var statusIndicators: some View {
        if let status = effectiveSyncStatus {
            HStack(spacing: 4) {
                if status.uncommittedChangeCount > 0 {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .help(status.uncommittedChangeCount == 1 ? "1 uncommitted change" : "\(status.uncommittedChangeCount) uncommitted changes")
                }
                if status.hasUpstream, status.behindCount > 0 {
                    SidebarSyncArrowIconView(
                        systemName: "arrow.down",
                        baseColor: NSColor(red: 0x40 / 255, green: 0x86 / 255, blue: 0xDC / 255, alpha: 1)
                    )
                    .frame(width: 9, height: 9)
                    .offset(x: 4)
                    .help(status.behindCount == 1 ? "1 commit behind" : "\(status.behindCount) commits behind")
                }
                if status.hasUpstream, status.aheadCount > 0 {
                    SidebarSyncArrowIconView(
                        systemName: "arrow.up",
                        baseColor: NSColor(red: 0x40 / 255, green: 0xDC / 255, blue: 0x81 / 255, alpha: 1)
                    )
                    .frame(width: 9, height: 9)
                    .offset(x: 4)
                    .help(status.aheadCount == 1 ? "1 commit to push" : "\(status.aheadCount) commits to push")
                }
            }
        }
    }

    private func beginRenamingIfNeeded() {
        guard isRenaming else { return }
        draftName = repo.displayName
        DispatchQueue.main.async {
            fieldFocused = true
        }
    }

    private func commitRename() {
        onCommitRename(draftName)
    }

    private func pickIcon() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = repo.url
        panel.prompt = "Choose Icon"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        sidebarStore.updateRepo(id: repo.id, displayName: repo.displayNameOverride, iconPath: url.path)
    }
}
