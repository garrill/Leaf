import AppKit
import SwiftUI

/// Per-paragraph (i.e. per-`DiffLine`) info needed to paint the row background and gutter
/// numbers — kept entirely out of the text storage itself so none of it is selectable or
/// copyable alongside the code text.
struct DiffLineMetadata {
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let backgroundColor: NSColor?
    /// This line is a hunk's first content line — `HunkSeparatorOverlayView` paints the top
    /// boundary rule at its top edge.
    let isHunkStart: Bool
    /// This line is a hunk's last content line — `HunkSeparatorOverlayView` paints the bottom
    /// boundary rule at its bottom edge.
    let isHunkEnd: Bool
    let kind: DiffLine.Kind
}

/// The code-only text view: trades SwiftUI's per-row `Text` (which gave us full row-width
/// backgrounds and a numbered gutter for free) for a real `NSTextView`, which is what actually
/// gets multi-line drag selection, Cmd-A, and Shift-arrow extension working — SwiftUI's
/// `.textSelection(.enabled)` on a stack of sibling `Text` views never coalesced them into one
/// selectable run here, no matter how the stack was restructured.
///
/// Built explicitly on the legacy TextKit 1 stack (`NSLayoutManager` + `NSTextContainer` wired up
/// by hand) rather than via `NSTextView()`'s default initializer — a default-initialized text view
/// on newer SDKs can come back TextKit 2-backed, where `.layoutManager` is nil and none of the
/// `enumerateLineFragments`/`characterIndexForGlyph` glyph APIs this view and its gutter depend on
/// are available.
///
/// Sized by an explicit `fittingHeight(forWidth:)` rather than `enclosingScrollView`-based
/// resizing — this view is no longer inside its own private `NSScrollView`. It's laid out by
/// `DiffCodeContainerView` and ultimately scrolled by a real SwiftUI `ScrollView`, which is what's
/// needed for `.scrollEdgeEffectStyle` to actually blur content under the diff header (a plain
/// `NSScrollView` wrapped via `NSViewRepresentable` never participates in that SwiftUI-only API).
final class DiffCodeTextView: NSTextView {
    /// Set by `DiffCodeScrollView` so this view can participate in cross-column arrow-key focus
    /// navigation (`AppState.focusedColumn`) as a real AppKit first responder — becoming first
    /// responder (a click, or `DiffCodeScrollView.updateNSView` claiming it on the diff column's
    /// behalf) claims `.diff`; a left-arrow press hands focus back to the files column. Every
    /// other key (up/down, page up/down, home/end, ⌘↑/⌘↓, …) is left to `NSTextView`'s own
    /// standard key bindings, which is the whole point of routing real focus here rather than
    /// hand-rolling scroll behavior in SwiftUI — see `DiffView`'s history for why the hand-rolled
    /// version was abandoned.
    weak var appState: AppState?
    private(set) var lineMetadata: [DiffLineMetadata] = []
    private var paragraphStartOffsets: [Int] = [0]
    /// The body font size last applied via `setContent` — `DiffGutterView` reads this to keep its
    /// line-number font sized proportionally, since the gutter draws independently of the text
    /// view's own attributed string (see the "Diff pane" gotcha in CLAUDE.md).
    private(set) var bodyFontSize: CGFloat = NSFont.systemFontSize

    /// Find-in-diff render state, pushed in by `DiffCodeContainerView.updateSearch`. When
    /// `isSearchActive`, `draw(_:)` fills a rounded rect behind every match, dims everything
    /// outside the matches, and paints the current match a stronger colour with forced-dark text.
    private(set) var isSearchActive = false
    private(set) var searchMatchRanges: [NSRange] = []
    private(set) var searchCurrentMatchIndex = 0
    /// 0→1 progress of the current match's "found" flash, replayed whenever the *range* it points
    /// at changes — a new query, ⌘G/⌘⇧G, or the bar just opening — so it plays once per actual
    /// jump rather than once per keystroke that leaves it in place. The fill fades in over this;
    /// the ~1.2x scale "pop" is a `sin` bump over it, rendered by `DiffSearchDimOverlayView` (on
    /// top of the dim) so the yellow box and text scale together and neither gets dimmed.
    private(set) var searchAnimationProgress: CGFloat = 1
    private var searchAnimationTimer: Timer?
    private var lastAnimatedMatchRange: NSRange?
    private static let searchAnimationDuration: CGFloat = 0.22
    /// Called ~60×/s while the flash animates, so the overlay can redraw the scaled pop in step.
    var onSearchAnimationFrame: (() -> Void)?

    deinit {
        searchAnimationTimer?.invalidate()
    }

    /// Floor for the text container's wrap width. `NSTextContainer` treats a width of 0 (or
    /// close to it) as effectively unbounded — each line lays out as one long fragment instead of
    /// wrapping — so as the diff column is squeezed down to nothing, wrapping would silently stop
    /// instead of degrading gracefully. Clamping to a small positive floor keeps wrapping active
    /// (very tight, single-word-per-line) all the way down, with the excess simply clipped by the
    /// column's own bounds rather than the wrap behavior breaking.
    static let minWrapWidth: CGFloat = 60

