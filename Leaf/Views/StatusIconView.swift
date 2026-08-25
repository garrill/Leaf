import AppKit
import SwiftUI

/// The changed-files list's per-row status glyph, wrapped in AppKit instead of a plain SwiftUI
/// `Image` so its color can track the enclosing row's selection state.
///
/// `List`'s native selection highlight (and the automatic white-on-selection color flip macOS
/// gives row text) is painted directly by `NSTableRowView` on mouse-DOWN, before the SwiftUI
/// `selection` binding actually commits on mouse-UP — so a color driven by `AppState`/SwiftUI
/// state unavoidably trails the highlight by the down-to-up gap. Observing the row's own
/// `isSelected` via KVO instead reads the exact same flag AppKit uses to paint the highlight,
/// so the icon recolors in lockstep with it.
struct StatusIconView: NSViewRepresentable {
    let status: FileChangeStatus

    func makeNSView(context: Context) -> StatusIconImageView {
        StatusIconImageView(status: status)
    }

    func updateNSView(_ nsView: StatusIconImageView, context: Context) {
        nsView.status = status
    }
}

final class StatusIconImageView: NSImageView {
    var status: FileChangeStatus {
        didSet {
            image = NSImage(named: Self.assetName(for: status))
            updateTintColor()
        }
    }

    private var selectionObservation: NSKeyValueObservation?

    init(status: FileChangeStatus) {
        self.status = status
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        image = NSImage(named: Self.assetName(for: status))
        updateTintColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()

        guard let row = enclosingRowView else {
            selectionObservation = nil
            return
        }

        selectionObservation = row.observe(\.isSelected, options: [.initial, .new]) { [weak self] _, _ in
            self?.updateTintColor()
        }
    }

    private var enclosingRowView: NSTableRowView? {
        var view: NSView? = self
        while let current = view {
            if let row = current as? NSTableRowView {
                return row
            }
            view = current.superview
        }
        return nil
    }

    private func updateTintColor() {
        contentTintColor = (enclosingRowView?.isSelected == true) ? .white : Self.color(for: status)
    }

    private static func assetName(for status: FileChangeStatus) -> String {
        switch status {
        case .modified: return "GitStatusModifiedTemplate"
        case .added: return "GitStatusAddedTemplate"
        case .deleted: return "GitStatusDeletedTemplate"
        case .renamed: return "GitStatusRenamedTemplate"
        case .untracked: return "GitStatusUntrackedTemplate"
        case .conflicted: return "GitStatusConflictedTemplate"
        case .unknown: return "GitStatusUnknownTemplate"
        }
    }

    /// Matches the exact fill colors baked into the original (non-template) icon artwork, as a
    /// light/dark dynamic `NSColor` so it still adapts with the system appearance the same way
    /// the two static PNGs used to.
    private static func color(for status: FileChangeStatus) -> NSColor {
        switch status {
        case .modified: return dynamicColor(light: (242, 209, 102), dark: (188, 152, 35))
        case .added: return dynamicColor(light: (64, 220, 129), dark: (42, 162, 92))
        case .deleted: return dynamicColor(light: (220, 64, 64), dark: (143, 38, 38))
        case .renamed: return dynamicColor(light: (64, 134, 220), dark: (38, 97, 169))
        case .untracked: return dynamicColor(light: (64, 220, 129), dark: (42, 162, 92))
        case .conflicted: return dynamicColor(light: (235, 113, 31), dark: (194, 102, 41))
        case .unknown: return dynamicColor(light: (186, 186, 186), dark: (121, 117, 117))
        }
    }

    private static func dynamicColor(
        light: (Int, Int, Int),
        dark: (Int, Int, Int)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            return NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }
}

#Preview {
    let statuses: [FileChangeStatus] = [.modified, .added, .deleted, .renamed, .untracked, .conflicted, .unknown]
    HStack(spacing: 12) {
        ForEach(statuses, id: \.self) { status in
            StatusIconView(status: status)
                .frame(width: 14, height: 14)
        }
    }
    .padding()
}
