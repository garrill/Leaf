import AppKit
import SwiftUI

struct RepoRowView: View {
    let repo: SidebarRepo
    let appState: AppState
    let sidebarStore: SidebarStore
    let isRenaming: Bool
    let onStartRename: () -> Void
    let onCommitRename: (String) -> Void

    @State private var draftName: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            iconView
                .frame(width: 16, height: 16)
            if isRenaming {
                TextField("Repository Name", text: $draftName)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onChange(of: isRenaming) { _, renaming in
            if renaming {
                draftName = repo.displayName
                fieldFocused = true
            }
        }
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
            Button("Remove", role: .destructive) {
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
