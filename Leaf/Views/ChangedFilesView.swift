import AppKit
import SwiftUI

struct ChangedFilesView: View {
    @Bindable var appState: AppState
    @FocusState private var isFocused: Bool
    /// Focus for the commit message field, tracked here (rather than solely inside
    /// `CommitFooterView`) so this view's own arrow-key/escape column-navigation handlers and its
    /// `isFocused` reclaim logic below can both check it and back off — see the comment on
    /// `CommitFooterView.isMessageFocused` for why a shared, separately-identified `@FocusState`
    /// is required here instead of letting the field fall under `isFocused`'s scope.
    @FocusState private var isCommitMessageFocused: Bool

    var body: some View {
        ZStack {
            List(appState.changedFiles, selection: fileSelection) { file in
                HStack {
                    if isWorkingChanges {
                        Toggle("", isOn: checkedBinding(for: file))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                    }
                    pathAndFileName(for: file)
                    Spacer()
                    if file.status == .conflicted {
                        Button("Mark Resolved") {
                            appState.markResolved(file)
                        }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                    } else {
                        StatusIconView(status: file.status)
                            .frame(width: 14, height: 14)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Every row's content is single-line regardless of which conditional branch
                // above applies (toggle vs. not, "Mark Resolved" button vs. status glyph) — an
                // explicit fixed height lets List treat every row as uniform instead of having
                // to measure each one individually. Without it, a commit touching hundreds of
                // files spent a large chunk of selection time (confirmed via Instruments' Time
                // Profiler) inside this row's `.contextMenu` closure, which only makes sense if
                // the full row (including its context menu) was being built for every item up
                // front rather than lazily for on-screen rows only.
                .frame(height: 22)
                .tag(file.path)
                .listRowSeparator(.visible)
                .contextMenu {
                    contextMenuItems(for: file)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .controlBackgroundColor))
            .environment(\.controlActiveState, .key)
            .opacity(showsList ? 1 : 0)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .safeAreaBar(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    header
                    if isWorkingChanges && appState.isMergeInProgress {
                        mergeBanner
                    }
                }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if isWorkingChanges && !appState.changedFiles.isEmpty {
                    CommitFooterView(appState: appState, isMessageFocused: $isCommitMessageFocused)
                } else if isStash && !appState.changedFiles.isEmpty {
                    StashFooterView(appState: appState)
                } else if isNewestUnpushedCommit || appState.pushSucceeded {
                    // `appState.pushSucceeded` keeps this footer around for its own few seconds
                    // even though a successful push immediately zeroes `aheadCount`, which would
                    // otherwise make `isNewestUnpushedCommit` false and yank the success message
                    // away before it's had a chance to animate out.
                    //
                    // By the time `pushSucceeded` flips back to false 3s later, `aheadCount` has
                    // long since settled to 0 (via `refreshSyncStatus()`'s own async fetch), so
                    // `isNewestUnpushedCommit` is already false too — that flip removes this whole
                    // branch, not just something inside `UnpushedCommitFooterView`. The transition
                    // has to live here, at the point the branch itself disappears, or the exit
                    // never animates; `UnpushedCommitFooterView`'s own internal transition only
                    // covers swapping between its buttons and its toast while it stays mounted.
                    UnpushedCommitFooterView(appState: appState)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: appState.pushSucceeded)
            .focused($isFocused)
            // Left/right/escape here are column-navigation shortcuts, not something the commit
            // message field should ever see — while it has focus, arrow keys need to move the
            // text cursor and escape needs to do nothing, so all three back off and let the
            // field's own default key handling run instead.
            .onKeyPress(.leftArrow) {
                guard !isCommitMessageFocused else { return .ignored }
                appState.focusedColumn = .branches
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard !isCommitMessageFocused else { return .ignored }
                appState.focusedColumn = .diff
                return .handled
            }
            .onKeyPress(.escape) {
                guard !isCommitMessageFocused, isNewestUnpushedCommit, !appState.isPushingCommit else { return .ignored }
                appState.undoLastCommit()
                return .handled
            }

            if appState.selectedRepoURL == nil {
                // Blank — column 2 already communicates "no repository selected".
            } else if appState.selectedSource == nil {
                ContentUnavailableView("Select Uncommitted Changes or a Commit", systemImage: "sidebar.left")
            } else if appState.changedFiles.isEmpty {
                Text("No Changes")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Keyed on the selection itself, not triggered imperatively from `AppState` — SwiftUI
        // cancels and restarts this automatically the moment `selectedSource` changes again, so
        // a superseded selection's git call never lingers to overwrite a newer one. This is what
        // actually keeps the commit-list row highlight (a plain, instant property write) fully
        // decoupled from however long this load takes. Repo URL is included alongside the source
        // because `refreshRepositoryState()` can resolve a newly selected repo to the very same
        // `ChangeSource` case (e.g. two repos in a row both defaulting to `.workingChanges`) —
        // without the URL in the key, that repo switch wouldn't change `id` at all, so this task
        // would never re-run and `changedFiles` would stay stuck at the empty list `selectRepo`
        // clears it to up front.
        .task(id: ChangedFilesLoadKey(repoURL: appState.selectedRepoURL, source: appState.selectedSource)) {
            await appState.loadChangedFilesForCurrentSelection()
        }
        // Cross-column arrow-key navigation landed here from another column — claim real
        // keyboard focus to match (see `AppState.focusedColumn`). Only ever assigns `true`: when
        // focus moves elsewhere, AppKit resigns this column's first-responder status on its own
        // as soon as another view calls `makeFirstResponder`, and `@FocusState` mirrors that back
        // down to `false` automatically. Explicitly assigning `false` here too raced against the
        // neighboring column's own `true` assignment (both fire from the same `focusedColumn`
        // change) — depending on NSHostingController update order, this column's `false` could
        // land after the other column's `true` and steal focus back to nothing.
        // Skipped while the commit message field already holds focus: setting `isFocused` here
        // would make SwiftUI hand real first-responder status to the List itself, yanking it away
        // from the field's `NSTextView` a beat after a click had just granted it — the exact
        // "only one of the two can actually hold it" conflict `DiffView` hits with its own text
        // view (see that file's comment on the same fight). `CommitFooterView`'s own `onChange`
        // is what sets `appState.focusedColumn = .files` when the field is clicked directly, so
        // this guard is what stops that from looping back and reclaiming focus in the same beat.
        .onChange(of: appState.focusedColumn) { _, newValue in
            guard newValue == .files, !isCommitMessageFocused else { return }
            isFocused = true
        }
        // The user tabbed/clicked into this column directly (not via arrow-key navigation) —
        // claim focus ownership so the next left/right press starts from here.
        .onChange(of: isFocused) { _, newValue in
            guard newValue else { return }
            appState.focusedColumn = .files
        }
    }

    private struct ChangedFilesLoadKey: Hashable {
        let repoURL: URL?
        let source: ChangeSource?
    }

    private var header: some View {
        HStack {
            Text(headerTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationTooltip(headerTitle)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: ColumnLayout.headerHeight)
    }

    private var headerTitle: String {
        switch appState.selectedSource {
        case .none: return ""
        case .workingChanges: return "Uncommitted Changes"
        case .stash: return "Stashed Changes"
        case .commit(let commit): return commit.summary
        }
    }

    private var mergeConflictCount: Int {
        appState.changedFiles.count { $0.status == .conflicted }
    }

    private var mergeBanner: some View {
        HStack {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(.orange)
            Text(mergeConflictCount > 0 ? "Merging — \(mergeConflictCount) conflict\(mergeConflictCount == 1 ? "" : "s") remaining" : "Merging — ready to commit")
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Button("Abort", role: .destructive) {
                appState.abortMerge()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    /// The files a context-menu action should apply to: the full multi-selection if the
    /// right-clicked file is part of it, otherwise just the right-clicked file on its own
    /// (matching Finder's behavior for right-clicking outside the current selection).
    private func targetFiles(for file: ChangedFile) -> [ChangedFile] {
        guard appState.selectedFilePaths.contains(file.path), appState.selectedFilePaths.count > 1 else {
            return [file]
        }
        return appState.changedFiles.filter { appState.selectedFilePaths.contains($0.path) }
    }

    @ViewBuilder
    private func contextMenuItems(for file: ChangedFile) -> some View {
        let files = targetFiles(for: file)
        if files.count == 1 {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fullURL(for: file)])
            }
            Button("Open in Default Program") {
                LeafSettings.open(fullURL(for: file))
            }
            Divider()
            Button("Copy File Path") {
                copyToPasteboard(fullURL(for: file).path)
            }
            Button("Copy Relative Path") {
                copyToPasteboard(file.path)
            }
            if isWorkingChanges, file.status != .conflicted {
                Divider()
                Button("Stash Changes") {
                    appState.stashChanges(for: [file])
                }
                Button("Discard Changes", role: .destructive) {
                    appState.discardChanges(for: file)
                }
                Button("Ignore File") {
                    appState.ignoreFile(file)
                }
            }
        } else {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(files.map(fullURL(for:)))
            }
            Divider()
            Button("Copy Relative Paths") {
                copyToPasteboard(files.map(\.path).joined(separator: "\n"))
            }
            if isWorkingChanges {
                let discardableFiles = files.filter { $0.status != .conflicted }
                if !discardableFiles.isEmpty {
                    Divider()
                    Button("Stash \(discardableFiles.count) Files") {
                        appState.stashChanges(for: discardableFiles)
                    }
                    Button("Discard Changes in \(discardableFiles.count) Files", role: .destructive) {
                        appState.discardChanges(for: discardableFiles)
                    }
                    Button("Add \(discardableFiles.count) Files to .gitignore") {
                        appState.ignoreFiles(discardableFiles)
                    }
                }
            }
        }
    }

    private func fullURL(for file: ChangedFile) -> URL {
        guard let repoURL = appState.selectedRepoURL else {
            return URL(fileURLWithPath: file.path)
        }
        return repoURL.appendingPathComponent(file.path)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private var isWorkingChanges: Bool {
        appState.selectedSource == .workingChanges
    }

    private var isStash: Bool {
        appState.selectedSource == .stash
    }

    /// True when the selected source is the branch's own tip commit (`commits.first`, not just
    /// any `.commit` case — history rows further back never show this toolbar) and that commit
    /// hasn't reached `origin` yet, whether because the branch has no upstream at all or because
    /// it does but sits ahead of it.
    private var isNewestUnpushedCommit: Bool {
        guard case .commit(let commit) = appState.selectedSource,
              appState.commits.first?.sha == commit.sha else { return false }
        return !appState.hasUpstream || appState.aheadCount > 0
    }

    private var showsList: Bool {
        appState.selectedRepoURL != nil && appState.selectedSource != nil && !appState.changedFiles.isEmpty
    }

    /// Backed by a `Set<String>` (file paths) rather than `Set<ChangedFile>` so native
    /// shift/cmd-click multi-selection works, tagging rows with `file.path` above.
    private var fileSelection: Binding<Set<String>> {
        Binding(
            get: { appState.selectedFilePaths },
            set: { newValue in appState.updateFileSelection(newValue) }
        )
    }

    /// Directory in secondary/grey, file name in primary color, on one line — matching
    /// `DiffView`'s header treatment, with `.truncationMode(.head)` so a long path truncates
    /// from the front and the file name (the most useful part) always stays visible.
    ///
    /// Renamed files show "oldPath → path" as two independent `Text` views (each with its own
    /// `.truncationMode(.head)`/tooltip) rather than one concatenated `Text` — a single `Text`
    /// can only truncate as one continuous run, which would swallow the arrow and destination
    /// path entirely once the combined string overflows, instead of eliding each side on its own.
    @ViewBuilder
    private func pathAndFileName(for file: ChangedFile) -> some View {
        if let oldPath = file.oldPath {
            HStack(spacing: 4) {
                pathText(for: oldPath)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .truncationTooltip(oldPath)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                pathText(for: file.path)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .truncationTooltip(file.path)
            }
        } else {
            pathText(for: file.path)
                .lineLimit(1)
                .truncationMode(.head)
                .truncationTooltip(file.path)
        }
    }

    private func pathText(for path: String) -> Text {
        let name = Text((path as NSString).lastPathComponent).foregroundColor(.primary)
        let directory = (path as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return name }
        return Text("\(Text(directory + "/").foregroundColor(.secondary))\(name)")
    }

    private func checkedBinding(for file: ChangedFile) -> Binding<Bool> {
        Binding(
            get: { appState.checkedFilePaths.contains(file.path) },
            set: { appState.setChecked($0, for: file.path) }
        )
    }

}

/// Split out from `ChangedFilesView` so typing in the commit message field only invalidates
/// this small view's `body` — `@Observable` tracks dependencies per `body` call, so keeping the
/// text field inline in `ChangedFilesView.body` meant every keystroke re-ran the whole parent
/// body, including reconstructing the entire changed-files `List`, which is what made typing feel
/// laggy on repos with many changed files.
private struct CommitFooterView: View {
    @Bindable var appState: AppState
    /// Passed down from `ChangedFilesView` (rather than a plain local `@FocusState` here) so that
    /// view's own column-navigation key handlers and its `isFocused` reclaim logic can see when
    /// this field has focus. It has to be its own separately-identified `@FocusState` rather than
    /// falling under `ChangedFilesView.isFocused`'s scope — with only one `.focused($isFocused)`
    /// in the tree, SwiftUI resolves *any* focusable descendant (this field included) as "focus
    /// for that binding," so a click landing in the field was also flipping `isFocused` true and
    /// making the List itself claim real first-responder status a beat later — stealing the field
    /// back before the click's effect had a chance to stick, and requiring a second click to win.
    var isMessageFocused: FocusState<Bool>.Binding

    /// Return-key submission can't be done via `.onKeyPress(.return)` on the field itself:
    /// `axis: .vertical` backs the field with a real multi-line `NSTextView`, which swallows
    /// Return as `insertNewline:` at the AppKit level before SwiftUI's key-press pipeline ever
    /// sees it (confirmed empirically — the modifier never fired). A local `NSEvent` monitor,
    /// installed only while this field holds focus, intercepts the key first and can suppress it
    /// by returning `nil`. Shift+Return still passes through untouched so a multi-line message
    /// stays possible.
    @State private var returnKeyMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Commit message", text: $appState.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                )
                .focused(isMessageFocused)

            Button {
                appState.commitOrCompleteMerge()
            } label: {
                commitButtonLabel
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .disabled(!canCommit)
        }
        .padding(10)
        .onChange(of: isMessageFocused.wrappedValue) { _, focused in
            if focused {
                // Set directly rather than through `ChangedFilesView.isFocused` — see that
                // view's own `onChange(of: appState.focusedColumn)` for why routing this through
                // the List's focus state instead would just reclaim the field right back.
                appState.focusedColumn = .files
                installReturnKeyMonitor()
            } else {
                removeReturnKeyMonitor()
            }
        }
        .onDisappear {
            removeReturnKeyMonitor()
        }
    }

    private func installReturnKeyMonitor() {
        removeReturnKeyMonitor()
        returnKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 36, !event.modifierFlags.contains(.shift) else { return event }
            guard canCommit else { return event }
            appState.commitOrCompleteMerge()
            return nil
        }
    }

    private func removeReturnKeyMonitor() {
        guard let returnKeyMonitor else { return }
        NSEvent.removeMonitor(returnKeyMonitor)
        self.returnKeyMonitor = nil
    }

    private var checkedCount: Int {
        appState.checkedFilePaths.count
    }

    private var hasUnresolvedConflicts: Bool {
        appState.changedFiles.contains { $0.status == .conflicted }
    }

    private var canCommit: Bool {
        let hasMessage = !appState.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if appState.isMergeInProgress {
            return hasMessage && !hasUnresolvedConflicts
        }
        return checkedCount > 0 && hasMessage
    }

    private var commitButtonLabel: Text {
        if appState.isMergeInProgress {
            return Text("Complete Merge")
        }
        let branchName = appState.selectedBranch?.name ?? "…"
        let suffix = checkedCount == 1 ? "" : "s"
        return Text("Commit \(checkedCount) file\(suffix) to ") + Text(branchName).bold()
    }
}

/// Footer shown when the top-of-stack stash is selected — no commit message, just the two
/// actions that make sense for a stash: apply-and-drop it back into the working tree, or drop it
/// unapplied.
private struct StashFooterView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Button("Discard", role: .destructive) {
                    appState.discardStash()
                }
                .buttonStyle(.bordered)
                Button("Restore") {
                    appState.restoreStash()
                }
                .buttonStyle(.glassProminent)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(10)
    }
}

/// Toolbar shown when the selected commit is the branch's own tip and hasn't reached `origin` yet
/// (`ChangedFilesView.isNewestUnpushedCommit`) — offers to undo it, landing its changes back on
/// "Uncommitted Changes" (`AppState.undoLastCommit()`'s `reset --soft` plus the usual
/// post-refresh selection heuristic), or push it straight up. The push button only appears at all
/// when an `origin` remote actually exists to push to.
private struct UnpushedCommitFooterView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            if appState.pushSucceeded {
                PushSuccessToastView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                HStack(spacing: 8) {
                    Button {
                        appState.undoLastCommit()
                    } label: {
                        Label("Undo Commit", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .disabled(appState.isPushingCommit)

                    if appState.hasOriginRemote {
                        Button {
                            appState.pushCurrentBranch()
                        } label: {
                            HStack(spacing: 6) {
                                if appState.isPushingCommit {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.up")
                                }
                                Text(appState.isPushingCommit ? (appState.pushProgressText ?? "Pushing") : "Push to Origin")
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .disabled(appState.isSyncing)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(10)
        .animation(.easeInOut(duration: 0.3), value: appState.pushSucceeded)
        .alert(
            "Push Failed",
            isPresented: Binding(
                get: { appState.pushErrorMessage != nil },
                set: { isPresented in if !isPresented { appState.pushErrorMessage = nil } }
            ),
            presenting: appState.pushErrorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

/// A floating "liquid glass" pill (frosted `.ultraThinMaterial` blur behind a translucent green
/// tint, a hairline white edge highlight, and a soft drop shadow), styled after
/// writetodisk.com/liquid-glass-toast/ — modulo that reference's actual `.glassEffect()`
/// modifier, which doesn't exist in the macOS 26.5 SDK (see CLAUDE.md); a tinted material
/// stand-in gets the same look. Centered rather than stretched full-width, so it reads as a
/// floating toast and not another full-width footer row.
private struct PushSuccessToastView: View {
    var body: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white)
                Text("Successfully pushed to origin")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color.green.opacity(0.55))
            }
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            Spacer(minLength: 0)
        }
    }
}
