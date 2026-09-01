import AppKit
import SwiftUI

/// Owns a single `NSTextFinder` for the diff pane and acts as its bar container.
///
/// The diff is a bare `DiffCodeTextView` laid out by `DiffCodeContainerView` and scrolled by a
/// SwiftUI `ScrollView` — there is no `NSScrollView`, so `NSTextView`'s built-in find bar never
/// appears on its own. `NSTextFinderBarContainer` is the supported way around that: we give AppKit
/// somewhere to put its find bar (surfaced to SwiftUI via `onBarInvalidated` and shown in a
/// bottom `.safeAreaBar` by `DiffFindBarHost`) and get stock incremental find — the search field
/// with its recents / match-case menu, the "n of m" count, next/previous, wrap-around, and
/// dimming the non-matching text (`incrementalSearchingShouldDimContentView`).
///
/// A plain `NSObject` with no `@MainActor` annotation, matching `DiffCodeTextView` and the other
/// AppKit views in this target — all of this runs on the main thread by convention.
final class DiffFinderController: NSObject, NSTextFinderBarContainer {
    let finder = NSTextFinder()

    /// Called with the find bar's new visibility. `DiffView` mirrors it into
    /// `AppState.diffFindBarVisible` so a `.safeAreaBar` can reveal/hide `DiffFindBarHost`.
    var onVisibilityChanged: ((Bool) -> Void)?
    /// Called whenever AppKit swaps its bar view or changes its height, so the host representable
    /// re-attaches / re-measures.
    var onBarInvalidated: (() -> Void)?

    /// The view `NSTextFinder` dims and draws match highlights into — the text view itself, the
    /// same as an `NSScrollView` container would return (its document view). Keeping the gutter
    /// and hunk rules out of it means line numbers stay readable while a search is active.
    private weak var dimmedContentView: NSView?
    private var storedFindBarView: NSView?
    private var storedFindBarVisible = false

    override init() {
        super.init()
        finder.findBarContainer = self
        finder.isIncrementalSearchingEnabled = true
        finder.incrementalSearchingShouldDimContentView = true
    }

    /// Wires the finder to a freshly-built diff container. Safe to call again when
    /// `DiffCodeScrollView` recreates its view.
    ///
    /// `DiffCodeTextView` conforms to `NSTextFinderClient` via a small extension (macOS's
    /// `NSTextView` implements most of the protocol but never declares it) — see the bottom of
    /// `DiffCodeTextView.swift`.
    func attach(to container: DiffCodeContainerView) {
        finder.client = container.textView
        container.finder = finder
        dimmedContentView = container.textView
    }

    func show() {
        finder.performAction(.showFindInterface)
        focusSearchField()
    }
    func hide() { finder.performAction(.hideFindInterface) }
    func next() { finder.performAction(.nextMatch) }
    func previous() { finder.performAction(.previousMatch) }

    /// `performAction(.showFindInterface)` reveals the bar but doesn't move first responder into
    /// its search field when the bar lives in a non-`NSScrollView` container like ours. The bar
    /// view is also only added to the window on the next SwiftUI pass (`DiffFindBarHost`), so
    /// retry across a few runloop turns until the field is on screen, then select-all + focus it.
    private func focusSearchField(attempt: Int = 0) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let field = self.storedFindBarView.flatMap({ Self.firstSearchField(in: $0) }), field.window != nil {
                field.selectText(nil)
            } else if attempt < 6 {
                self.focusSearchField(attempt: attempt + 1)
            }
        }
    }

    private static func firstSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews {
            if let found = firstSearchField(in: subview) { return found }
        }
        return nil
    }

    // MARK: - NSTextFinderBarContainer

    // Every member is explicitly `@objc` — Swift's inference for `@objc` protocol witnesses is
    // unreliable here (`contentView` in particular was silently not exposed, so AppKit's
    // "search wrapped" indicator crashed with `unrecognized selector` the first time a search
    // wrapped), and `NSTextFinder` calls all of these straight through the ObjC runtime.

    @objc var findBarView: NSView? {
        get { storedFindBarView }
        set {
            storedFindBarView = newValue
            onBarInvalidated?()
        }
    }

    @objc var isFindBarVisible: Bool {
        get { storedFindBarVisible }
        set {
            guard storedFindBarVisible != newValue else { return }
            storedFindBarVisible = newValue
            onVisibilityChanged?(newValue)
            onBarInvalidated?()
        }
    }

    @objc func findBarViewDidChangeHeight() {
        onBarInvalidated?()
    }

    // Imported from AppKit as a method (`contentView()`), not a property — declaring it as a
    // `var` is what left it invisible to the ObjC runtime before.
    @objc func contentView() -> NSView? { dimmedContentView }
}

/// Hosts the stock `NSTextFinder` find bar inside SwiftUI's bottom safe-area bar. `NSTextFinder`
/// builds the bar view lazily and hands it to `DiffFinderController`; this pins it edge-to-edge
/// and reports its resolved height back to SwiftUI. `invalidationToken` changes on every bar swap
/// or height change so `updateNSView` re-runs.
struct DiffFindBarHost: NSViewRepresentable {
    let controller: DiffFinderController
    var invalidationToken: Int

    /// Fallback bar height before `NSTextFinder`'s bar view has a resolved frame.
    private static let defaultBarHeight: CGFloat = 27

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ host: NSView, context: Context) {
        let barView = controller.findBarView
        guard host.subviews.first !== barView else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        guard let barView else { return }
        // Autoresizing rather than constraint activation: activating constraints from inside a
        // representable update runs during a layout pass and trips `_NSDetectedLayoutRecursion`.
        barView.frame = host.bounds
        barView.autoresizingMask = [.width, .height]
        host.addSubview(barView)
        Self.clearOpaqueBackgrounds(in: barView)
    }

    /// The stock find bar paints an opaque bar background. Drop it (and any nested box fill) so
    /// the soft scroll-edge blur behind the bar shows through instead. Left the search field and
    /// any `NSVisualEffectView` alone — those carry the field's own look.
    private static func clearOpaqueBackgrounds(in view: NSView) {
        if view is NSControl { return }
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        if let box = view as? NSBox {
            box.boxType = .custom
            box.fillColor = .clear
            box.borderWidth = 0
        }
        for subview in view.subviews {
            clearOpaqueBackgrounds(in: subview)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        // Read the bar's own resolved height — `NSTextFinder` sizes its bar view. Deliberately
        // not `fittingSize`, which forces an Auto Layout pass and can recurse mid-layout.
        let barHeight = controller.findBarView?.frame.height ?? 0
        let height = barHeight > 1 ? barHeight : Self.defaultBarHeight
        return CGSize(width: width, height: height)
    }
}
