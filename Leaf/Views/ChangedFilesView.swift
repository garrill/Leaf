import AppKit
import SwiftUI

struct ChangedFilesView: View {
    @Bindable var appState: AppState
    @FocusState private var isFocused: Bool
    /// Focus for the commit message field, tracked here (rather than solely inside
    /// `CommitFooterView`) so `ChangedFilesList`'s own arrow-key/escape column-navigation
    /// handlers and this view's `isFocused` reclaim logic can both check it and back off — see
    /// the comment on `CommitFooterView.isMessageFocused` for why a shared, separately-identified
    /// `@FocusState` is required here instead of letting the field fall under `isFocused`'s scope.
    @FocusState private var isCommitMessageFocused: Bool

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
                isCommitMessageFocused: $isCommitMessageFocused
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
            guard newValue == .files, !isCommitMessageFocused else { return }
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
                Text("Failed to push to:\n") + Text(remote).bold() + Text("\n\(alert.message)")
            } else {
                Text(alert.message)
            }
        }
        // A conflicting stash restore (`AppState.restoreStash()`) — separate from
        // `gitFailureAlert` above since it's not a failure to report so much as a choice about
        // what happens to the now-redundant stash entry once its content is already merged
        // (with conflict markers) into the working tree.
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
    var isCommitMessageFocused: FocusState<Bool>.Binding
    @State private var isTitleExpanded = false
    @State private var isTitleTruncated = false

    var body: some View {
        List(appState.changedFiles, selection: fileSelection) { file in
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
            .tag(file.path)
            .listRowSeparator(.visible)
        }
        .contextMenu(forSelectionType: String.self) { paths in
            contextMenuItems(forPaths: paths)
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
                CommitFooterView(appState: appState, isMessageFocused: isCommitMessageFocused)
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
        .focused(isFocused)
        // Left/right/escape here are column-navigation shortcuts, not something the commit
        // message field should ever see — while it has focus, arrow keys need to move the
        // text cursor and escape needs to do nothing, so all three back off and let the
        // field's own default key handling run instead.
        .onKeyPress(.leftArrow) {
            guard !isCommitMessageFocused.wrappedValue else { return .ignored }
            appState.focusedColumn = .branches
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !isCommitMessageFocused.wrappedValue else { return .ignored }
            appState.focusedColumn = .diff
            return .handled
        }
        .onKeyPress(.escape) {
            guard !isCommitMessageFocused.wrappedValue, isNewestUnpushedCommit, !appState.isPushingCommit else { return .ignored }
            appState.undoLastCommit()
            return .handled
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
            Text(headerTitle)
                .font(.headline)
                .lineLimit(isTitleExpanded ? nil : 1)
                .textSelection(.enabled)
                .truncationTooltip(headerTitle, isEnabled: !isTitleExpanded, font: .preferredFont(forTextStyle: .headline))
                .background(isTitleExpanded ? nil : titleTruncationProbe)
            Spacer(minLength: 0)
            if isTitleTruncated || isTitleExpanded {
                Button {
                    isTitleExpanded.toggle()
                } label: {
                    Image(systemName: "arrow.up.and.down.text.horizontal")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Expand title")
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
                Button("Ignore File") {
                    appState.ignoreFile(file)
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
    /// by returning `nil`. Shift+Return is passed through unmodified — it doesn't submit, and
    /// isn't given any newline-inserting behavior of its own either.
    @State private var returnKeyMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Commit message", text: $appState.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                // The backing `NSTextView` otherwise flashes its (empty) inline text-completion
                // candidates panel — a grey ~200pt rounded rect just below the field — for a
                // single frame when it first becomes first responder. Commit messages carry
                // identifiers/paths/branch names, so suppressing correction here is right anyway.
                .autocorrectionDisabled(true)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .focused(isMessageFocused)
                // `.plain` + the outer padding means the field's own click target is just the
                // text rect — clicks in the padded pill margin fall through and don't focus it.
                // Make the whole pill shape hit-test and route a tap there to the field. A tap
                // landing directly on the `TextField` is handled by its own (descendant) gesture
                // first, so cursor placement still works; this only catches the margin.
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onTapGesture { isMessageFocused.wrappedValue = true }

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
            Text("Commit \(checkedCount) file\(suffix) to ") + Text(branchName).bold()
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
                    Label("Discard", systemImage: "xmark.bin")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)

                Button {
                    appState.restoreStash()
                } label: {
                    Label("Restore", systemImage: "arrow.up.bin")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(10)
    }
}

/// Toolbar shown when the selected commit is the branch's own tip and hasn't reached `origin` yet
/// (`ChangedFilesList.isNewestUnpushedCommit`) — offers to undo it, landing its changes back on
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
