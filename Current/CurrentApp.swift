//
//  CurrentApp.swift
//  Current
//
//  Created by Jonny Garrill on 20/07/2026.
//

import SwiftUI

/// No `WindowGroup` here — the window itself is AppKit-owned (`AppDelegate` builds a
/// `MainWindowController`), because pinning a toolbar item to an interior split-view divider
/// requires a real `NSSplitViewController` + `NSTrackingSeparatorToolbarItem`, which
/// `NavigationSplitView` can't provide. `Settings` with an empty body is the standard way to give
/// an `App` a valid `Scene` without SwiftUI creating one of its own.
@main
struct CurrentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