    static func makeLegacyTextKit1() -> DiffCodeTextView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 4
        layoutManager.addTextContainer(container)
        return DiffCodeTextView(frame: .zero, textContainer: container)
    }

    func setContent(attributedString: NSAttributedString, metadata: [DiffLineMetadata], bodyFontSize: CGFloat) {
        lineMetadata = metadata
        self.bodyFontSize = bodyFontSize
        textStorage?.setAttributedString(attributedString)
        recomputeParagraphOffsets()
        needsDisplay = true
    }

    /// The height needed to lay out the full document at a given width — used by
    /// `DiffCodeContainerView`/`DiffCodeScrollView.sizeThatFits` to report this view's real
    /// intrinsic content size to the enclosing SwiftUI `ScrollView`.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        textContainer.containerSize = NSSize(width: max(width, Self.minWrapWidth), height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2
    }

    override func layout() {
        super.layout()
        // Keep the text container tracking this view's actual assigned frame width, in case it
        // differs slightly (rounding) from whatever width `fittingHeight(forWidth:)` last saw.
        textContainer?.containerSize = NSSize(width: max(bounds.width, Self.minWrapWidth), height: .greatestFiniteMagnitude)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            appState?.focusedColumn = .diff
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 { // Left arrow — hand focus back to the files column.
            appState?.focusedColumn = .files
            return
        }
        super.keyDown(with: event)
    }

    private func recomputeParagraphOffsets() {
        var offsets: [Int] = [0]
        let text = string as NSString
        var searchLocation = 0
        while searchLocation < text.length {
            let range = text.range(of: "\n", range: NSRange(location: searchLocation, length: text.length - searchLocation))
            guard range.location != NSNotFound else { break }
            offsets.append(range.location + 1)
            searchLocation = range.location + 1
        }
        paragraphStartOffsets = offsets
    }

    /// Index into `lineMetadata` (and the original `DiffLine` array) for a character offset into `string`.
    func paragraphIndex(forCharacterIndex index: Int) -> Int {
        var low = 0
        var high = paragraphStartOffsets.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if paragraphStartOffsets[mid] <= index {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// Character index (exclusive) at the end of the paragraph at `paragraphIndex` — right before
    /// its trailing newline, or the end of the document for the last paragraph. Lets
    /// `HunkSeparatorOverlayView` tell whether a given wrapped line fragment is the true last
    /// fragment of a paragraph, so a hunk-end boundary rule lands at the real bottom edge even
    /// when that last line wraps onto multiple rows.
    func paragraphEndCharacterIndex(for paragraphIndex: Int) -> Int {
        if paragraphIndex + 1 < paragraphStartOffsets.count {
            return paragraphStartOffsets[paragraphIndex + 1] - 1
        }
        return (string as NSString).length
    }

    /// True when the fragment starting at `charIndex` is the first wrapped fragment of its
    /// paragraph (as opposed to a continuation row of a long, wrapped line).
    func isFirstFragmentOfParagraph(charIndex: Int) -> Bool {
        charIndex == 0 || (string as NSString).character(at: charIndex - 1) == 10
    }

    /// `NSLayoutManager` bakes a paragraph's `paragraphSpacingBefore` into the *top* of its first
    /// line fragment's rect — see `HunkSeparatorOverlayView` — so the raw fragment rect for a
    /// hunk's first line spans the blank gap above it as well as the line itself. Every caller that
    /// fills or measures "this row" (row backgrounds, the gutter's number centering, its vertical
    /// border lines) needs the gap excluded, or their fill/centering bleeds upward into it — this
    /// is the one place that correction is made.
    func rowRect(for fragRect: NSRect, paragraphIndex: Int, isFirstFragmentOfParagraph: Bool) -> NSRect {
        guard isFirstFragmentOfParagraph,
              paragraphIndex > 0,
              paragraphIndex < lineMetadata.count,
              lineMetadata[paragraphIndex].isHunkStart else { return fragRect }
        var rect = fragRect
        rect.origin.y += HunkSeparatorOverlayView.gapHeight
        rect.size.height -= HunkSeparatorOverlayView.gapHeight
        return rect
    }

    /// Paints each line's background edge-to-edge before the glyphs draw. `NSAttributedString`'s
    /// `.backgroundColor` attribute alone only fills the glyph run's own advance width, which would
    /// leave short added/removed lines with a background that stops short of the trailing edge
    /// instead of spanning the full row the way the old SwiftUI `Text` rows did.
    override func draw(_ dirtyRect: NSRect) {
        if let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 {
            // Padded past the dirty rect's own edges for the same reason as `DiffGutterView.draw`
            // and `HunkSeparatorOverlayView.draw` — a hunk-start line's raw fragment rect extends
            // above its visible row by the hunk-gap height, so a tight search rect can
            // inconsistently miss that fragment depending on rounding, leaving its background
            // unpainted on a partial (scroll-driven) redraw even though a full-bounds redraw
            // (e.g. from resizing the window) always finds it.
            let padding = HunkSeparatorOverlayView.gapHeight
            let searchRect = NSRect(
                x: 0,
                y: dirtyRect.minY - padding,
                width: bounds.width,
                height: dirtyRect.height + padding * 2
            )
            let glyphRange = layoutManager.glyphRange(forBoundingRect: searchRect, in: textContainer)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
                guard fragGlyphRange.location < layoutManager.numberOfGlyphs else { return }
                let charIndex = layoutManager.characterIndexForGlyph(at: fragGlyphRange.location)
                let paragraphIndex = self.paragraphIndex(forCharacterIndex: charIndex)
                guard paragraphIndex < self.lineMetadata.count,
                      let color = self.lineMetadata[paragraphIndex].backgroundColor else { return }

                let isFirstFragment = self.isFirstFragmentOfParagraph(charIndex: charIndex)
                let rowRect = self.rowRect(for: fragRect, paragraphIndex: paragraphIndex, isFirstFragmentOfParagraph: isFirstFragment)

                var fillRect = rowRect
                fillRect.origin.x = 0
                fillRect.size.width = max(self.bounds.width, rowRect.maxX)
                fillRect.origin.y += self.textContainerOrigin.y

                color.setFill()
                fillRect.fill()
            }
        }

        // Only the current match's settled fill is drawn here (behind the glyphs). The dim +
        // non-current outlines + the scale "pop" are a separate top-most overlay
        // (`DiffSearchDimOverlayView`) spanning the gutter too, so there's no seam at the
        // gutter/text boundary and the pop is never dimmed.
        drawSearchMatchFills(dirtyRect)
        super.draw(dirtyRect)
    }

    /// The strong rounded fill behind the *current* match, at rest — painted before the glyphs so
    /// the (forced-dark) text sits on top of it. Fades in over `searchAnimationProgress`. During
    /// the pop this is hidden under the overlay's scaled copy; once settled it's what shows.
    private func drawSearchMatchFills(_ dirtyRect: NSRect) {
        guard isSearchActive, searchMatchRanges.indices.contains(searchCurrentMatchIndex) else { return }
        let eased = Self.easeOut(searchAnimationProgress)
        DiffView.searchCurrentMatchNSColor.withAlphaComponent(DiffView.searchCurrentMatchNSColor.alphaComponent * eased).setFill()
        for rect in searchMatchBoundingRects(for: searchMatchRanges[searchCurrentMatchIndex]) where rect.intersects(dirtyRect) {
            NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -2), xRadius: 4, yRadius: 4).fill()
        }
    }

    static func easeOut(_ t: CGFloat) -> CGFloat {
        1 - pow(1 - t, 3)
    }

    /// Restarts the "found" flash from scratch. ~60Hz fixed-step timer rather than a display-link
    /// or `CACurrentMediaTime` — simple, and more than smooth enough for a 0.22s fade.
    private func startSearchAnimation() {
        searchAnimationTimer?.invalidate()
        searchAnimationProgress = 0
        let interval: CGFloat = 1.0 / 60.0
        let step = interval / Self.searchAnimationDuration
        let timer = Timer(timeInterval: TimeInterval(interval), repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.searchAnimationProgress = min(1, self.searchAnimationProgress + step)
            self.needsDisplay = true
            self.onSearchAnimationFrame?()
            if self.searchAnimationProgress >= 1 {
                timer.invalidate()
                self.searchAnimationTimer = nil
            }
        }
        searchAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Bounding rects (this view's coords) for every match whose text is within `band`, tagged
    /// with whether it's the current one. Used by `DiffSearchDimOverlayView`.
    func visibleSearchMatchRects(in band: NSRect) -> [(isCurrent: Bool, rects: [NSRect])] {
        guard isSearchActive, !searchMatchRanges.isEmpty, let layoutManager, let textContainer else { return [] }
        let padded = band.insetBy(dx: 0, dy: -HunkSeparatorOverlayView.gapHeight)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: padded, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let stringLength = (string as NSString).length
        var result: [(Bool, [NSRect])] = []
        for (index, range) in searchMatchRanges.enumerated() {
            guard NSMaxRange(range) <= stringLength else { continue }
            let onScreen = NSIntersectionRange(range, charRange).length > 0 || range.location == NSMaxRange(charRange)
            guard onScreen else { continue }
            let rects = searchMatchBoundingRects(for: range).filter { $0.intersects(band) }
            if !rects.isEmpty { result.append((index == searchCurrentMatchIndex, rects)) }
        }
        return result
    }
}

/// Collapses any intersecting rects into their bounding union, iterating to a fixed point — so
/// two adjacent matches whose inflated rects overlap punch one disjoint hole in the dim's
/// even-odd clip instead of re-darkening the overlap.
func diffSearchMergedRects(_ rects: [NSRect]) -> [NSRect] {
    var result: [NSRect] = []
    for rect in rects {
        var union = rect
        var index = 0
        while index < result.count {
            if result[index].intersects(union) {
                union = result[index].union(union)
                result.remove(at: index)
                index = 0
            } else {
                index += 1
            }
        }
        result.append(union)
    }
    return result
}

/// Top-most overlay across the whole `DiffCodeContainerView` (gutter + code), so the find-in-diff
/// dim is one continuous surface with no seam at the gutter/text boundary. Darkens everything
/// except the matches (light mode only — `searchDimNSColor` is clear in dark), and outlines the
/// non-current matches. The *current* match's fill is still drawn behind the glyphs in
/// `DiffCodeTextView` so its text stays on top.
final class DiffSearchDimOverlayView: NSView {
    weak var codeTextView: DiffCodeTextView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = codeTextView,
              textView.isSearchActive,
              !textView.searchMatchRanges.isEmpty else { return }

        // Match rects come from the text view; shift into overlay (== container) coords.
        let offsetX = DiffGutterView.totalWidth
        let bandInTextView = dirtyRect.offsetBy(dx: -offsetX, dy: 0)
        let matches = textView.visibleSearchMatchRects(in: bandInTextView)

        var holes: [NSRect] = []
        for (_, rects) in matches {
            for rect in rects {
                holes.append(rect.offsetBy(dx: offsetX, dy: 0).insetBy(dx: -2, dy: -1))
            }
        }
        holes = diffSearchMergedRects(holes)

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if !isDark {
            let band = NSRect(x: 0, y: dirtyRect.minY, width: bounds.width, height: dirtyRect.height)
            let scrim = NSBezierPath(rect: band)
            for hole in holes {
                scrim.append(NSBezierPath(roundedRect: hole, xRadius: 4, yRadius: 4))
            }
            scrim.windingRule = .evenOdd
            NSGraphicsContext.saveGraphicsState()
            scrim.addClip()
            DiffView.searchDimNSColor.setFill()
            band.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        DiffView.searchMatchOutlineNSColor.setStroke()
        for (isCurrent, rects) in matches where !isCurrent {
            for rect in rects {
                let outline = NSBezierPath(roundedRect: rect.offsetBy(dx: offsetX, dy: 0).insetBy(dx: -1.5, dy: -0.5), xRadius: 3.5, yRadius: 3.5)
                outline.lineWidth = 1
                outline.stroke()
            }
        }

        drawCurrentMatchPop(textView: textView, offsetX: offsetX, dirtyRect: dirtyRect)
    }

    /// The "found" pop: the current match's yellow box + glyphs, redrawn here (on top of the dim)
    /// as one unit scaled ~1.2x→1x around its centre. The opaque fill covers the settled 1x copy
    /// underneath, so there's no ghosted original text. Skipped once settled and for the rare
    /// wrapped match.
    private func drawCurrentMatchPop(textView: DiffCodeTextView, offsetX: CGFloat, dirtyRect: NSRect) {
        guard textView.searchAnimationProgress < 1,
              textView.searchMatchRanges.indices.contains(textView.searchCurrentMatchIndex),
              let layoutManager = textView.layoutManager else { return }
        let pop = sin(min(textView.searchAnimationProgress, 1) * .pi)
        guard pop > 0.01 else { return }
        let scale = 1 + 0.2 * pop

        let range = textView.searchMatchRanges[textView.searchCurrentMatchIndex]
        let rects = textView.searchMatchBoundingRects(for: range)
        guard rects.count == 1, let base = rects.first else { return }
        let rect = base.offsetBy(dx: offsetX, dy: 0)
        guard rect.insetBy(dx: -rect.width * 0.25, dy: -rect.height * 0.25).intersects(dirtyRect) else { return }

        let center = NSPoint(x: rect.midX, y: rect.midY)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let glyphOrigin = NSPoint(x: textView.textContainerOrigin.x + offsetX, y: textView.textContainerOrigin.y)

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.scale(by: scale)
        transform.translateX(by: -center.x, yBy: -center.y)
        transform.concat()

        DiffView.searchCurrentMatchNSColor.withAlphaComponent(1).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -2), xRadius: 4, yRadius: 4).fill()
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: glyphOrigin)

        NSGraphicsContext.restoreGraphicsState()
    }
}

