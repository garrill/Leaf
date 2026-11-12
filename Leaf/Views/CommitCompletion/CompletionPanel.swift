import AppKit
import SwiftUI

/// Drives the commit field's completion popup: `CommitTextField` reports every text/caret
/// change (`update`), and routes ↑/↓/Return/Tab/Esc here first while the popup is showing.
/// One controller serves both the summary and description fields.
///
/// The popup is a non-activating child `NSPanel` that never becomes key, so the commit text
/// view keeps first responder (and its caret) throughout — clicks on a row are taken on the
/// first mouse-down without the panel ever taking focus.
@MainActor
final class CommitCompletionController {
    weak var appState: AppState?

    private let model = CompletionListModel()
    private var panel: CompletionPanel?
    private weak var textView: NSTextView?
    private var isSummary = true
    private var match: CompletionMatch?
    /// A token the user dismissed (Esc) or just completed — not reopened until the caret leaves it.
    private var suppressed: (kind: CompletionTriggerKind, location: Int)?
    private var resignKeyObserver: NSObjectProtocol?

    private var fileItemsCache: (signature: Int, items: [CompletionItem])?
    private var storeItemsCache: [CompletionTriggerKind: (generation: Int, signature: Int, items: [CompletionItem])] = [:]
    private var prefixCache: (signature: Int, types: [String])?

    var isVisible: Bool { panel?.isVisible == true && match != nil }

    // MARK: Driving

