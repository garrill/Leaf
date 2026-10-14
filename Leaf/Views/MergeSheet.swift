import SwiftUI

/// Named coordinate space the drag gesture reports locations in, and the ghost overlay positions
/// itself in — shared by both columns so a drag started on one side can be tested against the
/// other side's half of the sheet.
private let mergeColumnsCoordinateSpace = "mergeColumns"
/// The sheet is a fixed, non-resizable width (720pt, minus 20pt padding each side) — a constant
/// midpoint is safe rather than measuring live. A drop left of this counts as the left column,
/// right of it as the right column.
private let mergeColumnsMidX: CGFloat = 340
/// Height of the "changes on both branches" list — enough for ~3 rows, with a bottom fade when
/// there's more than that hiding underneath it.
private let mergeSharedListHeight: CGFloat = 160
private let mergeInboxCornerRadius: CGFloat = 10

/// Identifies one column's draggable inbox (native or landed) so its resting frame, reported via
/// `InboxFramePreferenceKey`, can be looked up by whichever one a drag picks up.
private struct InboxFrameKey: Hashable {
    let isCurrentSide: Bool
    let isLanded: Bool
}

private struct InboxFramePreferenceKey: PreferenceKey {
    static var defaultValue: [InboxFrameKey: CGRect] = [:]
    static func reduce(value: inout [InboxFrameKey: CGRect], nextValue: () -> [InboxFrameKey: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Lets the user see exactly which commits a merge would move, in which direction, before
/// anything happens — replacing the old one-click "Merge into X" menu item. Three shapes, driven
/// by `GitRepository.MergePreview.relationship`:
///  - `.identical`: nothing to merge, no drag offered.
///  - `.ancestor`: only one side has unique commits — drag them across into the empty side's
///    drop zone (a fast-forward, or the equivalent non-FF merge).
///  - `.diverged`: both sides have unique commits — either side's commits can be dragged into
///    the other. Only one direction can be committed at a time.
///
/// The drag is real drag-and-drop: the actual commit rows lift and follow the pointer (not an
/// abstract summary), and on a successful drop they render inline in the destination column's
/// list, with the source column left empty. Dropping the landed pile back on the column it came
/// from undoes the merge. The deliberate-action requirement comes from genuinely having to carry
/// the commits across and drop them, not from a separate gesture.
struct MergeSheet: View {
    @Bindable var appState: AppState
    @Binding var isPresented: Bool

    private struct ActiveDrag {
        let direction: AppState.MergeDirection
        let isCurrentSide: Bool
        /// True when this drag picked up a pile that had already landed here from a prior
        /// commit — dropping it on the opposite column undoes that commit rather than making a
        /// fresh one.
        let isUndo: Bool
        let commits: [GitCommit]
        let totalCount: Int
        /// Where the ghost rests when `translation` is zero — the gesture's own start point, so
        /// the ghost begins exactly where the pointer grabbed it instead of snapping to the
        /// content's center. Combined with `translation`, position tracking is then pure
        /// addition, not re-centering, so it has no "pop" to smooth out.
        let anchor: CGPoint
        var translation: CGSize = .zero
        /// Live absolute location, used only to test which column a drop lands on.
        var location: CGPoint
    }

    /// What one column's unique-commit section shows: its own ("native") unique commits, plus —
    /// only once a merge direction has been committed — the other side's commits that landed
    /// here. Kept separate rather than concatenated, so dragging the landed pile back only moves
    /// what was actually dragged in, not the native commits that were already sitting there.
    fileprivate struct UniqueColumnDisplay {
        var landedCommits: [GitCommit] = []
        var landedTotalCount = 0
        var nativeCommits: [GitCommit] = []
        var nativeTotalCount = 0
        /// This side's own commits moved away to the other column.
        var isEmptiedBySource = false
        var isEmpty: Bool { landedTotalCount == 0 && nativeTotalCount == 0 }
    }

    @State private var activeDrag: ActiveDrag?
    /// Resting frame of each column's draggable inbox, kept current via
    /// `InboxFramePreferenceKey` — read once when a drag starts, to anchor the ghost at the real
    /// content's position/size instead of guessing from the click point alone.
    @State private var inboxFrames: [InboxFrameKey: CGRect] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Merge")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            columns()

            warnings

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                Button("Confirm") { appState.confirmMerge() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(appState.mergeCommittedDirection == nil || appState.isMergeConfirming)
            }
        }
        .padding(20)
        .frame(width: 720)
        .onChange(of: appState.mergeOtherBranch) { _, _ in
            activeDrag = nil
            appState.mergeCommittedDirection = nil
            appState.mergeConflictCheck = nil
            appState.mergeDirtyTreeWarningVisible = false
            appState.loadMergePreview()
        }
    }

    // MARK: - Branch picker (always in the "Other branch" header; empty until one's chosen)

    private var otherBranchMenu: some View {
        Menu(appState.mergeOtherBranch?.name ?? "Select Branch") {
            ForEach(appState.branches.filter { !$0.isCurrent }) { branch in
                Button(branch.name) { appState.mergeOtherBranch = branch }
            }
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .fixedSize()
    }

    // MARK: - Columns

    @ViewBuilder
    private func columns() -> some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 0) {
                column(isCurrentSide: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                    .padding(.horizontal, 16)
                column(isCurrentSide: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: mergeColumnsCoordinateSpace)
            .onPreferenceChange(InboxFramePreferenceKey.self) { inboxFrames = $0 }

            // The lifted commits, following the pointer while a drag is in progress — rendered
            // above both columns so it visibly crosses the divider during the drag, not just at
            // the moment it lands. Position is anchor + live translation (not a repeated
            // recentering on the cursor), so it tracks the pointer exactly with no pop and no
            // animation needed to paper over one.
            if let activeDrag {
                commitInboxContent(
                    activeDrag.commits, totalCount: activeDrag.totalCount, isCurrentSide: activeDrag.isCurrentSide,
                    tags: appState.tagsByCommitSHA, unpushedSHAs: appState.unpushedCommitSHAs
                )
                .frame(width: 300, alignment: .leading)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                .position(x: activeDrag.anchor.x + activeDrag.translation.width, y: activeDrag.anchor.y + activeDrag.translation.height)
                .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 380)
    }

    private func column(isCurrentSide: Bool) -> some View {
        let direction: AppState.MergeDirection = isCurrentSide ? .currentIntoOther : .otherIntoCurrent
        let hasOtherBranch = appState.mergeOtherBranch != nil
        let isLoading = appState.isLoadingMergePreview
        let preview = appState.mergePreview

        var display = UniqueColumnDisplay()
        var relationship: GitRepository.MergePreview.Relationship = .diverged
        var sharedCommits: [GitCommit] = []
        var sharedTotalCount = 0
        var emptyPlaceholder: String?

        if isLoading {
            emptyPlaceholder = "Loading\u{2026}"
        } else if !hasOtherBranch {
            if !isCurrentSide { emptyPlaceholder = "Choose a branch above" }
        } else if let preview {
            display = uniqueDisplay(isCurrentSide: isCurrentSide, preview: preview)
            relationship = preview.relationship
            sharedCommits = preview.sharedCommits
            sharedTotalCount = preview.sharedTotalCount
        }

        let isLandedBeingDragged = activeDrag?.isCurrentSide == isCurrentSide && activeDrag?.isUndo == true
        let isNativeBeingDragged = activeDrag?.isCurrentSide == isCurrentSide && activeDrag?.isUndo == false
        // Not gated on `isNativeBeingDragged`: the gesture-bearing view this flag selects between
        // must stay the same view for the whole drag, or the live gesture recognizer detaches
        // mid-drag and freezes it. Hiding it while dragged is handled separately, in
        // `inboxOrPlaceholder`, without changing which view is mounted.
        let isNativeDraggable = appState.mergeCommittedDirection == nil && display.nativeTotalCount > 0

        return MergeColumnView(
            title: isCurrentSide ? "Current branch: \(appState.selectedBranch?.name ?? "")" : "Other branch",
            isOtherColumn: !isCurrentSide,
            relationship: relationship,
            display: display,
            emptyPlaceholder: emptyPlaceholder,
            isLandedBeingDragged: isLandedBeingDragged,
            isNativeBeingDragged: isNativeBeingDragged,
            isNativeDraggable: isNativeDraggable,
            sharedCommits: sharedCommits,
            sharedTotalCount: sharedTotalCount,
            otherBranchMenu: isCurrentSide ? nil : AnyView(otherBranchMenu),
            tags: appState.tagsByCommitSHA,
            unpushedSHAs: appState.unpushedCommitSHAs,
            isCurrentSide: isCurrentSide,
            onNativeDragChanged: { value in
                dragChanged(isCurrentSide: isCurrentSide, direction: direction, isUndo: false, commits: display.nativeCommits, totalCount: display.nativeTotalCount, value: value)
            },
            onNativeDragEnded: { value in dragEnded(isCurrentSide: isCurrentSide, direction: direction, location: value.location) },
            onLandedDragChanged: { value in
                dragChanged(isCurrentSide: isCurrentSide, direction: direction, isUndo: true, commits: display.landedCommits, totalCount: display.landedTotalCount, value: value)
            },
            onLandedDragEnded: { value in dragEnded(isCurrentSide: isCurrentSide, direction: direction, location: value.location) }
        )
    }

    private func dragChanged(
        isCurrentSide: Bool, direction: AppState.MergeDirection, isUndo: Bool, commits: [GitCommit], totalCount: Int,
        value: DragGesture.Value
    ) {
        if activeDrag == nil {
            guard totalCount > 0 else { return }
            // Anchor at the real content's resting center, not the click point — otherwise the
            // ghost (which renders at a fixed width/position via `.position()`) visibly recenters
            // itself under the cursor the instant the drag starts, instead of staying exactly
            // where it already was.
            let frame = inboxFrames[InboxFrameKey(isCurrentSide: isCurrentSide, isLanded: isUndo)]
            let anchor = frame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? value.startLocation
            activeDrag = ActiveDrag(
                direction: direction, isCurrentSide: isCurrentSide, isUndo: isUndo, commits: commits, totalCount: totalCount,
                anchor: anchor, translation: value.translation, location: value.location
            )
        } else if activeDrag?.isCurrentSide == isCurrentSide {
            activeDrag?.translation = value.translation
            activeDrag?.location = value.location
        }
    }

    private func dragEnded(isCurrentSide: Bool, direction: AppState.MergeDirection, location: CGPoint) {
        guard let drag = activeDrag, drag.isCurrentSide == isCurrentSide else { return }
        activeDrag = nil
        let droppedOnOppositeColumn = isCurrentSide ? location.x > mergeColumnsMidX : location.x < mergeColumnsMidX
        if droppedOnOppositeColumn {
            if drag.isUndo {
                appState.mergeDragWasReleasedBeforeThreshold()
            } else {
                appState.mergeDragDidReachThreshold(direction: direction)
            }
        } else if !drag.isUndo {
            appState.mergeDragWasReleasedBeforeThreshold()
        }
        // Dropped back on the same (already-committed) side: nothing to do, it's already there.
    }

    /// Splits a column's unique commits into what's natively its own versus what landed there
    /// from a committed drag — see `UniqueColumnDisplay`.
    private func uniqueDisplay(isCurrentSide: Bool, preview: GitRepository.MergePreview) -> UniqueColumnDisplay {
        let ownCommits = isCurrentSide ? preview.currentUniqueCommits : preview.otherUniqueCommits
        let ownTotal = isCurrentSide ? preview.currentUniqueTotalCount : preview.otherUniqueTotalCount

        guard let direction = appState.mergeCommittedDirection else {
            return UniqueColumnDisplay(nativeCommits: ownCommits, nativeTotalCount: ownTotal)
        }
        let gainedHere = (direction == .otherIntoCurrent && isCurrentSide) || (direction == .currentIntoOther && !isCurrentSide)
        let emptiedHere = (direction == .otherIntoCurrent && !isCurrentSide) || (direction == .currentIntoOther && isCurrentSide)

        if gainedHere {
            let oppositeCommits = isCurrentSide ? preview.otherUniqueCommits : preview.currentUniqueCommits
            let oppositeTotal = isCurrentSide ? preview.otherUniqueTotalCount : preview.currentUniqueTotalCount
            return UniqueColumnDisplay(
                landedCommits: oppositeCommits, landedTotalCount: oppositeTotal,
                nativeCommits: ownCommits, nativeTotalCount: ownTotal
            )
        } else if emptiedHere {
            return UniqueColumnDisplay(isEmptiedBySource: true)
        } else {
            return UniqueColumnDisplay(nativeCommits: ownCommits, nativeTotalCount: ownTotal)
        }
    }

    // MARK: - Post-drag warnings

    private var isConflicting: Bool {
        if case .conflicts = appState.mergeConflictCheck { return true }
        return false
    }

    @ViewBuilder
    private var warnings: some View {
        if let message = appState.mergePreviewErrorMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }

        if appState.isCheckingMergeConflicts {
            Label("Checking for conflicts\u{2026}", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if case .conflicts(let paths) = appState.mergeConflictCheck {
            Label(
                paths.isEmpty
                    ? "This merge will have conflicts."
                    : "This merge will conflict in \(paths.count == 1 ? "1 file" : "\(paths.count) files").",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        } else if let direction = appState.mergeCommittedDirection, !appState.mergeDirtyTreeWarningVisible,
                  let preview = appState.mergePreview {
            let count = direction == .otherIntoCurrent ? preview.otherUniqueTotalCount : preview.currentUniqueTotalCount
            let sourceName = direction == .otherIntoCurrent ? (appState.mergeOtherBranch?.name ?? "") : (appState.selectedBranch?.name ?? "")
            let destinationName = direction == .otherIntoCurrent ? (appState.selectedBranch?.name ?? "") : (appState.mergeOtherBranch?.name ?? "")
            Label(
                "This will merge \(count == 1 ? "1 commit" : "\(count) commits") from \(sourceName) into \(destinationName).",
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if appState.mergeDirtyTreeWarningVisible {
            HStack {
                Label(
                    "You have uncommitted changes. They need to be stashed before switching branches to complete this merge.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                Spacer()
                Button("Stash & Continue") {
                    // `confirmMerge()` reads `mergeDirtyTreeWarningVisible` to decide whether to
                    // stash first — this button just runs the merge immediately with that choice
                    // already made, instead of making the user also hit the main Confirm button.
                    appState.confirmMerge()
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }

        if let message = appState.mergeErrorMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

/// One side of the merge sheet: header, unique-commit section(s), and the shared-ancestry list.
private struct MergeColumnView: View {
    let title: String
    let isOtherColumn: Bool
    let relationship: GitRepository.MergePreview.Relationship
    let display: MergeSheet.UniqueColumnDisplay
    /// Shown inside the empty inbox when there's nothing to show yet (no other branch chosen,
    /// still loading) — `nil` once there's a real (possibly empty) comparison to report.
    let emptyPlaceholder: String?
    let isLandedBeingDragged: Bool
    let isNativeBeingDragged: Bool
    let isNativeDraggable: Bool
    let sharedCommits: [GitCommit]
    let sharedTotalCount: Int
    let otherBranchMenu: AnyView?
    let tags: [String: [GitTag]]
    let unpushedSHAs: Set<String>
    let isCurrentSide: Bool
    let onNativeDragChanged: (DragGesture.Value) -> Void
    let onNativeDragEnded: (DragGesture.Value) -> Void
    let onLandedDragChanged: (DragGesture.Value) -> Void
    let onLandedDragEnded: (DragGesture.Value) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let otherBranchMenu {
                    otherBranchMenu
                }
            }
            .frame(height: 24, alignment: .leading)

            Text(isOtherColumn ? "Changes not on current branch" : "Changes not on other branch")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                if relationship == .identical {
                    inbox(isEmpty: true, label: "Identical")
                } else if display.isEmpty {
                    inbox(isEmpty: true, label: emptyPlaceholder)
                } else {
                    if display.landedTotalCount > 0 {
                        inboxOrPlaceholder(isBeingDragged: isLandedBeingDragged) {
                            draggableInbox(
                                display.landedCommits, totalCount: display.landedTotalCount,
                                frameKey: InboxFrameKey(isCurrentSide: isCurrentSide, isLanded: true),
                                gesture: DragGesture(minimumDistance: 2, coordinateSpace: .named(mergeColumnsCoordinateSpace))
                                    .onChanged { onLandedDragChanged($0) }
                                    .onEnded { onLandedDragEnded($0) }
                            )
                        }
                    }
                    if display.nativeTotalCount > 0 {
                        inboxOrPlaceholder(isBeingDragged: isNativeBeingDragged) {
                            if isNativeDraggable {
                                draggableInbox(
                                    display.nativeCommits, totalCount: display.nativeTotalCount,
                                    frameKey: InboxFrameKey(isCurrentSide: isCurrentSide, isLanded: false),
                                    gesture: DragGesture(minimumDistance: 2, coordinateSpace: .named(mergeColumnsCoordinateSpace))
                                        .onChanged { onNativeDragChanged($0) }
                                        .onEnded { onNativeDragEnded($0) }
                                )
                            } else {
                                inbox(isEmpty: false) {
                                    commitRows(display.nativeCommits, totalCount: display.nativeTotalCount)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if sharedTotalCount > 0 {
                Text("Changes on both branches")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                sharedCommitsFadingList(sharedCommits, totalCount: sharedTotalCount)
            }
        }
    }

    /// `content` (the gesture-bearing view) stays mounted for the whole drag — only hidden under
    /// the dashed placeholder, never swapped out for it — or the live gesture recognizer detaches
    /// mid-drag and freezes.
    @ViewBuilder
    private func inboxOrPlaceholder(isBeingDragged: Bool, @ViewBuilder content: () -> some View) -> some View {
        ZStack(alignment: .topLeading) {
            content()
                .opacity(isBeingDragged ? 0 : 1)
            if isBeingDragged {
                inbox(isEmpty: true, label: "Dragging\u{2026}")
            }
        }
    }

    private func draggableInbox(_ commits: [GitCommit], totalCount: Int, frameKey: InboxFrameKey, gesture: some Gesture) -> some View {
        inbox(isEmpty: false) {
            commitRows(commits, totalCount: totalCount)
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: InboxFramePreferenceKey.self, value: [frameKey: geo.frame(in: .named(mergeColumnsCoordinateSpace))])
            }
        )
        .gesture(gesture)
    }

    /// The bordered "inbox" every unique-commit state renders inside — dashed when there's
    /// nothing in it (optionally with a centered label), solid once it holds real commits.
    @ViewBuilder
    private func inbox(isEmpty: Bool, label: String? = nil, @ViewBuilder content: () -> some View = { EmptyView() }) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: mergeInboxCornerRadius, style: .continuous)
                .strokeBorder(style: isEmpty ? StrokeStyle(lineWidth: 1.5, dash: [6, 4]) : StrokeStyle(lineWidth: 1))
                .foregroundStyle(.secondary.opacity(isEmpty ? 0.5 : 0.25))
            if isEmpty {
                if let label {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                content()
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: isEmpty ? 90 : 0)
        // A `strokeBorder`-only shape otherwise only hit-tests along the drawn line itself, not
        // its interior — without this, clicking empty padding/background inside the box (as
        // opposed to directly on a commit row) wouldn't start the drag at all.
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func commitRows(_ commits: [GitCommit], totalCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(commits) { commit in
                CommitRowView(
                    commit: commit,
                    tags: tags[commit.sha] ?? [],
                    isUnpushed: isCurrentSide && unpushedSHAs.contains(commit.sha),
                    showFullCommitTitle: false,
                    showCommitDescription: false
                )
                if commit.id != commits.last?.id { Divider() }
            }
            if totalCount > commits.count {
                Text("+\(totalCount - commits.count) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        }
    }

    /// Shows at most 3 rows' worth of height, fading the bottom row(s) out when there's more —
    /// a hint that the list continues rather than a literal count.
    private func sharedCommitsFadingList(_ commits: [GitCommit], totalCount: Int) -> some View {
        let hasOverflow = commits.count > 3
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(commits) { commit in
                CommitRowView(
                    commit: commit,
                    tags: tags[commit.sha] ?? [],
                    isUnpushed: false,
                    showFullCommitTitle: false,
                    showCommitDescription: false
                )
                Divider()
            }
        }
        .frame(height: mergeSharedListHeight, alignment: .top)
        .clipped()
        .mask(alignment: .top) {
            if hasOverflow {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.65),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            } else {
                Color.black
            }
        }
    }
}

/// The lifted ghost's content while a drag is in progress — same row rendering as a column's
/// inbox, but with its own opaque background/border since it floats freely over both columns
/// rather than sitting inside a column's own layout.
@ViewBuilder
private func commitInboxContent(
    _ commits: [GitCommit], totalCount: Int, isCurrentSide: Bool,
    tags: [String: [GitTag]], unpushedSHAs: Set<String>
) -> some View {
    ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: mergeInboxCornerRadius, style: .continuous)
            .fill(.background)
        RoundedRectangle(cornerRadius: mergeInboxCornerRadius, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(commits) { commit in
                CommitRowView(
                    commit: commit,
                    tags: tags[commit.sha] ?? [],
                    isUnpushed: isCurrentSide && unpushedSHAs.contains(commit.sha),
                    showFullCommitTitle: false,
                    showCommitDescription: false
                )
                if commit.id != commits.last?.id { Divider() }
            }
            if totalCount > commits.count {
                Text("+\(totalCount - commits.count) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        }
        .padding(8)
    }
    .fixedSize(horizontal: false, vertical: true)
}