extension DiffCodeTextView {
    /// Push new find-in-diff state (dedupe happens one level up, in `updateSearch`). Returns
    /// whether a match is available to scroll to.
    @discardableResult
    func applySearch(active: Bool, matchRanges: [NSRange], currentIndex: Int) -> Bool {
        isSearchActive = active
        searchMatchRanges = matchRanges
        searchCurrentMatchIndex = currentIndex
        refreshCurrentMatchTextColor()

        // Replay the "found" flash only when the current match's actual range changed — a new
        // query, ⌘G/⌘⇧G, or the bar just opening — not on every keystroke that happens to leave
        // it pointing at the same spot.
        let currentRange = matchRanges.indices.contains(currentIndex) ? matchRanges[currentIndex] : nil
        if active, let currentRange {
            if currentRange != lastAnimatedMatchRange {
                lastAnimatedMatchRange = currentRange
                startSearchAnimation()
            }
        } else {
            lastAnimatedMatchRange = nil
            searchAnimationTimer?.invalidate()
            searchAnimationTimer = nil
            searchAnimationProgress = 1
        }

        needsDisplay = true
        return active && !matchRanges.isEmpty
    }

    /// Forces the current match's glyphs to a fixed dark colour (layout-manager temporary
    /// attribute, so the permanent syntax/diff colours are untouched) — otherwise pale label text
    /// on the strong yellow fill is unreadable.
    private func refreshCurrentMatchTextColor() {
        guard let layoutManager else { return }
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        guard isSearchActive, searchMatchRanges.indices.contains(searchCurrentMatchIndex) else { return }
        let range = searchMatchRanges[searchCurrentMatchIndex]
        guard NSMaxRange(range) <= fullRange.length else { return }
        layoutManager.addTemporaryAttribute(.foregroundColor, value: DiffView.searchCurrentMatchTextNSColor, forCharacterRange: range)
    }

