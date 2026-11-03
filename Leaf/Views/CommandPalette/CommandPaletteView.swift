import SwiftUI

/// The palette card: search field on top, then up to `PaletteMatcher.maxResults` rows. A plain
/// `VStack` rather than a `List`/`ScrollView` — there are never more than nine rows, and a stack
/// lays out instantly with no cell reuse or selection machinery to fight.
struct CommandPaletteView: View {
    let model: CommandPaletteModel
    let appState: AppState
    let onRun: (PaletteItem) -> Void
    let onCancel: () -> Void
    /// Reports the card's height so the panel can resize itself to fit, keeping its top edge fixed.
    let onHeightChange: (CGFloat) -> Void

    static let width: CGFloat = 640
    /// Transparent margin between the card and the panel's edges, so the card's shadow has room
    /// to render instead of being clipped to the window bounds.
    static let shadowInset: CGFloat = 40

    /// The row under the pointer — tracked by id, not index, so a row that filters away while
    /// hovered can't leave its highlight on whichever row takes its place.
    @State private var hoveredItemID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                PaletteTextField(
                    model: model,
                    onRun: {
                        if let item = model.selectedItem { onRun(item) }
                    },
                    onCancel: onCancel
                )
                .frame(height: 28)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !model.results.isEmpty {
                Divider()
                VStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        CommandPaletteRow(
                            item: item,
                            index: index,
                            isSelected: index == model.selectedIndex,
                            isHovered: item.id == hoveredItemID,
                            appState: appState
                        )
                        .onHover { hovering in
                            if hovering {
                                hoveredItemID = item.id
                            } else if hoveredItemID == item.id {
                                hoveredItemID = nil
                            }
                        }
                        // Double-click runs; the single-click select is simultaneous rather than
                        // a competing `count: 1` tap, which SwiftUI would hold back until the
                        // double-click interval expired — selection lands on mouse-up instantly.
                        .gesture(TapGesture(count: 2).onEnded { onRun(item) })
                        .simultaneousGesture(TapGesture().onEnded { model.selectedIndex = index })
                    }
                }
                .padding(6)
            } else if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Divider()
                Text("No matching repositories, branches or commands")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: Self.width)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onHeightChange(height)
        }
        .padding(Self.shadowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct CommandPaletteRow: View {
    let item: PaletteItem
    let index: Int
    let isSelected: Bool
    let isHovered: Bool
    let appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                titleText
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            if let status = repoStatus {
                RepoStatusIndicators(status: status)
            }
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            Text(isSelected ? "\u{21A9}" : "\u{2318}\(index + 1)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(isSelected ? .secondary : .tertiary)
                .frame(minWidth: 26, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: subtitle == nil ? 32 : 42)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundColor)
        )
        .contentShape(Rectangle())
    }

    /// Selected (keyboard/click) is stronger than hovered, so the pointer resting on a row never
    /// reads as moving the selection that Return would run.
    private var backgroundColor: Color {
        if isSelected { return Color.primary.opacity(0.09) }
        if isHovered { return Color.primary.opacity(0.04) }
        return .clear
    }

    /// "Leaf – Rename" / "View > Hide Sidebar": the repo or menu dimmed, the action itself at
    /// full strength.
    private var titleText: Text {
        guard let prefix = item.displayPrefix else { return Text(item.title) }
        return Text("\(Text(prefix).foregroundStyle(.secondary))\(item.title)")
    }

    private var repo: SidebarRepo? {
        if case .repo(let repo) = item.kind { return repo }
        return nil
    }

    /// Read live from `RepoStatusStore` (not snapshotted into the item) so the palette's
    /// open-time `refreshAll` lands in rows already on screen.
    private var repoStatus: GitRepository.SidebarSyncStatus? {
        guard let repo else { return nil }
        return appState.repoStatusStore.statuses[repo.path]
    }

    private var subtitle: String? {
        guard let repo else { return item.subtitle }
        if let missing = item.subtitle { return missing }
        var parts: [String] = []
        if let branch = repoStatus?.currentBranch { parts.append(branch) }
        if let date = repoStatus?.lastCommitDate {
            parts.append(date.formatted(.relative(presentation: .named)))
        }
        if repo.path == appState.selectedRepoURL?.path { parts.append("Open") }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private var icon: some View {
        if let repo {
            RepoIconView(iconPath: repo.iconPath)
        } else {
            Image(systemName: item.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
