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
    @ObservedObject private var repoSelection = RepoSelectionObservable.shared
    @AppStorage(LeafSettings.externalEditorPathKey, store: LeafSettings.store) private var externalEditorPath = ""
    @AppStorage(LeafSettings.showRepoStatusKey, store: LeafSettings.store) private var showRepoStatus = LeafSettings.defaultShowRepoStatus
    @AppStorage(LeafSettings.showFullCommitTitleKey, store: LeafSettings.store) private var showFullCommitTitle = LeafSettings.defaultShowFullCommitTitle
    @AppStorage(LeafSettings.syntaxHighlightingEnabledKey, store: LeafSettings.store) private var syntaxHighlightingEnabled = LeafSettings.defaultSyntaxHighlightingEnabled
    @AppStorage(LeafSettings.hideWhitespaceChangesKey, store: LeafSettings.store) private var hideWhitespaceChanges = LeafSettings.defaultHideWhitespaceChanges
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
            CommandGroup(replacing: .newItem) {
                Button("New Window") { appDelegate.showMainWindow() }
                    .keyboardShortcut("n", modifiers: [.command])

                Divider()

                Button("Add Repository") { AppStateHolder.shared?.addRepoViaPicker() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Clone Repository…") { AppStateHolder.shared?.isCloneSheetPresented = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command])
            }
            CommandGroup(replacing: .saveItem) { }
            CommandGroup(replacing: .sidebar) {
                Button(sidebarVisibility.isCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .control])

                Divider()

                Button(showRepoStatus ? "Hide Repository Status" : "Show Repository Status") {
                    showRepoStatus.toggle()
                }
                Button(showFullCommitTitle ? "Truncate Commit Title" : "Show Full Commit Title") {
                    showFullCommitTitle.toggle()
                }
                Button(syntaxHighlightingEnabled ? "Disable Syntax Highlighting" : "Enable Syntax Highlighting") {
                    syntaxHighlightingEnabled.toggle()
                }
                Button(hideWhitespaceChanges ? "Show Whitespace Changes" : "Hide Whitespace Changes") {
                    hideWhitespaceChanges.toggle()
                }

                Divider()
            }
            CommandMenu("Repository") {
                Button("Push") { AppStateHolder.shared?.pushCurrentBranch() }
                    .keyboardShortcut("p", modifiers: [.command])
                    .disabled(!repoSelection.hasSelection)
                Button("Pull") { AppStateHolder.shared?.pullCurrentBranch() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!repoSelection.hasSelection)
                Button("Fetch") { AppStateHolder.shared?.fetchRemote() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!repoSelection.hasSelection)
                Button("Remove") { AppStateHolder.shared?.removeSelectedRepo() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(!repoSelection.hasSelection)

                Divider()

                Button("Show in Finder") { AppStateHolder.shared?.revealSelectedRepoInFinder() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(!repoSelection.hasSelection)
                Button(openInApplicationTitle) { AppStateHolder.shared?.openSelectedRepoInDefaultApplication() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!repoSelection.hasSelection)

                Divider()

                Button("Rename") { AppStateHolder.shared?.startRenamingSelectedRepo() }
                    .disabled(!repoSelection.hasSelection)
                Button("Choose Icon…") { AppStateHolder.shared?.chooseIconForSelectedRepo() }
                    .disabled(!repoSelection.hasSelection)
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
