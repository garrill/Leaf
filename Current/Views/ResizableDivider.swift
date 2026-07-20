import SwiftUI

/// A draggable divider that adjusts `width` within [minWidth, maxWidth].
/// Used to size the column directly to its leading side.
struct ResizableDivider: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Divider()
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        // .global coordinates: translation must track raw cursor movement,
                        // not the divider's own frame, which shifts as `width` changes mid-drag
                        // (using .local here causes a feedback loop: half-speed, oscillating drag).
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if dragStartWidth == nil { dragStartWidth = width }
                                let base = dragStartWidth ?? width
                                width = min(max(base + value.translation.width, minWidth), maxWidth)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
            )
    }
}