    func update(textView: NSTextView, isSummary: Bool) {
        guard textView.window?.firstResponder === textView,
              textView.selectedRange().length == 0,
              !textView.hasMarkedText(),
              let found = CompletionTrigger.detect(in: textView.string, cursor: textView.selectedRange().location, isSummary: isSummary)
        else {
            suppressed = nil
            dismiss()
            return
        }
        if let suppressed {
            if suppressed.kind == found.kind, suppressed.location == found.tokenRange.location {
                dismiss()
                return
            }
            self.suppressed = nil
        }
        self.textView = textView
        self.isSummary = isSummary
        match = found
        CompletionDataStore.shared.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    func moveSelection(by delta: Int) {
        guard !model.items.isEmpty else { return }
        model.selectedIndex = (model.selectedIndex + delta + model.items.count) % model.items.count
    }

    /// Inserts the selected row. `false` (and the popup closes) when there's nothing to insert,
    /// so the key falls through to its normal meaning.
    @discardableResult
    func accept(index: Int? = nil) -> Bool {
        let index = index ?? model.selectedIndex
        guard let match, let textView, model.items.indices.contains(index) else {
            dismiss()
            return false
        }
        let item = model.items[index]
        var range = match.tokenRange
        let string = textView.string as NSString
        // Step over a closing backtick already sitting after the caret rather than doubling it.
        if match.kind == .backtick, NSMaxRange(range) < string.length,
           string.character(at: NSMaxRange(range)) == 0x60 {
            range.length += 1
        }
        suppressed = (match.kind, range.location)
        dismiss()
        textView.insertText(item.insertText, replacementRange: range)
        return true
    }

    /// Esc: closes the popup and keeps it closed for this token.
    func cancel() {
        if let match { suppressed = (match.kind, match.tokenRange.location) }
        dismiss()
    }

    func dismiss() {
        match = nil
        hidePanel()
    }

    // MARK: Results

    private func refresh() {
        guard let match, let textView, let appState else {
            hidePanel()
            return
        }
        let (candidates, placeholder) = candidates(for: match.kind, appState: appState)
        let items: [CompletionItem]
        if match.kind == .prefix {
            items = candidates.filter { $0.title.hasPrefix(match.query) }.prefix(CompletionFilter.maxResults).map { $0 }
        } else {
            items = CompletionFilter.filter(candidates, query: match.query)
        }
        guard !items.isEmpty || placeholder != nil else {
            hidePanel()
            return
        }
        let previousID = model.items.indices.contains(model.selectedIndex) ? model.items[model.selectedIndex].id : nil
        model.placeholder = items.isEmpty ? placeholder : nil
        model.items = items
        model.selectedIndex = items.firstIndex { $0.id == previousID } ?? 0
        showPanel(below: match.tokenRange, in: textView)
    }

    /// Candidate rows for `kind`, plus a placeholder to show while they're still loading.
    private func candidates(for kind: CompletionTriggerKind, appState: AppState) -> ([CompletionItem], String?) {
        let store = CompletionDataStore.shared
        guard let repoURL = appState.selectedRepoURL else { return ([], nil) }
        switch kind {
        case .backtick:
            let untracked = appState.changedFiles.filter { $0.status == .untracked }.map(\.path)
            let symbols = store.symbols(repoURL: repoURL, untrackedPaths: untracked)
            let branchNames = appState.branches.map(\.name)
            var hasher = Hasher()
            hasher.combine(repoURL)
            hasher.combine(branchNames)
            let symbolItems = cachedStoreItems(.backtick, signature: hasher.finalize()) {
                let fileNames = Set(appState.changedFiles.map { ($0.path as NSString).lastPathComponent })
                let symbolRows = symbols.filter { !fileNames.contains($0) }.map {
                    CompletionItem(id: "symbol:\($0)", kind: .symbol, title: $0, insertText: "`\($0)`")
                }
                let branchRows = branchNames.map {
                    CompletionItem(id: "branch:\($0)", kind: .branch, title: $0, subtitle: "branch", insertText: "`\($0)`", boost: 10)
                }
                return symbolRows + branchRows
            }
            return (fileItems(appState: appState) + symbolItems, nil)

        case .mention, .coAuthor:
            guard let people = store.people(repoURL: repoURL, remoteURL: appState.originRemoteURL) else {
                return ([], "Loading people…")
            }
            var hasher = Hasher()
            hasher.combine(repoURL)
            hasher.combine(people.count)
            let items = cachedStoreItems(kind, signature: hasher.finalize()) {
                people.enumerated().map { rank, person in
                    let login = store.login(forEmail: person.email)
                    let boost = max(0, 40 - rank)
                    if kind == .coAuthor {
                        return CompletionItem(
                            id: "coauthor:\(person.email)", kind: .coAuthor, title: person.name,
                            subtitle: person.email, insertText: "\(person.name) <\(person.email)>",
                            keywords: [person.email] + (login.map { [$0] } ?? []), boost: boost
                        )
                    }
                    return CompletionItem(
                        id: "person:\(person.email)", kind: .person, title: person.name,
                        subtitle: login.map { "@\($0)" } ?? person.email,
                        insertText: login.map { "@\($0)" } ?? person.name,
                        keywords: (login.map { [$0] } ?? []) + [person.email], boost: boost
                    )
                }
            }
            return (items, nil)

        case .issue:
            let (issues, isAvailable) = store.issues(repoURL: repoURL, remoteURL: appState.originRemoteURL)
            guard isAvailable else { return ([], nil) }
            guard let issues else { return ([], "Loading issues…") }
            let items = cachedStoreItems(.issue, signature: repoURL.hashValue) {
                issues.enumerated().map { rank, issue in
                    CompletionItem(
                        id: "issue:\(issue.number)", kind: issue.isPullRequest ? .pullRequest : .issue,
                        title: issue.title, subtitle: "#\(issue.number)", insertText: "#\(issue.number)",
                        keywords: ["\(issue.number)"], fuzzy: .none, boost: max(0, 20 - rank / 5)
                    )
                }
            }
            return (items, nil)

        case .emoji:
            return (EmojiCatalog.items, nil)

        case .prefix:
            let summaries = appState.commits.prefix(500).map(\.summary)
            var hasher = Hasher()
            hasher.combine(summaries)
            let signature = hasher.finalize()
            if prefixCache?.signature != signature {
                let ranked = ConventionalPrefixes.rankedTypes(counts: ConventionalPrefixes.usageCounts(in: summaries))
                prefixCache = (signature, ranked)
            }
            let items = (prefixCache?.types ?? []).map {
                CompletionItem(id: "prefix:\($0)", kind: .prefix, title: $0, insertText: "\($0): ")
            }
            return (items, nil)
        }
    }

    /// Changed files (ticked ones first), rebuilt only when the file list or ticks change.
    private func fileItems(appState: AppState) -> [CompletionItem] {
        var hasher = Hasher()
        hasher.combine(appState.selectedRepoURL)
        hasher.combine(appState.changedFiles)
        hasher.combine(appState.checkedFilePaths)
        let signature = hasher.finalize()
        if let cache = fileItemsCache, cache.signature == signature { return cache.items }

        let files = appState.changedFiles.prefix(5000)
        let names = FileCompletionNames.displayNames(for: files.map(\.path))
        let items = files.map { file -> CompletionItem in
            let name = names[file.path] ?? file.path
            let directory = (file.path as NSString).deletingLastPathComponent
            return CompletionItem(
                id: "file:\(file.path)", kind: .file, title: name,
                subtitle: directory.isEmpty ? nil : directory,
                insertText: "`\(name)`",
                fuzzy: .text(file.path),
                boost: appState.checkedFilePaths.contains(file.path) ? 60 : 30
            )
        }
        fileItemsCache = (signature, items)
        return items
    }

    private func cachedStoreItems(_ kind: CompletionTriggerKind, signature: Int, build: () -> [CompletionItem]) -> [CompletionItem] {
        let generation = CompletionDataStore.shared.generation
        if let cache = storeItemsCache[kind], cache.generation == generation, cache.signature == signature {
            return cache.items
        }
        let items = build()
        storeItemsCache[kind] = (generation, signature, items)
        return items
    }

    // MARK: Panel

    private func showPanel(below range: NSRange, in textView: NSTextView) {
        guard let window = textView.window else { return }
        let panel = self.panel ?? makePanel()
        let anchor = textView.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
        let size = CompletionListView.size(rowCount: max(1, model.items.count))
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var origin = NSPoint(x: anchor.minX - CompletionListView.textLeadingOffset, y: anchor.minY - size.height - 4)
        if origin.y < screen.minY { origin.y = anchor.maxY + 4 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
        panel.orderFront(nil)
        panel.invalidateShadow()
    }

    private func hidePanel() {
        guard let panel, panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
    }

    private func makePanel() -> CompletionPanel {
        let panel = CompletionPanel()
        let root = CompletionListView(model: model) { [weak self] index in
            self?.accept(index: index)
        }
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }
}

/// Borderless, non-activating, never key — the commit field keeps focus while it's open.
final class CompletionPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: CompletionListView.width, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        // Borderless and transparent, so the window shadow follows the card's rounded shape.
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        isMovable = false
        animationBehavior = .none
        setAccessibilitySubrole(.unknown)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the click that lands on a non-key window instead of AppKit swallowing it.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@Observable
final class CompletionListModel {
    var items: [CompletionItem] = []
    var selectedIndex = 0
    /// Shown as the only row while the candidates are still loading ("Loading issues…").
    var placeholder: String?
}

struct CompletionListView: View {
    static let width: CGFloat = 360
    static let rowHeight: CGFloat = 26
    static let padding: CGFloat = 5
    private static let horizontalPadding: CGFloat = 8
    private static let iconWidth: CGFloat = 18
    private static let iconSpacing: CGFloat = 7
    /// From the panel's left edge to where a row's title starts — lines it up under the caret.
    static let textLeadingOffset = padding + horizontalPadding + iconWidth + iconSpacing

    static func size(rowCount: Int) -> NSSize {
        NSSize(width: width, height: CGFloat(rowCount) * rowHeight + padding * 2)
    }

    let model: CompletionListModel
    let onAccept: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let placeholder = model.placeholder {
                HStack(spacing: Self.iconSpacing) {
                    ProgressView().controlSize(.small).frame(width: Self.iconWidth)
                    Text(placeholder).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Self.horizontalPadding)
                .frame(height: Self.rowHeight)
            }
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                CompletionRow(item: item, isSelected: index == model.selectedIndex)
                    .onHover { hovering in
                        if hovering { model.selectedIndex = index }
                    }
                    .onTapGesture { onAccept(index) }
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }
}

private struct CompletionRow: View {
    let item: CompletionItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if let glyph = item.glyph {
                    Text(glyph)
                } else {
                    Image(systemName: symbolName)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                }
            }
            .frame(width: 18)

            Text(highlightedTitle)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            Spacer(minLength: 8)

            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: CompletionListView.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.subtitle ?? "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var symbolName: String {
        switch item.kind {
        case .file: return "doc"
        case .symbol: return "curlybraces"
        case .branch: return "arrow.triangle.branch"
        case .person: return "at"
        case .coAuthor: return "person.2"
        case .issue: return "smallcircle.filled.circle"
        case .pullRequest: return "arrow.triangle.pull"
        case .emoji: return "face.smiling"
        case .prefix: return "tag"
        }
    }

    private var highlightedTitle: AttributedString {
        var result = AttributedString(item.title)
        guard !item.matchedIndices.isEmpty else { return result }
        let matched = Set(item.matchedIndices)
        var index = result.startIndex
        var offset = 0
        while index < result.endIndex {
            let next = result.characters.index(after: index)
            if matched.contains(offset) {
                result[index..<next].font = .body.weight(.bold)
            }
            index = next
            offset += 1
        }
        return result
    }
}
