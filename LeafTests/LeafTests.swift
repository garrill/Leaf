//
//  LeafTests.swift
//  LeafTests
//
//  Created by Jonny Garrill on 20/07/2026.
//

import Testing
import Foundation
@testable import Leaf

/// Spins up a real throwaway repo (or bare repo) in a temp directory per test, and cleans it
/// up on teardown. `GitRepository` shells out to real `/usr/bin/git`, so tests exercise the
/// actual binary against real on-disk state rather than mocks.
final class TestRepo {
    let url: URL
    let repo: GitRepository

    init(bare: Bool = false) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        repo = GitRepository(rootURL: url)
        var initArgs = ["init", "-b", "main"]
        if bare { initArgs.append("--bare") }
        try! Self.run(["-C", url.path] + initArgs)
        if !bare {
            try! Self.run(["-C", url.path, "config", "user.email", "test@example.com"])
            try! Self.run(["-C", url.path, "config", "user.name", "Test"])
            try! Self.run(["-C", url.path, "config", "commit.gpgsign", "false"])
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Drain stdout on a dedicated background thread concurrently with reading stderr on the
        // calling thread below — reading either pipe fully before touching the other can deadlock:
        // if the unread pipe's OS buffer (~64KB) fills up, git blocks trying to write to it, the
        // process never exits/closes its pipes, and `readDataToEndOfFile()` on the pipe being read
        // never sees EOF.
        //
        // This uses a raw `Thread`, not `DispatchQueue.global`, on purpose. Swift Testing runs
        // suites in parallel on the Swift concurrency cooperative pool, whose worker threads share
        // the same capped workqueue that backs `DispatchQueue.global`. When every cooperative
        // thread is parked here in a blocking wait (one per in-flight test), the workqueue is at
        // its ceiling and never schedules the drain block, so `leave()` is never called and the
        // whole test run wedges on the first `git init`. A dedicated `Thread` is always scheduled.
        var outData = Data()
        let stdoutDrainDone = DispatchSemaphore(value: 0)
        let drainThread = Thread {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            stdoutDrainDone.signal()
        }
        // Match the caller's QoS — a raw `Thread` defaults to `.default`, and the calling test
        // worker runs at `.userInitiated`, so a mismatch trips the Thread Performance Checker's
        // priority-inversion warning while the caller blocks on the semaphore below.
        drainThread.qualityOfService = .userInitiated
        drainThread.stackSize = 1 << 20
        drainThread.start()

        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stdoutDrainDone.wait()

        guard process.terminationStatus == 0 else {
            throw GitError.commandFailed(String(data: errData, encoding: .utf8) ?? "")
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        try Self.run(["-C", url.path] + arguments)
    }

    func write(_ path: String, _ contents: String) throws {
        let fileURL = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func writeBinary(_ path: String, _ bytes: [UInt8]) throws {
        let fileURL = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: fileURL)
    }

    @discardableResult
    func commitAll(_ message: String) throws -> String {
        try run(["add", "-A"])
        try run(["commit", "-m", message])
        return try run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Clean repo / empty state

@Suite struct EmptyRepoTests {
    @Test func noCommitsYet() throws {
        let t = TestRepo()
        #expect(try t.repo.branches().isEmpty)
        #expect(try t.repo.statusEntries().isEmpty)
    }

    @Test func untrackedFileBeforeFirstCommit() throws {
        let t = TestRepo()
        try t.write("a.txt", "hello")
        let entries = try t.repo.statusEntries()
        #expect(entries.count == 1)
        #expect(entries[0].status == .untracked)
    }

    @Test func bareRepoOpenedByMistakeFailsGracefully() throws {
        let t = TestRepo(bare: true)
        #expect(throws: (any Error).self) {
            try t.repo.statusEntries().forEach { file in try t.repo.diff(for: file) }
        }
        // branches() on a bare empty repo just returns empty, doesn't crash.
        #expect(try t.repo.branches().isEmpty)
    }
}

// MARK: - Dirty tree status combinations

@Suite struct StatusTests {
    @Test func stagedUnstagedUntrackedIgnoredAllTogether() throws {
        let t = TestRepo()
        try t.write("staged.txt", "1")
        try t.write("unstaged.txt", "1")
        try t.write(".gitignore", "ignored.txt\n")
        _ = try t.commitAll("initial")

        try t.write("staged.txt", "2")
        try t.run(["add", "staged.txt"])
        try t.write("unstaged.txt", "2")
        try t.write("untracked.txt", "1")
        try t.write("ignored.txt", "1")

        let entries = try t.repo.statusEntries()
        let paths = Set(entries.map(\.path))
        #expect(paths.contains("staged.txt"))
        #expect(paths.contains("unstaged.txt"))
        #expect(paths.contains("untracked.txt"))
        #expect(!paths.contains("ignored.txt"), "ignored files must not show up in status")
    }

    @Test func deletedFile() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        _ = try t.commitAll("initial")
        try FileManager.default.removeItem(at: t.url.appendingPathComponent("a.txt"))
        let entries = try t.repo.statusEntries()
        #expect(entries.first?.status == .deleted)
    }

    @Test func renamedFile() throws {
        let t = TestRepo()
        try t.write("old.txt", "some content that is long enough to be detected as a rename\n")
        _ = try t.commitAll("initial")
        try FileManager.default.removeItem(at: t.url.appendingPathComponent("old.txt"))
        try t.write("new.txt", "some content that is long enough to be detected as a rename\n")
        try t.run(["add", "-A"])
        let entries = try t.repo.statusEntries()
        let renamed = entries.first { $0.status == .renamed }
        #expect(renamed?.path == "new.txt")
        #expect(renamed?.oldPath == "old.txt")
    }
}

// MARK: - Commit with pathspec-limited staging

@Suite struct CommitTests {
    @Test func partialStagePartialUnstageInOneCommit() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        try t.write("b.txt", "1")
        _ = try t.commitAll("initial")

