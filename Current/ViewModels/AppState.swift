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

    var isSyncing = false
    var hasUpstream = false
    var aheadCount = 0
    var behindCount = 0

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

    func selectRepo(_ url: URL) {
        selectedRepoURL = url
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
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        refreshRepositoryState()
    }

    func selectSource(_ source: ChangeSource?) {
        selectedSource = source
        // Go straight to the new file, without ever writing `selectedFile = nil` as an
        // intermediate step — that observable nil is what showed up in the diff view as a
        // flash of "No File Selected" between commits, even though this whole function runs
        // synchronously to completion before SwiftUI's next render.
        loadChangedFiles()
        selectFile(changedFiles.first)
    }

    func selectFile(_ file: ChangedFile?) {
        selectedFile = file
        selectedFilePaths = file.map { [$0.path] } ?? []
        loadDiff()
    }

    /// Updates the multi-selection from the list's native shift/cmd-click selection. The diff
    /// pane keeps following a single "primary" file: whichever one was just added to the
    /// selection, or the sole remaining one if the selection shrank back down to one.
    func updateFileSelection(_ paths: Set<String>) {
        let previousPaths = selectedFilePaths
        selectedFilePaths = paths
        guard !paths.isEmpty else {
            selectedFile = nil
            loadDiff()
            return
        }
        let added = paths.subtracting(previousPaths)
        let primaryPath = added.first ?? (paths.count == 1 ? paths.first : selectedFile?.path)
        let primaryFile = changedFiles.first(where: { $0.path == primaryPath }) ?? changedFiles.first(where: { paths.contains($0.path) })
        selectedFile = primaryFile
        loadDiff()
    }

    func discardChanges(for file: ChangedFile) {
        discardChanges(for: [file])
    }

    func discardChanges(for files: [ChangedFile]) {
        guard let repo = currentRepository, !files.isEmpty else { return }
        do {
            try repo.discardChanges(for: files)
            errorMessage = nil
            loadChangedFiles()
            selectFile(changedFiles.first)
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
            loadChangedFiles()
            selectFile(changedFiles.first)
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
            return
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

        let hasUncommittedChanges = (try? repo.statusEntries().isEmpty == false) ?? false
        if hasUncommittedChanges {
            selectSource(.workingChanges)
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

    /// Re-syncs branches/commits/files/diff after an FSEvents notification, without disturbing
    /// the user's current selection the way `refreshRepositoryState()`'s initial-selection
    /// heuristic would.
    private func handleExternalChange() {
        guard let repo = currentRepository else { return }
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
        }
        loadCommitLog()
        refreshSyncStatus()
        loadChangedFiles(preserveChecks: true)
        if let selectedFile, changedFiles.contains(selectedFile) {
            loadDiff()
        } else {
            selectFile(changedFiles.first)
        }
    }

    private func loadChangedFiles(preserveChecks: Bool = false) {
        guard let repo = currentRepository, let source = selectedSource else {
            changedFiles = []
            return
        }
        let previousPaths = Set(changedFiles.map(\.path))
        do {
            switch source {
            case .workingChanges:
                changedFiles = try repo.statusEntries()
                let currentPaths = Set(changedFiles.map(\.path))
                if preserveChecks {
                    // Keep the user's check state for files that are still around, and default
                    // newly-appeared files to checked, rather than resetting everything.
                    checkedFilePaths.formIntersection(currentPaths)
                    checkedFilePaths.formUnion(currentPaths.subtracting(previousPaths))
                } else {
                    checkedFilePaths = currentPaths
                }
            case .commit(let commit):
                changedFiles = try repo.filesChanged(in: commit)
                checkedFilePaths = []
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            changedFiles = []
        }
    }

    private func loadDiff() {
        guard let repo = currentRepository, let file = selectedFile, let source = selectedSource else {
            diffText = ""
            imageDiffOld = nil
            imageDiffNew = nil
            return
        }
        if file.isLikelyImage {
            let contents = repo.imageContents(for: file, in: source)
            diffText = ""
            errorMessage = nil
            // Only touch these if the bytes actually changed — an unconditional nil-then-set
            // makes the image view flash to its empty state on every FSEvents-triggered
            // refresh, even when this file didn't change.
            if contents.old != imageDiffOld { imageDiffOld = contents.old }
            if contents.new != imageDiffNew { imageDiffNew = contents.new }
            return
        }
        imageDiffOld = nil
        imageDiffNew = nil
        do {
            switch source {
            case .workingChanges:
                diffText = try repo.diff(for: file)
            case .commit(let commit):
                diffText = try repo.diff(for: file, in: commit)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            diffText = ""
        }
    }
}
