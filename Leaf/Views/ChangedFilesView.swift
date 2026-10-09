import AppKit
import SwiftUI

struct ChangedFilesView: View {
    @Bindable var appState: AppState
    @FocusState private var isFocused: Bool
    /// Which commit message field (if any) has focus, tracked here (rather than solely inside
    /// `CommitFooterView`) so `ChangedFilesList`'s own arrow-key/escape column-navigation
    /// handlers and this view's `isFocused` reclaim logic can both check it and back off. Plain
    /// state, not `@FocusState` — the fields are AppKit text views (`CommitTextField`) that
    /// report their own first-responder changes into it.
    @State private var commitFieldFocus: CommitField?

    var body: some View {
        ZStack {
            // The file `List` and everything attached directly to it (header/footer bars, focus,
            // key handlers) live in `ChangedFilesList` so that a selection change — which the
            // list's `selection:` binding makes a `body` dependency — re-runs only that small
            // subview, not this view's four `.alert`s, the empty-state overlays below, or the
            // load `.task`. On a commit with tens of thousands of changed files, that saved
            // re-evaluation is the difference between a click landing instantly and stalling.
            ChangedFilesList(
                appState: appState,
                isFocused: $isFocused,
                commitFieldFocus: $commitFieldFocus
            )

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
        // a superseded selection's git call never lingers to overwrite a newer one. Repo URL is
        // included alongside the source because `refreshRepositoryState()` can resolve a newly
        // selected repo to the very same `ChangeSource` case (e.g. two repos in a row both
        // defaulting to `.workingChanges`) — without the URL in the key, that repo switch
        // wouldn't change `id` at all, so this task would never re-run and `changedFiles` would
        // stay stuck at the empty list `selectRepo` clears it to up front.
        .task(id: ChangedFilesLoadKey(repoURL: appState.selectedRepoURL, source: appState.selectedSource)) {
            await appState.loadChangedFilesForCurrentSelection()
        }
        // `CommitFooterView`'s own `onChange` is what sets `appState.focusedColumn = .files` when
        // the message field is clicked directly, so this guard is what stops that from looping
        // back and reclaiming focus for the List in the same beat.
        .onChange(of: appState.focusedColumn) { _, newValue in
            guard newValue == .files, commitFieldFocus == nil else { return }
            isFocused = true
        }
        // The user tabbed/clicked into this column directly (not via arrow-key navigation) —
        // claim focus ownership so the next left/right press starts from here.
        .onChange(of: isFocused) { _, newValue in
            guard newValue else { return }
            appState.focusedColumn = .files
        }
        // Lives at the top level (not nested in a conditional footer) so it fires regardless of
        // what's currently selected/shown — a commit or push can be triggered from the toolbar
        // or menu bar as easily as from a footer button. See `AppState.gitFailureAlert`'s doc
        // comment for why this replaced reading the generic `errorMessage` inline in `DiffView`.
        .alert(
            appState.gitFailureAlert?.title ?? "",
            isPresented: Binding(
                get: { appState.gitFailureAlert != nil },
                set: { isPresented in if !isPresented { appState.gitFailureAlert = nil } }
            ),
            presenting: appState.gitFailureAlert
        ) { alert in
            Button("Cancel", role: .cancel) {}
            ForEach(alert.blockingTrackedPaths, id: \.self) { path in
                Button("Stash \(path)") {
                    appState.stashAndRetryPull(path: path)
                }
            }
            if alert.offerPullThenPush {
                Button("Pull from Origin") {
                    appState.pullThenPush()
                }
            }
        } message: { alert in
            // The rejected push's destination gets its own bold line rather than being spliced
            // into the sentence — `Text` doesn't parse Markdown from a plain `String`, so
            // backticks around it would render as literal characters, not a code span.
            if let remote = alert.pushRemoteURL {
                Text("Failed to push to:\n\(Text(remote).bold())\n\(alert.message)")
            } else {
                Text(alert.message)
            }
        }
        /// A conflicting stash restore (`AppState.restoreStash()`) — separate from `gitFailureAlert` above since it's not a failure to report so much as a choice about what happens to the now-redundant stash entry once its content is already merged (with conflict markers) into the working tree.
        .alert(
            "Restore Stash",
            isPresented: Binding(
                get: { appState.stashConflictAlert != nil },
                set: { isPresented in if !isPresented { appState.cancelStashConflict() } }
            ),
            presenting: appState.stashConflictAlert
        ) { alert in
            Button("Restore Conflicted and Remove Stash") {
                appState.keepStashConflictAndDropStash()
            }
            Button("Restore Conflicted and Keep Stash") {
                appState.keepStashConflictAndKeepStash()
            }
            Button("Cancel", role: .cancel) {
                appState.cancelStashConflict()
            }
        } message: { alert in
            if alert.conflictedPaths.count == 1, let path = alert.conflictedPaths.first {
                Text("\u{2018}\(path)\u{2019} will be conflicted if restored.")
            } else {
                Text("The following files will be conflicted if restored:\n" + alert.conflictedPaths.joined(separator: "\n"))
            }
        }
        // Refuses a commit whose checked files still have conflict markers — `canCommit` already
        // disables the button for this during a merge, but a conflict from a stash restore,
        // cherry-pick or rebase isn't a merge, so the button stays live and the commit call is
        // what has to stop it. Purely informational: the fix is per-file ("Mark Resolved").
        .alert(
            "Resolve Conflicts First",
            isPresented: Binding(
                get: { appState.conflictedCommitAlert != nil },
                set: { isPresented in if !isPresented { appState.conflictedCommitAlert = nil } }
            ),
            presenting: appState.conflictedCommitAlert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            if alert.conflictedPaths.count == 1, let path = alert.conflictedPaths.first {
                Text("\u{2018}\(path)\u{2019} still has unresolved conflict markers. Fix the conflict and choose \u{201C}Mark Resolved\u{201D}, then commit again.")
            } else {
                Text("These files still have unresolved conflict markers. Fix each conflict and choose \u{201C}Mark Resolved\u{201D}, then commit again:\n" + alert.conflictedPaths.joined(separator: "\n"))
            }
        }
        // Raised when the resolve-button icon is clicked on a file whose contents still
        // contain `<<<<<<<` markers — staging it anyway is allowed, but confirmed first.
        .alert(
            "Mark as resolved?",
            isPresented: Binding(
                get: { appState.unresolvedConflictAlert != nil },
                set: { isPresented in if !isPresented { appState.unresolvedConflictAlert = nil } }
            ),
            presenting: appState.unresolvedConflictAlert
        ) { alert in
            Button("Cancel", role: .cancel) {}
            Button("Mark resolved") {
                appState.markResolved(alert.file)
            }
        } message: { alert in
            Text("The file \u{201C}\(alert.fileName)\u{201D} does not appear to be resolved. Are you sure you want to mark it resolved?")
        }
    }

    private struct ChangedFilesLoadKey: Hashable {
        let repoURL: URL?
        let source: ChangeSource?
    }
}

/// The changed-files `List` for column 3, plus its header/merge banner, footer bars, and
/// keyboard handling. Split out from `ChangedFilesView` so a file-selection change (a `body`
/// dependency via the list's `selection:` binding) only re-runs this subview — not that view's
/// alerts, empty-state overlays, or load task.
private struct ChangedFilesList: View {
    @Bindable var appState: AppState
    var isFocused: FocusState<Bool>.Binding
    var commitFieldFocus: Binding<CommitField?>
    @State private var isTitleExpanded = false
    @State private var isTitleTruncated = false
    /// `List`'s selection binds to this local buffer rather than straight into `appState`, same
    /// reasoning as `BranchListView.localSelection` — `List(selection:)` fires its internal
    /// spurious empty-set deselect before a real click's selection lands, and routed directly
    /// into `appState.updateFileSelection` that briefly-empty write was clearing `selectedFile`
    /// to nil, which is what left the diff pane blank after selecting a repo/source (the
    /// programmatic `selectFile(changedFiles.first)` that follows a load got stomped by this
    /// same spurious empty fire before the user ever touched the list).
    @State private var localFileSelection: Set<String> = []
    /// Set right before a non-user-driven write to `localFileSelection` (see the
    /// `appState.selectedFilePaths` mirror below) and checked in `localFileSelection`'s own
    /// `onChange` so that a repo/commit switch's auto-selected first file doesn't steal
    /// `focusedColumn`/real keyboard focus the way an actual click on a row should.
    @State private var pendingProgrammaticFileSelection: Set<String>?

