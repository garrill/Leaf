import AppKit
import Foundation
import Testing
@testable import Leaf

private func item(_ title: String, keywords: [String] = [], boost: Int = 0) -> PaletteItem {
    PaletteItem(id: title, kind: .command, title: title, symbol: "circle", keywords: keywords, boost: boost, perform: {})
}

@Suite struct PaletteMatcherTests {
    @Test func prefixBeatsSubstringBeatsSubsequence() {
        let items = [item("Delete Branch"), item("Leaf"), item("Show Legend")]
        let titles = PaletteMatcher.filter(items, query: "le").map(\.title)
        #expect(titles == ["Leaf", "Show Legend", "Delete Branch"])
    }

    @Test func fuzzySubsequenceMatchesAcrossWords() {
        let titles = PaletteMatcher.filter([item("Stash All Changes"), item("Push")], query: "sac").map(\.title)
        #expect(titles == ["Stash All Changes"])
    }

    @Test func keywordsMatchWhenTitleDoesNot() {
        let titles = PaletteMatcher.filter([item("Push", keywords: ["upload"]), item("Pull")], query: "upl").map(\.title)
        #expect(titles == ["Push"])
    }

    @Test func boostBreaksEqualMatches() {
        let titles = PaletteMatcher.filter([item("main"), item("main", boost: 40)], query: "main").map(\.boost)
        #expect(titles == [40, 0])
    }

    @Test func resultsCappedAtNine() {
        let items = (0..<30).map { item("Item \($0)") }
        #expect(PaletteMatcher.filter(items, query: "item").count == PaletteMatcher.maxResults)
    }

    @Test func noMatchIsExcludedAndEmptyQueryIsEmpty() {
        #expect(PaletteMatcher.filter([item("Fetch")], query: "zz").isEmpty)
        #expect(PaletteMatcher.filter([item("Fetch")], query: "  ").isEmpty)
    }
}

@MainActor @Suite struct CommandPaletteModelTests {
    @Test func emptyQueryShowsSuggestionsAndTypingFilters() {
        let model = CommandPaletteModel()
        model.reset(items: [item("Leaf"), item("Fetch")], suggestions: [item("Recent")])
        #expect(model.results.map(\.title) == ["Recent"])
        model.query = "fe"
        #expect(model.results.map(\.title) == ["Fetch"])
        #expect(model.selectedIndex == 0)
    }

    @Test func ghostCompletesPrefixOrHintsTitle() {
        let model = CommandPaletteModel()
        model.reset(items: [item("Fetch"), item("Stash All Changes")], suggestions: [])
        model.query = "FE"
        #expect(model.ghost == .completion("tch"))
        #expect(model.acceptCompletion())
        #expect(model.query == "Fetch")
        #expect(model.ghost == nil)
        model.query = "sac"
        #expect(model.ghost == .hint("Stash All Changes"))
        #expect(!model.acceptCompletion())
    }

    @Test func repoGhostEndsWithOpenAndScopedCommandsNameTheRepo() {
        let repo = SidebarRepo(id: UUID(), path: "/amricc", displayNameOverride: nil, iconPath: nil, folderID: nil, sortIndex: 0)
        let repoItem = PaletteItem(id: "r", kind: .repo(repo), title: "amricc", symbol: "circle", perform: {})
        let rename = PaletteItem(id: "c", kind: .command, title: "Rename", scope: "Leaf", symbol: "circle", perform: {})
        #expect(rename.displayTitle == "Leaf \u{2013} Rename")
        let toggle = PaletteItem(id: "m", kind: .command, title: "Show Whitespace Changes", menuPath: "View", symbol: "circle", perform: {})
        #expect(toggle.displayTitle == "View › Show Whitespace Changes")

        let model = CommandPaletteModel()
        model.reset(items: [repoItem, rename], suggestions: [repoItem])
        #expect(model.ghost == .completion("amricc \u{2013} Open"))
        model.query = "am"
        #expect(model.ghost == .completion("ricc \u{2013} Open"))
        #expect(model.acceptCompletion())
        #expect(model.ghost == .completion(" \u{2013} Open"))
        model.query = "ren"
        #expect(model.ghost == .completion("ame \u{2013} Leaf"))
        model.query = "nam"
        #expect(model.ghost == .hint("Leaf \u{2013} Rename"))
    }

