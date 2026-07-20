import AppKit
import SwiftUI

struct RepoRowView: View {
    let repo: SidebarRepo
    let appState: AppState
    let sidebarStore: SidebarStore
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            iconView
                .frame(width: 16, height: 16)
            Text(repo.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contextMenu {
            Button("Edit…") { onEdit() }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([repo.url])
            }
            if !sidebarStore.folders.isEmpty || repo.folderID != nil {
                Divider()
                Menu("Move to Folder") {
                    if repo.folderID != nil {
                        Button("Top Level") {
                            sidebarStore.moveRepo(id: repo.id, toFolder: nil, index: nil)
                        }
                        if !sidebarStore.folders.isEmpty {
                            Divider()
                        }
                    }
                    ForEach(sidebarStore.folders.filter { $0.id != repo.folderID }) { folder in
                        Button(folder.name) {
                            sidebarStore.moveRepo(id: repo.id, toFolder: folder.id, index: nil)
                        }
                    }
                }
            }
            Divider()
            Button("Remove", role: .destructive) {
                sidebarStore.removeRepo(id: repo.id)
                if appState.selectedRepoURL == repo.url {
                    appState.selectedRepoURL = nil
                }
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let iconPath = repo.iconPath, let nsImage = NSImage(contentsOfFile: iconPath) {
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
}