    /// Enclosing rects for a character range, in this view's coordinates (offset by the text
    /// container origin). More than one when the match wraps a line.
    func searchMatchBoundingRects(for range: NSRange) -> [NSRect] {
        guard let layoutManager, let textContainer else { return [] }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = textContainerOrigin
        var rects: [NSRect] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { rect, _ in
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return rects
    }
}

/// Dual old/new line-number gutter, drawn in its own plain `NSView` to the left of the code text
/// view — entirely outside the text view's own bounds and text storage, exactly like Xcode's or
/// BBEdit's gutters, so numbers can never get swept into a text selection or a copy. Previously
/// this was an `NSRulerView` hosted by a private `NSScrollView`; now that the code view is laid
/// out and scrolled by a real SwiftUI `ScrollView` (see `DiffCodeContainerView`), there's no
/// `NSScrollView` for an `NSRulerView` to attach to, so it draws directly off the text view's
/// `NSLayoutManager` instead of the ruler's coordinate-transform APIs.
final class DiffGutterView: NSView {
    weak var codeTextView: DiffCodeTextView?

    /// Scaled off the code text's own body font size (`Settings` → diff font size) rather than a
    /// fixed constant, so the two stay proportional however the user resizes the body text —
    /// matching the ~2pt gap between `NSFont.systemFontSize`/`.smallSystemFontSize` this replaced.
    private var numberFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: max(9, (codeTextView?.bodyFontSize ?? NSFont.systemFontSize) - 2), weight: .regular)
    }
    private static let leadingPadding: CGFloat = 4
    private static let columnWidth: CGFloat = 36
    private static let columnGap: CGFloat = 8
    private static let trailingPadding: CGFloat = 8

    private static let oldColumnX: CGFloat = leadingPadding
    private static let newColumnX: CGFloat = leadingPadding + columnWidth + columnGap
    /// Vertical border between the old/new number columns, centered in the gap between them.
    private static let middleBorderX: CGFloat = oldColumnX + columnWidth + columnGap / 2
    /// Vertical border separating the gutter from the code text view, centered in the gap after
    /// the new-number column (rather than flush against it) so it doesn't crowd either side.
    private static let rightBorderX: CGFloat = newColumnX + columnWidth + trailingPadding / 2
    /// Total gutter width — shared with `DiffCodeContainerView.layout()`, which must reserve this
    /// much space to the left of the code text view.
    static let totalWidth: CGFloat = newColumnX + columnWidth + trailingPadding

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = codeTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              layoutManager.numberOfGlyphs > 0 else { return }

        // This view only ever positively paints a background for added/removed rows — a context
        // row's background is just whatever was already there. Without an explicit clear, a number
        // (or added/removed tint) drawn at one position can leave ghost pixels behind if a later
        // partial redraw repaints that row slightly differently (e.g. AppKit invalidating only part
        // of a row that shifted after a content update) without also touching the old pixels.
        DiffView.paneBackgroundNSColor.setFill()
        dirtyRect.fill()

        // The gutter and text view share the same y-origin and flip (both are non-scrolling
        // siblings inside `DiffCodeContainerView`), so the dirty rect's y-range maps directly onto
        // the text view's own coordinate space without any scroll-offset translation. Padded well
        // past the dirty rect's own edges: a hunk-start line's raw fragment rect extends above its
        // visible row by the hunk-gap height (see `DiffCodeTextView.rowRect`), so a search rect that
        // stops exactly at the dirty rect's edge can inconsistently include/exclude that fragment
        // depending on rounding — occasionally dropping that row's numbers or border segment on a
        // partial (scroll-driven) redraw, even though a full-bounds redraw always finds it.
        let padding = HunkSeparatorOverlayView.gapHeight
        let searchRect = NSRect(
            x: 0,
            y: dirtyRect.minY - padding,
            width: textView.bounds.width,
            height: dirtyRect.height + padding * 2
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: searchRect, in: container)

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
            guard fragGlyphRange.location < layoutManager.numberOfGlyphs else { return }
            let charIndex = layoutManager.characterIndexForGlyph(at: fragGlyphRange.location)

            let paragraphIndex = textView.paragraphIndex(forCharacterIndex: charIndex)
            guard paragraphIndex < textView.lineMetadata.count else { return }
            let meta = textView.lineMetadata[paragraphIndex]

            // Excludes any hunk-gap spacing baked into the top of this fragment's rect (see
            // `DiffCodeTextView.rowRect`), so the background tint, numbers, and border segment
            // below all stay confined to the actual row and don't bleed into the blank gap.
            let isFirstFragmentOfParagraph = textView.isFirstFragmentOfParagraph(charIndex: charIndex)
            var lineRect = textView.rowRect(for: fragRect, paragraphIndex: paragraphIndex, isFirstFragmentOfParagraph: isFirstFragmentOfParagraph)
            lineRect.origin.y += textView.textContainerOrigin.y

            // Full-row background tint, matching the code side's own row background — added/
            // removed is conveyed by the whole gutter row, not just the number's text color. Every
            // wrapped fragment of a paragraph gets tinted, not just the first, or a multi-line-wrap
            // change would leave the gutter unpainted alongside its own continuation rows.
            if let color = meta.backgroundColor {
                var fillRect = lineRect
                fillRect.origin.x = 0
                fillRect.size.width = self.bounds.width
                color.setFill()
                fillRect.fill()
            }

            // Only the first wrapped fragment of a paragraph carries its line numbers.
            guard isFirstFragmentOfParagraph else { return }

            self.drawNumber(meta.oldLineNumber, x: Self.oldColumnX, width: Self.columnWidth, rowRect: lineRect)
            self.drawNumber(meta.newLineNumber, x: Self.newColumnX, width: Self.columnWidth, rowRect: lineRect)
        }

        // Two vertical borders — between the old/new columns, and between the gutter and the code
        // text — drawn per line fragment (rather than as one solid line for the whole visible
        // range) so each row's border segment can take on that row's added/removed color instead
        // of a uniform separator color throughout.
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
            guard fragGlyphRange.location < layoutManager.numberOfGlyphs else { return }
            let charIndex = layoutManager.characterIndexForGlyph(at: fragGlyphRange.location)
            let paragraphIndex = textView.paragraphIndex(forCharacterIndex: charIndex)
            guard paragraphIndex < textView.lineMetadata.count else { return }
            let meta = textView.lineMetadata[paragraphIndex]

            // Same gap exclusion as above — otherwise these border segments run straight through
            // the blank space between hunks, crossing the horizontal boundary rules drawn there.
            let isFirstFragmentOfParagraph = textView.isFirstFragmentOfParagraph(charIndex: charIndex)
            var lineRect = textView.rowRect(for: fragRect, paragraphIndex: paragraphIndex, isFirstFragmentOfParagraph: isFirstFragmentOfParagraph)
            lineRect.origin.y += textView.textContainerOrigin.y

            let borderColor = DiffView.borderNSColor(for: meta.kind)
            borderColor.setFill()
            NSRect(x: Self.middleBorderX, y: lineRect.minY, width: 1, height: lineRect.height).fill()
            NSRect(x: Self.rightBorderX, y: lineRect.minY, width: 1, height: lineRect.height).fill()
        }
    }

    private func drawNumber(_ number: Int?, x: CGFloat, width: CGFloat, rowRect: NSRect) {
        guard let number else { return }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let attributed = NSAttributedString(string: "\(number)", attributes: [
            .font: numberFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ])
        let size = attributed.size()
        let drawRect = NSRect(
            x: x,
            y: rowRect.minY + (rowRect.height - size.height) / 2,
            width: width,
            height: size.height
        )
        attributed.draw(in: drawRect)
    }
}

