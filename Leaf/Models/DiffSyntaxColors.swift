import AppKit
import HighlightSwift

/// Per-token-role syntax highlighting colors for the diff view's code. Values below start from
/// HighlightSwift's built-in `.xcode` light/dark themes (comments and strings
/// customised; `#rrggbbaa` alpha works since hljs HTML goes through `NSAttributedString`'s
/// WebKit import) — but each role is broken into its own named constant (rather than one opaque CSS
/// blob) so the Diff Theme Editor web tool can regenerate this file with different colors.
enum DiffSyntaxColors {
    struct Role {
        let light: String
        let dark: String
    }

    static let base = Role(light: "#000000", dark: "#ffffff")
    static let comment = Role(light: "#000000aa", dark: "#ffffff99")
    static let keyword = Role(light: "#aa0d91", dark: "#fc5fa3")
    static let variable = Role(light: "#3f6e74", dark: "#fc5fa3")
    static let string = Role(light: "#003066", dark: "#fd8f85")
    static let link = Role(light: "#0e0eff", dark: "#5482ff")
    static let number = Role(light: "#1c00cf", dark: "#41a1c0")
    static let meta = Role(light: "#643820", dark: "#fc5fa3")
    static let type = Role(light: "#5c2699", dark: "#d0a8ff")
    static let attribute = Role(light: "#836c28", dark: "#bf8555")
    static let selector = Role(light: "#9b703f", dark: "#9b703f")

    /// Comment color on added/removed lines — `comment` tinted toward the row's green/red, since
    /// the plain translucent black/white barely picks up the pale row background. Not part of
    /// the hljs CSS (the highlighter doesn't know a line's kind); `commentColor(replacing:for:)`
    /// swaps these in when the diff text is built.
    static let addedComment = Role(light: "#576B5E", dark: "#daf6e199")
    static let removedComment = Role(light: "#695454", dark: "#fbe0de99")

    /// If `color` is the `comment` role's color (light or dark — whichever theme the highlight
    /// was computed for), returns the tinted comment color for an added/removed line of the same
    /// theme; otherwise `nil`. Matched on RGBA so a fully-opaque base-text run never matches.
    static func commentColor(replacing color: NSColor, for kind: DiffLine.Kind) -> NSColor? {
        let tinted: Role
        switch kind {
        case .added: tinted = addedComment
        case .removed: tinted = removedComment
        case .context, .meta: return nil
        }
        if matches(color, comment.light) { return nsColor(tinted.light) }
        if matches(color, comment.dark) { return nsColor(tinted.dark) }
        return nil
    }

    private static func matches(_ color: NSColor, _ hex: String) -> Bool {
        guard let a = color.usingColorSpace(.sRGB), let b = nsColor(hex) else { return false }
        let tolerance: CGFloat = 0.01
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
            && abs(a.alphaComponent - b.alphaComponent) < tolerance
    }

    /// Parses `#rrggbb` / `#rrggbbaa`.
    private static func nsColor(_ hex: String) -> NSColor? {
        let digits = hex.dropFirst()
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let rgba = digits.count == 6 ? value << 8 | 0xff : value
        func component(_ shift: UInt64) -> CGFloat { CGFloat((rgba >> shift) & 0xff) / 255 }
        return NSColor(srgbRed: component(24), green: component(16), blue: component(8), alpha: component(0))
    }

    /// Selector groupings mirror HighlightSwift's built-in `.xcode` theme (see the package's
    /// `HighlightCSS.swift`) so language/token coverage is unaffected — only the colors differ.
    private static let selectorGroups: [(selectors: String, role: Role)] = [
        (".hljs,.hljs-subst", base),
        (".hljs-comment,.hljs-quote", comment),
        (".hljs-tag,.hljs-attribute,.hljs-keyword,.hljs-selector-tag,.hljs-literal,.hljs-name", keyword),
        (".hljs-variable,.hljs-template-variable", variable),
        (".hljs-code,.hljs-string,.hljs-meta .hljs-string,.hljs-meta-string", string),
        (".hljs-regexp,.hljs-link", link),
        (".hljs-title,.hljs-symbol,.hljs-bullet,.hljs-number", number),
        (".hljs-section,.hljs-meta", meta),
        (".hljs-class .hljs-title,.hljs-type,.hljs-built_in,.hljs-builtin-name,.hljs-params,.hljs-title.class_", type),
        (".hljs-attr", attribute),
        (".hljs-selector-id,.hljs-selector-class", selector)
    ]

    private static func css(isDark: Bool) -> String {
        var rules = ["pre code.hljs{display:block;overflow-x:auto;padding:1em}code.hljs{padding:3px 5px}"]
        rules += selectorGroups.map { "\($0.selectors){color:\(isDark ? $0.role.dark : $0.role.light)}" }
        rules.append(".hljs-doctag,.hljs-strong{font-weight:700}")
        rules.append(".hljs-formula,.hljs-emphasis{font-style:italic}")
        return rules.joined()
    }

    static func colors(isDark: Bool) -> HighlightColors {
        .custom(css: css(isDark: isDark))
    }
}