        try t.write("a.txt", "2")
        try t.write("b.txt", "2")
        // b.txt gets staged externally first (simulating something already staged outside the app).
        try t.run(["add", "b.txt"])

        try t.repo.commit(message: "commit a only", paths: ["a.txt"], unstagePaths: ["b.txt"])

        let log = try t.run(["log", "-1", "--name-only", "--format="])
        #expect(log.contains("a.txt"))
        #expect(!log.contains("b.txt"))
        // b.txt should now be unstaged-but-modified, not committed.
        let entries = try t.repo.statusEntries()
        #expect(entries.contains { $0.path == "b.txt" && $0.status == .modified })
    }

    @Test func commitUntrackedFileViaPathspec() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        _ = try t.commitAll("initial")
        try t.write("new.txt", "brand new")
        try t.repo.commit(message: "add new", paths: ["new.txt"], unstagePaths: [])
        let entries = try t.repo.statusEntries()
        #expect(entries.isEmpty)
    }
}

// MARK: - Stash

private extension GitRepository.StashApplyOutcome {
    var isSuccess: Bool { if case .success = self { true } else { false } }
    var isConflicts: Bool { if case .conflicts = self { true } else { false } }
}

@Suite struct StashTests {
    @Test func pushListApplySingleSlot() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        _ = try t.commitAll("initial")
        try t.write("a.txt", "2")

        #expect(t.repo.stashCount() == 0)
        try t.repo.stashChanges(paths: [], includeUntracked: true)
        #expect(t.repo.stashCount() == 1)
        #expect(try t.repo.statusEntries().isEmpty)

        let result = try t.repo.restoreStash()
        #expect(result.isSuccess)
        #expect(t.repo.stashCount() == 0)
        let contents = try String(contentsOf: t.url.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(contents == "2")
    }

    @Test func discardStashDrop() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        _ = try t.commitAll("initial")
        try t.write("a.txt", "2")
        try t.repo.stashChanges(paths: [], includeUntracked: true)
        try t.repo.dropStash()
        #expect(t.repo.stashCount() == 0)
    }

    @Test func multipleStashEntriesDoNotCorruptState() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        _ = try t.commitAll("initial")

        try t.write("a.txt", "2")
        try t.repo.stashChanges(paths: [], includeUntracked: true)
        try t.write("a.txt", "3")
        try t.repo.stashChanges(paths: [], includeUntracked: true)

        #expect(t.repo.stashCount() == 2)
        // The UI only ever looks at stash@{0} — confirm that's the most recent one and that
        // popping it doesn't touch the older entry.
        let files = try t.repo.filesChanged(inStash: "stash@{0}")
        #expect(files.contains { $0.path == "a.txt" })
        let result = try t.repo.restoreStash()
        #expect(result.isSuccess)
        #expect(t.repo.stashCount() == 1)
    }

    @Test func stashWithUntrackedFile() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        _ = try t.commitAll("initial")
        try t.write("untracked.txt", "brand new")
        try t.repo.stashChanges(paths: [], includeUntracked: true)
        let files = try t.repo.filesChanged(inStash: "stash@{0}")
        #expect(files.contains { $0.path == "untracked.txt" && $0.status == .untracked })
        let (old, new) = t.repo.imageContents(for: files.first { $0.path == "untracked.txt" }!, in: .stash)
        _ = old
        _ = new // exercised for crash-safety; untracked stash blobs live under ^3
    }

    @Test func restoreConflictingStash() throws {
        let t = TestRepo()
        try t.write("a.txt", "1\n")
        _ = try t.commitAll("initial")
        try t.write("a.txt", "2\n")
        try t.repo.stashChanges(paths: [], includeUntracked: true)
        // Commit a conflicting change to the same line on top of the base so popping the
        // stash has to merge, not just overwrite a dirty working copy (which git refuses
        // outright rather than producing conflict markers).
        try t.write("a.txt", "3\n")
        _ = try t.commitAll("diverging commit")
        let result = try t.repo.restoreStash()
        #expect(result.isConflicts)
    }
}

