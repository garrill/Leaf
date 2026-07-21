import AppKit
import SwiftUI

/// Configures the hosting NSWindow directly for a title-text-free title bar that blends into
/// the SwiftUI-managed `.toolbar { }` content (attached separately via the `toolbar` modifier
/// on the view hierarchy) while the close/minimize/zoom buttons stay visible and functional.
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
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
    }
}
