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
/// `enumerateLineFragments`/`characterIndexForGlyph` glyph APIs this view and its ruler depend on
/// are available.
final class DiffCodeTextView: NSTextView {
    private(set) var lineMetadata: [DiffLineMetadata] = []
    private var paragraphStartOffsets: [Int] = [0]

    static func makeLegacyTextKit1() -> DiffCodeTextView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        container.lineFragmentPadding = 4
        layoutManager.addTextContainer(container)
        return DiffCodeTextView(frame: .zero, textContainer: container)
    }

    func setContent(attributedString: NSAttributedString, metadata: [DiffLineMetadata]) {
        lineMetadata = metadata
        textStorage?.setAttributedString(attributedString)
        recomputeParagraphOffsets()
        resizeToFitContent()
        needsDisplay = true
    }

    /// Setting `textStorage` directly (rather than typing into the view) never fires the
    /// notifications `isVerticallyResizable` normally relies on to grow the document view's frame,
    /// so the scroll view kept treating the content as exactly one viewport tall regardless of the
    /// diff's real length — this is what caused scrolling to be clamped to the initial size (with
    /// a rubber-band bounce even on short documents, since the frame never actually matched the
    /// content). Called after every content change and on every `layout()` pass, so it also re-fits
    /// when the enclosing scroll view is resized and lines re-wrap.
    private func resizeToFitContent() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2
        let viewportSize = enclosingScrollView?.contentSize ?? frame.size
        let newWidth = viewportSize.width > 0 ? viewportSize.width : frame.width
        let newHeight = max(usedHeight, viewportSize.height)
        if abs(frame.width - newWidth) > 0.5 || abs(frame.height - newHeight) > 0.5 {
            setFrameSize(NSSize(width: newWidth, height: newHeight))
        }
    }

    override func layout() {
        super.layout()
        resizeToFitContent()
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

/// Dual old/new line-number gutter, drawn in the scroll view's ruler area — entirely outside the
/// text view's own bounds and text storage, exactly like Xcode's or BBEdit's gutters, so numbers
/// can never get swept into a text selection or a copy.
final class DiffGutterRulerView: NSRulerView {
    weak var codeTextView: DiffCodeTextView?

    private static let numberFont = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    private static let columnWidth: CGFloat = 36
    private static let columnGap: CGFloat = 8

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 2 * Self.columnWidth + Self.columnGap + 8
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = codeTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              layoutManager.numberOfGlyphs > 0 else { return }

        let visibleRect = scrollView?.contentView.bounds ?? textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let text = textView.string as NSString

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
            guard fragGlyphRange.location < layoutManager.numberOfGlyphs else { return }
            let charIndex = layoutManager.characterIndexForGlyph(at: fragGlyphRange.location)

            // Only the first wrapped fragment of a paragraph carries its line numbers.
            let isFirstFragmentOfParagraph = charIndex == 0 || text.character(at: charIndex - 1) == 10
            guard isFirstFragmentOfParagraph else { return }

            let paragraphIndex = textView.paragraphIndex(forCharacterIndex: charIndex)
            guard paragraphIndex < textView.lineMetadata.count else { return }
            let meta = textView.lineMetadata[paragraphIndex]
            guard !meta.isHunkHeader else { return }

            var lineRect = fragRect
            lineRect.origin.y += textView.textContainerOrigin.y
            let converted = textView.convert(lineRect, to: self)

            self.drawNumber(meta.oldLineNumber, x: 4, width: Self.columnWidth, rowRect: converted)
            self.drawNumber(meta.newLineNumber, x: 4 + Self.columnWidth, width: Self.columnWidth, rowRect: converted)
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

/// SwiftUI bridge for the `NSTextView`/`NSRulerView` pair above. Builds the per-line
/// `NSAttributedString` and background/gutter metadata from the already-parsed diff lines and
/// (once ready) the syntax-highlighted pieces computed by `DiffView`.
struct DiffCodeScrollView: NSViewRepresentable {
    let lines: [DiffLine]
    let highlightSnapshot: HighlightSnapshot?
    let diffText: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = DiffCodeTextView.makeLegacyTextKit1()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let ruler = DiffGutterRulerView(scrollView: scrollView)
        ruler.codeTextView = textView
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        updateContent(textView: textView, ruler: ruler)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView, let ruler = context.coordinator.ruler else { return }
        updateContent(textView: textView, ruler: ruler)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var textView: DiffCodeTextView?
        var ruler: DiffGutterRulerView?
    }

    private func updateContent(textView: DiffCodeTextView, ruler: DiffGutterRulerView) {
        let (attributed, metadata) = Self.buildContent(lines: lines, highlightSnapshot: highlightSnapshot, diffText: diffText)
        textView.setContent(attributedString: attributed, metadata: metadata)
        ruler.needsDisplay = true
    }

    private static func buildContent(
        lines: [DiffLine],
        highlightSnapshot: HighlightSnapshot?,
        diffText: String
    ) -> (NSAttributedString, [DiffLineMetadata]) {
        let bodyFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let headerFont = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
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
                    .foregroundColor: NSColor.secondaryLabelColor
                ]))
                metadata.append(DiffLineMetadata(
                    oldLineNumber: nil,
                    newLineNumber: nil,
                    backgroundColor: DiffView.hunkHeaderBackgroundNSColor,
                    isHunkHeader: true
                ))
                continue
            }

            let piece = NSMutableAttributedString(string: line.displayText)
            let fullRange = NSRange(location: 0, length: piece.length)
            piece.addAttribute(.font, value: bodyFont, range: fullRange)
            piece.addAttribute(.foregroundColor, value: DiffView.foregroundNSColor(for: line.kind), range: fullRange)

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
                isHunkHeader: false
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
