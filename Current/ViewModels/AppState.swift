import AppKit
import Foundation

@Observable
final class AppState {
    let sidebarStore = SidebarStore()

    var selectedRepoURL: URL?
    var branches: [GitBranch] = []
    var selectedBranch: GitBranch?
    var isDetachedHead = false
    var detachedHeadShortSHA: String?

    var commits: [GitCommit] = []
    var selectedSource: ChangeSource?

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

    var diffText: String = ""
    var imageDiffOld: Data?
    var imageDiffNew: Data?
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

    var isMergeInProgress = false
    var mergeMessage: String?

    var isCloning = false
    var cloneErrorMessage: String?

    var renamingFolderID: UUID?
    var renamingRepoID: UUID?
    var isCloneSheetPresented = false

    /// GitHub owner (user/org) of the selected repo's `origin` remote, shown as the window
    /// subtitle. `nil` for non-GitHub remotes or repos with no `origin`.
    var repoOwner: String?

    private var currentRepository: GitRepository? {
        selectedRepoURL.map { GitRepository(rootURL: $0) }
    }

    private var repoWatcher: RepoWatcher?

    func addRepoViaPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Repository"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        sidebarStore.addRepo(at: url)
        selectRepo(url)
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
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try GitRepository.clone(from: trimmedURL, into: destination)
                }.value
                await MainActor.run {
                    self.isCloning = false
                    self.sidebarStore.addRepo(at: destination)
                    self.selectRepo(destination)
                    completion(true)
                }
            } catch {
                await MainActor.run {
                    self.isCloning = false
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
        refreshRepositoryState()
        repoWatcher = RepoWatcher(url: url) { [weak self] in
            self?.handleExternalChange()
        }
    }

    func deselectRepo() {
        selectedRepoURL = nil
        repoWatcher = nil
        refreshRepositoryState()
    }

    func selectBranch(_ branch: GitBranch) {
        guard let repo = currentRepository else { return }
        if !branch.isCurrent {
            do {
                try repo.checkout(branch: branch.name)
                errorMessage = nil
            } catch let GitError.commandFailed(message) where Self.isLocalChangesCheckoutFailure(message) {
                // Checkout is blocked by a dirty working tree — auto-stash (silently, including
                // untracked files) and retry rather than surfacing an error the user would just
                // have to work around manually. The stash is left in the list for manual restore.
                do {
                    try repo.stashChanges(paths: [], includeUntracked: true)
                    try repo.checkout(branch: branch.name)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        refreshRepositoryState()
    }

    /// Matches git's checkout-blocked-by-local-changes wording (both the tracked- and
    /// untracked-file variants) so an auto-stash-and-retry only kicks in for that specific
    /// failure, not any other reason `checkout` might fail (bad ref, detached HEAD oddities, etc).
    private static func isLocalChangesCheckoutFailure(_ message: String) -> Bool {
        message.contains("Please commit your changes or stash them before you switch branches")
            || message.contains("The following untracked working tree files would be overwritten")
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

    func discardChanges(for file: ChangedFile) {
        discardChanges(for: [file])
    }

    func discardChanges(for files: [ChangedFile]) {
        guard let repo = currentRepository, !files.isEmpty else { return }
        do {
            try repo.discardChanges(for: files)
            errorMessage = nil
            Task { await loadChangedFilesForCurrentSelection(immediate: true) }
        } catch {
            errorMessage = error.localizedDescription
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
        do {
            try repo.stashChanges(paths: files.map(\.path), includeUntracked: includeUntracked)
            errorMessage = nil
            refreshRepositoryState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Applies and drops the top-of-stack stash. On a conflicting pop, the stash is left in
    /// place by git and the working tree gets conflict markers with no `MERGE_HEAD` — landing on
    /// Uncommitted Changes lets the existing per-row "Mark Resolved" flow handle it like any
    /// other on-disk conflict, rather than needing a separate stash-conflict UI.
    func restoreStash() {
        guard let repo = currentRepository else { return }
        do {
            let result = try repo.restoreStash()
            errorMessage = nil
            refreshRepositoryState()
            if result == .conflicts {
                selectSource(.workingChanges)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func discardStash() {
        guard let repo = currentRepository else { return }
        do {
            try repo.discardStash()
            errorMessage = nil
            refreshRepositoryState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func ignoreFile(_ file: ChangedFile) {
        ignoreFiles([file])
    }

    func ignoreFiles(_ files: [ChangedFile]) {
        guard let repo = currentRepository, !files.isEmpty else { return }
        do {
            try repo.ignoreFiles(files)
            errorMessage = nil
            Task { await loadChangedFilesForCurrentSelection(immediate: true) }
        } catch {
            errorMessage = error.localizedDescription
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

        do {
            try repo.commit(message: message, paths: paths, unstagePaths: unstagePaths)
            commitMessage = ""
            errorMessage = nil
            refreshRepositoryState()
        } catch {
            errorMessage = error.localizedDescription
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
        do {
            try repo.markResolved(file)
            errorMessage = nil
            Task {
                await loadChangedFilesForCurrentSelection(preserveChecks: true, immediate: true, resetSelection: false)
                if selectedFile?.path == file.path {
                    await loadDiffForCurrentSelection(immediate: true)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func abortMerge() {
        guard let repo = currentRepository else { return }
        do {
            try repo.mergeAbort()
            errorMessage = nil
            refreshRepositoryState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completeMerge() {
        guard let repo = currentRepository else { return }
        let resolvedPaths = changedFiles.filter { checkedFilePaths.contains($0.path) }.map(\.path)
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        do {
            try repo.completeMerge(message: message, resolvedPaths: resolvedPaths)
            commitMessage = ""
            errorMessage = nil
            refreshRepositoryState()
        } catch {
            errorMessage = error.localizedDescription
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
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try repo.push(branch: branch) }.value
                await MainActor.run {
                    self.errorMessage = nil
                    self.isSyncing = false
                    self.refreshSyncStatus()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isSyncing = false
                }
            }
        }
    }

    private func refreshSyncStatus() {
        guard let repo = currentRepository else {
            hasUpstream = false
            aheadCount = 0
            behindCount = 0
            return
        }
        if let counts = repo.aheadBehind() {
            hasUpstream = true
            aheadCount = counts.ahead
            behindCount = counts.behind
        } else {
            hasUpstream = false
            aheadCount = 0
            behindCount = 0
        }
    }

    private func refreshRepositoryState() {
        guard let repo = currentRepository else {
            branches = []
            commits = []
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
            isMergeInProgress = false
            mergeMessage = nil
            repoOwner = nil
            return
        }
        repoOwner = repo.githubOwner()
        isMergeInProgress = repo.isMergeInProgress()
        mergeMessage = repo.mergeMessage()
        if isMergeInProgress, commitMessage.isEmpty {
            commitMessage = mergeMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        do {
            branches = try repo.branches()
            if let current = branches.first(where: { $0.isCurrent }) {
                selectedBranch = current
                isDetachedHead = false
                detachedHeadShortSHA = nil
            } else {
                selectedBranch = nil
                isDetachedHead = true
                detachedHeadShortSHA = repo.currentHEADShortSHA()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            branches = []
            selectedBranch = nil
            isDetachedHead = false
            detachedHeadShortSHA = nil
        }
        loadCommitLog()
        refreshSyncStatus()
        stashCount = repo.stashCount()
        stashFileCount = stashCount > 0 ? ((try? repo.filesChanged(inStash: "stash@{0}").count) ?? 0) : 0

        let hasUncommittedChanges = (try? repo.statusEntries().isEmpty == false) ?? false
        if hasUncommittedChanges {
            selectSource(.workingChanges)
        } else if stashCount > 0 {
            selectSource(.stash)
        } else if let firstCommit = commits.first {
            selectSource(.commit(firstCommit))
        } else {
            selectSource(.workingChanges)
        }
    }

    private func loadCommitLog() {
        guard let repo = currentRepository, let branch = selectedBranch else {
            commits = []
            return
        }
        do {
            commits = try repo.commitLog(branch: branch.name)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            commits = []
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
        var aheadBehind: (ahead: Int, behind: Int)?
        var changedFiles: [ChangedFile]
        var statusEntries: [ChangedFile]
        var stashCount: Int
        var stashFileCount: Int
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
                    aheadBehind: aheadBehind,
                    changedFiles: changedFiles,
                    statusEntries: statusEntries,
                    stashCount: stashCount,
                    stashFileCount: stashFileCount
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
            if source != nil {
                self.changedFiles = snapshot.changedFiles
                self.updateUncommittedSummary(repo: repo, statusEntries: snapshot.statusEntries)
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
        uncommittedLastModifiedDate = repo.lastModifiedDate(for: statusEntries.map(\.path))
    }

    /// macOS's key-repeat interval, even at a middling (non-"Fast") setting, is often close to
    /// what an 80ms window allows through — each repeat can "win" its own debounce window before
    /// the next one arrives, so almost nothing actually gets coalesced. A wider margin makes
    /// suppression reliable across repeat-rate settings without being perceptible as added
    /// latency for a deliberate, single selection.
    private static let selectionDebounceNanoseconds: UInt64 = 180_000_000

    /// Sleeps out the debounce window and reports whether the caller should proceed (`false`
    /// means a newer selection superseded this one while sleeping, so no real work should start
    /// at all — as opposed to starting it and discarding the result).
    private func debounceSelection() async -> Bool {
        try? await Task.sleep(nanoseconds: Self.selectionDebounceNanoseconds)
        return !Task.isCancelled
    }

    /// Loads the changed-files list for the current selection. Called from `ChangedFilesView`'s
    /// `.task(id: appState.selectedSource)`, so SwiftUI cancels this `Task` the moment the
    /// selection changes again — that cancellation does *not* propagate into `Task.detached` on
    /// its own, which is why `debounceSelection()` checks `Task.isCancelled` itself before
    /// starting any real work. The git subprocess work runs via `Task.detached` because that's
    /// what actually gets it off the main thread — a `nonisolated async` function alone does not,
    /// under this project's `NonisolatedNonsendingByDefault` build setting (it runs on the
    /// caller's actor instead of hopping to a background executor). `GitRepository` shells out to
    /// `/usr/bin/git` synchronously (`Process` + `waitUntilExit()`) — for a commit touching
    /// thousands of files that alone can block a thread for over a second (confirmed via
    /// Instruments' Hangs instrument), so it must never run inline on the main thread.
    ///
    /// `immediate` skips both the debounce and the `Task.detached` hop, for callers
    /// (`discardChanges`/`ignoreFiles`/`markResolved`) that already know exactly what changed and
    /// want their own action reflected right away rather than waiting out a debounce meant for
    /// coalescing rapid *selection* changes. `resetSelection` is `false` for `markResolved`, which
    /// wants to keep the same file selected (just refresh its status) rather than jumping to the
    /// first file in the reloaded list.
    func loadChangedFilesForCurrentSelection(preserveChecks: Bool = false, immediate: Bool = false, resetSelection: Bool = true) async {
        guard let repo = currentRepository, let source = selectedSource else {
            changedFiles = []
            if resetSelection { selectFile(nil) }
            return
        }
        // Skip the debounce on the very first load into an empty list (e.g. right after
        // `selectRepo` clears it) — there's nothing on screen yet for a debounce to protect
        // against flashing, only added latency before the first paint.
        let isInitialLoad = changedFiles.isEmpty
        if !immediate && !isInitialLoad {
            guard await debounceSelection() else { return }
        }

        let outcome: Result<(files: [ChangedFile], statusEntries: [ChangedFile]), Error>
        if immediate {
            outcome = Result { try repo.changedFilesWithStatus(for: source) }
        } else {
            outcome = await Task.detached(priority: .userInitiated) {
                Result { try repo.changedFilesWithStatus(for: source) }
            }.value
            // The `.task(id:)` driving this was cancelled by a newer selection while the git call
            // was in flight — drop this now-stale result instead of flashing it onto the wrong
            // selection before the newer load's own result arrives.
            guard !Task.isCancelled else { return }
        }

        switch outcome {
        case .success(let result):
            let previousPaths = Set(changedFiles.map(\.path))
            changedFiles = result.files
            updateUncommittedSummary(repo: repo, statusEntries: result.statusEntries)
            switch source {
            case .workingChanges:
                let currentPaths = Set(result.files.map(\.path))
                if preserveChecks {
                    // Keep the user's check state for files that are still around, and default
                    // newly-appeared files to checked, rather than resetting everything.
                    checkedFilePaths.formIntersection(currentPaths)
                    checkedFilePaths.formUnion(currentPaths.subtracting(previousPaths))
                } else {
                    checkedFilePaths = currentPaths
                }
            case .stash, .commit:
                checkedFilePaths = []
            }
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.localizedDescription
            changedFiles = []
        }
        if resetSelection {
            selectFile(changedFiles.first)
        }
    }

    /// Loads the diff for the current file selection — see `loadChangedFilesForCurrentSelection`,
    /// including what `immediate` means. Called from `DiffView`'s `.task(id:)`, keyed on the
    /// selected file, source, and `diffReloadToken`.
    func loadDiffForCurrentSelection(immediate: Bool = false) async {
        guard let repo = currentRepository, let file = selectedFile, let source = selectedSource else {
            diffText = ""
            imageDiffOld = nil
            imageDiffNew = nil
            return
        }
        if file.isLikelyImage {
            // Just Data(contentsOf:) on disk — cheap enough to stay synchronous.
            let contents = repo.imageContents(for: file, in: source)
            diffText = ""
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
        // Skip the debounce on the very first diff load (nothing on screen yet to protect).
        let isInitialLoad = diffText.isEmpty
        if !immediate && !isInitialLoad {
            guard await debounceSelection() else { return }
        }

        let outcome: Result<String, Error>
        if immediate {
            outcome = Result { try repo.diffText(for: file, in: source) }
        } else {
            outcome = await Task.detached(priority: .userInitiated) {
                Result { try repo.diffText(for: file, in: source) }
            }.value
            guard !Task.isCancelled else { return }
        }
        switch outcome {
        case .success(let text):
            diffText = text
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.localizedDescription
            diffText = ""
        }
    }
}
