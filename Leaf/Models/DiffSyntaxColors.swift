import AppKit

/// Per-token-role syntax highlighting colors for the diff view's code. Values below start from
/// highlight.js's `.xcode` light/dark themes (comments and strings customised; `#rrggbbaa`
/// alpha is supported) — but each role is broken into its own named constant (rather than one
/// opaque CSS blob) so the Diff Theme Editor web tool can regenerate this file with different colors.
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
    /// the plain translucent black/white barely picks up the pale row background. The
    /// highlighter doesn't know a line's kind; `color(for:isDark:lineKind:)` swaps these in when
    /// the diff text is built.
    static let addedComment = Role(light: "#576B5E", dark: "#daf6e199")
    static let removedComment = Role(light: "#695454", dark: "#fbe0de99")

    /// The color for a token `role` on a line of `lineKind`, resolved once per theme.
    static func color(for role: SyntaxRole, isDark: Bool, lineKind: DiffLine.Kind) -> NSColor {
        let palette = isDark ? darkPalette : lightPalette
        if role == .comment {
            switch lineKind {
            case .added: return palette.addedComment
            case .removed: return palette.removedComment
            case .context, .meta: break
            }
        }
        return palette.roles[Int(role.rawValue)]
    }

    private struct Palette {
        let roles: [NSColor]
        let addedComment: NSColor
        let removedComment: NSColor
    }

    private static let lightPalette = palette(isDark: false)
    private static let darkPalette = palette(isDark: true)

    private static func palette(isDark: Bool) -> Palette {
        func resolve(_ role: Role) -> NSColor { nsColor(isDark ? role.dark : role.light) ?? .labelColor }
        let byRole: [SyntaxRole: Role] = [
            .base: base, .comment: comment, .keyword: keyword, .variable: variable, .string: string,
            .link: link, .number: number, .meta: meta, .type: type, .attribute: attribute, .selector: selector
        ]
        let count = Int(SyntaxRole.selector.rawValue) + 1
        let roles = (0..<count).map { raw in
            SyntaxRole(rawValue: UInt8(raw)).flatMap { byRole[$0] }.map(resolve) ?? .labelColor
        }
        return Palette(roles: roles, addedComment: resolve(addedComment), removedComment: resolve(removedComment))
    }

    /// Parses `#rrggbb` / `#rrggbbaa`.
    private static func nsColor(_ hex: String) -> NSColor? {
        let digits = hex.dropFirst()
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let rgba = digits.count == 6 ? value << 8 | 0xff : value
        func component(_ shift: UInt64) -> CGFloat { CGFloat((rgba >> shift) & 0xff) / 255 }
        return NSColor(srgbRed: component(24), green: component(16), blue: component(8), alpha: component(0))
    }

    /// hljs CSS class selectors per role, mirroring highlight.js's `.xcode` theme so
    /// language/token coverage is unaffected — only the colors differ. Resolved against hljs's
    /// span classes by `SyntaxRoleResolver` with CSS precedence (specificity, then rule order).
    nonisolated static let selectorRoles: [(selectors: String, role: SyntaxRole)] = [
        (".hljs,.hljs-subst", .base),
        (".hljs-comment,.hljs-quote", .comment),
        (".hljs-tag,.hljs-attribute,.hljs-keyword,.hljs-selector-tag,.hljs-literal,.hljs-name", .keyword),
        (".hljs-variable,.hljs-template-variable", .variable),
        (".hljs-code,.hljs-string,.hljs-meta .hljs-string,.hljs-meta-string", .string),
        (".hljs-regexp,.hljs-link", .link),
        (".hljs-title,.hljs-symbol,.hljs-bullet,.hljs-number", .number),
        (".hljs-section,.hljs-meta", .meta),
        (".hljs-class .hljs-title,.hljs-type,.hljs-built_in,.hljs-builtin-name,.hljs-params,.hljs-title.class_", .type),
        (".hljs-attr", .attribute),
        (".hljs-selector-id,.hljs-selector-class", .selector)
    ]
}
