import SwiftUI

/// Shown in place of the sidebar's `NSOutlineView` when there are no repos yet — hosted directly
/// by `SidebarViewController` as a plain overlay subview (not wrapping the outline view itself;
/// see that file for why).
struct SidebarEmptyStateView: View {
    @Bindable var appState: AppState

    var body: some View {
        ZStack {
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
