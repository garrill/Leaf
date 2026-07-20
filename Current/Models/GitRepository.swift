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
                let path = String(line.dropFirst(3))

                let statusChar = workTreeStatus != " " ? workTreeStatus : indexStatus
                let status = FileChangeStatus(rawValue: String(statusChar)) ?? .unknown
                return ChangedFile(path: path, status: status)
            }
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
}
