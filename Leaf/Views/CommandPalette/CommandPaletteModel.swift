import AppKit
import Foundation
import Observation

/// Which modifier runs a row's alternate action instead of its primary one — ⌥↩, ⇧↩, ⌘↩
/// (or the same modifier held while double-clicking).
enum PaletteModifier: CaseIterable {
    case option, shift, command

    var glyph: String {
        switch self {
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }

    /// The single modifier held in `flags`, ignoring Caps Lock/Fn etc. `nil` for none, or for a
    /// combination (⌥⇧↩ isn't bound to anything).
    init?(flags: NSEvent.ModifierFlags) {
        let relevant = flags.intersection([.option, .shift, .command, .control])
        switch relevant {
        case .option: self = .option
        case .shift: self = .shift
        case .command: self = .command
        default: return nil
        }
    }
}

/// A secondary action on a row, run with its modifier + Return.
struct PaletteAlternate {
    let modifier: PaletteModifier
    let title: String
    let perform: () -> Void
}

/// One row the command palette can show and run.
struct PaletteItem: Identifiable {
    enum Kind {
        case repo(SidebarRepo)
        case branch
        case commit
        case file
        case command
    }

    typealias FuzzyTarget = MatchFuzzyTarget

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
    /// Appended to the subtitle as a relative date ("3 days ago") when the row renders — kept
    /// as a `Date` so building hundreds of commit rows never formats dates nobody sees.
    var date: Date?
    var symbol: String
    /// The item's menu-bar shortcut, shown dimmed on the trailing side (e.g. "⇧⌘P").
    var shortcut: String?
    /// Extra search words that don't appear in the title ("upload" for Push, "git" for git
    /// commands) — matched with lower weight than the title itself.
    var keywords: [String] = []
    /// Ranking bias added to the match score — repos rank above commands with a similar match,
    /// recently opened repos above other repos, often-used commands above rarely-used ones.
    var boost: Int = 0
    /// Why the command can't run right now ("Nothing to push"). Shown in place of the subtitle,
    /// dimmed; Return/⌘N beep instead of running it. Shown rather than hidden so a command
    /// never seems to be missing from the palette.
    var unavailableReason: String?
    /// The verb the footer shows next to ↩ ("Open", "Switch", "Show").
    var actionLabel: String = "Run"
    var alternates: [PaletteAlternate] = []
    /// Key for `CommandUsageStore` — set on items worth learning habits for (commands,
    /// branches); `nil` for one-off rows like a particular commit or file.
    var usageKey: String?
    /// For a command that takes a typed argument ("New Branch ‹name›"): the text Tab/→ fills
    /// in, leaving the caret ready for the argument.
    var argumentPrefix: String?
    /// The dimmed placeholder shown once `argumentPrefix` has been typed, e.g. "branch name".
    var argumentPlaceholder: String?
    /// The row is unavailable *only* because its argument hasn't been typed yet ("Commit" with
    /// an empty message) — so Return fills in `argumentPrefix` instead of beeping. `false` for
    /// any other reason (no files checked, busy), which typing an argument couldn't fix.
    var needsArgument = false
    /// Overrides the field's autofill for this row: shown verbatim after the typed text, and
    /// never accepted by Tab. Empty means show nothing.
    var ghostOverride: String?
    let perform: () -> Void

    /// Character offsets into `title` the current query matched — bolded in the row. Set on the
    /// result copies by `PaletteMatcher.filter`, empty otherwise.
    var matchedIndices: [Int] = []

    var isEnabled: Bool { unavailableReason == nil }

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

    func alternate(for modifier: PaletteModifier) -> PaletteAlternate? {
        alternates.first { $0.modifier == modifier }
    }

    /// Precomputed once at build time so filtering never lowercases per keystroke.
    let matchKey: MatchKey

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
        fuzzy: FuzzyTarget = .title,
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
        matchKey = MatchKey(title: title, keywords: keywords, fuzzy: fuzzy)
    }
}

/// What fuzzy (subsequence) matching runs against: the title, some other text (a file's
/// full path), or nothing — commit summaries are long prose, where scattered single-letter
/// hits are noise rather than intent.
nonisolated enum MatchFuzzyTarget {
    case title
    case text(String)
    case none
}

