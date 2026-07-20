import AppKit
import Foundation

@Observable
final class AppState {
    let repoStore = RepoStore()

    var selectedRepoURL: URL?
    var branches: [GitBranch] = []
    var selectedBranch: GitBranch?

    var changedFiles: [ChangedFile] = []
    var selectedFile: ChangedFile?

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
        repoStore.addRepo(at: url)
        selectRepo(url)
    }

    func selectRepo(_ url: URL) {
        selectedRepoURL = url
        selectedFile = nil
        diffText = ""
        refreshBranchesAndStatus()
    }

    func selectFile(_ file: ChangedFile?) {
        selectedFile = file
        loadDiff()
    }

    func refreshBranchesAndStatus() {
        guard let repo = currentRepository else {
            branches = []
            changedFiles = []
            selectedBranch = nil
            return
        }
        do {
            branches = try repo.branches()
            selectedBranch = branches.first { $0.isCurrent }
            changedFiles = try repo.statusEntries()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            branches = []
            changedFiles = []
        }
    }

    private func loadDiff() {
        guard let repo = currentRepository, let file = selectedFile else {
            diffText = ""
            return
        }
        do {
            diffText = try repo.diff(for: file)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            diffText = ""
        }
    }
}
