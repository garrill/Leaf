import AppKit
import SwiftUI

/// Shows a tooltip with the full, untruncated string when a truncated single-line `Text` is
/// hovered, after a short delay (matching native tooltip behavior).
///
/// The tooltip itself renders in a standalone, non-activating `NSPanel` positioned in screen
/// coordinates at the label's own top-left corner — not a SwiftUI `.overlay` — specifically so
/// it can extend beyond the bounds of whatever clips its host view (a `List` row, a resizable
/// column, a toolbar item, etc.), the same way a real AppKit tooltip would.
///
/// Detection works by comparing the ideal (untruncated) width of the string, measured via a
/// hidden `fixedSize()` copy, against the width actually available to the visible text.
private struct TruncationTooltip: ViewModifier {
    let text: String
    @State private var isTruncated = false

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { visibleGeo in
                    // Reuses `content` itself (not a fresh `Text`) so the ideal-width probe below
                    // carries the exact same font/weight/etc. as what's actually rendered —
                    // otherwise a mismatched font here (e.g. a caller-applied `.font`/`.fontWeight`)
                    // throws off the width comparison and reports truncation that isn't real.
                    content
                        .lineLimit(1)
                        .fixedSize()
                        .hidden()
                        .background(
                            GeometryReader { idealGeo in
                                Color.clear
                                    .onAppear {
                                        updateTruncated(idealWidth: idealGeo.size.width, visibleWidth: visibleGeo.size.width)
                                    }
                                    .onChange(of: idealGeo.size.width) { _, newValue in
                                        updateTruncated(idealWidth: newValue, visibleWidth: visibleGeo.size.width)
                                    }
                                    .onChange(of: visibleGeo.size.width) { _, newValue in
                                        updateTruncated(idealWidth: idealGeo.size.width, visibleWidth: newValue)
                                    }
                            }
                        )
                }
            )
            .overlay(TooltipHoverProbe(text: text, isTruncated: isTruncated))
    }

    private func updateTruncated(idealWidth: CGFloat, visibleWidth: CGFloat) {
        isTruncated = idealWidth > visibleWidth + 0.5
    }
}

extension View {
    /// Applies `TruncationTooltip` for `text`. Use on a single-line, truncating `Text` view.
    func truncationTooltip(_ text: String) -> some View {
        modifier(TruncationTooltip(text: text))
    }
}

/// A transparent, click-through `NSView` overlay whose only job is tracking hover (via
/// `NSTrackingArea`, independent of hit-testing) to drive `TooltipPanel`.
private struct TooltipHoverProbe: NSViewRepresentable {
    let text: String
    let isTruncated: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.text = text
        view.isTruncated = isTruncated
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.text = text
        nsView.isTruncated = isTruncated
    }

    final class ProbeView: NSView {
        var text: String = ""
        var isTruncated: Bool = false {
            didSet {
                if !isTruncated { cancelPendingShow(); TooltipPanel.shared.hide(owner: self) }
            }
        }
        private var trackingArea: NSTrackingArea?
        private var showWorkItem: DispatchWorkItem?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            guard isTruncated else { return }
            cancelPendingShow()
            let item = DispatchWorkItem { [weak self] in
                self?.presentTooltip()
            }
            showWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
        }

        override func mouseExited(with event: NSEvent) {
            cancelPendingShow()
            TooltipPanel.shared.hide(owner: self)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                cancelPendingShow()
                TooltipPanel.shared.hide(owner: self)
            }
        }

        private func cancelPendingShow() {
            showWorkItem?.cancel()
            showWorkItem = nil
        }

        private func presentTooltip() {
            guard let window, isTruncated else { return }
            // Top-left corner of this view, in screen coordinates — the tooltip is positioned
            // to start exactly there, over the start of the truncated text it's replacing.
            let topLeftInWindow = convert(NSPoint(x: 0, y: 0), to: nil)
            let topLeftOnScreen = window.convertPoint(toScreen: topLeftInWindow)
            TooltipPanel.shared.show(text: text, topLeftOnScreen: topLeftOnScreen, owner: self)
        }
    }
}

/// A single shared, reused tooltip panel — avoids creating an `NSWindow` per row in a long list,
/// and there is only ever one tooltip visible at a time regardless of which row is hovered.
private final class TooltipPanel {
    static let shared = TooltipPanel()

    private let panel: NSPanel
    private let label: NSTextField
    private weak var currentOwner: AnyObject?

    private init() {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.lineBreakMode = .byClipping
        self.label = label

        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 5
        contentView.addSubview(label)

        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // A real window shadow (rather than a manually drawn `CALayer` shadow) so it renders
        // correctly around the panel's rounded corners regardless of content size.
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = contentView
        self.panel = panel
    }

    private static func backgroundColor(forDark isDark: Bool) -> NSColor {
        isDark ? NSColor(white: 0.24, alpha: 1) : NSColor(white: 0.9, alpha: 1)
    }

    func show(text: String, topLeftOnScreen: NSPoint, owner: AnyObject) {
        currentOwner = owner
        label.stringValue = text
        label.sizeToFit()

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        panel.contentView?.layer?.backgroundColor = Self.backgroundColor(forDark: isDark).cgColor

        let horizontalPadding: CGFloat = 5
        let verticalPadding: CGFloat = 3
        let size = NSSize(width: label.frame.width + horizontalPadding * 2, height: label.frame.height + verticalPadding * 2)
        label.frame.origin = NSPoint(x: horizontalPadding, y: verticalPadding)

        // Shifted up-and-left by exactly the label's own padding, so the tooltip's text lands
        // precisely over the truncated text it's replacing rather than sitting offset below/right
        // of it by the padding amount.
        let origin = NSPoint(x: topLeftOnScreen.x - horizontalPadding - 2, y: topLeftOnScreen.y - size.height + verticalPadding)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)
    }

    func hide(owner: AnyObject) {
        guard currentOwner === owner else { return }
        panel.orderOut(nil)
        currentOwner = nil
    }
}
