import Foundation

/// Turns git's raw stderr (`GitError.commandFailed`'s message) into a short human-readable
/// `summary` plus the complete `fullLog` to copy. `--progress` commands (push, clone, checkout)
/// report failures after hundreds of meter lines, so raw output can't go straight into an alert.
///
/// The raw text stays untouched inside `GitError`, because callers pattern-match on it. This is
/// applied only when an error is displayed. Text that didn't come from git (a short sentence
/// `AppState` wrote itself) passes through unchanged, with `hasFurtherDetail` false.
nonisolated struct GitErrorReport: Equatable {
    let summary: String
    let fullLog: String

    /// Whether copying the log would tell the user anything `summary` doesn't.
    var hasFurtherDetail: Bool {
        var log = Substring(fullLog)
        for prefix in ["fatal: ", "error: "] where log.hasPrefix(prefix) {
            log = log.dropFirst(prefix.count)
        }
        return summary.caseInsensitiveCompare(String(log)) != .orderedSame
    }

    init(rawOutput: String) {
        fullLog = Self.cleanedLog(rawOutput)
        summary = Self.summarize(log: fullLog)
    }

    private static let maxSummaryLines = 6
    private static let maxSummaryLineLength = 300

    // MARK: - Log cleanup

    /// Normalizes line endings (git repaints its meter with `\r`), and removes terminal escapes
    /// and any credentials embedded in a remote URL, since a copied log tends to get pasted into
    /// bug reports. Every line is kept, progress included.
    private static func cleanedLog(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        text = text
            .replacingOccurrences(of: #"(https?://)[^/\s@]+@"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(://[^/\s:@]+):[^/\s@]+@"#, with: "$1@", options: .regularExpression)
        return text
            .components(separatedBy: "\n")
            .map { line in
                var line = Substring(line)
                while line.last?.isWhitespace == true { line.removeLast() }
                return String(line)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Summary

    private static func summarize(log: String) -> String {
        let lines = log
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isProgressLine($0) }
        return recognizedFailure(log: log, lines: lines) ?? fallbackSummary(lines: lines)
    }

    /// git's meter and its bookkeeping lines, with or without the `remote:` sideband prefix.
    private static func isProgressLine(_ line: String) -> Bool {
        let body = line.hasPrefix("remote: ") ? String(line.dropFirst("remote: ".count)) : line
        let patterns = [
            #"^[A-Za-z ]+:\s+\d+%"#,
            #"^Enumerating objects: \d+"#,
            #"^Delta compression using"#,
            #"^Total \d+ \(delta"#,
            #"^Cloning into "#,
        ]
        return patterns.contains { body.range(of: $0, options: .regularExpression) != nil }
    }

    /// Order matters: a large-file rejection also reads as a remote rejection, and an SSH network
    /// failure also says "Could not read from remote repository".
    private static func recognizedFailure(log: String, lines: [String]) -> String? {
        let lowercased = log.lowercased()
        func mentions(_ needles: String...) -> Bool { needles.contains { lowercased.contains($0) } }

        if mentions("exceeds github's file size limit", "gh001", "large files detected", "http 413", "pack exceeds maximum") {
            return "The push is too large for the remote to accept. It may contain a file over the remote\u{2019}s size limit."
        }
        if let rejection = remoteRejection(log: log, lines: lines) {
            return rejection
        }
        if mentions("permission denied (publickey)", "host key verification failed") {
            return "The remote wouldn\u{2019}t accept your SSH credentials. Check that your SSH key is set up for this remote and has access to the repository."
        }
        if mentions("could not resolve host", "could not resolve hostname", "connection timed out", "operation timed out", "failed to connect", "couldn't connect to server", "network is unreachable", "connection refused", "connection reset", "the remote end hung up", "early eof", "rpc failed", "ssl_error", "ssl certificate problem") {
            return "Couldn\u{2019}t reach the remote. Check your internet connection and try again."
        }
        if mentions("authentication failed", "could not read username", "could not read password", "terminal prompts disabled", "invalid username or", "returned error: 401", "returned error: 403") {
            return "The remote wouldn\u{2019}t accept your credentials. Check that you\u{2019}re signed in to git for this remote and have access to the repository."
        }
        if mentions("repository not found", "does not appear to be a git repository", "could not read from remote repository") {
            return "Couldn\u{2019}t find the repository on the remote. It may have moved, or you may not have access to it."
        }
        if mentions("please tell me who you are", "unable to auto-detect email address") {
            return "Git doesn\u{2019}t know who you are yet. Set your name and email with git config user.name and git config user.email, then try again."
        }
        if mentions("failed to sign the data", "gpg failed to sign") {
            return "Git couldn\u{2019}t sign this commit. Check your commit signing setup, then try again."
        }
        if mentions("index.lock") {
            return "Another git process is using this repository. Wait for it to finish, then try again."
        }
        if mentions("you have not concluded your merge", "because you have unmerged files", "unresolved conflict") {
            return "This repository has an unfinished merge. Resolve the conflicts and commit them, then try again."
        }
        if mentions("need to specify how to reconcile divergent branches", "not possible to fast-forward") {
            return "Your branch and the remote have both changed, and git\u{2019}s settings here don\u{2019}t say how to combine them. Set pull.rebase in git config, then try again."
        }
        if mentions("there is no tracking information for the current branch") {
            return "This branch isn\u{2019}t linked to a branch on the remote yet, so there\u{2019}s nothing to pull. Push it first."
        }
        if mentions("nothing to commit", "no changes added to commit") {
            return "There\u{2019}s nothing to commit."
        }
        return nil
    }

    /// A `! [remote rejected] local -> remote (reason)` line: the push reached the remote, which
    /// then refused to update the ref. A hook's `remote:` lines usually state the actual rule that
    /// was broken, so they're quoted.
    private static func remoteRejection(log: String, lines: [String]) -> String? {
        guard let line = lines.first(where: { $0.contains("[remote rejected]") }) else { return nil }
        let parts = line.split(separator: " ").map(String.init)
        let destination = parts.firstIndex(of: "->").flatMap { parts.indices.contains($0 + 1) ? parts[$0 + 1] : nil }
        let target = destination.map { "\u{201C}\($0)\u{201D}" } ?? "this branch"

        var reason = ""
        if let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), open < close {
            reason = String(line[line.index(after: open)..<close])
        }

        if reason == "failure" || log.contains("commit_refs") || reason.localizedCaseInsensitiveContains("internal") {
            return "The remote hit a problem on its side and couldn\u{2019}t update \(target). Your commits are still safe on this Mac. This is usually temporary, so try pushing again in a moment."
        }

        let remoteMessages = lines
            .filter { $0.hasPrefix("remote: ") }
            .map { String($0.dropFirst("remote: ".count)).trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("error: ") ? String($0.dropFirst("error: ".count)) : $0 }
            .filter { !$0.isEmpty }
        let intro = reason.contains("hook declined") || reason.isEmpty
            ? "The remote refused the push to \(target)."
            : "The remote refused the push to \(target): \(reason)."
        return ([intro] + capped(remoteMessages)).joined(separator: "\n")
    }

    /// Unrecognized failures: git's own `fatal:`/`error:` lines if it wrote any. Otherwise the end
    /// of the output, which is where something like a failing commit hook reports its error.
    private static func fallbackSummary(lines: [String]) -> String {
        let diagnostics = lines.compactMap { line -> String? in
            for prefix in ["fatal: ", "error: "] where line.hasPrefix(prefix) {
                let message = line.dropFirst(prefix.count)
                return message.prefix(1).uppercased() + message.dropFirst()
            }
            return nil
        }
        if !diagnostics.isEmpty {
            return capped(diagnostics).joined(separator: "\n")
        }
        guard !lines.isEmpty else { return "Git didn\u{2019}t give a reason for this failure." }
        let tail = Array(lines.suffix(maxSummaryLines))
        return ((lines.count > tail.count ? ["\u{2026}"] : []) + capped(tail)).joined(separator: "\n")
    }

    private static func capped(_ lines: [String]) -> [String] {
        var result = lines.prefix(maxSummaryLines).map { line in
            line.count > maxSummaryLineLength ? line.prefix(maxSummaryLineLength) + "\u{2026}" : line
        }
        if lines.count > maxSummaryLines { result.append("\u{2026}") }
        return result
    }
}

/// A caller-sized list for an alert's message. An alert has no scrolling, so an uncapped list can
/// run off the screen and take the alert's buttons with it.
nonisolated enum AlertList {
    static func text(_ items: [String], limit: Int = 12) -> String {
        guard items.count > limit else { return items.joined(separator: "\n") }
        return (items.prefix(limit) + ["\u{2026}and \((items.count - limit).formatted()) more"]).joined(separator: "\n")
    }
}