// MARK: - Merge

@Suite struct MergeTests {
    private func makeDivergedRepo() throws -> (TestRepo, base: String) {
        let t = TestRepo()
        try t.write("a.txt", "1")
        let base = try t.commitAll("initial")
        try t.run(["checkout", "-b", "feature"])
        try t.write("b.txt", "1")
        _ = try t.commitAll("feature commit")
        try t.run(["checkout", "main"])
        return (t, base)
    }

    @Test func fastForwardMerge() throws {
        let (t, _) = try makeDivergedRepo()
        // main hasn't moved since the branch point, so merging feature is a fast-forward.
        let result = try t.repo.merge(branch: "feature")
        #expect(result == .fastForward)
    }

    @Test func cleanMergeCommit() throws {
        let (t, _) = try makeDivergedRepo()
        try t.write("c.txt", "1")
        _ = try t.commitAll("main commit")
        let result = try t.repo.merge(branch: "feature")
        #expect(result == .merged)
    }

    @Test func upToDateMerge() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        _ = try t.commitAll("initial")
        try t.run(["checkout", "-b", "feature"])
        try t.run(["checkout", "main"])
        let result = try t.repo.merge(branch: "feature")
        #expect(result == .upToDate)
    }

    @Test func conflictingMergeThenAbort() throws {
        let t = TestRepo()
        try t.write("a.txt", "base\n")
        _ = try t.commitAll("initial")
        try t.run(["checkout", "-b", "feature"])
        try t.write("a.txt", "feature change\n")
        _ = try t.commitAll("feature commit")
        try t.run(["checkout", "main"])
        try t.write("a.txt", "main change\n")
        _ = try t.commitAll("main commit")

        let result = try t.repo.merge(branch: "feature")
        #expect(result == .conflicts)
        #expect(t.repo.isMergeInProgress())
        #expect(t.repo.mergeMessage() != nil)

        try t.repo.mergeAbort()
        #expect(!t.repo.isMergeInProgress())
    }

    @Test func conflictingMergeThenCompleteWithMarkResolved() throws {
        let t = TestRepo()
        try t.write("a.txt", "base\n")
        _ = try t.commitAll("initial")
        try t.run(["checkout", "-b", "feature"])
        try t.write("a.txt", "feature change\n")
        _ = try t.commitAll("feature commit")
        try t.run(["checkout", "main"])
        try t.write("a.txt", "main change\n")
        _ = try t.commitAll("main commit")

        let result = try t.repo.merge(branch: "feature")
        #expect(result == .conflicts)

        let entries = try t.repo.statusEntries()
        let conflicted = entries.first { $0.status == .conflicted }
        #expect(conflicted != nil)

        // Hand-resolve by writing over the conflict markers, then mark resolved.
        try t.write("a.txt", "resolved\n")
        try t.repo.markResolved(conflicted!)
        let afterResolve = try t.repo.statusEntries()
        #expect(!afterResolve.contains { $0.status == .conflicted })

        // --cleanup=strip must drop the "# Conflicts:" comment lines from MERGE_MSG.
        let message = "Merge feature\n\n# Conflicts:\n#\ta.txt\n"
        try t.repo.completeMerge(message: message, resolvedPaths: [])
        let committedMessage = try t.run(["log", "-1", "--format=%B"])
        #expect(!committedMessage.contains("# Conflicts:"))
        #expect(committedMessage.contains("Merge feature"))
    }
}

// MARK: - Conflict status codes

@Suite struct ConflictStatusCodeTests {
    /// AA/DD have no 'U' char at all, and can't be derived from either single status char alone —
    /// this is the specific gap CLAUDE.md calls out.
    @Test func bothAddedProducesConflictedStatus() throws {
        let t = TestRepo()
        try t.write("base.txt", "1")
        _ = try t.commitAll("initial") // needs at least a first commit for branching below
        try t.run(["checkout", "-b", "feature"])
        try t.write("new.txt", "feature version\n")
        _ = try t.commitAll("feature adds new.txt")
        try t.run(["checkout", "main"])
        try t.write("new.txt", "main version\n")
        _ = try t.commitAll("main adds new.txt")

        let result = try t.repo.merge(branch: "feature")
        #expect(result == .conflicts)
        let entries = try t.repo.statusEntries()
        #expect(entries.first { $0.path == "new.txt" }?.status == .conflicted)
    }
}

// MARK: - Branches