    @Test func selectionWraps() {
        let model = CommandPaletteModel()
        model.reset(items: [], suggestions: [item("A"), item("B"), item("C")])
        model.moveSelection(by: -1)
        #expect(model.selectedItem?.title == "C")
        model.moveSelection(by: 1)
        #expect(model.selectedItem?.title == "A")
    }
}

@Suite struct RecentReposStoreTests {
    private func makeDefaults() -> UserDefaults {
        let name = "LeafTests.recents.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func repo(_ path: String) -> SidebarRepo {
        SidebarRepo(id: UUID(), path: path, displayNameOverride: nil, iconPath: nil, folderID: nil, sortIndex: 0)
    }

    @Test func mostRecentFirstDedupedAndPersisted() {
        let defaults = makeDefaults()
        let store = RecentReposStore(defaults: defaults)
        store.recordOpened(path: "/a")
        store.recordOpened(path: "/b")
        store.recordOpened(path: "/a")
        #expect(store.paths == ["/a", "/b"])
        #expect(RecentReposStore(defaults: defaults).paths == ["/a", "/b"])
    }

    @Test func recentExcludesCurrentDropsStaleAndFillsFromSidebar() {
        let store = RecentReposStore(defaults: makeDefaults())
        for path in ["/gone", "/c", "/b", "/a"] { store.recordOpened(path: path) }
        // MRU is now /a, /b, /c, /gone.
        let repos = ["/a", "/b", "/c", "/d"].map(repo)
        #expect(store.recent(from: repos, limit: 3, excludingPath: "/a", exists: { _ in true }).map(\.path) == ["/b", "/c", "/d"])
        let fresh = RecentReposStore(defaults: makeDefaults())
        #expect(fresh.recent(from: repos, limit: 3, excludingPath: nil, exists: { _ in true }).map(\.path) == ["/a", "/b", "/c"])
    }

    @Test func missingFoldersAreNeverSuggested() {
        let store = RecentReposStore(defaults: makeDefaults())
        for path in ["/b", "/missing", "/a"] { store.recordOpened(path: path) }
        let repos = ["/a", "/missing", "/b"].map(repo)
        let suggested = store.recent(from: repos, limit: 3, excludingPath: nil, exists: { $0 != "/missing" })
        #expect(suggested.map(\.path) == ["/a", "/b"])
    }

    @Test func capacityIsBounded() {
        let store = RecentReposStore(defaults: makeDefaults())
        for index in 0..<(RecentReposStore.capacity + 5) { store.recordOpened(path: "/\(index)") }
        #expect(store.paths.count == RecentReposStore.capacity)
    }
}

@Suite struct HeadSummaryTests {
    @Test func reportsBranchAndDateThenDetachedShortSHA() throws {
        let test = TestRepo()
        let unborn = test.repo.headSummary()
        #expect(unborn.branch == "main")
        #expect(unborn.lastCommitDate == nil)

        try test.write("a.txt", "a")
        let sha = try test.commitAll("first")
        let onBranch = test.repo.headSummary()
        #expect(onBranch.branch == "main")
        #expect(onBranch.lastCommitDate != nil)

        try TestRepo.run(["-C", test.url.path, "checkout", "--detach", sha])
        let detached = test.repo.headSummary()
        #expect(detached.branch.map { sha.hasPrefix($0) } == true)
    }
}

@Suite struct PaletteHighlightAndAvailabilityTests {
    @Test func matchedIndicesCoverPrefixSubstringAndSubsequence() throws {
        let prefix = try #require(PaletteMatcher.filter([item("Fetch")], query: "fe").first)
        #expect(prefix.matchedIndices == [0, 1])
        let substring = try #require(PaletteMatcher.filter([item("Show Legend")], query: "leg").first)
        #expect(substring.matchedIndices == [5, 6, 7])
        let fuzzy = try #require(PaletteMatcher.filter([item("Stash All Changes")], query: "sac").first)
        #expect(fuzzy.matchedIndices == [0, 6, 10])
        let keyword = try #require(PaletteMatcher.filter([item("Push", keywords: ["upload"])], query: "upl").first)
        #expect(keyword.matchedIndices.isEmpty)
    }

