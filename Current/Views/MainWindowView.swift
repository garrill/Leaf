import SwiftUI

struct MainWindowView: View {
    @State private var appState = AppState()

    var body: some View {
        HStack(spacing: 0) {
            RepoListView(appState: appState)
            Divider()
            BranchListView(appState: appState)
            Divider()
            ChangedFilesView(appState: appState)
            Divider()
            DiffView(appState: appState)
        }
        .frame(minWidth: 900, minHeight: 500)
    }
}

#Preview {
    MainWindowView()
}