@Suite struct BranchTests {
    @Test func createSwitchDelete() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        _ = try t.commitAll("initial")
        try t.repo.createBranch(named: "feature")
        var branches = try t.repo.branches()
        #expect(branches.first { $0.name == "feature" }?.isCurrent == true)

        try t.repo.checkout(branch: "main")
        branches = try t.repo.branches()
        #expect(branches.first { $0.name == "main" }?.isCurrent == true)
        #expect(branches.first { $0.name == "feature" }?.isCurrent == false)

        try t.run(["branch", "-d", "feature"])
        branches = try t.repo.branches()
        #expect(!branches.contains { $0.name == "feature" })
    }

    @Test func switchWithDirtyTreeFailsCleanly() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        _ = try t.commitAll("initial")
        try t.run(["checkout", "-b", "feature"])
        try t.write("a.txt", "feature\n")
        _ = try t.commitAll("feature commit")
        try t.run(["checkout", "main"])

        try t.write("a.txt", "dirty uncommitted change\n")
        #expect(throws: (any Error).self) {
            try t.repo.checkout(branch: "feature")
        }
        // The dirty change should survive the failed checkout untouched.
        let contents = try String(contentsOf: t.url.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(contents == "dirty uncommitted change\n")
    }

    @Test func detachedHEAD() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        _ = try t.commitAll("first")
        try t.write("a.txt", "2")
        let secondSHA = try t.commitAll("second")
        try t.run(["checkout", secondSHA])
        // Detached HEAD shows no current branch in `for-each-ref refs/heads/`.
        let branches = try t.repo.branches()
        #expect(!branches.contains { $0.isCurrent })
        #expect(t.repo.currentHEADShortSHA() != nil)
    }
}

// MARK: - Remote-backed: diverged, fetch/pull/push against a local bare remote

@Suite struct RemoteTests {
    private func makeRemoteSetup() throws -> (origin: TestRepo, clone: TestRepo) {
        let origin = TestRepo(bare: true)
        let clone = TestRepo()
        try clone.run(["remote", "add", "origin", origin.url.path])
        try clone.write("a.txt", "1")
        _ = try clone.commitAll("initial")
        try clone.run(["push", "-u", "origin", "HEAD:main"])
        try clone.run(["checkout", "main"]) // ensure local branch is literally named main, tracking origin/main
        try clone.run(["branch", "--set-upstream-to=origin/main", "main"])
        return (origin, clone)
    }

    @Test func aheadOnly() throws {
        let (_, clone) = try makeRemoteSetup()
        try clone.write("b.txt", "1")
        _ = try clone.commitAll("local only")
        let counts = clone.repo.aheadBehind()
        #expect(counts?.ahead == 1)
        #expect(counts?.behind == 0)
    }

    @Test func behindOnly() throws {
        let (origin, clone) = try makeRemoteSetup()
        // A second clone pushes a commit the first clone doesn't have yet.
        let secondClone = TestRepo()
        try secondClone.run(["remote", "add", "origin", origin.url.path])
        try secondClone.run(["fetch", "origin"])
        try secondClone.run(["checkout", "main"])
        try secondClone.write("c.txt", "1")
        _ = try secondClone.commitAll("remote only")
        try secondClone.run(["push", "origin", "main"])

        try clone.repo.fetch()
        let counts = clone.repo.aheadBehind()
        #expect(counts?.ahead == 0)
        #expect(counts?.behind == 1)
    }

    @Test func aheadAndBehindBoth() throws {
        let (origin, clone) = try makeRemoteSetup()
        let secondClone = TestRepo()
        try secondClone.run(["remote", "add", "origin", origin.url.path])
        try secondClone.run(["fetch", "origin"])
        try secondClone.run(["checkout", "main"])
        try secondClone.write("c.txt", "1")
        _ = try secondClone.commitAll("remote only")
        try secondClone.run(["push", "origin", "main"])

        try clone.write("b.txt", "1")
        _ = try clone.commitAll("local only")
        try clone.repo.fetch()

        let counts = clone.repo.aheadBehind()
        #expect(counts?.ahead == 1)
        #expect(counts?.behind == 1)
    }

    @Test func pullFastForwards() throws {
        let (origin, clone) = try makeRemoteSetup()
        let secondClone = TestRepo()
        try secondClone.run(["remote", "add", "origin", origin.url.path])
        try secondClone.run(["fetch", "origin"])
        try secondClone.run(["checkout", "main"])
        try secondClone.write("c.txt", "1")
        _ = try secondClone.commitAll("remote only")
        try secondClone.run(["push", "origin", "main"])

        try clone.repo.pull()
        #expect(FileManager.default.fileExists(atPath: clone.url.appendingPathComponent("c.txt").path))
    }

