import Foundation

/// Most-recently-opened repo paths, newest first — backs the command palette's empty-query
/// suggestions. Deliberately separate from `SidebarRepo`/`SidebarStore`: mutating
/// `sidebarStore.repos` on every repo switch would trigger a sidebar outline reload for what's
/// purely palette metadata.
final class RecentReposStore {
    static let defaultsKey = "recentRepoPaths"
    static let capacity = 20

    private let defaults: UserDefaults
    private(set) var paths: [String]

    init(defaults: UserDefaults = LeafSettings.store) {
        self.defaults = defaults
        paths = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func recordOpened(path: String) {
        guard paths.first != path else { return }
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > Self.capacity {
            paths.removeLast(paths.count - Self.capacity)
        }
        defaults.set(paths, forKey: Self.defaultsKey)
    }

    /// Up to `limit` of `repos`, most recently opened first, skipping `excludingPath` (the
    /// currently open repo — switching to it would be a no-op). Paths no longer in the sidebar
    /// are dropped; if fewer than `limit` have ever been opened, the rest are filled in sidebar
    /// order so the palette never opens emptier than it needs to. Repos whose folder no longer
    /// exists on disk are never suggested.
    func recent(
        from repos: [SidebarRepo],
        limit: Int,
        excludingPath: String?,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [SidebarRepo] {
        let byPath = Dictionary(repos.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [SidebarRepo] = []
        var seen = Set<String>()
        if let excludingPath { seen.insert(excludingPath) }
        for path in paths where result.count < limit {
            guard !seen.contains(path), let repo = byPath[path], exists(path) else { continue }
            seen.insert(path)
            result.append(repo)
        }
        for repo in repos where result.count < limit && !seen.contains(repo.path) && exists(repo.path) {
            seen.insert(repo.path)
            result.append(repo)
        }
        return result
    }
}
