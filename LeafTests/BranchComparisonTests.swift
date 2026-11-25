import Foundation
import Testing
@testable import Leaf

@Suite struct BranchComparisonTests {
    /// Past the recent-use window, so fresh test repos report their underlying merge verdict.
    private let later = Date().addingTimeInterval(GitRepository.BranchComparison.recentUseInterval + 3600)

    @Test func recentUseReplacesSafeVerdictsOnly() throws {
        let t = try makeRepo()
        #expect(try compare(t).verdict() == .unmerged(localOnlyCount: 2))
        try t.run(["merge", "--squash", "feature"])
        try t.commitAll("squashed")
        #expect(try compare(t).verdict() == .recentlyUsed)
        try t.run(["merge", "--no-ff", "--no-edit", "feature"])
        #expect(try compare(t).verdict() == .recentlyUsed)
        #expect(try compare(t).verdict(asOf: later) == .merged)
    }

    @Test func newBranchOnOldCommitIsRecentlyUsed() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        try t.run(["add", "-A"])
        try t.run(["commit", "-m", "old", "--date=2020-01-01T00:00:00Z"])
        try t.run(["branch", "feature"])
        #expect(try compare(t).verdict() == .recentlyUsed)
    }

    @Test func checkoutAloneCountsAsUse() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        try t.run(["add", "-A"])
        try t.run(["commit", "-m", "old", "--date=2020-01-01T00:00:00Z"])
        try t.run(["branch", "feature"])
        // Drop the creation entry, leaving only the 2020 commit as evidence of use.
        try FileManager.default.removeItem(at: t.url.appendingPathComponent(".git/logs/refs/heads/feature"))
        #expect(try compare(t).verdict() == .merged)
        try t.run(["checkout", "feature"])
        try t.run(["checkout", "main"])
        #expect(try compare(t).verdict() == .recentlyUsed)
    }

    @Test func worktreeCheckoutIsNeverSafe() throws {
        let t = try makeRepo()
        try t.run(["merge", "--no-ff", "--no-edit", "feature"])
        try t.run(["worktree", "add", t.url.appendingPathComponent("wt").path, "feature"])
        #expect(try compare(t).verdict(asOf: later) == .recentlyUsed)
    }

    /// `main` with one commit and a `feature` branch with two, left on `main`.
    private func makeRepo() throws -> TestRepo {
        let t = TestRepo()
        try t.write("a.txt", "base\n")
        try t.commitAll("initial")
        try t.run(["checkout", "-b", "feature"])
        try t.write("f.txt", "one\n")
        try t.commitAll("feature one")
        try t.write("g.txt", "two\n")
        try t.commitAll("feature two")
        try t.run(["checkout", "main"])
        return t
    }

    private func addOrigin(to t: TestRepo, pushing branches: [String]) throws -> TestRepo {
        let origin = TestRepo(bare: true)
        try t.run(["remote", "add", "origin", origin.url.path])
        for branch in branches { try t.run(["push", "-u", "origin", branch]) }
        return origin
    }

    private func compare(_ t: TestRepo) throws -> GitRepository.BranchComparison {
        try t.repo.compareBranch("feature", base: "main", isDefaultBranch: false)
    }

    @Test func localOnlyCommitsAreUnmergedAndNothingChanges() throws {
        let t = try makeRepo()
        let before = try t.run(["for-each-ref"]) + t.run(["status", "--porcelain"])
        let result = try compare(t)
        #expect(result.verdict(asOf: later) == .unmerged(localOnlyCount: 2))
        #expect(result.uniqueCommits.map(\.summary) == ["feature two", "feature one"])
        #expect(result.lastCommit?.summary == "feature two")
        #expect(result.upstream == .none)
        #expect(result.lastFetchDate == nil)
        #expect(try t.run(["for-each-ref"]) + t.run(["status", "--porcelain"]) == before)
    }

    @Test func regularMerge() throws {
        let t = try makeRepo()
        try t.run(["merge", "--no-ff", "--no-edit", "feature"])
        let result = try compare(t)
        #expect(result.verdict(asOf: later) == .merged)
        #expect(result.behindCount == 1)
        #expect(result.uniqueCommits.isEmpty)
    }

    @Test func squashMergeIsDetectedAfterUnrelatedWork() throws {
        let t = try makeRepo()
        try t.run(["merge", "--squash", "feature"])
        try t.commitAll("squashed")
        #expect(try compare(t).verdict(asOf: later) == .contentIncluded)
        try t.write("other.txt", "x")
        try t.commitAll("unrelated")
        #expect(try compare(t).verdict(asOf: later) == .contentIncluded)
    }

    @Test func squashThenRevertIsNotSafe() throws {
        let t = try makeRepo()
        try t.run(["merge", "--squash", "feature"])
        try t.commitAll("squashed")
        try t.run(["revert", "--no-edit", "HEAD"])
        #expect(try compare(t).verdict(asOf: later) == .unmerged(localOnlyCount: 2))
    }

    @Test func cherryPickedCommitsThenRewrittenOnMain() throws {
        let t = try makeRepo()
        // Different parent, so the picked commits get new SHAs.
        try t.write("other.txt", "x")
        try t.commitAll("unrelated")
        try t.run(["cherry-pick", "feature~1", "feature"])
        // Makes the dry-run merge conflict, so only the per-commit check can prove it.
        try t.write("f.txt", "rewritten\n")
        try t.commitAll("rewrite")
        #expect(try compare(t).verdict(asOf: later) == .contentIncluded)
    }

    @Test func partlyCherryPickedIsNotSafe() throws {
        let t = try makeRepo()
        try t.write("other.txt", "x")
        try t.commitAll("unrelated")
        try t.run(["cherry-pick", "feature~1"])
        #expect(try compare(t).verdict(asOf: later) == .unmerged(localOnlyCount: 2))
    }

    @Test func mergeCommitOnBranchDisablesPerCommitCheck() throws {
        let t = try makeRepo()
        try t.write("other.txt", "x")
        try t.commitAll("unrelated")
        try t.run(["checkout", "feature"])
        // An edit made inside the merge commit, which `git cherry` can't see.
        try t.run(["merge", "--no-commit", "--no-ff", "main"])
        try t.write("evil.txt", "only in the merge")
        try t.commitAll("merge main")
        try t.run(["checkout", "main"])
        try t.run(["cherry-pick", "feature~2", "feature~1"])
        #expect(try compare(t).verdict(asOf: later) == .unmerged(localOnlyCount: 3))
    }

    @Test func conflictingBranchIsNotSafe() throws {
        let t = try makeRepo()
        try t.write("f.txt", "different\n")
        try t.commitAll("conflict")
        #expect(try compare(t).verdict(asOf: later) == .unmerged(localOnlyCount: 2))
    }

    @Test func unrelatedHistoriesAreNotSafe() throws {
        let t = try makeRepo()
        try t.run(["branch", "-D", "feature"])
        try t.run(["checkout", "--orphan", "feature"])
        try t.write("z.txt", "z")
        try t.commitAll("orphan")
        try t.run(["checkout", "main"])
        #expect(try compare(t).verdict(asOf: later) == .unmerged(localOnlyCount: 1))
    }

    @Test func pushedButUnmerged() throws {
        let t = try makeRepo()
        let origin = try addOrigin(to: t, pushing: ["main", "feature"])
        try withExtendedLifetime(origin) {
            let result = try compare(t)
            #expect(result.verdict(asOf: later) == .backedUpOnRemote)
            #expect(result.upstream == .inSync("origin/feature"))

            try t.run(["checkout", "feature"])
            try t.write("h.txt", "three")
            try t.commitAll("unpushed")
            try t.run(["checkout", "main"])
            let ahead = try compare(t)
            #expect(ahead.verdict(asOf: later) == .unmerged(localOnlyCount: 1))
            #expect(ahead.upstream == .outOfSync("origin/feature", track: "ahead 1"))
        }
    }

    @Test func goneUpstreamIsNotABackup() throws {
        let t = try makeRepo()
        let origin = try addOrigin(to: t, pushing: ["main", "feature"])
        try origin.run(["branch", "-D", "feature"])
        try t.repo.fetch()
        let result = try compare(t)
        #expect(result.upstream == .gone("origin/feature"))
        #expect(result.verdict(asOf: later) == .unmerged(localOnlyCount: 2))
        #expect(result.lastFetchDate != nil)
    }

    @Test func mergedOnServerWhileLocalMainIsStale() throws {
        let t = try makeRepo()
        let origin = try addOrigin(to: t, pushing: ["main"])
        try withExtendedLifetime(origin) {
            try t.run(["push", "origin", "feature:main"])
            let result = try compare(t)
            #expect(result.verdict(asOf: later) == .merged)
        }
    }

    @Test func unpushedLocalMergeCounts() throws {
        let t = try makeRepo()
        let origin = try addOrigin(to: t, pushing: ["main"])
        try withExtendedLifetime(origin) {
            try t.run(["merge", "--no-ff", "--no-edit", "feature"])
            let result = try compare(t)
            #expect(result.verdict(asOf: later) == .merged)
        }
    }

    @Test func sameNamedTagIsIgnored() throws {
        let t = try makeRepo()
        try t.run(["tag", "feature", "main"])
        try t.run(["tag", "main", "refs/heads/feature"])
        #expect(try compare(t).verdict(asOf: later) == .unmerged(localOnlyCount: 2))
    }

    @Test func worktreePathIsReported() throws {
        let t = try makeRepo()
        #expect(try compare(t).worktreePath == nil)
        try t.run(["worktree", "add", t.url.appendingPathComponent("wt").path, "feature"])
        #expect(try compare(t).worktreePath?.hasSuffix("/wt") == true)
    }

    @Test func missingBaseThrows() throws {
        let t = try makeRepo()
        #expect(throws: GitError.self) {
            try t.repo.compareBranch("feature", base: "nope", isDefaultBranch: false)
        }
    }

    @Test func comparisonBaseSelection() {
        func base(_ branch: String, _ defaultBranch: String?, _ locals: [String], _ current: String?) -> String? {
            GitRepository.comparisonBase(
                for: branch, defaultBranch: defaultBranch, localBranches: locals, current: current
            ).map { "\($0.name) \($0.isDefaultBranch)" }
        }
        #expect(base("f", "develop", ["f", "main"], "x") == "develop false")
        #expect(base("f", nil, ["f", "master"], "x") == "master false")
        #expect(base("f", nil, ["f", "x"], "x") == "x false")
        #expect(base("main", "main", ["main", "x"], "x") == "x true")
        #expect(base("main", "main", ["main"], nil) == nil)
    }
}
