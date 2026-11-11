import Foundation
import JavaScriptCore

/// A syntax-highlighting token role. Each maps to one color pair in `DiffSyntaxColors`.
nonisolated enum SyntaxRole: UInt8, Sendable {
    case base, comment, keyword, variable, string, link, number, meta, type, attribute, selector
}

/// One colored run inside a single line, as UTF-16 offsets relative to the line's own start
/// (matching `NSString`/`NSAttributedString` ranges). Kept to 12 bytes on purpose: the
/// `AttributedString` runs the HTML importer used to produce cost roughly 1 KB each.
nonisolated struct SyntaxToken: Equatable, Sendable {
    var location: Int32
    var length: Int32
    var role: SyntaxRole

    var range: NSRange { NSRange(location: Int(location), length: Int(length)) }
}

/// Runs highlight.js in a JavaScriptCore context and turns its HTML output into compact
/// per-line `SyntaxToken`s with a small hand-written span parser.
///
/// This used to go through HighlightSwift, which converted hljs's HTML with
/// `NSAttributedString(data:options:[.documentType: .html])`. That HTML importer loads WebKit
/// into the process (about 25 MB that never goes away), and its output carries a full attribute
/// dictionary per run. hljs only ever emits `<span class="…">`, `</span>` and five escaped
/// entities, so parsing that by hand needs neither.
///
/// Results are cached by run text (`BoundedCache`, about 4 MB). Colors aren't part of the
/// result; `DiffCodeScrollView` resolves them per theme, so switching light/dark re-colors from
/// the cache without another JS call. The JS context is dropped after `idleUnloadDelay` with no
/// highlighting, or on memory pressure (`purge()`), and reloads (tens of ms) on next use.
enum SyntaxHighlighter {
    private static let engine = HighlightEngine()

    /// Cost counts the token storage plus the key's own text, which the cache also keeps alive.
    private static var cache = BoundedCache<CacheKey, CachedTokens>(costLimit: 4 * 1024 * 1024) { $0.cost }

    private struct CachedTokens {
        let lines: [[SyntaxToken]]
        let cost: Int
    }

    private struct CacheKey: Hashable {
        let text: String
        let language: String?
    }

    private static let idleUnloadDelay: Duration = .seconds(120)
    private static var idleUnloadTask: Task<Void, Never>?

    /// Highlights `text` (lines joined by "\n") and returns one token array per line, or nil if
    /// hljs couldn't highlight it (unknown language, JS error, or output that didn't decode back
    /// to `text`'s exact length). `language` is an hljs alias from `language(forPath:)`; nil
    /// uses hljs's auto-detection.
    static func tokens(for text: String, language: String?) async -> [[SyntaxToken]]? {
        let key = CacheKey(text: text, language: language)
        if let cached = cache[key] {
            return cached.lines
        }
        scheduleIdleUnload()
        guard let lines = await engine.highlight(text, language: language) else { return nil }
        let tokenBytes = lines.reduce(0) { $0 + $1.count * MemoryLayout<SyntaxToken>.stride + 32 }
        cache[key] = CachedTokens(lines: lines, cost: text.utf8.count + tokenBytes)
        return lines
    }

    /// Drops every cached result and frees the JS context. Called on system memory pressure.
    static func purge() {
        cache.removeAll()
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        Task { await engine.unload() }
    }

    private static func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task {
            try? await Task.sleep(for: idleUnloadDelay)
            guard !Task.isCancelled else { return }
            await engine.unload()
        }
    }

    /// Maps a file path's extension to an hljs language alias, so callers can skip hljs's
    /// slower, less reliable auto-detection on short snippets. Every alias here is registered in
    /// the bundled `highlight.min.js`, except `clojure`/`elixir`, which hljs rejects and so stay
    /// unhighlighted (same as before this moved off HighlightSwift).
    static func language(forPath path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "m", "h": return "objectivec"
        case "mm", "cc", "cpp", "cxx", "hpp", "hh": return "cpp"
        case "c": return "c"
        case "cs": return "csharp"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "py": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "php": return "php"
        case "html", "htm": return "html"
        case "css": return "css"
        case "scss": return "scss"
        case "less": return "less"
        case "json": return "json"
        case "yml", "yaml": return "yaml"
        case "toml": return "toml"
        case "md", "markdown": return "markdown"
        case "sh", "bash", "zsh": return "bash"
        case "sql": return "sql"
        case "dockerfile": return "dockerfile"
        case "makefile", "mk": return "makefile"
        case "lua": return "lua"
        case "pl", "pm": return "perl"
        case "r": return "r"
        case "scala": return "scala"
        case "hs": return "haskell"
        case "clj", "cljs": return "clojure"
        case "ex", "exs": return "elixir"
        case "dart": return "dart"
        case "graphql", "gql": return "graphql"
        case "xml", "plist", "storyboard", "xib": return "html"
        default: return nil
        }
    }
}

/// Owns the JavaScriptCore context. An actor so JS evaluation and HTML parsing run off the main
/// thread, one request at a time (a `JSContext` isn't thread-safe).
private actor HighlightEngine {
    private var context: JSContext?
    private var hljs: JSValue?

    func highlight(_ text: String, language: String?) -> [[SyntaxToken]]? {
        guard let hljs = loadIfNeeded(), let context else { return nil }
        context.exception = nil
        let result: JSValue?
        if let language {
            result = hljs.invokeMethod("highlight", withArguments: [text, ["language": language, "ignoreIllegals": false]])
        } else {
            result = hljs.invokeMethod("highlightAuto", withArguments: [text])
        }
        guard context.exception == nil,
              let value = result?.objectForKeyedSubscript("value"),
              value.isString,
              let html = value.toString() else { return nil }
        let lines = HighlightHTMLParser.parse(html)
        // Any mismatch means the parser and hljs disagree about the text — never paint offsets
        // that might not line up with what's on screen.
        guard lines.decodedUTF16Count == text.utf16.count else { return nil }
        return lines.tokens
    }

    func unload() {
        hljs = nil
        context = nil
    }

    private func loadIfNeeded() -> JSValue? {
        if let hljs { return hljs }
        guard let url = Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return nil }
        context.evaluateScript(script)
        guard let hljs = context.objectForKeyedSubscript("hljs"), hljs.isObject else { return nil }
        self.context = context
        self.hljs = hljs
        return hljs
    }
}

