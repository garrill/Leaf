import AppKit
import SwiftUI

/// Per-paragraph (i.e. per-`DiffLine`) info needed to paint the row background and gutter
/// numbers — kept entirely out of the text storage itself so none of it is selectable or
/// copyable alongside the code text.
struct DiffLineMetadata {
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let backgroundColor: NSColor?
    let isHunkHeader: Bool
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
    private(set) var lineMetadata: [DiffLineMetadata] = []
    private var paragraphStartOffsets: [Int] = [0]

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

    func setContent(attributedString: NSAttributedString, metadata: [DiffLineMetadata]) {
        lineMetadata = metadata
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

    /// Paints each line's background edge-to-edge before the glyphs draw. `NSAttributedString`'s
    /// `.backgroundColor` attribute alone only fills the glyph run's own advance width, which would
    /// leave short added/removed lines with a background that stops short of the trailing edge
    /// instead of spanning the full row the way the old SwiftUI `Text` rows did.
    override func draw(_ dirtyRect: NSRect) {
        if let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 {
            let glyphRange = layoutManager.glyphRange(forBoundingRect: dirtyRect, in: textContainer)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
                guard fragGlyphRange.location < layoutManager.numberOfGlyphs else { return }
                let charIndex = layoutManager.characterIndexForGlyph(at: fragGlyphRange.location)
                let paragraphIndex = self.paragraphIndex(forCharacterIndex: charIndex)
                guard paragraphIndex < self.lineMetadata.count,
                      let color = self.lineMetadata[paragraphIndex].backgroundColor else { return }

                var fillRect = fragRect
                fillRect.origin.x = 0
                fillRect.size.width = max(self.bounds.width, fragRect.maxX)
                fillRect.origin.y += self.textContainerOrigin.y

                color.setFill()
                fillRect.fill()
            }
        }
        super.draw(dirtyRect)
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

    private static let numberFont = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
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

        // The gutter and text view share the same y-origin and flip (both are non-scrolling
        // siblings inside `DiffCodeContainerView`), so the dirty rect's y-range maps directly onto
        // the text view's own coordinate space without any scroll-offset translation.
        let searchRect = NSRect(x: 0, y: dirtyRect.minY, width: textView.bounds.width, height: dirtyRect.height)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: searchRect, in: container)
        let text = textView.string as NSString

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
            guard fragGlyphRange.location < layoutManager.numberOfGlyphs else { return }
            let charIndex = layoutManager.characterIndexForGlyph(at: fragGlyphRange.location)

            let paragraphIndex = textView.paragraphIndex(forCharacterIndex: charIndex)
            guard paragraphIndex < textView.lineMetadata.count else { return }
            let meta = textView.lineMetadata[paragraphIndex]
            guard !meta.isHunkHeader else { return }

            var lineRect = fragRect
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
            let isFirstFragmentOfParagraph = charIndex == 0 || text.character(at: charIndex - 1) == 10
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

            var lineRect = fragRect
            lineRect.origin.y += textView.textContainerOrigin.y

            let borderColor = meta.isHunkHeader ? NSColor.separatorColor : DiffView.borderNSColor(for: meta.kind)
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
            .font: Self.numberFont,
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

/// Hosts the gutter and code text view as plain (non-scrolling) sibling subviews, laid out
/// side-by-side and sized to fit their full content — the whole thing is scrolled by a real
/// SwiftUI `ScrollView` one level up, not by an internal `NSScrollView`.
final class DiffCodeContainerView: NSView {
    let textView = DiffCodeTextView.makeLegacyTextKit1()
    let gutterView = DiffGutterView()
    /// What `setContent` last actually applied — `DiffCodeScrollView.updateNSView` runs on
    /// *every* SwiftUI update of this view (scroll position changes, hover state, unrelated
    /// parent re-renders, etc.), not just ones where the diff itself changed. Without this,
    /// every such call rebuilt the full attributed string and re-ran text layout from scratch
    /// (confirmed via Instruments: ~200ms combined for `buildContent`/`setContent`/
    /// `fittingHeight` on a single unrelated re-render) even when nothing about the diff had.
    private var lastContentKey: DiffContentKey?

