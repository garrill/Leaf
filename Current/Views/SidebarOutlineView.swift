import AppKit
import SwiftUI

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
        outlineView.rowHeight = 36
        outlineView.backgroundColor = .clear
        outlineView.allowsMultipleSelection = false
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.registerForDraggedTypes([SidebarOutlineCoordinator.pasteboardType])
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

/// Draws the selection highlight inset from the leading edge for rows nested inside a folder,
/// so the selection pill starts at the item's own indentation rather than the outline view's edge.
final class SidebarTableRowView: NSTableRowView {
    var leadingInset: CGFloat = 0

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        var rect = bounds.insetBy(dx: 4, dy: 2)
        rect.origin.x += leadingInset
        rect.size.width -= leadingInset
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        color.setFill()
        path.fill()
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

    private var sidebarStore: SidebarStore { appState.sidebarStore }

    init(appState: AppState, renamingFolderID: Binding<UUID?>, renamingRepoID: Binding<UUID?>) {
        self.appState = appState
        self.renamingFolderIDBinding = renamingFolderID
        self.renamingRepoIDBinding = renamingRepoID
    }

    // MARK: Item identity

    private func item(forFolder id: UUID) -> SidebarOutlineItem {
        let key = SidebarOutlineItem.Kind.folder(id)
        if let existing = itemCache[key] { return existing }
        let item = SidebarOutlineItem(kind: key)
        itemCache[key] = item
        return item
    }

    private func item(forRepo id: UUID) -> SidebarOutlineItem {
        let key = SidebarOutlineItem.Kind.repo(id)
        if let existing = itemCache[key] { return existing }
        let item = SidebarOutlineItem(kind: key)
        itemCache[key] = item
        return item
    }

