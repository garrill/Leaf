import SwiftUI

struct RepoListView: View {
    @Bindable var appState: AppState

    var body: some View {
        List(appState.repoStore.repoPaths, id: \.self, selection: repoSelection) { url in
            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .listStyle(.sidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button {
                    appState.addRepoViaPicker()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.glass)
                .clipShape(Circle())
                .help("Add Repo…")
            }
            .padding(10)
        }
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
