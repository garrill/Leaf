import AppKit
import SwiftUI

/// Configures the hosting NSWindow directly for a flush, traffic-light-only title bar:
/// no title text, no reserved toolbar strip, content extends to the very top of the window
/// while the close/minimize/zoom buttons stay visible and functional.
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
        window.toolbar = nil
    }
}