    var body: some View {
        List(appState.changedFiles, selection: $localFileSelection) { file in
            HStack {
                if isWorkingChanges {
                    Toggle("", isOn: checkedBinding(for: file))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
                pathAndFileName(for: file)
                Spacer()
                if file.status == .conflicted || appState.justResolvedPath == file.path {
                    // The orange conflict glyph stays alongside the resolve button (to its
                    // right) — the button is now just a `checkmark.circle` icon, so the
                    // row still needs the status glyph to read as conflicted. During the
                    // brief post-resolve window `file.status` has already flipped to the
                    // staged glyph while the green `checkmark.circle.fill` confirms.
                    Button {
                        appState.requestMarkResolved(file)
                    } label: {
                        ResolveIconView(isResolved: appState.justResolvedPath == file.path)
                            .frame(width: 15, height: 15)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Mark as resolved")
                    StatusIconView(status: file.status)
                        .frame(width: 14, height: 14)
                } else {
                    StatusIconView(status: file.status)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Every row's content is single-line, so a fixed height lets List treat rows as
            // uniform instead of measuring each. Combined with keeping the row body free of
            // laziness-defeating modifiers — no per-row `.contextMenu` (moved to the
            // List-level `.contextMenu(forSelectionType:)` below, which is only built on
            // right-click) and no per-row `NSViewRepresentable` (the truncation tooltip is now
            // a plain `.help`) — this is what keeps selecting a row in a 10k-file list as fast
            // as in a 5-file one. Both were confirmed via Instruments to be run for every item
            // up front, not just the on-screen ones.
            .frame(height: 22)
            .contentShape(Rectangle())
            // Clicking the row that's *already* selected (grey because another column has
            // focus) leaves `localFileSelection` unchanged, so its `onChange` focus claim below
            // never fires — claim focus on the click itself too. Set `isFocused` directly as
            // well as `focusedColumn`: the latter can already read `.files` (e.g. commit
            // message field focused), in which case its own `onChange` wouldn't fire either.
            .simultaneousGesture(TapGesture().onEnded {
                isFocused.wrappedValue = true
                appState.focusedColumn = .files
            })
            .tag(file.path)
            .listRowSeparator(.visible)
        }
        .contextMenu(forSelectionType: String.self) { paths in
            contextMenuItems(forPaths: paths)
        } primaryAction: { paths in
            // Double-click (or Return) — same as the single-file "Open in Default Program"
            // context-menu item. Skipped for a multi-selection and for a file that no longer
            // exists on disk (deleted in the working tree or in the selected commit).
            guard paths.count == 1, let file = appState.changedFiles.first(where: { paths.contains($0.path) }) else { return }
            let url = fullURL(for: file)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            LeafSettings.open(url)
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
                CommitFooterView(appState: appState, focusedField: commitFieldFocus)
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
                    .transition(.materialize)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.pushSucceeded)
        .focused(isFocused)
        // Left/right/escape here are column-navigation shortcuts, not something the commit
        // message field should ever see — while it has focus, arrow keys need to move the
        // text cursor and escape needs to do nothing, so all three back off and let the
        // field's own default key handling run instead.
        .onKeyPress(.leftArrow) {
            guard commitFieldFocus.wrappedValue == nil else { return .ignored }
            appState.focusedColumn = .branches
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard commitFieldFocus.wrappedValue == nil else { return .ignored }
            appState.focusedColumn = .diff
            return .handled
        }
        .onKeyPress(.escape) {
            guard commitFieldFocus.wrappedValue == nil, isNewestUnpushedCommit, !appState.isPushingCommit else { return .ignored }
            appState.undoLastCommit()
            return .handled
        }
        .task {
            localFileSelection = appState.selectedFilePaths
        }
        // The user picked row(s) natively — propagate a step after AppKit's own selection
        // commit. The empty set is ignored: it's either `List`'s spurious pre-click internal
        // deselect (see `localFileSelection`'s doc comment) or the list having just been cleared
        // by a load already handled via the mirror below, never a real "deselect everything"
        // gesture this app needs to support.
        .onChange(of: localFileSelection) { _, newValue in
            guard !newValue.isEmpty else { return }
            appState.updateFileSelection(newValue)
            // Only a real click/arrow should steal focus — a repo/commit switch's auto-selected
            // first file lands here too (via the mirror below assigning `localFileSelection`),
            // and that one must leave `focusedColumn` wherever it already was.
            guard pendingProgrammaticFileSelection != newValue else {
                pendingProgrammaticFileSelection = nil
                return
            }
            // See `BranchListView`'s matching comment — a plain click doesn't reliably flip
            // `isFocused` true on its own, so claim `focusedColumn` here to force real AppKit
            // first-responder status onto this list instead of leaving it on the sidebar.
            appState.focusedColumn = .files
        }
        // Selection changed for a reason other than the user clicking/arrowing a row (a fresh
        // load's auto-selected first file, switching repos/sources, discarding the selected
        // file, etc.) — mirror it into the local state that actually drives the table view,
        // snapping instead of animating since this is a full jump.
        .onChange(of: appState.selectedFilePaths) { _, newValue in
            guard localFileSelection != newValue else { return }
            pendingProgrammaticFileSelection = newValue
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                localFileSelection = newValue
            }
        }
    }

    /// Top inset for the header title's first line. Chosen to sit where a single centred line
    /// of `.font(.headline)` lands inside `ColumnLayout.headerHeight`, so the first line stays
    /// put whether or not the title is expanded — top-aligning both states (rather than letting
    /// `minHeight` centre the collapsed line) is what keeps it from jumping a couple of px up
    /// when the extra lines appear and eat the centring slack.
    private static let headerTitleTopInset: CGFloat = 11

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(headerTitle)
                    .font(.headline)
                    .lineLimit(isTitleExpanded ? nil : 1)
                    .textSelection(.enabled)
                    .truncationTooltip(headerTitle, isEnabled: !isTitleExpanded, font: .preferredFont(forTextStyle: .headline))
                    .background(isTitleExpanded ? nil : titleTruncationProbe)
                // Hidden until expanded, so the header stays a single line by default.
                if isTitleExpanded, !headerDescription.isEmpty {
                    Text(headerDescription)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            if isTitleTruncated || isTitleExpanded || !headerDescription.isEmpty {
                Button {
                    isTitleExpanded.toggle()
                } label: {
                    Image(systemName: "arrow.up.and.down.text.horizontal")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isTitleExpanded ? "Collapse commit message" : "Expand commit message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, Self.headerTitleTopInset)
        .padding(.bottom, isTitleExpanded ? 8 : 0)
        .frame(maxWidth: .infinity, minHeight: ColumnLayout.headerHeight, alignment: .topLeading)
        .onChange(of: headerTitle) { _, _ in isTitleExpanded = false }
    }

    /// Measures `headerTitle`'s ideal (untruncated) single-line width against the space actually
    /// available to it, so the expand button only appears when the title is genuinely cut off.
    /// This one probe is a single instance (not per row), so its cost is negligible.
    private var titleTruncationProbe: some View {
        GeometryReader { visibleGeo in
            Text(headerTitle)
                .font(.headline)
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .background(
                    GeometryReader { idealGeo in
                        Color.clear
                            .onAppear {
                                isTitleTruncated = idealGeo.size.width > visibleGeo.size.width + 0.5
                            }
                            .onChange(of: idealGeo.size.width) { _, newValue in
                                isTitleTruncated = newValue > visibleGeo.size.width + 0.5
                            }
                            .onChange(of: visibleGeo.size.width) { _, newValue in
                                isTitleTruncated = idealGeo.size.width > newValue + 0.5
                            }
                    }
                )
        }
    }

    private var headerDescription: String {
        guard case .commit(let commit) = appState.selectedSource else { return "" }
        return commit.body
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
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    /// `.contextMenu(forSelectionType:)` hands us the effective target set already — the live
    /// multi-selection if the right-clicked row is part of it, otherwise just that row — so this
    /// only has to resolve paths back to `ChangedFile`s. Built lazily, once, on right-click.
    @ViewBuilder
    private func contextMenuItems(forPaths paths: Set<String>) -> some View {
        let files = appState.changedFiles.filter { paths.contains($0.path) }
        if let file = files.first, files.count == 1 {
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
                Menu("Ignore…") {
                    Button("Ignore File") {
                        appState.ignoreFile(file)
                    }
                    if let ext = fileExtension(for: file) {
                        Button("Ignore All .\(ext) Files") {
                            appState.ignorePatterns(["*.\(ext)"])
                        }
                    }
                    let folders = ancestorFolders(for: file.path)
                    if !folders.isEmpty {
                        Divider()
                        ForEach(Array(folders.enumerated()), id: \.offset) { index, folder in
                            Button(index == 0 ? "Ignore Folder \(folder)" : "Ignore Parent Folder \(folder)") {
                                appState.ignorePatterns(["/\(folder)/"])
                            }
                        }
                    }
                }
            }
        } else if files.count > 1 {
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

    private func fileExtension(for file: ChangedFile) -> String? {
        let ext = (file.path as NSString).pathExtension
        return ext.isEmpty ? nil : ext
    }

    /// Ancestor folders of `path`, deepest (immediate parent) first, walking up to the repo root.
    /// Empty if the file sits at the repo root.
    private func ancestorFolders(for path: String) -> [String] {
        var components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return [] }
        components.removeLast()
        guard !components.isEmpty else { return [] }
        return stride(from: components.count, through: 1, by: -1).map {
            components.prefix($0).joined(separator: "/")
        }
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
    /// Owned by `ChangedFilesView` so its column-navigation key handlers and its `isFocused`
    /// reclaim logic can see when a commit field has focus and back off.
    @Binding var focusedField: CommitField?

    /// True while either field has focus. Kept separately from `focusedField` (rather than
    /// derived from it) so the collapse can be deferred — clicking from the summary into the
    /// description can pass through a momentary `nil` focus, and collapsing on that would yank
    /// the description field out from under the very click meant to focus it.
    @State private var isEditing = false
    @State private var collapseTask: Task<Void, Never>?
    @Environment(\.displayScale) private var displayScale

    private static let cornerRadius: CGFloat = 18
    private static let expandAnimation = Animation.smooth(duration: 0.25)

    /// At rest with no description this is the same single-line pill as a plain message field;
    /// focusing it (or a description already being there) grows it into the divided box.
    private var isExpanded: Bool {
        isEditing || !appState.commitDescription.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            messageBox

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
        .onChange(of: focusedField) { _, field in
            if field != nil {
                collapseTask?.cancel()
                isEditing = true
                // Set directly rather than through `ChangedFilesView.isFocused` — see that
                // view's own `onChange(of: appState.focusedColumn)` for why routing this through
                // the List's focus state instead would just reclaim the field right back.
                appState.focusedColumn = .files
            } else {
                scheduleCollapse()
            }
        }
        .onDisappear {
            collapseTask?.cancel()
        }
    }

    /// Two separate fields (each scrolling on its own) sharing one glass shape, divided by a
    /// hairline so they read as a single input.
    ///
    /// - Summary: Return commits (never inserts a newline — the subject is one line), Tab moves
    ///   to the description. Grows once to a second line for a long summary, then scrolls.
    /// - Description: Return inserts a newline, Shift+Tab moves back to the summary. Fixed three
    ///   lines tall; longer text scrolls.
    /// - Either: Cmd+Return commits.
    private var messageBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            CommitTextField(
                text: $appState.commitMessage,
                placeholder: isExpanded ? "Commit summary" : "Commit message",
                font: .systemFont(ofSize: NSFont.systemFontSize),
                field: .summary,
                focus: $focusedField,
                maxLines: 2,
                isSingleParagraph: true,
                onSubmit: commitIfPossible,
                onCommandReturn: commitIfPossible
            )

            if isExpanded {
                Rectangle()
                    .fill(.separator)
                    // One device pixel — 0.5pt on Retina.
                    .frame(height: 1 / displayScale)
                    .padding(.horizontal, CommitTextField.horizontalInset)
                    .transition(.opacity)

                CommitTextField(
                    text: $appState.commitDescription,
                    placeholder: "Description (optional)",
                    font: .preferredFont(forTextStyle: .callout),
                    textColor: .secondaryLabelColor,
                    field: .description,
                    focus: $focusedField,
                    minLines: 3,
                    maxLines: 3,
                    onCommandReturn: commitIfPossible
                )
                .transition(.opacity)
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        // Keeps the scrolling text views inside the rounded corners.
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .animation(Self.expandAnimation, value: isExpanded)
    }

    private func commitIfPossible() {
        guard canCommit else { return }
        appState.commitOrCompleteMerge()
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, focusedField == nil else { return }
            isEditing = false
        }
    }

    private var checkedCount: Int {
        appState.checkedFilePaths.count
    }

    private var hasUnresolvedConflicts: Bool {
        appState.changedFiles.contains { $0.status == .conflicted }
    }

    private var canCommit: Bool {
        guard !appState.isCommitting else { return false }
        let hasMessage = !appState.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if appState.isMergeInProgress {
            return hasMessage && !hasUnresolvedConflicts
        }
        return checkedCount > 0 && hasMessage
    }

    /// While a commit is in flight the label is just a spinner — a big commit takes long
    /// enough that a static label reads as an unresponsive button.
    @ViewBuilder
    private var commitButtonLabel: some View {
        if appState.isCommitting {
            ProgressView()
                .controlSize(.small)
        } else if appState.isMergeInProgress {
            Text("Complete Merge")
        } else {
            let branchName = appState.selectedBranch?.name ?? "…"
            let suffix = checkedCount == 1 ? "" : "s"
            Text("Commit \(checkedCount) file\(suffix) to \(Text(branchName).bold())")
        }
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
                Button(role: .destructive) {
                    appState.discardStash()
                } label: {
                    buttonLabel(
                        title: "Discard", busyTitle: "Discarding\u{2026}", systemImage: "xmark.bin",
                        isBusy: appState.busyOperation == .discarding
                    )
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)

                Button {
                    appState.restoreStash()
                } label: {
                    buttonLabel(
                        title: "Restore", busyTitle: "Restoring\u{2026}", systemImage: "arrow.up.bin",
                        isBusy: appState.busyOperation == .restoring
                    )
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
            }
            .frame(maxWidth: .infinity)
            .disabled(appState.isRepositoryBusy)
        }
        .padding(10)
    }

    /// Swaps the icon for a spinner and the title for its "-ing…" form while that operation runs
    /// — git reports no progress for `stash apply`, so there's no count to show, but on a big
    /// stash a static label otherwise reads as a dead button.
    private func buttonLabel(title: String, busyTitle: String, systemImage: String, isBusy: Bool) -> some View {
        HStack(spacing: 6) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                Text(busyTitle)
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

/// Toolbar shown when the selected commit is the branch's own tip and hasn't reached `origin` yet
/// (`ChangedFilesList.isNewestUnpushedCommit`) — offers to undo it, landing its changes back on
/// "Uncommitted Changes" (`AppState.undoLastCommit()`'s `reset --soft` plus the usual
/// post-refresh selection heuristic), or push it straight up. The push button only appears at all
/// when an `origin` remote actually exists to push to.
private struct UnpushedCommitFooterView: View {
    @Bindable var appState: AppState

    private enum Panel { case buttons, toast }

    /// How long each half of the buttons ⇄ toast swap takes. The outgoing panel fully
    /// dissolves first, *then* the incoming one materializes — never both at once.
    private static let fadeDuration: TimeInterval = 0.3

    /// Which panel is currently (or becoming) visible. `nil` mid-swap, while the outgoing
    /// panel has dissolved and before the incoming one starts.
    @State private var visiblePanel: Panel?
    /// Which panel sizes the footer. Only switched while both panels are invisible, so the
    /// height change between the buttons' and the toast's sizes rides on the incoming fade.
    @State private var layoutPanel: Panel = .buttons
    @State private var hasAppeared = false

    var body: some View {
        // Both panels stay mounted and are faded via `MaterializeModifier` directly rather than
        // inserted/removed with transitions: an `if/else` swap would leave the footer at zero
        // height between the two phases. Deliberately no `GlassEffectContainer` either — inside
        // one, the buttons' glass morphs into the toast's green glass instead of dissolving.
        ZStack(alignment: .top) {
            HStack(spacing: 8) {
                Button {
                    appState.undoLastCommit()
                } label: {
                    Label("Undo Commit", systemImage: "arrow.uturn.backward")
                        .materializeBlur()
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
                        .materializeBlur()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(appState.isSyncing)
                }
            }
            .frame(maxWidth: .infinity)
            .modifier(panelAppearance(.buttons))

            PushSuccessToastView()
                .modifier(panelAppearance(.toast))
        }
        .padding(10)
        .task(id: appState.pushSucceeded) {
            let target: Panel = appState.pushSucceeded ? .toast : .buttons
            // First appearance: snap straight to the right panel, no animation.
            guard hasAppeared else {
                hasAppeared = true
                visiblePanel = target
                layoutPanel = target
                return
            }
            withAnimation(.easeInOut(duration: Self.fadeDuration)) { visiblePanel = nil }
            try? await Task.sleep(for: .seconds(Self.fadeDuration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: Self.fadeDuration)) {
                layoutPanel = target
                visiblePanel = target
            }
        }
    }

    private func panelAppearance(_ panel: Panel) -> PanelAppearance {
        // Until the first `.task` run has synced the state, read straight from `pushSucceeded`
        // so the footer's very first frame isn't blank.
        guard hasAppeared else {
            let initial: Panel = appState.pushSucceeded ? .toast : .buttons
            return PanelAppearance(isVisible: initial == panel, ownsLayout: initial == panel)
        }
        return PanelAppearance(isVisible: visiblePanel == panel, ownsLayout: layoutPanel == panel)
    }
}

/// Fades a footer panel in/out with the materialize look, and collapses it out of the layout
/// (height 0, still drawn but invisible) when it isn't the one sizing the footer.
private struct PanelAppearance: ViewModifier {
    let isVisible: Bool
    let ownsLayout: Bool

    func body(content: Content) -> some View {
        content
            .modifier(MaterializeModifier(progress: isVisible ? 1 : 0))
            .frame(height: ownsLayout ? nil : 0, alignment: .top)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}

/// A floating "liquid glass" pill, styled after writetodisk.com/liquid-glass-toast/ using the
/// real `.glassEffect()` modifier with a green tint. Centered rather than stretched full-width,
/// so it reads as a floating toast and not another full-width footer row.
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
            .materializeBlur()
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .glassEffect(.clear.tint(.green.opacity(0.8)), in: .capsule)
            .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
            Spacer(minLength: 0)
        }
    }
}

#Preview("Push Success Toast") {
    ZStack(alignment: .bottom) {
        List {
            ForEach(0..<12) { i in
                Text("fileabcdefghijklmnopqrstuvwxyz_\(i).swift")
            }
        }
        PushSuccessToastView()
            .padding(.bottom, 16)
    }
    .frame(width: 420, height: 200)
}

private extension AnyTransition {
    /// Materializes in and dissolves out in place (blur + fade) — no movement either way.
    static var materialize: AnyTransition {
        .modifier(
            active: MaterializeModifier(progress: 0),
            identity: MaterializeModifier(progress: 1)
        )
    }
}

/// Fades a view with the materialize look. Only the *opacity* is applied here, to the whole
/// view: blurring a view that contains Liquid Glass renders it offscreen, which stops the glass
/// sampling what's behind it — it snaps to a flat, solid fill the moment the transition starts.
/// The blur half is instead published through `materializeProgress` and applied by
/// `materializeBlur()` to just the labels/icons *inside* the glass.
private struct MaterializeModifier: ViewModifier, Animatable {
    /// Blur radius at the fully-dissolved end of the transition.
    static let maxBlur: CGFloat = 8

    /// 1 = fully present, 0 = fully dissolved.
    var progress: Double

    // Animatable so `body` re-runs every frame and the environment value below animates too.
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.materializeProgress, progress)
            .opacity(progress)
    }
}

private extension EnvironmentValues {
    /// The enclosing `MaterializeModifier`'s progress (1 = fully present).
    @Entry var materializeProgress: Double = 1
}

private struct MaterializeBlurModifier: ViewModifier {
    @Environment(\.materializeProgress) private var progress

    func body(content: Content) -> some View {
        content.blur(radius: (1 - progress) * MaterializeModifier.maxBlur)
    }
}

private extension View {
    /// The blur half of the materialize transition — apply to content *inside* a glass shape,
    /// never to the glass itself (see `MaterializeModifier`).
    func materializeBlur() -> some View {
        modifier(MaterializeBlurModifier())
    }
}

/// Toggles `pushSucceeded` on the real footer to replay the buttons → toast → gone transitions.
/// "Push Succeeded" swaps the buttons for the toast; "Remove Footer" mimics the footer
/// itself disappearing once `pushSucceeded` flips back after a push.
#Preview("Unpushed Commit Footer Transitions") {
    @Previewable @State var appState: AppState = {
        let appState = AppState()
        appState.hasOriginRemote = true
        return appState
    }()
    @Previewable @State var showsFooter = true

    VStack(spacing: 0) {
        List {
            ForEach(0..<12) { i in
                Text("fileabcdefghijklmnopqrstuvwxyz_\(i).swift")
            }
        }
        // Same styling as `ChangedFilesList`, so the footer sits over the same background.
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if showsFooter {
                UnpushedCommitFooterView(appState: appState)
                    .transition(.materialize)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showsFooter)

        Divider()
        HStack {
            Button(appState.pushSucceeded ? "Show Buttons" : "Push Succeeded") {
                appState.pushSucceeded.toggle()
            }
            Button(showsFooter ? "Remove Footer" : "Show Footer") {
                showsFooter.toggle()
            }
        }
        .padding(8)
    }
    .frame(width: 420, height: 320)
}
