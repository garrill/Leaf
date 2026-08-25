import AppKit
import Foundation

@Observable
final class AppState {
    let sidebarStore = SidebarStore()
    let repoStatusStore = RepoStatusStore()

    var selectedRepoURL: URL?
    /// Which of the four columns currently holds keyboard focus, driving left/right arrow-key
    /// navigation between them (`MainColumn.repos`/`.branches`/`.files` — `.diff` isn't wired up
    /// yet). The source of truth each column's own local `@FocusState` syncs against, since a
    /// separate `NSHostingController` per column (see `MainSplitViewController`) means there's no
    /// single shared `@FocusState` that could drive this directly.
    var focusedColumn: MainColumn?
    var branches: [GitBranch] = []
    var selectedBranch: GitBranch?
    var isDetachedHead = false
    var detachedHeadShortSHA: String?

    var commits: [GitCommit] = []
    var selectedSource: ChangeSource?

    var tags: [GitTag] = []
    /// Commit SHA -> tags pointing at it, recomputed whenever `tags` changes. `BranchListView`
    /// looks this up per row, so a plain per-row linear scan over `tags` would redo the same
    /// grouping work for every commit on screen.
    var tagsByCommitSHA: [String: [GitTag]] {
        Dictionary(grouping: tags, by: \.sha)
    }

    var changedFiles: [ChangedFile] = []
    var uncommittedChangeCount: Int = 0
    var uncommittedLastModifiedDate: Date?
    var stashCount: Int = 0
    /// Files touched by the top-of-stack stash entry — what the "Stashed Changes" row's count
    /// badge shows, as opposed to `stashCount` (number of stash *entries*, used only to decide
    /// whether the row appears at all).
    var stashFileCount: Int = 0
    var selectedFile: ChangedFile?
    /// All files selected in the changed-files list, for shift/cmd multi-select and batch
    /// actions. Always a superset containing `selectedFile` when non-empty.
    var selectedFilePaths: Set<String> = []
    var checkedFilePaths: Set<String> = []
    var commitMessage: String = ""
    /// One in-progress commit message draft per repo, so switching repos doesn't carry text typed
    /// for one repo over to another — saved/restored around `selectedRepoURL` changes in
    /// `selectRepo`/`deselectRepo` rather than making `commitMessage` itself a computed property,
    /// since plenty of call sites just assign into it directly (clearing it after a commit, the
    /// merge-message prefill in `refreshRepositoryState`/`applySnapshot`).
    private var commitMessageDrafts: [URL: String] = [:]
    /// Drives the commit box's "Generate" button spinner/disabled state while
    /// `generateCommitMessage()`'s on-device model call is in flight.
    var isGeneratingCommitMessage = false

    var diffText: String = ""
    var imageDiffOld: Data?
    var imageDiffNew: Data?
    /// True when the current selection's diff was skipped because the file is too large to
    /// render (see `GitRepository.isFileTooLargeToDiff`) — `DiffView` shows a placeholder instead
    /// of ever handing the text to `DiffCodeTextView`.
    var diffFileTooLarge = false
    /// True when "Hide Whitespace Changes" is on and the current selection's diff came back empty
    /// only because every change in it was whitespace-only — distinct from a genuinely empty diff
    /// (`diffText.isEmpty` with this false), so `DiffView` can show an explanatory message instead
    /// of a blank pane.
    var diffOnlyWhitespaceChanges = false
    var errorMessage: String?
    /// Bumped whenever the currently-selected file's on-disk content may have changed out from
    /// under it (see `handleExternalChange`), without the file/source *selection* itself
    /// changing. `DiffView`'s `.task(id:)` includes this in its key so it re-fires — keeping diff
    /// loading triggered from exactly one place instead of also being called directly here,
    /// which could otherwise race a concurrent load already in flight for the same file.
    var diffReloadToken = 0

    var isSyncing = false
    var hasUpstream = false
    var aheadCount = 0
    var behindCount = 0
    /// Whether an `origin` remote is configured — drives whether `CommitFooterView`'s "unpushed
    /// commit" toolbar offers a Push button at all, distinct from `hasUpstream` (a fresh local
    /// branch can lack an upstream yet still have somewhere to push to).
    var hasOriginRemote = false

    /// Drives `UnpushedCommitFooterView`'s push button state, independent of the generic
    /// `isSyncing` (which also covers fetch/pull and just disables buttons). `pushProgressText`
    /// is git's own `--progress` meter (e.g. "Writing objects (5/12)"), reformatted by
    /// `AppState.formatPushProgress(_:)`. `pushSucceeded` briefly flips true after a successful
    /// push so the footer can show a checkmark before it animates away; `pushErrorMessage` is
    /// separate from the generic `errorMessage` (which `DiffView` also reads inline) so a push
    /// failure always surfaces as its own alert instead.
    var isPushingCommit = false
    var pushProgressText: String?
    var pushSucceeded = false
    var pushErrorMessage: String?

    var isMergeInProgress = false
    var mergeMessage: String?

    /// `cloneProgressText` mirrors `pushProgressText`'s treatment of git's `--progress` meter
    /// (via `AppState.formatProgressLine(_:)`) for `CloneRepoSheet`'s status line.
    /// `cloneProgressFraction` drives its progress bar, via `cloneStageFraction(for:)`, and is
    /// clamped to never decrease (see `cloneRepo`) since that mapping isn't itself monotonic.
    var isCloning = false
    var cloneErrorMessage: String?
    var cloneProgressText: String?
    var cloneProgressFraction: Double?

    var renamingFolderID: UUID?
    var renamingRepoID: UUID?
    var isCloneSheetPresented = false
    var isNewBranchSheetPresented = false
    var newBranchErrorMessage: String?
    var isNewTagSheetPresented = false
    var newTagErrorMessage: String?
    /// Which commit "Tag Commit…" was invoked on — set right before presenting the sheet, since
    /// tag creation targets whatever commit was right-clicked rather than always HEAD.
    var newTagTargetCommit: GitCommit?

    /// GitHub owner (user/org) of the selected repo's `origin` remote, shown as the window
    /// subtitle. `nil` for non-GitHub remotes or repos with no `origin`.
    var repoOwner: String?

    private var currentRepository: GitRepository? {
        selectedRepoURL.map { GitRepository(rootURL: $0) }
    }

    /// The sidebar's own record for the selected repo — separate from `currentRepository`
    /// (a plain `GitRepository` git-command wrapper), needed for anything that touches sidebar
    /// metadata (display name override, icon, rename) rather than the git repo itself.
    private var selectedSidebarRepo: SidebarRepo? {
        guard let url = selectedRepoURL else { return nil }
        return sidebarStore.repos.first { $0.path == url.path }
    }

    private var repoWatcher: RepoWatcher?

    private struct ChangedFilesCacheValue {
        let files: [ChangedFile]
        let statusEntries: [ChangedFile]
    }

    private struct DiffCacheKey: Hashable {
        let source: ChangeSource
        let file: ChangedFile
        let ignoreWhitespace: Bool
    }

    private struct DiffCacheValue {
        let text: String
        let onlyWhitespaceChanges: Bool
    }