/// Draws the plain top/bottom boundary rules around each hunk, replacing the old `@@ ... @@`
/// header row. Lives in its own overlay `NSView` stacked on top of both the gutter and the code
/// text view — neither of those views' own bounds span the full panel width the rule needs to
/// cross (from the gutter's far-left edge to the code side's far-right edge) — and never accepts
/// hits, so it can't intercept clicks/selection meant for the text view underneath.
final class HunkSeparatorOverlayView: NSView {
    weak var codeTextView: DiffCodeTextView?

    /// Must match `DiffCodeScrollView.hunkGapHeight` — the space between hunks. `NSLayoutManager`
    /// bakes a paragraph's `paragraphSpacingBefore` into the *top* of its line fragment rect (in
    /// this flipped view, its smaller-y edge), so the fragment's reported `minY` lands at the
    /// start of the gap, not after it — the top rule has to be pushed down by this amount to land
    /// at the actual glyph top, past the gap, instead of directly on top of the previous hunk's
    /// bottom rule.
    static let gapHeight: CGFloat = DiffCodeScrollView.hunkGapHeight

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = codeTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              layoutManager.numberOfGlyphs > 0 else { return }

        // Padded past the dirty rect's own edges for the same reason as `DiffGutterView.draw` — a
        // hunk-start line's raw fragment rect extends above its visible row by the gap height, so a
        // tight search rect can inconsistently miss a boundary rule depending on rounding, which
        // otherwise only a full-bounds redraw (e.g. from resizing the window) reliably catches.
        let padding = Self.gapHeight
        let searchRect = NSRect(
            x: 0,
            y: dirtyRect.minY - padding,
            width: textView.bounds.width,
            height: dirtyRect.height + padding * 2
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: searchRect, in: container)
        let text = textView.string as NSString

