import AppKit
import SwiftUI

/// Configures the hosting NSWindow directly for a title-text-free title bar that blends into
/// the SwiftUI-managed `.toolbar { }` content (attached separately via the `toolbar` modifier
/// on the view hierarchy) while the close/minimize/zoom buttons stay visible and functional.
/// The window's title text itself is left to SwiftUI's own `.navigationTitle` management
/// (see `MainWindowView`) rather than set here — setting `window.title` directly from this
/// async-dispatched configure step raced with SwiftUI's own title updates and could leave the
/// title stuck on the app's default name after switching repos.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.styleMask.insert(.fullSizeContentView)
    }
}
