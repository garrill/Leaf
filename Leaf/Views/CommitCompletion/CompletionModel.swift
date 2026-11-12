import Foundation

/// What a commit-message completion row stands for (picks its icon and how it's inserted).
nonisolated enum CompletionKind: Hashable, Sendable {
    case file
    case symbol
    case branch
    case person
    case coAuthor
    case issue
    case pullRequest
    case emoji
    case prefix
}

/// One row of the commit field's completion popup.
nonisolated struct CompletionItem: Identifiable, Sendable {
    let id: String
    let kind: CompletionKind
    let title: String
    /// Dimmed trailing text: a file's directory, a person's email/login, an issue's number.
    var subtitle: String?
    /// Shown in place of the kind's icon (an emoji row's glyph).
    var glyph: String?
    /// Replaces the trigger and the typed query on accept.
    let insertText: String
    /// Ranking bias over the match score, and the order with nothing typed yet.
    var boost: Int = 0
    let matchKey: MatchKey
    /// Title offsets the query hit, bolded in the row. Set by `CompletionFilter.filter`.
    var matchedIndices: [Int] = []

    init(
        id: String,
        kind: CompletionKind,
        title: String,
        subtitle: String? = nil,
        glyph: String? = nil,
        insertText: String,
        keywords: [String] = [],
        fuzzy: MatchFuzzyTarget = .title,
        boost: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.glyph = glyph
        self.insertText = insertText
        self.boost = boost
        matchKey = MatchKey(title: title, keywords: keywords, fuzzy: fuzzy)
    }
}

/// Which trigger the text before the caret is.
nonisolated enum CompletionTriggerKind: Hashable, Sendable {
    /// `` ` `` — files, symbols from the diff, branches.
    case backtick
    /// `@` — people from history.
    case mention
    /// A `Co-authored-by:` line in the description — the full trailer value.
    case coAuthor
    /// `#` — GitHub issues and pull requests.
    case issue
    /// `:` plus at least two characters — emoji shortcodes.
    case emoji
    /// Letters at the very start of the summary — conventional-commit types.
    case prefix
}

nonisolated struct CompletionMatch: Equatable, Sendable {
    let kind: CompletionTriggerKind
    /// UTF-16 range replaced on accept: the trigger character plus the query after it (just the
    /// query for `.coAuthor`/`.prefix`, which have no trigger character of their own).
    let tokenRange: NSRange
    let query: String
}

