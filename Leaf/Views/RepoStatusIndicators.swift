import AppKit
import SwiftUI

/// A repo's icon — its chosen custom icon if it has one, otherwise the default closed-book
/// symbol. Shared by the sidebar's `RepoRowView` and the command palette's repo rows.
struct RepoIconView: View {
    let iconPath: String?

    var body: some View {
        if let iconPath, let nsImage = IconComposerRenderer.image(forIconPath: iconPath, size: 32) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "book.closed.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        }
    }
}

/// The uncommitted-changes dot plus behind/ahead arrows. Shared by the sidebar's `RepoRowView`
/// and the command palette's repo rows, so both read identically.
struct RepoStatusIndicators: View {
    let status: GitRepository.SidebarSyncStatus

    var body: some View {
        HStack(spacing: 4) {
            if status.uncommittedChangeCount > 0 {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .help(status.uncommittedChangeCount == 1 ? "1 uncommitted change" : "\(status.uncommittedChangeCount) uncommitted changes")
            }
            if status.hasUpstream, status.behindCount > 0 {
                SidebarSyncArrowIconView(
                    systemName: "arrow.down",
                    baseColor: NSColor(red: 0x40 / 255, green: 0x86 / 255, blue: 0xDC / 255, alpha: 1)
                )
                .frame(width: 9, height: 9)
                .offset(x: 1)
                .help(status.behindCount == 1 ? "1 commit behind" : "\(status.behindCount) commits behind")
            }
            if status.hasUpstream, status.aheadCount > 0 {
                SidebarSyncArrowIconView(
                    systemName: "arrow.up",
                    baseColor: NSColor(red: 0x40 / 255, green: 0xDC / 255, blue: 0x81 / 255, alpha: 1)
                )
                .frame(width: 9, height: 9)
                .offset(x: 1)
                .help(status.aheadCount == 1 ? "1 commit to push" : "\(status.aheadCount) commits to push")
            }
        }
    }
}
