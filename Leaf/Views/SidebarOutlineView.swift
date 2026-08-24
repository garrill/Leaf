import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared layout constants for the sidebar, used both by `SidebarOutlineCoordinator` (to size
/// rows) and by `RepoRowView`/`FolderRowView` (to reserve the matching blank space in their own
/// content) so the two stay in sync.
enum SidebarLayout {
    static let rowHeight: CGFloat = 36
    static let groupSpacing: CGFloat = 10
}

/// Hosts the repo/folder sidebar in a real `NSOutlineView`, matching Finder/Mail/Xcode: native
/// drag-reorder with a system-drawn insertion line between rows, and a native highlight when
/// dropping directly onto a folder to append into it. AppKit owns all of the hit-testing for this,
/// so there's no custom SwiftUI drop-zone geometry to get wrong.
struct SidebarOutlineView: NSViewRepresentable {
    @Bindable var appState: AppState
    @Binding var renamingFolderID: UUID?
    @Binding var renamingRepoID: UUID?

    func makeCoordinator() -> SidebarOutlineCoordinator {
        SidebarOutlineCoordinator(
            appState: appState,
            renamingFolderID: $renamingFolderID,
            renamingRepoID: $renamingRepoID
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        outlineView.addTableColumn(column)
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowHeight = SidebarLayout.rowHeight
        outlineView.indentationPerLevel = 0
        outlineView.backgroundColor = .clear
        outlineView.allowsMultipleSelection = false
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.registerForDraggedTypes([
            SidebarOutlineCoordinator.pasteboardType,
            .fileURL
        ])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        context.coordinator.outlineView = outlineView
        context.coordinator.reloadPreservingState()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.appState = appState
        context.coordinator.renamingFolderIDBinding = $renamingFolderID
        context.coordinator.renamingRepoIDBinding = $renamingRepoID

        // Reading these establishes the @Observable dependency that re-invokes updateNSView.
        _ = appState.sidebarStore.topLevelOrder
        _ = appState.sidebarStore.repos
        _ = appState.sidebarStore.folders
        _ = appState.selectedRepoURL

        context.coordinator.reloadPreservingState()
    }
}

/// Draws the selection pill inset from the row's edges, matching the rounded highlight used by
/// Finder/Mail-style sidebars.
///
/// The native NSOutlineView disclosure button is hidden while leaving the outline hierarchy
/// intact, so NSOutlineView continues to handle expansion/collapse normally.
final class SidebarTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }

        let color: NSColor = isEmphasized
            ? .selectedContentBackgroundColor
            : .unemphasizedSelectedContentBackgroundColor

        // Rows at the end of a group are taller than `SidebarLayout.rowHeight`, carrying blank
        // group-spacing padding below their content — keep the selection pill pinned to the top,
        // matching the content, instead of stretching down through that padding.
        var rect = bounds.insetBy(dx: 4, dy: 2)
        rect.size.height = min(rect.height, SidebarLayout.rowHeight - 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        color.setFill()
        path.fill()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)

        // NSOutlineView adds its disclosure button to the row hierarchy.
        // Hide it without disabling the outline view's normal expansion behaviour.
        if let button = subview as? NSButton {
            button.isHidden = true
        }
    }

    override func layout() {
        super.layout()

        // NSOutlineView's own layout pass can flip the disclosure button back to visible after
        // it's first added (seen on the very first draw, before any row is selected/toggled) —
        // re-hide it on every layout rather than relying solely on the one-shot didAddSubview hook.
        for subview in subviews {
            if let button = subview as? NSButton, !button.isHidden {
                button.isHidden = true
            }
        }
    }
}

/// A hosting view for `FolderRowView` that tracks real mouse hover via `NSTrackingArea` — SwiftUI's
/// `.onHover` is unreliable this deep inside a reused `NSOutlineView` row cell, so hover is driven
/// natively instead and pushed into the (otherwise value-type, stateless-for-this) `FolderRowView`
/// by rebuilding `rootView` with the new value.
final class FolderHoverHostingView: NSHostingView<FolderRowView> {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )

        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}

