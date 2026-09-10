import AppKit
import SwiftUI

/// Shows a tooltip with the full string when a single-line `Text` is actually truncated — and
/// nothing when it fits.
///
/// The tooltip renders in a standalone, non-activating `NSPanel` positioned in screen
/// coordinates at the label's own top-left corner (not a SwiftUI `.overlay`), so its text lands
/// directly over the truncated text it's replacing and can extend past whatever clips its host
/// row/column.
///
/// Nothing is measured or instantiated at rest. Hover detection is SwiftUI's own `.onHover`
/// (one lightweight tracking area per *realised* row — a lazy `List` only realises the
/// on-screen ones), and only while the pointer is actually over the text does a tiny
/// `NSViewRepresentable` appear whose sole job is to give the truncation check a real view to
/// measure against and a real window to convert coordinates through. That transient view is
/// gone the instant the pointer leaves, so it never accumulates across a 10k-row list and never
/// forces the `List` to build every row up front the way a permanent per-row representable does.
private struct TruncationTooltip: ViewModifier {
    let text: String
    let isEnabled: Bool
    let font: NSFont

    @State private var isHovering = false

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onHover { isHovering = $0 }
                .overlay {
                    if isHovering {
                        TooltipAnchor(text: text, font: font)
                    }
                }
        } else {
            content
        }
    }
}

extension NSFont {
    /// Same family and size, restyled to `weight` — for building a measurement font that
    /// matches a `Text` styled with `.fontWeight(...)`.
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

extension View {
    /// Applies a truncation-only tooltip for `text`. Use on a single-line, truncating `Text`.
    ///
    /// - Parameters:
    ///   - text: the full string to show when the visible text is truncated.
    ///   - isEnabled: pass `false` to skip entirely (e.g. the caller isn't truncating at all).
    ///   - font: the `NSFont` the visible text is rendered in, used to measure whether it's
    ///     truncated. Defaults to the standard system body font; pass a match when the `Text`
    ///     uses a different style (e.g. `.headline`, `.subheadline`).
    func truncationTooltip(
        _ text: String,
        isEnabled: Bool = true,
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    ) -> some View {
        modifier(TruncationTooltip(text: text, isEnabled: isEnabled, font: font))
    }
}

/// Present only while the pointer is over the labelled text. Overlays the text exactly, so its
/// `bounds` is the width available to the text and `convert(_:to: nil)` gives the text's
/// on-screen position. Decides (once, here) whether the text is truncated and, if so, drives
/// `TooltipPanel` after the standard hover delay.
private struct TooltipAnchor: NSViewRepresentable {
    let text: String
    let font: NSFont

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.text = text
        view.font = font
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.text = text
        nsView.font = font
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.tearDown()
    }

    final class AnchorView: NSView {
        var text: String = ""
        var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)

        private var showWorkItem: DispatchWorkItem?
        private var isHitTestingForOcclusionCheck = false

        override var isFlipped: Bool { true }

        // Click-through so this never steals a click from the row it sits on. Flipped briefly to
        // a real hit-test only for the occlusion check below.
        override func hitTest(_ point: NSPoint) -> NSView? {
            isHitTestingForOcclusionCheck ? super.hitTest(point) : nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            guard isTextTruncated else { return }
            // Match the system tooltip delay before showing.
            let item = DispatchWorkItem { [weak self] in self?.presentTooltip() }
            showWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { tearDown() }
        }

        func tearDown() {
            showWorkItem?.cancel()
            showWorkItem = nil
            TooltipPanel.shared.hide(owner: self)
        }

        /// Whether the full string doesn't fit the width this view overlays. Core Text only —
        /// no view, no layout pass.
        private var isTextTruncated: Bool {
            guard bounds.width > 0 else { return false }
            let idealWidth = (text as NSString).size(withAttributes: [.font: font]).width
            return idealWidth > bounds.width + 0.5
        }

        /// SwiftUI's `.onHover` fires from the row's frame and can report a hover for a row that
        /// has scrolled under a `.safeAreaBar`-docked header/footer. Re-verify via a real
        /// hit-test from the window content view that this anchor (not an occluding sibling) is
        /// actually under the cursor. Invoked once, on show — not per row.
        private func isTopmostAtCurrentMouseLocation() -> Bool {
            guard let window else { return false }
            let mouseInWindow = window.mouseLocationOutsideOfEventStream
            isHitTestingForOcclusionCheck = true
            defer { isHitTestingForOcclusionCheck = false }
            return window.contentView?.hitTest(mouseInWindow) === self
        }

        private func presentTooltip() {
            guard let window, isTextTruncated, isTopmostAtCurrentMouseLocation() else { return }
            // Top-left corner of this view in screen coordinates — the panel is positioned to
            // start exactly there, over the start of the truncated text it's replacing.
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

        // The anchor view is torn down on hover-out, which hides the panel — but scrolling the
        // row out from under a stationary cursor, or the window losing key/active status, may
        // not produce a hover-out, so also force-hide on those.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hideUnconditionally() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hideUnconditionally() }
        NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hideUnconditionally() }
    }

    private func hideUnconditionally() {
        panel.orderOut(nil)
        currentOwner = nil
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
