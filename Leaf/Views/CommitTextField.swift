import AppKit
import SwiftUI

/// Which of the commit footer's two text fields has focus.
enum CommitField: Hashable {
    case summary
    case description
}

/// One section of the commit footer's divided message box: a real `NSTextView` in an
/// `NSScrollView`, in place of SwiftUI's `TextField(axis: .vertical)`. That field only scrolls
/// while focused (trackpad/wheel scrolling does nothing at rest), and it renders its resting text
/// separately from its focused field editor, so overflowing content visibly jumped a few points
/// the moment it was focused. One text view drawing in both states fixes both.
///
/// Focus is reported through `focus` from the text view's own first-responder changes rather
/// than SwiftUI's `.focused` — a representable's inner `NSTextView` isn't something
/// `@FocusState` can address. Setting `focus` to `field` makes it first responder.
///
/// The section's padding is the text view's own `textContainerInset`, so the whole section
/// (margins included) is the click target and text scrolls right up to the section's edge.
struct CommitTextField: NSViewRepresentable {
    static let horizontalInset: CGFloat = 14
    static let verticalInset: CGFloat = 10

    @Binding var text: String
    let placeholder: String
    let font: NSFont
    var textColor: NSColor = .labelColor
    let field: CommitField
    @Binding var focus: CommitField?
    /// Lines the field is always at least this tall.
    var minLines = 1
    /// Lines the field grows to before it scrolls instead.
    var maxLines = 1
    /// When true the text is a single paragraph (wrapping, never containing newlines): Return
    /// goes to `onSubmit` and pasted newlines become spaces.
    var isSingleParagraph = false
    var onSubmit: () -> Void = {}
    var onCommandReturn: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CommitNSTextView.makeLegacyTextKit1()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        // Commit messages carry identifiers/paths/branch names — no autocorrect, smart
        // punctuation, or the inline completion panel (which also flashed empty on focus).
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: Self.horizontalInset, height: Self.verticalInset)
        textView.insertionPointColor = .labelColor

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = textView

        apply(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CommitNSTextView else { return }
        apply(to: textView)

        // Only pull focus in — never push it out. Losing focus is the text view's own business
        // (a click elsewhere); resigning here as well would fight AppKit over the responder.
        if focus == field, textView.window?.firstResponder !== textView {
            if let window = textView.window {
                window.makeFirstResponder(textView)
            } else {
                // Just inserted (the description appearing as the box expands) — no window yet.
                DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
            }
        }
    }

    private func apply(to textView: CommitNSTextView) {
        if textView.textColor != textColor {
            textView.textColor = textColor
            textView.typingAttributes[.foregroundColor] = textColor
        }
        if textView.font != font {
            textView.font = font
            textView.typingAttributes[.font] = font
        }
        // Only on a real external change (cleared after commit, draft restored on repo switch)
        // — reassigning on every update would reset the selection and undo stack mid-typing.
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let textWidth = max(1, width - 2 * Self.horizontalInset)
        let measured = (text.isEmpty ? " " : text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lines = Int((measured.height / lineHeight).rounded(.up))
        let visibleLines = min(max(lines, minLines), maxLines)
        return CGSize(width: width, height: CGFloat(visibleLines) * lineHeight + 2 * Self.verticalInset)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommitTextField

        init(_ parent: CommitTextField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)) where parent.isSingleParagraph:
                parent.onSubmit()
                return true
            case #selector(NSResponder.insertTab(_:)) where parent.field == .summary:
                parent.focus = .description
                return true
            case #selector(NSResponder.insertBacktab(_:)) where parent.field == .description:
                parent.focus = .summary
                return true
            default:
                return false
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard parent.isSingleParagraph, let replacementString,
                  replacementString.contains(where: \.isNewline) else { return true }
            let flattened = replacementString
                .split(whereSeparator: \.isNewline)
                .joined(separator: " ")
            textView.insertText(flattened, replacementRange: affectedCharRange)
            return false
        }

        func didBecomeFirstResponder() {
            parent.focus = parent.field
        }

        func didResignFirstResponder() {
            if parent.focus == parent.field {
                parent.focus = nil
            }
        }
    }
}

final class CommitNSTextView: NSTextView {
    weak var coordinator: CommitTextField.Coordinator?
    var placeholder = ""

    /// Explicitly TextKit 1 — see `DiffCodeTextView.makeLegacyTextKit1()`.
    static func makeLegacyTextKit1() -> CommitNSTextView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        return CommitNSTextView(frame: .zero, textContainer: container)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.didBecomeFirstResponder() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { coordinator?.didResignFirstResponder() }
        return resigned
    }

    /// Removed from the window while still first responder (the commit footer swapping out for
    /// the unpushed-commit footer the moment a commit lands) — AppKit never calls
    /// `resignFirstResponder` for that, so without this `focus` stays stuck on this field and
    /// every column-navigation key handler keeps backing off as if the user were still typing.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, window.firstResponder === self {
            coordinator?.didResignFirstResponder()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Cmd+Return isn't bound to any text-system command, so it has to be caught here.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if event.keyCode == 36, modifiers == .command {
            coordinator?.parent.onCommandReturn()
            return
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        // The placeholder's visibility depends on emptiness.
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        (placeholder as NSString).draw(at: textContainerOrigin, withAttributes: attributes)
    }
}