        NSColor.separatorColor.setFill()

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
            guard fragGlyphRange.location < layoutManager.numberOfGlyphs else { return }
            let charRange = layoutManager.characterRange(forGlyphRange: fragGlyphRange, actualGlyphRange: nil)
            let paragraphIndex = textView.paragraphIndex(forCharacterIndex: charRange.location)
            guard paragraphIndex < textView.lineMetadata.count else { return }
            let meta = textView.lineMetadata[paragraphIndex]
            guard meta.isHunkStart || meta.isHunkEnd else { return }

            var lineRect = fragRect
            lineRect.origin.y += textView.textContainerOrigin.y

            // Only the first wrapped fragment of a paragraph carries the top rule, and only the
            // last carries the bottom rule, so a wrapped line doesn't get a rule through its middle.
            if meta.isHunkStart {
                let isFirstFragment = charRange.location == 0 || text.character(at: charRange.location - 1) == 10
                if isFirstFragment {
                    // The very first paragraph in the document has no gap before it (nothing to
                    // separate from), so its fragment rect's top is the real glyph top already.
                    let topY = paragraphIndex == 0 ? lineRect.minY : lineRect.minY + Self.gapHeight
                    NSRect(x: 0, y: topY, width: self.bounds.width, height: 1).fill()
                }
            }
            if meta.isHunkEnd {
                let paragraphEnd = textView.paragraphEndCharacterIndex(for: paragraphIndex)
                if charRange.location + charRange.length >= paragraphEnd {
                    NSRect(x: 0, y: lineRect.maxY - 1, width: self.bounds.width, height: 1).fill()
                }
            }
        }
    }
}

/// Hosts the gutter and code text view as plain (non-scrolling) sibling subviews, laid out
/// side-by-side and sized to fit their full content — the whole thing is scrolled by a real
/// SwiftUI `ScrollView` one level up, not by an internal `NSScrollView`.
final class DiffCodeContainerView: NSView {
    let textView = DiffCodeTextView.makeLegacyTextKit1()
    let gutterView = DiffGutterView()
    let hunkSeparatorView = HunkSeparatorOverlayView()
    let searchDimOverlay = DiffSearchDimOverlayView()
    /// What `setContent` last actually applied — `DiffCodeScrollView.updateNSView` runs on
    /// *every* SwiftUI update of this view (scroll position changes, hover state, unrelated
    /// parent re-renders, etc.), not just ones where the diff itself changed. Without this,
    /// every such call rebuilt the full attributed string and re-ran text layout from scratch
    /// (confirmed via Instruments: ~200ms combined for `buildContent`/`setContent`/
    /// `fittingHeight` on a single unrelated re-render) even when nothing about the diff had.
    private var lastContentKey: DiffContentKey?
    /// The file/source last seen by `resetScrollIfSelectionChanged` — deliberately a separate key
    /// from `lastContentKey`: content also changes (a new `DiffContentKey`) when syntax
    /// highlighting finishes arriving late for the *same* file, which must not reset scroll
    /// position out from under someone already reading further down.
    private var lastSelectionKey: DiffSelectionKey?
    /// What `updateSearch` last pushed, so an unrelated `updateNSView` doesn't re-scroll to the
    /// current match.
    private var lastSearchKey: DiffSearchRenderKey?

    override init(frame: NSRect) {
        super.init(frame: frame)
        gutterView.codeTextView = textView
        hunkSeparatorView.codeTextView = textView
        searchDimOverlay.codeTextView = textView
        // Redraw the overlay's scaled "pop" in step with the text view's flash timer.
        textView.onSearchAnimationFrame = { [weak searchDimOverlay] in searchDimOverlay?.needsDisplay = true }
        addSubview(gutterView)
        addSubview(textView)
        addSubview(hunkSeparatorView)
        addSubview(searchDimOverlay)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let gutterWidth = DiffGutterView.totalWidth
        gutterView.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        let textWidth = max(bounds.width - gutterWidth, 0)
        textView.frame = NSRect(x: gutterWidth, y: 0, width: textWidth, height: bounds.height)
        hunkSeparatorView.frame = bounds
        searchDimOverlay.frame = bounds
    }

    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        textView.fittingHeight(forWidth: max(width - DiffGutterView.totalWidth, 0))
    }

    /// True when `key` differs from what's already applied — callers should skip building the
    /// (expensive) attributed string at all when this is false, not just skip `setContent`.
    func needsContentUpdate(for key: DiffContentKey) -> Bool {
        key != lastContentKey
    }

    func setContent(attributedString: NSAttributedString, metadata: [DiffLineMetadata], key: DiffContentKey) {
        lastContentKey = key
        textView.setContent(attributedString: attributedString, metadata: metadata, bodyFontSize: key.fontSize)
        needsLayout = true
        gutterView.needsDisplay = true
        hunkSeparatorView.needsDisplay = true
        searchDimOverlay.needsDisplay = true
        // Text storage was replaced — the current-match temporary attribute is gone; re-push
        // whatever search state we hold onto the fresh content.
        lastSearchKey = nil
    }

    /// Push find-in-diff state to the text view and scroll the current match into view when it
    /// (or the match set / active flag) changed. A `nil` `lastSearchKey` (just after `setContent`
    /// replaced the text) forces a re-apply but suppresses the scroll — the fresh file is already
    /// parked at the top by `resetScrollIfSelectionChanged`.
    func updateSearch(active: Bool, matchRanges: [NSRange], currentIndex: Int) {
        let key = DiffSearchRenderKey(active: active, matchRanges: matchRanges, currentIndex: currentIndex)
        let forced = lastSearchKey == nil
        guard forced || key != lastSearchKey else { return }
        lastSearchKey = key
        let shouldScroll = textView.applySearch(active: active, matchRanges: matchRanges, currentIndex: currentIndex)
        gutterView.needsDisplay = true
        searchDimOverlay.needsDisplay = true
        if !forced, shouldScroll, matchRanges.indices.contains(currentIndex) {
            textView.scrollRangeToVisible(matchRanges[currentIndex])
        }
    }

    /// Selecting a different file (or the same file under a different commit/source) resets
    /// scroll to the top — switching files only swaps the text content, which otherwise leaves
    /// whatever scroll offset the previous file was left at.
    func resetScrollIfSelectionChanged(_ key: DiffSelectionKey) {
        guard key != lastSelectionKey else { return }
        lastSelectionKey = key
        textView.scrollToBeginningOfDocument(nil)
    }
}