/// The lowercased, precomputed form of a row's searchable text, scored by `PaletteMatcher`.
/// Shared by the command palette's `PaletteItem` and the commit field's `CompletionItem`.
nonisolated struct MatchKey {
    let titleKey: [Character]
    let titleWordStarts: Set<Int>
    let keywordKeys: [String]
    /// `nil` when fuzzy matching is off; the title's own key/word starts for `.title`.
    let fuzzyKey: [Character]?
    let fuzzyWordStarts: Set<Int>
    /// Whether `fuzzyKey` is the title itself — only then do fuzzy hits map to title letters.
    let fuzzyMatchesTitle: Bool
    /// The original title's character count — highlighting is skipped when lowercasing changed it.
    let titleCount: Int

    init(title: String, keywords: [String] = [], fuzzy: MatchFuzzyTarget = .title) {
        titleKey = Array(title.lowercased())
        titleCount = title.count
        titleWordStarts = PaletteMatcher.wordStarts(in: titleKey)
        keywordKeys = keywords.map { $0.lowercased() }
        switch fuzzy {
        case .title:
            fuzzyKey = titleKey
            fuzzyWordStarts = titleWordStarts
            fuzzyMatchesTitle = true
        case .text(let text):
            let key = Array(text.lowercased())
            fuzzyKey = key
            fuzzyWordStarts = PaletteMatcher.wordStarts(in: key)
            fuzzyMatchesTitle = false
        case .none:
            fuzzyKey = nil
            fuzzyWordStarts = []
            fuzzyMatchesTitle = false
        }
    }
}

