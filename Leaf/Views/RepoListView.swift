import SwiftUI

struct RepoListView: View {
    @Bindable var appState: AppState

    var body: some View {
        ZStack {
            SidebarOutlineView(
                appState: appState,
                renamingFolderID: $appState.renamingFolderID,
                renamingRepoID: $appState.renamingRepoID
            )
            .opacity(appState.sidebarStore.repos.isEmpty ? 0 : 1)

            if appState.sidebarStore.repos.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text("No Repositories")
                        .font(.subheadline.weight(.medium))
                    Text("Add a folder that contains a git repository to get started.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        appState.addRepoViaPicker()
                    } label: {
                        Label("Add local repository", systemImage: "plus")
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(.blue)
                    .padding(.top, 14)
                }
                .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $appState.isCloneSheetPresented) {
            CloneRepoSheet(appState: appState, isPresented: $appState.isCloneSheetPresented)
        }
    }
}