    @Test func fetchPrunesGoneUpstreamAndListsOrphanedLocals() throws {
        let (origin, clone) = try makeRemoteSetup()
        // Branch off, push it (so it gets an upstream), then delete it on the remote.
        try clone.run(["checkout", "-b", "feature"])
        try clone.write("f.txt", "1")
        _ = try clone.commitAll("feature work")
        try clone.run(["push", "-u", "origin", "feature"])
        try clone.run(["checkout", "main"])
        try TestRepo.run(["-C", origin.url.path, "branch", "-D", "feature"])

        // Before fetch --prune, git still thinks origin/feature exists.
        #expect(try clone.repo.branchesWithGoneUpstream().isEmpty)

        try clone.repo.fetch()

        #expect(try clone.repo.branchesWithGoneUpstream() == ["feature"])
        // main still tracks a live origin/main, so it must not be flagged.
        #expect(!(try clone.repo.branchesWithGoneUpstream().contains("main")))

        try clone.repo.deleteBranches(named: ["feature"])
        #expect(!(try clone.repo.branches().contains { $0.name == "feature" }))
        #expect(try clone.repo.branchesWithGoneUpstream().isEmpty)
    }

    @Test func branchWithNoUpstreamIsNotFlaggedAsGone() throws {
        let (_, clone) = try makeRemoteSetup()
        // A purely local branch that was never pushed has no upstream at all — not "gone".
        try clone.run(["branch", "local-only"])
        #expect(try clone.repo.branchesWithGoneUpstream().isEmpty)
    }

    @Test func listsAndChecksOutRemoteOnlyBranches() throws {
        let (origin, clone) = try makeRemoteSetup()
        // A second clone creates two branches and pushes them; the first clone only sees them
        // as remote-tracking refs after a fetch.
        let secondClone = TestRepo()
        try secondClone.run(["remote", "add", "origin", origin.url.path])
        try secondClone.run(["fetch", "origin"])
        try secondClone.run(["checkout", "main"])
        try secondClone.run(["checkout", "-b", "craft-4/production"])
        try secondClone.write("p.txt", "1")
        _ = try secondClone.commitAll("prod")
        try secondClone.run(["push", "-u", "origin", "craft-4/production"])
        try secondClone.run(["checkout", "-b", "craft-4/staging", "main"])
        try secondClone.run(["push", "-u", "origin", "craft-4/staging"])

        try clone.repo.fetch()

        let remoteOnly = try clone.repo.remoteBranchesWithoutLocalCounterpart()
        #expect(remoteOnly.map(\.name) == ["craft-4/production", "craft-4/staging"])
        #expect(remoteOnly.first?.upstreamRef == "origin/craft-4/production")
        // `main` already has a local branch, so it must not appear; nor `origin/HEAD`.
        #expect(!remoteOnly.contains { $0.name == "main" || $0.name == "HEAD" })

        try clone.repo.checkoutRemoteBranch(remoteOnly[0])
        let branches = try clone.repo.branches()
        #expect(branches.first { $0.name == "craft-4/production" }?.isCurrent == true)
        // Upstream is wired up so pull/push know where to go.
        let upstream = try clone.run(["rev-parse", "--abbrev-ref", "craft-4/production@{upstream}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(upstream == "origin/craft-4/production")
        // It's no longer "remote only" now that a local branch exists.
        #expect(!(try clone.repo.remoteBranchesWithoutLocalCounterpart().contains { $0.name == "craft-4/production" }))
    }

    @Test func defaultBranchReadsOriginHead() throws {
        let (origin, clone) = try makeRemoteSetup()
        // makeRemoteSetup pushes `main`; point the bare remote's HEAD at it, then re-resolve.
        try TestRepo.run(["-C", origin.url.path, "symbolic-ref", "HEAD", "refs/heads/main"])
        try clone.repo.fetch() // runs `git remote set-head origin --auto`
        #expect(clone.repo.defaultBranch() == "main")

        // Change the default on the remote to a different branch — a plain fetch won't notice,
        // but fetch() re-runs set-head so Leaf keeps up.
        try TestRepo.run(["-C", origin.url.path, "branch", "release", "refs/heads/main"])
        try TestRepo.run(["-C", origin.url.path, "symbolic-ref", "HEAD", "refs/heads/release"])
        try clone.repo.fetch()
        #expect(clone.repo.defaultBranch() == "release")
    }

    @Test func defaultBranchNilWithoutRemote() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        _ = try t.commitAll("initial")
        #expect(t.repo.defaultBranch() == nil)
    }

    @Test func pushSetsUpstreamOnFirstPush() throws {
        let origin = TestRepo(bare: true)
        let local = TestRepo()
        try local.run(["remote", "add", "origin", origin.url.path])
        try local.write("a.txt", "1")
        _ = try local.commitAll("initial")
        try local.repo.push(branch: "main")
        let remoteBranches = try TestRepo.run(["-C", origin.url.path, "branch", "--list"])
        #expect(remoteBranches.contains("main"))
    }

    @Test func pushReportsProgressLines() throws {
        let origin = TestRepo(bare: true)
        let local = TestRepo()
        try local.run(["remote", "add", "origin", origin.url.path])
        try local.write("a.txt", "1")
        _ = try local.commitAll("initial")

        let lock = NSLock()
        var lines: [String] = []
        try local.repo.push(branch: "main") { line in
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        lock.lock()
        let captured = lines
        lock.unlock()
        #expect(!captured.isEmpty)
    }

    @Test func pushToUnreachableRemoteThrows() throws {
        let local = TestRepo()
        try local.run(["remote", "add", "origin", "/tmp/leaf-tests-nonexistent-remote-\(UUID().uuidString).git"])
        try local.write("a.txt", "1")
        _ = try local.commitAll("initial")
        #expect(throws: GitError.self) {
            try local.repo.push(branch: "main")
        }
    }

    // A line ending exactly at ")" (e.g. "Compressing objects: 100% (8/8)", with no trailing
    // ", done." text after the count) previously crashed: `formatProgressLine` sliced through
    // `closeParen.upperBound` with a *closed* range, and that upper bound is `endIndex` when ")"
    // is the line's last character — not a valid index to include in a closed range subscript.
    @Test(arguments: [
        ("Compressing objects: 100% (8/8)", "Compressing objects (8/8)"),
        ("Writing objects:  42% (5/12), 1.15 KiB | 1.15 MiB/s", "Writing objects (5/12)"),
    ])
    func formatProgressLineExtractsCounts(line: String, expected: String) {
        #expect(AppState.formatProgressLine(line) == expected)
    }

    @Test(arguments: [
        "Delta compression using up to 8 threads",
        "done.",
    ])
    func formatProgressLineReturnsNilWhenNothingToShow(line: String) {
        #expect(AppState.formatProgressLine(line) == nil)
    }
}

// MARK: - Ambiguous / quoted paths

@Suite struct QuotedPathTests {
    @Test func unquoteRoundTripsThroughStatus() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        _ = try t.commitAll("initial")
        try t.write("file with spaces.txt", "1")
        let entries = try t.repo.statusEntries()
        #expect(entries.contains { $0.path == "file with spaces.txt" })
    }