    private struct RepositorySnapshot {
        let owner: String?
        let isMergeInProgress: Bool
        let mergeMessage: String?
        let branches: [GitBranch]
        let selectedBranch: GitBranch?
        let detachedHeadShortSHA: String?
        let commits: [GitCommit]
        let tags: [GitTag]
        let aheadBehind: (ahead: Int, behind: Int)?
        let stashCount: Int
        let stashFileCount: Int
        let statusEntries: [ChangedFile]
        let errorMessage: String?
        let hasOriginRemote: Bool
    }

    /// Selection data is immutable for a particular repository state. Keeping it here makes
    /// back/forward history navigation and revisiting a file instantaneous, while the watcher
    /// below clears it as soon as Git or the working tree changes.
    private var changedFilesCache: [ChangeSource: ChangedFilesCacheValue] = [:]
    private var diffTextCache: [DiffCacheKey: DiffCacheValue] = [:]
    private var selectionCacheGeneration = 0
    private var repositoryRefreshGeneration = 0
    private var uncommittedSummaryGeneration = 0

    private func invalidateSelectionCaches() {
        selectionCacheGeneration &+= 1
        uncommittedSummaryGeneration &+= 1
        changedFilesCache.removeAll()
        diffTextCache.removeAll()
    }

    func addRepoViaPicker() {
        addRepoViaPicker(intoFolder: nil)
    }

