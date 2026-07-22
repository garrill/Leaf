import AppKit
import SwiftUI

struct BranchListView: View {
    @Bindable var appState: AppState

    var body: some View {
        ZStack {
            List(selection: sourceSelection) {
                Label("Uncommitted Changes", systemImage: "pencil.circle")
                    .tag(ChangeSource.workingChanges)
                    .listRowSeparator(.visible)

                Section("History") {
                    ForEach(appState.commits) { commit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(commit.summary)
                                .lineLimit(1)
                                .truncationTooltip(commit.summary)
                            Text("\(commit.shortSha) · \(commit.relativeDate)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(ChangeSource.commit(commit))
                        .listRowSeparator(.visible)
                        .contextMenu {
                            Button("Copy SHA") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(commit.sha, forType: .string)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .controlBackgroundColor))
            .environment(\.controlActiveState, .key)
            .opacity(appState.selectedRepoURL == nil ? 0 : 1)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaBar(edge: .top, spacing: 0) { header }

            if appState.selectedRepoURL == nil {
                Text("No Repository Selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(repoDisplayName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .truncationTooltip(repoDisplayName)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: MainWindowView.columnHeaderHeight)
    }

    private var repoDisplayName: String {
        guard let url = appState.selectedRepoURL else { return "" }
        return appState.sidebarStore.repos.first(where: { $0.url == url })?.displayName ?? url.lastPathComponent
    }

    private var sourceSelection: Binding<ChangeSource?> {
        Binding(
            get: { appState.selectedSource },
            // List(selection:) with an Optional binding fires this setter with nil first (its
            // internal deselect) then the real value on the same click — ignore the nil so the
            // diff view never flashes to "no file selected" in between.
            set: { newValue in
                if let newValue {
                    appState.selectSource(newValue)
                }
            }
        )
    }
}
