import AppKit
import SwiftUI

/// Borderless floating panel hosting `CommandPaletteView`. ⌘1–⌘9 are caught here in
/// `performKeyEquivalent` — the key window gets first look at key equivalents, ahead of the main
/// menu — rather than through SwiftUI `.onKeyPress`, which follows `@FocusState` instead of the
/// real AppKit responder (the field editor, here).
final class CommandPalettePanel: NSPanel {
    var onCommandNumber: ((Int) -> Void)?
    /// ⌘↩ — the selected row's ⌘ alternate. Caught here because, like ⌘1–⌘9, it's a key
    /// equivalent and never reaches the field editor's `doCommandBy`.
    var onCommandReturn: (() -> Void)?
    var onDismiss: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: CommandPaletteView.width + CommandPaletteView.shadowInset * 2, height: 400),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        // The card draws its own SwiftUI shadow into the panel's transparent margin — a window
        // shadow would trace the (rectangular) panel bounds instead.
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        isMovable = false
        animationBehavior = .utilityWindow
        // Never drawn (borderless), but it's what VoiceOver names the window.
        title = "Command Palette"
        setAccessibilitySubrole(.dialog)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 { // Return, keypad Enter
            onCommandReturn?()
            return true
        }
        if flags == .command,
           let characters = event.charactersIgnoringModifiers,
           let number = Int(characters), (1...9).contains(number) {
            onCommandNumber?(number)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// A click in the transparent shadow margin around the card counts as clicking outside it.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown,
           let contentView,
           !contentView.bounds.insetBy(dx: CommandPaletteView.shadowInset, dy: CommandPaletteView.shadowInset)
               .contains(contentView.convert(event.locationInWindow, from: nil)) {
            onDismiss?()
            return
        }
        super.sendEvent(event)
    }

    /// Clicking anywhere else (including back into the main window) dismisses the palette.
    override func resignKey() {
        super.resignKey()
        onDismiss?()
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}

/// Owns the palette panel and its model for the main window. `shared` is how `LeafApp`'s ⌘K
/// menu item reaches it — same reasoning as `AppStateHolder`.
final class CommandPaletteController {
    static weak var shared: CommandPaletteController?

    private let appState: AppState
    private weak var parentWindow: NSWindow?
    private let model = CommandPaletteModel()
    private let usage = CommandUsageStore()
    /// Repo folders found missing by the last background check — what `build` marks
    /// "Folder not found". Starts empty: a repo whose folder has vanished shows as normal until
    /// the first check (a moment after the first open) lands.
    private var missingRepoPaths: Set<String> = []
    private var missingCheckGeneration = 0
    private var panel: CommandPalettePanel?
    /// The panel's top edge in screen coordinates while shown — resizes keep it fixed so the
    /// card grows/shrinks downward as results change.
    private var anchoredTop: CGFloat = 0
    private var contentHeight: CGFloat = 0
    private var isDismissing = false

    init(appState: AppState, parentWindow: NSWindow?) {
        self.appState = appState
        self.parentWindow = parentWindow
    }

    var isShown: Bool { panel?.isVisible == true }

    func toggle() {
        isShown ? dismiss() : show()
    }

    func show() {
        guard let parentWindow, parentWindow.isVisible, parentWindow.attachedSheet == nil, !isShown else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let built = CommandPaletteItems.build(appState: appState, usage: usage, missingPaths: missingRepoPaths)
        model.reset(items: built.items, suggestions: built.suggestions, dynamicItems: built.dynamicItems)
        checkMissingRepoFolders()
        // Coalesced, async, and one repo at a time — rows show the cached status immediately and
        // pick up fresh branch/date/dirty state as each repo's check lands.
        appState.repoStatusStore.refreshAll(repos: appState.sidebarStore.repos)

        let parentFrame = parentWindow.frame
        anchoredTop = parentFrame.maxY - min(160, parentFrame.height * 0.2)
        let height = contentHeight > 0 ? contentHeight : 400
        panel.setFrame(frame(height: height, in: parentFrame), display: false)

        parentWindow.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        // Ordering out the key panel fires its `resignKey`, which calls back in here.
        guard let panel, panel.isVisible, !isDismissing else { return }
        isDismissing = true
        defer { isDismissing = false }
        parentWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
        if NSApp.isActive {
            parentWindow?.makeKeyAndOrderFront(nil)
        }
    }

