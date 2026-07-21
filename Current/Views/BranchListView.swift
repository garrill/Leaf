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
            .environment(\.controlActiveState, .key)
            .opacity(appState.selectedRepoURL == nil ? 0 : 1)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaBar(edge: .top, spacing: 0) { header }

            if appState.selectedRepoURL == nil {
                ContentUnavailableView("No Repo Selected", systemImage: "folder")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(appState.selectedBranch?.name ?? "")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: MainWindowView.columnHeaderHeight)
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
