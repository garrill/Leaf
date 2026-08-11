import Foundation

struct GitBranch: Identifiable, Hashable {
    let name: String
    let isCurrent: Bool

    var id: String { name }
}

enum FileChangeStatus: String {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case untracked = "?"
    case conflicted = "U"
    case unknown

    var label: String {
        switch self {
        case .modified: return "Modified"
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .untracked: return "Untracked"
        case .conflicted: return "Conflicted"
        case .unknown: return "Changed"
        }
    }
}

struct ChangedFile: Identifiable, Hashable {
    let path: String
    let status: FileChangeStatus
    /// The pre-rename path, set only when `status == .renamed`.
    var oldPath: String? = nil

    var id: String { path }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"
    ]

    var isLikelyImage: Bool {
        Self.imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}

struct GitCommit: Identifiable, Hashable {
    let sha: String
    let shortSha: String
    let summary: String
    let date: Date
    let author: String

    var id: String { sha }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var relativeDate: String {
        Self.relativeDate(for: date)
    }

    static func relativeDate(for date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 {
            return "Just now"
        }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

enum ChangeSource: Hashable {
    case workingChanges
    /// Only ever addresses the top of the stack (`stash@{0}`) — the app shows a single
    /// aggregate "Stashed Changes" entry rather than browsing individual stash entries.
    case stash
    case commit(GitCommit)
}

enum GitError: Error, LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): return message
        }
    }
}