/// Scores a query against a palette item. Tiers, highest first: exact title, title prefix,
/// prefix of a word in the title, contiguous substring, keyword prefix, then a fuzzy
/// subsequence (every query character in order) that favours word-start and consecutive hits.
/// `nil` means no match at all.
nonisolated enum PaletteMatcher {
    static let maxResults = 9
    /// Ranking penalty for an unavailable command, so it never beats a runnable match of the
    /// same tier but still shows when it's what was typed.
    static let unavailablePenalty = 60

    static func score(query: [Character], item: PaletteItem) -> Int? {
        score(query: query, key: item.matchKey)
    }

    static func score(query: [Character], key item: MatchKey) -> Int? {
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
        if let fuzzyKey = item.fuzzyKey,
           let fuzzy = subsequenceScore(query: query, in: fuzzyKey, wordStarts: item.fuzzyWordStarts) {
            return 100 + fuzzy
        }
        return nil
    }

    /// Top `limit` matches, best first; ties keep `items`' original order. Each result carries
    /// the title offsets the query hit (`matchedIndices`) — computed for the returned handful
    /// only, never per candidate.
    static func filter(_ items: [PaletteItem], query: String, limit: Int = maxResults) -> [PaletteItem] {
        let queryKey = Array(query.trimmingCharacters(in: .whitespaces).lowercased())
        guard !queryKey.isEmpty, limit > 0 else { return [] }
        var scored: [(score: Int, index: Int)] = []
        scored.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if let score = score(query: queryKey, item: item) {
                let penalty = item.isEnabled ? 0 : unavailablePenalty
                scored.append((score + item.boost - penalty, index))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.prefix(limit).map { entry in
            var item = items[entry.index]
            item.matchedIndices = matchedIndices(query: queryKey, in: item.matchKey)
            return item
        }
    }

    /// Where in the title the query hit, following the same tiers as `score`: the contiguous
    /// run for a prefix/substring match, the subsequence positions for a fuzzy match *on the
    /// title*, and nothing when what matched was a keyword (a commit's SHA) or a non-title
    /// fuzzy key (a file's directory) — bolding look-alike letters in the title would claim a
    /// match that isn't there. Offsets are only meaningful when lowercasing kept the title's
    /// character count — otherwise nothing is highlighted rather than the wrong letters.
    static func matchedIndices(query: [Character], in item: MatchKey) -> [Int] {
        let title = item.titleKey
        guard !query.isEmpty, title.count == item.titleCount else { return [] }
        if let index = firstIndex(of: query, in: title) {
            return Array(index..<(index + query.count))
        }
        let queryString = String(query)
        guard item.fuzzyMatchesTitle,
              !item.keywordKeys.contains(where: { $0.hasPrefix(queryString) }),
              subsequenceScore(query: query, in: title, wordStarts: item.titleWordStarts) != nil
        else { return [] }
        // Subsequence: each query letter takes the next word-start occurrence when the rest of
        // the query can still match after it — "sac" bolds Stash *A*ll *C*hanges, not the "a"
        // inside "Stash" — otherwise the next occurrence of any kind.
        var positions: [Int] = []
        var start = 0
        for queryIndex in query.indices {
            let character = query[queryIndex]
            let rest = query[(queryIndex + 1)...]
            let candidates = (start..<title.count).filter { title[$0] == character }
            guard let first = candidates.first else { return [] }
            let chosen = candidates.first { candidate in
                item.titleWordStarts.contains(candidate) && isSubsequence(rest, of: title[(candidate + 1)...])
            } ?? first
            positions.append(chosen)
            start = chosen + 1
        }
        return positions
    }

    private static func isSubsequence(_ needle: ArraySlice<Character>, of haystack: ArraySlice<Character>) -> Bool {
        var iterator = needle.makeIterator()
        var next = iterator.next()
        for character in haystack where character == next {
            next = iterator.next()
            if next == nil { return true }
        }
        return next == nil
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
    /// Rows derived from the typed text itself rather than matched against `items` — "New
    /// Branch foo", a pasted clone URL or folder path. Always listed first.
    @ObservationIgnored private var dynamicItems: (String) -> [PaletteItem] = { _ in [] }

    /// Starts a fresh session: clears the query and shows `suggestions` (the recent repos)
    /// until something is typed.
    func reset(
        items: [PaletteItem],
        suggestions: [PaletteItem],
        dynamicItems: @escaping (String) -> [PaletteItem] = { _ in [] }
    ) {
        self.items = items
        self.suggestions = suggestions
        self.dynamicItems = dynamicItems
        query = ""
        refilter()
        focusRequest &+= 1
    }

    /// Swaps in freshly built items mid-session (e.g. once the background missing-folder check
    /// lands) without disturbing what's been typed: re-filters, and keeps the selected row
    /// selected if it's still there.
    func replaceItems(
        _ items: [PaletteItem],
        suggestions: [PaletteItem],
        dynamicItems: @escaping (String) -> [PaletteItem]
    ) {
        let selectedID = selectedItem?.id
        self.items = items
        self.suggestions = suggestions
        self.dynamicItems = dynamicItems
        refilter()
        if let selectedID, let index = results.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        }
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
        if let override = item.ghostOverride {
            return override.isEmpty ? nil : .completion(override)
        }
        if query.isEmpty {
            if case .repo = item.kind { return .completion(item.title + item.ghostTrailer) }
            return .completion(item.displayTitle)
        }
        let lowered = query.lowercased()
        if let prefix = item.argumentPrefix, let placeholder = item.argumentPlaceholder {
            if lowered == prefix.lowercased() { return .completion("\u{2039}\(placeholder)\u{203A}") }
            if prefix.lowercased().hasPrefix(lowered) {
                return .completion(String(prefix.dropFirst(query.count)) + "\u{2039}\(placeholder)\u{203A}")
            }
        }
        if item.title.lowercased().hasPrefix(lowered) {
            let rest = String(item.title.dropFirst(query.count)) + item.ghostTrailer
            return rest.isEmpty ? nil : .completion(rest)
        }
        if case .repo = item.kind { return .hint(item.title + item.ghostTrailer) }
        return .hint(item.displayTitle)
    }

    /// Tab/→ at the end of the field: fill in the selected row's full title — or, for a command
    /// that takes an argument, its prefix ("New Branch "), ready for the argument to be typed.
    func acceptCompletion() -> Bool {
        guard let item = selectedItem, item.ghostOverride == nil else { return false }
        let lowered = query.lowercased()
        if let prefix = item.argumentPrefix,
           prefix.count > query.count,
           prefix.lowercased().hasPrefix(lowered) {
            query = prefix
            return true
        }
        guard item.title.count > query.count,
              item.title.lowercased().hasPrefix(lowered) else { return false }
        query = item.title
        return true
    }

    private func refilter() {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            results = suggestions
        } else {
            let dynamic = Array(dynamicItems(query).prefix(PaletteMatcher.maxResults))
            let matched = PaletteMatcher.filter(items, query: query, limit: PaletteMatcher.maxResults - dynamic.count)
            results = dynamic + matched
        }
        // Land on something Return can actually run; an unavailable row is still selectable
        // with the arrows (to read why), just never the default.
        selectedIndex = results.firstIndex(where: \.isEnabled) ?? 0
    }
}