    @Test func unavailableRowsRankBelowRunnableOnesAndArentSelectedByDefault() {
        var push = item("Push")
        push.unavailableReason = "Nothing to push"
        let pull = item("Pull")
        #expect(PaletteMatcher.filter([push, pull], query: "pu").map(\.title) == ["Pull", "Push"])

        let model = CommandPaletteModel()
        var fetch = item("Fetch")
        fetch.unavailableReason = "Busy"
        model.reset(items: [fetch, item("Fetch All")], suggestions: [])
        model.query = "fetch"
        // Exact-match Fetch still outranks Fetch All despite the penalty — but isn't selected.
        #expect(model.results.map(\.title) == ["Fetch", "Fetch All"])
        #expect(model.selectedItem?.title == "Fetch All")
    }

    @Test func fuzzyCanBeOffOrRunAgainstOtherText() {
        let commit = PaletteItem(id: "c", kind: .commit, title: "Shorten all copy", symbol: "c", fuzzy: .none, perform: {})
        #expect(PaletteMatcher.filter([commit], query: "sac").isEmpty)
        let file = PaletteItem(id: "f", kind: .file, title: "AppState.swift", symbol: "f", fuzzy: .text("Leaf/ViewModels/AppState.swift"), perform: {})
        #expect(PaletteMatcher.filter([file], query: "vmapp").map(\.id) == ["f"])
    }

    @Test func modifierFromFlagsIgnoresCombinationsAndCapsLock() {
        #expect(PaletteModifier(flags: [.option]) == .option)
        #expect(PaletteModifier(flags: [.shift, .capsLock]) == .shift)
        #expect(PaletteModifier(flags: [.command]) == .command)
        #expect(PaletteModifier(flags: [.option, .shift]) == nil)
        #expect(PaletteModifier(flags: []) == nil)
    }
}

@MainActor @Suite struct PaletteDynamicItemTests {
    @Test func dynamicItemsLeadAndShareTheNineSlotCap() {
        let model = CommandPaletteModel()
        let items = (0..<20).map { item("New thing \($0)") }
        model.reset(items: items, suggestions: [], dynamicItems: { query in
            [PaletteItem(id: "dyn", kind: .command, title: "Typed: \(query)", symbol: "d", perform: {})]
        })
        model.query = "new"
        #expect(model.results.first?.id == "dyn")
        #expect(model.results.count == PaletteMatcher.maxResults)
    }

    @Test func argumentCommandsCompleteToTheirPrefixAndShowAPlaceholder() {
        var newBranch = item("New Branch…")
        newBranch.argumentPrefix = "New Branch "
        newBranch.argumentPlaceholder = "branch name"
        let model = CommandPaletteModel()
        model.reset(items: [newBranch], suggestions: [])
        model.query = "new b"
        #expect(model.ghost == .completion("ranch \u{2039}branch name\u{203A}"))
        #expect(model.acceptCompletion())
        #expect(model.query == "New Branch ")
        #expect(model.ghost == .completion("\u{2039}branch name\u{203A}"))
    }

    @Test func ghostOverrideIsShownVerbatimAndNeverAccepted() {
        var dynamic = item("New Branch “x”")
        dynamic.ghostOverride = ""
        let model = CommandPaletteModel()
        model.reset(items: [], suggestions: [], dynamicItems: { _ in [dynamic] })
        model.query = "new branch x"
        #expect(model.ghost == nil)
        #expect(!model.acceptCompletion())
    }
}

@Suite struct PaletteParsingTests {
    @Test func argumentsFollowAPhraseAndASpace() {
        let phrases = ["new branch", "branch"]
        #expect(CommandPaletteItems.argument(in: "New Branch feature/x", after: phrases) == "feature/x")
        #expect(CommandPaletteItems.argument(in: "branch  fix ", after: phrases) == "fix")
        #expect(CommandPaletteItems.argument(in: "new branch ", after: phrases) == nil)
        #expect(CommandPaletteItems.argument(in: "branches", after: phrases) == nil)
        #expect(CommandPaletteItems.argument(in: "commit fix the thing", after: ["commit"]) == "fix the thing")
    }

    @Test func refNamesHaveWhitespaceTurnedIntoDashes() {
        #expect(CommandPaletteItems.sanitizedRefName("fix login  bug") == "fix-login-bug")
        #expect(CommandPaletteItems.sanitizedRefName("feature/x") == "feature/x")
    }

