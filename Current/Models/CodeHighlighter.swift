import Foundation
import HighlightSwift

/// Thin wrapper around HighlightSwift's `Highlight`. A single shared instance is used because
/// its underlying `HLJS` actor lazily loads and caches a JavaScriptCore context on first use —
/// constructing a fresh `Highlight()` per call would reparse highlight.min.js every time.
enum CodeHighlighter {
    static let shared = Highlight()

    private struct CacheKey: Hashable {
        let text: String
        let language: HighlightLanguage?
        let isDark: Bool
    }

    /// Keyed on the exact hunk-side text block, so re-viewing a file already highlighted this
    /// session (or scrolling back to a previous file) is instant with no JS round-trip. Callers
    /// only ever run on the main actor, so a plain dictionary is safe without extra locking.
    /// Unbounded for now — entries are small hunk-sized snippets, not whole files.
    private static var cache: [CacheKey: AttributedString] = [:]

    /// Highlights `text`, using the theme-appropriate Xcode colors, and caching the result.
    /// Returns nil (rather than throwing) on any HighlightSwift failure, since a highlighting
    /// error should just fall back to plain text, not surface as an app error.
    static func attributedText(_ text: String, language: HighlightLanguage?, isDark: Bool) async -> AttributedString? {
        let key = CacheKey(text: text, language: language, isDark: isDark)
        if let cached = cache[key] {
            return cached
        }
        let colors = DiffSyntaxColors.colors(isDark: isDark)
        guard let attributed = try? await request(text, language: language, colors: colors) else {
            return nil
        }
        cache[key] = attributed
        return attributed
    }

    private static func request(
        _ text: String,
        language: HighlightLanguage?,
        colors: HighlightColors
    ) async throws -> AttributedString {
        if let language {
            return try await shared.attributedText(text, language: language, colors: colors)
        }
        return try await shared.attributedText(text, colors: colors)
    }

    /// Maps a file path's extension to the closest HighlightSwift language, so callers can skip
    /// hljs's (slower, less reliable on short snippets) auto-detection.
    static func language(forPath path: String) -> HighlightLanguage? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return .swift
        case "m", "h": return .objectiveC
        case "mm", "cc", "cpp", "cxx", "hpp", "hh": return .cPlusPlus
        case "c": return .c
        case "cs": return .cSharp
        case "js", "mjs", "cjs", "jsx": return .javaScript
        case "ts", "tsx": return .typeScript
        case "py": return .python
        case "rb": return .ruby
        case "go": return .go
        case "rs": return .rust
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "php": return .php
        case "html", "htm": return .html
        case "css": return .css
        case "scss": return .scss
        case "less": return .less
        case "json": return .json
        case "yml", "yaml": return .yaml
        case "toml": return .toml
        case "md", "markdown": return .markdown
        case "sh", "bash", "zsh": return .bash
        case "sql": return .sql
        case "dockerfile": return .dockerfile
        case "makefile", "mk": return .makefile
        case "lua": return .lua
        case "pl", "pm": return .perl
        case "r": return .r
        case "scala": return .scala
        case "hs": return .haskell
        case "clj", "cljs": return .clojure
        case "ex", "exs": return .elixir
        case "dart": return .dart
        case "graphql", "gql": return .graphQL
        case "xml", "plist", "storyboard", "xib": return .html
        default: return nil
        }
    }
}
