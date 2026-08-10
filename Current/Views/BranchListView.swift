import AppKit
import SwiftUI

struct BranchListView: View {
    @Bindable var appState: AppState

    var body: some View {
        ZStack {
            List(selection: sourceSelection) {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(appState.uncommittedChangeCount == 0 ? "No Uncommitted Changes" : "Uncommitted Changes")
                            Spacer()
                            if appState.uncommittedChangeCount > 0 {
                                Text("\(appState.uncommittedChangeCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let lastModifiedDate = appState.uncommittedLastModifiedDate {
                            Text("Last modified \(GitCommit.relativeDate(for: lastModifiedDate).lowercased())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .tag(ChangeSource.workingChanges)
                    .selectionDisabled(appState.uncommittedChangeCount == 0)
                    .listRowSeparator(.visible)
                } header: {
                    sectionHeader("Local changes", systemImage: "doc")
                }

                Section {
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
                } header: {
                    sectionHeader("History", systemImage: "clock")
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

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Color.primary.opacity(0.55))
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