    private func item(for entry: TopLevelEntry) -> SidebarOutlineItem {
        switch entry {
        case .folder(let id): return item(forFolder: id)
        case .repo(let id): return item(forRepo: id)
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
        // `reloadData()` recreates every row's underlying item object, and can itself
        // synchronously fire `outlineViewSelectionDidChange` for the row that's already
        // selected purely because of that — not because the user (or `appState`) actually
        // changed anything. Left unguarded, that spurious notification reached
        // `AppState.selectRepo(_:)` and ran its fully-synchronous `refreshRepositoryState()`
        // (branches, commits, status, a `git remote get-url origin` call) on the main thread —
        // confirmed via Instruments as a real source of hangs, and one that fired on *every*
        // re-render of this view (including ones triggered by unrelated state elsewhere in the
        // app, like a commit-history selection settling), not just actual repo switches.
        // `applySelectionFromAppState()` below is what authoritatively reconciles the selection
        // afterward, so nothing is lost by ignoring whatever `reloadData()` does on its own.
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
        guard row >= 0, outlineView.selectedRow != row else { return }
        isApplyingSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isApplyingSelection = false
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return sidebarStore.topLevelOrder.count }
        guard let boxed = item as? SidebarOutlineItem, case .folder(let id) = boxed.kind else { return 0 }
        return children(ofFolder: id).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return self.item(for: sidebarStore.topLevelOrder[index]) }
        guard let boxed = item as? SidebarOutlineItem, case .folder(let id) = boxed.kind else {
            fatalError("Requested a child of a non-folder sidebar item")
        }
        return self.item(forRepo: children(ofFolder: id)[index].id)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let boxed = item as? SidebarOutlineItem else { return false }
        if case .folder = boxed.kind { return true }
        return false
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let boxed = item as? SidebarOutlineItem else { return nil }
        switch boxed.kind {
        case .folder(let id):
            guard let folder = sidebarStore.folders.first(where: { $0.id == id }) else { return nil }
            return makeFolderCell(folder: folder, outlineView: outlineView)
        case .repo(let id):
            guard let repo = sidebarStore.repos.first(where: { $0.id == id }) else { return nil }
            return makeRepoCell(repo: repo, outlineView: outlineView)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let boxed = item as? SidebarOutlineItem else { return false }
        if case .repo = boxed.kind { return true }
        return false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, let outlineView else { return }
        let row = outlineView.selectedRow
        guard row >= 0,
              let boxed = outlineView.item(atRow: row) as? SidebarOutlineItem,
              case .repo(let id) = boxed.kind,
              let repo = sidebarStore.repos.first(where: { $0.id == id }) else { return }
        appState.selectRepo(repo.url)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let boxed = notification.userInfo?["NSObject"] as? SidebarOutlineItem,
              case .folder(let id) = boxed.kind else { return }
        sidebarStore.setFolderExpanded(id: id, true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let boxed = notification.userInfo?["NSObject"] as? SidebarOutlineItem,
              case .folder(let id) = boxed.kind else { return }
        sidebarStore.setFolderExpanded(id: id, false)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = SidebarTableRowView()
        if let boxed = item as? SidebarOutlineItem,
           case .repo(let id) = boxed.kind,
           let repo = sidebarStore.repos.first(where: { $0.id == id }),
           repo.folderID != nil {
            rowView.leadingInset = 20
        }
        return rowView
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let boxed = item as? SidebarOutlineItem else { return nil }
        let payload: SidebarDragItem
        switch boxed.kind {
        case .folder(let id): payload = SidebarDragItem(kind: .folder, id: id)
        case .repo(let id): payload = SidebarDragItem(kind: .repo, id: id)
        }
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
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
        guard let payload = draggedPayload(from: info) else { return [] }

        guard let item else { return .move } // top level: both repos and folders are valid there

        guard let boxed = item as? SidebarOutlineItem else { return [] }
        switch boxed.kind {
        case .repo(let repoID):
            // Repos aren't containers; redirect an ambiguous/"on" drop to a sibling position.
            redirectToSiblingPosition(after: repoID, outlineView: outlineView)
            return .move
        case .folder:
            return payload.kind == .repo ? .move : [] // folders can't nest inside folders
        }
    }

    private func redirectToSiblingPosition(after repoID: UUID, outlineView: NSOutlineView) {
        guard let repo = sidebarStore.repos.first(where: { $0.id == repoID }) else { return }
        if let folderID = repo.folderID {
            let kids = children(ofFolder: folderID)
            guard let idx = kids.firstIndex(where: { $0.id == repoID }) else { return }
            outlineView.setDropItem(item(forFolder: folderID), dropChildIndex: idx + 1)
        } else {
            let entries = sidebarStore.topLevelOrder
            guard let idx = entries.firstIndex(of: .repo(repoID)) else { return }
            outlineView.setDropItem(nil, dropChildIndex: idx + 1)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let payload = draggedPayload(from: info) else { return false }
        let dragItem = SidebarDragItem(kind: payload.kind, id: payload.id)

        if let item, let boxed = item as? SidebarOutlineItem, case .folder(let folderID) = boxed.kind {
            guard payload.kind == .repo else { return false }
            if index == NSOutlineViewDropOnItemIndex {
                return sidebarStore.applyDrop(dragItem, target: .folderAppend(folderID))
            }
            let kids = children(ofFolder: folderID)
            let beforeID = index >= 0 && index < kids.count ? kids[index].id : nil
            return sidebarStore.applyDrop(dragItem, target: .folderChild(folderID: folderID, before: beforeID))
        } else {
            let entries = sidebarStore.topLevelOrder
            let beforeEntry: TopLevelEntry? = index >= 0 && index < entries.count ? entries[index] : nil
            return sidebarStore.applyDrop(dragItem, target: .topLevel(before: beforeEntry))
        }
    }

    private func draggedPayload(from info: NSDraggingInfo) -> SidebarDragItem? {
        guard let items = info.draggingPasteboard.pasteboardItems else { return nil }
        for item in items {
            if let data = item.data(forType: Self.pasteboardType),
               let payload = try? JSONDecoder().decode(SidebarDragItem.self, from: data) {
                return payload
            }
        }
        return nil
    }

    // MARK: Cell building

    private func makeRepoCell(repo: SidebarRepo, outlineView: NSOutlineView) -> NSView {
        // Identifier is unique per repo (not shared across all repo rows) so AppKit's view-reuse
        // pool never hands this repo's cell a different repo's stale SwiftUI @State (rename
        // draft text, focus) left over from a previous reload.
        let identifier = NSUserInterfaceItemIdentifier("RepoCell-\(repo.id.uuidString)")
        let content = RepoRowView(
            repo: repo,
            appState: appState,
            sidebarStore: sidebarStore,
            isRenaming: renamingRepoIDBinding.wrappedValue == repo.id,
            onStartRename: { [self] in renamingRepoIDBinding.wrappedValue = repo.id },
            onCommitRename: { [self] newName in
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                let override = (trimmed.isEmpty || trimmed == repo.url.lastPathComponent) ? nil : trimmed
                sidebarStore.updateRepo(id: repo.id, displayName: override, iconPath: repo.iconPath)
                renamingRepoIDBinding.wrappedValue = nil
            }
        )
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSHostingView<RepoRowView> {
            reused.rootView = content
            return reused
        }
        let hosting = NSHostingView(rootView: content)
        hosting.identifier = identifier
        hosting.autoresizingMask = [.width, .height]
        return hosting
    }

    private func makeFolderCell(folder: SidebarFolder, outlineView: NSOutlineView) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("FolderCell-\(folder.id.uuidString)")
        let content = FolderRowView(
            folder: folder,
            repoCount: sidebarStore.repos.count { $0.folderID == folder.id },
            isRenaming: renamingFolderIDBinding.wrappedValue == folder.id,
            onToggle: { [self] in
                let item = self.item(forFolder: folder.id)
                guard let outlineView = self.outlineView else { return }
                if outlineView.isItemExpanded(item) {
                    outlineView.collapseItem(item)
                } else {
                    outlineView.expandItem(item)
                }
            },
            onStartRename: { [self] in renamingFolderIDBinding.wrappedValue = folder.id },
            onCommitRename: { [self] newName in
                sidebarStore.renameFolder(id: folder.id, to: newName)
                renamingFolderIDBinding.wrappedValue = nil
            },
            onDelete: { [self] in
                if let selectedURL = appState.selectedRepoURL,
                   sidebarStore.repos.contains(where: { $0.folderID == folder.id && $0.url == selectedURL }) {
                    appState.selectedRepoURL = nil
                }
                sidebarStore.deleteFolder(id: folder.id)
            }
        )
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSHostingView<FolderRowView> {
            reused.rootView = content
            return reused
        }
        let hosting = NSHostingView(rootView: content)
        hosting.identifier = identifier
        hosting.autoresizingMask = [.width, .height]
        return hosting
    }
}
