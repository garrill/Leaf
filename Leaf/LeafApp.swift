//
//  LeafApp.swift
//  Leaf
//
//  Created by Jonny Garrill on 20/07/2026.
//

import AppKit
import Sparkle
import SwiftUI

/// No `WindowGroup` here — the window itself is AppKit-owned (`AppDelegate` builds a
/// `MainWindowController`), because pinning a toolbar item to an interior split-view divider
/// requires a real `NSSplitViewController` + `NSTrackingSeparatorToolbarItem`, which
/// `NavigationSplitView` can't provide. The `Settings` scene both gives the app its Preferences
/// window (opened via the standard Cmd+, item, added automatically once this scene exists) and
/// satisfies SwiftUI's requirement for a valid `Scene` without it creating a stray `WindowGroup`.
@main
struct LeafApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var sidebarVisibility = SidebarVisibility.shared
    @AppStorage(LeafSettings.externalEditorPathKey, store: LeafSettings.store) private var externalEditorPath = ""
    @StateObject private var checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: UpdaterHolder.shared.updater)

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdaterHolder.shared.checkForUpdates(nil)
                }
                .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
            }
            CommandGroup(replacing: .sidebar) {
                Button(sidebarVisibility.isCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
            CommandMenu("Repository") {
                Button("Push") { AppStateHolder.shared?.pushCurrentBranch() }
                    .keyboardShortcut("p", modifiers: [.command])
                Button("Pull") { AppStateHolder.shared?.pullCurrentBranch() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Fetch") { AppStateHolder.shared?.fetchRemote() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Remove") { AppStateHolder.shared?.removeSelectedRepo() }
                    .keyboardShortcut(.delete, modifiers: [.command])

                Divider()

                Button("Show in Finder") { AppStateHolder.shared?.revealSelectedRepoInFinder() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button(openInApplicationTitle) { AppStateHolder.shared?.openSelectedRepoInDefaultApplication() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])

                Divider()

                Button("Rename") { AppStateHolder.shared?.startRenamingSelectedRepo() }
                Button("Choose Icon…") { AppStateHolder.shared?.chooseIconForSelectedRepo() }
            }
            CommandGroup(replacing: .help) {
                Button("Leaf Help") {
                    NSWorkspace.shared.open(AppLinks.helpURL)
                }
                Button("Report an Issue…") {
                    NSWorkspace.shared.open(AppLinks.issuesURL)
                }
            }
        }
    }

    private var openInApplicationTitle: String {
        guard !externalEditorPath.isEmpty else { return "Open in Default Application" }
        return "Open in \(FileManager.default.displayName(atPath: externalEditorPath))"
    }
}

enum AppLinks {
    static let issuesURL = URL(string: "https://github.com/garrill/Leaf/issues/new")!
    static let helpURL = URL(string: "https://github.com/garrill/Leaf#readme")!
}
