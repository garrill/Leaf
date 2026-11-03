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
        #expect(toggle.displayTitle == "View > Show Whitespace Changes")

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
