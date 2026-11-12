import Foundation
import Testing
@testable import Leaf

private func detect(_ text: String, summary: Bool = true) -> CompletionMatch? {
    CompletionTrigger.detect(in: text, cursor: (text as NSString).length, isSummary: summary)
}

@Suite struct CompletionTriggerTests {
    @Test func backtickOpensAtWordStart() {
        let match = detect("Fix `Commit")
        #expect(match?.kind == .backtick)
        #expect(match?.query == "Commit")
        #expect(match?.tokenRange == NSRange(location: 4, length: 7))
        #expect(detect("Fix `")?.query == "")
    }

    @Test func closingBacktickDoesNotOpen() {
        #expect(detect("Fix `foo`") == nil)
        #expect(detect("Fix `foo` and `ba")?.query == "ba")
    }

    @Test func midWordTriggersDoNotOpen() {
        #expect(detect("Mail foo@bar") == nil)
        #expect(detect("Fix issue#2") == nil)
        #expect(detect("Thanks @jon")?.kind == .mention)
        #expect(detect("Closes #12")?.kind == .issue)
        #expect(detect("Closes (#12")?.kind == .issue)
    }

    @Test func emojiNeedsTwoCharacters() {
        #expect(detect("Add :s") == nil)
        #expect(detect("Add :sp")?.kind == .emoji)
        #expect(detect("Fix: thing") == nil)
    }

    @Test func prefixOnlyAtStartOfSummary() {
        #expect(detect("fe")?.kind == .prefix)
        #expect(detect("fe", summary: false)?.kind == nil)
        #expect(detect("Fe") == nil)
        #expect(detect("add fe") == nil)
    }

    @Test func coAuthorOnlyInDescription() {
        let text = "Body\nCo-authored-by: Ja"
        let match = detect(text, summary: false)
        #expect(match?.kind == .coAuthor)
        #expect(match?.query == "Ja")
        #expect(detect("co-authored-by: Ja", summary: true) == nil)
    }
}

@Suite struct FileCompletionNamesTests {
    @Test func uniqueNamesAreBare() {
        let names = FileCompletionNames.displayNames(for: ["Leaf/Views/A.swift", "B.swift"])
        #expect(names["Leaf/Views/A.swift"] == "A.swift")
        #expect(names["B.swift"] == "B.swift")
    }

    @Test func clashingNamesGetShortestDistinguishingPath() {
        let names = FileCompletionNames.displayNames(for: [
            "Leaf/Views/View.swift",
            "Leaf/Models/View.swift",
            "Other/Models/View.swift",
            "View.swift",
        ])
        #expect(names["Leaf/Views/View.swift"] == "Views/View.swift")
        #expect(names["Leaf/Models/View.swift"] == "Leaf/Models/View.swift")
        #expect(names["Other/Models/View.swift"] == "Other/Models/View.swift")
        #expect(names["View.swift"] == "View.swift")
    }
}

@Suite struct CompletionPeopleTests {
    @Test func noreplyLogins() {
        #expect(CompletionPeople.githubLogin(fromNoreplyEmail: "12345+octocat@users.noreply.github.com") == "octocat")
        #expect(CompletionPeople.githubLogin(fromNoreplyEmail: "octocat@users.noreply.github.com") == "octocat")
        #expect(CompletionPeople.githubLogin(fromNoreplyEmail: "octocat@example.com") == nil)
    }

    @Test func parsesAuthorsAndCoAuthorsExcludingSelf() {
        let log = [
            "Me\u{1F}me@example.com\u{1F}Ann <ann@example.com>\u{1E}Bot [bot] <b@example.com>",
            "\nBob\u{1F}bob@example.com\u{1F}",
            "\nAnn Smith\u{1F}ANN@example.com\u{1F}",
        ].joined(separator: "\u{1D}") + "\u{1D}"
        let people = CompletionPeople.parse(log, excludingEmail: "me@example.com")
        #expect(people.map(\.name) == ["Ann", "Bob"])
        #expect(people.first?.score == 6)
    }
}

@Suite struct ConventionalPrefixTests {
    @Test func ranksByUsage() {
        let counts = ConventionalPrefixes.usageCounts(in: [
            "fix: a", "fix(ui): b", "feat!: c", "perf: d", "fix: e", "Random message", "wip: x", "wip: y",
        ])
        #expect(counts["fix"] == 3)
        #expect(counts["feat"] == 1)
        let ranked = ConventionalPrefixes.rankedTypes(counts: counts)
        #expect(Array(ranked.prefix(2)) == ["fix", "wip"])
        #expect(ConventionalPrefixes.matches("f", rankedTypes: ranked) == ["fix", "feat"])
    }
}

@Suite struct CompletionIdentifierTests {
    @Test func extractsCodeLookingIdentifiers() {
        let diff = """
        diff --git a/x.swift b/x.swift
        --- a/x.swift
        +++ b/x.swift
        @@ -1 +1 @@
        -    let value = loadDiffForCurrentSelection()
        +    appState.refresh(); render(snake_case_name)
         unchangedContextLine
        """
        let symbols = CompletionIdentifiers.extract(from: CompletionIdentifiers.changedLines(inDiff: diff))
        #expect(symbols.contains("loadDiffForCurrentSelection"))
        #expect(symbols.contains("refresh"))
        #expect(symbols.contains("snake_case_name"))
        #expect(symbols.contains("render"))
        #expect(!symbols.contains("value"))
        #expect(!symbols.contains("unchangedContextLine"))
    }
}

@Suite struct CompletionFilterTests {
    @Test func emptyQueryOrdersByBoost() {
        let items = [
            CompletionItem(id: "a", kind: .file, title: "A.swift", insertText: "`A.swift`", boost: 30),
            CompletionItem(id: "b", kind: .file, title: "B.swift", insertText: "`B.swift`", boost: 60),
        ]
        #expect(CompletionFilter.filter(items, query: "").map(\.id) == ["b", "a"])
        #expect(CompletionFilter.filter(items, query: "a.s").map(\.id) == ["a"])
    }
}
