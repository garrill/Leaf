import Foundation

/// An open GitHub issue or pull request.
nonisolated struct GitHubIssue: Hashable, Sendable {
    let number: Int
    let title: String
    let isPullRequest: Bool
}

/// The slower commit-message completion sources — people from history, symbols from the diff,
/// GitHub issues and logins — loaded off-main on first use and cached per repo. Everything
/// in-memory already (changed files, branches, commit summaries) is read straight from
/// `AppState` by `CommitCompletionController` instead.
///
/// `generation` bumps whenever anything lands, and `onChange` tells the open popup to refresh.
@MainActor
final class CompletionDataStore {
    static let shared = CompletionDataStore()

    private(set) var generation = 0
    /// The (single) open popup's refresh hook — set by whichever controller is active.
    var onChange: (() -> Void)?

    private struct RepoData {
        var people: [CompletionPerson]?
        var isLoadingPeople = false
        var issues: [GitHubIssue]?
        var issuesFetchedAt: Date?
        var isLoadingIssues = false
        var didFetchLogins = false
        var symbols: [String]?
        var symbolsFetchedAt: Date?
        var isLoadingSymbols = false
    }

    private var repos: [String: RepoData] = [:]
    /// Email (lowercased) → GitHub login, learned from the GitHub commits API. Persisted so each
    /// address only needs resolving once.
    private var logins: [String: String]

    private static let loginsDefaultsKey = "commitCompletionGitHubLogins"
    private static let maxStoredLogins = 2000
    private static let issuesLifetime: TimeInterval = 5 * 60
    private static let symbolsLifetime: TimeInterval = 15

    private init() {
        logins = UserDefaults.standard.dictionary(forKey: Self.loginsDefaultsKey) as? [String: String] ?? [:]
    }

    func purge() {
        repos.removeAll()
        generation += 1
    }

    // MARK: People

    /// Authors from history, best first; `nil` while the first load runs. With a GitHub
    /// `origin`, also starts (once per repo) resolving their GitHub logins.
    func people(repoURL: URL, remoteURL: String?) -> [CompletionPerson]? {
        let key = repoURL.path
        let data = repos[key] ?? RepoData()
        if data.people == nil, !data.isLoadingPeople {
            repos[key, default: RepoData()].isLoadingPeople = true
            let repository = GitRepository(rootURL: repoURL)
            Task.detached(priority: .utility) {
                let log = repository.authorLogForCompletion() ?? ""
                let people = CompletionPeople.parse(log, excludingEmail: repository.configuredUserEmail())
                await MainActor.run {
                    self.repos[key, default: RepoData()].people = people
                    self.repos[key]?.isLoadingPeople = false
                    self.changed()
                }
            }
        }
        if !data.didFetchLogins, let slug = GitHubClient.slug(fromRemoteURL: remoteURL) {
            repos[key, default: RepoData()].didFetchLogins = true
            Task.detached(priority: .utility) {
                let found = await GitHubClient.commitAuthorLogins(slug: slug)
                guard !found.isEmpty else { return }
                await MainActor.run { self.learnLogins(found) }
            }
        }
        return data.people
    }

    /// A GitHub login for `email`: encoded in a noreply address, or learned from the API.
    func login(forEmail email: String) -> String? {
        CompletionPeople.githubLogin(fromNoreplyEmail: email) ?? logins[email.lowercased()]
    }

    private func learnLogins(_ found: [String: String]) {
        var updated = logins
        for (email, login) in found { updated[email.lowercased()] = login }
        guard updated != logins else { return }
        if updated.count > Self.maxStoredLogins {
            updated = Dictionary(uniqueKeysWithValues: updated.prefix(Self.maxStoredLogins).map { ($0.key, $0.value) })
        }
        logins = updated
        UserDefaults.standard.set(updated, forKey: Self.loginsDefaultsKey)
        changed()
    }

    // MARK: Issues

    /// Open issues and PRs, newest first. `nil` while loading (or for a non-GitHub remote,
    /// where `isAvailable` is false). Refetched in the background after 5 minutes.
    func issues(repoURL: URL, remoteURL: String?) -> (issues: [GitHubIssue]?, isAvailable: Bool) {
        guard let slug = GitHubClient.slug(fromRemoteURL: remoteURL) else { return (nil, false) }
        let key = repoURL.path
        let data = repos[key] ?? RepoData()
        let isStale = data.issuesFetchedAt.map { Date().timeIntervalSince($0) > Self.issuesLifetime } ?? true
        if isStale, !data.isLoadingIssues {
            repos[key, default: RepoData()].isLoadingIssues = true
            Task.detached(priority: .userInitiated) {
                let issues = await GitHubClient.openIssues(slug: slug)
                await MainActor.run {
                    // A failure keeps whatever was there and marks the attempt, so a missing
                    // network doesn't retry on every keystroke.
                    if let issues { self.repos[key, default: RepoData()].issues = issues }
                    else if self.repos[key]?.issues == nil { self.repos[key, default: RepoData()].issues = [] }
                    self.repos[key]?.issuesFetchedAt = Date()
                    self.repos[key]?.isLoadingIssues = false
                    self.changed()
                }
            }
        }
        return (data.issues, true)
    }

