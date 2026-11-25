import AppKit
import Foundation
import Sparkle

/// Builds the palette's item list from what `AppState` already holds in memory — no git calls
/// — so opening the palette is instant. Each command calls the same `AppState` entry point as
/// its menu-bar/toolbar/context-menu counterpart (see `LeafApp`'s `.commands`). A command that
/// can't run right now is listed with the reason (`unavailableReason`) rather than left out,
/// so it never looks like the palette is missing it.
enum CommandPaletteItems {
    static let suggestionCount = 3
    /// The selected source's files are searchable up to this many — beyond it a working tree is
    /// a bulk change nobody jumps around by name, and filtering stays well under a frame.
    static let maxFileItems = 2000

    struct Built {
        let items: [PaletteItem]
        let suggestions: [PaletteItem]
        /// Rows made from the typed text itself (see `CommandPaletteModel.reset`).
        let dynamicItems: (String) -> [PaletteItem]
    }

    /// `missingPaths` are the repo folders last found not to exist (see
    /// `CommandPaletteController.checkMissingRepoFolders`) — passed in rather than checked here,
    /// so opening never `stat`s every repo on the main thread, where one on an unmounted
    /// network volume could stall it.
    static func build(appState: AppState, usage: CommandUsageStore, missingPaths: Set<String> = []) -> Built {
        let repos = appState.sidebarStore.repos
        let currentPath = appState.selectedRepoURL?.path
        let recentRank = Dictionary(
            appState.recentRepos.paths.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var items: [PaletteItem] = []
        var repoItemsByPath: [String: PaletteItem] = [:]

        for repo in repos {
            let item = repoItem(repo, isCurrent: repo.path == currentPath, recentRank: recentRank[repo.path], isMissing: missingPaths.contains(repo.path), appState: appState)
            items.append(item)
            repoItemsByPath[repo.path] = item
        }

        let scope = appState.selectedRepoURL.map { url in
            repos.first { $0.url == url }?.displayName ?? url.lastPathComponent
        }
        if let scope {
            items += branchItems(appState: appState, scope: scope)
            items += tagItems(appState: appState, scope: scope)
            items += gitCommandItems(appState: appState, scope: scope)
            items += copyAndGitHubItems(appState: appState, scope: scope)
        }
        items += menuCommandItems(appState: appState, scope: scope)
        if scope != nil, !appState.isRepositoryBusy {
            items += commitItems(appState: appState)
            items += fileItems(appState: appState)
        }

        let now = Date()
        for index in items.indices {
            if let key = items[index].usageKey {
                items[index].boost += usage.boost(for: key, now: now)
            }
        }

        let suggestions = appState.recentRepos
            .recent(from: repos, limit: suggestionCount, excludingPath: currentPath, exists: { !missingPaths.contains($0) })
            .compactMap { repoItemsByPath[$0.path] }

        return Built(
            items: items,
            suggestions: suggestions,
            dynamicItems: { [weak appState] query in
                guard let appState else { return [] }
                return dynamicItems(for: query, appState: appState, scope: scope)
            }
        )
    }

    // MARK: - Repos

    private static func repoItem(_ repo: SidebarRepo, isCurrent: Bool, recentRank: Int?, isMissing: Bool, appState: AppState) -> PaletteItem {
        // Recent repos win ties against other repos; the open one ranks lowest since switching
        // to it does nothing.
        var boost = 40
        if let recentRank { boost += max(0, 30 - recentRank * 3) }
        if isCurrent { boost = 0 }
        if isMissing { boost = -200 }
        let url = repo.url
        var item = PaletteItem(
            id: "repo:\(repo.id)",
            kind: .repo(repo),
            title: repo.displayName,
            symbol: "book.closed.fill",
            keywords: repo.displayNameOverride != nil ? [url.lastPathComponent] : [],
            boost: boost,
            perform: { [weak appState] in appState?.selectRepo(url) }
        )
        item.actionLabel = "Open"
        item.unavailableReason = isMissing ? "Folder not found" : nil
        var alternates: [PaletteAlternate] = []
        if !isMissing {
            alternates.append(PaletteAlternate(modifier: .option, title: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
            alternates.append(PaletteAlternate(modifier: .command, title: openInApplicationTitle) {
                LeafSettings.open(url)
            })
            alternates.append(PaletteAlternate(modifier: .shift, title: "Open on GitHub") {
                openOnGitHub(repoAt: url)
            })
        }
        item.alternates = alternates
        return item
    }

    // MARK: - Branches

    private static func branchItems(appState: AppState, scope: String) -> [PaletteItem] {
        guard !appState.isRepositoryBusy else { return [] }
        let repoPath = appState.selectedRepoURL?.path ?? ""
        let currentBranch = appState.selectedBranch
        let canMerge = !appState.isMergeInProgress && !appState.isSyncing
        var items: [PaletteItem] = []
        for branch in appState.branches where !branch.isCurrent {
            var item = PaletteItem(
                id: "branch:\(branch.name)",
                kind: .branch,
                title: branch.name,
                scope: scope,
                subtitle: "Switch to branch",
                symbol: "arrow.triangle.branch",
                keywords: ["checkout", "switch", "branch"],
                perform: { [weak appState] in appState?.selectBranch(branch) }
            )
            item.actionLabel = "Switch"
            item.usageKey = "branch:\(repoPath):\(branch.name)"
            var alternates: [PaletteAlternate] = []
            if canMerge, let currentBranch {
                alternates.append(PaletteAlternate(modifier: .option, title: "Merge into \(currentBranch.name)\(AppState.isMergeHelperEnabled ? "…" : "")") { [weak appState] in
                    appState?.requestMerge(of: branch)
                })
            }
            alternates.append(PaletteAlternate(modifier: .shift, title: "Copy Name") { copy(branch.name) })
            alternates.append(PaletteAlternate(modifier: .command, title: "Delete…") { [weak appState] in
                appState?.deleteBranch(branch)
            })
            item.alternates = alternates
            items.append(item)
        }
        for remote in appState.remoteOnlyBranches {
            var item = PaletteItem(
                id: "remote:\(remote.upstreamRef)",
                kind: .branch,
                title: remote.name,
                scope: scope,
                subtitle: "Check out \(remote.upstreamRef)",
                symbol: "icloud.and.arrow.down",
                keywords: ["checkout", "remote", "branch"],
                boost: -10,
                perform: { [weak appState] in appState?.checkoutRemoteBranch(remote) }
            )
            item.actionLabel = "Check Out"
            item.usageKey = "remote:\(repoPath):\(remote.upstreamRef)"
            item.alternates = [PaletteAlternate(modifier: .shift, title: "Copy Name") { copy(remote.name) }]
            items.append(item)
        }
        return items
    }

    // MARK: - Tags

    /// Return jumps to the tagged commit, when it's in the loaded history.
    private static func tagItems(appState: AppState, scope: String) -> [PaletteItem] {
        guard !appState.isRepositoryBusy, !appState.tags.isEmpty else { return [] }
        let commitsBySHA = Dictionary(appState.commits.map { ($0.sha, $0) }, uniquingKeysWith: { first, _ in first })
        return appState.tags.map { tag in
            let commit = commitsBySHA[tag.sha]
            var item = PaletteItem(
                id: "tag:\(tag.name)",
                kind: .commit,
                title: tag.name,
                scope: scope,
                subtitle: commit.map { "Tag on \($0.shortSha) \($0.summary)" },
                symbol: "tag",
                keywords: ["tag"],
                boost: -15,
                perform: { [weak appState] in
                    guard let appState, let commit else { return }
                    appState.selectSource(.commit(commit))
                    appState.focusedColumn = .branches
                    appState.revealSelectionRequest &+= 1
                }
            )
            item.actionLabel = "Show Commit"
            item.unavailableReason = commit == nil ? "Tagged commit isn\u{2019}t in the loaded history" : nil
            item.alternates = [
                PaletteAlternate(modifier: .shift, title: "Copy Name") { copy(tag.name) },
                PaletteAlternate(modifier: .option, title: "Delete Tag…") { [weak appState] in appState?.deleteTag(tag) },
            ]
            return item
        }
    }

    // MARK: - Argument pickers

    /// A command whose argument is picked from a list ("Merge ‹branch›"): typing `prefix` (or
    /// one of `aliases`) and a space lists `candidates`, filtered by whatever follows.
    struct ArgumentPicker {
        struct Candidate {
            let name: String
            var subtitle: String?
            let perform: () -> Void
        }

        let key: String
        /// The command's own row, e.g. "Delete Branch…".
        let title: String
        /// What comes before the argument, without its trailing space: "Delete Branch".
        let prefix: String
        /// Lowercased. Longest first where one starts another.
        var aliases: [String] = []
        let placeholder: String
        let symbol: String
        let actionLabel: String
        var keywords: [String] = []
        /// Why no candidate can be picked right now.
        var unavailable: String?
        let candidates: [Candidate]

        var phrases: [String] { [prefix.lowercased()] + aliases }

        /// What the command's own row says it's missing.
        var typeHint: String { "Type \(prefix) \u{2039}\(placeholder)\u{203A}" }
    }

    static func argumentPickers(appState: AppState) -> [ArgumentPicker] {
        typealias Candidate = ArgumentPicker.Candidate
        let busy = appState.isRepositoryBusy ? "Wait for the current operation to finish" : nil
        let otherBranches = appState.branches.filter { !$0.isCurrent }
        let noOthers = otherBranches.isEmpty ? "No other branches" : nil

        let switchable = otherBranches.map { branch in
            Candidate(name: branch.name) { [weak appState] in appState?.selectBranch(branch) }
        } + appState.remoteOnlyBranches.map { remote in
            Candidate(name: remote.name, subtitle: "Check out \(remote.upstreamRef)") { [weak appState] in
                appState?.checkoutRemoteBranch(remote)
            }
        }
        let current = appState.selectedBranch?.name
        let mergeReason = busy
            ?? (appState.isSyncing ? "Wait for the current sync to finish" : nil)
            ?? (appState.isMergeInProgress ? "A merge is already in progress" : nil)
            ?? (current == nil ? "Not on a branch" : nil)
            ?? noOthers

        return [
            ArgumentPicker(
                key: "Switch to Branch", title: "Switch to Branch…", prefix: "Switch to",
                aliases: ["checkout", "check out", "switch"], placeholder: "branch",
                symbol: "arrow.triangle.branch", actionLabel: "Switch", keywords: ["checkout", "branch"],
                unavailable: busy ?? (switchable.isEmpty ? "No other branches" : nil), candidates: switchable
            ),
            ArgumentPicker(
                key: "Merge", title: "Merge…", prefix: "Merge", placeholder: "branch",
                symbol: "arrow.triangle.merge", actionLabel: "Merge", keywords: ["combine", "integrate"],
                unavailable: mergeReason,
                candidates: otherBranches.map { branch in
                    Candidate(name: branch.name, subtitle: current.map { "Into \($0)" }) { [weak appState] in
                        appState?.requestMerge(of: branch)
                    }
                }
            ),
            ArgumentPicker(
                key: "Delete Branch", title: "Delete Branch…", prefix: "Delete Branch",
                aliases: ["remove branch"], placeholder: "branch",
                symbol: "trash", actionLabel: "Delete…", keywords: ["remove"],
                unavailable: busy ?? noOthers,
                candidates: otherBranches.map { branch in
                    Candidate(name: branch.name) { [weak appState] in appState?.deleteBranch(branch) }
                }
            ),
            ArgumentPicker(
                key: "Delete Tag", title: "Delete Tag…", prefix: "Delete Tag",
                aliases: ["remove tag"], placeholder: "tag",
                symbol: "tag.slash", actionLabel: "Delete…", keywords: ["remove"],
                unavailable: busy ?? (appState.tags.isEmpty ? "No tags" : nil),
                candidates: appState.tags.map { tag in
                    Candidate(name: tag.name) { [weak appState] in appState?.deleteTag(tag) }
                }
            ),
        ]
    }

    /// The rows for a picker `query` has entered — empty when it's entered none (or that picker
    /// is unavailable; its own row then says why).
    static func pickerItems(for query: String, pickers: [ArgumentPicker], scope: String?) -> [PaletteItem] {
        for picker in pickers where picker.unavailable == nil {
            guard let typed = pickerArgument(in: query, after: picker.phrases) else { continue }
            // Matched against the bare names, so "merge m" isn't matched by the "m" in "Merge".
            let names = picker.candidates.enumerated().map { index, candidate in
                PaletteItem(id: String(index), kind: .command, title: candidate.name, symbol: picker.symbol, perform: {})
            }
            let matches = typed.isEmpty
                ? Array(names.prefix(PaletteMatcher.maxResults))
                : PaletteMatcher.filter(names, query: typed)
            return matches.compactMap { match in
                guard let index = Int(match.id) else { return nil }
                let candidate = picker.candidates[index]
                let lead = picker.prefix + " "
                var item = PaletteItem(
                    id: "pick:\(picker.key):\(index):\(candidate.name)",
                    kind: .command,
                    title: lead + candidate.name,
                    scope: scope,
                    subtitle: candidate.subtitle,
                    symbol: picker.symbol,
                    fuzzy: .none,
                    perform: candidate.perform
                )
                item.actionLabel = picker.actionLabel
                item.usageKey = "git:\(picker.key)"
                item.matchedIndices = match.matchedIndices.map { $0 + lead.count }
                return item
            }
        }
        return []
    }

    // MARK: - Commits & files

    /// The current branch's loaded history (`AppState.commits`, ≤200). Summary substring or SHA
    /// prefix only — no fuzzy matching, which across long prose matches nearly anything.
    private static func commitItems(appState: AppState) -> [PaletteItem] {
        let unpushed = appState.unpushedCommitSHAs
        let webURL = appState.originRemoteURL.flatMap(GitRepository.githubWebURL(fromRemoteURL:))
        return appState.commits.map { commit in
            var item = PaletteItem(
                id: "commit:\(commit.sha)",
                kind: .commit,
                title: commit.summary.isEmpty ? "(no message)" : commit.summary,
                subtitle: "\(commit.shortSha) · \(commit.author)",
                symbol: "smallcircle.filled.circle",
                keywords: [commit.shortSha, commit.sha],
                boost: -30,
                fuzzy: .none,
                perform: { [weak appState] in
                    guard let appState else { return }
                    appState.selectSource(.commit(commit))
                    appState.focusedColumn = .branches
                    appState.revealSelectionRequest &+= 1
                }
            )
            item.date = commit.date
            item.actionLabel = "Show"
            var alternates = [PaletteAlternate(modifier: .shift, title: "Copy SHA") { copy(commit.sha) }]
            if let webURL, !unpushed.contains(commit.sha) {
                alternates.append(PaletteAlternate(modifier: .option, title: "Open on GitHub") {
                    NSWorkspace.shared.open(webURL.appendingPathComponent("commit/\(commit.sha)"))
                })
            }
            item.alternates = alternates
            return item
        }
    }

    /// Files of whichever source is selected (Uncommitted Changes, the stash, or a commit) —
    /// the list column 3 is showing. Matched by file name, or fuzzily by full path.
    private static func fileItems(appState: AppState) -> [PaletteItem] {
        guard let repoURL = appState.selectedRepoURL else { return [] }
        let sourceLabel: String
        switch appState.selectedSource {
        case .workingChanges?: sourceLabel = "Uncommitted Changes"
        case .stash?: sourceLabel = "Stashed Changes"
        case .commit(let commit)?: sourceLabel = commit.shortSha
        case nil: return []
        }
        let openTitle = openInApplicationTitle
        return appState.changedFiles.prefix(maxFileItems).map { file in
            let nsPath = file.path as NSString
            let directory = nsPath.deletingLastPathComponent
            let fileURL = repoURL.appendingPathComponent(file.path)
            var item = PaletteItem(
                id: "file:\(file.path)",
                kind: .file,
                title: nsPath.lastPathComponent,
                subtitle: [directory.isEmpty ? nil : directory, file.status.label, sourceLabel]
                    .compactMap { $0 }
                    .joined(separator: " · "),
                symbol: "doc",
                keywords: [file.path],
                boost: -20,
                fuzzy: .text(file.path),
                perform: { [weak appState] in
                    guard let appState else { return }
                    appState.selectFile(file)
                    appState.focusedColumn = .files
                    appState.revealSelectionRequest &+= 1
                }
            )
            item.actionLabel = "Show Diff"
            var alternates = [PaletteAlternate(modifier: .shift, title: "Copy Path") { copy(file.path) }]
            // Existence is checked when run, not here — a stat per file on every open would be
            // the one slow part of building.
            if file.status != .deleted {
                alternates.append(PaletteAlternate(modifier: .option, title: "Show in Finder") {
                    guard FileManager.default.fileExists(atPath: fileURL.path) else { return NSSound.beep() }
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                })
                alternates.append(PaletteAlternate(modifier: .command, title: openTitle) {
                    guard FileManager.default.fileExists(atPath: fileURL.path) else { return NSSound.beep() }
                    LeafSettings.open(fileURL)
                })
            }
            item.alternates = alternates
            return item
        }
    }

    // MARK: - Git commands

    private static func gitCommandItems(appState: AppState, scope: String) -> [PaletteItem] {
        var items: [PaletteItem] = []
        let busyReason = appState.isRepositoryBusy ? "Wait for the current operation to finish" : nil
        let syncReason = busyReason ?? (appState.isSyncing ? "Wait for the current sync to finish" : nil)
        func add(
            _ title: String,
            key: String? = nil,
            subtitle: String? = nil,
            symbol: String,
            shortcut: String? = nil,
            keywords: [String] = [],
            unavailable: String? = nil,
            needsArgument: Bool = false,
            argumentPrefix: String? = nil,
            argumentPlaceholder: String? = nil,
            _ perform: @escaping (AppState) -> Void
        ) {
            let key = key ?? title
            var item = PaletteItem(
                id: "git:\(key)",
                kind: .command,
                title: title,
                scope: scope,
                subtitle: subtitle,
                symbol: symbol,
                shortcut: shortcut,
                keywords: keywords + ["git"],
                boost: 20,
                perform: { [weak appState] in appState.map(perform) }
            )
            item.unavailableReason = busyReason ?? unavailable
            item.needsArgument = busyReason == nil && needsArgument
            item.usageKey = "git:\(key)"
            item.argumentPrefix = argumentPrefix
            item.argumentPlaceholder = argumentPlaceholder
            items.append(item)
        }

        let branchName = appState.selectedBranch?.name
        let notOnBranch = branchName == nil ? "Not on a branch" : nil
        add(
            "Push",
            subtitle: appState.aheadCount > 0 ? countLabel(appState.aheadCount, "commit to push", "commits to push") : branchName.map { "Push \($0)" },
            symbol: "arrow.up",
            shortcut: "⌘P",
            keywords: ["upload", "send"],
            unavailable: syncReason ?? notOnBranch
                ?? (!appState.hasUpstream && !appState.hasOriginRemote ? "No remote to push to" : nil)
                ?? (appState.hasUpstream && appState.aheadCount == 0 ? "Nothing to push" : nil)
        ) { $0.pushCurrentBranch() }
        add(
            "Pull",
            subtitle: appState.behindCount > 0 ? countLabel(appState.behindCount, "commit behind", "commits behind") : branchName.map { "Pull \($0)" },
            symbol: "arrow.down",
            shortcut: "⇧⌘P",
            keywords: ["download", "update"],
            unavailable: syncReason ?? notOnBranch ?? (appState.hasUpstream ? nil : "No upstream branch to pull from")
        ) { $0.pullCurrentBranch() }
        add(
            "Fetch",
            symbol: "arrow.trianglehead.2.clockwise",
            shortcut: "⇧⌘T",
            keywords: ["refresh", "remote"],
            unavailable: syncReason
        ) { $0.fetchRemote() }

        let message = appState.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let commitReason = commitUnavailableReason(appState: appState)
        let commitSubtitle = message.isEmpty ? nil : "\u{201C}\(message)\u{201D} · \(countLabel(appState.checkedFilePaths.count, "file", "files"))"
        if appState.isMergeInProgress {
            add(
                "Complete Merge",
                subtitle: commitSubtitle,
                symbol: "checkmark.circle",
                keywords: ["commit", "save"],
                unavailable: commitReason ?? (message.isEmpty ? "Type a commit message first" : nil)
            ) { $0.commitOrCompleteMerge() }
        } else {
            add(
                "Commit",
                subtitle: commitSubtitle,
                symbol: "checkmark.circle",
                keywords: ["save"],
                // An empty message isn't a dead end: "Commit ‹message›" types one inline.
                unavailable: commitReason ?? (message.isEmpty ? "Type Commit \u{2039}message\u{203A} to commit" : nil),
                needsArgument: commitReason == nil && message.isEmpty,
                argumentPrefix: "Commit ",
                argumentPlaceholder: "message"
            ) { $0.commitOrCompleteMerge() }
        }

        add(
            "Pull Then Push",
            subtitle: branchName.map { "Pull \($0), then push it" },
            symbol: "arrow.up.arrow.down",
            keywords: ["sync", "update"],
            unavailable: syncReason ?? notOnBranch
                ?? (appState.hasUpstream ? nil : "No upstream branch to pull from")
                ?? (appState.aheadCount == 0 ? "Nothing to push" : nil)
        ) { $0.pullThenPush() }
        let lastCommit = appState.commits.first
        add(
            "Undo Last Commit",
            subtitle: lastCommit.map { "\($0.shortSha) \($0.summary)" },
            symbol: "arrow.uturn.backward",
            keywords: ["reset", "revert", "uncommit"],
            unavailable: undoUnavailableReason(appState: appState)
        ) { state in
            if let lastCommit { state.undoLastCommit(lastCommit) }
        }

        let noChanges = appState.uncommittedChangeCount == 0 ? "No uncommitted changes" : nil
        add(
            "Show Uncommitted Changes",
            subtitle: noChanges == nil ? countLabel(appState.uncommittedChangeCount, "change", "changes") : nil,
            symbol: "doc.badge.ellipsis",
            keywords: ["working", "changes", "local", "modified", "status", "select"],
            unavailable: noChanges ?? (appState.selectedSource == .workingChanges ? "Already showing" : nil)
        ) { state in
            state.selectSource(.workingChanges)
            state.focusedColumn = .branches
            state.revealSelectionRequest &+= 1
        }
        add(
            "Stash All Changes",
            subtitle: noChanges == nil ? countLabel(appState.uncommittedChangeCount, "change", "changes") : nil,
            symbol: "tray.and.arrow.down",
            keywords: ["shelve", "save"],
            unavailable: noChanges
        ) { $0.stashAllChanges() }
        add("Discard All Changes…", key: "Discard All Changes", symbol: "trash", keywords: ["reset", "revert", "clean"], unavailable: noChanges) { $0.discardAllChanges() }

        let showsWorking = appState.selectedSource == .workingChanges
        let checkedCount = appState.checkedFilePaths.count
        add(
            "Check All Files",
            symbol: "checklist.checked",
            keywords: ["stage", "select"],
            unavailable: noChanges ?? (showsWorking && checkedCount == appState.changedFiles.count ? "All files are checked" : nil)
        ) { $0.setAllWorkingChangesChecked(true) }
        add(
            "Uncheck All Files",
            symbol: "checklist.unchecked",
            keywords: ["unstage", "deselect"],
            unavailable: noChanges ?? (showsWorking && checkedCount == 0 ? "No files are checked" : nil)
        ) { $0.setAllWorkingChangesChecked(false) }

        // Conflicted files are left out of these three, as in the file list's context menu.
        let selectedFiles = showsWorking ? appState.changedFiles.filter { appState.selectedFilePaths.contains($0.path) } : []
        let actionable = selectedFiles.filter { $0.status != .conflicted }
        let noSelection = !showsWorking ? "Select Uncommitted Changes first"
            : selectedFiles.isEmpty ? "No file selected"
            : actionable.isEmpty ? "Resolve the conflict first" : nil
        let selectedNoun = actionable.count > 1 ? "Selected Files" : "Selected File"
        let selectedSubtitle = actionable.count == 1 ? actionable.first?.path
            : actionable.isEmpty ? nil : countLabel(actionable.count, "file", "files")
        add("Stash \(selectedNoun)", key: "Stash Selected", subtitle: selectedSubtitle, symbol: "tray.and.arrow.down", keywords: ["shelve"], unavailable: noSelection) {
            $0.stashChanges(for: actionable)
        }
        add("Discard \(selectedNoun)…", key: "Discard Selected", subtitle: selectedSubtitle, symbol: "trash", keywords: ["revert", "reset"], unavailable: noSelection) {
            $0.discardChanges(for: actionable)
        }
        add("Ignore \(selectedNoun)", key: "Ignore Selected", subtitle: selectedSubtitle, symbol: "eye.slash", keywords: ["gitignore"], unavailable: noSelection) {
            $0.ignoreFiles(actionable)
        }
        let conflicted = selectedFiles.count == 1 ? selectedFiles.first { $0.status == .conflicted } : nil
        add(
            "Mark Resolved",
            subtitle: conflicted?.path,
            symbol: "checkmark.seal",
            keywords: ["conflict", "merge"],
            unavailable: conflicted == nil ? "Select a conflicted file first" : nil
        ) { state in
            if let conflicted { state.requestMarkResolved(conflicted) }
        }

        let noStash = appState.stashCount == 0 ? "No stashed changes" : nil
        add(
            "Show Stashed Changes",
            subtitle: noStash == nil ? countLabel(appState.stashFileCount, "file", "files") : nil,
            symbol: "tray",
            keywords: ["view", "select"],
            unavailable: noStash ?? (appState.selectedSource == .stash ? "Already showing" : nil)
        ) { state in
            state.selectSource(.stash)
            state.focusedColumn = .branches
            state.revealSelectionRequest &+= 1
        }
        add(
            "Restore Stash",
            subtitle: noStash == nil ? countLabel(appState.stashFileCount, "file", "files") : nil,
            symbol: "tray.and.arrow.up",
            keywords: ["pop", "apply", "unstash"],
            unavailable: noStash
        ) { $0.restoreStash() }
        add("Discard Stash…", key: "Discard Stash", symbol: "tray.full", keywords: ["drop", "delete"], unavailable: noStash) { $0.discardStash() }

        add(
            "New Branch…",
            key: "New Branch",
            subtitle: "Or type New Branch \u{2039}name\u{203A}",
            symbol: "plus",
            keywords: ["create", "branch"],
            argumentPrefix: "New Branch ",
            argumentPlaceholder: "branch name"
        ) { $0.isNewBranchSheetPresented = true }
        let tagTarget = targetCommit(appState: appState)
        add(
            "New Tag…",
            key: "New Tag",
            subtitle: tagTarget.map { "On \($0.shortSha) \($0.summary)" },
            symbol: "tag",
            keywords: ["create", "release", "version", "commit"],
            unavailable: tagTarget == nil ? "No commits to tag yet" : nil,
            argumentPrefix: "New Tag ",
            argumentPlaceholder: "tag name"
        ) { state in
            state.newTagTargetCommit = tagTarget
            state.isNewTagSheetPresented = true
        }
        if appState.isMergeInProgress {
            add("Abort Merge", symbol: "xmark.circle", keywords: ["cancel", "merge"]) { $0.abortMerge() }
        }
        for picker in argumentPickers(appState: appState) {
            let opensSheet = picker.key == "Merge" && AppState.isMergeHelperEnabled
            add(
                picker.title,
                key: picker.key,
                symbol: picker.symbol,
                keywords: picker.keywords,
                unavailable: picker.unavailable ?? (opensSheet ? nil : picker.typeHint),
                needsArgument: picker.unavailable == nil && !opensSheet,
                argumentPrefix: picker.prefix + " ",
                argumentPlaceholder: picker.placeholder
            ) { if opensSheet { $0.openMergeSheet(prefilledOtherBranch: nil) } }
        }
        add(
            "Prune Gone Branches",
            subtitle: "Delete local branches whose upstream is gone",
            symbol: "scissors",
            keywords: ["clean", "delete", "branches"],
            unavailable: appState.hasOriginRemote ? nil : "No remote"
        ) { $0.pruneGoneBranches() }
        return items
    }

    /// Why committing the checked files can't happen right now, ignoring the message (which
    /// "Commit ‹message›" supplies). `nil` when it can.
    private static func commitUnavailableReason(appState: AppState) -> String? {
        if appState.isCommitting { return "Already committing" }
        if appState.uncommittedChangeCount == 0 { return "No changes to commit" }
        if appState.selectedSource != .workingChanges { return "Select Uncommitted Changes to commit" }
        if appState.checkedFilePaths.isEmpty { return "No files checked" }
        return nil
    }

    /// The selected commit when browsing history, otherwise HEAD.
    private static func targetCommit(appState: AppState) -> GitCommit? {
        if case .commit(let commit)? = appState.selectedSource { return commit }
        return appState.commits.first
    }

    /// Why the newest commit can't be undone. Undoing puts its message back in the commit
    /// fields, so a draft already there blocks it rather than being silently overwritten.
    private static func undoUnavailableReason(appState: AppState) -> String? {
        guard let head = appState.commits.first else { return "No commits yet" }
        if appState.selectedBranch == nil { return "Not on a branch" }
        if appState.isSyncing || appState.isPushingCommit { return "Wait for the current sync to finish" }
        if appState.isCommitting { return "Already committing" }
        if appState.isMergeInProgress { return "A merge is in progress" }
        if appState.commits.count < 2 { return "The first commit can\u{2019}t be undone" }
        let isPushed = appState.hasUpstream
            ? appState.aheadCount == 0
            : appState.hasOriginRemote && !appState.unpushedCommitSHAs.contains(head.sha)
        if isPushed { return "Last commit is already pushed" }
        if !(appState.commitMessage + appState.commitDescription).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Clear the commit message draft first"
        }
        return nil
    }

    // MARK: - Copy & GitHub

    private static func copyAndGitHubItems(appState: AppState, scope: String) -> [PaletteItem] {
        var items: [PaletteItem] = []
        func add(_ title: String, subtitle: String? = nil, symbol: String, keywords: [String], unavailable: String? = nil, _ perform: @escaping () -> Void) {
            var item = PaletteItem(
                id: "copy:\(title)",
                kind: .command,
                title: title,
                scope: scope,
                subtitle: subtitle,
                symbol: symbol,
                keywords: keywords,
                perform: perform
            )
            item.unavailableReason = unavailable
            item.usageKey = "copy:\(title)"
            items.append(item)
        }

        let targetCommit = targetCommit(appState: appState)

        if let branch = appState.selectedBranch?.name {
            add("Copy Branch Name", subtitle: branch, symbol: "doc.on.doc", keywords: ["clipboard", "copy", "branch"]) { copy(branch) }
        }
        if let commit = targetCommit {
            add("Copy Commit SHA", subtitle: "\(commit.shortSha) \(commit.summary)", symbol: "doc.on.doc", keywords: ["clipboard", "copy", "hash"]) { copy(commit.sha) }
            add("Copy Commit Title", subtitle: commit.summary, symbol: "doc.on.doc", keywords: ["clipboard", "copy", "message"]) { copy(commit.summary) }
        }
        if let remote = appState.originRemoteURL {
            add("Copy Remote URL", subtitle: remote, symbol: "doc.on.doc", keywords: ["clipboard", "copy", "origin"]) { copy(remote) }
        }
        if let path = appState.selectedRepoURL?.path {
            add("Copy Repository Path", subtitle: path, symbol: "doc.on.doc", keywords: ["clipboard", "copy", "folder"]) { copy(path) }
        }

        guard let remote = appState.originRemoteURL else { return items }
        let githubKeywords = ["github", "browser", "web"]
        guard let webURL = GitRepository.githubWebURL(fromRemoteURL: remote) else {
            add("Open on GitHub", symbol: "safari", keywords: githubKeywords, unavailable: "Remote isn\u{2019}t on GitHub") {}
            return items
        }
        add("Open on GitHub", subtitle: webURL.absoluteString, symbol: "safari", keywords: githubKeywords) {
            NSWorkspace.shared.open(webURL)
        }
        if let branch = appState.selectedBranch?.name, let repoURL = appState.selectedRepoURL {
            let notPushed = appState.hasUpstream ? nil : "Branch isn\u{2019}t pushed yet"
            add("Open Branch on GitHub", subtitle: branch, symbol: "safari", keywords: githubKeywords + ["branch"], unavailable: notPushed) {
                openUpstreamPage(of: branch, repoURL: repoURL, webURL: webURL, path: "tree")
            }
            if branch != appState.defaultBranchName {
                add("Create Pull Request", subtitle: "\(branch) on GitHub", symbol: "arrow.triangle.pull", keywords: githubKeywords + ["pr", "compare"], unavailable: notPushed) {
                    openUpstreamPage(of: branch, repoURL: repoURL, webURL: webURL, path: "compare", query: "expand=1")
                }
            }
        }
        if let commit = targetCommit {
            let notPushed = appState.unpushedCommitSHAs.contains(commit.sha) ? "Commit isn\u{2019}t pushed yet" : nil
            add("Open Commit on GitHub", subtitle: "\(commit.shortSha) \(commit.summary)", symbol: "safari", keywords: githubKeywords + ["commit"], unavailable: notPushed) {
                NSWorkspace.shared.open(webURL.appendingPathComponent("commit/\(commit.sha)"))
            }
        }
        return items
    }

    /// `base` + a path that may contain `/` (branch names do), percent-encoded.
    static func githubURL(_ base: URL, path: String, query: String? = nil) -> URL? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var string = base.absoluteString + "/" + encoded
        if let query { string += "?" + query }
        return URL(string: string)
    }

    // MARK: - Menu bar

    private static func menuCommandItems(appState: AppState, scope: String?) -> [PaletteItem] {
        var items: [PaletteItem] = []
        func add(
            _ title: String,
            key: String? = nil,
            scope: String? = nil,
            menu: String? = nil,
            symbol: String,
            shortcut: String? = nil,
            keywords: [String] = [],
            unavailable: String? = nil,
            _ perform: @escaping () -> Void
        ) {
            let key = key ?? title
            var item = PaletteItem(
                id: "menu:\(key)",
                kind: .command,
                title: title,
                scope: scope,
                menuPath: menu,
                symbol: symbol,
                shortcut: shortcut,
                keywords: keywords,
                perform: perform
            )
            item.unavailableReason = unavailable
            item.usageKey = "menu:\(key)"
            items.append(item)
        }

        add("Add Repository…", menu: "File", symbol: "plus.rectangle.on.folder", shortcut: "⌘O", keywords: ["open", "import"]) { [weak appState] in appState?.addRepoViaPicker() }
        add("Clone Repository…", menu: "File", symbol: "square.and.arrow.down", shortcut: "⇧⌘O", keywords: ["download", "github"]) { [weak appState] in appState?.isCloneSheetPresented = true }

        if let scope {
            add("Show in Finder", scope: scope, symbol: "folder", shortcut: "⇧⌘F", keywords: ["reveal"]) { [weak appState] in appState?.revealSelectedRepoInFinder() }
            add(openInApplicationTitle, key: "Open in Application", scope: scope, symbol: "arrow.up.forward.app", shortcut: "⇧⌘A", keywords: ["editor", "open"]) { [weak appState] in appState?.openSelectedRepoInDefaultApplication() }
            add("Rename", scope: scope, symbol: "pencil", keywords: ["name", "repository"]) { [weak appState] in appState?.startRenamingSelectedRepo() }
            add("Choose Icon…", scope: scope, symbol: "photo", keywords: ["image", "icon", "repository"]) { [weak appState] in appState?.chooseIconForSelectedRepo() }
            add("Remove…", scope: scope, symbol: "minus.circle", shortcut: "⌘⌫", keywords: ["delete", "repository"]) { [weak appState] in appState?.removeSelectedRepo() }
            add("Find in Diff", scope: scope, symbol: "magnifyingglass", shortcut: "⌘F", keywords: ["search"]) { [weak appState] in appState?.showDiffFind() }
            let noMatches = appState.diffFindMatchCount == 0 ? "No matches \u{2013} use Find in Diff first" : nil
            add("Find Next in Diff", scope: scope, symbol: "chevron.right", shortcut: "⌘G", keywords: ["search"], unavailable: noMatches) { [weak appState] in appState?.diffFindNext() }
            add("Find Previous in Diff", scope: scope, symbol: "chevron.left", shortcut: "⇧⌘G", keywords: ["search"], unavailable: noMatches) { [weak appState] in appState?.diffFindPrevious() }

            let store = appState.sidebarStore
            if let repo = store.repos.first(where: { $0.url == appState.selectedRepoURL }) {
                for folder in store.folders {
                    add(
                        "Move to \u{201C}\(folder.name)\u{201D}",
                        key: "Move to Group:\(folder.id)",
                        scope: scope,
                        symbol: "folder.badge.plus",
                        keywords: ["group", "sidebar", "organize"],
                        unavailable: repo.folderID == folder.id ? "Already in this group" : nil
                    ) { [weak store] in store?.moveRepo(id: repo.id, intoFolder: folder.id, before: nil) }
                }
                if !store.folders.isEmpty || repo.folderID != nil {
                    add(
                        "Move to Top Level",
                        scope: scope,
                        symbol: "arrow.up.left",
                        keywords: ["group", "sidebar", "organize"],
                        unavailable: repo.folderID == nil ? "Already at the top level" : nil
                    ) { [weak store] in store?.moveRepoToTopLevel(id: repo.id, before: nil) }
                }
            }
        }

        add(SidebarVisibility.shared.isCollapsed ? "Show Sidebar" : "Hide Sidebar", key: "Toggle Sidebar", menu: "View", symbol: "sidebar.left", shortcut: "⌃⌘S") {
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        }
        for toggle in viewToggles {
            let isOn = LeafSettings.store.object(forKey: toggle.key) as? Bool ?? toggle.defaultValue
            add(isOn ? toggle.onTitle : toggle.offTitle, key: "toggle:\(toggle.key)", menu: "View", symbol: toggle.symbol, keywords: ["view", "toggle"]) {
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

    // MARK: - Typed input

    /// Rows made from the query itself: a pasted clone URL or folder path, and the commands
    /// that take an argument ("New Branch feature/login", "Commit fix typo"). Recomputed per
    /// keystroke, from in-memory state and (for a path) a single `stat`.
    static func dynamicItems(for query: String, appState: AppState, scope: String?) -> [PaletteItem] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        var items: [PaletteItem] = []

        if let url = cloneURL(in: text) {
            var item = PaletteItem(
                id: "dynamic:clone",
                kind: .command,
                title: "Clone \u{201C}\(GitRepository.repoName(fromURLString: url))\u{201D}",
                subtitle: url,
                symbol: "square.and.arrow.down",
                fuzzy: .none,
                perform: { [weak appState] in
                    appState?.cloneSheetPrefilledURL = url
                    appState?.isCloneSheetPresented = true
                }
            )
            item.actionLabel = "Clone"
            item.ghostOverride = ""
            items.append(item)
        }

        if let path = folderPath(in: text) {
            items.append(folderItem(path: path, appState: appState))
        }

        guard let scope else { return items }
        items += pickerItems(for: query, pickers: argumentPickers(appState: appState), scope: scope)
        let busyReason = appState.isRepositoryBusy ? "Wait for the current operation to finish" : nil

        if let name = argument(in: text, after: ["new branch", "create branch", "branch"]).map(sanitizedRefName) {
            let exists = appState.branches.contains { $0.name == name }
            var item = PaletteItem(
                id: "dynamic:newBranch",
                kind: .command,
                title: "New Branch \u{201C}\(name)\u{201D}",
                scope: scope,
                subtitle: "Create from HEAD and switch to it",
                symbol: "plus",
                fuzzy: .none,
                perform: { [weak appState] in
                    appState?.createBranch(named: name) { success in
                        if !success { presentError("Couldn\u{2019}t Create Branch", appState?.newBranchErrorMessage) }
                    }
                }
            )
            item.actionLabel = "Create"
            item.unavailableReason = busyReason ?? (exists ? "A branch named \u{201C}\(name)\u{201D} already exists" : nil)
            item.ghostOverride = ""
            items.append(item)
        }

        if let name = argument(in: text, after: ["new tag", "create tag", "tag"]).map(sanitizedRefName) {
            let target = targetCommit(appState: appState)
            let exists = appState.tags.contains { $0.name == name }
            var item = PaletteItem(
                id: "dynamic:newTag",
                kind: .command,
                title: "New Tag \u{201C}\(name)\u{201D}",
                scope: scope,
                subtitle: target.map { "On \($0.shortSha) \($0.summary)" },
                symbol: "tag",
                fuzzy: .none,
                perform: { [weak appState] in
                    guard let target else { return }
                    appState?.createTag(named: name, at: target.sha) { success in
                        if !success { presentError("Couldn\u{2019}t Create Tag", appState?.newTagErrorMessage) }
                    }
                }
            )
            item.actionLabel = "Create"
            item.unavailableReason = busyReason
                ?? (target == nil ? "No commits to tag yet" : nil)
                ?? (exists ? "A tag named \u{201C}\(name)\u{201D} already exists" : nil)
            item.ghostOverride = ""
            items.append(item)
        }

        if !appState.isMergeInProgress, let message = argument(in: text, after: ["commit"]) {
            let fileCount = appState.checkedFilePaths.count
            var item = PaletteItem(
                id: "dynamic:commit",
                kind: .command,
                title: "Commit \u{201C}\(message)\u{201D}",
                scope: scope,
                subtitle: countLabel(fileCount, "checked file", "checked files"),
                symbol: "checkmark.circle",
                fuzzy: .none,
                // The typed message is used as-is — the commit footer's own summary/description
                // draft is neither included nor cleared.
                perform: { [weak appState] in appState?.commitCheckedChanges(explicitMessage: message) }
            )
            item.actionLabel = "Commit"
            item.unavailableReason = busyReason ?? commitUnavailableReason(appState: appState)
            item.ghostOverride = ""
            items.append(item)
        }
        return items
    }

    private static func folderItem(path: String, appState: AppState) -> PaletteItem {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        if let repo = appState.sidebarStore.repos.first(where: { $0.path == path }) {
            var item = PaletteItem(
                id: "dynamic:folder",
                kind: .command,
                title: "Open \u{201C}\(repo.displayName)\u{201D}",
                subtitle: path,
                symbol: "book.closed",
                fuzzy: .none,
                perform: { [weak appState] in appState?.selectRepo(url) }
            )
            item.actionLabel = "Open"
            item.unavailableReason = path == appState.selectedRepoURL?.path ? "Already open" : nil
            item.ghostOverride = ""
            return item
        }
        let isRepo = GitRepository.isGitRepository(at: url)
        var item = PaletteItem(
            id: "dynamic:folder",
            kind: .command,
            title: "Add Repository \u{201C}\(name)\u{201D}",
            menuPath: "File",
            subtitle: path,
            symbol: "plus.rectangle.on.folder",
            fuzzy: .none,
            perform: { [weak appState] in
                guard let appState else { return }
                if appState.sidebarStore.addRepo(at: url) {
                    appState.selectRepo(url)
                } else {
                    appState.presentNotARepositoryAlert(for: [name])
                }
            }
        )
        item.actionLabel = "Add"
        item.unavailableReason = isRepo ? nil : "Not a git repository"
        item.ghostOverride = ""
        return item
    }

    // MARK: - Parsing

    /// The text after one of `phrases` (case-insensitive, then a space), or `nil` when the
    /// query doesn't start with one or nothing follows it yet.
    nonisolated static func argument(in text: String, after phrases: [String]) -> String? {
        for phrase in phrases {
            guard let range = text.range(of: phrase + " ", options: [.caseInsensitive, .anchored]) else { continue }
            let rest = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    /// Like `argument(in:after:)`, but for a picker: the bare "merge " already counts, as an
    /// empty argument (list everything). `query` is untrimmed — that trailing space is the signal.
    nonisolated static func pickerArgument(in query: String, after phrases: [String]) -> String? {
        let text = String(query.drop(while: \.isWhitespace))
        for phrase in phrases {
            guard let range = text.range(of: phrase + " ", options: [.caseInsensitive, .anchored]) else { continue }
            return text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// What a typed branch/tag name becomes: runs of whitespace (which git refs can't contain)
    /// turned into "-" — "fix login bug" → "fix-login-bug".
    nonisolated static func sanitizedRefName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    /// `text` when it looks like something `git clone` takes — an http(s)/ssh/git URL with a
    /// path, or scp-style "user@host:path".
    nonisolated static func cloneURL(in text: String) -> String? {
        guard !text.contains(where: \.isWhitespace) else { return nil }
        let patterns = [#"^(https?|ssh|git)://[^/]+/.+"#, #"^[\w.-]+@[\w.-]+:.+"#]
        guard patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) else { return nil }
        return text
    }

    /// An existing folder named by `text`: an absolute or `~` path, or a `file://` URL — with
    /// shell escaping (`\ `) or surrounding quotes, as a path copied from Terminal has.
    static func folderPath(in text: String, fileManager: FileManager = .default) -> String? {
        var candidate = text
        if candidate.count >= 2, let first = candidate.first, first == candidate.last, first == "\"" || first == "'" {
            candidate = String(candidate.dropFirst().dropLast())
        }
        candidate = candidate.replacingOccurrences(of: "\\ ", with: " ")
        if candidate.hasPrefix("file://") {
            guard let url = URL(string: candidate), url.isFileURL else { return nil }
            candidate = url.path
        }
        guard candidate.hasPrefix("/") || candidate.hasPrefix("~") else { return nil }
        let path = URL(fileURLWithPath: (candidate as NSString).expandingTildeInPath).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return path
    }

    // MARK: - Helpers

    private static var openInApplicationTitle: String {
        LeafSettings.openInApplicationTitle(editorPath: LeafSettings.store.string(forKey: LeafSettings.externalEditorPathKey) ?? "")
    }

    /// Triggers the app menu's own "Settings…" item (added by SwiftUI's `Settings` scene) —
    /// SwiftUI offers no public imperative way to open that window from AppKit code.
    private static func openSettings() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command })
        else { return }
        appMenu.performActionForItem(at: index)
    }

    /// Any sidebar repo's GitHub page. Only the open repo's remote is held in memory, so this
    /// reads `origin` when run (one quick git call, off the main thread) rather than at build
    /// time for every repo. Beeps when there's no GitHub remote.
    private static func openOnGitHub(repoAt url: URL) {
        Task {
            let webURL = await Task.detached(priority: .userInitiated) {
                GitRepository(rootURL: url).originRemoteURL().flatMap(GitRepository.githubWebURL(fromRemoteURL:))
            }.value
            if let webURL {
                NSWorkspace.shared.open(webURL)
            } else {
                NSSound.beep()
            }
        }
    }

    /// Opens `webURL/<path>/<upstream branch>` — the branch `localBranch` actually tracks,
    /// which can be named differently ("fix" tracking origin/feature/fix). The upstream isn't
    /// held in memory, so it's read from git config when run, off the main thread. Beeps when
    /// there's no upstream, or it's on a remote other than `origin` (whose page `webURL` is).
    private static func openUpstreamPage(of localBranch: String, repoURL: URL, webURL: URL, path: String, query: String? = nil) {
        Task {
            let upstream = await Task.detached(priority: .userInitiated) {
                GitRepository(rootURL: repoURL).upstream(ofBranch: localBranch)
            }.value
            guard let upstream, upstream.remote == "origin",
                  let url = githubURL(webURL, path: "\(path)/\(upstream.branch)", query: query) else {
                return NSSound.beep()
            }
            NSWorkspace.shared.open(url)
        }
    }

    private static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// For the inline-argument commands, whose sheet counterparts would show the error in the
    /// sheet itself.
    private static func presentError(_ title: String, _ message: String?) {
        let report = GitErrorReport(rawOutput: message ?? "")
        GitErrorAlert.present(
            title: title,
            message: message == nil ? "" : report.summary,
            log: report.hasFurtherDetail ? report.fullLog : nil
        )
    }

    private static func countLabel(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count.formatted()) \(count == 1 ? singular : plural)"
    }
}
