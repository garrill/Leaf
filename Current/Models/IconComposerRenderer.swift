import AppKit
import Foundation

/// Renders a preview `NSImage` for a custom repo icon path chosen via the file picker.
///
/// Icon Composer (`.icon`) files are directory bundles — an `icon.json` layer spec plus an
/// `Assets` folder of SVG/PNG layer images — not a single image `NSImage(contentsOfFile:)` can
/// load directly. Xcode itself compiles these into `.icns`/asset-catalog icons at build time;
/// there's no public API for rendering one ad hoc at runtime. This is a practical approximation,
/// not a faithful Icon Composer renderer: it draws a rounded-square backdrop from the top-level
/// `fill`, then composites each group's layer images centered on top, tinted by the layer's own
/// `fill` (solid or linear-gradient) when present. It intentionally ignores shadows,
/// translucency, and exact per-layer `position.scale`/`translation` semantics — good enough for
/// a small sidebar glyph, not pixel-identical to the real icon.
enum IconComposerRenderer {
    private static var cache: [String: NSImage] = [:]

    static func image(forIconPath path: String, size: CGFloat) -> NSImage? {
        let cacheKey = "\(path)@\(size)"
        if let cached = cache[cacheKey] { return cached }

        let url = URL(fileURLWithPath: path)
        let image: NSImage?
        if url.pathExtension.lowercased() == "icon" {
            image = renderIconBundle(at: url, size: size)
        } else {
            image = NSImage(contentsOfFile: path)
        }

        if let image {
            cache[cacheKey] = image
        }
        return image
    }

    private struct IconSpec: Decodable {
        var fill: FillSpec?
        var groups: [GroupSpec]?
    }

    private struct GroupSpec: Decodable {
        var layers: [LayerSpec]?
    }

    private struct LayerSpec: Decodable {
        var fill: FillSpec?
        var imageName: String?

        enum CodingKeys: String, CodingKey {
            case fill
            case imageName = "image-name"
        }
    }

    /// Only the two fill shapes actually used by Icon Composer's `fill` field are handled: a
    /// flat color/gradient keyword (`automatic-gradient`), or an explicit two-stop
    /// `linear-gradient` array. Anything else (radial gradients, etc.) falls back to gray.
    private struct FillSpec: Decodable {
        var automaticGradient: String?
        var linearGradient: [String]?

        enum CodingKeys: String, CodingKey {
            case automaticGradient = "automatic-gradient"
            case linearGradient = "linear-gradient"
        }

        var colors: [NSColor] {
            if let linearGradient {
                return linearGradient.compactMap(Self.color(fromExtendedSRGB:))
            }
            if let automaticGradient, let color = Self.color(fromExtendedSRGB: automaticGradient) {
                return [color]
            }
            return [.systemGray]
        }

        /// Parses Icon Composer's `"extended-srgb:r,g,b,a"` / `"extended-gray:w,a"` color strings.
        nonisolated private static func color(fromExtendedSRGB spec: String) -> NSColor? {
            let parts = spec.split(separator: ":")
            guard parts.count == 2 else { return nil }
            let components = parts[1].split(separator: ",").compactMap { Double($0) }
            if (parts[0] == "extended-srgb" || parts[0] == "srgb"), components.count >= 4 {
                return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: components[3])
            }
            if (parts[0] == "extended-gray" || parts[0] == "gray"), components.count >= 2 {
                return NSColor(white: components[0], alpha: components[1])
            }
            return nil
        }
    }

    private static func renderIconBundle(at bundleURL: URL, size: CGFloat) -> NSImage? {
        let specURL = bundleURL.appendingPathComponent("icon.json")
        guard let data = try? Data(contentsOf: specURL),
              let spec = try? JSONDecoder().decode(IconSpec.self, from: data) else {
            return nil
        }
        let assetsURL = bundleURL.appendingPathComponent("Assets")

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let backgroundRect = NSRect(x: 0, y: 0, width: size, height: size)
        let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: size * 0.22, yRadius: size * 0.22)
        drawFill(spec.fill, colors: spec.fill?.colors ?? [.systemGray], in: backgroundPath, rect: backgroundRect)

        let inset = size * 0.16
        let layerRect = backgroundRect.insetBy(dx: inset, dy: inset)
        for group in spec.groups ?? [] {
            for layer in group.layers ?? [] {
                guard let imageName = layer.imageName,
                      let layerImage = NSImage(contentsOf: assetsURL.appendingPathComponent(imageName)) else { continue }
                draw(layerImage, tintedWith: layer.fill, in: layerRect)
            }
        }

        image.unlockFocus()
        return image
    }

    private static func drawFill(_ fill: FillSpec?, colors: [NSColor], in path: NSBezierPath, rect: NSRect) {
        if colors.count >= 2, let gradient = NSGradient(starting: colors[0], ending: colors[1]) {
            gradient.draw(in: path, angle: -90)
        } else {
            (colors.first ?? .systemGray).setFill()
            path.fill()
        }
    }

    /// Draws `layerImage` scaled to fit `rect`, then — if the layer specifies a solid/gradient
    /// `fill` — recolors it by drawing that fill masked to the image's own alpha, matching how
    /// Icon Composer treats monochrome template layers.
    private static func draw(_ layerImage: NSImage, tintedWith fill: FillSpec?, in rect: NSRect) {
        let imageSize = layerImage.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawOrigin = NSPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
        let drawRect = NSRect(origin: drawOrigin, size: drawSize)

        guard let fill, !fill.colors.isEmpty else {
            layerImage.draw(in: drawRect)
            return
        }

        // Render the tint (solid or gradient) into a same-sized image, then mask it to the
        // layer artwork's own alpha channel, so the artwork's silhouette gets recolored.
        let colors = fill.colors
        let tinted = NSImage(size: drawSize)
        tinted.lockFocus()
        let localRect = NSRect(origin: .zero, size: drawSize)
        if colors.count >= 2, let gradient = NSGradient(starting: colors[0], ending: colors[1]) {
            gradient.draw(in: localRect, angle: -90)
        } else {
            colors[0].setFill()
            localRect.fill()
        }
        layerImage.draw(in: localRect, from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()

        tinted.draw(in: drawRect)
    }
}
