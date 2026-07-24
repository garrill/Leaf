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
                            Text("\(commit.author) · \(commit.relativeDate)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
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

            if appState.selectedRepoURL == nil {
                Text("No Repository Selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