final class SidebarOutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let pasteboardType = NSPasteboard.PasteboardType("digital.pepper.current.sidebar-drag-item")

    var appState: AppState
    var renamingFolderIDBinding: Binding<UUID?>
    var renamingRepoIDBinding: Binding<UUID?>
    weak var outlineView: NSOutlineView?

    private var itemCache: [SidebarOutlineItem.Kind: SidebarOutlineItem] = [:]
    private var isApplyingSelection = false
    private var hoveredFolderIDs: Set<UUID> = []

    /// The tree-shape-relevant slice of `sidebarStore` state as of the last `reloadData()` —
    /// lets `reloadPreservingState()` skip the actual `reloadData()`/expand-collapse pass (which
    /// recreates every row's `NSHostingView`) when nothing structural changed and this call was
    /// only triggered by `appState.selectedRepoURL` changing (e.g. clicking a different repo).
    /// `SidebarFolder.isExpanded` is part of the struct, so an expand/collapse still invalidates
    /// this correctly.
    private struct StructureSnapshot: Equatable {
        let repos: [SidebarRepo]
        let folders: [SidebarFolder]
        let topLevelOrder: [TopLevelEntry]
    }
    private var lastStructureSnapshot: StructureSnapshot?

    private var sidebarStore: SidebarStore {
        appState.sidebarStore
    }

    init(
        appState: AppState,
        renamingFolderID: Binding<UUID?>,
        renamingRepoID: Binding<UUID?>
    ) {
        self.appState = appState
        self.renamingFolderIDBinding = renamingFolderID
        self.renamingRepoIDBinding = renamingRepoID
    }

    // MARK: Item identity

    private func item(forFolder id: UUID) -> SidebarOutlineItem {
        let key = SidebarOutlineItem.Kind.folder(id)

        if let existing = itemCache[key] {
            return existing
        }

        let item = SidebarOutlineItem(kind: key)
        itemCache[key] = item
        return item
    }

    private func item(forRepo id: UUID) -> SidebarOutlineItem {
        let key = SidebarOutlineItem.Kind.repo(id)

        if let existing = itemCache[key] {
            return existing
        }

        let item = SidebarOutlineItem(kind: key)
        itemCache[key] = item
        return item
    }

    private func item(for entry: TopLevelEntry) -> SidebarOutlineItem {
        switch entry {
        case .folder(let id):
            return item(forFolder: id)
        case .repo(let id):
            return item(forRepo: id)
        }
    }

    private func children(ofFolder folderID: UUID) -> [SidebarRepo] {
        sidebarStore.repos
            .filter { $0.folderID == folderID }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    // MARK: Reload

    func reloadPreservingState() {
        guard let outlineView else { return }

        // `reloadData()` recreates every row's underlying item object (re-hosting every
        // `NSHostingView`), and can itself synchronously fire `outlineViewSelectionDidChange` for
        // the row that's already selected purely because of that — not because the user (or
        // `appState`) actually changed anything. Left unguarded, that spurious notification
        // reached `AppState.selectRepo(_:)` and ran its fully-synchronous `refreshRepositoryState()`
        // (branches, commits, status, a `git remote get-url origin` call) on the main thread —
        // confirmed via Instruments as a real source of hangs, and one that fired on *every*
        // re-render of this view (including ones triggered by unrelated state elsewhere in the
        // app, like a commit-history selection settling), not just actual repo switches.
        // `applySelectionFromAppState()` below is what authoritatively reconciles the selection
        // afterward, so nothing is lost by ignoring whatever `reloadData()` does on its own.
        //
        // This view also gets re-invoked on every `appState.selectedRepoURL` change (clicking a
        // different repo in the sidebar) even though the tree *shape* hasn't changed at all — only
        // rebuild rows when the structural state actually changed, since a full `reloadData()`
        // scales with total sidebar item count and was otherwise paid on every single click.
        let snapshot = StructureSnapshot(
            repos: sidebarStore.repos,
            folders: sidebarStore.folders,
            topLevelOrder: sidebarStore.topLevelOrder
        )
        if snapshot != lastStructureSnapshot {
            lastStructureSnapshot = snapshot

            isApplyingSelection = true
            outlineView.reloadData()
            isApplyingSelection = false

            for folder in sidebarStore.folders {
                let item = item(forFolder: folder.id)

                if folder.isExpanded {
                    outlineView.expandItem(item)
                } else {
                    outlineView.collapseItem(item)
                }
            }
        }

        applySelectionFromAppState()
    }

    private func applySelectionFromAppState() {
        guard let outlineView else { return }

        guard let url = appState.selectedRepoURL,
              let repo = sidebarStore.repos.first(where: { $0.url == url }) else {
            if outlineView.selectedRow >= 0 {
                isApplyingSelection = true
                outlineView.deselectAll(nil)
                isApplyingSelection = false
            }
            return
        }

        let item = item(forRepo: repo.id)
        let row = outlineView.row(forItem: item)

        guard row >= 0, outlineView.selectedRow != row else {
            return
        }

        isApplyingSelection = true
        outlineView.selectRowIndexes(
            IndexSet(integer: row),
            byExtendingSelection: false
        )
        isApplyingSelection = false
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        guard let item else {
            return sidebarStore.topLevelOrder.count
        }

        guard let boxed = item as? SidebarOutlineItem,
              case .folder(let id) = boxed.kind else {
            return 0
        }

        return children(ofFolder: id).count
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        guard let item else {
            return self.item(for: sidebarStore.topLevelOrder[index])
        }

        guard let boxed = item as? SidebarOutlineItem,
              case .folder(let id) = boxed.kind else {
            fatalError("Requested a child of a non-folder sidebar item")
        }

        return self.item(forRepo: children(ofFolder: id)[index].id)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        isItemExpandable item: Any
    ) -> Bool {
        guard let boxed = item as? SidebarOutlineItem else {
            return false
        }

        if case .folder = boxed.kind {
            return true
        }

        return false
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let boxed = item as? SidebarOutlineItem else {
            return nil
        }

        switch boxed.kind {
        case .folder(let id):
            guard let folder = sidebarStore.folders.first(where: { $0.id == id }) else {
                return nil
            }

            return makeFolderCell(
                folder: folder,
                outlineView: outlineView
            )

        case .repo(let id):
            guard let repo = sidebarStore.repos.first(where: { $0.id == id }) else {
                return nil
            }

            return makeRepoCell(
                repo: repo,
                outlineView: outlineView
            )
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        shouldSelectItem item: Any
    ) -> Bool {
        guard let boxed = item as? SidebarOutlineItem else {
            return false
        }

        if case .repo = boxed.kind {
            return true
        }

        return false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, let outlineView else {
            return
        }

        let row = outlineView.selectedRow

        guard row >= 0,
              let boxed = outlineView.item(atRow: row) as? SidebarOutlineItem,
              case .repo(let id) = boxed.kind,
              let repo = sidebarStore.repos.first(where: { $0.id == id }) else {
            return
        }

        appState.selectRepo(repo.url)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let boxed = notification.userInfo?["NSObject"] as? SidebarOutlineItem,
              case .folder(let id) = boxed.kind else {
            return
        }

        sidebarStore.setFolderExpanded(id: id, true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let boxed = notification.userInfo?["NSObject"] as? SidebarOutlineItem,
              case .folder(let id) = boxed.kind else {
            return
        }

        sidebarStore.setFolderExpanded(id: id, false)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        rowViewForItem item: Any
    ) -> NSTableRowView? {
        SidebarTableRowView()
    }

    /// Adds breathing room under each top-level group (folder), matching Finder/Mail-style
    /// sidebars — appended to whichever row currently draws last for that group: the folder's own
    /// row when collapsed or empty, otherwise its last visible child repo.
    func outlineView(
        _ outlineView: NSOutlineView,
        heightOfRowByItem item: Any
    ) -> CGFloat {
        isLastRowOfGroup(item, in: outlineView)
            ? SidebarLayout.rowHeight + SidebarLayout.groupSpacing
            : SidebarLayout.rowHeight
    }

    /// Whether `item` is the last row drawn for its top-level group (folder) — the folder's own
    /// row when collapsed or empty, otherwise its last visible child repo.
    private func isLastRowOfGroup(_ item: Any, in outlineView: NSOutlineView) -> Bool {
        guard let boxed = item as? SidebarOutlineItem else {
            return false
        }

        switch boxed.kind {
        case .folder(let id):
            return !outlineView.isItemExpanded(item) || children(ofFolder: id).isEmpty

        case .repo(let id):
            guard let repo = sidebarStore.repos.first(where: { $0.id == id }),
                  let folderID = repo.folderID else {
                return false
            }
            return children(ofFolder: folderID).last?.id == id
        }
    }

    // MARK: Drag and drop

    func outlineView(
        _ outlineView: NSOutlineView,
        pasteboardWriterForItem item: Any
    ) -> NSPasteboardWriting? {
        guard let boxed = item as? SidebarOutlineItem else {
            return nil
        }

        let payload: SidebarDragItem

        switch boxed.kind {
        case .folder(let id):
            payload = SidebarDragItem(kind: .folder, id: id)
        case .repo(let id):
            payload = SidebarDragItem(kind: .repo, id: id)
        }

        guard let data = try? JSONEncoder().encode(payload) else {
            return nil
        }

        let pbItem = NSPasteboardItem()
        pbItem.setData(data, forType: Self.pasteboardType)
        return pbItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let payload = draggedPayload(from: info) else {
            if draggedFolderURLs(from: info) != nil {
                // A drag from Finder always just adds top-level entries, regardless of which row
                // it's hovering — draw the "drop on the whole list" highlight rather than trying
                // to compute a specific insertion point.
                outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .copy
            }
            return []
        }

        guard let item else {
            return .move
        }

        guard let boxed = item as? SidebarOutlineItem else {
            return []
        }

        switch boxed.kind {
        case .repo(let repoID):
            // Repos aren't containers; redirect an ambiguous/"on" drop to a sibling position.
            redirectToSiblingPosition(
                after: repoID,
                outlineView: outlineView
            )
            return .move

        case .folder:
            return payload.kind == .repo ? .move : []
        }
    }

    private func redirectToSiblingPosition(
        after repoID: UUID,
        outlineView: NSOutlineView
    ) {
        guard let repo = sidebarStore.repos.first(where: { $0.id == repoID }) else {
            return
        }

        if let folderID = repo.folderID {
            let kids = children(ofFolder: folderID)

            guard let idx = kids.firstIndex(where: { $0.id == repoID }) else {
                return
            }

            outlineView.setDropItem(
                item(forFolder: folderID),
                dropChildIndex: idx + 1
            )
        } else {
            let entries = sidebarStore.topLevelOrder

            guard let idx = entries.firstIndex(of: .repo(repoID)) else {
                return
            }

            outlineView.setDropItem(
                nil,
                dropChildIndex: idx + 1
            )
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let payload = draggedPayload(from: info) else {
            guard let urls = draggedFolderURLs(from: info) else {
                return false
            }
            var rejectedNames: [String] = []
            var lastAddedURL: URL?
            for url in urls {
                if sidebarStore.addRepo(at: url) {
                    lastAddedURL = url
                } else {
                    rejectedNames.append(url.lastPathComponent)
                }
            }
            if let lastAddedURL {
                appState.selectRepo(lastAddedURL)
            }
            if !rejectedNames.isEmpty {
                appState.presentNotARepositoryAlert(for: rejectedNames)
            }
            return lastAddedURL != nil
        }

        let dragItem = SidebarDragItem(
            kind: payload.kind,
            id: payload.id
        )

        if let item,
           let boxed = item as? SidebarOutlineItem,
           case .folder(let folderID) = boxed.kind {
            guard payload.kind == .repo else {
                return false
            }

            if index == NSOutlineViewDropOnItemIndex {
                return sidebarStore.applyDrop(
                    dragItem,
                    target: .folderAppend(folderID)
                )
            }

            let kids = children(ofFolder: folderID)
            let beforeID = index >= 0 && index < kids.count
                ? kids[index].id
                : nil

            return sidebarStore.applyDrop(
                dragItem,
                target: .folderChild(
                    folderID: folderID,
                    before: beforeID
                )
            )
        } else {
            let entries = sidebarStore.topLevelOrder
            let beforeEntry: TopLevelEntry? =
                index >= 0 && index < entries.count
                    ? entries[index]
                    : nil

            return sidebarStore.applyDrop(
                dragItem,
                target: .topLevel(before: beforeEntry)
            )
        }
    }

    private func draggedPayload(
        from info: NSDraggingInfo
    ) -> SidebarDragItem? {
        guard let items = info.draggingPasteboard.pasteboardItems else {
            return nil
        }

        for item in items {
            if let data = item.data(forType: Self.pasteboardType),
               let payload = try? JSONDecoder().decode(
                SidebarDragItem.self,
                from: data
               ) {
                return payload
            }
        }

        return nil
    }

    /// Folder URLs from an external drag (e.g. Finder) — `nil` if the drag carries no
    /// folder-conforming file URLs at all, so callers can fall through to "not a drag we handle".
    private func draggedFolderURLs(from info: NSDraggingInfo) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingContentsConformToTypes: [UTType.folder.identifier]
        ]
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL], !urls.isEmpty else {
            return nil
        }
        return urls
    }

    // MARK: Cell building

    private func makeRepoCell(
        repo: SidebarRepo,
        outlineView: NSOutlineView
    ) -> NSView {
        // Identifier is unique per repo (not shared across all repo rows) so AppKit's view-reuse
        // pool never hands this repo's cell a different repo's stale SwiftUI @State (rename
        // draft text, focus) left over from a previous reload.
        let identifier = NSUserInterfaceItemIdentifier(
            "RepoCell-\(repo.id.uuidString)"
        )

        let content = RepoRowView(
            repo: repo,
            appState: appState,
            sidebarStore: sidebarStore,
            isRenaming: renamingRepoIDBinding.wrappedValue == repo.id,
            isLastInGroup: isLastRowOfGroup(item(forRepo: repo.id), in: outlineView),
            onStartRename: { [self] in
                renamingRepoIDBinding.wrappedValue = repo.id
            },
            onCommitRename: { [self] newName in
                let trimmed = newName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

                let override =
                    (trimmed.isEmpty || trimmed == repo.url.lastPathComponent)
                    ? nil
                    : trimmed

                sidebarStore.updateRepo(
                    id: repo.id,
                    displayName: override,
                    iconPath: repo.iconPath
                )

                renamingRepoIDBinding.wrappedValue = nil
            }
        )

        if let reused = outlineView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? NSHostingView<RepoRowView> {
            reused.rootView = content
            return reused
        }

        let hosting = NSHostingView(rootView: content)
        hosting.identifier = identifier
        hosting.autoresizingMask = [.width, .height]
        return hosting
    }

    private func makeFolderRowView(
        folder: SidebarFolder,
        isHovering: Bool
    ) -> FolderRowView {
        let isLastInGroup: Bool = {
            guard let outlineView else { return false }
            return isLastRowOfGroup(item(forFolder: folder.id), in: outlineView)
        }()

        return FolderRowView(
            folder: folder,
            repoCount: sidebarStore.repos.count {
                $0.folderID == folder.id
            },
            isRenaming: renamingFolderIDBinding.wrappedValue == folder.id,
            isHovering: isHovering,
            isLastInGroup: isLastInGroup,

            onToggle: { [self] in
                let item = self.item(forFolder: folder.id)

                guard let outlineView = self.outlineView else {
                    return
                }

                if outlineView.isItemExpanded(item) {
                    outlineView.collapseItem(item)
                } else {
                    outlineView.expandItem(item)
                }
            },

            onStartRename: { [self] in
                renamingFolderIDBinding.wrappedValue = folder.id
            },

            onCommitRename: { [self] newName in
                sidebarStore.renameFolder(
                    id: folder.id,
                    to: newName
                )

                renamingFolderIDBinding.wrappedValue = nil
            },

            onSort: { [self] in
                sidebarStore.sortRepos(inFolder: folder.id)
            },

            onAddRepo: { [self] in
                appState.addRepoViaPicker(intoFolder: folder.id)
            },

            onDelete: { [self] in
                requestDeleteFolder(folder)
            }
        )
    }

    private func requestDeleteFolder(_ folder: SidebarFolder) {
        let repoCount = sidebarStore.repos.count {
            $0.folderID == folder.id
        }

        guard repoCount > 0 else {
            sidebarStore.deleteFolder(id: folder.id)
            return
        }

        guard let window = outlineView?.window else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(folder.name)\u{201D}?"
        alert.informativeText =
            "This group contains \(repoCount) \(repoCount == 1 ? "repository" : "repositories"). You can delete them along with the group, or move them out to the top level first."

        alert.addButton(
            withTitle: "Delete \(repoCount == 1 ? "Repository" : "Repositories")"
        )
        alert.addButton(
            withTitle: "Move \(repoCount == 1 ? "It" : "Them") Out of Group"
        )
        alert.addButton(withTitle: "Cancel")

        alert.buttons[0].hasDestructiveAction = true

        alert.beginSheetModal(for: window) { [self] response in
            switch response {
            case .alertFirstButtonReturn:
                if let selectedURL = appState.selectedRepoURL,
                   sidebarStore.repos.contains(where: {
                       $0.folderID == folder.id && $0.url == selectedURL
                   }) {
                    appState.selectedRepoURL = nil
                }

                sidebarStore.deleteFolder(id: folder.id)

            case .alertSecondButtonReturn:
                sidebarStore.deleteFolderKeepingRepos(id: folder.id)

            default:
                break
            }
        }
    }

    private func makeFolderCell(
        folder: SidebarFolder,
        outlineView: NSOutlineView
    ) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier(
            "FolderCell-\(folder.id.uuidString)"
        )

        let isHovering = hoveredFolderIDs.contains(folder.id)
        let content = makeFolderRowView(
            folder: folder,
            isHovering: isHovering
        )

        let hosting: FolderHoverHostingView

        if let reused = outlineView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? FolderHoverHostingView {
            reused.rootView = content
            hosting = reused
        } else {
            hosting = FolderHoverHostingView(rootView: content)
            hosting.identifier = identifier
            hosting.autoresizingMask = [.width, .height]
        }

        hosting.onHoverChange = { [self] hovering in
            if hovering {
                hoveredFolderIDs.insert(folder.id)
            } else {
                hoveredFolderIDs.remove(folder.id)
            }

            hosting.rootView = makeFolderRowView(
                folder: folder,
                isHovering: hovering
            )
        }

        return hosting
    }
}