    /// Same picker flow as `addRepoViaPicker()`, but adds the chosen repo directly into `folderID`
    /// instead of the top level.
    func addRepoViaPicker(intoFolder folderID: UUID?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Repository"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard sidebarStore.addRepo(at: url, intoFolder: folderID) else {
            presentNotARepositoryAlert(for: [url.lastPathComponent])
            return
        }
        selectRepo(url)
    }

    /// Shown when one or more folders added via the picker or a Finder drag turn out not to be
    /// git repositories (no `.git` entry) — those are skipped rather than added.
    func presentNotARepositoryAlert(for folderNames: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if folderNames.count == 1 {
            alert.messageText = "\"\(folderNames[0])\" Is Not a Git Repository"
            alert.informativeText = "This folder does not contain a git repository, so it wasn't added."
        } else {
            alert.messageText = "Some Folders Are Not Git Repositories"
            alert.informativeText = "The following folders don't contain a git repository, so they weren't added:\n\n"
                + folderNames.joined(separator: "\n")
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Clones `urlString` into a new folder (named after the repo) under `destinationParent`,
    /// then registers and selects it, mirroring `addRepoViaPicker()`'s add-then-select flow.
    /// `completion` reports success so the presenting sheet knows whether to dismiss.
    func cloneRepo(urlString: String, destinationParent: URL, completion: @escaping (Bool) -> Void) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !isCloning else {
            completion(false)
            return
        }
        let destination = destinationParent.appendingPathComponent(GitRepository.repoName(fromURLString: trimmedURL))
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            cloneErrorMessage = "A folder named \"\(destination.lastPathComponent)\" already exists at that location."
            completion(false)
            return
        }

        isCloning = true
        cloneErrorMessage = nil
        cloneProgressText = nil
        cloneProgressFraction = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try GitRepository.clone(from: trimmedURL, into: destination) { [weak self] line in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.cloneProgressText = Self.formatProgressLine(line)
                            if let fraction = Self.cloneStageFraction(for: line) {
                                // Clamped to never decrease: within the "remote" macro-stage,
                                // git's own sub-phases (enumerating/counting/compressing) each
                                // restart their *own* 0-100%, which would otherwise visibly snap
                                // the bar backward every time git moves to the next sub-phase.
                                self.cloneProgressFraction = max(self.cloneProgressFraction ?? 0, fraction)
                            }
                        }
                    }
                }.value
                await MainActor.run {
                    self.isCloning = false
                    self.cloneProgressText = nil
                    self.cloneProgressFraction = nil
                    self.sidebarStore.addRepo(at: destination)
                    self.selectRepo(destination)
                    completion(true)
                }
            } catch {
                await MainActor.run {
                    self.isCloning = false
                    self.cloneProgressText = nil
                    self.cloneProgressFraction = nil
                    self.cloneErrorMessage = error.localizedDescription
                    completion(false)
                }
            }
        }
    }

    func selectRepo(_ url: URL) {
        // `SidebarOutlineView.updateNSView` unconditionally calls `reloadPreservingState()` on
        // every re-render (including ones triggered by unrelated state, like a commit-history
        // selection settling), and `NSOutlineView.reloadData()` can itself fire a spurious
        // `outlineViewSelectionDidChange` for the row that's already selected, since its
        // underlying item objects get recreated. Without this guard, that redundant reselect ran
        // the fully-synchronous `refreshRepositoryState()` (branches, commits, status, a
        // `git remote get-url origin` call) on the main thread on every such reload — a real,
        // confirmed-via-Instruments source of main-thread hangs completely unrelated to whatever
        // was actually being navigated at the time.
        guard url != selectedRepoURL else { return }
        if let previousURL = selectedRepoURL {
            commitMessageDrafts[previousURL] = commitMessage
        }
        commitMessage = commitMessageDrafts[url] ?? ""
        selectedRepoURL = url
        // Clear the previous repo's file list/diff immediately rather than leaving them on
        // screen until the new repo's debounced/detached loads complete — otherwise columns 3
        // and 4 briefly show one repo's files/diff next to column 2's already-updated branches.
        changedFiles = []
        selectedFile = nil
        selectedFilePaths = []
        checkedFilePaths = []
        diffText = ""
        imageDiffOld = nil
        imageDiffNew = nil
        errorMessage = nil
        invalidateSelectionCaches()
        refreshRepositoryState()
        repoWatcher = RepoWatcher(url: url) { [weak self] in
            self?.handleExternalChange()
        }
    }

    func deselectRepo() {
        if let previousURL = selectedRepoURL {
            commitMessageDrafts[previousURL] = commitMessage
        }
        commitMessage = ""
        selectedRepoURL = nil
        repoWatcher = nil
        errorMessage = nil
        invalidateSelectionCaches()
        refreshRepositoryState()
    }

    /// Removes the selected repo from the sidebar, matching `RepoRowView`'s per-row "Remove from
    /// Sidebar" context-menu action (same confirmation alert, same optional move-to-Bin); this is
    /// the Repository menu's equivalent for whichever repo is currently selected.
    func removeSelectedRepo() {
        guard let repo = selectedSidebarRepo else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Are you sure you want to remove \u{201C}\(repo.displayName)\u{201D} from Leaf?"

        let checkbox = NSButton(checkboxWithTitle: "Also move this repository to the Bin", target: nil, action: nil)
        checkbox.state = .off
        alert.accessoryView = checkbox

        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let moveToBin = checkbox.state == .on
        sidebarStore.removeRepo(id: repo.id)
        deselectRepo()
        if moveToBin {
            try? FileManager.default.trashItem(at: repo.url, resultingItemURL: nil)
        }
    }

    func revealSelectedRepoInFinder() {
        guard let url = selectedRepoURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openSelectedRepoInDefaultApplication() {
        guard let url = selectedRepoURL else { return }
        LeafSettings.open(url)
    }

    /// Puts the selected repo's sidebar row into rename mode — `SidebarOutlineView`/`RepoRowView`
    /// watch `renamingRepoID` and do the actual text-field/commit work.
    func startRenamingSelectedRepo() {
        guard let repo = selectedSidebarRepo else { return }
        renamingRepoID = repo.id
    }

    /// Mirrors `RepoRowView.pickIcon()`, but for whichever repo is currently selected rather than
    /// whichever row was right-clicked.
    func chooseIconForSelectedRepo() {
        guard let repo = selectedSidebarRepo, let url = selectedRepoURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = url
        panel.prompt = "Choose Icon"
        guard panel.runModal() == .OK, let iconURL = panel.url else { return }
        sidebarStore.updateRepo(id: repo.id, displayName: repo.displayNameOverride, iconPath: iconURL.path)
    }

    func selectBranch(_ branch: GitBranch) {
        guard let repo = currentRepository else { return }
        guard !branch.isCurrent else {
            refreshRepositoryState()
            return
        }
        // `checkout`/`stashChanges`/`restoreStash` all shell out synchronously (`Process.
        // waitUntilExit()`); running them inline on the main thread would freeze the whole UI for
        // the duration of the call on a branch switch touching many files, so the actual git work
        // happens in `Task.detached`, same pattern as `fetchRemote`/`pullCurrentBranch`.
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Re-read the branch list from git before attempting the checkout — `self.branches`
            // can be stale (e.g. someone deleted the branch outside Leaf, or it was only removed
            // on the remote and never refreshed locally), and there was previously no other way
            // to refresh it short of switching repos. This also lets a deleted branch be reported
            // with a clear message instead of a raw git pathspec error, and drops it from the menu
            // immediately rather than leaving it clickable until the next unrelated refresh.
            let freshBranches = await Task.detached(priority: .userInitiated) { (try? repo.branches()) ?? [] }.value
            self.branches = freshBranches
            guard freshBranches.contains(where: { $0.name == branch.name }) else {
                self.errorMessage = "Branch \u{201C}\(branch.name)\u{201D} no longer exists. It may have been deleted."
                return
            }
            do {
                try await Task.detached(priority: .userInitiated) { try repo.checkout(branch: branch.name) }.value
                self.errorMessage = nil
            } catch let GitError.commandFailed(message) where Self.isLocalChangesCheckoutFailure(message) {
                // Checkout is blocked by a dirty working tree — ask the user whether to bring
                // those changes along to the new branch, stash them behind on the current one,
                // or cancel the switch entirely, rather than silently guessing.
                switch Self.promptForDirtyCheckout(to: branch.name) {
                case .bringChanges:
                    do {
                        let result = try await Task.detached(priority: .userInitiated) { () throws -> GitRepository.StashRestoreResult in
                            try repo.stashChanges(paths: [], includeUntracked: true)
                            try repo.checkout(branch: branch.name)
                            return try repo.restoreStash()
                        }.value
                        self.errorMessage = result == .conflicts
                            ? "Bringing your changes to \(branch.name) caused conflicts. Resolve them in Working Changes."
                            : nil
                    } catch {
                        self.errorMessage = error.localizedDescription
                    }
                case .stashChanges:
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try repo.stashChanges(paths: [], includeUntracked: true)
                            try repo.checkout(branch: branch.name)
                        }.value
                        self.errorMessage = nil
                    } catch {
                        self.errorMessage = error.localizedDescription
                    }
                case .cancel:
                    break
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.refreshRepositoryState()
        }
    }

    /// Deletes a local branch after confirming — this is a force delete (`git branch -D`), so the
    /// confirmation alert is the only safety net; there's no separate "unmerged changes" warning.
    func deleteBranch(_ branch: GitBranch) {
        guard let repo = currentRepository, !branch.isCurrent else { return }
        guard Self.confirmDestructiveAction(
            title: "Delete branch \u{201C}\(branch.name)\u{201D}?",
            message: "This action cannot be undone.",
            confirmButtonTitle: "Delete"
        ) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) { try repo.deleteBranch(named: branch.name) }.value
                self.errorMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.refreshRepositoryState()
        }
    }

    /// Matches git's checkout-blocked-by-local-changes wording (both the tracked- and
    /// untracked-file variants) so the dirty-checkout prompt only fires for that specific
    /// failure, not any other reason `checkout` might fail (bad ref, detached HEAD oddities, etc).
    private static func isLocalChangesCheckoutFailure(_ message: String) -> Bool {
        message.contains("Please commit your changes or stash them before you switch branches")
            || message.contains("The following untracked working tree files would be overwritten")
    }

    private enum DirtyCheckoutChoice {
        case bringChanges
        case stashChanges
        case cancel
    }

    private static func promptForDirtyCheckout(to branchName: String) -> DirtyCheckoutChoice {
        let alert = NSAlert()
        alert.messageText = "You have uncommitted changes"
        alert.informativeText = "Bring your changes to \"\(branchName)\", leave them stashed on the current branch, or cancel switching branches."
        alert.addButton(withTitle: "Bring Changes")
        alert.addButton(withTitle: "Stash Changes")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .bringChanges
        case .alertSecondButtonReturn: return .stashChanges
        default: return .cancel
        }
    }

    /// Creates a new branch off HEAD and switches to it. `completion` reports success so the
    /// sheet knows whether to dismiss itself, mirroring `cloneRepo`'s callback shape.
    func createBranch(named name: String, completion: @escaping (Bool) -> Void) {
        guard let repo = currentRepository else { completion(false); return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(false); return }
        do {
            try repo.createBranch(named: trimmed)
            newBranchErrorMessage = nil
            refreshRepositoryState()
            completion(true)
        } catch {
            newBranchErrorMessage = error.localizedDescription
            completion(false)
        }
    }

    /// Creates a lightweight tag at the given commit. `completion` reports success so the sheet
    /// knows whether to dismiss itself, mirroring `createBranch`.
    func createTag(named name: String, at sha: String, completion: @escaping (Bool) -> Void) {
        guard let repo = currentRepository else { completion(false); return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(false); return }
        do {
            try repo.createTag(named: trimmed, at: sha)
            newTagErrorMessage = nil
            refreshRepositoryState()
            completion(true)
        } catch {
            newTagErrorMessage = error.localizedDescription
            completion(false)
        }
    }

    func deleteTag(_ tag: GitTag) {
        guard let repo = currentRepository else { return }
        do {
            try repo.deleteTag(named: tag.name)
            errorMessage = nil
            refreshRepositoryState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Records the selection and clears the previous source's file selection/diff — `ChangedFilesView`'s
    /// `.task(id: appState.selectedSource)` is what actually reloads the changed-files list, off the
    /// main thread and automatically cancelled/replaced by SwiftUI itself if the selection changes
    /// again before it finishes. Clearing `selectedFile`/`diffText` here is still just plain
    /// assignment (never coupled to, or delayed by, that load) but keeps `DiffView`'s own
    /// `.task(id:)` from ever pairing the *previous* source's file with the *new* source — without
    /// it, e.g. switching commits could fire a diff load for a file that doesn't exist in the newly
    /// selected commit, flashing blank/wrong content until the changed-files reload catches up.
    func selectSource(_ source: ChangeSource?) {
        selectedSource = source
        selectedFile = nil
        selectedFilePaths = []
        diffText = ""
        imageDiffOld = nil
        imageDiffNew = nil
    }

    /// Just records the selection — `DiffView`'s `.task(id:)` loads the diff text; see
    /// `selectSource`.
    func selectFile(_ file: ChangedFile?) {
        selectedFile = file
        selectedFilePaths = file.map { [$0.path] } ?? []
    }

    /// Updates the multi-selection from the list's native shift/cmd-click selection. The diff
    /// pane keeps following a single "primary" file: whichever one was just added to the
    /// selection, or the sole remaining one if the selection shrank back down to one.
    func updateFileSelection(_ paths: Set<String>) {
        let previousPaths = selectedFilePaths
        selectedFilePaths = paths
        guard !paths.isEmpty else {
            selectedFile = nil
            return
        }
        let added = paths.subtracting(previousPaths)
        let primaryPath = added.first ?? (paths.count == 1 ? paths.first : selectedFile?.path)
        let primaryFile = changedFiles.first(where: { $0.path == primaryPath }) ?? changedFiles.first(where: { paths.contains($0.path) })
        selectedFile = primaryFile
    }

    /// Blocking confirmation for an action that would lose work with no in-app undo. Mirrors
    /// `promptForDirtyCheckout`'s plain (non-sheet) `NSAlert` usage — these are all triggered
    /// from imperative button/menu actions on `AppState`, not from a SwiftUI view that could
    /// hold its own `@State` alert-presentation flag.
    private static func confirmDestructiveAction(title: String, message: String, confirmButtonTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    func discardChanges(for file: ChangedFile) {
        discardChanges(for: [file])
    }

    func discardChanges(for files: [ChangedFile]) {
        guard let repo = currentRepository, !files.isEmpty else { return }
        // Untracked files have no commit to fall back to — they're moved to the Bin outright,
        // unlike tracked files which are also moved to the Bin but then revert to the last
        // commit. Call that out explicitly rather than lumping both under one generic warning.
        let hasUntracked = files.contains { $0.status == .untracked }
        let title = files.count == 1
            ? "Discard changes to \u{201C}\((files[0].path as NSString).lastPathComponent)\u{201D}?"
            : "Discard changes to \(files.count) files?"
        let message = hasUntracked
            ? "Untracked files will be moved to the Bin; tracked files will be moved to the Bin and revert to their last committed version."
            : "Files will be moved to the Bin and revert to their last committed version."
        guard Self.confirmDestructiveAction(title: title, message: message, confirmButtonTitle: "Discard") else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) { try repo.discardChanges(for: files) }.value
                self.errorMessage = nil
                await self.loadChangedFilesForCurrentSelection()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Stashes the given files (`git stash push`), including untracked ones if any target file
    /// is untracked. Uses `refreshRepositoryState()` rather than the lighter
    /// `loadChangedFilesForCurrentSelection` — stashing can empty out `.workingChanges` entirely,
    /// and the selection needs to re-derive through `refreshRepositoryState()`'s fallback chain
    /// (which now checks the stash before falling through to history).
    func stashChanges(for files: [ChangedFile]) {
        guard let repo = currentRepository, !files.isEmpty else { return }
        let includeUntracked = files.contains { $0.status == .untracked }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try repo.stashChanges(paths: files.map(\.path), includeUntracked: includeUntracked)
                }.value
                self.errorMessage = nil
                self.refreshRepositoryState()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Applies and drops the top-of-stack stash. On a conflicting pop, the stash is left in
    /// place by git and the working tree gets conflict markers with no `MERGE_HEAD` — landing on
    /// Uncommitted Changes lets the existing per-row "Mark Resolved" flow handle it like any
    /// other on-disk conflict, rather than needing a separate stash-conflict UI.
    func restoreStash() {
        guard let repo = currentRepository else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { try repo.restoreStash() }.value
                self.errorMessage = nil
                self.refreshRepositoryState()
                if result == .conflicts {
                    self.selectSource(.workingChanges)
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func discardStash() {
        guard let repo = currentRepository else { return }
        guard Self.confirmDestructiveAction(
            title: "Discard stashed changes?",
            message: "This cannot be undone. The stashed changes will be permanently deleted.",
            confirmButtonTitle: "Discard"
        ) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) { try repo.discardStash() }.value
                self.errorMessage = nil
                self.refreshRepositoryState()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func ignoreFile(_ file: ChangedFile) {
        ignoreFiles([file])
    }

    func ignoreFiles(_ files: [ChangedFile]) {
        guard let repo = currentRepository, !files.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) { try repo.ignoreFiles(files) }.value
                self.errorMessage = nil
                await self.loadChangedFilesForCurrentSelection()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func setChecked(_ isChecked: Bool, for path: String) {
        if isChecked {
            checkedFilePaths.insert(path)
        } else {
            checkedFilePaths.remove(path)
        }
    }

    func commitCheckedChanges() {
        guard let repo = currentRepository else { return }
        let paths = changedFiles.filter { checkedFilePaths.contains($0.path) }.map(\.path)
        let unstagePaths = changedFiles.filter { !checkedFilePaths.contains($0.path) }.map(\.path)
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paths.isEmpty, !message.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try repo.commit(message: message, paths: paths, unstagePaths: unstagePaths)
                }.value
                self.commitMessage = ""
                self.errorMessage = nil
                self.refreshRepositoryState()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Undoes the repo's most recent commit — only ever called from the "unpushed commit"
    /// toolbar (`UnpushedCommitFooterView`), which only shows for that exact commit, but this
    /// re-checks it's still `commits.first` in case a background refresh raced the button tap.
    /// `GitRepository.undoLastCommit()`'s `reset --soft` leaves the index/working tree exactly as
    /// they were pre-commit, and `refreshRepositoryState()`'s usual selection heuristic then
    /// naturally lands back on `.workingChanges` showing those same changes again.
    func undoLastCommit() {
        guard let repo = currentRepository,
              case .commit(let commit) = selectedSource,
              commits.first?.sha == commit.sha else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) { try repo.undoLastCommit() }.value
                // The subject line is all `GitCommit` carries — enough to let the user immediately
                // re-commit as-is, or edit/expand it, rather than retyping from scratch.
                self.commitMessage = commit.summary
                self.errorMessage = nil
                self.refreshRepositoryState()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Fills `commitMessage` from an on-device model reading the diff of the uncommitted changes
    /// (whichever files are checked, or every changed file if none are), following the style
    /// configured in Settings (`LeafSettings.commitMessageStyleKey`/`customCommitInstructionsKey`).
    /// Called from the commit box's "Generate" button (`CommitFooterView`).
    func generateCommitMessage() {
        guard let repo = currentRepository else { return }
        let files = changedFiles.filter { checkedFilePaths.isEmpty || checkedFilePaths.contains($0.path) }
        guard !files.isEmpty else {
            errorMessage = "There are no uncommitted changes to summarize."
            return
        }

        let styleRawValue = LeafSettings.store.string(forKey: LeafSettings.commitMessageStyleKey) ?? LeafSettings.defaultCommitMessageStyle.rawValue
        let style = CommitMessageStyle(rawValue: styleRawValue) ?? LeafSettings.defaultCommitMessageStyle
        let customInstructions = LeafSettings.store.string(forKey: LeafSettings.customCommitInstructionsKey) ?? ""

        isGeneratingCommitMessage = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isGeneratingCommitMessage = false }
            do {
                let diff = try await Task.detached(priority: .userInitiated) {
                    files.map { (try? repo.diff(for: $0)) ?? "" }.joined(separator: "\n\n")
                }.value
                let message = try await CommitMessageGenerator.generate(diff: diff, style: style, customInstructions: customInstructions)
                self.commitMessage = message
                self.errorMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Calls `completeMerge()` while a merge is in progress, otherwise the normal commit.
    /// The shared entry point for the commit footer's single button.
    func commitOrCompleteMerge() {
        if isMergeInProgress {
            completeMerge()
        } else {
            commitCheckedChanges()
        }
    }

    func mergeBranch(_ branch: GitBranch) {
        guard let repo = currentRepository, !isSyncing else { return }
        isSyncing = true
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) { try repo.merge(branch: branch.name) }.value
                await MainActor.run {
                    self.errorMessage = nil
                    self.isSyncing = false
                    self.refreshRepositoryState()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isSyncing = false
                }
            }
        }
    }

    /// Stages a hand-edited conflicted file, which is what actually flips its status away from
    /// `.conflicted` — editing the file alone doesn't change what `git status` reports.
    func markResolved(_ file: ChangedFile) {
        guard let repo = currentRepository else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) { try repo.markResolved(file) }.value
                self.errorMessage = nil
                await self.loadChangedFilesForCurrentSelection(preserveChecks: true, resetSelection: false)
                if self.selectedFile?.path == file.path {
                    await self.loadDiffForCurrentSelection()
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func abortMerge() {
        guard let repo = currentRepository else { return }
        guard Self.confirmDestructiveAction(
            title: "Abort this merge?",
            message: "This cannot be undone. Any conflict resolutions you've made so far will be discarded, and the branch will return to its state before the merge.",
            confirmButtonTitle: "Abort Merge"
        ) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) { try repo.mergeAbort() }.value
                self.errorMessage = nil
                self.refreshRepositoryState()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func completeMerge() {
        guard let repo = currentRepository else { return }
        let resolvedPaths = changedFiles.filter { checkedFilePaths.contains($0.path) }.map(\.path)
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try repo.completeMerge(message: message, resolvedPaths: resolvedPaths)
                }.value
                self.commitMessage = ""
                self.errorMessage = nil
                self.refreshRepositoryState()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func fetchRemote() {
        guard let repo = currentRepository, !isSyncing else { return }
        isSyncing = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try repo.fetch() }.value
                await MainActor.run {
                    self.errorMessage = nil
                    self.refreshSyncStatus()
                    self.isSyncing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isSyncing = false
                }
            }
        }
    }

    func pullCurrentBranch() {
        guard let repo = currentRepository, !isSyncing else { return }
        isSyncing = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try repo.pull() }.value
                await MainActor.run {
                    self.errorMessage = nil
                    self.isSyncing = false
                    self.refreshRepositoryState()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isSyncing = false
                }
            }
        }
    }

    func pushCurrentBranch() {
        guard let repo = currentRepository, let branch = selectedBranch?.name, !isSyncing else { return }
        isSyncing = true
        isPushingCommit = true
        pushProgressText = nil
        pushSucceeded = false
        pushErrorMessage = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try repo.push(branch: branch) { [weak self] line in
                        Task { @MainActor [weak self] in
                            self?.pushProgressText = Self.formatProgressLine(line)
                        }
                    }
                }.value
                await MainActor.run {
                    self.errorMessage = nil
                    self.isSyncing = false
                    self.isPushingCommit = false
                    self.pushProgressText = nil
                    self.refreshSyncStatus()
                    self.pushSucceeded = true
                }
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    self.pushSucceeded = false
                }
            } catch {
                await MainActor.run {
                    self.isSyncing = false
                    self.isPushingCommit = false
                    self.pushProgressText = nil
                    self.pushErrorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Reformats one line of git's `--progress` meter, e.g. "Writing objects:  42% (5/12)", into
    /// "Writing objects (5/12)" for the push footer/clone progress line. Falls back to the stage
    /// name alone (or `nil` for lines with neither, like "Delta compression using up to 8 threads")
    /// when there's no `(x/y)` count to show.
    static func formatProgressLine(_ line: String) -> String? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let stage = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
        guard !stage.isEmpty else { return nil }
        guard let openParen = line.range(of: "(", options: .backwards),
              let closeParen = line.range(of: ")", options: .backwards),
              openParen.lowerBound < closeParen.lowerBound else {
            return stage
        }
        let counts = line[openParen.lowerBound..<closeParen.upperBound]
        return "\(stage) \(counts)"
    }

    /// Extracts the `NN%` figure from one line of git's `--progress` meter (e.g.
    /// "Receiving objects:  42% (420/1000)" -> 0.42). `nil` for lines that don't report a
    /// percentage (e.g. "remote: Enumerating objects: 12, done.").
    private static func progressFraction(from line: String) -> Double? {
        guard let percentRange = line.range(of: #"\d+(?=%)"#, options: .regularExpression),
              let percent = Double(line[percentRange]) else {
            return nil
        }
        return percent / 100
    }

    /// `git clone --progress` runs through a fixed sequence of stages: enumerating/counting/
    /// compressing happen server-side (all prefixed "remote:"), then git receives the objects,
    /// resolves deltas, and checks the result out into the working tree. Each stage reports its
    /// own independent 0-100%, so showing that percentage directly makes `CloneRepoSheet`'s
    /// progress bar snap backward to 0 every time git moves to the next stage. Bucketing the four
    /// stages into even quarters of the bar instead — "remote" 0-25%, receiving 25-50%, resolving
    /// deltas 50-75%, updating files 75-100% — makes it read as one steadily-advancing bar.
    private enum CloneStage: Int, CaseIterable {
        case remote, receivingObjects, resolvingDeltas, updatingFiles

        static func stage(for line: String) -> CloneStage? {
            if line.contains("Receiving objects") { return .receivingObjects }
            if line.contains("Resolving deltas") { return .resolvingDeltas }
            // Git renamed "Checking out files" to "Updating files" at some point; accept both.
            if line.contains("Updating files") || line.contains("Checking out files") { return .updatingFiles }
            if line.hasPrefix("remote:") || line.contains("Enumerating objects") { return .remote }
            return nil
        }
    }

    /// Maps one line of git clone's `--progress` output to overall progress (0...1) across all
    /// four `CloneStage`s, rather than that stage's own independent percentage. `nil` if the line
    /// doesn't match a recognized stage at all.
    static func cloneStageFraction(for line: String) -> Double? {
        guard let stage = CloneStage.stage(for: line) else { return nil }
        let stageWidth = 1.0 / Double(CloneStage.allCases.count)
        let stageBase = Double(stage.rawValue) * stageWidth
        let withinStage = (progressFraction(from: line) ?? 0) * stageWidth
        return stageBase + withinStage
    }

    private func refreshSyncStatus() {
        guard let repo = currentRepository else {
            hasUpstream = false
            aheadCount = 0
            behindCount = 0
            return
        }
        let repoURL = selectedRepoURL
        Task { @MainActor [weak self] in
            let counts = await Task.detached(priority: .userInitiated) {
                repo.aheadBehind()
            }.value
            guard let self, self.selectedRepoURL == repoURL else { return }
            if let counts {
                self.hasUpstream = true
                self.aheadCount = counts.ahead
                self.behindCount = counts.behind
            } else {
                self.hasUpstream = false
                self.aheadCount = 0
                self.behindCount = 0
            }
            if let repoURL {
                self.repoStatusStore.setStatus(self.currentSyncStatus, forPath: repoURL.path)
            }
        }
    }

    /// The selected repo's status-icon data, built from fields `refreshRepositoryState()`/
    /// `refreshSyncStatus()` already fetched — handed to `repoStatusStore` so its cache for this
    /// repo stays warm without an extra git call.
    private var currentSyncStatus: GitRepository.SidebarSyncStatus {
        GitRepository.SidebarSyncStatus(
            uncommittedChangeCount: uncommittedChangeCount,
            hasUpstream: hasUpstream,
            aheadCount: aheadCount,
            behindCount: behindCount
        )
    }

    private func refreshRepositoryState() {
        // Every caller has just changed repository-level state (or selected another repo), so
        // cached selection results may no longer describe the Git graph being displayed.
        invalidateSelectionCaches()
        guard let repo = currentRepository else {
            branches = []
            commits = []
            tags = []
            changedFiles = []
            stashCount = 0
            stashFileCount = 0
            selectedBranch = nil
            selectedSource = nil
            selectedFile = nil
            selectedFilePaths = []
            diffText = ""
            isDetachedHead = false
            detachedHeadShortSHA = nil
            errorMessage = nil
            checkedFilePaths = []
            imageDiffOld = nil
            imageDiffNew = nil
            hasUpstream = false
            aheadCount = 0
            behindCount = 0
            hasOriginRemote = false
            isMergeInProgress = false
            mergeMessage = nil
            repoOwner = nil
            return
        }
        repositoryRefreshGeneration &+= 1
        let generation = repositoryRefreshGeneration
        let repoURL = selectedRepoURL
        Task { @MainActor [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.repositorySnapshot(for: repo)
            }.value
            guard let self, generation == self.repositoryRefreshGeneration, repoURL == self.selectedRepoURL else { return }

            self.repoOwner = snapshot.owner
            self.isMergeInProgress = snapshot.isMergeInProgress
            self.mergeMessage = snapshot.mergeMessage
            if snapshot.isMergeInProgress, self.commitMessage.isEmpty {
                self.commitMessage = snapshot.mergeMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            self.branches = snapshot.branches
            self.selectedBranch = snapshot.selectedBranch
            self.isDetachedHead = snapshot.selectedBranch == nil && !snapshot.branches.isEmpty
            self.detachedHeadShortSHA = snapshot.detachedHeadShortSHA
            self.commits = snapshot.commits
            self.tags = snapshot.tags
            // Only overwrite with the snapshot's own error (nil on a normal successful refresh) —
            // never blindly clear an error a caller just set moments ago (e.g. `selectBranch`'s
            // catch block setting a checkout failure) by unconditionally assigning `nil` here,
            // which previously made failed checkouts look like they silently did nothing.
            if let snapshotError = snapshot.errorMessage {
                self.errorMessage = snapshotError
            }
            self.stashCount = snapshot.stashCount
            self.stashFileCount = snapshot.stashFileCount
            self.updateUncommittedSummary(repo: repo, statusEntries: snapshot.statusEntries)
            if let counts = snapshot.aheadBehind {
                self.hasUpstream = true
                self.aheadCount = counts.ahead
                self.behindCount = counts.behind
            } else {
                self.hasUpstream = false
                self.aheadCount = 0
                self.behindCount = 0
            }
            self.hasOriginRemote = snapshot.hasOriginRemote
            if let repoURL {
                self.repoStatusStore.setStatus(self.currentSyncStatus, forPath: repoURL.path)
            }
            if !snapshot.statusEntries.isEmpty {
                self.selectSource(.workingChanges)
            } else if snapshot.stashCount > 0 {
                self.selectSource(.stash)
            } else if let firstCommit = snapshot.commits.first {
                self.selectSource(.commit(firstCommit))
            } else {
                self.selectSource(.workingChanges)
            }
            self.prefetchRecentCommitFileLists(snapshot.commits, repo: repo, repoURL: repoURL)
        }
    }

    /// Warms the file-list cache for the nearby history rows while the user is reading the
    /// branch column. This is intentionally sequential and utility-priority: it avoids a burst
    /// of Git processes competing with the currently selected diff, while making a first click
    /// on a recent commit commonly a cache hit.
    private func prefetchRecentCommitFileLists(_ commits: [GitCommit], repo: GitRepository, repoURL: URL?) {
        let selectedCommitSHA: String?
        if case .commit(let selectedCommit) = selectedSource {
            selectedCommitSHA = selectedCommit.sha
        } else {
            selectedCommitSHA = nil
        }
        let cacheGeneration = selectionCacheGeneration
        Task { @MainActor [weak self] in
            for commit in commits.prefix(10) where commit.sha != selectedCommitSHA {
                guard let self, !Task.isCancelled,
                      self.selectedRepoURL == repoURL,
                      self.selectionCacheGeneration == cacheGeneration else { return }
                let source = ChangeSource.commit(commit)
                guard self.changedFilesCache[source] == nil else { continue }
                guard let files = await Task.detached(priority: .utility, operation: {
                    try? repo.filesChanged(in: commit)
                }).value else { continue }
                guard !Task.isCancelled,
                      self.selectedRepoURL == repoURL,
                      self.selectionCacheGeneration == cacheGeneration else { return }
                self.changedFilesCache[source] = ChangedFilesCacheValue(files: files, statusEntries: [])
            }
        }
    }

    nonisolated private static func repositorySnapshot(for repo: GitRepository) -> RepositorySnapshot {
        let owner = repo.githubOwner()
        let isMergeInProgress = repo.isMergeInProgress()
        let mergeMessage = repo.mergeMessage()
        do {
            let branches = try repo.branches()
            let selectedBranch = branches.first(where: { $0.isCurrent })
            let commits = selectedBranch.flatMap { try? repo.commitLog(branch: $0.name) } ?? []
            let detachedHeadShortSHA: String?
            if selectedBranch != nil {
                detachedHeadShortSHA = nil
            } else {
                detachedHeadShortSHA = repo.currentHEADShortSHA()
            }
            let stashCount = repo.stashCount()
            return RepositorySnapshot(
                owner: owner,
                isMergeInProgress: isMergeInProgress,
                mergeMessage: mergeMessage,
                branches: branches,
                selectedBranch: selectedBranch,
                detachedHeadShortSHA: detachedHeadShortSHA,
                commits: commits,
                tags: (try? repo.tags()) ?? [],
                aheadBehind: repo.aheadBehind(),
                stashCount: stashCount,
                stashFileCount: stashCount > 0 ? ((try? repo.filesChanged(inStash: "stash@{0}").count) ?? 0) : 0,
                statusEntries: (try? repo.statusEntries()) ?? [],
                errorMessage: nil,
                hasOriginRemote: repo.hasOriginRemote()
            )
        } catch {
            return RepositorySnapshot(owner: owner, isMergeInProgress: isMergeInProgress, mergeMessage: mergeMessage, branches: [], selectedBranch: nil, detachedHeadShortSHA: nil, commits: [], tags: (try? repo.tags()) ?? [], aheadBehind: repo.aheadBehind(), stashCount: repo.stashCount(), stashFileCount: 0, statusEntries: (try? repo.statusEntries()) ?? [], errorMessage: error.localizedDescription, hasOriginRemote: repo.hasOriginRemote())
        }
    }

    /// Incremented at the start of every `handleExternalChange()` call; a snapshot is only
    /// applied if this still matches by the time its (unstructured, uncancellable) `Task`
    /// finishes. FSEvents can fire `handleExternalChange()` multiple times in quick succession
    /// (e.g. several `.git/index` writes during one `git pull`), each starting its own
    /// `Task.detached` snapshot fetch of unpredictable duration — without this guard, an older
    /// call's slower fetch finishing after a newer one's would overwrite fresher state with stale
    /// branches/commits/changed-files.
    private var externalChangeGeneration = 0

    private struct ExternalChangeSnapshot {
        var isMergeInProgress: Bool
        var mergeMessage: String?
        var branches: [GitBranch]
        var selectedBranch: GitBranch?
        var isDetachedHead: Bool
        var detachedHeadShortSHA: String?
        var errorMessage: String?
        var commits: [GitCommit]
        var tags: [GitTag]
        var aheadBehind: (ahead: Int, behind: Int)?
        var changedFiles: [ChangedFile]
        var statusEntries: [ChangedFile]
        var stashCount: Int
        var stashFileCount: Int
        var hasOriginRemote: Bool
    }

    /// Re-syncs branches/commits/files/diff after an FSEvents notification, without disturbing
    /// the user's current selection the way `refreshRepositoryState()`'s initial-selection
    /// heuristic would. `RepoWatcher` watches `.git` itself, and our own git calls (even ones
    /// already off the main thread) can touch `.git/index` and retrigger it — so this used to be
    /// a real, confirmed-via-Instruments source of main-thread hangs on every such retrigger,
    /// same class of bug as the sidebar's redundant reselect but via a different path. All the
    /// git work now happens in `Task.detached`, same pattern as the selection loads.
    private func handleExternalChange() {
        guard let repo = currentRepository else { return }
        // Any filesystem event can affect a diff, status, or commit/stash contents. Prefer a
        // slightly conservative cache clear to ever presenting an old Git snapshot.
        invalidateSelectionCaches()
        let source = selectedSource
        let previousSelectedFile = selectedFile
        let previousCheckedFilePaths = checkedFilePaths
        let previousChangedFilePaths = Set(changedFiles.map(\.path))
        externalChangeGeneration += 1
        let generation = externalChangeGeneration

        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await Task.detached(priority: .userInitiated) { () -> ExternalChangeSnapshot in
                let isMergeInProgress = repo.isMergeInProgress()
                let mergeMessage = repo.mergeMessage()

                var branches: [GitBranch] = []
                var selectedBranch: GitBranch?
                var isDetachedHead = false
                var detachedHeadShortSHA: String?
                var errorMessage: String?
                do {
                    branches = try repo.branches()
                    if let current = branches.first(where: { $0.isCurrent }) {
                        selectedBranch = current
                    } else {
                        isDetachedHead = true
                        detachedHeadShortSHA = repo.currentHEADShortSHA()
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }

                let commits = selectedBranch.flatMap { try? repo.commitLog(branch: $0.name) } ?? []
                let tags = (try? repo.tags()) ?? []
                let aheadBehind = repo.aheadBehind()

                var changedFiles: [ChangedFile] = []
                var statusEntries: [ChangedFile] = []
                if let source, let result = try? repo.changedFilesWithStatus(for: source) {
                    changedFiles = result.files
                    statusEntries = result.statusEntries
                }
                let stashCount = repo.stashCount()
                let stashFileCount = stashCount > 0 ? ((try? repo.filesChanged(inStash: "stash@{0}").count) ?? 0) : 0

                return ExternalChangeSnapshot(
                    isMergeInProgress: isMergeInProgress,
                    mergeMessage: mergeMessage,
                    branches: branches,
                    selectedBranch: selectedBranch,
                    isDetachedHead: isDetachedHead,
                    detachedHeadShortSHA: detachedHeadShortSHA,
                    errorMessage: errorMessage,
                    commits: commits,
                    tags: tags,
                    aheadBehind: aheadBehind,
                    changedFiles: changedFiles,
                    statusEntries: statusEntries,
                    stashCount: stashCount,
                    stashFileCount: stashFileCount,
                    hasOriginRemote: repo.hasOriginRemote()
                )
            }.value

            // A newer `handleExternalChange()` call started (and possibly already applied its
            // own snapshot) while this one's detached fetch was still in flight — drop this
            // stale result instead of overwriting fresher state with it.
            guard generation == self.externalChangeGeneration else { return }

            self.isMergeInProgress = snapshot.isMergeInProgress
            self.mergeMessage = snapshot.mergeMessage
            if self.isMergeInProgress, self.commitMessage.isEmpty {
                self.commitMessage = snapshot.mergeMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            self.branches = snapshot.branches
            self.selectedBranch = snapshot.selectedBranch
            self.isDetachedHead = snapshot.isDetachedHead
            self.detachedHeadShortSHA = snapshot.detachedHeadShortSHA
            self.errorMessage = snapshot.errorMessage
            self.commits = snapshot.commits
            self.tags = snapshot.tags
            self.stashCount = snapshot.stashCount
            self.stashFileCount = snapshot.stashFileCount
            if let aheadBehind = snapshot.aheadBehind {
                self.hasUpstream = true
                self.aheadCount = aheadBehind.ahead
                self.behindCount = aheadBehind.behind
            } else {
                self.hasUpstream = false
                self.aheadCount = 0
                self.behindCount = 0
            }
            self.hasOriginRemote = snapshot.hasOriginRemote
            // The selection can change while this snapshot's git calls were in flight (e.g. a
            // commit both flips `selectedSource` via its own `refreshRepositoryState()` *and*
            // triggers this very external-change notification via `.git`'s FSEvents) — applying
            // a result fetched for the *old* `source` would stomp the newly selected source's
            // freshly loaded files with stale (often empty) ones.
            if source != nil, source == self.selectedSource {
                self.changedFiles = snapshot.changedFiles
                // Only `.workingChanges` populates real `statusEntries` (see
                // `GitRepository.changedFilesWithStatus(for:)`) — for `.stash`/`.commit` it's
                // always `[]`, so applying it unconditionally here would zero out the sidebar's
                // "Uncommitted Changes" count (and, via `BranchListView`'s row losing its `.tag`,
                // make that row unclickable) any time an external-change notification fires while
                // browsing history or the stash.
                if case .workingChanges = source {
                    self.updateUncommittedSummary(repo: repo, statusEntries: snapshot.statusEntries)
                }
                let currentPaths = Set(snapshot.changedFiles.map(\.path))
                self.checkedFilePaths = previousCheckedFilePaths.intersection(currentPaths)
                    .union(currentPaths.subtracting(previousChangedFilePaths))
            }
            if let previousSelectedFile, self.changedFiles.contains(previousSelectedFile) {
                // Same file still selected, but its on-disk content may have changed — the
                // `.task(id:)` that normally loads the diff only reacts to the *selection*
                // changing, so bump this token to make it re-fire instead of calling the loader
                // directly here (which could otherwise race a load `DiffView`'s own `.task(id:)`
                // starts concurrently for the same file).
                self.diffReloadToken += 1
            } else {
                self.selectFile(self.changedFiles.first)
            }
        }
    }

    private func updateUncommittedSummary(repo: GitRepository, statusEntries: [ChangedFile]) {
        uncommittedChangeCount = statusEntries.count
        // File metadata is only used for the small secondary label. Do not make a large
        // working tree's first list paint wait for hundreds or thousands of stat calls.
        uncommittedSummaryGeneration &+= 1
        let generation = uncommittedSummaryGeneration
        let paths = statusEntries.map(\.path)
        Task { @MainActor [weak self] in
            let date = await Task.detached(priority: .utility) {
                repo.lastModifiedDate(for: paths)
            }.value
            guard let self, generation == self.uncommittedSummaryGeneration else { return }
            self.uncommittedLastModifiedDate = date
        }
    }

    /// Loads the changed-files list for the current selection. Called from `ChangedFilesView`'s
    /// `.task(id: appState.selectedSource)`, so SwiftUI cancels this `Task` the moment the
    /// selection changes again — that cancellation does *not* propagate into `Task.detached` on
    /// its own, so the result is checked before applying it. The git subprocess work runs via
    /// `Task.detached` because that's what actually gets it off the main thread — a `nonisolated async` function alone does not,
    /// under this project's `NonisolatedNonsendingByDefault` build setting (it runs on the
    /// caller's actor instead of hopping to a background executor). `GitRepository` shells out to
    /// `/usr/bin/git` synchronously (`Process` + `waitUntilExit()`) — for a commit touching
    /// thousands of files that alone can block a thread for over a second (confirmed via
    /// Instruments' Hangs instrument), so it must never run inline on the main thread.
    ///
    /// `resetSelection` is `false` for `markResolved`, which wants to keep the same file selected
    /// (just refresh its status) rather than jumping to the first file in the reloaded list.
    func loadChangedFilesForCurrentSelection(preserveChecks: Bool = false, resetSelection: Bool = true) async {
        guard let repo = currentRepository, let source = selectedSource else {
            changedFiles = []
            if resetSelection { selectFile(nil) }
            return
        }
        if let cached = changedFilesCache[source] {
            applyChangedFiles(cached, source: source, repo: repo, preserveChecks: preserveChecks, resetSelection: resetSelection)
            return
        }
        // Start every explicit selection immediately. Stale results are discarded below when
        // SwiftUI cancels the selection task or repository state changes.
        let cacheGeneration = selectionCacheGeneration
        let outcome = await Task.detached(priority: .userInitiated) {
            Result { try repo.changedFilesWithStatus(for: source) }
        }.value
        // The `.task(id:)` driving this was cancelled by a newer selection while the git call
        // was in flight — drop this now-stale result instead of flashing it onto the wrong
        // selection before the newer load's own result arrives.
        guard !Task.isCancelled, cacheGeneration == selectionCacheGeneration else { return }

        switch outcome {
        case .success(let result):
            let cached = ChangedFilesCacheValue(files: result.files, statusEntries: result.statusEntries)
            changedFilesCache[source] = cached
            applyChangedFiles(cached, source: source, repo: repo, preserveChecks: preserveChecks, resetSelection: resetSelection)
        case .failure(let error):
            errorMessage = error.localizedDescription
            changedFiles = []
        }
    }

    private func applyChangedFiles(_ result: ChangedFilesCacheValue, source: ChangeSource, repo: GitRepository, preserveChecks: Bool, resetSelection: Bool) {
        let previousPaths = Set(changedFiles.map(\.path))
        changedFiles = result.files
        if case .workingChanges = source {
            updateUncommittedSummary(repo: repo, statusEntries: result.statusEntries)
            let currentPaths = Set(result.files.map(\.path))
            if preserveChecks {
                checkedFilePaths.formIntersection(currentPaths)
                checkedFilePaths.formUnion(currentPaths.subtracting(previousPaths))
            } else {
                checkedFilePaths = currentPaths
            }
        } else {
            checkedFilePaths = []
        }
        errorMessage = nil
        if resetSelection {
            selectFile(changedFiles.first)
        }
    }

    /// Loads the diff for the current file selection. Called from `DiffView`'s `.task(id:)`,
    /// keyed on the selected file, source, and `diffReloadToken`.
    func loadDiffForCurrentSelection() async {
        guard let repo = currentRepository, let file = selectedFile, let source = selectedSource else {
            diffText = ""
            diffOnlyWhitespaceChanges = false
            imageDiffOld = nil
            imageDiffNew = nil
            diffFileTooLarge = false
            return
        }
        let ignoreWhitespace = LeafSettings.store.bool(forKey: LeafSettings.hideWhitespaceChangesKey)
        let cacheKey = DiffCacheKey(source: source, file: file, ignoreWhitespace: ignoreWhitespace)
        if let cached = diffTextCache[cacheKey] {
            diffText = cached.text
            diffOnlyWhitespaceChanges = cached.onlyWhitespaceChanges
            diffFileTooLarge = false
            errorMessage = nil
            return
        }
        if file.isLikelyImage {
            // Image blobs can be large (and working-tree reads can be on a network volume), so
            // keep these reads off the UI actor just like textual diffs.
            let contents = await Task.detached(priority: .userInitiated) {
                repo.imageContents(for: file, in: source)
            }.value
            guard !Task.isCancelled else { return }
            diffText = ""
            diffOnlyWhitespaceChanges = false
            diffFileTooLarge = false
            errorMessage = nil
            // Only touch these if the bytes actually changed — an unconditional nil-then-set
            // makes the image view flash to its empty state on every FSEvents-triggered refresh,
            // even when this file didn't change.
            if contents.old != imageDiffOld { imageDiffOld = contents.old }
            if contents.new != imageDiffNew { imageDiffNew = contents.new }
            return
        }
        imageDiffOld = nil
        imageDiffNew = nil
        // Unlike a changed-files list, a diff is tied to one explicit click. Debouncing here
        // imposed a guaranteed 180 ms blank/stale interval before even launching Git, which is
        // much more noticeable than the small amount of superseded work from rapid arrowing.
        // The surrounding SwiftUI task still cancels stale results before they reach the UI.
        // As above, this never turns the Git process into synchronous UI-actor work.
        let cacheGeneration = selectionCacheGeneration
        // Checked (a cheap `stat`/`git cat-file -s`) before ever calling `diffText(for:in:)` —
        // rendering the diff, not generating it, is what froze the app on a >100MB SQL dump.
        let tooLarge = await Task.detached(priority: .userInitiated) {
            repo.isFileTooLargeToDiff(file, in: source)
        }.value
        guard !Task.isCancelled, cacheGeneration == selectionCacheGeneration else { return }
        if tooLarge {
            diffFileTooLarge = true
            diffText = ""
            diffOnlyWhitespaceChanges = false
            errorMessage = nil
            return
        }
        diffFileTooLarge = false
        let outcome = await Task.detached(priority: .userInitiated) {
            Result { () -> DiffCacheValue in
                let text = try repo.diffText(for: file, in: source, ignoreWhitespace: ignoreWhitespace)
                guard ignoreWhitespace, text.isEmpty else {
                    return DiffCacheValue(text: text, onlyWhitespaceChanges: false)
                }
                // Empty only because whitespace-only changes were filtered out, vs. genuinely no
                // diff — re-run unfiltered (only reached when the filtered result is already
                // empty) to tell the two apart so the UI can explain why the pane is blank.
                let rawText = try repo.diffText(for: file, in: source, ignoreWhitespace: false)
                return DiffCacheValue(text: text, onlyWhitespaceChanges: !rawText.isEmpty)
            }
        }.value
        guard !Task.isCancelled, cacheGeneration == selectionCacheGeneration else { return }
        switch outcome {
        case .success(let value):
            diffTextCache[cacheKey] = value
            diffText = value.text
            diffOnlyWhitespaceChanges = value.onlyWhitespaceChanges
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.localizedDescription
            diffText = ""
            diffOnlyWhitespaceChanges = false
        }
    }
}