    /// Closes first, then runs on the next turn of the run loop — so any alert, sheet or open
    /// panel the command brings up attaches to the main window rather than the palette.
    /// `modifier` picks the row's alternate action instead; a row without that alternate, or an
    /// unavailable row, beeps and leaves the palette open.
    private func run(_ item: PaletteItem, modifier: PaletteModifier? = nil) {
        let action: () -> Void
        if let modifier {
            guard let alternate = item.alternate(for: modifier) else { return NSSound.beep() }
            action = alternate.perform
        } else {
            guard item.isEnabled else {
                // "Commit" with no message yet: Return fills in "Commit " to type one, rather
                // than being a dead end. Only when the missing argument is the *only* reason —
                // otherwise typing one couldn't make it runnable.
                if item.needsArgument, let prefix = item.argumentPrefix,
                   !model.query.lowercased().hasPrefix(prefix.lowercased()) {
                    model.query = prefix
                } else {
                    NSSound.beep()
                }
                return
            }
            action = item.perform
            if let key = item.usageKey { usage.recordUse(of: key) }
        }
        dismiss()
        DispatchQueue.main.async {
            action()
        }
    }

    /// Checks every repo folder still exists, off the main thread (a `stat` on an unmounted
    /// network volume can block for seconds). If the set of missing ones changed, the open
    /// palette's items are rebuilt in place — query and selection kept.
    private func checkMissingRepoFolders() {
        missingCheckGeneration &+= 1
        let generation = missingCheckGeneration
        let paths = appState.sidebarStore.repos.map(\.path)
        Task { @MainActor [weak self] in
            let missing = await Task.detached(priority: .utility) {
                Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
            }.value
            guard let self, generation == self.missingCheckGeneration, missing != self.missingRepoPaths else { return }
            self.missingRepoPaths = missing
            guard self.isShown else { return }
            let built = CommandPaletteItems.build(appState: self.appState, usage: self.usage, missingPaths: missing)
            self.model.replaceItems(built.items, suggestions: built.suggestions, dynamicItems: built.dynamicItems)
        }
    }

    private func makePanel() -> CommandPalettePanel {
        let panel = CommandPalettePanel()
        let root = CommandPaletteView(
            model: model,
            appState: appState,
            onRun: { [weak self] item, modifier in self?.run(item, modifier: modifier) },
            onCancel: { [weak self] in self?.dismiss() },
            onHeightChange: { [weak self] height in self?.contentHeightDidChange(height) }
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.onCommandNumber = { [weak self] number in
            guard let self else { return }
            let index = number - 1
            guard self.model.results.indices.contains(index) else { return }
            self.run(self.model.results[index])
        }
        panel.onCommandReturn = { [weak self] in
            guard let self, let item = self.model.selectedItem else { return }
            self.run(item, modifier: .command)
        }
        panel.onDismiss = { [weak self] in self?.dismiss() }
        return panel
    }

    private func contentHeightDidChange(_ height: CGFloat) {
        guard height > 0, height != contentHeight else { return }
        contentHeight = height
        guard let panel, let parentWindow, panel.isVisible else { return }
        panel.setFrame(frame(height: height, in: parentWindow.frame), display: true)
    }

    /// `cardHeight` is the card alone; the panel adds the shadow margin on every side, and
    /// `anchoredTop` is where the card's (not the panel's) top edge sits.
    private func frame(height cardHeight: CGFloat, in parentFrame: NSRect) -> NSRect {
        let inset = CommandPaletteView.shadowInset
        let width = CommandPaletteView.width + inset * 2
        let height = cardHeight.rounded(.up) + inset * 2
        return NSRect(
            x: (parentFrame.midX - width / 2).rounded(),
            y: (anchoredTop + inset - height).rounded(),
            width: width,
            height: height
        )
    }
}
