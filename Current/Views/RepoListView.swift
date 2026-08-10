import SwiftUI

struct RepoListView: View {
    @Bindable var appState: AppState

    var body: some View {
        SidebarOutlineView(
            appState: appState,
            renamingFolderID: $appState.renamingFolderID,
            renamingRepoID: $appState.renamingRepoID
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $appState.isCloneSheetPresented) {
            CloneRepoSheet(appState: appState, isPresented: $appState.isCloneSheetPresented)
        }
    }
}