    override init(frame: NSRect) {
        super.init(frame: frame)
        gutterView.codeTextView = textView
        addSubview(gutterView)
        addSubview(textView)
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
        textView.setContent(attributedString: attributedString, metadata: metadata)
        needsLayout = true
        gutterView.needsDisplay = true
    }
}

/// Identifies what's currently painted in a `DiffCodeContainerView` well enough to know when a
/// rebuild can be skipped, without needing `HighlightSnapshot`'s `[Int: AttributedString]` (not
/// cheaply equatable) to be `Equatable` itself. Uses the snapshot's own identity rather than its
/// line count — `DiffView.refreshHighlighting()` always produces a brand-new `HighlightSnapshot`
/// (a new `id`) each time it runs, including when only the color scheme changed and the diff text
/// and line count are otherwise identical, so an identity-based key repaints in that case where a
/// line-count-based one would not.
struct DiffContentKey: Equatable {
    let diffText: String
    let highlightSnapshotID: UUID?
}

/// SwiftUI bridge for the gutter/text-view pair above. Builds the per-line `NSAttributedString`
/// and background/gutter metadata from the already-parsed diff lines and (once ready) the
/// syntax-highlighted pieces computed by `DiffView`. Reports its own intrinsic size via
/// `sizeThatFits` so it can be scrolled by a real SwiftUI `ScrollView` (see `DiffView.content`)
/// instead of owning a private `NSScrollView`.
struct DiffCodeScrollView: NSViewRepresentable {
    let lines: [DiffLine]
    let highlightSnapshot: HighlightSnapshot?
    let diffText: String

    func makeNSView(context: Context) -> DiffCodeContainerView {
        let container = DiffCodeContainerView(frame: .zero)
        configure(textView: container.textView)
        updateContent(container: container)
        return container
    }

    func updateNSView(_ container: DiffCodeContainerView, context: Context) {
        updateContent(container: container)
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
        let key = DiffContentKey(diffText: diffText, highlightSnapshotID: highlightSnapshot?.id)
        guard container.needsContentUpdate(for: key) else { return }
        let (attributed, metadata) = Self.buildContent(lines: lines, highlightSnapshot: highlightSnapshot, diffText: diffText)
        container.setContent(attributedString: attributed, metadata: metadata, key: key)
    }

    private static func buildContent(
        lines: [DiffLine],
        highlightSnapshot: HighlightSnapshot?,
        diffText: String
    ) -> (NSAttributedString, [DiffLineMetadata]) {
        let bodyFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let headerFont = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        // Applied to every line (header and body alike) so row height — which the gutter and its
        // background/border fills read straight off the layout manager's line fragments — grows
        // along with it everywhere, not just where the code font itself is used.
        let lineParagraphStyle = NSMutableParagraphStyle()
        lineParagraphStyle.lineHeightMultiple = 1.3
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

            if line.kind == .hunkHeader {
                result.append(NSAttributedString(string: line.text, attributes: [
                    .font: headerFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: lineParagraphStyle
                ]))
                metadata.append(DiffLineMetadata(
                    oldLineNumber: nil,
                    newLineNumber: nil,
                    backgroundColor: DiffView.hunkHeaderBackgroundNSColor,
                    isHunkHeader: true,
                    kind: .hunkHeader
                ))
                continue
            }

            let piece = NSMutableAttributedString(string: line.displayText)
            let fullRange = NSRange(location: 0, length: piece.length)
            piece.addAttribute(.font, value: bodyFont, range: fullRange)
            piece.addAttribute(.foregroundColor, value: DiffView.foregroundNSColor(for: line.kind), range: fullRange)
            piece.addAttribute(.paragraphStyle, value: lineParagraphStyle, range: fullRange)

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
                isHunkHeader: false,
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