    @Test func unquoteHandlesEscapedQuoteAndBackslash() throws {
        let raw = "\"has \\\"quote\\\" and \\\\backslash.txt\""
        let unquoted = GitRepository.unquoteGitPath(raw)
        #expect(unquoted == "has \"quote\" and \\backslash.txt")
    }

    @Test func unquoteHandlesOctalEscapedNonASCII() throws {
        // git quotes a UTF-8 non-ASCII filename byte-by-byte in octal, e.g. "café.txt".
        let bytes: [UInt8] = Array("café.txt".utf8)
        var quoted = "\""
        for byte in bytes {
            if byte < 0x80 {
                quoted.append(Character(UnicodeScalar(byte)))
            } else {
                quoted += String(format: "\\%03o", byte)
            }
        }
        quoted += "\""
        #expect(GitRepository.unquoteGitPath(quoted) == "café.txt")
    }

    @Test func discardAndCleanRoundTripOnQuotedPath() throws {
        let t = TestRepo()
        try t.write("has \"quotes\".txt", "1")
        let entries = try t.repo.statusEntries()
        let file = try #require(entries.first)
        try t.repo.discardChanges(for: file)
        #expect(try t.repo.statusEntries().isEmpty)
    }
}

// MARK: - Discard / ignore / clean

@Suite struct DiscardIgnoreTests {
    @Test func discardTrackedChange() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        _ = try t.commitAll("initial")
        try t.write("a.txt", "2")
        let file = try #require(try t.repo.statusEntries().first)
        try t.repo.discardChanges(for: file)
        let contents = try String(contentsOf: t.url.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(contents == "1")
    }

    @Test func discardUntrackedCleansFile() throws {
        let t = TestRepo()
        try t.write("junk.txt", "1")
        let file = try #require(try t.repo.statusEntries().first)
        try t.repo.discardChanges(for: file)
        #expect(!FileManager.default.fileExists(atPath: t.url.appendingPathComponent("junk.txt").path))
    }

    @Test func discardBatchMixedTrackedAndUntracked() throws {
        let t = TestRepo()
        try t.write("tracked.txt", "1")
        _ = try t.commitAll("initial")
        try t.write("tracked.txt", "2")
        try t.write("untracked.txt", "1")
        let files = try t.repo.statusEntries()
        try t.repo.discardChanges(for: files)
        #expect(try t.repo.statusEntries().isEmpty)
    }

