import SwiftUI

struct FolderRowView: View {
    let folder: SidebarFolder
    let isRenaming: Bool
    let onToggle: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: (String) -> Void
    let onDelete: () -> Void
    let onDrop: (SidebarDragPayload) -> Void

    @State private var draftName: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))

            Image(systemName: folder.isExpanded ? "folder" : "folder.fill")
                .foregroundStyle(.secondary)

            if isRenaming {
                TextField("Folder Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { commitRename() }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(folder.name)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isRenaming { onToggle() } }
        .draggable(SidebarDragPayload.folder(folder.id))
        .dropDestination(for: SidebarDragPayload.self) { items, _ in
            guard let payload = items.first else { return false }
            onDrop(payload)
            return true
        }
        .contextMenu {
            Button("Rename") { onStartRename() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
        .onChange(of: isRenaming) { _, renaming in
            if renaming {
                draftName = folder.name
                fieldFocused = true
            }
        }
    }

    private func commitRename() {
        onCommitRename(draftName)
    }
}
