import SwiftUI

struct FolderRowView: View {
    let folder: SidebarFolder
    let repoCount: Int
    let isRenaming: Bool
    let isHovering: Bool
    let isLastInGroup: Bool
    let onToggle: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: (String) -> Void
    let onSort: () -> Void
    let onDelete: () -> Void

    @State private var draftName: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: isHovering ? 10 : 0)
                .opacity(isHovering ? 1 : 0)
                .clipped()

            if isRenaming {
                TextField(folder.name, text: $draftName)
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
                    .truncationTooltip(folder.name)
            }

            Spacer()

            if repoCount > 0 {
                Text("\(repoCount)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.bottom, isLastInGroup ? SidebarLayout.groupSpacing : 0)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .overlay {
            // Only exists (and only intercepts clicks) while NOT renaming — otherwise a plain
            // `.onTapGesture` on the whole row would swallow clicks meant to focus the TextField.
            if !isRenaming {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onToggle() }
            }
        }
        .contextMenu {
            Button("Rename") { onStartRename() }
            Button("Sort Items by Name") { onSort() }
            Divider()
            Button("Delete…", role: .destructive) { onDelete() }
        }
        .onAppear { beginRenamingIfNeeded() }
        .onChange(of: isRenaming) { _, renaming in
            if renaming { beginRenamingIfNeeded() }
        }
    }

    private func beginRenamingIfNeeded() {
        guard isRenaming else { return }
        draftName = folder.name
        DispatchQueue.main.async {
            fieldFocused = true
        }
    }

    private func commitRename() {
        onCommitRename(draftName)
    }
}

private struct FolderRowPreviewRepo: View {
    let name: String
    let selected: Bool
    let appState: AppState
    let sidebarStore: SidebarStore

    var body: some View {
        RepoRowView(
            repo: SidebarRepo(id: UUID(), path: "/tmp/\(name)", displayNameOverride: name, iconPath: nil, folderID: UUID(), sortIndex: 0),
            appState: appState,
            sidebarStore: sidebarStore,
            isRenaming: false,
            isLastInGroup: false,
            onStartRename: {},
            onCommitRename: { _ in }
        )
        .background(selected ? Color.accentColor : Color.clear)
        .foregroundStyle(selected ? .white : .primary)
    }
}

#Preview {
    let appState = AppState()
    let sidebarStore = appState.sidebarStore

    return VStack(spacing: 0) {
        FolderRowView(
            folder: SidebarFolder(id: UUID(), name: "Websites", isExpanded: true),
            repoCount: 3,
            isRenaming: false,
            isHovering: false,
            isLastInGroup: false,
            onToggle: {},
            onStartRename: {},
            onCommitRename: { _ in },
            onSort: {},
            onDelete: {}
        )
        FolderRowPreviewRepo(name: "Oakdoor", selected: true, appState: appState, sidebarStore: sidebarStore)
        FolderRowPreviewRepo(name: "pepper.digital", selected: false, appState: appState, sidebarStore: sidebarStore)
        FolderRowPreviewRepo(name: "Chigwell", selected: false, appState: appState, sidebarStore: sidebarStore)

        FolderRowView(
            folder: SidebarFolder(id: UUID(), name: "Apps", isExpanded: true),
            repoCount: 2,
            isRenaming: false,
            isHovering: true,
            isLastInGroup: false,
            onToggle: {},
            onStartRename: {},
            onCommitRename: { _ in },
            onSort: {},
            onDelete: {}
        )
        FolderRowPreviewRepo(name: "Radio", selected: false, appState: appState, sidebarStore: sidebarStore)
        FolderRowPreviewRepo(name: "Current", selected: false, appState: appState, sidebarStore: sidebarStore)

        FolderRowView(
            folder: SidebarFolder(id: UUID(), name: "Renaming Me", isExpanded: true),
            repoCount: 0,
            isRenaming: true,
            isHovering: false,
            isLastInGroup: true,
            onToggle: {},
            onStartRename: {},
            onCommitRename: { _ in },
            onSort: {},
            onDelete: {}
        )
    }
    .frame(width: 220)
    .padding(.vertical, 8)
}