/// Finds the completion trigger (if any) the caret is in. Pure, so it's unit-testable.
nonisolated enum CompletionTrigger {
    static let coAuthorMarker = "co-authored-by:"
    /// Emoji needs this many characters after `:` before it opens — `:` alone is far too common.
    static let minimumEmojiQuery = 2

    static func detect(in text: String, cursor: Int, isSummary: Bool) -> CompletionMatch? {
        let string = text as NSString
        guard cursor >= 0, cursor <= string.length else { return nil }
        let lineStart = string.lineRange(for: NSRange(location: cursor, length: 0)).location
        guard lineStart <= cursor else { return nil }

        if !isSummary, let match = coAuthorMatch(in: string, lineStart: lineStart, cursor: cursor) {
            return match
        }
        if isSummary, let match = prefixMatch(in: string, cursor: cursor) {
            return match
        }

        // Walk back over the query to the trigger character.
        var start = cursor
        while start > lineStart {
            let character = string.character(at: start - 1)
            if isTriggerCharacter(character) || isWhitespace(character) { break }
            start -= 1
        }
        let triggerLocation = start - 1
        guard triggerLocation >= lineStart else { return nil }
        let trigger = string.character(at: triggerLocation)
        guard isTriggerCharacter(trigger) else { return nil }
        // Only at the start of a word — `foo@bar`, `issue#2`, `feat:` never open it.
        if triggerLocation > lineStart {
            let previous = string.character(at: triggerLocation - 1)
            guard isWhitespace(previous) || openingPunctuation.contains(previous) else { return nil }
        }
        let query = string.substring(with: NSRange(location: start, length: cursor - start))
        let range = NSRange(location: triggerLocation, length: cursor - triggerLocation)

        switch trigger {
        case backtick:
            // An odd number of backticks earlier on the line means this one closes a pair.
            var count = 0
            for index in lineStart..<triggerLocation where string.character(at: index) == backtick {
                count += 1
            }
            guard count.isMultiple(of: 2) else { return nil }
            return CompletionMatch(kind: .backtick, tokenRange: range, query: query)
        case at:
            guard query.unicodeScalars.allSatisfy(isHandleScalar) else { return nil }
            return CompletionMatch(kind: .mention, tokenRange: range, query: query)
        case hash:
            guard query.unicodeScalars.allSatisfy(isHandleScalar) else { return nil }
            return CompletionMatch(kind: .issue, tokenRange: range, query: query)
        case colon:
            guard query.count >= minimumEmojiQuery,
                  query.unicodeScalars.allSatisfy(isEmojiScalar) else { return nil }
            return CompletionMatch(kind: .emoji, tokenRange: range, query: query)
        default:
            return nil
        }
    }

    /// `Co-authored-by: <query>` as the start of the caret's line (any case, any spacing).
    private static func coAuthorMatch(in string: NSString, lineStart: Int, cursor: Int) -> CompletionMatch? {
        let markerLength = (coAuthorMarker as NSString).length
        guard cursor - lineStart >= markerLength else { return nil }
        let lead = string.substring(with: NSRange(location: lineStart, length: markerLength))
        guard lead.lowercased() == coAuthorMarker else { return nil }
        var queryStart = lineStart + markerLength
        while queryStart < cursor, string.character(at: queryStart) == space { queryStart += 1 }
        let range = NSRange(location: queryStart, length: cursor - queryStart)
        return CompletionMatch(kind: .coAuthor, tokenRange: range, query: string.substring(with: range))
    }

    /// Lowercase letters from the start of the summary up to the caret: a type being typed.
    private static func prefixMatch(in string: NSString, cursor: Int) -> CompletionMatch? {
        guard cursor > 0 else { return nil }
        let typed = string.substring(to: cursor)
        guard typed.unicodeScalars.allSatisfy({ $0.value >= 0x61 && $0.value <= 0x7A }) else { return nil }
        return CompletionMatch(kind: .prefix, tokenRange: NSRange(location: 0, length: cursor), query: typed)
    }

    private static let backtick: unichar = 0x60
    private static let at: unichar = 0x40
    private static let hash: unichar = 0x23
    private static let colon: unichar = 0x3A
    private static let space: unichar = 0x20
    private static let openingPunctuation: Set<unichar> = [0x28, 0x5B, 0x7B, 0x22, 0x27] // ( [ { " '

    private static func isTriggerCharacter(_ character: unichar) -> Bool {
        character == backtick || character == at || character == hash || character == colon
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D || character == 0xA0
    }

    private static func isHandleScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_" || scalar == "."
    }

    private static func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
            || scalar == "_" || scalar == "+" || scalar == "-"
    }
}

