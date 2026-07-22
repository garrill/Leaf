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
    case unknown

    var label: String {
        switch self {
        case .modified: return "Modified"
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .untracked: return "Untracked"
        case .unknown: return "Changed"
        }
    }
}

struct ChangedFile: Identifiable, Hashable {
    let path: String
    let status: FileChangeStatus

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
        if abs(date.timeIntervalSinceNow) < 60 {
            return "Just now"
        }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

enum ChangeSource: Hashable {
    case workingChanges
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

struct GitRepository {
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

    func statusEntries() throws -> [ChangedFile] {
        let output = try run(["status", "--porcelain=v1", "--untracked-files=all"])
        return output
            .split(separator: "\n")
            .compactMap { line -> ChangedFile? in
                guard line.count > 3 else { return nil }
                let indexStatus = line[line.startIndex]
                let workTreeStatus = line[line.index(after: line.startIndex)]
                var rawPath = String(line.dropFirst(3))

                let statusChar = workTreeStatus != " " ? workTreeStatus : indexStatus
                let status = FileChangeStatus(rawValue: String(statusChar)) ?? .unknown
                // Renamed entries are formatted as "old -> new" — only the destination path is
                // the file's current path.
                if status == .renamed, let arrowRange = rawPath.range(of: " -> ") {
                    rawPath = String(rawPath[arrowRange.upperBound...])
                }
                let path = Self.unquoteGitPath(rawPath)
                return ChangedFile(path: path, status: status)
            }
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

    func filesChanged(in commit: GitCommit) throws -> [ChangedFile] {
        let output = try run(["show", "--format=", "--name-status", commit.sha])
        return output
            .split(separator: "\n")
            .compactMap { line -> ChangedFile? in
                let parts = line.split(separator: "\t")
                guard let first = parts.first, let last = parts.last, parts.count >= 2 else { return nil }
                let statusChar = first.first.map(String.init) ?? "?"
                let status = FileChangeStatus(rawValue: statusChar) ?? .unknown
                return ChangedFile(path: Self.unquoteGitPath(String(last)), status: status)
            }
    }

    func diff(for file: ChangedFile, in commit: GitCommit) throws -> String {
        try run(["show", commit.sha, "--", file.path])
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
}
