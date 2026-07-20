import SwiftUI

struct RepoListView: View {
    @Bindable var appState: AppState

    @State private var renamingFolderID: UUID?
    @State private var editingRepo: SidebarRepo?

    private var sidebarStore: SidebarStore { appState.sidebarStore }

    var body: some View {
        List(selection: repoSelection) {
            ForEach(visibleRows) { row in
                rowContent(for: row)
            }
        }
        .listStyle(.sidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Menu {
                    Button("Add Repository") { appState.addRepoViaPicker() }
                    Button("Add Folder") {
                        let id = sidebarStore.addFolder()
                        renamingFolderID = id
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.glass)
                .clipShape(Circle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add…")
            }
            .padding(10)
        }
        .sheet(item: $editingRepo) { repo in
            EditRepoSheet(repo: repo, sidebarStore: sidebarStore)
        }
    }

    // MARK: Row building

    @ViewBuilder
    private func rowContent(for row: SidebarRow) -> some View {
        switch row {
        case .folder(let folder):
            FolderRowView(
                folder: folder,
                isRenaming: renamingFolderID == folder.id,
                onToggle: { sidebarStore.setFolderExpanded(id: folder.id, !folder.isExpanded) },
                onStartRename: { renamingFolderID = folder.id },
                onCommitRename: { newName in
                    sidebarStore.renameFolder(id: folder.id, to: newName)
                    renamingFolderID = nil
                },
                onDelete: {
                    if let selectedURL = appState.selectedRepoURL,
                       sidebarStore.repos.contains(where: { $0.folderID == folder.id && $0.url == selectedURL }) {
                        appState.selectedRepoURL = nil
                    }
                    sidebarStore.deleteFolder(id: folder.id)
                },
                onDrop: { payload in handleDrop(payload, ontoFolder: folder) }
            )
        case .repo(let repo, let indented):
            RepoRowView(
                repo: repo,
                appState: appState,
                sidebarStore: sidebarStore,
                onEdit: { editingRepo = repo },
                onDrop: { payload in handleDrop(payload, ontoRepo: repo) }
            )
            .tag(repo.id)
            .padding(.leading, indented ? 16 : 0)
        }
    }

    private var visibleRows: [SidebarRow] {
        var rows: [SidebarRow] = []
        for entry in sidebarStore.topLevelOrder {
            switch entry {
            case .folder(let folderID):
                guard let folder = sidebarStore.folders.first(where: { $0.id == folderID }) else { continue }
                rows.append(.folder(folder))
                if folder.isExpanded {
                    let children = sidebarStore.repos
                        .filter { $0.folderID == folderID }
                        .sorted { $0.sortIndex < $1.sortIndex }
                    rows.append(contentsOf: children.map { .repo($0, indented: true) })
                }
            case .repo(let repoID):
                guard let repo = sidebarStore.repos.first(where: { $0.id == repoID }) else { continue }
                rows.append(.repo(repo, indented: false))
            }
        }
        return rows
    }

    // MARK: Drag & drop

    private func handleDrop(_ payload: SidebarDragPayload, ontoRepo target: SidebarRepo) {
        switch payload {
        case .repo(let draggedID):
            guard draggedID != target.id else { return }
            if let folderID = target.folderID {
                let siblings = sidebarStore.repos
                    .filter { $0.folderID == folderID }
                    .sorted { $0.sortIndex < $1.sortIndex }
                let index = siblings.firstIndex(where: { $0.id == target.id }) ?? siblings.count
                sidebarStore.moveRepo(id: draggedID, toFolder: folderID, index: index)
            } else {
                let index = topLevelIndex(ofRepo: target.id) ?? sidebarStore.topLevelOrder.count
                sidebarStore.moveRepo(id: draggedID, toFolder: nil, index: index)
            }
        case .folder(let draggedID):
            guard target.folderID == nil else { return }
            let index = topLevelIndex(ofRepo: target.id) ?? sidebarStore.topLevelOrder.count
            sidebarStore.moveTopLevelEntry(.folder(draggedID), toIndex: index)
        }
    }

    private func handleDrop(_ payload: SidebarDragPayload, ontoFolder target: SidebarFolder) {
        switch payload {
        case .repo(let draggedID):
            sidebarStore.moveRepo(id: draggedID, toFolder: target.id, index: nil)
        case .folder(let draggedID):
            guard draggedID != target.id else { return }
            let index = topLevelIndex(ofFolder: target.id) ?? sidebarStore.topLevelOrder.count
            sidebarStore.moveTopLevelEntry(.folder(draggedID), toIndex: index)
        }
    }

    private func topLevelIndex(ofRepo id: UUID) -> Int? {
        sidebarStore.topLevelOrder.firstIndex {
            if case .repo(let rid) = $0 { return rid == id }
            return false
        }
    }

    private func topLevelIndex(ofFolder id: UUID) -> Int? {
        sidebarStore.topLevelOrder.firstIndex {
            if case .folder(let fid) = $0 { return fid == id }
            return false
        }
    }

    // MARK: Selection

    private var repoSelection: Binding<UUID?> {
        Binding(
            get: {
                guard let url = appState.selectedRepoURL else { return nil }
                return sidebarStore.repos.first(where: { $0.url == url })?.id
            },
            set: { newValue in
                guard let newValue, let repo = sidebarStore.repos.first(where: { $0.id == newValue }) else { return }
                appState.selectRepo(repo.url)
            }
        )
    }
}
