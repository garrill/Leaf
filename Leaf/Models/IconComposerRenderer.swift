import AppKit
import Foundation

/// Renders a preview `NSImage` for a custom repo icon path chosen via the file picker.
///
/// Icon Composer (`.icon`) files are directory bundles — an `icon.json` layer spec plus an
/// `Assets` folder of SVG/PNG layer images — not a single image `NSImage(contentsOfFile:)` can
/// load directly. Xcode itself compiles these into `.icns`/asset-catalog icons at build time;
/// there's no public API for rendering one ad hoc at runtime. This is a practical approximation,
/// not a faithful Icon Composer renderer: it draws a rounded-square backdrop from the top-level
/// `fill`, then composites each layer image onto Icon Composer's 1024pt canvas at its own
/// `position` (scale + translation from center, y-down), tinted by the layer's `fill` (solid or
/// linear-gradient, honoring `orientation`), faded by group/layer opacity, and composites each
/// group with its blend mode. `icon.json` lists the front-most group/layer first, so both are
/// drawn in reverse. It intentionally ignores shadows, specular, refraction, and translucency —
/// good enough for a small sidebar glyph, not pixel-identical to the real icon.
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
        var hidden: Bool?
        var opacity: Double?
        var opacitySpecializations: [Specialization<Double>]?
        var blendMode: String?
        var blendModeSpecializations: [Specialization<String>]?

        enum CodingKeys: String, CodingKey {
            case layers, hidden, opacity
            case opacitySpecializations = "opacity-specializations"
            case blendMode = "blend-mode"
            case blendModeSpecializations = "blend-mode-specializations"
        }

        var resolvedOpacity: Double { opacity ?? Specialization.defaultValue(opacitySpecializations) ?? 1 }
        var resolvedBlendMode: CGBlendMode { cgBlendMode(blendMode ?? Specialization.defaultValue(blendModeSpecializations)) }
    }

    private struct LayerSpec: Decodable {
        var fill: FillSpec?
        var imageName: String?
        var hidden: Bool?
        var opacity: Double?
        var opacitySpecializations: [Specialization<Double>]?
        var position: PositionSpec?

        enum CodingKeys: String, CodingKey {
            case fill, hidden, opacity, position
            case imageName = "image-name"
            case opacitySpecializations = "opacity-specializations"
        }

        var resolvedOpacity: Double { opacity ?? Specialization.defaultValue(opacitySpecializations) ?? 1 }
    }

    /// Maps Icon Composer's kebab-case blend-mode names onto Core Graphics; unknown → normal.
    private static func cgBlendMode(_ name: String?) -> CGBlendMode {
        switch name {
        case "multiply": .multiply
        case "screen": .screen
        case "overlay": .overlay
        case "darken": .darken
        case "lighten": .lighten
        case "color-dodge": .colorDodge
        case "color-burn": .colorBurn
        case "soft-light": .softLight
        case "hard-light": .hardLight
        case "difference": .difference
        case "exclusion": .exclusion
        case "hue": .hue
        case "saturation": .saturation
        case "color": .color
        case "luminosity": .luminosity
        case "plus-darker": .plusDarker
        case "plus-lighter": .plusLighter
        default: .normal
        }
    }

    /// A per-appearance override list; the entry with no `appearance` is the light/default one.
    private struct Specialization<Value: Decodable>: Decodable {
        var appearance: String?
        var value: Value

        static func defaultValue(_ list: [Specialization]?) -> Value? {
            list?.first(where: { $0.appearance == nil })?.value
        }
    }

    private struct PositionSpec: Decodable {
        var scale: Double?
        var translationInPoints: [Double]?

        enum CodingKeys: String, CodingKey {
            case scale
            case translationInPoints = "translation-in-points"
        }
    }

    private struct UnitPoint: Decodable {
        var x: Double
        var y: Double
    }

    private struct OrientationSpec: Decodable {
        var start: UnitPoint
        var stop: UnitPoint
    }

    /// Only the two fill shapes actually used by Icon Composer's `fill` field are handled: a
    /// flat color/gradient keyword (`automatic-gradient`), or an explicit two-stop
    /// `linear-gradient` array. Anything else (radial gradients, etc.) falls back to gray.
    private struct FillSpec: Decodable {
        var automaticGradient: String?
        var linearGradient: [String]?
        var orientation: OrientationSpec?

        enum CodingKeys: String, CodingKey {
            case automaticGradient = "automatic-gradient"
            case linearGradient = "linear-gradient"
            case orientation
        }

        var colors: [NSColor] {
            if let linearGradient {
                return linearGradient.compactMap(Self.color(fromSpec:))
            }
            if let automaticGradient, let color = Self.color(fromSpec: automaticGradient) {
                return [color]
            }
            return [.systemGray]
        }

        /// Parses Icon Composer's `"extended-srgb:r,g,b,a"` / `"display-p3:r,g,b,a"` /
        /// `"extended-gray:w,a"` color strings.
        nonisolated private static func color(fromSpec spec: String) -> NSColor? {
            let parts = spec.split(separator: ":")
            guard parts.count == 2 else { return nil }
            let components = parts[1].split(separator: ",").compactMap { Double($0) }
            if (parts[0] == "extended-srgb" || parts[0] == "srgb"), components.count >= 4 {
                return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: components[3])
            }
            if parts[0] == "display-p3", components.count >= 4 {
                return NSColor(displayP3Red: components[0], green: components[1], blue: components[2], alpha: components[3])
            }
            if (parts[0] == "extended-gray" || parts[0] == "gray"), components.count >= 2 {
                return NSColor(white: components[0], alpha: components[1])
            }
            return nil
        }

        /// Paints the fill across `rect`. `orientation` points are unit coordinates, y-down;
        /// Icon Composer's default runs top to bottom.
        func paint(in rect: NSRect) {
            let colors = self.colors
            guard colors.count >= 2, let gradient = NSGradient(starting: colors[0], ending: colors[1]) else {
                (colors.first ?? .systemGray).setFill()
                rect.fill()
                return
            }
            let start = orientation?.start ?? UnitPoint(x: 0.5, y: 0)
            let stop = orientation?.stop ?? UnitPoint(x: 0.5, y: 1)
            func point(_ p: UnitPoint) -> NSPoint {
                NSPoint(x: rect.minX + p.x * rect.width, y: rect.maxY - p.y * rect.height)
            }
            gradient.draw(from: point(start), to: point(stop), options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        }
    }

    /// Icon Composer's canvas size, in points; layer translations are relative to its center.
    private static let canvasSize: CGFloat = 1024

    private static func renderIconBundle(at bundleURL: URL, size: CGFloat) -> NSImage? {
        let specURL = bundleURL.appendingPathComponent("icon.json")
        guard let data = try? Data(contentsOf: specURL),
              let spec = try? JSONDecoder().decode(IconSpec.self, from: data) else {
            return nil
        }
        let assetsURL = bundleURL.appendingPathComponent("Assets")

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let context = NSGraphicsContext.current?.cgContext else { return nil }

        let backgroundRect = NSRect(x: 0, y: 0, width: size, height: size)
        NSBezierPath(roundedRect: backgroundRect, xRadius: size * 0.22, yRadius: size * 0.22).addClip()
        (spec.fill ?? FillSpec()).paint(in: backgroundRect)

        let pointScale = size / canvasSize
        for group in (spec.groups ?? []).reversed() where group.hidden != true {
            context.saveGState()
            context.setAlpha(group.resolvedOpacity)
            context.setBlendMode(group.resolvedBlendMode)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            for layer in (group.layers ?? []).reversed() where layer.hidden != true {
                guard let imageName = layer.imageName,
                      let layerImage = NSImage(contentsOf: assetsURL.appendingPathComponent(imageName)) else { continue }
                let imageSize = layerImage.size
                guard imageSize.width > 0, imageSize.height > 0 else { continue }

                let scale = layer.position?.scale ?? 1
                let translation = layer.position?.translationInPoints ?? []
                let tx = translation.count > 0 ? translation[0] : 0
                let ty = translation.count > 1 ? translation[1] : 0
                let width = imageSize.width * scale * pointScale
                let height = imageSize.height * scale * pointScale
                // Translation is y-down from the canvas center; AppKit's context here is y-up.
                let centerX = (canvasSize / 2 + tx) * pointScale
                let centerY = (canvasSize / 2 - ty) * pointScale
                let drawRect = NSRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
                draw(layerImage, tintedWith: layer.fill, in: drawRect, opacity: layer.resolvedOpacity)
            }
            // Re-applied: `NSImage.draw(operation:)` above can leave its own composite op set.
            context.setBlendMode(group.resolvedBlendMode)
            context.endTransparencyLayer()
            context.restoreGState()
        }

        return image
    }

    /// Draws `layerImage` into `rect`, then — if the layer specifies a solid/gradient `fill` —
    /// recolors it by drawing that fill masked to the image's own alpha, matching how Icon
    /// Composer treats monochrome template layers.
    private static func draw(_ layerImage: NSImage, tintedWith fill: FillSpec?, in rect: NSRect, opacity: Double) {
        guard let fill else {
            layerImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
            return
        }

        // Render the tint (solid or gradient) into a same-sized image, then mask it to the
        // layer artwork's own alpha channel, so the artwork's silhouette gets recolored.
        let tinted = NSImage(size: rect.size)
        tinted.lockFocus()
        let localRect = NSRect(origin: .zero, size: rect.size)
        fill.paint(in: localRect)
        layerImage.draw(in: localRect, from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()

        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
    }
}