/// Identifies which file/source is currently selected, independent of `DiffContentKey` (which
/// identifies what's currently *painted* — see `DiffCodeContainerView.lastSelectionKey`'s doc
/// comment for why the two can't be the same key).
struct DiffSelectionKey: Equatable {
    let filePath: String?
    let source: ChangeSource?
}

/// What `DiffCodeContainerView.updateSearch` last applied — lets an unrelated `updateNSView`
/// (scroll, hover, parent re-render) skip re-pushing identical search state and re-scrolling.
private struct DiffSearchRenderKey: Equatable {
    let active: Bool
    let matchRanges: [NSRange]
    let currentIndex: Int
}

/// Identifies what's currently painted in a `DiffCodeContainerView` well enough to know when a
/// rebuild can be skipped, without needing `HighlightSnapshot`'s `[Int: AttributedString]` (not
/// cheaply equatable) to be `Equatable` itself. Uses the snapshot's own identity rather than its
/// line count — `DiffView.refreshHighlighting()` always produces a brand-new `HighlightSnapshot`
/// (a new `id`) each time it runs, including when only the color scheme changed and the diff text
/// and line count are otherwise identical, so an identity-based key repaints in that case where a
/// line-count-based one would not.
///
/// `lineCount` is included alongside `diffText` because `DiffView`'s parsed `diffLines` (passed
/// in as `DiffCodeScrollView.lines`) is cached separately, updated via its own `.onChange`, and
/// can momentarily lag a render pass behind `diffText` itself changing (each async diff load
/// lands as its own transaction). Without this, the very first `updateContent` after selecting a
/// new file could bake in a stale/empty `lines` (same `diffText` as what's about to arrive), and
/// the later call carrying the now-correct `lines` would look unchanged by `diffText` alone and
/// get skipped — leaving the pane blank until something else (any key field changing) forced a
/// rebuild. With syntax highlighting on, a fresh `HighlightSnapshot` arriving shortly after always
/// provided that forcing nudge, which is what masked this; with it off, nothing ever did.
struct DiffContentKey: Equatable {
    let diffText: String
    let lineCount: Int
    let highlightSnapshotID: UUID?
    let fontSize: CGFloat
}

/// SwiftUI bridge for the gutter/text-view pair above. Builds the per-line `NSAttributedString`
/// and background/gutter metadata from the already-parsed diff lines and (once ready) the
/// syntax-highlighted pieces computed by `DiffView`. Reports its own intrinsic size via
/// `sizeThatFits` so it can be scrolled by a real SwiftUI `ScrollView` (see `DiffView.content`)
/// instead of owning a private `NSScrollView`.
struct DiffCodeScrollView: NSViewRepresentable {
    @Bindable var appState: AppState
    let lines: [DiffLine]
    let highlightSnapshot: HighlightSnapshot?
    let diffText: String
    var fontSize: CGFloat = NSFont.systemFontSize
    /// Find-in-diff render state (see `DiffSearchBar` / `AppState.diffFind*` / `DiffView`). The
    /// ranges are character offsets into the rendered text, which is exactly
    /// `lines.map(\.displayText).joined("\n")`.
    var searchActive = false
    var searchMatchRanges: [NSRange] = []
    var searchCurrentIndex = 0

    /// The gap painted between consecutive hunks — shared with `HunkSeparatorOverlayView`, which
    /// has to correct for this same amount when locating a hunk's top boundary rule.
    static let hunkGapHeight: CGFloat = 20

    func makeNSView(context: Context) -> DiffCodeContainerView {
        let container = DiffCodeContainerView(frame: .zero)
        container.textView.appState = appState
        configure(textView: container.textView)
        updateContent(container: container)
        container.updateSearch(active: searchActive, matchRanges: searchMatchRanges, currentIndex: searchCurrentIndex)
        container.resetScrollIfSelectionChanged(DiffSelectionKey(filePath: appState.selectedFile?.path, source: appState.selectedSource))
        return container
    }

