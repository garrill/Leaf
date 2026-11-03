import Foundation
import Observation

/// One row the command palette can show and run.
struct PaletteItem: Identifiable {
    enum Kind {
        case repo(SidebarRepo)
        case branch
        case command
    }

    let id: String
    let kind: Kind
    let title: String
    /// The repo a command acts on (the open one), shown before the title — "Leaf – Rename" — so
    /// it's obvious what a command will affect. Not matched against; only `title`/`keywords` are.
    var scope: String?
    /// Where an app-wide command lives in the menu bar ("View"), shown as a breadcrumb before
    /// the title — "View > Show Whitespace Changes". Not used together with `scope`.
    var menuPath: String?
    var subtitle: String?
    var symbol: String
    /// The item's menu-bar shortcut, shown dimmed on the trailing side (e.g. "⇧⌘P").
    var shortcut: String?
    /// Extra search words that don't appear in the title ("upload" for Push, "git" for git
    /// commands) — matched with lower weight than the title itself.
    var keywords: [String] = []
    /// Ranking bias added to the match score — repos rank above commands with a similar match,
    /// recently opened repos above other repos.
    var boost: Int = 0
    let perform: () -> Void

    /// "Repo – Title" for repo-scoped commands, "Menu > Title" for menu-bar commands,
    /// otherwise just the title.
    var displayTitle: String {
        guard let prefix = displayPrefix else { return title }
        return prefix + title
    }

    /// The dimmed lead-in before the title: "Leaf – " or "View › ".
    var displayPrefix: String? {
        if let scope { return "\(scope) \u{2013} " }
        if let menuPath { return "\(menuPath) › " }
        return nil
    }

    /// What follows the title in the field's autofill: the action for a repo ("amricc – Open"),
    /// the repo a scoped command affects ("Push – Leaf").
    var ghostTrailer: String {
        if case .repo = kind { return " \u{2013} Open" }
        return scope.map { " \u{2013} \($0)" } ?? ""
    }

    /// Precomputed once at build time so filtering never lowercases per keystroke.
    fileprivate(set) var titleKey: [Character] = []
    fileprivate(set) var titleWordStarts: Set<Int> = []
    fileprivate(set) var keywordKeys: [String] = []

    init(
        id: String,
        kind: Kind,
        title: String,
        scope: String? = nil,
        menuPath: String? = nil,
        subtitle: String? = nil,
        symbol: String,
        shortcut: String? = nil,
        keywords: [String] = [],
        boost: Int = 0,
        perform: @escaping () -> Void
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.scope = scope
        self.menuPath = menuPath
        self.subtitle = subtitle
        self.symbol = symbol
        self.shortcut = shortcut
        self.keywords = keywords
        self.boost = boost
        self.perform = perform
        titleKey = Array(title.lowercased())
        titleWordStarts = PaletteMatcher.wordStarts(in: titleKey)
        keywordKeys = keywords.map { $0.lowercased() }
    }
}

/// Scores a query against a palette item. Tiers, highest first: exact title, title prefix,
/// prefix of a word in the title, contiguous substring, keyword prefix, then a fuzzy
/// subsequence (every query character in order) that favours word-start and consecutive hits.
/// `nil` means no match at all.
enum PaletteMatcher {
    static let maxResults = 9

    static func score(query: [Character], item: PaletteItem) -> Int? {
        guard !query.isEmpty else { return 0 }
        let title = item.titleKey
        if title == query { return 1000 }
        if title.starts(with: query) { return 900 - min(title.count - query.count, 50) }
        if let index = firstIndex(of: query, in: title) {
            if item.titleWordStarts.contains(index) { return 700 - min(index, 50) }
            return 500 - min(index, 50)
        }
        let queryString = String(query)
        for keyword in item.keywordKeys where keyword.hasPrefix(queryString) {
            return 400
        }
        if let fuzzy = subsequenceScore(query: query, in: title, wordStarts: item.titleWordStarts) {
            return 100 + fuzzy
        }
        return nil
    }