/// Explicitly `nonisolated` — the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting
/// would otherwise make every method here MainActor-isolated, which is exactly wrong for a type
/// whose whole job is shelling out to `/usr/bin/git` synchronously and getting called from
/// `Task.detached` closures all over `AppState` to keep that off the main thread. `rootURL: URL`
/// is the only stored state and is `Sendable`, so there's no actor-isolated state to protect.
nonisolated struct GitRepository {
    let rootURL: URL

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        let (output, _, exitCode) = try runRaw(arguments)
        if exitCode != 0 {
            throw GitError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    /// Runs git without treating a non-zero exit as an error, for commands
    /// (like `diff --no-index`) that use the exit code to report "differences found".
    private func runRaw(_ arguments: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = rootURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errData, encoding: .utf8) ?? ""
        return (output, errorOutput, process.terminationStatus)
    }

    /// The GitHub "owner" (user or org) for this repo's `origin` remote, parsed locally from the
    /// remote URL — no network call, so it works offline and for private repos without needing a
    /// GitHub token. Returns `nil` if there's no `origin` or it isn't a github.com URL.
    func githubOwner() -> String? {
        guard let url = try? run(["remote", "get-url", "origin"]) else { return nil }
        return Self.githubOwner(fromRemoteURL: url.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "git@github.com:owner/repo.git" or "https://github.com/owner/repo.git" -> "owner".
    static func githubOwner(fromRemoteURL url: String) -> String? {
        guard let range = url.range(of: "github.com[:/]", options: .regularExpression) else {
            return nil
        }
        let rest = url[range.upperBound...]
        guard let owner = rest.split(separator: "/").first, !owner.isEmpty else { return nil }
        return String(owner)
    }

    /// Derives the folder name git itself would use for a clone destination, e.g.
    /// "https://github.com/user/repo.git" -> "repo".
    static func repoName(fromURLString urlString: String) -> String {
        var name = (urlString as NSString).lastPathComponent
        if name.hasSuffix(".git") {
            name = String(name.dropLast(4))
        }
        return name.isEmpty ? "repository" : name
    }

    /// Runs `git clone` directly (not via the instance `run`/`runRaw` helpers, which pin
    /// `currentDirectoryURL` to an already-existing `rootURL` — the clone destination doesn't
    /// exist yet).
    static func clone(from urlString: String, into destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = destination.deletingLastPathComponent()
        process.arguments = ["clone", urlString, destination.path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        _ = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorOutput = String(data: errData, encoding: .utf8) ?? ""
            throw GitError.commandFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func branches() throws -> [GitBranch] {
        let output = try run(["for-each-ref", "--format=%(refname:short)|%(HEAD)", "refs/heads/"])
        return output
            .split(separator: "\n")
            .map { line -> GitBranch in
                let parts = line.split(separator: "|", maxSplits: 1)
                let name = String(parts[0])
                let isCurrent = parts.count > 1 && parts[1] == "*"
                return GitBranch(name: name, isCurrent: isCurrent)
            }
    }

    /// Two-letter porcelain codes git uses for unmerged (conflicted) paths — these don't fit the
    /// normal "prefer worktree char over index char" scheme since e.g. `AA`/`DD` have no `U` at all.
    private static let conflictStatusCodes: Set<String> = ["UU", "AA", "DD", "AU", "UA", "DU", "UD"]

    func statusEntries() throws -> [ChangedFile] {
        let output = try run(["status", "--porcelain=v1", "--untracked-files=all"])
        return output
            .split(separator: "\n")
            .compactMap { line -> ChangedFile? in
                guard line.count > 3 else { return nil }
                let indexStatus = line[line.startIndex]
                let workTreeStatus = line[line.index(after: line.startIndex)]
                var rawPath = String(line.dropFirst(3))

                let status: FileChangeStatus
                if Self.conflictStatusCodes.contains(String(indexStatus) + String(workTreeStatus)) {
                    status = .conflicted
                } else {
                    let statusChar = workTreeStatus != " " ? workTreeStatus : indexStatus
                    status = FileChangeStatus(rawValue: String(statusChar)) ?? .unknown
                }
                // Renamed entries are formatted as "old -> new" — only the destination path is
                // the file's current path.
                var oldPath: String?
                if status == .renamed, let arrowRange = rawPath.range(of: " -> ") {
                    oldPath = Self.unquoteGitPath(String(rawPath[..<arrowRange.lowerBound]))
                    rawPath = String(rawPath[arrowRange.upperBound...])
                }
                let path = Self.unquoteGitPath(rawPath)
                return ChangedFile(path: path, status: status, oldPath: oldPath)
            }
    }

    /// Latest filesystem modification date across the given working-tree-relative paths.
    /// Deleted files have nothing on disk to stat, so they're skipped rather than counted.
    func lastModifiedDate(for paths: [String]) -> Date? {
        let fileManager = FileManager.default
        return paths.compactMap { path -> Date? in
            let attributes = try? fileManager.attributesOfItem(atPath: rootURL.appendingPathComponent(path).path)
            return attributes?[.modificationDate] as? Date
        }.max()
    }

    /// Git quotes a pathname as a C-style double-quoted string (escaping spaces-adjacent
    /// quote/backslash characters and any non-ASCII bytes as octal escapes) whenever the raw
    /// path would otherwise be ambiguous in porcelain/name-status output. Left unquoted, a path
    /// like `"foo bar.txt"` gets passed to later git commands (checkout/clean/add) as if the
    /// file were literally named with quote characters, so those commands silently fail to find it.
    static func unquoteGitPath(_ raw: String) -> String {
        guard raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 else { return raw }
        let inner = raw.dropFirst().dropLast()
        var bytes: [UInt8] = []
        let chars = Array(inner)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                switch next {
                case "\"": bytes.append(0x22); i += 2
                case "\\": bytes.append(0x5C); i += 2
                case "n": bytes.append(0x0A); i += 2
                case "t": bytes.append(0x09); i += 2
                case "r": bytes.append(0x0D); i += 2
                case "a": bytes.append(0x07); i += 2
                case "b": bytes.append(0x08); i += 2
                case "f": bytes.append(0x0C); i += 2
                case "v": bytes.append(0x0B); i += 2
                default:
                    if next.isNumber {
                        var digits = ""
                        var j = i + 1
                        while j < chars.count, digits.count < 3, chars[j].isNumber {
                            digits.append(chars[j])
                            j += 1
                        }
                        if let value = UInt8(digits, radix: 8) {
                            bytes.append(value)
                            i = j
                        } else {
                            bytes.append(contentsOf: Array(String(c).utf8))
                            i += 1
                        }
                    } else {
                        bytes.append(contentsOf: Array(String(next).utf8))
                        i += 2
                    }
                }
            } else {
                bytes.append(contentsOf: Array(String(c).utf8))
                i += 1
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? raw
    }

    func diff(for file: ChangedFile) throws -> String {
        if file.status == .untracked {
            // `--no-index` exits 1 when a diff is found (not an error) and 2 on a real failure.
            let (stdout, stderr, exitCode) = try runRaw(["diff", "--no-index", "--", "/dev/null", file.path])
            if exitCode == 2 {
                throw GitError.commandFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return stdout
        }
        return try run(["diff", "--", file.path])
    }

    /// Like `runRaw`, but returns raw `Data` instead of decoding as UTF-8 — needed for binary
    /// blob contents (images) where `git show` output isn't valid text.
    private func runRawData(_ arguments: [String]) throws -> (stdout: Data, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = rootURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (outData, process.terminationStatus)
    }

    private func blobData(_ spec: String) -> Data? {
        guard let result = try? runRawData(["show", spec]) else { return nil }
        return result.exitCode == 0 ? result.stdout : nil
    }

    /// Returns the "before"/"after" raw bytes of a file for image diffing. A `nil` side means
    /// the file doesn't exist on that side (newly added, or deleted).
    func imageContents(for file: ChangedFile, in source: ChangeSource) -> (old: Data?, new: Data?) {
        switch source {
        case .workingChanges:
            let newData: Data? = file.status == .deleted
                ? nil
                : try? Data(contentsOf: rootURL.appendingPathComponent(file.path))
            let oldData: Data? = (file.status == .untracked || file.status == .added)
                ? nil
                : blobData("HEAD:\(file.path)")
            return (oldData, newData)
        case .stash:
            // An untracked file's blob lives under `stash@{0}^3` (the separate untracked-files
            // commit `-u` creates), not the main stash tree — `stash@{0}:path` fails outright for
            // it (confirmed empirically), so this needs its own branch rather than reusing the
            // tracked-file logic below.
            if file.status == .untracked {
                return (nil, blobData("stash@{0}^3:\(file.path)"))
            }
            let newData = file.status == .deleted ? nil : blobData("stash@{0}:\(file.path)")
            let oldData = file.status == .added ? nil : blobData("stash@{0}^1:\(file.path)")
            return (oldData, newData)
        case .commit(let commit):
            let newData = file.status == .deleted ? nil : blobData("\(commit.sha):\(file.path)")
            let oldData = file.status == .added ? nil : blobData("\(commit.sha)^:\(file.path)")
            return (oldData, newData)
        }
    }

    func checkout(branch: String) throws {
        try run(["checkout", branch])
    }

    /// Short SHA of HEAD, used to label a detached-HEAD state since there's no branch name to show.
    func currentHEADShortSHA() -> String? {
        (try? run(["rev-parse", "--short", "HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fetch() throws {
        try run(["fetch"])
    }

    func pull() throws {
        try run(["pull"])
    }

    /// Pushes the current branch, setting up its upstream on the first push if none exists yet.
    func push(branch: String) throws {
        do {
            try run(["push"])
        } catch let GitError.commandFailed(message) where message.contains("has no upstream branch") {
            try run(["push", "--set-upstream", "origin", branch])
        }
    }

    /// Ahead/behind counts of the current branch relative to its upstream, or `nil` if it has none.
    func aheadBehind() -> (ahead: Int, behind: Int)? {
        guard let output = try? run(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"]) else {
            return nil
        }
        let counts = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "\t" || $0 == " " })
            .compactMap { Int($0) }
        guard counts.count == 2 else { return nil }
        return (ahead: counts[1], behind: counts[0])
    }

    private static let fieldSeparator = "\u{1F}"

    func commitLog(branch: String, limit: Int = 200) throws -> [GitCommit] {
        let format = ["%H", "%h", "%s", "%at", "%an"].joined(separator: Self.fieldSeparator)
        let output = try run(["log", branch, "-n", String(limit), "--format=\(format)"])
        return output
            .split(separator: "\n")
            .compactMap { line -> GitCommit? in
                let parts = String(line).components(separatedBy: Self.fieldSeparator)
                guard parts.count == 5, let epochSeconds = TimeInterval(parts[3]) else { return nil }
                let date = Date(timeIntervalSince1970: epochSeconds)
                return GitCommit(sha: parts[0], shortSha: parts[1], summary: parts[2], date: date, author: parts[4])
            }
    }

    /// Parses `--name-status` output shared by both the commit and stash paths.
    private static func parseNameStatus(_ output: String) -> [ChangedFile] {
        output
            .split(separator: "\n")
            .compactMap { line -> ChangedFile? in
                let parts = line.split(separator: "\t")
                guard let first = parts.first, let last = parts.last, parts.count >= 2 else { return nil }
                let statusChar = first.first.map(String.init) ?? "?"
                let status = FileChangeStatus(rawValue: statusChar) ?? .unknown
                // Rename lines are "R100\told\tnew" — the middle field is the pre-rename path.
                let oldPath = (status == .renamed && parts.count >= 3) ? Self.unquoteGitPath(String(parts[1])) : nil
                return ChangedFile(path: Self.unquoteGitPath(String(last)), status: status, oldPath: oldPath)
            }
    }

    func filesChanged(in commit: GitCommit) throws -> [ChangedFile] {
        Self.parseNameStatus(try run(["show", "--format=", "--name-status", commit.sha]))
    }

    /// True if `ref` (a commit-ish) has a parent at the given index — used to detect whether a
    /// stash entry has an untracked-files commit (`^3`), which only exists when the stash was
    /// created with `-u`/`--include-untracked`.
    private func hasParent(_ ref: String) -> Bool {
        (try? run(["rev-parse", "--verify", "--quiet", ref])) != nil
    }

    /// Files touched by a stash entry. `git show <ref>` can't be used here the way it is for
    /// ordinary commits — a stash entry created with `-u` is a 3-parent commit, and `git show`'s
    /// default combined-diff format for merge commits only lists paths that differ from *every*
    /// parent, which silently drops untracked-only files (confirmed empirically: a stash holding
    /// only a new untracked file shows an empty `--name-status`, and `stash@{0}:path` fails
    /// outright for it since the untracked file lives in a separate `^3` tree, not the main one).
    /// Tracked changes are found via a plain 2-way diff against the base commit (`^1`) instead,
    /// which avoids the combined-diff format entirely; untracked files (if a `^3` parent exists)
    /// are enumerated directly from that parent's tree, since every path in it is untracked by
    /// definition — no diffing needed.
    func filesChanged(inStash ref: String = "stash@{0}") throws -> [ChangedFile] {
        var files = Self.parseNameStatus(try run(["diff", "--name-status", "\(ref)^1", ref]))
        if hasParent("\(ref)^3") {
            let untrackedOutput = try run(["ls-tree", "-r", "--name-only", "\(ref)^3"])
            files += untrackedOutput
                .split(separator: "\n")
                .map { ChangedFile(path: Self.unquoteGitPath(String($0)), status: .untracked) }
        }
        return files
    }

    func diff(for file: ChangedFile, in commit: GitCommit) throws -> String {
        try run(["show", commit.sha, "--", file.path])
    }

    /// See `filesChanged(inStash:)` for why a stash's tracked/untracked files need different
    /// bases: tracked changes diff against the base commit (`^1`); untracked files only exist
    /// under the separate `^3` parent, so they diff against that instead (base commit vs. `^3`
    /// reads as "file newly added," matching how untracked files show up everywhere else).
    func diff(for file: ChangedFile, inStash ref: String = "stash@{0}") throws -> String {
        let target = file.status == .untracked ? "\(ref)^3" : ref
        return try run(["diff", "\(ref)^1", target, "--", file.path])
    }

    func commit(message: String, paths: [String], unstagePaths: [String]) throws {
        // `git commit -- <pathspec>` fails on untracked files ("did not match any files"),
        // so stage the chosen paths explicitly first, then commit whatever is staged.
        // Unchecked files may already be staged from outside the app, so unstage them
        // first — otherwise a plain `git commit` (no pathspec) would sweep them in too.
        if !unstagePaths.isEmpty {
            try run(["reset", "--"] + unstagePaths)
        }
        try run(["add", "--"] + paths)
        try run(["commit", "-m", message])
    }

    enum MergeResult {
        case upToDate
        case fastForward
        case merged
        case conflicts
    }

    /// True while a merge is stopped partway through (conflicts, or an explicit `--no-commit`),
    /// i.e. `.git/MERGE_HEAD` exists — git's own ground truth for "a merge is in progress".
    func isMergeInProgress() -> Bool {
        FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(".git/MERGE_HEAD").path)
    }

    /// Git's suggested merge commit message (`.git/MERGE_MSG`), used to prefill the commit box
    /// when finishing a merge.
    func mergeMessage() -> String? {
        try? String(contentsOf: rootURL.appendingPathComponent(".git/MERGE_MSG"), encoding: .utf8)
    }

    /// Merges `branch` into the current branch. A merge that stops on conflicts exits 1 by
    /// git's own design, not as a process failure, so exit code alone can't distinguish
    /// "conflicts" from a real error (dirty worktree, unrelated histories, etc. also exit 1) —
    /// `MERGE_HEAD` presence after a non-zero exit is the reliable signal that git stopped
    /// mid-merge rather than failing outright.
    func merge(branch: String) throws -> MergeResult {
        let (stdout, stderr, exitCode) = try runRaw(["merge", "--no-edit", branch])
        if exitCode == 0 {
            if stdout.contains("Already up to date") { return .upToDate }
            if stdout.contains("Fast-forward") { return .fastForward }
            return .merged
        }
        if isMergeInProgress() { return .conflicts }
        throw GitError.commandFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func mergeAbort() throws {
        try run(["merge", "--abort"])
    }

    /// Completes an in-progress merge: stages the given (now-resolved) paths and commits with
    /// the given message. Unlike `commit(message:paths:unstagePaths:)`, this never unstages
    /// anything — a merge commit must include the full merge, not a partial selection.
    func completeMerge(message: String, resolvedPaths: [String]) throws {
        if !resolvedPaths.isEmpty {
            try run(["add", "--"] + resolvedPaths)
        }
        // `-m` alone defaults to `--cleanup=whitespace`, not `strip` — without this, the
        // `# Conflicts:` comment lines from MERGE_MSG (prefilled into the commit box) would be
        // baked into the actual commit message verbatim instead of being dropped as advisory text.
        try run(["commit", "-m", message, "--cleanup=strip"])
    }

    /// Stages a conflicted file once the user has hand-edited it to remove the conflict markers —
    /// `git status` only stops reporting a path as unmerged (`UU`) once it's staged, so this is
    /// the actual "mark as resolved" action, not just bookkeeping.
    func markResolved(_ file: ChangedFile) throws {
        try run(["add", "--", file.path])
    }

    /// Raw working-tree contents of a conflicted file, which already contains git's
    /// `<<<<<<<`/`=======`/`>>>>>>>` markers — shown as-is in the diff pane rather than as a
    /// real diff, since `git diff` of a conflicted path isn't the useful thing to show here.
    func conflictedFileContents(_ file: ChangedFile) throws -> String {
        try String(contentsOf: rootURL.appendingPathComponent(file.path), encoding: .utf8)
    }

    func stashList() -> [String] {
        (try? run(["stash", "list"]))?
            .split(separator: "\n")
            .map(String.init) ?? []
    }

    func stashCount() -> Int {
        stashList().count
    }

    /// Stashes dirty paths. Empty `paths` stashes everything dirty (used for the
    /// auto-stash-on-checkout-failure path in `AppState.selectBranch`); non-empty `paths`
    /// stashes only those files, matching the per-file precedent set by `discardChanges`/`ignoreFiles`.
    func stashChanges(paths: [String], includeUntracked: Bool) throws {
        var arguments = ["stash", "push"]
        if includeUntracked {
            arguments.append("-u")
        }
        if !paths.isEmpty {
            arguments.append("--")
            arguments.append(contentsOf: paths)
        }
        try run(arguments)
    }

    enum StashRestoreResult {
        case success
        case conflicts
    }

    /// Applies and drops the top-of-stack stash (`git stash pop`). A conflicting pop exits
    /// nonzero but, unlike a conflicting merge, leaves no `.git/MERGE_HEAD` marker — the only
    /// ground truth available afterward is `git status` itself reporting conflicted paths, which
    /// is what distinguishes a real conflict (stash left in place, working tree gets conflict
    /// markers) from a plain pre-check failure (stash left in place, nothing on disk changed).
    func restoreStash() throws -> StashRestoreResult {
        let (_, stderr, exitCode) = try runRaw(["stash", "pop"])
        if exitCode == 0 { return .success }
        if let entries = try? statusEntries(), entries.contains(where: { $0.status == .conflicted }) {
            return .conflicts
        }
        throw GitError.commandFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Drops the top-of-stack stash without applying it.
    func discardStash() throws {
        try run(["stash", "drop"])
    }

    func discardChanges(for file: ChangedFile) throws {
        if file.status == .untracked {
            try run(["clean", "-f", "--", file.path])
        } else {
            try run(["checkout", "--", file.path])
        }
    }

    /// Discards a batch of files in one pass, splitting into an untracked group (`clean`) and a
    /// tracked group (`checkout`) since the two need different git subcommands.
    func discardChanges(for files: [ChangedFile]) throws {
        let untracked = files.filter { $0.status == .untracked }.map(\.path)
        let tracked = files.filter { $0.status != .untracked }.map(\.path)
        if !untracked.isEmpty {
            try run(["clean", "-f", "--"] + untracked)
        }
        if !tracked.isEmpty {
            try run(["checkout", "--"] + tracked)
        }
    }

    /// Appends the path to the repo's top-level `.gitignore`, creating it if needed.
    func ignoreFile(_ file: ChangedFile) throws {
        try ignoreFiles([file])
    }

    /// Appends multiple paths to the repo's top-level `.gitignore` in one write, creating it if needed.
    func ignoreFiles(_ files: [ChangedFile]) throws {
        let gitignoreURL = rootURL.appendingPathComponent(".gitignore")
        var existing = (try? String(contentsOf: gitignoreURL, encoding: .utf8)) ?? ""
        if !existing.isEmpty && !existing.hasSuffix("\n") {
            existing += "\n"
        }
        existing += files.map(\.path).joined(separator: "\n") + "\n"
        try existing.write(to: gitignoreURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Convenience wrappers for selection-driven loads

    /// Plain synchronous throwing calls — the caller (`AppState`) is responsible for running
    /// these via `Task.detached` to get off the main thread. Marking these `async`+`nonisolated`
    /// does **not** achieve that on its own: this project's build enables Swift's
    /// `NonisolatedNonsendingByDefault` upcoming feature, under which a `nonisolated async`
    /// function runs on the *caller's* actor by default rather than hopping to a background
    /// executor — so an `await` from `@MainActor`-isolated `AppState` would still block the main
    /// thread here, which is exactly what caused a `SIGSEGV` crashing inside
    /// `-[NSConcreteTask waitUntilExit]` reentered from the main run loop.
    func changedFilesWithStatus(for source: ChangeSource) throws -> (files: [ChangedFile], statusEntries: [ChangedFile]) {
        switch source {
        case .workingChanges:
            let entries = try statusEntries()
            return (entries, entries)
        case .stash:
            let files = try filesChanged(inStash: "stash@{0}")
            let statusEntries = (try? self.statusEntries()) ?? []
            return (files, statusEntries)
        case .commit(let commit):
            let files = try filesChanged(in: commit)
            let statusEntries = (try? self.statusEntries()) ?? []
            return (files, statusEntries)
        }
    }

    /// See `changedFilesWithStatus(for:)`.
    func diffText(for file: ChangedFile, in source: ChangeSource) throws -> String {
        if file.status == .conflicted {
            // Raw working-tree contents (with git's own conflict markers), not a real diff —
            // `git diff` of a conflicted path isn't the useful thing to show here.
            return try conflictedFileContents(file)
        }
        switch source {
        case .workingChanges:
            return try diff(for: file)
        case .stash:
            return try diff(for: file, inStash: "stash@{0}")
        case .commit(let commit):
            return try diff(for: file, in: commit)
        }
    }
}
