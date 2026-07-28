import HighlightSwift

/// Per-token-role syntax highlighting colors for the diff view's code. Values below reproduce
/// HighlightSwift's built-in `.xcode` light/dark themes exactly, so the look is unchanged out of
/// the box — but each role is broken into its own named constant (rather than one opaque CSS
/// blob) so the Diff Theme Editor web tool can regenerate this file with different colors.
enum DiffSyntaxColors {
    struct Role {
        let light: String
        let dark: String
    }

    static let base = Role(light: "#000000", dark: "#ffffff")
    static let comment = Role(light: "#007400", dark: "#6c7986")
    static let keyword = Role(light: "#aa0d91", dark: "#fc5fa3")
    static let variable = Role(light: "#3f6e74", dark: "#fc5fa3")
    static let string = Role(light: "#c41a16", dark: "#fc6a5d")
    static let link = Role(light: "#0e0eff", dark: "#5482ff")
    static let number = Role(light: "#1c00cf", dark: "#41a1c0")
    static let meta = Role(light: "#643820", dark: "#fc5fa3")
    static let type = Role(light: "#5c2699", dark: "#d0a8ff")
    static let attribute = Role(light: "#836c28", dark: "#bf8555")
    static let selector = Role(light: "#9b703f", dark: "#9b703f")

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
