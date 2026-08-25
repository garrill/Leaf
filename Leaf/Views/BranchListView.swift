import AppKit
import SwiftUI

struct BranchListView: View {
    @Bindable var appState: AppState
    /// `List`'s selection binds directly to this plain local `@State`, not to a computed
    /// `Binding` that reaches into `appState` on every keystroke. AppKit commits a native
    /// `@State` change about as cheaply as SwiftUI allows; going straight through a `Binding`
    /// whose `set` calls into an `@Observable` class means every keystroke, while still inside
    /// NSTableView's own selection-change delegate callback, also pays for Observation walking
    /// its dependency graph and notifying every other view reading `selectedSource` (this view,
    /// `ChangedFilesView`'s `.task(id:)`, etc.) before AppKit gets control back — under rapid
    /// key-repeat that per-event overhead is what made selection changes arrive in bursts rather
    /// than smoothly, even with all the actual git work already off the main thread. Syncing
    /// `appState.selectedSource` a step later, via `.onChange` below, keeps the hot path (a
    /// native table view committing its own selection) as cheap as possible.
    @State private var localSelection: ChangeSource?
    @FocusState private var isFocused: Bool
    @AppStorage(LeafSettings.showFullCommitTitleKey, store: LeafSettings.store) private var showFullCommitTitle = LeafSettings.defaultShowFullCommitTitle

    var body: some View {
        ZStack {
            List(selection: $localSelection) {
                Section {
                    Group {
                        if appState.uncommittedChangeCount > 0 {
                            uncommittedChangesRow.tag(ChangeSource.workingChanges)
                        } else {
                            uncommittedChangesRow
                        }
                    }
                    .listRowSeparator(.visible)

                    if appState.stashCount > 0 {
                        stashedChangesRow
                            .tag(ChangeSource.stash)
                            .listRowSeparator(.visible)
                    }
                } header: {
                    sectionHeader("Local changes", systemImage: "doc")
                }

                Section {
                    ForEach(appState.commits) { commit in
                        let commitTags = appState.tagsByCommitSHA[commit.sha] ?? []
                        CommitRowView(
                            commit: commit,
                            tags: commitTags,
                            showFullCommitTitle: showFullCommitTitle
                        )
                        .tag(ChangeSource.commit(commit))
                        .listRowSeparator(.visible)
                        .contextMenu {
                            Button("Copy SHA") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(commit.sha, forType: .string)
                            }
                            Button("Copy Commit Title") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(commit.summary, forType: .string)
                            }
                            Button("Tag Commit…") {
                                appState.newTagTargetCommit = commit
                                appState.isNewTagSheetPresented = true
                            }
                            if !commitTags.isEmpty {
                                Divider()
                                ForEach(commitTags) { tag in
                                    Button("Delete Tag \"\(tag.name)\"", role: .destructive) {
                                        appState.deleteTag(tag)
                                    }
                                }
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
            .focused($isFocused)
            .onKeyPress(.leftArrow) {
                appState.focusedColumn = .repos
                return .handled
            }
            .onKeyPress(.rightArrow) {
                appState.focusedColumn = .files
                return .handled
            }

            if appState.selectedRepoURL == nil {
                Text("No Repository Selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $appState.isNewBranchSheetPresented) {
            NewBranchSheet(appState: appState, isPresented: $appState.isNewBranchSheetPresented)
        }
        .sheet(isPresented: $appState.isNewTagSheetPresented) {
            NewTagSheet(appState: appState, isPresented: $appState.isNewTagSheetPresented)
        }
        .task {
            localSelection = appState.selectedSource
        }
        // The user picked a new row natively — propagate it to `appState` a step after AppKit's
        // own selection commit, not from inside it.
        .onChange(of: localSelection) { _, newValue in
            // List(selection:) with an Optional binding fires this with nil first (its internal
            // deselect) then the real value on the same click — ignore the nil so the diff view
            // never flashes to "no file selected" in between.
            guard let newValue else { return }
            appState.selectSource(newValue)
        }
        // Selection changed for a reason other than the user clicking/arrowing a row (initial
        // load, switching repos, discarding the selected file, etc.) — mirror it into the local
        // state that actually drives the table view, snapping instead of animating since this
        // is a full jump, not a step-by-step navigation the user should see move.
        .onChange(of: appState.selectedSource) { _, newValue in
            guard localSelection != newValue else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                localSelection = newValue
            }
        }
        // Cross-column arrow-key navigation landed here from another column — claim real
        // keyboard focus to match (see `AppState.focusedColumn`). Only ever assigns `true`: when
        // focus moves elsewhere, AppKit resigns this column's first-responder status on its own
        // as soon as another view calls `makeFirstResponder`, and `@FocusState` mirrors that back
        // down to `false` automatically. Explicitly assigning `false` here too raced against the
        // neighboring column's own `true` assignment (both fire from the same `focusedColumn`
        // change) — depending on NSHostingController update order, this column's `false` could
        // land after the other column's `true` and steal focus back to nothing.
        .onChange(of: appState.focusedColumn) { _, newValue in
            guard newValue == .branches else { return }
            isFocused = true
        }
        // The user tabbed/clicked into this column directly (not via arrow-key navigation) —
        // claim focus ownership so the next left/right press starts from here.
        .onChange(of: isFocused) { _, newValue in
            guard newValue else { return }
            appState.focusedColumn = .branches
        }
    }

    private var uncommittedChangesRow: some View {
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
    }

    private var stashedChangesRow: some View {
        HStack {
            Text("Stashed Changes")
            Spacer()
            Text("\(appState.stashFileCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
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

}

/// A single commit row, including its tag badges. Pulled out into its own `View` type only to
/// keep the `ForEach` body readable.
private struct CommitRowView: View {
    let commit: GitCommit
    let tags: [GitTag]
    let showFullCommitTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(commit.summary)
                    .lineLimit(showFullCommitTitle ? nil : 1)
                    .truncationTooltip(commit.summary, isEnabled: !showFullCommitTitle)
                if !tags.isEmpty {
                    Spacer(minLength: 6)
                    HStack(spacing: 4) {
                        ForEach(tags) { tag in
                            tagBadge(tag)
                        }
                    }
                }
            }
            Text("\(commit.author) · \(commit.relativeDate)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    /// `.secondary` (rather than a literal color like `.accentColor`) is what lets this badge pick
    /// up the same automatic white-on-selection flip macOS gives ordinary row text/labels for free
    /// — no KVO/AppKit tracking needed, unlike `StatusIconView`'s status glyph (a colored icon, not
    /// a semantic label color, so it doesn't participate in that automatic flip).
    private func tagBadge(_ tag: GitTag) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "tag.fill")
                .font(.system(size: 8))
            Text(tag.name)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}
