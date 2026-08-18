import AppKit
import SwiftUI

/// Ahead/behind arrow glyph for `RepoRowView`'s sync status, wrapped in AppKit for the same
/// reason as `StatusIconView`: it needs to track the enclosing row's real `isSelected`/
/// `isEmphasized` state via KVO rather than SwiftUI state, so it recolors in lockstep with
/// `NSOutlineView`'s own selection paint instead of trailing it.
///
/// Tints white only while the row is both selected and emphasized (blue background); once the
/// window loses key status and the background fades to the unemphasized grey, this falls back to
/// `baseColor` — matching how the row's own text reverts to its normal (non-white) color at the
/// same moment.
struct SidebarSyncArrowIconView: NSViewRepresentable {
    let systemName: String
    let baseColor: NSColor

    func makeNSView(context: Context) -> SidebarSyncArrowImageView {
        SidebarSyncArrowImageView(systemName: systemName, baseColor: baseColor)
    }

    func updateNSView(_ nsView: SidebarSyncArrowImageView, context: Context) {
        nsView.baseColor = baseColor
    }
}

final class SidebarSyncArrowImageView: NSImageView {
    var baseColor: NSColor {
        didSet { updateTintColor() }
    }

    private var selectionObservation: NSKeyValueObservation?
    private var emphasisObservation: NSKeyValueObservation?

    init(systemName: String, baseColor: NSColor) {
        self.baseColor = baseColor
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        updateTintColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()

        guard let row = enclosingRowView else {
            selectionObservation = nil
            emphasisObservation = nil
            return
        }

        selectionObservation = row.observe(\.isSelected, options: [.initial, .new]) { [weak self] _, _ in
            self?.updateTintColor()
        }
        emphasisObservation = row.observe(\.isEmphasized, options: [.initial, .new]) { [weak self] _, _ in
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
        let row = enclosingRowView
        let isHighlighted = row?.isSelected == true && row?.isEmphasized == true
        contentTintColor = isHighlighted ? .white : baseColor
    }
}