    @Test func cloneURLsAreRecognised() {
        #expect(CommandPaletteItems.cloneURL(in: "https://github.com/a/b.git") != nil)
        #expect(CommandPaletteItems.cloneURL(in: "git@github.com:a/b.git") != nil)
        #expect(CommandPaletteItems.cloneURL(in: "ssh://git@host.com/a/b") != nil)
        #expect(CommandPaletteItems.cloneURL(in: "https://github.com") == nil)
        #expect(CommandPaletteItems.cloneURL(in: "push origin") == nil)
        #expect(CommandPaletteItems.cloneURL(in: "fetch") == nil)
    }

    @Test func folderPathsAcceptTildeQuotesEscapesAndFileURLs() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("palette path \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.standardizedFileURL.path
        #expect(CommandPaletteItems.folderPath(in: path) == path)
        #expect(CommandPaletteItems.folderPath(in: "\"\(path)\"") == path)
        #expect(CommandPaletteItems.folderPath(in: path.replacingOccurrences(of: " ", with: "\\ ")) == path)
        #expect(CommandPaletteItems.folderPath(in: base.absoluteString) == path)
        #expect(CommandPaletteItems.folderPath(in: "~") == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
        #expect(CommandPaletteItems.folderPath(in: path + "/missing") == nil)
        #expect(CommandPaletteItems.folderPath(in: "Leaf") == nil)
    }

    @Test func githubWebURLsFromEveryRemoteForm() {
        let expected = URL(string: "https://github.com/owner/repo")
        #expect(GitRepository.githubWebURL(fromRemoteURL: "git@github.com:owner/repo.git") == expected)
        #expect(GitRepository.githubWebURL(fromRemoteURL: "https://github.com/owner/repo.git") == expected)
        #expect(GitRepository.githubWebURL(fromRemoteURL: "https://github.com/owner/repo") == expected)
        #expect(GitRepository.githubWebURL(fromRemoteURL: "ssh://git@github.com/owner/repo.git") == expected)
        #expect(GitRepository.githubWebURL(fromRemoteURL: "git@gitlab.com:owner/repo.git") == nil)
        #expect(GitRepository.githubWebURL(fromRemoteURL: "https://github.com/owner") == nil)
    }

    @Test func githubPathsKeepSlashesAndEncodeTheRest() {
        let base = URL(string: "https://github.com/o/r")!
        #expect(CommandPaletteItems.githubURL(base, path: "tree/feature/x")?.absoluteString == "https://github.com/o/r/tree/feature/x")
        #expect(CommandPaletteItems.githubURL(base, path: "compare/a b", query: "expand=1")?.absoluteString == "https://github.com/o/r/compare/a%20b?expand=1")
    }
}

@Suite struct CommandUsageStoreTests {
    private func makeDefaults() -> UserDefaults {
        let name = "LeafTests.usage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func boostGrowsWithUseIsCappedAndPersists() {
        let defaults = makeDefaults()
        let store = CommandUsageStore(defaults: defaults)
        let now = Date()
        #expect(store.boost(for: "git:Fetch", now: now) == 0)
        store.recordUse(of: "git:Fetch", at: now)
        let once = store.boost(for: "git:Fetch", now: now)
        for _ in 0..<50 { store.recordUse(of: "git:Fetch", at: now) }
        let often = store.boost(for: "git:Fetch", now: now)
        #expect(once > 0)
        #expect(often > once)
        #expect(often <= CommandUsageStore.maxBoost)
        #expect(CommandUsageStore(defaults: defaults).boost(for: "git:Fetch", now: now) == often)
    }

    @Test func boostDecaysWithAge() {
        let store = CommandUsageStore(defaults: makeDefaults())
        let then = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<5 { store.recordUse(of: "k", at: then) }
        let fresh = store.boost(for: "k", now: then.addingTimeInterval(60))
        let week = store.boost(for: "k", now: then.addingTimeInterval(10 * 86_400))
        let old = store.boost(for: "k", now: then.addingTimeInterval(90 * 86_400))
        #expect(fresh > week)
        #expect(week > old)
        #expect(old > 0)
    }

    @Test func capacityDropsLeastRecentlyUsed() {
        let store = CommandUsageStore(defaults: makeDefaults())
        let start = Date(timeIntervalSince1970: 0)
        for index in 0..<(CommandUsageStore.capacity + 3) {
            store.recordUse(of: "k\(index)", at: start.addingTimeInterval(TimeInterval(index)))
        }
        #expect(store.entries.count == CommandUsageStore.capacity)
        #expect(store.entries["k0"] == nil)
        #expect(store.entries["k\(CommandUsageStore.capacity + 2)"] != nil)
    }
}

