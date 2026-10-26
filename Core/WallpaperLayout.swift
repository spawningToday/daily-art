import CoreGraphics
import Foundation

enum WallpaperMode: String, Codable, CaseIterable, Sendable {
    /// Artwork as large as possible over a backdrop derived from the image.
    case immersive
    /// Artwork beside a museum-style label on a gallery wall.
    case gallery
}

/// Backdrop behind artworks that don't fill the screen (portrait, square, or too small).
enum BackdropStyle: String, Codable, CaseIterable, Sendable {
    case blurred
    case colorMatched
    case neutral
}

enum TextSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    var factor: CGFloat {
        switch self {
        case .small: return 0.88
        case .medium: return 1.0
        case .large: return 1.15
        }
    }
}

struct WallpaperStyle: Codable, Hashable, Sendable {
    var mode: WallpaperMode = .gallery
    var showText = true
    var textSize: TextSize = .medium
    var backdrop: BackdropStyle = .blurred
    var isDark = false
}

/// Insets in points.
struct Insets: Codable, Hashable, Sendable {
    var top: CGFloat = 0
    var left: CGFloat = 0
    var bottom: CGFloat = 0
    var right: CGFloat = 0

    static let zero = Insets()

    func scaled(_ s: CGFloat) -> Insets {
        Insets(top: top * s, left: left * s, bottom: bottom * s, right: right * s)
    }
}

/// The output bitmap for one display.
struct RenderCanvas: Codable, Hashable, Sendable {
    var pixelWidth: Int
    var pixelHeight: Int
    /// Pixels per point (2 on Retina).
    var scale: CGFloat
    /// Areas covered by the menu bar / Dock / notch, in points.
    var safeInsets: Insets

    var size: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
    var pointSize: CGSize { CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale) }
}

/// Pure geometry for a wallpaper. All rects are in pixels, Core Graphics orientation
/// (origin bottom-left).
struct WallpaperLayout: Equatable, Sendable {
    enum Placement: Equatable, Sendable {
        /// Aspect-fill: the artwork covers the canvas with a small, bounded crop.
        case fill
        /// Aspect-fit: the whole artwork is visible over a backdrop or wall.
        case fit
    }

    var placement: Placement
    var imageRect: CGRect
    /// Space available for text (gallery label column, or the maximum caption card area).
    var textRect: CGRect?
    var isCaptionCard: Bool
    /// Output pixels per source pixel (> 1 means the image is enlarged).
    var upscale: CGFloat
    /// Typography multiplier (points → pixels already included).
    var typeScale: CGFloat

    /// Fraction of the source image hidden by cropping (0 when fitting).
    var cropFraction: CGFloat = 0
}

enum WallpaperLayoutEngine {
    /// Never enlarge source pixels beyond this; smaller images are shown smaller instead of
    /// being stretched into a soft, blurry wallpaper.
    static let maxUpscale: CGFloat = 1.5
    /// Filling the screen may enlarge slightly more: on a Retina panel 1.6× is still
    /// sharper than the same image on a standard-density display at 1:1.
    static let maxFillUpscale: CGFloat = 1.6
    /// Landscape works fill the screen only when this little of the image would be cropped.
    static let maxFillCrop: CGFloat = 0.2