/// Parses highlight.js HTML output (only `<span class="…">`, `</span>`, text and HTML-escaped
/// entities) into per-line tokens. The role for each piece of text is resolved the way the
/// browser would apply `DiffSyntaxColors`' CSS: the innermost span with a matching rule wins
/// (highest specificity, later rule on a tie), otherwise it inherits from its parent.
nonisolated enum HighlightHTMLParser {
    struct Result {
        var tokens: [[SyntaxToken]]
        var decodedUTF16Count: Int
    }

    static func parse(_ html: String) -> Result {
        var lines: [[SyntaxToken]] = []
        var current: [SyntaxToken] = []
        var column: Int32 = 0
        var total = 0
        // Each open span's classes and resolved role; the bottom entry is `code.hljs` itself.
        var stack: [(classes: [Substring], role: SyntaxRole)] = [(["hljs"], .base)]

        func emit(_ length: Int32) {
            guard length > 0 else { return }
            let role = stack[stack.count - 1].role
            defer { column += length; total += Int(length) }
            guard role != .base else { return }
            if var last = current.last, last.role == role, last.location + last.length == column {
                last.length += length
                current[current.count - 1] = last
            } else {
                current.append(SyntaxToken(location: column, length: length, role: role))
            }
        }

        func endLine() {
            lines.append(current)
            current = []
            column = 0
            total += 1
        }

        let bytes = Array(html.utf8)
        var index = 0
        var runLength: Int32 = 0 // UTF-16 length of plain text pending emission

        func flush() {
            emit(runLength)
            runLength = 0
        }

        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "<"):
                flush()
                guard let close = bytes[index...].firstIndex(of: UInt8(ascii: ">")) else {
                    index = bytes.count
                    break
                }
                let tag = String(decoding: bytes[(index + 1)..<close], as: UTF8.self)
                if tag.hasPrefix("/") {
                    if stack.count > 1 { stack.removeLast() }
                } else {
                    let classes = classAttribute(of: tag).split(separator: " ")
                    let ancestors = stack
                    let role = SyntaxRoleResolver.role(classes: classes, ancestors: ancestors.map(\.classes)) ?? stack[stack.count - 1].role
                    stack.append((classes, role))
                }
                index = close + 1
            case UInt8(ascii: "&"):
                let end = bytes[index...].prefix(10).firstIndex(of: UInt8(ascii: ";"))
                if let end, let decoded = decodeEntity(String(decoding: bytes[(index + 1)..<end], as: UTF8.self)) {
                    runLength += Int32(decoded.utf16.count)
                    index = end + 1
                } else {
                    runLength += 1
                    index += 1
                }
            case UInt8(ascii: "\n"):
                flush()
                endLine()
                index += 1
            default:
                // UTF-16 length from UTF-8: one unit per scalar, two for a 4-byte (astral) scalar.
                if byte & 0xC0 != 0x80 { runLength += 1 }
                if byte & 0xF8 == 0xF0 { runLength += 1 }
                index += 1
            }
        }
        flush()
        lines.append(current)
        return Result(tokens: lines, decodedUTF16Count: total)
    }

    private static func classAttribute(of tag: String) -> Substring {
        guard let start = tag.range(of: "class=\"") else { return "" }
        let rest = tag[start.upperBound...]
        return rest[..<(rest.firstIndex(of: "\"") ?? rest.endIndex)]
    }

    private static func decodeEntity(_ name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default:
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits, radix: 10)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }
}

/// CSS-style rule matching for `DiffSyntaxColors.selectorGroups`. Supports exactly what that
/// table uses: compound class selectors (`.hljs-title.class_`) with an optional single
/// descendant ancestor (`.hljs-meta .hljs-string`).
nonisolated enum SyntaxRoleResolver {
    private struct Rule {
        let ancestor: Substring?
        let classes: [Substring]
        let role: SyntaxRole
        let order: Int
        var specificity: Int { classes.count + (ancestor == nil ? 0 : 1) }
    }

    private static let rules: [Rule] = {
        var rules: [Rule] = []
        for (selectors, role) in DiffSyntaxColors.selectorRoles {
            for selector in selectors.split(separator: ",") {
                let parts = selector.split(separator: " ")
                guard let last = parts.last else { continue }
                let classes = last.split(separator: ".")
                rules.append(Rule(ancestor: parts.count > 1 ? parts[0].split(separator: ".").first : nil, classes: classes, role: role, order: rules.count))
            }
        }
        return rules
    }()

    static func role(classes: [Substring], ancestors: [[Substring]]) -> SyntaxRole? {
        guard !classes.isEmpty else { return nil }
        var best: Rule?
        for rule in rules where rule.classes.allSatisfy(classes.contains) {
            if let ancestor = rule.ancestor, !ancestors.contains(where: { $0.contains(ancestor) }) { continue }
            if let current = best, (current.specificity, current.order) > (rule.specificity, rule.order) { continue }
            best = rule
        }
        return best?.role
    }
}
