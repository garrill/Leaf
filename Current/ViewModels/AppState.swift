import AppKit
import Foundation

@Observable
final class AppState {
    let sidebarStore = SidebarStore()

    var selectedRepoURL: URL?
    var branches: [GitBranch] = []
    var selectedBranch: GitBranch?

    var commits: [GitCommit] = []
    var selectedSource: ChangeSource?

    var changedFiles: [ChangedFile] = []
    var selectedFile: ChangedFile?
    var checkedFilePaths: Set<String> = []
    var commitMessage: String = ""

    var diffText: String = ""
    var errorMessage: String?

    private var currentRepository: GitRepository? {
        selectedRepoURL.map { GitRepository(rootURL: $0) }
    }

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
        selectedFile = nil
        diffText = ""
        loadChangedFiles()
    }

    func selectFile(_ file: ChangedFile?) {
        selectedFile = file
        loadDiff()
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
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paths.isEmpty, !message.isEmpty else { return }

        do {
            try repo.commit(message: message, paths: paths)
            commitMessage = ""
            errorMessage = nil
            refreshRepositoryState()
        } catch {
            errorMessage = error.localizedDescription
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
            diffText = ""
            return
        }
        do {
            branches = try repo.branches()
            selectedBranch = branches.first { $0.isCurrent } ?? branches.first
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            branches = []
            selectedBranch = nil
        }
        loadCommitLog()
        selectSource(.workingChanges)
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

    private func loadChangedFiles() {
        guard let repo = currentRepository, let source = selectedSource else {
            changedFiles = []
            return
        }
        do {
            switch source {
            case .workingChanges:
                changedFiles = try repo.statusEntries()
                checkedFilePaths = Set(changedFiles.map(\.path))
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
            return
        }
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
