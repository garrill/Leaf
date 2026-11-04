import Testing
import Foundation
@testable import Leaf

/// `GitErrorReport` turns raw git stderr into something that fits in an alert, so these feed it the
/// exact shapes git produces, progress meter included.
@Suite struct GitErrorReportTests {
    /// A push's meter, repainted with `\r` the way git really emits it.
    private static let progressNoise = (1...79).map { "Counting objects: \(Int(Double($0) / 79 * 100))% (\($0)/79)" }.joined(separator: "\r")
        + "\rCounting objects: 100% (79/79), done.\nDelta compression using up to 10 threads\n"
        + (1...49).map { "Writing objects: \(Int(Double($0) / 49 * 100))% (\($0)/49)" }.joined(separator: "\r")
        + "\rWriting objects: 100% (49/49), 9.28 KiB | 9.28 MiB/s, done.\nTotal 49 (delta 30), reused 26 (delta 9), pack-reused 0 (from 0)\n"
        + "remote: Resolving deltas:   0% (0/30)        \rremote: Resolving deltas: 100% (30/30), completed with 22 local objects.        \n"

    @Test func commitRefsFailureIsSummarizedAndLogKeepsEverything() {
        let raw = Self.progressNoise + """
        remote: fatal error in commit_refs        
        To github.com:acme/site.git
         ! [remote rejected]     staging -> staging (failure)
        error: failed to push some refs to 'github.com:acme/site.git'
        """
        let report = GitErrorReport(rawOutput: raw)

        #expect(report.summary.contains("\u{201C}staging\u{201D}"))
        #expect(report.summary.contains("try pushing again"))
        #expect(!report.summary.contains("%"))
        #expect(report.hasFurtherDetail)
        #expect(report.fullLog.contains("Counting objects: 1% (1/79)"))
        #expect(report.fullLog.contains("fatal error in commit_refs"))
        #expect(!report.fullLog.contains("\r"))
    }

    @Test func hookRejectionQuotesTheRemotesExplanation() {
        let raw = Self.progressNoise + """
        remote: error: GH006: Protected branch update failed for refs/heads/main.
        remote: error: Changes must be made through a pull request.
        To github.com:acme/site.git
         ! [remote rejected] main -> main (protected branch hook declined)
        error: failed to push some refs to 'github.com:acme/site.git'
        """
        let summary = GitErrorReport(rawOutput: raw).summary

        #expect(summary.contains("refused the push to \u{201C}main\u{201D}"))
        #expect(summary.contains("Changes must be made through a pull request."))
        #expect(!summary.contains("Resolving deltas"))
        #expect(!summary.contains("error:"))
    }

    @Test(arguments: [
        ("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.", "SSH"),
        ("ssh: connect to host github.com port 22: Operation timed out\nfatal: Could not read from remote repository.", "internet connection"),
        ("fatal: unable to access 'https://github.com/a/b.git/': Could not resolve host: github.com", "internet connection"),
        ("remote: Repository not found.\nfatal: repository 'https://github.com/a/b.git/' not found", "find the repository"),
        ("fatal: Unable to create '/x/.git/index.lock': File exists.", "Another git process"),
    ])
    func recognizedFailures(raw: String, expected: String) {
        #expect(GitErrorReport(rawOutput: raw).summary.contains(expected))
    }

    @Test func unrecognizedFailureUsesGitsOwnDiagnosticWithoutItsPrefix() {
        let report = GitErrorReport(rawOutput: "hint: something\nfatal: a branch named 'x' already exists")
        #expect(report.summary == "A branch named 'x' already exists")
        #expect(report.hasFurtherDetail)
    }

    @Test func singleDiagnosticHasNothingFurtherToCopy() {
        let report = GitErrorReport(rawOutput: "fatal: a branch named 'x' already exists")
        #expect(report.summary == "A branch named 'x' already exists")
        #expect(!report.hasFurtherDetail)
    }

