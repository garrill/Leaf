import AppKit
import SwiftUI

/// Renders an image file's diff by comparing its "before" and "after" bytes directly, since a
/// textual `git diff` is meaningless for images. Offers a side-by-side layout or a draggable
/// before/after swiper, with size/dimension info for each side underneath.
struct ImageDiffView: View {
    @Bindable var appState: AppState

    private enum Mode: String, CaseIterable, Identifiable {
        case sideBySide = "Side by Side"
        case swiper = "Swiper"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .sideBySide

    private var oldImage: NSImage? { appState.imageDiffOld.flatMap(NSImage.init(data:)) }
    private var newImage: NSImage? { appState.imageDiffNew.flatMap(NSImage.init(data:)) }

    var body: some View {
        if oldImage == nil || newImage == nil {
            singleImageLayout
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 16) {
                Picker("View Mode", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                .padding(.top, 16)

                switch mode {
                case .sideBySide: sideBySideLayout
                case .swiper: swiperLayout
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A file that's purely added or removed has only one side to show — the tab picker and
    /// Before/After labels would be redundant, so just show the one image full-bleed (dimensions
    /// and file size are still worth keeping, just without the now-meaningless side label).
    private var singleImageLayout: some View {
        let image = newImage ?? oldImage
        let data = newImage != nil ? appState.imageDiffNew : appState.imageDiffOld
        return VStack(spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.secondary.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                        .overlay(Text("No Preview Available").font(.callout).foregroundStyle(.secondary))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(metadataText(image: image, data: data))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var sideBySideLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            pane(title: "Before", image: oldImage, data: appState.imageDiffOld, emptyReason: "No Previous Version")
            pane(title: "After", image: newImage, data: appState.imageDiffNew, emptyReason: "File Deleted")
        }
        .padding([.horizontal, .bottom], 20)
    }

    private var swiperLayout: some View {
        VStack(spacing: 8) {
            ImageSwiperView(before: oldImage, after: newImage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)

            HStack(spacing: 32) {
                metadataLabel(title: "Before", image: oldImage, data: appState.imageDiffOld)
                metadataLabel(title: "After", image: newImage, data: appState.imageDiffNew)
            }
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private func pane(title: String, image: NSImage?, data: Data?, emptyReason: String) -> some View {
        VStack(spacing: 8) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                    .overlay(Text(emptyReason).font(.callout).foregroundStyle(.secondary))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            metadataLabel(title: title, image: image, data: data)
        }
        .frame(maxWidth: .infinity)
    }

    private func metadataLabel(title: String, image: NSImage?, data: Data?) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(metadataText(image: image, data: data))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func metadataText(image: NSImage?, data: Data?) -> String {
        guard let image, let data else { return "—" }
        let pixelSize = image.pixelSize
        let dimensions = "\(Int(pixelSize.width))×\(Int(pixelSize.height))"
        return "\(dimensions) · \(Self.byteFormatter.string(fromByteCount: Int64(data.count)))"
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

private extension NSImage {
    /// `NSImage.size` is the logical (point) size, which is wrong for high-DPI or oddly-tagged
    /// images; use the backing bitmap's actual pixel dimensions instead.
    var pixelSize: CGSize {
        guard let rep = representations.first else { return size }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

/// A draggable divider that reveals the "before" image on the left and "after" on the right.
private struct ImageSwiperView: View {
    let before: NSImage?
    let after: NSImage?

    @State private var position: CGFloat = 0.5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.06))

                if let after {
                    Image(nsImage: after)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .mask(alignment: .trailing) {
                            Rectangle().frame(width: geo.size.width * (1 - position))
                        }
                } else {
                    Text("File Deleted")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: geo.size.width, height: geo.size.height)
                }

                if let before {
                    Image(nsImage: before)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geo.size.width * position)
                        }
                }

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2)
                    .shadow(radius: 1)
                    .position(x: geo.size.width * position, y: geo.size.height / 2)

                Circle()
                    .fill(Color.white)
                    .frame(width: 26, height: 26)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.caption2).foregroundStyle(.black))
                    .shadow(radius: 2)
                    .position(x: geo.size.width * position, y: geo.size.height / 2)
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    position = min(max(0, value.location.x / geo.size.width), 1)
                }
            )
        }
    }
}
