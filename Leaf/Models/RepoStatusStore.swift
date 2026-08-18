import Foundation

/// Caches each sidebar repo's status-icon data (`GitRepository.SidebarSyncStatus`), keyed by repo
/// path. Deliberately *not* polled on a timer or re-checked on every repo/file selection — both
/// caused the icons to blink empty-then-back as a stale/nil value briefly showed before a fresh
/// git call landed. Instead:
/// - `AppState.refreshRepositoryState()`/`refreshSyncStatus()` write the selected repo's entry
///   here using data they already fetched for their own purposes (branches/commits/status), so
///   this never triggers an *extra* git call — it just keeps the cache warm for when that repo is
///   later deselected.
/// - `refreshAll(repos:)` is the only path that actively re-checks every repo, called from
///   `MainWindowController` on window refocus.
/// `setStatus`/`refresh` only publish a value that's actually different from what's cached, so a
/// row that hasn't changed never re-renders its icons.
@Observable
final class RepoStatusStore {
    private(set) var statuses: [String: GitRepository.SidebarSyncStatus] = [:]

    private var isRefreshingAll = false

    func setStatus(_ status: GitRepository.SidebarSyncStatus, forPath path: String) {
        guard statuses[path] != status else { return }
        statuses[path] = status
    }

    /// Re-checks every repo in `repos`, one at a time (plain `git status`/`rev-list` calls are
    /// cheap, but running them for every sidebar repo simultaneously would still burst a lot of
    /// processes at once). Coalesced: a refresh already in flight is left to finish rather than
    /// starting a redundant second pass.
    func refreshAll(repos: [SidebarRepo]) {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        let paths = repos.map(\.path)
        Task { [weak self] in
            for path in paths {
                await self?.refresh(path: path)
            }
            self?.isRefreshingAll = false
        }
    }

    /// Re-checks a single repo, e.g. right after a fetch/pull/push completes for it.
    func refresh(path: String) async {
        let url = URL(fileURLWithPath: path)
        let computed = await Task.detached(priority: .utility) {
            GitRepository(rootURL: url).sidebarSyncStatus()
        }.value
        setStatus(computed, forPath: path)
    }
}
