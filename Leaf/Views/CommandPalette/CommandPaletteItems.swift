import AppKit
import Foundation
import Sparkle

/// Builds the palette's full item list from what `AppState` already holds in memory — no git
/// calls — so opening the palette is instant. Each command calls the same `AppState` entry point
/// as its menu-bar/toolbar/context-menu counterpart (see `LeafApp`'s `.commands`), and is left
/// out entirely when it wouldn't apply right now rather than shown disabled.
enum CommandPaletteItems {
    static let suggestionCount = 3

    static func build(appState: AppState) -> (items: [PaletteItem], suggestions: [PaletteItem]) {
        let repos = appState.sidebarStore.repos
        let currentPath = appState.selectedRepoURL?.path
        let recentRank = Dictionary(
            appState.recentRepos.paths.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var items: [PaletteItem] = []
        var repoItemsByPath: [String: PaletteItem] = [:]

        for repo in repos {
            let isCurrent = repo.path == currentPath
            // Recent repos win ties against other repos; the open one ranks lowest since
            // switching to it does nothing.
            var boost = 40
            if let rank = recentRank[repo.path] { boost += max(0, 30 - rank * 3) }
            if isCurrent { boost = 0 }
            let isMissing = !FileManager.default.fileExists(atPath: repo.path)
            if isMissing { boost = -200 }
            let url = repo.url
            let item = PaletteItem(
                id: "repo:\(repo.id)",
                kind: .repo(repo),
                title: repo.displayName,
                subtitle: isMissing ? "Folder not found" : nil,
                symbol: "book.closed.fill",
                keywords: repo.displayNameOverride != nil ? [url.lastPathComponent] : [],
                boost: boost,
                perform: { [weak appState] in appState?.selectRepo(url) }
            )
            items.append(item)
            repoItemsByPath[repo.path] = item
        }

        let scope = appState.selectedRepoURL.map { url in
            repos.first { $0.url == url }?.displayName ?? url.lastPathComponent
        }
        if let scope {
            items += branchItems(appState: appState, scope: scope)
            items += gitCommandItems(appState: appState, scope: scope)
        }
        items += menuCommandItems(appState: appState, scope: scope)

        let suggestions = appState.recentRepos
            .recent(from: repos, limit: suggestionCount, excludingPath: currentPath)
            .compactMap { repoItemsByPath[$0.path] }

        return (items, suggestions)
    }

    // MARK: - Branches

    private static func branchItems(appState: AppState, scope: String) -> [PaletteItem] {
        guard !appState.isRepositoryBusy else { return [] }
        var items: [PaletteItem] = []
        for branch in appState.branches where !branch.isCurrent {
            items.append(PaletteItem(
                id: "branch:\(branch.name)",
                kind: .branch,
                title: branch.name,
                scope: scope,
                subtitle: "Switch to branch",
                symbol: "arrow.triangle.branch",
                keywords: ["checkout", "switch", "branch"],
                perform: { [weak appState] in appState?.selectBranch(branch) }
            ))
        }
        for remote in appState.remoteOnlyBranches {
            items.append(PaletteItem(
                id: "remote:\(remote.upstreamRef)",
                kind: .branch,
                title: remote.name,
                scope: scope,
                subtitle: "Check out \(remote.upstreamRef)",
                symbol: "icloud.and.arrow.down",
                keywords: ["checkout", "remote", "branch"],
                boost: -10,
                perform: { [weak appState] in appState?.checkoutRemoteBranch(remote) }
            ))
        }
        return items
    }

    // MARK: - Git commands

    private static func gitCommandItems(appState: AppState, scope: String) -> [PaletteItem] {
        guard !appState.isRepositoryBusy else { return [] }
        var items: [PaletteItem] = []
        func add(
            _ title: String,
            subtitle: String? = nil,
            symbol: String,
            shortcut: String? = nil,
            keywords: [String] = [],
            _ perform: @escaping (AppState) -> Void
        ) {
            items.append(PaletteItem(
                id: "git:\(title)",
                kind: .command,
                title: title,
                scope: scope,
                subtitle: subtitle,
                symbol: symbol,
                shortcut: shortcut,
                keywords: keywords + ["git"],
                boost: 20,
                perform: { [weak appState] in appState.map(perform) }
            ))
        }

        let branchName = appState.selectedBranch?.name
        add(
            "Push",
            subtitle: appState.aheadCount > 0 ? countLabel(appState.aheadCount, "commit to push", "commits to push") : branchName.map { "Push \($0)" },
            symbol: "arrow.up",
            shortcut: "⌘P",
            keywords: ["upload", "send"]
        ) { $0.pushCurrentBranch() }
        add(
            "Pull",
            subtitle: appState.behindCount > 0 ? countLabel(appState.behindCount, "commit behind", "commits behind") : branchName.map { "Pull \($0)" },
            symbol: "arrow.down",
            shortcut: "⇧⌘P",
            keywords: ["download", "update"]
        ) { $0.pullCurrentBranch() }
        add("Fetch", symbol: "arrow.trianglehead.2.clockwise", shortcut: "⇧⌘T", keywords: ["refresh", "remote"]) { $0.fetchRemote() }

        let message = appState.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if appState.selectedSource == .workingChanges, !message.isEmpty, !appState.checkedFilePaths.isEmpty {
            add(
                appState.isMergeInProgress ? "Complete Merge" : "Commit",
                subtitle: "\u{201C}\(message)\u{201D} · \(countLabel(appState.checkedFilePaths.count, "file", "files"))",
                symbol: "checkmark.circle",
                keywords: ["save"]
            ) { $0.commitOrCompleteMerge() }
        }

        if appState.uncommittedChangeCount > 0 {
            add("Stash All Changes", subtitle: countLabel(appState.uncommittedChangeCount, "change", "changes"), symbol: "tray.and.arrow.down", keywords: ["shelve", "save"]) { $0.stashAllChanges() }
            add("Discard All Changes…", symbol: "trash", keywords: ["reset", "revert", "clean"]) { $0.discardAllChanges() }
        }
        if appState.stashCount > 0 {
            add("Restore Stash", subtitle: countLabel(appState.stashFileCount, "file", "files"), symbol: "tray.and.arrow.up", keywords: ["pop", "apply", "unstash"]) { $0.restoreStash() }
            add("Discard Stash…", symbol: "tray.full", keywords: ["drop", "delete"]) { $0.discardStash() }
        }

        add("New Branch…", symbol: "plus", keywords: ["create", "branch"]) { $0.isNewBranchSheetPresented = true }
        if let head = appState.commits.first {
            add("New Tag…", subtitle: "On \(head.shortSha) \(head.summary)", symbol: "tag", keywords: ["create", "release", "version"]) { state in
                state.newTagTargetCommit = head
                state.isNewTagSheetPresented = true
            }
        }
        if appState.isMergeInProgress {
            add("Abort Merge", symbol: "xmark.circle", keywords: ["cancel", "merge"]) { $0.abortMerge() }
        } else {
            add("Merge…", symbol: "arrow.triangle.merge", keywords: ["combine", "integrate"]) { $0.openMergeSheet(prefilledOtherBranch: nil) }
        }
        add("Prune Gone Branches", subtitle: "Delete local branches whose upstream is gone", symbol: "scissors", keywords: ["clean", "delete", "branches"]) { $0.pruneGoneBranches() }
        return items
    }

    // MARK: - Menu bar

    private static func menuCommandItems(appState: AppState, scope: String?) -> [PaletteItem] {
        var items: [PaletteItem] = []
        func add(
            _ title: String,
            scope: String? = nil,
            menu: String? = nil,
            symbol: String,
            shortcut: String? = nil,
            keywords: [String] = [],
            _ perform: @escaping () -> Void
        ) {
            items.append(PaletteItem(
                id: "menu:\(title)",
                kind: .command,
                title: title,
                scope: scope,
                menuPath: menu,
                symbol: symbol,
                shortcut: shortcut,
                keywords: keywords,
                perform: perform
            ))
        }

        add("Add Repository…", menu: "File", symbol: "plus.rectangle.on.folder", shortcut: "⌘O", keywords: ["open", "import"]) { [weak appState] in appState?.addRepoViaPicker() }
        add("Clone Repository…", menu: "File", symbol: "square.and.arrow.down", shortcut: "⇧⌘O", keywords: ["download", "github"]) { [weak appState] in appState?.isCloneSheetPresented = true }

        if let scope {
            add("Show in Finder", scope: scope, symbol: "folder", shortcut: "⇧⌘F", keywords: ["reveal"]) { [weak appState] in appState?.revealSelectedRepoInFinder() }
            let editorPath = LeafSettings.store.string(forKey: LeafSettings.externalEditorPathKey) ?? ""
            add(LeafSettings.openInApplicationTitle(editorPath: editorPath), scope: scope, symbol: "arrow.up.forward.app", shortcut: "⇧⌘A", keywords: ["editor", "open"]) { [weak appState] in appState?.openSelectedRepoInDefaultApplication() }
            add("Rename", scope: scope, symbol: "pencil", keywords: ["name", "repository"]) { [weak appState] in appState?.startRenamingSelectedRepo() }
            add("Choose Icon…", scope: scope, symbol: "photo", keywords: ["image", "icon", "repository"]) { [weak appState] in appState?.chooseIconForSelectedRepo() }
            add("Remove…", scope: scope, symbol: "minus.circle", shortcut: "⌘⌫", keywords: ["delete", "repository"]) { [weak appState] in appState?.removeSelectedRepo() }
            add("Find in Diff", scope: scope, symbol: "magnifyingglass", shortcut: "⌘F", keywords: ["search"]) { [weak appState] in appState?.showDiffFind() }
        }

        add(SidebarVisibility.shared.isCollapsed ? "Show Sidebar" : "Hide Sidebar", menu: "View", symbol: "sidebar.left", shortcut: "⌃⌘S") {
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        }
        for toggle in viewToggles {
            let isOn = LeafSettings.store.object(forKey: toggle.key) as? Bool ?? toggle.defaultValue
            add(isOn ? toggle.onTitle : toggle.offTitle, menu: "View", symbol: toggle.symbol, keywords: ["view", "toggle"]) {
                LeafSettings.store.set(!isOn, forKey: toggle.key)
            }
        }

        add("Settings…", menu: "Leaf", symbol: "gearshape", shortcut: "⌘,", keywords: ["preferences"]) { openSettings() }
        if UpdaterHolder.shared.updater.canCheckForUpdates {
            add("Check for Updates…", menu: "Leaf", symbol: "arrow.down.circle", keywords: ["upgrade", "version"]) { UpdaterHolder.shared.checkForUpdates(nil) }
        }
        add("Leaf Help", menu: "Help", symbol: "questionmark.circle", keywords: ["docs", "readme"]) { NSWorkspace.shared.open(AppLinks.helpURL) }
        add("Report an Issue…", menu: "Help", symbol: "exclamationmark.bubble", keywords: ["bug", "feedback"]) { NSWorkspace.shared.open(AppLinks.issuesURL) }
        return items
    }

    /// The View menu's on/off items (`LeafApp`'s `CommandGroup(replacing: .sidebar)`), with the
    /// same titles and the same `LeafSettings` keys, so toggling here updates the menu's
    /// `@AppStorage` too.
    private struct ViewToggle {
        let key: String
        let defaultValue: Bool
        let onTitle: String
        let offTitle: String
        let symbol: String
    }

    private static let viewToggles: [ViewToggle] = [
        ViewToggle(key: LeafSettings.showRepoStatusKey, defaultValue: LeafSettings.defaultShowRepoStatus, onTitle: "Hide Repository Status", offTitle: "Show Repository Status", symbol: "circle.fill"),
        ViewToggle(key: LeafSettings.showFullCommitTitleKey, defaultValue: LeafSettings.defaultShowFullCommitTitle, onTitle: "Truncate Commit Message", offTitle: "Show Full Commit Message", symbol: "text.alignleft"),
        ViewToggle(key: LeafSettings.showCommitDescriptionKey, defaultValue: LeafSettings.defaultShowCommitDescription, onTitle: "Hide Commit Description", offTitle: "Show Commit Description", symbol: "text.below.photo"),
        ViewToggle(key: LeafSettings.syntaxHighlightingEnabledKey, defaultValue: LeafSettings.defaultSyntaxHighlightingEnabled, onTitle: "Disable Syntax Highlighting", offTitle: "Enable Syntax Highlighting", symbol: "paintbrush"),
        ViewToggle(key: LeafSettings.hideWhitespaceChangesKey, defaultValue: LeafSettings.defaultHideWhitespaceChanges, onTitle: "Show Whitespace Changes", offTitle: "Hide Whitespace Changes", symbol: "space"),
    ]

    /// Triggers the app menu's own "Settings…" item (added by SwiftUI's `Settings` scene) —
    /// SwiftUI offers no public imperative way to open that window from AppKit code.
    private static func openSettings() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command })
        else { return }
        appMenu.performActionForItem(at: index)
    }

    private static func countLabel(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count.formatted()) \(count == 1 ? singular : plural)"
    }
}