    // MARK: Symbols

    /// Identifiers from the uncommitted diff (plus small untracked files), most frequent
    /// first. Empty until the first load lands; reloaded in the background once 15 seconds old.
    func symbols(repoURL: URL, untrackedPaths: [String]) -> [String] {
        let key = repoURL.path
        let data = repos[key] ?? RepoData()
        let isStale = data.symbolsFetchedAt.map { Date().timeIntervalSince($0) > Self.symbolsLifetime } ?? true
        if isStale, !data.isLoadingSymbols {
            repos[key, default: RepoData()].isLoadingSymbols = true
            let repository = GitRepository(rootURL: repoURL)
            let untracked = Array(untrackedPaths.prefix(30))
            Task.detached(priority: .utility) {
                var lines = CompletionIdentifiers.changedLines(inDiff: repository.uncommittedDiffForCompletion() ?? "")
                for path in untracked {
                    let url = repoURL.appendingPathComponent(path)
                    guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                          size <= 256 * 1024,
                          let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    lines.append(contentsOf: contents.split(separator: "\n"))
                }
                let symbols = CompletionIdentifiers.extract(from: lines)
                await MainActor.run {
                    let previous = self.repos[key]?.symbols
                    self.repos[key, default: RepoData()].symbols = symbols
                    self.repos[key]?.symbolsFetchedAt = Date()
                    self.repos[key]?.isLoadingSymbols = false
                    if previous != symbols { self.changed() }
                }
            }
        }
        return data.symbols ?? []
    }

    private func changed() {
        generation += 1
        onChange?()
    }
}

/// Read-only GitHub lookups for completion. Uses the `gh` CLI when it's installed and logged
/// in (so private repos work), otherwise GitHub's unauthenticated REST API (public repos
/// only). Every failure is silent — completion just has less to offer.
nonisolated enum GitHubClient {
    /// "owner/repo" for a github.com `origin`, via `GitRepository.githubPathComponents`.
    static func slug(fromRemoteURL url: String?) -> String? {
        guard let url, let parts = GitRepository.githubPathComponents(fromRemoteURL: url), parts.count >= 2 else { return nil }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !repo.isEmpty else { return nil }
        return "\(parts[0])/\(repo)"
    }

    static func openIssues(slug: String) async -> [GitHubIssue]? {
        guard let data = await get("repos/\(slug)/issues?state=open&per_page=100&sort=updated"),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return array.compactMap { entry in
            guard let number = entry["number"] as? Int, let title = entry["title"] as? String else { return nil }
            return GitHubIssue(number: number, title: title, isPullRequest: entry["pull_request"] != nil)
        }
        .sorted { $0.number > $1.number }
    }

    /// Commit-author email → login for the newest 100 commits on the default branch.
    static func commitAuthorLogins(slug: String) async -> [String: String] {
        guard let data = await get("repos/\(slug)/commits?per_page=100"),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var logins: [String: String] = [:]
        for entry in array {
            guard let commit = entry["commit"] as? [String: Any],
                  let author = commit["author"] as? [String: Any],
                  let email = author["email"] as? String,
                  let user = entry["author"] as? [String: Any],
                  let login = user["login"] as? String else { continue }
            logins[email.lowercased()] = login
        }
        return logins
    }

    /// `gh api <path>` when that works, else an unauthenticated request to api.github.com.
    private static func get(_ path: String) async -> Data? {
        if let data = await runGH(["api", path]) { return data }
        guard let url = URL(string: "https://api.github.com/\(path)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Leaf", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// A GUI app's `PATH` doesn't include Homebrew, so look in the usual install locations.
    private static let ghExecutable: URL? = {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }()

    /// stdout of a successful `gh` run, `nil` on any failure or after 10 seconds.
    private static func runGH(_ arguments: [String]) async -> Data? {
        guard let executable = ghExecutable else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["GH_PROMPT_DISABLED"] = "1"
                environment["NO_COLOR"] = "1"
                process.environment = environment
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
