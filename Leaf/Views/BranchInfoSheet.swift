import SwiftUI

/// Answers "is this branch old, is it in main yet, can I delete it?" without checking it out.
struct BranchInfoSheet: View {
    @Bindable var appState: AppState
    let branch: GitBranch

    @State private var comparison: GitRepository.BranchComparison?
    @State private var loadError: String?
    @State private var reloadToken = 0

    /// Only drives the "Stale" label — an old branch can still hold unmerged work.
    private static let staleAge: TimeInterval = 90 * 24 * 60 * 60

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(branch.name)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if let comparison {
                verdict(comparison)
                details(comparison)
                if comparison.aheadCount > 0 {
                    commits(comparison)
                }
            }
            if let loadError {
                GitErrorMessageView(rawMessage: loadError)
            } else if comparison == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }

            fetchRow
            buttons
        }
        .padding(20)
        .frame(width: 460)
        .task(id: reloadToken) { await load() }
        .onChange(of: appState.isSyncing) { _, isSyncing in
            if !isSyncing { reloadToken += 1 }
        }
    }

    private func load() async {
        do {
            let result = try await appState.loadBranchComparison(branch)
            guard !Task.isCancelled else { return }
            comparison = result
            loadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            // Never leave an out-of-date "safe to delete" on screen next to an error.
            comparison = nil
            loadError = error.localizedDescription
        }
    }

    // MARK: - Verdict

    private func verdict(_ comparison: GitRepository.BranchComparison) -> some View {
        let content = verdictContent(comparison)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: content.symbol)
                .foregroundStyle(content.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .fontWeight(.semibold)
                Text(content.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func verdictContent(
        _ comparison: GitRepository.BranchComparison
    ) -> (symbol: String, color: Color, title: String, detail: String) {
        let base = comparison.baseName
        switch comparison.verdict() {
        case .merged:
            return ("checkmark.circle.fill", .green, "Safe to delete",
                    "Fully merged: every commit is already in \(base).")
        case .contentIncluded:
            return ("checkmark.circle.fill", .green, "Safe to delete",
                    "Its changes are already in \(base), probably through a squash merge or rebase.")
        case .recentlyUsed:
            let use: String
            if comparison.worktreePath != nil {
                use = "Checked out in another worktree."
            } else {
                use = comparison.lastUsedDate.map { "Last used \(GitCommit.relativeDate(for: $0).lowercased())." } ?? ""
            }
            let state = comparison.aheadCount == 0
                ? "Every commit is already in \(base)" : "Its changes are already in \(base)"
            return ("clock.fill", .blue, "Recently used", "\(use) \(state), but you may still need this branch.")
        case .backedUpOnRemote:
            return ("exclamationmark.triangle.fill", .orange, "Not merged into \(base)",
                    "Its commits are on the remote, so deleting removes only your local copy.")
        case .unmerged(let count):
            let subject = count == 1 ? "1 commit isn\u{2019}t" : "\(count) commits aren\u{2019}t"
            return ("xmark.octagon.fill", .red, "Not safe to delete",
                    "\(subject) in \(base) or on any remote. Deleting could lose this work.")
        case .notApplicable:
            return ("info.circle.fill", .secondary, "Default branch", "Compared with \(base) for information only.")
        }
    }

    // MARK: - Details

    private func details(_ comparison: GitRepository.BranchComparison) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            if let commit = comparison.lastCommit {
                let isStale = Date().timeIntervalSince(commit.date) > Self.staleAge
                row("Last commit", "\(commit.relativeDate) by \(commit.author)" + (isStale ? " (stale)" : ""))
            }
            row("Compared with \(comparison.baseName)", "\(comparison.aheadCount) ahead, \(comparison.behindCount) behind")
            if let date = comparison.lastUsedDate {
                row("Last used", GitCommit.relativeDate(for: date))
            }
            row("Remote", upstreamText(comparison.upstream))
            if let path = comparison.worktreePath {
                row("Checked out in", path)
            }
        }
        .font(.callout)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func upstreamText(_ upstream: GitRepository.BranchComparison.Upstream) -> String {
        switch upstream {
        case .none: "No upstream branch"
        case .inSync(let name): "In sync with \(name)"
        case .outOfSync(let name, let track): "\(track) of \(name)"
        case .gone(let name): "\(name) was deleted on the remote"
        }
    }

    // MARK: - Commits

    private func commits(_ comparison: GitRepository.BranchComparison) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(comparison.isContentIncluded
                 ? "Original commits (their changes are already in \(comparison.baseName))"
                 : "Commits not in \(comparison.baseName)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(comparison.uniqueCommits) { commit in
                        CommitRowView(
                            commit: commit,
                            tags: appState.tagsByCommitSHA[commit.sha] ?? [],
                            isUnpushed: false,
                            showFullCommitTitle: false,
                            showCommitDescription: false
                        )
                        Divider()
                    }
                    if comparison.aheadCount > comparison.uniqueCommits.count {
                        Text("+\(comparison.aheadCount - comparison.uniqueCommits.count) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                }
            }
            .frame(height: min(CGFloat(comparison.uniqueCommits.count) * 48, 190))
        }
    }

    // MARK: - Footer

    private var fetchRow: some View {
        HStack(spacing: 8) {
            if let comparison {
                Text(comparison.lastFetchDate.map { "Last fetched: \(GitCommit.relativeDate(for: $0))" }
                     ?? "Not fetched yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if appState.hasOriginRemote {
                Button("Fetch") { appState.fetchRemote() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(appState.isSyncing || appState.isRepositoryBusy)
            }
            if appState.isSyncing {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var buttons: some View {
        HStack {
            if comparison?.isDefaultBranch == false {
                Button("Delete…", role: .destructive) { dismissThen { appState.deleteBranch(branch) } }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .disabled(comparison?.worktreePath != nil || isBlocked)
            }
            Spacer()
            Button("Checkout") { dismissThen { appState.selectBranch(branch) } }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .disabled(comparison?.worktreePath != nil || isBlocked)
            Button("Done") { appState.branchComparisonTarget = nil }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
        }
        // Return is Done; this hidden button gives Esc the same effect.
        .background {
            Button("Close") { appState.branchComparisonTarget = nil }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var isBlocked: Bool { appState.isSyncing || appState.isRepositoryBusy }

    /// Runs `action` once the sheet is on its way out, so its alerts attach to the main window.
    private func dismissThen(_ action: @escaping () -> Void) {
        appState.branchComparisonTarget = nil
        DispatchQueue.main.async(execute: action)
    }
}