    @Test func plainSentencePassesThroughWithNothingFurtherToCopy() {
        let sentence = "Branch \u{201C}x\u{201D} no longer exists. It may have been deleted."
        let report = GitErrorReport(rawOutput: sentence)
        #expect(report.summary == sentence)
        #expect(!report.hasFurtherDetail)
    }

    @Test func longUnrecognizedOutputIsCappedToItsEnd() {
        let raw = (1...500).map { "hook output \($0)" }.joined(separator: "\n")
        let report = GitErrorReport(rawOutput: raw)
        #expect(report.summary.components(separatedBy: "\n").count <= 7)
        #expect(report.summary.contains("hook output 500"))
        #expect(report.fullLog.contains("hook output 1\n"))
    }

    @Test func credentialsInRemoteURLsAreRemoved() {
        let report = GitErrorReport(rawOutput: "fatal: unable to access 'https://bob:s3cret@example.com/a.git/': boom\nfatal: bad ssh://bob:s3cret@example.com/a.git")
        #expect(!report.fullLog.contains("s3cret"))
        #expect(!report.summary.contains("s3cret"))
        #expect(report.fullLog.contains("https://example.com/a.git/"))
        #expect(report.fullLog.contains("ssh://bob@example.com/a.git"))
    }

    @Test func emptyOutputStillSaysSomething() {
        #expect(!GitErrorReport(rawOutput: "  \n").summary.isEmpty)
    }

    @Test func alertListCapsLongLists() {
        #expect(AlertList.text(["a", "b"]) == "a\nb")
        let lines = AlertList.text((1...100).map(String.init), limit: 3).components(separatedBy: "\n")
        #expect(lines == ["1", "2", "3", "\u{2026}and 97 more"])
    }
}

@MainActor @Suite struct ParseGitFailureTests {
    private static let pullHeader = "From github.com:acme/site\n   ce0c1c0..d6f0788  main       -> origin/main\n"

    @Test func trackedOverwriteOffersOnlyTheRealPaths() {
        let raw = Self.pullHeader + "error: Your local changes to the following files would be overwritten by merge:\n\tf.txt\n\tdir/g.txt\nPlease commit your changes or stash them before you merge.\nAborting\nUpdating ce0c1c0..d6f0788\n"
        let alert = AppState.parseGitFailure(raw, operation: .pull)
        #expect(alert.blockingTrackedPaths == ["f.txt", "dir/g.txt"])
        #expect(alert.overwriteVerb == "merge")
        #expect(alert.log.contains("Updating ce0c1c0"))
    }

    @Test func untrackedOverwriteOffersNoStash() {
        let raw = "error: The following untracked working tree files would be overwritten by merge:\n\tnew.txt\nPlease move or remove them before you merge.\nAborting\n"
        let alert = AppState.parseGitFailure(raw, operation: .pull)
        #expect(alert.blockingTrackedPaths.isEmpty)
        #expect(alert.message.contains("new.txt"))
    }

    @Test func nonFastForwardPushStillOffersPull() {
        let raw = "To github.com:acme/site.git\n ! [rejected]        main -> main (fetch first)\nerror: failed to push some refs to 'github.com:acme/site.git'\nhint: Updates were rejected because the remote contains work that you do not have locally.\n"
        let alert = AppState.parseGitFailure(raw, operation: .push)
        #expect(alert.offerPullThenPush)
        #expect(alert.pushRemoteURL == "github.com:acme/site.git")
    }

    @Test func remoteRejectionDoesNotOfferPull() {
        let raw = "remote: fatal error in commit_refs\nTo github.com:acme/site.git\n ! [remote rejected] staging -> staging (failure)\nerror: failed to push some refs to 'github.com:acme/site.git'\n"
        let alert = AppState.parseGitFailure(raw, operation: .push)
        #expect(!alert.offerPullThenPush)
        #expect(alert.message.count < 250)
    }
}