    /// Top `maxResults` matches, best first; ties keep `items`' original order.
    static func filter(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        let queryKey = Array(query.trimmingCharacters(in: .whitespaces).lowercased())
        guard !queryKey.isEmpty else { return [] }
        var scored: [(score: Int, index: Int)] = []
        scored.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if let score = score(query: queryKey, item: item) {
                scored.append((score + item.boost, index))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.prefix(maxResults).map { items[$0.index] }
    }

    static func wordStarts(in text: [Character]) -> Set<Int> {
        var starts: Set<Int> = []
        for index in text.indices {
            if index == 0 {
                starts.insert(0)
                continue
            }
            let previous = text[index - 1]
            if !previous.isLetter && !previous.isNumber && (text[index].isLetter || text[index].isNumber) {
                starts.insert(index)
            }
        }
        return starts
    }

    private static func firstIndex(of needle: [Character], in haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            var matched = true
            for offset in 1..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }

    /// 0–299: more points for hits at word starts and runs of consecutive hits, fewer for gaps.
    private static func subsequenceScore(query: [Character], in text: [Character], wordStarts: Set<Int>) -> Int? {
        var queryIndex = 0
        var score = 0
        var lastHit = -2
        for (index, character) in text.enumerated() where queryIndex < query.count {
            guard character == query[queryIndex] else { continue }
            if wordStarts.contains(index) { score += 12 }
            if index == lastHit + 1 { score += 8 }
            lastHit = index
            queryIndex += 1
        }
        guard queryIndex == query.count else { return nil }
        return max(0, min(299, score - text.count / 4))
    }
}

/// State for one palette session. Everything here is synchronous and in-memory — `items` are
/// built once when the palette opens (no git calls), and each keystroke re-filters them on the
/// spot, so results update in the same frame as the typing.
@Observable
final class CommandPaletteModel {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            refilter()
        }
    }
    private(set) var results: [PaletteItem] = []
    var selectedIndex = 0
    /// Bumped to ask the text field to (re)claim first responder — e.g. each time the palette opens.
    private(set) var focusRequest = 0

    @ObservationIgnored private var items: [PaletteItem] = []
    @ObservationIgnored private var suggestions: [PaletteItem] = []

    /// Starts a fresh session: clears the query and shows `suggestions` (the recent repos)
    /// until something is typed.
    func reset(items: [PaletteItem], suggestions: [PaletteItem]) {
        self.items = items
        self.suggestions = suggestions
        query = ""
        refilter()
        focusRequest &+= 1
    }

    var selectedItem: PaletteItem? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
    }

    func selectFirst() {
        selectedIndex = 0
    }

    func selectLast() {
        selectedIndex = max(0, results.count - 1)
    }

    /// What the field should show after the typed text, for the selected row. `.completion` is
    /// the rest of the title when the query is a prefix of it (accepted with Tab/→); `.hint` is
    /// the whole title otherwise, so it's always clear what Return will run.
    enum Ghost: Equatable {
        case completion(String)
        case hint(String)
    }

    var ghost: Ghost? {
        guard let item = selectedItem else { return nil }
        if query.isEmpty {
            if case .repo = item.kind { return .completion(item.title + item.ghostTrailer) }
            return .completion(item.displayTitle)
        }
        if item.title.lowercased().hasPrefix(query.lowercased()) {
            let rest = String(item.title.dropFirst(query.count)) + item.ghostTrailer
            return rest.isEmpty ? nil : .completion(rest)
        }
        if case .repo = item.kind { return .hint(item.title + item.ghostTrailer) }
        return .hint(item.displayTitle)
    }

    /// Tab/→ at the end of the field: fill in the selected row's full title.
    func acceptCompletion() -> Bool {
        guard let item = selectedItem,
              item.title.count > query.count,
              item.title.lowercased().hasPrefix(query.lowercased()) else { return false }
        query = item.title
        return true
    }

    private func refilter() {
        results = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? suggestions
            : PaletteMatcher.filter(items, query: query)
        selectedIndex = 0
    }
}
