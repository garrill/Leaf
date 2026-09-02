import Foundation

struct GitBranch: Identifiable, Hashable {
    let name: String
    let isCurrent: Bool

    var id: String { name }
}

struct GitTag: Identifiable, Hashable {
    let name: String
    let sha: String

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

nonisolated struct ChangedFile: Identifiable, Hashable {
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

/// Splits a live process's stderr into lines as chunks arrive so a caller can render git's progress
/// meter (e.g. `push`'s "Writing objects: 42% (5/12)") as it updates rather than only after the
/// process exits. git repaints that meter in place via `\r`, not `\n`, so lines are split on either.
/// `append(_:)` is called from the stderr drain thread only, but `@unchecked Sendable` + the lock
/// keep it safe even if that ever changes; the raw bytes are collected separately by the caller.
private nonisolated final class ProgressLineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var lineBuffer = Data()
    private let handler: @Sendable (String) -> Void

    init(handler: @escaping @Sendable (String) -> Void) {
        self.handler = handler
    }

    func append(_ chunk: Data) {
        lock.lock()
        lineBuffer.append(chunk)
        var lines: [String] = []
        while let index = lineBuffer.firstIndex(where: { $0 == 0x0d || $0 == 0x0a }) {
            let lineData = lineBuffer[..<index]
            lineBuffer.removeSubrange(...index)
            if let line = String(data: lineData, encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { lines.append(trimmed) }
            }
        }
        lock.unlock()
        for line in lines { handler(line) }
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
    private func run(_ arguments: [String], progress: (@Sendable (String) -> Void)? = nil) throws -> String {
        let (output, errorOutput, exitCode) = try runRaw(arguments, progress: progress)
        if exitCode != 0 {
            // git writes its actual fatal/error text to stderr, not stdout — stdout is usually
            // empty on failure, which previously made every `GitError.commandFailed` message
            // blank and broke callers (like `push`) that pattern-match on the message text.
            let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(message.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : message)
        }
        return output
    }

    /// Runs git without treating a non-zero exit as an error, for commands
    /// (like `diff --no-index`) that use the exit code to report "differences found".
    ///
    /// When `progress` is supplied, stderr is streamed line-by-line as the process runs (instead of
    /// read in one shot at the end) so callers like `push(branch:progress:)` can surface git's own
    /// progress meter live. git repaints that meter via `\r`, not `\n`, so `ProgressLineAccumulator`
    /// splits on either.
    private func runRaw(_ arguments: [String], progress: (@Sendable (String) -> Void)? = nil) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = rootURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let accumulator = progress.map { ProgressLineAccumulator(handler: $0) }

        try process.run()

        // Drain both pipes on dedicated background threads concurrently — reading either pipe
        // fully before touching the other can deadlock: if the unread pipe's OS buffer (~64KB)
        // fills up, git blocks trying to write to it, the process never exits/closes its pipes,
        // and the read on the other pipe never sees EOF. A verbose command with large output on
        // both streams (e.g. a noisy merge/push) could hang the app indefinitely without this.
        //
        // These are raw `Thread`s, not `DispatchQueue.global`. `runRaw` is called synchronously
        // from `Task.detached` closures, which run on the Swift concurrency cooperative pool —
        // the same capped workqueue that backs `DispatchQueue.global`. If enough of those tasks
        // are parked here in a blocking wait at once, the workqueue is at its thread ceiling and
        // never schedules the drain blocks, so they never run and every caller wedges. (Swift
        // Testing's parallel suites hit exactly this.) A dedicated `Thread` is always scheduled
        // regardless of pool pressure. QoS is pinned to match the (typically `.userInitiated`)
        // caller blocking on the semaphores below, so the Thread Performance Checker doesn't
        // flag the wait as a priority inversion.
        //
        // stderr is drained the same way whether or not `progress` is set (rather than via a
        // `FileHandle.readabilityHandler`): a readability handler fires on a private GCD queue
        // that races the teardown read on the calling thread, and clearing it doesn't wait for
        // an in-flight block — so the handler could read git's final "fatal: …" chunk off the
        // pipe (making the teardown read see only EOF) but not yet have appended it to the
        // accumulator when `finalData` is read, surfacing as a bogus `commandFailed("")`.
        var outData = Data()
        var errData = Data()
        let stdoutDone = DispatchSemaphore(value: 0)
        let stderrDone = DispatchSemaphore(value: 0)

        let stdoutThread = Thread {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            stdoutDone.signal()
        }
        let stderrThread = Thread {
            let handle = stderr.fileHandleForReading
            while case let chunk = handle.availableData, !chunk.isEmpty {
                errData.append(chunk)
                accumulator?.append(chunk)
            }
            stderrDone.signal()
        }
        for thread in [stdoutThread, stderrThread] {
            thread.qualityOfService = .userInitiated
            thread.stackSize = 1 << 20
            thread.start()
        }

        process.waitUntilExit()
        stdoutDone.wait()
        stderrDone.wait()

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

    /// Whether `url` is a git repository's working tree root — i.e. it has a `.git` entry.
    /// Covers both a plain repo (`.git` directory) and a worktree/submodule (`.git` file
    /// pointing elsewhere), same as `git rev-parse` would accept, without shelling out.
    static func isGitRepository(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    /// Whether `/usr/bin/git` actually works. On a Mac without Xcode or the Command Line Tools
    /// installed, `/usr/bin/git` still exists as a stub that pops up the system "install Command
    /// Line Tools" dialog and exits non-zero rather than failing to launch — so a `try? Process()`
    /// existence check isn't enough; this has to actually run it and check the result.
    static func isGitAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--version"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return false
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return false }
        let output = String(data: outData, encoding: .utf8) ?? ""
        return output.hasPrefix("git version")
    }

    /// Runs `git clone` directly (not via the instance `run`/`runRaw` helpers, which pin
    /// `currentDirectoryURL` to an already-existing `rootURL` — the clone destination doesn't
    /// exist yet). `--progress` plus the same live-stderr-streaming setup as `runRaw(_:progress:)`
    /// lets a caller (`AppState.cloneRepo`) surface git's own "Receiving objects: 42% (5/12)"-style
    /// meter while the clone is still in flight.
    static func clone(from urlString: String, into destination: URL, progress: (@Sendable (String) -> Void)? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = destination.deletingLastPathComponent()
        process.arguments = ["clone", "--progress", urlString, destination.path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let accumulator = progress.map { ProgressLineAccumulator(handler: $0) }

        try process.run()

        // Drain both pipes on dedicated background threads — see `runRaw(_:progress:)` for the
        // full rationale: reading one pipe fully before the other can deadlock a chatty clone,
        // a raw `Thread` (not `DispatchQueue.global`) stays clear of cooperative-pool starvation,
        // and looping `availableData` into the accumulator avoids the readability-handler race
        // where git's final stderr chunk is read off the pipe but not yet appended when the
        // result is inspected.
        var errData = Data()
        let stdoutDone = DispatchSemaphore(value: 0)
        let stderrDone = DispatchSemaphore(value: 0)

        let stdoutThread = Thread {
            _ = stdout.fileHandleForReading.readDataToEndOfFile()
            stdoutDone.signal()
        }
        let stderrThread = Thread {
            let handle = stderr.fileHandleForReading
            while case let chunk = handle.availableData, !chunk.isEmpty {
                errData.append(chunk)
                accumulator?.append(chunk)
            }
            stderrDone.signal()
        }
        for thread in [stdoutThread, stderrThread] {
            thread.qualityOfService = .userInitiated
            thread.stackSize = 1 << 20
            thread.start()
        }

        process.waitUntilExit()
        stdoutDone.wait()
        stderrDone.wait()

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

    func tags() throws -> [GitTag] {
        let output = try run(["for-each-ref", "--format=%(refname:short)|%(objectname)", "refs/tags/"])
        return output
            .split(separator: "\n")
            .compactMap { line -> GitTag? in
                let parts = line.split(separator: "|", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return GitTag(name: String(parts[0]), sha: String(parts[1]))
            }
    }

    func createTag(named name: String, at sha: String) throws {
        try run(["tag", name, sha])
    }

    func deleteTag(named name: String) throws {
        try run(["tag", "-d", name])
    }

    /// Two-letter porcelain codes git uses for unmerged (conflicted) paths — these don't fit the
    /// normal "prefer worktree char over index char" scheme since e.g. `AA`/`DD` have no `U` at all.
    private static let conflictStatusCodes: Set<String> = ["UU", "AA", "DD", "AU", "UA", "DU", "UD"]

    func statusEntries() throws -> [ChangedFile] {
        // `--no-optional-locks` stops git from refreshing/rewriting `.git/index`'s stat cache as
        // a side effect of `status` — without it, every status call bumps the index's mtime,
        // which `RepoWatcher`'s FSEvents stream (watching the whole repo, `.git` included) picks
        // up as an external change and reacts to by calling `handleExternalChange()`, which in
        // turn calls `statusEntries()` again while `.workingChanges` is selected — a self-sustaining
        // refresh loop that starves in-flight diff loads (their cache-generation guard keeps
        // getting invalidated before the git process returns) and, once the user selects a commit
        // or stash, zeroes the sidebar's uncommitted-changes count via a stray leftover firing.
        let output = try run(["--no-optional-locks", "status", "--porcelain=v1", "--untracked-files=all"])
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
                } else if indexStatus == "R" || workTreeStatus == "R" {
                    // A rename can only be reported in the index column ("R "/"RM"/"RD") — never
                    // let a worktree-column edit on top of it (e.g. "RM") fall through to
                    // `.modified` below and lose the rename/oldPath split.
                    status = .renamed
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

    func diff(for file: ChangedFile, ignoreWhitespace: Bool = false) throws -> String {
        let whitespaceFlags = ignoreWhitespace ? ["-w"] : []
        if file.status == .untracked {
            // `--no-index` exits 1 when a diff is found (not an error) and 2 on a real failure.
            let (stdout, stderr, exitCode) = try runRaw(["diff", "--no-index"] + whitespaceFlags + ["--", "/dev/null", file.path])
            if exitCode == 2 {
                throw GitError.commandFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return stdout
        }
        // Against `HEAD`, not a plain `git diff` (which is index-vs-working-tree only) — the
        // "Uncommitted Changes" row is meant to show *everything* not yet committed, staged or
        // not. A file that's fully staged with no further edits has an empty index/working-tree
        // delta, so a plain `git diff` came back empty and the pane showed nothing even though
        // `statusEntries()` (which diffs against `HEAD` via porcelain status) correctly still
        // listed the file as changed.
        return try run(["diff", "HEAD"] + whitespaceFlags + ["--", file.path])
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

    /// Creates a new branch off HEAD and switches to it in one step (`git checkout -b`).
    func createBranch(named name: String) throws {
        try run(["checkout", "-b", name])
    }

    /// Deletes a local branch (`git branch -D`) — a force delete rather than `-d` since the
    /// caller already shows its own "cannot be undone" confirmation, so there's no need for git's
    /// separate "not fully merged" safety check to block it with a second, less clear error.
    func deleteBranch(named name: String) throws {
        try run(["branch", "-D", name])
    }

    /// Short SHA of HEAD, used to label a detached-HEAD state since there's no branch name to show.
    func currentHEADShortSHA() -> String? {
        (try? run(["rev-parse", "--short", "HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fetch() throws {
        try run(["fetch"])
    }

    /// `--no-rebase`: a plain `git pull` on a repo/user with no `pull.rebase`/`pull.ff` config set
    /// (git 2.27+) refuses outright with "fatal: Need to specify how to reconcile divergent
    /// branches" instead of pulling — Leaf has no rebase UI, so it always resolves divergence the
    /// traditional way (a merge commit) regardless of what's configured globally, rather than
    /// surfacing that fatal error and asking the user to go set a config value themselves.
    func pull() throws {
        try run(["pull", "--no-rebase"])
    }

    /// Pushes the current branch, setting up its upstream on the first push if none exists yet.
    /// `--progress` forces git to emit its normal progress meter even though stderr here is a pipe,
    /// not a tty (git otherwise suppresses it), which `progress` receives one line at a time.
    func push(branch: String, progress: (@Sendable (String) -> Void)? = nil) throws {
        do {
            try run(["push", "--progress"], progress: progress)
        } catch let GitError.commandFailed(message) where message.contains("has no upstream branch") {
            try run(["push", "--progress", "--set-upstream", "origin", branch], progress: progress)
        }
    }

    /// Combined status for the sidebar's per-repo status icon — count of files with uncommitted
    /// changes, plus ahead/behind vs. the upstream branch. Two separate git calls, same as
    /// `statusEntries()`/`aheadBehind()` are already used individually elsewhere; bundled into one
    /// struct so `RepoRowView` has a single value to poll for and store.
    struct SidebarSyncStatus: Equatable {
        var uncommittedChangeCount: Int
        var hasUpstream: Bool
        var aheadCount: Int
        var behindCount: Int
    }

    func sidebarSyncStatus() -> SidebarSyncStatus {
        let uncommittedChangeCount = (try? statusEntries().count) ?? 0
        guard let counts = aheadBehind() else {
            return SidebarSyncStatus(uncommittedChangeCount: uncommittedChangeCount, hasUpstream: false, aheadCount: 0, behindCount: 0)
        }
        return SidebarSyncStatus(uncommittedChangeCount: uncommittedChangeCount, hasUpstream: true, aheadCount: counts.ahead, behindCount: counts.behind)
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

    func diff(for file: ChangedFile, in commit: GitCommit, ignoreWhitespace: Bool = false) throws -> String {
        let whitespaceFlags = ignoreWhitespace ? ["-w"] : []
        return try run(["show"] + whitespaceFlags + [commit.sha, "--", file.path])
    }

    /// See `filesChanged(inStash:)` for why a stash's tracked/untracked files need different
    /// bases: tracked changes diff against the base commit (`^1`); untracked files only exist
    /// under the separate `^3` parent, so they diff against that instead (base commit vs. `^3`
    /// reads as "file newly added," matching how untracked files show up everywhere else).
    func diff(for file: ChangedFile, inStash ref: String = "stash@{0}", ignoreWhitespace: Bool = false) throws -> String {
        let target = file.status == .untracked ? "\(ref)^3" : ref
        let whitespaceFlags = ignoreWhitespace ? ["-w"] : []
        return try run(["diff", "\(ref)^1", target] + whitespaceFlags + ["--", file.path])
    }

    /// Whether an `origin` remote is configured at all — distinct from `hasUpstream`/`aheadBehind`
    /// (which are about the *current branch*'s tracking relationship), since a fresh local branch
    /// with no upstream yet can still have somewhere to push to.
    func hasOriginRemote() -> Bool {
        (try? run(["remote", "get-url", "origin"])) != nil
    }

    /// Undoes the most recent commit while leaving the working tree and index exactly as they
    /// were right before it — `--soft` only moves HEAD back to the parent commit, so whatever was
    /// staged/unstaged going into the commit reappears exactly the same way against the new HEAD.
    func undoLastCommit() throws {
        try run(["reset", "--soft", "HEAD~1"])
    }

    func commit(message: String, paths: [String], unstagePaths: [String]) throws {
        // `git commit -- <pathspec>` fails on untracked files ("did not match any files"),
        // so stage the chosen paths explicitly first, then commit whatever is staged.
        // Unchecked files may already be staged from outside the app, so unstage them
        // first — otherwise a plain `git commit` (no pathspec) would sweep them in too.
        if !unstagePaths.isEmpty {
            try run(["reset", "--"] + unstagePaths)
        }
        // A path that's already fully staged with nothing left in the working tree — most often
        // a deletion staged outside Leaf, or left staged by an earlier aborted commit — exists
        // in neither the working tree nor the index, so `git add <path>` (even `-A`) aborts the
        // whole commit with "pathspec '…' did not match any files". It's already staged exactly
        // as the diff shows, and the pathspec-less `git commit` below sweeps in the whole index,
        // so the fix is simply not to re-add it.
        let pathsToStage = paths.filter { path in
            if FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(path).path) {
                return true
            }
            // Absent from the working tree: only worth an `add` if it's still in the index with
            // an unstaged change to pick up (a `git rm` that wasn't staged). If it's not even in
            // the index, it's an already-staged removal — skip it.
            return (try? run(["ls-files", "--error-unmatch", "--", path])) != nil
        }
        // `-f`: `paths` only ever comes from `statusEntries()`, which never surfaces ignored
        // *untracked* files (no `--ignored` flag) — so any path here that also matches a
        // `.gitignore` pattern is necessarily already tracked (e.g. committed before the
        // pattern existed). Plain `git add` refuses those with a nonzero exit even though the
        // file is already tracked, which would otherwise abort the whole commit before
        // `git commit` ever runs, leaving the file staged but nothing committed.
        if !pathsToStage.isEmpty {
            try run(["add", "-f", "--"] + pathsToStage)
        }
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

    enum StashApplyOutcome {
        case success
        /// Paths git reported conflicted (`UU`/etc. — see `FileChangeStatus.conflicted`) after
        /// the apply.
        case conflicts(paths: [String])
    }

    /// Applies the top-of-stack stash *without* deciding whether to drop it — that's left to the
    /// caller via `dropStash()`/`undoStashApply(conflictedPaths:)`, so an interactive caller can
    /// ask the user what to do about a conflicting apply before committing to anything, rather
    /// than a non-interactive caller's blanket "drop regardless" (`restoreStash()`, below).
    /// A conflicting apply exits nonzero but, unlike a conflicting merge, leaves no
    /// `.git/MERGE_HEAD` marker — the only ground truth available afterward is `git status`
    /// itself reporting conflicted paths, which is what distinguishes a real conflict (working
    /// tree gets conflict markers) from a plain pre-check failure (nothing on disk changed).
    func applyStash() throws -> StashApplyOutcome {
        let (_, stderr, exitCode) = try runRaw(["stash", "apply"])
        if exitCode == 0 { return .success }
        let conflictedPaths = (try? statusEntries())?.filter { $0.status == .conflicted }.map(\.path) ?? []
        guard !conflictedPaths.isEmpty else {
            throw GitError.commandFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .conflicts(paths: conflictedPaths)
    }

    /// Drops the top-of-stack stash without applying it — also the "keep the conflict I just
    /// applied, but remove the now-redundant stash entry" half of resolving `applyStash()`.
    func dropStash() throws {
        try run(["stash", "drop"])
    }

    /// Reverts a conflicting `applyStash()` attempt without dropping the stash: restores the
    /// given paths to their pre-apply `HEAD` contents, discarding the conflict markers
    /// `applyStash()` just wrote, so the working tree ends up exactly as if `applyStash()` had
    /// never been called — the "cancel this restore" half of resolving `applyStash()`.
    func undoStashApply(conflictedPaths: [String]) throws {
        try run(["checkout", "HEAD", "--"] + conflictedPaths)
    }

    /// Applies the top-of-stack stash and drops it regardless of outcome (`applyStash()` +
    /// always `dropStash()`) — for a non-interactive caller (the auto-stash-before-checkout path
    /// in `AppState.selectBranch`) that has nowhere to surface `applyStash()`'s three-way
    /// keep/drop/undo choice and just needs *a* answer: by the time a conflict happens, its
    /// content is already materialized into the working tree as `<<<<<<<`/`>>>>>>>` markers (the
    /// same place `Uncommitted Changes`' own "Mark Resolved" flow expects to find it), so leaving
    /// a stale copy behind in `Stashed Changes` too would just double up the same change with
    /// nothing left to "try again" from.
    func restoreStash() throws -> StashApplyOutcome {
        let outcome = try applyStash()
        try dropStash()
        return outcome
    }

    func discardChanges(for file: ChangedFile) throws {
        try discardChanges(for: [file])
    }

    /// Discards a batch of files in one pass, splitting into an untracked group (`clean`) and a
    /// tracked group (`checkout`) since the two need different git subcommands. Rather than
    /// deleting/overwriting the pre-discard working-tree contents outright, each affected path's
    /// current on-disk version (if any — a `.deleted` file has none) is first moved to the Trash,
    /// so a discard is recoverable there instead of being unrecoverably gone.
    func discardChanges(for files: [ChangedFile]) throws {
        for file in files {
            let url = rootURL.appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
        // Untracked files needed no further action: they're already gone from disk, moved to
        // the Trash above, with nothing in git's index to restore.
        //
        // `.added`/`.renamed` paths are staged but have no HEAD entry to check out from (a new
        // path a plain `checkout HEAD --` would reject as unknown to git at HEAD) — `reset`
        // unstages them, leaving them fully gone since the on-disk copy was already trashed above.
        //
        // Everything else needs restoring from HEAD, not just the index: a file can be modified
        // *and* already staged (e.g. `git add`d outside Leaf, or left staged by a previous action
        // in Leaf) — a plain `checkout -- path` only restores the worktree from the index, which
        // is a no-op when the two already match, silently failing to discard the staged change.
        let staged = files.filter { $0.status == .added || $0.status == .renamed }.map(\.path)
        if !staged.isEmpty {
            try run(["reset", "--"] + staged)
        }
        let tracked = files.filter { $0.status != .untracked && $0.status != .added && $0.status != .renamed }.map(\.path)
        if !tracked.isEmpty {
            try run(["checkout", "HEAD", "--"] + tracked)
        }
    }

    /// Appends the path to the repo's top-level `.gitignore`, creating it if needed.
    func ignoreFile(_ file: ChangedFile) throws {
        try ignoreFiles([file])
    }

    /// Appends multiple paths to the repo's top-level `.gitignore` in one write, creating it if needed.
    func ignoreFiles(_ files: [ChangedFile]) throws {
        try appendToGitignore(files.map(\.path))
    }

    private func appendToGitignore(_ paths: [String]) throws {
        let gitignoreURL = rootURL.appendingPathComponent(".gitignore")
        var existing = (try? String(contentsOf: gitignoreURL, encoding: .utf8)) ?? ""
        if !existing.isEmpty && !existing.hasSuffix("\n") {
            existing += "\n"
        }
        existing += paths.joined(separator: "\n") + "\n"
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
            // The working-tree summary is independent of the stash selection. Fetching it here
            // made every click on Stashed Changes launch a second git process for no benefit.
            return (files, [])
        case .commit(let commit):
            let files = try filesChanged(in: commit)
            // Ditto for history navigation: a commit's file list needs `git show`, not a fresh
            // working-tree status query. The summary is refreshed on repository snapshots and
            // filesystem notifications instead.
            return (files, [])
        }
    }

    /// Above this size, `diffText(for:in:)` skips generating a diff entirely. Actually running
    /// `git diff`/`git show` is fast even on a huge file, but the result then gets fed to
    /// `DiffCodeTextView` (a real `NSTextView`) plus word-diff/syntax-highlight passes on the main
    /// thread — laying out hundreds of MB of text there is what actually freezes the UI, confirmed
    /// against a >100MB SQL dump accidentally committed into a repo.
    static let maxDiffableFileSize: Int64 = 5 * 1024 * 1024

    /// Cheap upper-bound size check (a `stat` or `git cat-file -s`, never the full diff) for
    /// whether `file` is too large to diff — called before `diffText(for:in:)` invokes any real
    /// diff/show command. Images are exempted since they're rendered as images, not diff text.
    func isFileTooLargeToDiff(_ file: ChangedFile, in source: ChangeSource) -> Bool {
        guard file.status != .conflicted, !file.isLikelyImage else { return false }
        let size = fileSize(for: file, in: source)
        return size > Self.maxDiffableFileSize
    }

    /// The larger of the "old"/"new" sides' sizes (whichever exist), so a huge file is caught
    /// whether it was added, deleted, or modified. A side that can't be determined (e.g. a
    /// deleted file with no reachable blob) contributes 0 rather than failing the whole check.
    private func fileSize(for file: ChangedFile, in source: ChangeSource) -> Int64 {
        func onDiskSize() -> Int64 {
            let attrs = try? FileManager.default.attributesOfItem(atPath: rootURL.appendingPathComponent(file.path).path)
            return (attrs?[.size] as? Int64) ?? Int64((attrs?[.size] as? Int) ?? 0)
        }
        switch source {
        case .workingChanges:
            let newSize = file.status == .deleted ? 0 : onDiskSize()
            let oldSize = (file.status == .untracked || file.status == .added) ? 0 : blobSize("HEAD:\(file.path)")
            return max(newSize, oldSize)
        case .stash:
            let ref = "stash@{0}"
            if file.status == .untracked {
                return blobSize("\(ref)^3:\(file.path)")
            }
            let newSize = file.status == .deleted ? 0 : blobSize("\(ref):\(file.path)")
            let oldSize = file.status == .added ? 0 : blobSize("\(ref)^1:\(file.path)")
            return max(newSize, oldSize)
        case .commit(let commit):
            let newSize = file.status == .deleted ? 0 : blobSize("\(commit.sha):\(file.path)")
            let oldSize = file.status == .added ? 0 : blobSize("\(commit.sha)^:\(file.path)")
            return max(newSize, oldSize)
        }
    }

    private func blobSize(_ spec: String) -> Int64 {
        guard let output = try? run(["cat-file", "-s", spec]) else { return 0 }
        return Int64(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// See `changedFilesWithStatus(for:)`.
    func diffText(for file: ChangedFile, in source: ChangeSource, ignoreWhitespace: Bool = false) throws -> String {
        if file.status == .conflicted {
            // Raw working-tree contents (with git's own conflict markers), not a real diff —
            // `git diff` of a conflicted path isn't the useful thing to show here.
            return try conflictedFileContents(file)
        }
        switch source {
        case .workingChanges:
            return try diff(for: file, ignoreWhitespace: ignoreWhitespace)
        case .stash:
            return try diff(for: file, inStash: "stash@{0}", ignoreWhitespace: ignoreWhitespace)
        case .commit(let commit):
            return try diff(for: file, in: commit, ignoreWhitespace: ignoreWhitespace)
        }
    }
}