    func updateNSView(_ container: DiffCodeContainerView, context: Context) {
        container.textView.appState = appState
        updateContent(container: container)
        container.updateSearch(active: searchActive, matchRanges: searchMatchRanges, currentIndex: searchCurrentIndex)
        container.resetScrollIfSelectionChanged(DiffSelectionKey(filePath: appState.selectedFile?.path, source: appState.selectedSource))

        // Cross-column arrow-key navigation landed here from another column (`focusedColumn ==
        // .diff`) — claim real AppKit keyboard focus to match, the same way
        // `SidebarViewController.handleStateChange` does for the repos column. Skipped while the
        // find bar is up: this runs on every unrelated `updateNSView` (e.g. the per-keystroke
        // match rescan), and would otherwise yank first responder off the search field on each key.
        if appState.focusedColumn == .diff, !appState.diffFindBarVisible,
           container.textView.window?.firstResponder !== container.textView {
            container.textView.window?.makeFirstResponder(container.textView)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DiffCodeContainerView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        let height = nsView.fittingHeight(forWidth: width)
        return CGSize(width: width, height: height)
    }

    private func configure(textView: DiffCodeTextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
    }

    private func updateContent(container: DiffCodeContainerView) {
        let key = DiffContentKey(diffText: diffText, lineCount: lines.count, highlightSnapshotID: highlightSnapshot?.id, fontSize: fontSize)
        guard container.needsContentUpdate(for: key) else { return }
        let (attributed, metadata) = Self.buildContent(lines: lines, highlightSnapshot: highlightSnapshot, diffText: diffText, fontSize: fontSize)
        container.setContent(attributedString: attributed, metadata: metadata, key: key)
    }

    private static func buildContent(
        lines: [DiffLine],
        highlightSnapshot: HighlightSnapshot?,
        diffText: String,
        fontSize: CGFloat
    ) -> (NSAttributedString, [DiffLineMetadata]) {
        let bodyFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Applied to every line so row height — which the gutter and its background/border fills
        // read straight off the layout manager's line fragments — grows along with it everywhere.
        let lineParagraphStyle = NSMutableParagraphStyle()
        lineParagraphStyle.lineHeightMultiple = 1.3
        // Same, but with extra space before the paragraph — applied only to a hunk's first line
        // (other than the file's very first line) so consecutive hunks read as visually separate
        // blocks instead of one continuous run, now that there's no `@@ ... @@` header row between
        // them to do that job.
        let hunkGapParagraphStyle = NSMutableParagraphStyle()
        hunkGapParagraphStyle.lineHeightMultiple = 1.3
        hunkGapParagraphStyle.paragraphSpacingBefore = hunkGapHeight
        // Only trust the snapshot if it was computed for this exact diff text — a still-running
        // (or superseded) highlight task must never paint stale colors onto newly-selected text.
        let validSnapshot = highlightSnapshot?.diffText == diffText ? highlightSnapshot : nil

        let result = NSMutableAttributedString()
        var metadata: [DiffLineMetadata] = []
        metadata.reserveCapacity(lines.count)
        let wordDiffRanges = Self.wordDiffRanges(for: lines)

        for (index, line) in lines.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }

            let piece = NSMutableAttributedString(string: line.displayText)
            let fullRange = NSRange(location: 0, length: piece.length)
            piece.addAttribute(.font, value: bodyFont, range: fullRange)
            piece.addAttribute(.foregroundColor, value: DiffView.foregroundNSColor(for: line.kind), range: fullRange)
            let paragraphStyle = (line.isHunkStart && index > 0) ? hunkGapParagraphStyle : lineParagraphStyle
            piece.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

            // hljs only assigns explicit colors to tokens it recognizes; overlay just those runs
            // on top of the kind-based default so unclassified characters keep the fallback color.
            if let highlighted = validSnapshot?.lines[line.id] {
                let highlightedNS = NSAttributedString(highlighted)
                highlightedNS.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: highlightedNS.length)) { value, range, _ in
                    guard let value, range.location + range.length <= piece.length else { return }
                    piece.addAttribute(.foregroundColor, value: value, range: range)
                }
            }

            // The stronger "word diff" highlight — the sub-range that actually differs from this
            // line's paired counterpart — layered on top of everything else, last, so it always wins.
            if let strongColor = DiffView.strongBackgroundNSColor(for: line.kind),
               let wordRange = wordDiffRanges[index], wordRange.location + wordRange.length <= piece.length {
                piece.addAttribute(.backgroundColor, value: strongColor, range: wordRange)
            }

            result.append(piece)
            metadata.append(DiffLineMetadata(
                oldLineNumber: line.oldLineNumber,
                newLineNumber: line.newLineNumber,
                backgroundColor: DiffView.backgroundNSColor(for: line.kind),
                isHunkStart: line.isHunkStart,
                isHunkEnd: line.isHunkEnd,
                kind: line.kind
            ))
        }

        return (result, metadata)
    }

    // MARK: - Word diff

    /// GitHub-style "word diff": within a block where a run of removed lines is immediately
    /// followed by a run of added lines (a one-for-one replacement, e.g. a single changed value),
    /// pairs them up index-wise and finds the sub-range that actually differs in each pair via
    /// common-prefix/suffix trimming — simple, but it's exactly what produces the "just the version
    /// number is highlighted" effect for straightforward substitutions. Blocks with an unequal
    /// number of removed/added lines, or added/removed lines with no paired counterpart at all
    /// (pure insertions/deletions), are left with only the whole-line background.
    private static func wordDiffRanges(for lines: [DiffLine]) -> [Int: NSRange] {
        var result: [Int: NSRange] = [:]
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removed else {
                index += 1
                continue
            }

            var removedEnd = index
            while removedEnd + 1 < lines.count, lines[removedEnd + 1].kind == .removed {
                removedEnd += 1
            }
            let addedStart = removedEnd + 1
            var addedEnd = addedStart - 1
            if addedStart < lines.count, lines[addedStart].kind == .added {
                addedEnd = addedStart
                while addedEnd + 1 < lines.count, lines[addedEnd + 1].kind == .added {
                    addedEnd += 1
                }
            }

            let removedCount = removedEnd - index + 1
            let addedCount = max(0, addedEnd - addedStart + 1)
            let pairCount = min(removedCount, addedCount)
            for offset in 0..<pairCount {
                let oldLine = lines[index + offset]
                let newLine = lines[addedStart + offset]
                guard let (oldRange, newRange) = diffRanges(old: oldLine.displayText, new: newLine.displayText) else { continue }
                result[index + offset] = oldRange
                result[addedStart + offset] = newRange
            }

            index = addedCount > 0 ? addedEnd + 1 : removedEnd + 1
        }
        return result
    }

    /// Trims the common leading and trailing substrings shared by `old` and `new`, returning the
    /// differing middle range in each (in UTF-16 offsets, matching `NSRange`), or `nil` if the two
    /// strings are identical.
    private static func diffRanges(old: String, new: String) -> (old: NSRange, new: NSRange)? {
        let oldNS = old as NSString
        let newNS = new as NSString
        if oldNS.isEqual(to: new) { return nil }

        let oldLength = oldNS.length
        let newLength = newNS.length
        let maxPrefix = min(oldLength, newLength)

        var prefix = 0
        while prefix < maxPrefix, oldNS.character(at: prefix) == newNS.character(at: prefix) {
            prefix += 1
        }

        var suffix = 0
        let maxSuffix = maxPrefix - prefix
        while suffix < maxSuffix,
              oldNS.character(at: oldLength - 1 - suffix) == newNS.character(at: newLength - 1 - suffix) {
            suffix += 1
        }

        let oldRange = NSRange(location: prefix, length: oldLength - prefix - suffix)
        let newRange = NSRange(location: prefix, length: newLength - prefix - suffix)
        guard oldRange.length > 0 || newRange.length > 0 else { return nil }
        return (oldRange, newRange)
    }
}
