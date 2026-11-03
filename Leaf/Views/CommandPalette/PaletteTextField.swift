import AppKit
import SwiftUI

/// The palette's search field: a plain AppKit `NSTextField` rather than a SwiftUI `TextField`, so
/// ↑/↓/Return/Tab/Esc come through `control(_:textView:doCommandBy:)` from the real field editor
/// — deterministic regardless of SwiftUI focus state (see CLAUDE.md on `.onKeyPress`). The dimmed
/// autofill ghost is drawn by the field's own editor (`GhostFieldEditor`).
struct PaletteTextField: NSViewRepresentable {
    let model: CommandPaletteModel
    /// Return runs the selected row; ⌥↩/⇧↩ pass the modifier for its alternate action.
    let onRun: (PaletteModifier?) -> Void
    let onCancel: () -> Void

    static let font = NSFont.systemFont(ofSize: 20, weight: .regular)

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, onRun: onRun, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> PaletteFieldContainer {
        let container = PaletteFieldContainer()
        container.textField.delegate = context.coordinator
        return container
    }

    func updateNSView(_ container: PaletteFieldContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.onRun = onRun
        coordinator.onCancel = onCancel

        // Programmatic query changes (Tab-accepting a completion, a fresh session).
        if container.textField.stringValue != model.query {
            container.textField.stringValue = model.query
            if let editor = container.textField.currentEditor() {
                editor.selectedRange = NSRange(location: (model.query as NSString).length, length: 0)
            }
        }
        container.ghost = model.ghost
        // The empty-query ghost (first suggestion's name) sits where a placeholder would, so the
        // placeholder only shows when there's nothing to suggest.
        container.textField.placeholderString = model.ghost == nil && model.query.isEmpty
            ? "Search repositories, branches and commands"
            : nil

        if coordinator.lastFocusRequest != model.focusRequest {
            coordinator.lastFocusRequest = model.focusRequest
            DispatchQueue.main.async {
                container.window?.makeFirstResponder(container.textField)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: CommandPaletteModel
        var onRun: (PaletteModifier?) -> Void
        var onCancel: () -> Void
        var lastFocusRequest = -1

        init(model: CommandPaletteModel, onRun: @escaping (PaletteModifier?) -> Void, onCancel: @escaping () -> Void) {
            self.model = model
            self.onRun = onRun
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                model.moveSelection(by: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                model.moveSelection(by: 1)
                return true
            case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)),
                 #selector(NSResponder.scrollToBeginningOfDocument(_:)):
                // Page Up/Home: a single-line field would otherwise scroll its own text a
                // couple of points vertically. Jump to the first row instead.
                model.selectFirst()
                return true
            case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)),
                 #selector(NSResponder.scrollToEndOfDocument(_:)):
                model.selectLast()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                // ⇧↩ arrives as a plain `insertNewline:` — the modifier is only on the event.
                // (⌘↩ never gets here; it's a key equivalent, caught by the panel.)
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                onRun(PaletteModifier(flags: flags))
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // ⌥↩.
                onRun(.option)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true
            case #selector(NSResponder.insertTab(_:)):
                _ = model.acceptCompletion()
                return true
            case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)):
                // Only at the very end of the text — otherwise → is ordinary caret movement.
                let range = textView.selectedRange()
                guard range.length == 0, range.location == (textView.string as NSString).length else { return false }
                return model.acceptCompletion()
            default:
                return false
            }
        }
    }
}

final class PaletteFieldContainer: NSView {
    let textField = NSTextField()
    /// The field editor `textField` edits with — it draws the ghost itself (see
    /// `GhostFieldEditor`), so the ghost shares the typed text's exact baseline and position.
    private let fieldEditor = GhostFieldEditor()

    var ghost: CommandPaletteModel.Ghost? {
        didSet {
            switch ghost {
            case .completion(let suffix)?:
                fieldEditor.ghostText = suffix
            case .hint(let title)?:
                fieldEditor.ghostText = "  \u{2014} \(title)"
            default:
                fieldEditor.ghostText = ""
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let cell = GhostTextFieldCell(textCell: "")
        cell.ghostFieldEditor = fieldEditor
        textField.cell = cell
        textField.isEditable = true
        textField.isSelectable = true
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = PaletteTextField.font
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byClipping
        cell.isScrollable = true
        cell.wraps = false
        textField.setAccessibilityLabel("Command palette")
        textField.setAccessibilityHelp("Type to search repositories, branches, commits, files and commands. Use the up and down arrows to choose, Return to run.")
        addSubview(textField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: textField.intrinsicContentSize.height)
    }

    override func layout() {
        super.layout()
        let height = textField.intrinsicContentSize.height
        textField.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }
}

/// Hands `PaletteFieldContainer`'s `GhostFieldEditor` to the field instead of the window's shared
/// field editor.
private final class GhostTextFieldCell: NSTextFieldCell {
    var ghostFieldEditor: NSTextView?

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        ghostFieldEditor ?? super.fieldEditor(for: controlView)
    }
}

/// A field editor that draws dimmed autofill text straight after the last typed character. Drawn
/// by the editor itself, from its own layout manager's line fragment and baseline, so the ghost
/// can never sit higher/lower or further along than the typed text — and it scrolls with the
/// text if the query overflows the field.
final class GhostFieldEditor: NSTextView {
    var ghostText = "" {
        // Unconditional: even unchanged ghost text moves when the typed text's width changes.
        didSet { needsDisplay = true }
    }

    /// Built on an explicit TextKit 1 stack (as `DiffCodeTextView.makeLegacyTextKit1()` does) —
    /// the plain initializer can come back TextKit 2-backed with no `layoutManager`, and the
    /// ghost's position comes from the layout manager. Container sized like AppKit's own field
    /// editor: unbounded width, no tracking, so a long query lays out on one line.
    init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isFieldEditor = true
        isHorizontallyResizable = true
        isVerticallyResizable = false
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !ghostText.isEmpty,
              let layoutManager,
              let textContainer,
              let font = font ?? PaletteTextField.font as NSFont? else { return }
        layoutManager.ensureLayout(for: textContainer)

        let endX: CGFloat
        let baselineY: CGFloat
        let glyphCount = layoutManager.numberOfGlyphs
        if glyphCount > 0 {
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            baselineY = lineRect.minY + layoutManager.location(forGlyphAt: 0).y
            let lastGlyph = NSRange(location: glyphCount - 1, length: 1)
            endX = layoutManager.boundingRect(forGlyphRange: lastGlyph, in: textContainer).maxX
        } else {
            let lineRect = layoutManager.extraLineFragmentRect
            baselineY = lineRect.minY + layoutManager.defaultBaselineOffset(for: font)
            endX = lineRect.minX + textContainer.lineFragmentPadding
        }

        let origin = textContainerOrigin
        let ghost = NSAttributedString(
            string: ghostText,
            attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        )
        // No `.usesLineFragmentOrigin`: the rect's origin is then the first line's baseline.
        ghost.draw(
            with: NSRect(x: origin.x + endX, y: origin.y + baselineY, width: 10_000, height: 0),
            options: []
        )
    }
}
