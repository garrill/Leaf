import AppKit
import SwiftUI

/// The palette card: search field on top, then up to `PaletteMatcher.maxResults` rows, then a
/// footer naming what Return (and ⌥/⇧/⌘-Return) will do for the selected row. A plain
/// `VStack` rather than a `List`/`ScrollView` — there are never more than nine rows, and a
/// stack lays out instantly with no cell reuse or selection machinery to fight.
struct CommandPaletteView: View {
    let model: CommandPaletteModel
    let appState: AppState
    let onRun: (PaletteItem, PaletteModifier?) -> Void
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
                    .accessibilityHidden(true)
                PaletteTextField(
                    model: model,
                    onRun: { modifier in
                        if let item = model.selectedItem { onRun(item, modifier) }
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
                            appState: appState,
                            onRun: { modifier in onRun(item, modifier) }
                        )
                        .onHover { hovering in
                            if hovering {
                                hoveredItemID = item.id
                            } else if hoveredItemID == item.id {
                                hoveredItemID = nil
                            }
                        }
                        // Double-click runs (holding ⌥/⇧/⌘ runs that alternate); the single-click
                        // select is simultaneous rather than a competing `count: 1` tap, which
                        // SwiftUI would hold back until the double-click interval expired —
                        // selection lands on mouse-up instantly.
                        .gesture(TapGesture(count: 2).onEnded {
                            onRun(item, PaletteModifier(flags: NSEvent.modifierFlags))
                        })
                        .simultaneousGesture(TapGesture().onEnded { model.selectedIndex = index })
                    }
                }
                .padding(6)

                if let selected = model.selectedItem {
                    Divider()
                    PaletteFooter(item: selected)
                }
            } else if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Divider()
                Text("No matching repositories, branches, commits, files or commands")
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
        // VoiceOver stays in the search field while ↑/↓ move the selection, so the rows'
        // `isSelected` trait alone is never read out — announce the selected row instead.
        .onChange(of: announcementKey) {
            announceSelection()
        }
    }

    private var announcementKey: String {
        "\(model.selectedItem?.id ?? "")|\(model.results.count)|\(model.query.isEmpty)"
    }

    private func announceSelection() {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        let text: String
        if let item = model.selectedItem {
            var parts = [item.displayTitle]
            if let reason = item.unavailableReason {
                parts.append("unavailable, \(reason)")
            } else if let subtitle = item.subtitle {
                parts.append(subtitle)
            }
            parts.append("\(model.selectedIndex + 1) of \(model.results.count)")
            text = parts.joined(separator: ", ")
        } else if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            text = "No results"
        } else {
            return
        }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

/// "↩ Open   ⌥↩ Show in Finder   ⇧↩ Copy Path" for the selected row. Always present while
/// there are results (even for a row with no alternates), so the card's height doesn't jump as
/// the selection moves.
private struct PaletteFooter: View {
    let item: PaletteItem

    var body: some View {
        HStack(spacing: 14) {
            if item.isEnabled {
                hint("\u{21A9}", item.actionLabel)
            } else if item.needsArgument {
                hint("\u{21A9}", "Type \(item.argumentPlaceholder ?? "argument")")
            } else {
                Text("Unavailable")
                    .foregroundStyle(.tertiary)
            }
            ForEach(PaletteModifier.allCases, id: \.self) { modifier in
                if let alternate = item.alternate(for: modifier) {
                    hint("\(modifier.glyph)\u{21A9}", alternate.title)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        // Each row exposes these as named accessibility actions instead.
        .accessibilityHidden(true)
    }

    private func hint(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            Text(keys).foregroundStyle(.tertiary)
            Text(title).foregroundStyle(.secondary)
        }
    }
}

private struct CommandPaletteRow: View {
    let item: PaletteItem
    let index: Int
    let isSelected: Bool
    let isHovered: Bool
    let appState: AppState
    let onRun: (PaletteModifier?) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                titleText
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

            if let status = repoStatus, item.isEnabled {
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
        // Unavailable rows recede but stay readable — they're there to explain themselves.
        .opacity(item.isEnabled ? 1 : 0.5)
        .padding(.horizontal, 10)
        .frame(height: subtitle == nil ? 32 : 42)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundColor)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.displayTitle)
        .accessibilityValue(item.unavailableReason.map { "Unavailable, \($0)" } ?? subtitle ?? "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(item.isEnabled ? item.actionLabel : "")
        .accessibilityAction { onRun(nil) }
        .accessibilityActions {
            ForEach(PaletteModifier.allCases, id: \.self) { modifier in
                if let alternate = item.alternate(for: modifier) {
                    Button(alternate.title) { onRun(modifier) }
                }
            }
        }
    }

    /// Selected (keyboard/click) is stronger than hovered, so the pointer resting on a row never
    /// reads as moving the selection that Return would run.
    private var backgroundColor: Color {
        if isSelected { return Color.primary.opacity(0.09) }
        if isHovered { return Color.primary.opacity(0.04) }
        return .clear
    }

    /// "Leaf – Rename" / "View › Hide Sidebar": the repo or menu dimmed, the action itself at
    /// full strength, with the letters the query matched in bold.
    private var titleText: Text {
        let title = Text(highlightedTitle)
        guard let prefix = item.displayPrefix else { return title }
        return Text("\(Text(prefix).fontWeight(titleWeight).foregroundStyle(.secondary))\(title)")
    }

    /// Light text on a dark background renders visibly heavier, which made the bold matched
    /// letters hard to tell apart in dark mode — so the unmatched text drops a weight there.
    private var titleWeight: Font.Weight {
        colorScheme == .dark ? .regular : .medium
    }

    private var highlightedTitle: AttributedString {
        var result = AttributedString(item.title)
        result.font = .body.weight(titleWeight)
        guard !item.matchedIndices.isEmpty else { return result }
        let matched = Set(item.matchedIndices)
        var index = result.startIndex
        var offset = 0
        while index < result.endIndex {
            let next = result.characters.index(after: index)
            if matched.contains(offset) {
                result[index..<next].font = .body.weight(.bold)
            }
            index = next
            offset += 1
        }
        return result
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
        if let reason = item.unavailableReason { return reason }
        if let repo {
            var parts: [String] = []
            if let branch = repoStatus?.currentBranch { parts.append(branch) }
            if let date = repoStatus?.lastCommitDate {
                parts.append(date.formatted(.relative(presentation: .named)))
            }
            if repo.path == appState.selectedRepoURL?.path { parts.append("Open") }
            return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
        }
        if let date = item.date {
            let relative = date.formatted(.relative(presentation: .named))
            return item.subtitle.map { "\($0) \u{00B7} \(relative)" } ?? relative
        }
        return item.subtitle
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
