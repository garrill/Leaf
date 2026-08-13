import Foundation
import SwiftUI

@Observable
final class SidebarStore {
    private(set) var repos: [SidebarRepo] = []
    private(set) var folders: [SidebarFolder] = []
    private(set) var topLevelOrder: [TopLevelEntry] = []

    private let defaultsKey = "sidebarState.v2"
    private let legacyDefaultsKey = "repoPaths"

    private struct Snapshot: Codable {
        var repos: [SidebarRepo]
        var folders: [SidebarFolder]
        var topLevelOrder: [TopLevelEntry]
    }

    init() {
        load()
    }

    // MARK: Repo CRUD

    /// Adds `url` as a repo, returning `false` (and not adding it) if it isn't a git repository.
    /// Already-added repos report `true` without duplicating the entry.
    @discardableResult
    func addRepo(at url: URL) -> Bool {
        guard GitRepository.isGitRepository(at: url) else { return false }
        guard !repos.contains(where: { $0.path == url.path }) else { return true }
        let repo = SidebarRepo(id: UUID(), path: url.path, displayNameOverride: nil, iconPath: nil, folderID: nil, sortIndex: 0)
        repos.append(repo)
        topLevelOrder.append(.repo(repo.id))
        persist()
        return true
    }

    func removeRepo(id: UUID) {
        repos.removeAll { $0.id == id }
        topLevelOrder.removeAll { if case .repo(let rid) = $0 { return rid == id }; return false }
        persist()
    }

    func updateRepo(id: UUID, displayName: String?, iconPath: String?) {
        guard let idx = repos.firstIndex(where: { $0.id == id }) else { return }
        repos[idx].displayNameOverride = displayName
        repos[idx].iconPath = iconPath
        persist()
    }

    /// Moves a repo to the top level, inserted immediately before `target` (nil = append at the end).
    func moveRepoToTopLevel(id: UUID, before target: TopLevelEntry?) {
        guard let repoIdx = repos.firstIndex(where: { $0.id == id }) else { return }
        if target == .repo(id) { return }

        repos[repoIdx].folderID = nil
        topLevelOrder.removeAll { if case .repo(let rid) = $0 { return rid == id }; return false }

        if let target, let idx = topLevelOrder.firstIndex(of: target) {
            topLevelOrder.insert(.repo(id), at: idx)
        } else {
            topLevelOrder.append(.repo(id))
        }
        persist()
    }

    /// Moves a repo into `folderID`, inserted immediately before the sibling `beforeRepoID` (nil = append at the end).
    func moveRepo(id: UUID, intoFolder folderID: UUID, before beforeRepoID: UUID?) {
        guard let repoIdx = repos.firstIndex(where: { $0.id == id }) else { return }
        if beforeRepoID == id { return }

        if repos[repoIdx].folderID == nil {
            topLevelOrder.removeAll { if case .repo(let rid) = $0 { return rid == id }; return false }
        }
        repos[repoIdx].folderID = folderID

        var siblingIDs = repos
            .filter { $0.folderID == folderID && $0.id != id }
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(\.id)
        let insertAt = beforeRepoID.flatMap { siblingIDs.firstIndex(of: $0) } ?? siblingIDs.count
        siblingIDs.insert(id, at: insertAt)
        for (i, rid) in siblingIDs.enumerated() {
            if let idx = repos.firstIndex(where: { $0.id == rid }) {
                repos[idx].sortIndex = i
            }
        }
        persist()
    }

    // MARK: Folder CRUD

    @discardableResult
    func addFolder(name: String = "New Group") -> UUID {
        let folder = SidebarFolder(id: UUID(), name: name, isExpanded: true)
        folders.append(folder)
        topLevelOrder.append(.folder(folder.id))
        persist()
        return folder.id
    }

    func renameFolder(id: UUID, to name: String) {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folders[idx].name = trimmed
        persist()
    }

