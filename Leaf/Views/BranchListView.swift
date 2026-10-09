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
    /// Set right before a non-user-driven write to `localSelection` (see the `appState.selectedSource`
    /// mirror below) and checked in `localSelection`'s own `onChange` so that a repo switch's
    /// auto-selected first commit doesn't steal `focusedColumn`/real keyboard focus away from the
    /// sidebar the way an actual click on a row should.
    @State private var pendingProgrammaticSelection: ChangeSource?
    @FocusState private var isFocused: Bool
    @AppStorage(LeafSettings.showFullCommitTitleKey, store: LeafSettings.store) private var showFullCommitTitle = LeafSettings.defaultShowFullCommitTitle
    @AppStorage(LeafSettings.showCommitDescriptionKey, store: LeafSettings.store) private var showCommitDescription = LeafSettings.defaultShowCommitDescription

    var body: some View {
        ZStack {
            List(selection: $localSelection) {
                Section {
                    Group {
                        if appState.uncommittedChangeCount > 0 {
                            uncommittedChangesRow
                                .claimingFocusOnClick(claimFocusOnClick)
                                .tag(ChangeSource.workingChanges)
                                .contextMenu {
                                    Button("Stash All Changes") { appState.stashAllChanges() }
                                    Button("Discard All Changes\u{2026}", role: .destructive) { appState.discardAllChanges() }
                                    Divider()
                                    Button("Check All Files") { appState.setAllWorkingChangesChecked(true) }
                                    Button("Uncheck All Files") { appState.setAllWorkingChangesChecked(false) }
                                }
                        } else {
                            uncommittedChangesRow
                        }
                    }
                    .listRowSeparator(.visible)

                    if appState.stashCount > 0 {
                        stashedChangesRow
                            .claimingFocusOnClick(claimFocusOnClick)
                            .tag(ChangeSource.stash)
                            .listRowSeparator(.visible)
                            .contextMenu {
                                Button("Restore Stash") { appState.restoreStash() }
                                Button("Discard Stash\u{2026}", role: .destructive) { appState.discardStash() }
                            }
                    }
                } header: {
                    sectionHeader("Local changes", systemImage: "doc")
                }

                Section {
                    let unpushedSHAs = appState.unpushedCommitSHAs
                    ForEach(appState.commits) { commit in
                        let commitTags = appState.tagsByCommitSHA[commit.sha] ?? []
                        CommitRowView(
                            commit: commit,
                            tags: commitTags,
                            isUnpushed: unpushedSHAs.contains(commit.sha),
                            showFullCommitTitle: showFullCommitTitle,
                            showCommitDescription: showCommitDescription
                        )
                        .claimingFocusOnClick(claimFocusOnClick)
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
            // Only a real click/arrow should steal focus — a repo switch's auto-selected first
            // commit lands here too (via the mirror below assigning `localSelection`), and that
            // one must leave `focusedColumn` on the sidebar.
            guard pendingProgrammaticSelection != newValue else {
                pendingProgrammaticSelection = nil
                return
            }
            // A mouse click on a row doesn't reliably flip `isFocused` true on its own (unlike
            // arrow-key cross-column navigation, which sets `focusedColumn` explicitly) — claim
            // it here too, or the sidebar's `NSOutlineView` keeps real AppKit first-responder
            // status (and its blue selection) while this list's own selection renders grey.
            appState.focusedColumn = .branches
        }
        // Selection changed for a reason other than the user clicking/arrowing a row (initial
        // load, switching repos, discarding the selected file, etc.) — mirror it into the local
        // state that actually drives the table view, snapping instead of animating since this
        // is a full jump, not a step-by-step navigation the user should see move.
        .onChange(of: appState.selectedSource) { _, newValue in
            guard localSelection != newValue else { return }
            pendingProgrammaticSelection = newValue
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

    /// Clicking the row that's *already* selected (grey because another column has focus)
    /// leaves `localSelection` unchanged, so its `onChange` focus claim never fires — this
    /// claims it on the click itself. Sets `isFocused` directly as well as `focusedColumn`, since
    /// the latter may already read `.branches` and then its own `onChange` wouldn't fire either.
    private func claimFocusOnClick() {
        isFocused = true
        appState.focusedColumn = .branches
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
    /// This commit exists locally but not on the branch's upstream — flagged with a trailing
    /// up-arrow badge.
    let isUnpushed: Bool
    /// Lets the summary and description wrap in full; otherwise one line and two respectively.
    let showFullCommitTitle: Bool
    let showCommitDescription: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(commit.summary)
                    .lineLimit(showFullCommitTitle ? nil : 1)
                    .truncationTooltip(commit.summary, isEnabled: !showFullCommitTitle)
                if !tags.isEmpty || isUnpushed {
                    Spacer(minLength: 6)
                    HStack(spacing: 4) {
                        ForEach(tags) { tag in
                            tagBadge(tag)
                        }
                        if isUnpushed {
                            unpushedBadge
                        }
                    }
                }
            }
            if showCommitDescription, !commit.body.isEmpty {
                Text(commit.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(showFullCommitTitle ? nil : 2)
            }
            Text("\(commit.author) · \(commit.relativeDate)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    /// Up-arrow badge marking a commit that hasn't been pushed to the remote. Same reliance on
    /// semantic colors (`.primary` glyph, `.secondary` circle) as `tagBadge` so both the glyph and
    /// its background flip to white automatically when the row is selected and emphasised.
    private var unpushedBadge: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: 16, height: 16)
            .background(Circle().fill(Color.secondary.opacity(0.2)))
            .help("This commit has not been pushed to the remote repository")
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

private extension View {
    /// Runs `action` on a click anywhere in the row, alongside (not instead of) `List`'s own
    /// native selection handling.
    func claimingFocusOnClick(_ action: @escaping () -> Void) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(action))
    }
}
