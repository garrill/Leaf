import Foundation
import Testing
@testable import Leaf

/// `SidebarStore.Snapshot.normalized()` — every repo must end up visible in the sidebar exactly
/// once, whatever state the saved data was left in.
@MainActor @Suite struct SidebarStoreInvariantTests {
    private func repo(_ path: String, folder: UUID? = nil, id: UUID = UUID()) -> SidebarRepo {
        SidebarRepo(id: id, path: path, displayNameOverride: nil, iconPath: nil, folderID: folder, sortIndex: 0)
    }

    /// The shown set, exactly as the outline builds it: top-level repo entries, plus each
    /// listed folder's children.
    private func shownRepoIDs(_ snapshot: SidebarStore.Snapshot) -> [UUID] {
        snapshot.topLevelOrder.flatMap { entry -> [UUID] in
            switch entry {
            case .repo(let id): return snapshot.repos.contains { $0.id == id && $0.folderID == nil } ? [id] : []
            case .folder(let folderID): return snapshot.repos.filter { $0.folderID == folderID }.map(\.id)
            }
        }
    }

    private func expectEveryRepoShownOnce(_ snapshot: SidebarStore.Snapshot) {
        let shown = shownRepoIDs(snapshot)
        #expect(shown.count == Set(shown).count)
        #expect(Set(shown) == Set(snapshot.repos.map(\.id)))
    }

    @Test func repoWithNoTopLevelSlotIsAppendedAtTheEnd() {
        let kept = repo("/kept")
        let orphan = repo("/orphan")
        let snapshot = SidebarStore.Snapshot(repos: [orphan, kept], folders: [], topLevelOrder: [.repo(kept.id)])
        let fixed = snapshot.normalized()
        #expect(fixed.topLevelOrder == [.repo(kept.id), .repo(orphan.id)])
        expectEveryRepoShownOnce(fixed)
    }

    @Test func repoInADeletedFolderMovesToTheTopLevel() {
        let stranded = repo("/stranded", folder: UUID())
        let fixed = SidebarStore.Snapshot(repos: [stranded], folders: [], topLevelOrder: []).normalized()
        #expect(fixed.repos.first?.folderID == nil)
        #expect(fixed.topLevelOrder == [.repo(stranded.id)])
        expectEveryRepoShownOnce(fixed)
    }

    @Test func folderMissingFromTheOrderIsAppended() {
        let folder = SidebarFolder(id: UUID(), name: "Apps")
        let child = repo("/child", folder: folder.id)
        let fixed = SidebarStore.Snapshot(repos: [child], folders: [folder], topLevelOrder: []).normalized()
        #expect(fixed.topLevelOrder == [.folder(folder.id)])
        expectEveryRepoShownOnce(fixed)
    }

    @Test func staleDuplicateAndContradictoryEntriesAreDropped() {
        let folder = SidebarFolder(id: UUID(), name: "Apps")
        let inFolder = repo("/in-folder", folder: folder.id)
        let top = repo("/top")
        let snapshot = SidebarStore.Snapshot(
            repos: [inFolder, top],
            folders: [folder],
            topLevelOrder: [.repo(top.id), .repo(UUID()), .folder(UUID()), .folder(folder.id), .repo(top.id), .repo(inFolder.id)]
        )
        let fixed = snapshot.normalized()
        #expect(fixed.topLevelOrder == [.repo(top.id), .folder(folder.id)])
        expectEveryRepoShownOnce(fixed)
    }

    @Test func duplicateReposByIdOrPathKeepTheFirst() {
        let id = UUID()
        let first = repo("/a", id: id)
        let snapshot = SidebarStore.Snapshot(
            repos: [first, repo("/b", id: id), repo("/a")],
            folders: [],
            topLevelOrder: [.repo(id)]
        )
        let fixed = snapshot.normalized()
        #expect(fixed.repos == [first])
        expectEveryRepoShownOnce(fixed)
    }

    @Test func validStateIsLeftUntouched() {
        let folder = SidebarFolder(id: UUID(), name: "Apps")
        let snapshot = SidebarStore.Snapshot(
            repos: [repo("/a"), repo("/b", folder: folder.id)],
            folders: [folder],
            topLevelOrder: []
        )
        let valid = snapshot.normalized()
        #expect(valid.normalized() == valid)
    }
}
