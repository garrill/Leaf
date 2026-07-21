import Foundation
import HighlightSwift

/// Thin wrapper around HighlightSwift's `Highlight`. A single shared instance is used because
/// its underlying `HLJS` actor lazily loads and caches a JavaScriptCore context on first use —
/// constructing a fresh `Highlight()` per call would reparse highlight.min.js every time.
enum CodeHighlighter {
    static let shared = Highlight()

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