    /// Deletes the folder and every repo inside it.
    func deleteFolder(id: UUID) {
        folders.removeAll { $0.id == id }
        repos.removeAll { $0.folderID == id }
        topLevelOrder.removeAll { if case .folder(let fid) = $0 { return fid == id }; return false }
        persist()
    }

    /// Deletes the folder but keeps its repos, promoting them to the top level in place of the folder.
    func deleteFolderKeepingRepos(id: UUID) {
        guard let folderIdx = topLevelOrder.firstIndex(of: .folder(id)) else {
            deleteFolder(id: id)
            return
        }
        let childIDs = children(ofFolder: id).map(\.id)
        for repoID in childIDs {
            if let idx = repos.firstIndex(where: { $0.id == repoID }) {
                repos[idx].folderID = nil
            }
        }
        topLevelOrder.remove(at: folderIdx)
        topLevelOrder.insert(contentsOf: childIDs.map { .repo($0) }, at: folderIdx)
        folders.removeAll { $0.id == id }
        persist()
    }

    private func children(ofFolder folderID: UUID) -> [SidebarRepo] {
        repos
            .filter { $0.folderID == folderID }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Reassigns `sortIndex` for every repo directly inside `folderID` so they land in
    /// alphabetical order by `displayName` (case-insensitive, locale-aware).
    func sortRepos(inFolder folderID: UUID) {
        let sortedIDs = children(ofFolder: folderID)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map(\.id)
        for (i, id) in sortedIDs.enumerated() {
            if let idx = repos.firstIndex(where: { $0.id == id }) {
                repos[idx].sortIndex = i
            }
        }
        persist()
    }

    func setFolderExpanded(id: UUID, _ expanded: Bool) {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[idx].isExpanded = expanded
        persist()
    }

    // MARK: Reordering

    /// Moves a folder within the top level, inserted immediately before `target` (nil = append at the end).
    func moveFolder(id: UUID, before target: TopLevelEntry?) {
        let entry = TopLevelEntry.folder(id)
        if target == entry { return }
        topLevelOrder.removeAll { $0 == entry }
        if let target, let idx = topLevelOrder.firstIndex(of: target) {
            topLevelOrder.insert(entry, at: idx)
        } else {
            topLevelOrder.append(entry)
        }
        persist()
    }

    /// Applies a drag-and-drop move for `item` to `target`. Invalid combinations (e.g. nesting a folder
    /// into another folder) are silently ignored.
    @discardableResult
    func applyDrop(_ item: SidebarDragItem, target: SidebarDropTarget) -> Bool {
        switch (item.kind, target) {
        case (.repo, .topLevel(let before)):
            moveRepoToTopLevel(id: item.id, before: before)
            return true
        case (.repo, .folderAppend(let folderID)):
            moveRepo(id: item.id, intoFolder: folderID, before: nil)
            return true
        case (.repo, .folderChild(let folderID, let before)):
            moveRepo(id: item.id, intoFolder: folderID, before: before)
            return true
        case (.folder, .topLevel(let before)):
            moveFolder(id: item.id, before: before)
            return true
        case (.folder, .folderAppend), (.folder, .folderChild):
            return false
        }
    }

    // MARK: Persistence

    private func persist() {
        let snapshot = Snapshot(repos: repos, folders: folders, topLevelOrder: topLevelOrder)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            repos = snapshot.repos
            folders = snapshot.folders
            topLevelOrder = snapshot.topLevelOrder
        } else {
            migrate()
        }
    }

    private func migrate() {
        let paths = UserDefaults.standard.stringArray(forKey: legacyDefaultsKey) ?? []
        repos = paths.enumerated().map { index, path in
            SidebarRepo(id: UUID(), path: path, displayNameOverride: nil, iconPath: nil, folderID: nil, sortIndex: index)
        }
        folders = []
        topLevelOrder = repos.map { .repo($0.id) }
        persist()
    }
}