    static func layout(canvas: RenderCanvas, imagePixelSize: CGSize, style: WallpaperStyle) -> WallpaperLayout {
        let s = canvas.scale
        let W = CGFloat(canvas.pixelWidth)
        let H = CGFloat(canvas.pixelHeight)
        let insets = canvas.safeInsets.scaled(s)
        // Typography scales gently with display size (900 pt tall ≈ 1.0).
        let unit = min(max(canvas.pointSize.height / 1000, 0.85), 1.35)
        let typeScale = s * unit * style.textSize.factor
        let image = CGSize(width: max(imagePixelSize.width, 1), height: max(imagePixelSize.height, 1))

        switch style.mode {
        case .immersive:
            let fillScale = max(W / image.width, H / image.height)
            let crop = 1 - min((W / fillScale) / image.width, (H / fillScale) / image.height)
            let caption: CGRect? = style.showText ? {
                let margin = max(36, 0.045 * canvas.pointSize.height) * s
                let width = min(max(0.3 * W, 340 * s * unit), 540 * s * unit) * style.textSize.factor
                return CGRect(x: insets.left + margin, y: insets.bottom + margin,
                              width: min(width, W - 2 * margin), height: 0.38 * H)
            }() : nil

            if crop <= maxFillCrop && fillScale <= maxFillUpscale {
                let size = CGSize(width: image.width * fillScale, height: image.height * fillScale)
                let rect = CGRect(x: (W - size.width) / 2, y: (H - size.height) / 2, width: size.width, height: size.height)
                return WallpaperLayout(placement: .fill, imageRect: rect, textRect: caption, isCaptionCard: caption != nil,
                                       upscale: fillScale, typeScale: typeScale, cropFraction: crop)
            }
            let margin = max(40, 0.055 * canvas.pointSize.height) * s
            let area = CGRect(x: insets.left + margin, y: insets.bottom + margin,
                              width: W - insets.left - insets.right - 2 * margin,
                              height: H - insets.top - insets.bottom - 2 * margin)
            let rect = fit(image, in: area, maxScale: maxUpscale)
            return WallpaperLayout(placement: .fit, imageRect: rect, textRect: caption, isCaptionCard: caption != nil,
                                   upscale: rect.width / image.width, typeScale: typeScale)

        case .gallery:
            let margin = max(48, 0.065 * canvas.pointSize.height) * s
            let inner = CGRect(x: insets.left + margin, y: insets.bottom + margin,
                               width: W - insets.left - insets.right - 2 * margin,
                               height: H - insets.top - insets.bottom - 2 * margin)
            guard style.showText else {
                let rect = fit(image, in: inner, maxScale: maxUpscale)
                return WallpaperLayout(placement: .fit, imageRect: rect, textRect: nil, isCaptionCard: false,
                                       upscale: rect.width / image.width, typeScale: typeScale)
            }
            if W / H >= 1.1 {
                // Label column on the left: the right edge is where Finder puts desktop icons.
                let column = min(max(0.27 * inner.width, 300 * s * unit), 520 * s * unit) * style.textSize.factor
                let gutter = margin * 1.1
                let text = CGRect(x: inner.minX, y: inner.minY, width: min(column, inner.width * 0.45), height: inner.height)
                let art = CGRect(x: text.maxX + gutter, y: inner.minY, width: inner.maxX - text.maxX - gutter, height: inner.height)
                let rect = fit(image, in: art, maxScale: maxUpscale)
                return WallpaperLayout(placement: .fit, imageRect: rect, textRect: text, isCaptionCard: false,
                                       upscale: rect.width / image.width, typeScale: typeScale)
            } else {
                // Portrait / square displays: label below the artwork.
                let textHeight = inner.height * 0.32
                let gutter = margin * 0.8
                let text = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: textHeight)
                let art = CGRect(x: inner.minX, y: text.maxY + gutter, width: inner.width, height: inner.height - textHeight - gutter)
                let rect = fit(image, in: art, maxScale: maxUpscale)
                return WallpaperLayout(placement: .fit, imageRect: rect, textRect: text, isCaptionCard: false,
                                       upscale: rect.width / image.width, typeScale: typeScale)
            }
        }
    }

    /// Largest aspect-preserving rect for `size` inside `area`, centered, never enlarging
    /// beyond `maxScale`. Snapped to whole pixels.
    static func fit(_ size: CGSize, in area: CGRect, maxScale: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else {
            return CGRect(origin: CGPoint(x: area.midX, y: area.midY), size: .zero)
        }
        let scale = min(area.width / size.width, area.height / size.height, maxScale)
        let w = (size.width * scale).rounded()
        let h = (size.height * scale).rounded()
        return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w, height: h)
    }
}
