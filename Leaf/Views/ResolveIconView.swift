import AppKit
import SwiftUI

/// The conflicted-row "mark resolved" glyph — an SF Symbol wrapped in AppKit rather than a
/// plain SwiftUI `Image` so its tint can track the enclosing row's selection highlight
/// (`NSTableRowView` paints that on mouse-DOWN, before SwiftUI's `selection` binding commits
/// on mouse-UP — see `StatusIconView`).
///
/// It renders only; the click is owned by the SwiftUI `Button` this sits inside as a label.
/// `hitTest` returns `nil` so the mouse-down falls through to that button — an `NSImageView`
/// otherwise claims the hit, and then neither the button's action nor this view's `mouseDown`
/// ever runs (SwiftUI intercepts raw AppKit events inside a `List` row).
struct ResolveIconView: NSViewRepresentable {
    /// `false` → hollow `checkmark.circle` in `.secondary`; `true` → filled green
    /// `checkmark.circle.fill` (the brief post-resolve confirmation).
    var isResolved: Bool

    func makeNSView(context: Context) -> ResolveIconImageView {
        ResolveIconImageView(isResolved: isResolved)
    }

    func updateNSView(_ nsView: ResolveIconImageView, context: Context) {
        nsView.isResolved = isResolved
    }
}

final class ResolveIconImageView: NSImageView {
    var isResolved: Bool {
        didSet {
            image = Self.symbolImage(isResolved: isResolved)
            updateTintColor()
        }
    }

    private var selectionObservation: NSKeyValueObservation?

    init(isResolved: Bool) {
        self.isResolved = isResolved
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        image = Self.symbolImage(isResolved: isResolved)
        updateTintColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Runs after the view is actually in the hierarchy — `viewDidMoveToSuperview` fires
        // while the window is still nil and no `NSTableRowView` ancestor exists yet.
        observeRowSelection()
    }

    private func observeRowSelection() {
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
        if enclosingRowView?.isSelected == true {
            contentTintColor = .white
        } else {
            contentTintColor = isResolved ? .systemGreen : .secondaryLabelColor
        }
    }

    /// Rendered at a fixed point size (rather than left to `imageScaling` alone) so the glyph
    /// reads the same weight as the adjacent bitmap status icon.
    private static func symbolImage(isResolved: Bool) -> NSImage? {
        let name = isResolved ? "checkmark.circle.fill" : "checkmark.circle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Mark as resolved")
        return image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    }
}

#Preview {
    HStack(spacing: 12) {
        ResolveIconView(isResolved: false)
            .frame(width: 15, height: 15)
        ResolveIconView(isResolved: true)
            .frame(width: 15, height: 15)
    }
    .padding()
}
