import AppKit
import SwiftUI

struct RepoRowView: View {
    let repo: SidebarRepo
    let appState: AppState
    let sidebarStore: SidebarStore
    let onEdit: () -> Void
    let onDrop: (SidebarDragPayload) -> Void

    var body: some View {
        HStack(spacing: 6) {
            iconView
                .frame(width: 16, height: 16)
            Text(repo.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .draggable(SidebarDragPayload.repo(repo.id))
        .dropDestination(for: SidebarDragPayload.self) { items, _ in
            guard let payload = items.first else { return false }
            onDrop(payload)
            return true
        }
        .contextMenu {
            Button("Edit…") { onEdit() }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([repo.url])
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
            Image(systemName: "folder.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        }
    }
}
