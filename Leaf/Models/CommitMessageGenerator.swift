import FoundationModels
import Foundation

/// The three commit-message conventions `SettingsView` lets a user pick between (see the
/// "AI Commit Messages" section) and that `CommitMessageGenerator` turns into model instructions.
/// Raw values are persisted directly to `LeafSettings.commitMessageStyleKey`.
enum CommitMessageStyle: String, CaseIterable, Identifiable {
    case scoped
    case conventional
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .scoped: "Scoped"
        case .conventional: "Conventional"
        case .custom: "Custom"
        }
    }

    /// `nil` for `.custom`, where the user's own free-text instructions are used instead.
    ///
    /// Deliberately avoids angle-bracket placeholder syntax like `<type>` — the on-device model
    /// is small enough that it was observed echoing that literal syntax back verbatim instead of
    /// substituting it (confirmed empirically). A concrete worked example steers it far more
    /// reliably than a template description does.
    var builtInInstructions: String? {
        switch self {
        case .scoped:
            return """
            Follow the Scoped Commits convention (scopedcommits.com). Write exactly one line in \
            the form "component: summary", where component is a single lowercase word for the \
            area of the codebase most affected overall, a colon, a space, then a short \
            imperative-mood summary of the change as a whole. For example: \
            "settings: add commit message style picker". Treat every file in the diff as parts \
            of ONE change and describe that one change — never list files individually, never \
            write more than one line, never explain your reasoning.
            """
        case .conventional:
            return """
            Follow the Conventional Commits specification (conventionalcommits.org). Write \
            exactly one line: pick a single type — feat, fix, refactor, perf, style, test, docs, \
            build, ci, or chore — that best matches the overall change, optionally a short scope \
            in parentheses, a colon, a space, then a short imperative-mood description. For \
            example: "feat: add on-device commit message generation". Treat every file in the \
            diff as parts of ONE change and describe that one change — never list files \
            individually, never write more than one line, never explain your reasoning.
            """
        case .custom:
            return nil
        }
    }
}

enum CommitMessageGeneratorError: LocalizedError {
    case unavailable(String)
    case noChanges
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .noChanges: "There are no uncommitted changes to summarize."
        case .generationFailed(let reason): reason
        }
    }
}

/// Generates a commit message from a diff of the uncommitted changes, using Apple's on-device
/// `SystemLanguageModel`. Called from `AppState.generateCommitMessage()`.
enum CommitMessageGenerator {
    /// Diffs of any real size vastly exceed the session's shared context budget (instructions +
    /// prompt + output all share it) — truncating keeps the request well inside that budget while
    /// still giving the model plenty of real content to summarize.
    private static let maxDiffCharacters = 12_000

    /// `nil` when generation is available; otherwise a user-facing reason it isn't, suitable for
    /// `AppState.errorMessage` or disabling the "Generate" button.
    static func availabilityMessage() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence isn't enabled. Turn it on in System Settings to generate commit messages."
        case .unavailable(.modelNotReady):
            return "The on-device language model isn't ready yet. Try again in a moment."
        case .unavailable(.deviceNotEligible):
            return "This Mac can't run Apple Intelligence, so commit messages can't be generated on it."
        case .unavailable:
            return "On-device commit message generation isn't available right now."
        }
    }

    static func generate(diff: String, style: CommitMessageStyle, customInstructions: String) async throws -> String {
        if let reason = availabilityMessage() {
            throw CommitMessageGeneratorError.unavailable(reason)
        }

        let trimmedDiff = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDiff.isEmpty else {
            throw CommitMessageGeneratorError.noChanges
        }

        let instructions: String
        if let builtIn = style.builtInInstructions {
            instructions = builtIn
        } else {
            let custom = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            instructions = custom.isEmpty
                ? "Write a concise, imperative-mood git commit message summarizing the change."
                : custom
        }

        let session = LanguageModelSession {
            """
            You write a git commit message summarizing a diff of uncommitted changes across one \
            or more files, treating all of it as a single change. \(instructions)

            Base the message only on what the diff actually shows — never invent file names, \
            reasoning, or context the diff doesn't contain. Output the commit message text and \
            nothing else: no "commit:" prefix or label of any kind, no quotation marks, no \
            markdown or code fences, no bullet points or numbered list, no per-file breakdown, no \
            explanation before or after it.
            """
        }

        let truncatedDiff = String(trimmedDiff.prefix(maxDiffCharacters))

        do {
            let response = try await session.respond(to: "Diff:\n\(truncatedDiff)")
            let message = cleanUp(response.content)
            guard !message.isEmpty else {
                throw CommitMessageGeneratorError.generationFailed("The model returned an empty response.")
            }
            return message
        } catch let error as CommitMessageGeneratorError {
            throw error
        } catch {
            throw CommitMessageGeneratorError.generationFailed(error.localizedDescription)
        }
    }

    /// Defensive cleanup for the small on-device model's occasional misbehavior (observed
    /// empirically): echoing a literal `commit:` label, wrapping the message in quotes/code
    /// fences, or — worst case — emitting one `commit: …` line per file instead of a single
    /// summary of the whole diff. Strips those artifacts rather than relying on prompting alone.
    private static func cleanUp(_ raw: String) -> String {
        var lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "```" }

        if lines.filter({ $0.lowercased().hasPrefix("commit:") }).count > 1 {
            lines = Array(lines.prefix(1))
        }

        var message = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if message.lowercased().hasPrefix("commit:") {
            message = String(message.dropFirst("commit:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if message.hasPrefix("\"") && message.hasSuffix("\"") && message.count > 1 {
            message = String(message.dropFirst().dropLast())
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
