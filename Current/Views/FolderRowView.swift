import SwiftUI

struct FolderRowView: View {
    let folder: SidebarFolder
    let repoCount: Int
    let isRenaming: Bool
    let onToggle: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: (String) -> Void
    let onDelete: () -> Void

    @State private var draftName: String = ""
    @FocusState private var fieldFocused: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            if isRenaming {
                TextField("Group Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .focused($fieldFocused)
                    .onSubmit { commitRename() }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(folder.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if repoCount > 0 {
                Text("\(repoCount)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Image(systemName: "chevron.down")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(folder.isExpanded ? 0 : -90))
                .opacity(isHovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if !isRenaming { onToggle() } }
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
