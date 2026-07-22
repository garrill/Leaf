import SwiftUI

struct RepoListView: View {
    @Bindable var appState: AppState

    @State private var renamingFolderID: UUID?
    @State private var renamingRepoID: UUID?

    private var sidebarStore: SidebarStore { appState.sidebarStore }

    var body: some View {
        SidebarOutlineView(appState: appState, renamingFolderID: $renamingFolderID, renamingRepoID: $renamingRepoID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Menu {
                        Button("Add Repository") { appState.addRepoViaPicker() }
                        Button("Add Group") {
                            let id = sidebarStore.addFolder()
                            renamingFolderID = id
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.blue))
                    }
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add…")
                }
                .padding(16)
            }
    }
}
