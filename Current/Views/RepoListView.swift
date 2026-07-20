import SwiftUI

struct RepoListView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            List(appState.repoStore.repoPaths, id: \.self, selection: repoSelection) { url in
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .listStyle(.sidebar)

            Divider()

            Button {
                appState.addRepoViaPicker()
            } label: {
                Label("Add Repo…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .frame(minWidth: 180, idealWidth: 200)
    }

    private var repoSelection: Binding<URL?> {
        Binding(
            get: { appState.selectedRepoURL },
            set: { newValue in
                if let newValue {
                    appState.selectRepo(newValue)
                }
            }
        )
    }
}