    @Test func ignoreFileAppendsToGitignore() throws {
        let t = TestRepo()
        try t.write("secret.env", "1")
        let file = try #require(try t.repo.statusEntries().first)
        try t.repo.ignoreFile(file)
        let entries = try t.repo.statusEntries()
        #expect(!entries.contains { $0.path == "secret.env" })
        let gitignore = try String(contentsOf: t.url.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(gitignore.contains("secret.env"))
    }

    @Test func ignoreFilesAppendsWithoutClobberingExisting() throws {
        let t = TestRepo()
        try t.write(".gitignore", "already-ignored.txt\n")
        _ = try t.commitAll("initial")
        try t.write("a.txt", "1")
        try t.write("b.txt", "1")
        let entries = try t.repo.statusEntries()
        try t.repo.ignoreFiles(entries)
        let gitignore = try String(contentsOf: t.url.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(gitignore.contains("already-ignored.txt"))
        #expect(gitignore.contains("a.txt"))
        #expect(gitignore.contains("b.txt"))
    }

    @Test func gitignoreCoveringNestedDirectory() throws {
        let t = TestRepo()
        try t.write(".gitignore", "build/\n")
        _ = try t.commitAll("initial")
        try t.write("build/nested/output.o", "binary junk")
        try t.write("src/main.swift", "code")
        let entries = try t.repo.statusEntries()
        let paths = Set(entries.map(\.path))
        #expect(!paths.contains(where: { $0.hasPrefix("build/") }))
        #expect(paths.contains("src/main.swift"))
    }
}

// MARK: - Binary files

@Suite struct BinaryFileTests {
    @Test func binaryFileShowsInStatusAndDoesNotCrashDiff() throws {
        let t = TestRepo()
        try t.writeBinary("image.png", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])
        let entries = try t.repo.statusEntries()
        let file = try #require(entries.first { $0.path == "image.png" })
        #expect(file.status == .untracked)
        #expect(file.isLikelyImage)
        // git's own binary diff output — just confirm this doesn't throw.
        _ = try t.repo.diff(for: file)
    }

    @Test func binaryImageContentsForWorkingChanges() throws {
        let t = TestRepo()
        let originalBytes: [UInt8] = [0x01, 0x02, 0x03]
        try t.writeBinary("image.png", originalBytes)
        _ = try t.commitAll("add image")
        let newBytes: [UInt8] = [0x04, 0x05, 0x06]
        try t.writeBinary("image.png", newBytes)

        let file = try #require(try t.repo.statusEntries().first)
        let (old, new) = t.repo.imageContents(for: file, in: .workingChanges)
        #expect(old == Data(originalBytes))
        #expect(new == Data(newBytes))
    }
}

// MARK: - Submodules

@Suite struct SubmoduleTests {
    @Test func repoWithSubmoduleDoesNotCrashStatus() throws {
        let sub = TestRepo()
        try sub.write("a.txt", "1")
        _ = try sub.commitAll("sub initial")

        let t = TestRepo()
        try t.write("a.txt", "1")
        _ = try t.commitAll("initial")
        try t.run(["-c", "protocol.file.allow=always", "submodule", "add", sub.url.path, "sub"])
        _ = try t.commitAll("add submodule")

        // Should not crash or throw — a submodule row is just another status entry.
        #expect(try t.repo.statusEntries().isEmpty)
        let branches = try t.repo.branches()
        #expect(!branches.isEmpty)
    }
}

// MARK: - Commit log / files changed in commit

@Suite struct HistoryTests {
    @Test func commitLogAndFilesChanged() throws {
        let t = TestRepo()
        try t.write("a.txt", "1")
        _ = try t.commitAll("first commit")
        try t.write("a.txt", "2")
        try t.write("b.txt", "1")
        _ = try t.commitAll("second commit")

        let log = try t.repo.commitLog(branch: "main")
        #expect(log.count == 2)
        #expect(log[0].summary == "second commit")

        let files = try t.repo.filesChanged(in: log[0])
        #expect(Set(files.map(\.path)) == ["a.txt", "b.txt"])
    }

    @Test func diffForFileInCommit() throws {
        let t = TestRepo()
        try t.write("a.txt", "1\n")
        _ = try t.commitAll("first")
        try t.write("a.txt", "2\n")
        _ = try t.commitAll("second")
        let log = try t.repo.commitLog(branch: "main")
        let files = try t.repo.filesChanged(in: log[0])
        let diff = try t.repo.diff(for: files[0], in: log[0])
        #expect(diff.contains("-1"))
        #expect(diff.contains("+2"))
    }
}

// MARK: - Ignore-whitespace diffs ("Hide Whitespace Changes" setting)

@Suite struct WhitespaceDiffTests {
    @Test func workingChangesDiffOmitsWhitespaceOnlyEdit() throws {
        let t = TestRepo()
        try t.write("a.txt", "line one\nline two\n")
        _ = try t.commitAll("initial")
        try t.write("a.txt", "line one   \nline two\n")

        let file = try #require(try t.repo.statusEntries().first)
        let normalDiff = try t.repo.diff(for: file)
        #expect(normalDiff.contains("@@"))
        let ignoredDiff = try t.repo.diff(for: file, ignoreWhitespace: true)
        #expect(ignoredDiff.isEmpty)
    }