/// Ranks completion rows against the typed query with `PaletteMatcher`'s tiers.
nonisolated enum CompletionFilter {
    static let maxResults = 8

    /// Best `limit` rows. With nothing typed: the highest `boost` first, otherwise source order.
    static func filter(_ items: [CompletionItem], query: String, limit: Int = maxResults) -> [CompletionItem] {
        let queryKey = Array(query.lowercased())
        var scored: [(score: Int, index: Int)] = []
        scored.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if queryKey.isEmpty {
                scored.append((item.boost, index))
            } else if let score = PaletteMatcher.score(query: queryKey, key: item.matchKey) {
                scored.append((score + item.boost, index))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.prefix(limit).map { entry in
            var item = items[entry.index]
            item.matchedIndices = PaletteMatcher.matchedIndices(query: queryKey, in: item.matchKey)
            return item
        }
    }
}

/// How changed files are named in the popup and in the message: the bare file name, unless
/// another candidate shares it — then the shortest trailing path that tells them apart.
nonisolated enum FileCompletionNames {
    static func displayNames(for paths: [String]) -> [String: String] {
        let components = paths.map { $0.split(separator: "/").map(String.init) }
        var byName: [String: [Int]] = [:]
        for (index, parts) in components.enumerated() {
            byName[parts.last ?? paths[index], default: []].append(index)
        }
        var names: [String: String] = [:]
        for (name, indices) in byName {
            guard indices.count > 1 else {
                names[paths[indices[0]]] = name
                continue
            }
            for index in indices {
                let parts = components[index]
                var chosen = paths[index]
                if parts.count >= 2 {
                    for length in 2...parts.count {
                        let suffix = parts.suffix(length)
                        let clashes = indices.contains { other in
                            other != index && Array(components[other].suffix(length)) == Array(suffix)
                        }
                        if !clashes {
                            chosen = suffix.joined(separator: "/")
                            break
                        }
                    }
                }
                names[paths[index]] = chosen
            }
        }
        return names
    }
}

/// Someone who has authored or co-authored commits in the repo.
nonisolated struct CompletionPerson: Hashable, Sendable {
    let name: String
    let email: String
    /// Recency-weighted commit count — the ranking.
    var score: Int
}

nonisolated enum CompletionPeople {
    /// Parses `GitRepository.authorLogForCompletion()` output, newest commit first. People are
    /// keyed by (lowercased) email, named as in their newest commit, ranked by how often they
    /// appear, with the newest 100 commits counting triple. `excludingEmail` (you) and bots
    /// are left out.
    static func parse(_ log: String, excludingEmail: String?) -> [CompletionPerson] {
        let excluded = excludingEmail?.lowercased()
        var people: [String: CompletionPerson] = [:]
        var order: [String] = []

        func add(name: String, email: String, weight: Int) {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = email.lowercased()
            guard !name.isEmpty, !key.isEmpty, key != excluded,
                  !key.contains("[bot]"), !name.lowercased().hasSuffix("[bot]") else { return }
            if people[key] == nil {
                people[key] = CompletionPerson(name: name, email: email, score: 0)
                order.append(key)
            }
            people[key]?.score += weight
        }

        let records = log.split(separator: "\u{1D}", omittingEmptySubsequences: true)
        for (index, record) in records.enumerated() {
            let weight = index < 100 ? 3 : 1
            let fields = record.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            add(name: String(fields[0]), email: String(fields[1]), weight: weight)
            if fields.count >= 3 {
                for trailer in fields[2].split(separator: "\u{1E}") {
                    if let (name, email) = parseNameAndEmail(String(trailer)) {
                        add(name: name, email: email, weight: weight)
                    }
                }
            }
        }
        let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return people.values.sorted {
            $0.score != $1.score ? $0.score > $1.score : positions[$0.email.lowercased()]! < positions[$1.email.lowercased()]!
        }
    }

    /// "Name <email>" → (Name, email).
    static func parseNameAndEmail(_ text: String) -> (String, String)? {
        guard let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close else { return nil }
        let name = text[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        let email = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !email.isEmpty else { return nil }
        return (name, email)
    }

    /// The GitHub login a noreply address encodes: `12345+login@users.noreply.github.com` or
    /// the older `login@users.noreply.github.com`.
    static func githubLogin(fromNoreplyEmail email: String) -> String? {
        let lowered = email.lowercased()
        let suffix = "@users.noreply.github.com"
        guard lowered.hasSuffix(suffix) else { return nil }
        var local = String(email.dropLast(suffix.count))
        if let plus = local.firstIndex(of: "+"), local[..<plus].allSatisfy(\.isNumber) {
            local = String(local[local.index(after: plus)...])
        }
        return local.isEmpty ? nil : local
    }
}

/// Conventional-commit types offered at the start of the summary.
nonisolated enum ConventionalPrefixes {
    static let standardTypes = ["feat", "fix", "perf", "refactor", "docs", "test", "chore", "build", "ci", "style", "revert"]

    /// How often each type leads a summary (`type:`, `type(scope):`, `type!:`), lowercased.
    static func usageCounts(in summaries: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for summary in summaries {
            guard let colon = summary.firstIndex(of: ":") else { continue }
            var type = summary[..<colon]
            if type.hasSuffix("!") { type = type.dropLast() }
            if let paren = type.firstIndex(of: "(") {
                guard type.hasSuffix(")") else { continue }
                type = type[..<paren]
            }
            guard !type.isEmpty, type.count <= 12, type.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
            counts[type.lowercased(), default: 0] += 1
        }
        return counts
    }

    /// The standard types plus any other the repo has used at least twice, most-used first.
    static func rankedTypes(counts: [String: Int]) -> [String] {
        var types = standardTypes
        for (type, count) in counts where count >= 2 && !types.contains(type) {
            types.append(type)
        }
        let positions = Dictionary(uniqueKeysWithValues: types.enumerated().map { ($1, $0) })
        return types.sorted {
            let (a, b) = (counts[$0, default: 0], counts[$1, default: 0])
            return a != b ? a > b : positions[$0]! < positions[$1]!
        }
    }

    /// Types `query` is a prefix of, in ranked order.
    static func matches(_ query: String, rankedTypes: [String]) -> [String] {
        rankedTypes.filter { $0.hasPrefix(query) }
    }
}

/// Code-looking identifiers from changed lines, offered inside backticks.
nonisolated enum CompletionIdentifiers {
    private static let stopWords: Set<String> = [
        "self", "Self", "init", "func", "return", "guard", "super", "some", "else", "while", "switch",
        "case", "true", "false", "null", "this", "function", "const", "async", "await", "print",
        "String", "Bool", "Int", "Double", "Array", "Optional", "Void", "type", "import", "from",
    ]

    /// The `+`/`-` lines of a unified diff (file headers excluded).
    static func changedLines(inDiff diff: String) -> [Substring] {
        diff.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let first = line.first, first == "+" || first == "-" else { return nil }
            if line.hasPrefix("+++") || line.hasPrefix("---") { return nil }
            return line.dropFirst()
        }
    }

    /// Identifiers of 4+ characters that look like code — camelCase / PascalCase with an inner
    /// capital, snake_case, or used as `.member` / `call(` — most frequent first, deduplicated.
    static func extract(from lines: [Substring], limit: Int = 2000) -> [String] {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        for line in lines {
            let bytes = Array(line.utf8)
            var index = 0
            while index < bytes.count {
                guard isIdentifierStart(bytes[index]) else {
                    index += 1
                    continue
                }
                let start = index
                index += 1
                while index < bytes.count, isIdentifierCharacter(bytes[index]) { index += 1 }
                let length = index - start
                guard length >= 4, length <= 80 else { continue }
                let token = bytes[start..<index]
                let afterDot = start > 0 && bytes[start - 1] == UInt8(ascii: ".")
                let beforeParen = index < bytes.count && bytes[index] == UInt8(ascii: "(")
                let innerCapital = token.dropFirst().contains { $0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z") }
                    && token.contains { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }
                let innerUnderscore = token.dropFirst().dropLast().contains(UInt8(ascii: "_"))
                guard afterDot || beforeParen || innerCapital || innerUnderscore else { continue }
                let word = String(decoding: token, as: UTF8.self)
                guard !stopWords.contains(word) else { continue }
                if counts[word] == nil { firstSeen[word] = firstSeen.count }
                counts[word, default: 0] += 1
            }
        }
        return counts.keys
            .sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : firstSeen[$0]! < firstSeen[$1]! }
            .prefix(limit)
            .map { $0 }
    }

    private static func isIdentifierStart(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || byte == UInt8(ascii: "_")
    }

    private static func isIdentifierCharacter(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    }
}

/// GitHub's emoji shortcodes, bundled (`emoji.json`, generated from github/gemoji, MIT) and
/// loaded the first time `:` completion runs.
nonisolated enum EmojiCatalog {
    static let items: [CompletionItem] = {
        guard let url = Bundle.main.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let pairs = try? JSONDecoder().decode([[String]].self, from: data) else { return [] }
        return pairs.compactMap { pair -> CompletionItem? in
            guard pair.count == 2 else { return nil }
            return CompletionItem(
                id: "emoji:\(pair[0])",
                kind: .emoji,
                title: pair[0],
                glyph: pair[1],
                insertText: ":\(pair[0]):",
                fuzzy: .none
            )
        }
    }()
}