@Suite struct PaletteReviewFixTests {
    @Test func keywordAndPathMatchesHighlightNothingInTheTitle() throws {
        let commit = PaletteItem(id: "c", kind: .commit, title: "Fix a3 flag", symbol: "c", keywords: ["a3f9c21"], fuzzy: .none, perform: {})
        let shaHit = try #require(PaletteMatcher.filter([commit], query: "a3f").first)
        #expect(shaHit.matchedIndices.isEmpty)

        let file = PaletteItem(id: "f", kind: .file, title: "Main.swift", symbol: "f", fuzzy: .text("Views/Models/Main.swift"), perform: {})
        let pathHit = try #require(PaletteMatcher.filter([file], query: "vms").first)
        #expect(pathHit.matchedIndices.isEmpty)
        let nameHit = try #require(PaletteMatcher.filter([file], query: "main").first)
        #expect(nameHit.matchedIndices == [0, 1, 2, 3])

        let keywordAndTitle = try #require(PaletteMatcher.filter([item("Push", keywords: ["upload"])], query: "up").first)
        #expect(keywordAndTitle.matchedIndices.isEmpty)
    }

    @Test func credentialsAreStrippedFromRemoteURLs() {
        #expect(GitRepository.redactedRemoteURL("https://user:ghp_secret@github.com/o/r.git") == "https://github.com/o/r.git")
        #expect(GitRepository.redactedRemoteURL("https://ghp_secret@github.com/o/r.git") == "https://github.com/o/r.git")
        #expect(GitRepository.redactedRemoteURL("ssh://git:pw@host.com/o/r.git") == "ssh://git@host.com/o/r.git")
        #expect(GitRepository.redactedRemoteURL("ssh://git@host.com/o/r.git") == "ssh://git@host.com/o/r.git")
        #expect(GitRepository.redactedRemoteURL("git@github.com:o/r.git") == "git@github.com:o/r.git")
        #expect(GitRepository.redactedRemoteURL("https://github.com/o/r.git") == "https://github.com/o/r.git")
    }

    @Test func githubParsingHandlesPortsAndRejectsLookalikeHosts() {
        let expected = URL(string: "https://github.com/owner/repo")
        #expect(GitRepository.githubWebURL(fromRemoteURL: "ssh://git@github.com:22/owner/repo.git") == expected)
        #expect(GitRepository.githubWebURL(fromRemoteURL: "https://www.github.com/owner/repo") == expected)
        #expect(GitRepository.githubWebURL(fromRemoteURL: "https://notgithub.com/owner/repo") == nil)
        #expect(GitRepository.githubWebURL(fromRemoteURL: "git@notgithub.com:owner/repo.git") == nil)
        #expect(GitRepository.githubWebURL(fromRemoteURL: "https://github.com.evil.com/owner/repo") == nil)
        #expect(GitRepository.githubOwner(fromRemoteURL: "ssh://git@github.com:22/owner/repo.git") == "owner")
        #expect(GitRepository.githubOwner(fromRemoteURL: "https://notgithub.com/owner/repo") == nil)
    }

    @Test func upstreamReportsTheTrackedBranchNotTheLocalName() throws {
        let test = TestRepo()
        try test.write("a.txt", "a")
        _ = try test.commitAll("first")
        #expect(test.repo.upstream(ofBranch: "main") == nil)
        try TestRepo.run(["-C", test.url.path, "config", "branch.main.remote", "origin"])
        try TestRepo.run(["-C", test.url.path, "config", "branch.main.merge", "refs/heads/feature/fix"])
        let upstream = try #require(test.repo.upstream(ofBranch: "main"))
        #expect(upstream.remote == "origin")
        #expect(upstream.branch == "feature/fix")
    }
}

@MainActor @Suite struct PaletteModelReviewFixTests {
    @Test func replacingItemsKeepsQueryAndSelection() {
        let model = CommandPaletteModel()
        model.reset(items: [item("Fetch"), item("Fetch All"), item("Fetch Tags")], suggestions: [])
        model.query = "fetch"
        model.selectedIndex = 2
        let selected = model.selectedItem?.id
        model.replaceItems([item("Fetch"), item("Fetch All"), item("Fetch Tags")], suggestions: [], dynamicItems: { _ in [] })
        #expect(model.query == "fetch")
        #expect(model.selectedItem?.id == selected)
    }
}
