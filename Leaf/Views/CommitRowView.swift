import SwiftUI

/// A single commit row, including its tag badges. Shared by `BranchListView`'s history list and
/// `MergeSheet`'s commit previews.
struct CommitRowView: View {
    let commit: GitCommit
    let tags: [GitTag]
    /// This commit exists locally but not on the branch's upstream — flagged with a trailing
    /// up-arrow badge.
    let isUnpushed: Bool
    /// Lets the summary and description wrap in full; otherwise one line and two respectively.
    let showFullCommitTitle: Bool
    let showCommitDescription: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(commit.summary)
                    .lineLimit(showFullCommitTitle ? nil : 1)
                    .truncationTooltip(commit.summary, isEnabled: !showFullCommitTitle)
                if !tags.isEmpty || isUnpushed {
                    Spacer(minLength: 6)
                    HStack(spacing: 4) {
                        ForEach(tags) { tag in
                            tagBadge(tag)
                        }
                        if isUnpushed {
                            unpushedBadge
                        }
                    }
                }
            }
            if showCommitDescription, !commit.body.isEmpty {
                Text(commit.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(showFullCommitTitle ? nil : 2)
            }
            Text("\(commit.author) · \(commit.relativeDate)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    /// Up-arrow badge marking a commit that hasn't been pushed to the remote. Same reliance on
    /// semantic colors (`.primary` glyph, `.secondary` circle) as `tagBadge` so both the glyph and
    /// its background flip to white automatically when the row is selected and emphasised.
    private var unpushedBadge: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: 16, height: 16)
            .background(Circle().fill(Color.secondary.opacity(0.2)))
            .help("This commit has not been pushed to the remote repository")
    }

    /// `.secondary` (rather than a literal color like `.accentColor`) is what lets this badge pick
    /// up the same automatic white-on-selection flip macOS gives ordinary row text/labels for free
    /// — no KVO/AppKit tracking needed, unlike `StatusIconView`'s status glyph (a colored icon, not
    /// a semantic label color, so it doesn't participate in that automatic flip).
    private func tagBadge(_ tag: GitTag) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "tag.fill")
                .font(.system(size: 8))
            Text(tag.name)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}