    @Test func workingChangesDiffStillShowsRealEditWhenIgnoringWhitespace() throws {
        let t = TestRepo()
        try t.write("a.txt", "line one\n")
        _ = try t.commitAll("initial")
        try t.write("a.txt", "line ONE\n")

        let file = try #require(try t.repo.statusEntries().first)
        let ignoredDiff = try t.repo.diff(for: file, ignoreWhitespace: true)
        #expect(ignoredDiff.contains("@@"))
    }

    @Test func untrackedFileDiffIgnoresWhitespaceFlagButStillWorks() throws {
        // Untracked files go through `diff --no-index`; -w just needs to not break that path.
        let t = TestRepo()
        try t.write("new.txt", "hello\n")
        let file = try #require(try t.repo.statusEntries().first)
        let diff = try t.repo.diff(for: file, ignoreWhitespace: true)
        #expect(diff.contains("hello"))
    }

    @Test func commitDiffOmitsWhitespaceOnlyEdit() throws {
        let t = TestRepo()
        try t.write("a.txt", "line one\n")
        _ = try t.commitAll("first")
        try t.write("a.txt", "line one   \n")
        _ = try t.commitAll("second")

        let log = try t.repo.commitLog(branch: "main")
        let files = try t.repo.filesChanged(in: log[0])
        let file = try #require(files.first)

        let normalDiff = try t.repo.diff(for: file, in: log[0])
        #expect(normalDiff.contains("@@"))
        let ignoredDiff = try t.repo.diff(for: file, in: log[0], ignoreWhitespace: true)
        #expect(!ignoredDiff.contains("@@"))
    }

    @Test func stashDiffOmitsWhitespaceOnlyEdit() throws {
        let t = TestRepo()
        try t.write("a.txt", "line one\n")
        _ = try t.commitAll("initial")
        try t.write("a.txt", "line one  \n")
        try t.repo.stashChanges(paths: [], includeUntracked: true)

        let files = try t.repo.filesChanged(inStash: "stash@{0}")
        let file = try #require(files.first)
        let normalDiff = try t.repo.diff(for: file, inStash: "stash@{0}")
        #expect(normalDiff.contains("@@"))
        let ignoredDiff = try t.repo.diff(for: file, inStash: "stash@{0}", ignoreWhitespace: true)
        #expect(!ignoredDiff.contains("@@"))
    }

    @Test func diffTextRoutesIgnoreWhitespaceThroughForEachSource() throws {
        let t = TestRepo()
        try t.write("a.txt", "line one\n")
        _ = try t.commitAll("initial")
        try t.write("a.txt", "line one \n")

        let file = try #require(try t.repo.statusEntries().first)
        let text = try t.repo.diffText(for: file, in: .workingChanges, ignoreWhitespace: true)
        #expect(text.isEmpty)
    }

    @Test func conflictedFileDiffTextIgnoresWhitespaceFlagAndReturnsRawMarkers() throws {
        // `diffText` special-cases `.conflicted` to return raw working-tree contents regardless
        // of the diff source or whitespace flag — never a real `git diff`.
        let t = TestRepo()
        try t.write("a.txt", "base\n")
        _ = try t.commitAll("initial")
        try t.run(["checkout", "-b", "feature"])
        try t.write("a.txt", "feature change\n")
        _ = try t.commitAll("feature commit")
        try t.run(["checkout", "main"])
        try t.write("a.txt", "main change\n")
        _ = try t.commitAll("main commit")
        _ = try t.repo.merge(branch: "feature")

        let entries = try t.repo.statusEntries()
        let conflicted = try #require(entries.first { $0.status == .conflicted })
        let text = try t.repo.diffText(for: conflicted, in: .workingChanges, ignoreWhitespace: true)
        #expect(text.contains("<<<<<<<"))
    }
}

// MARK: - GitHub remote parsing (pure functions, no repo needed)

@Suite struct GitHubOwnerParsingTests {
    @Test(arguments: [
        ("git@github.com:owner/repo.git", "owner"),
        ("https://github.com/owner/repo.git", "owner"),
        ("https://gitlab.com/owner/repo.git", nil),
    ])
    func githubOwner(url: String, expected: String?) {
        #expect(GitRepository.githubOwner(fromRemoteURL: url) == expected)
    }

    @Test(arguments: [
        ("https://github.com/owner/repo.git", "repo"),
        ("", "repository"),
    ])
    func repoName(url: String, expected: String) {
        #expect(GitRepository.repoName(fromURLString: url) == expected)
    }
}
