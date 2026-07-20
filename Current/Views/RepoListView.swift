import SwiftUI

struct RepoListView: View {
    @Bindable var appState: AppState

    @State private var renamingFolderID: UUID?
    @State private var editingRepo: SidebarRepo?

    private var sidebarStore: SidebarStore { appState.sidebarStore }

    var body: some View {
        List(selection: repoSelection) {
            ForEach(sidebarStore.topLevelOrder, id: \.self) { entry in
                topLevelRow(for: entry)
            }
            .onMove { source, destination in
                sidebarStore.moveTopLevelEntries(fromOffsets: source, toOffset: destination)
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
                        .font(.title2)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
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
    private func topLevelRow(for entry: TopLevelEntry) -> some View {
        switch entry {
        case .folder(let folderID):
            if let folder = sidebarStore.folders.first(where: { $0.id == folderID }) {
                FolderRowView(
                    folder: folder,
                    repoCount: sidebarStore.repos.count { $0.folderID == folder.id },
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
                    }
                )

                if folder.isExpanded {
                    ForEach(children(of: folder)) { repo in
                        repoRow(repo, indented: true)
                    }
                    .onMove { source, destination in
                        sidebarStore.moveRepos(inFolder: folder.id, fromOffsets: source, toOffset: destination)
                    }
                }
            }
        case .repo(let repoID):
            if let repo = sidebarStore.repos.first(where: { $0.id == repoID }) {
                repoRow(repo, indented: false)
            }
        }
    }

    private func repoRow(_ repo: SidebarRepo, indented: Bool) -> some View {
        RepoRowView(repo: repo, appState: appState, sidebarStore: sidebarStore, onEdit: { editingRepo = repo })
            .tag(repo.id)
            .padding(.leading, indented ? 20 : 0)
    }

    private func children(of folder: SidebarFolder) -> [SidebarRepo] {
        sidebarStore.repos
            .filter { $0.folderID == folder.id }
            .sorted { $0.sortIndex < $1.sortIndex }
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
