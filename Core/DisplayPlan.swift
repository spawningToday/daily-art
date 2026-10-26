import CoreGraphics
import Foundation

enum DisplayPolicy: String, Codable, CaseIterable, Sendable {
    /// Today's artwork on every connected display, each rendered for its own resolution.
    case allDisplays
    /// Only the main display changes; others keep their current wallpaper.
    case mainOnly
}

/// A snapshot of one display's geometry, decoupled from NSScreen so planning is testable.
struct DisplayDescriptor: Hashable, Sendable {
    /// CGDirectDisplayID as a string (stable while the display stays connected).
    var id: String
    var name: String
    var pointSize: CGSize
    var scale: CGFloat
    var safeInsets: Insets
    var isMain: Bool
}

enum WallpaperPlanner {
    /// Upper bound on the long edge of a rendered wallpaper. Larger framebuffers (e.g.
    /// scaled 6K modes) are rendered smaller and scaled up by macOS; the artwork itself is
    /// at most 3400 px, so nothing is lost.
    static let maxLongEdge: CGFloat = 6400

    static func targets(for displays: [DisplayDescriptor], policy: DisplayPolicy) -> [DisplayDescriptor] {
        switch policy {
        case .allDisplays:
            return displays
        case .mainOnly:
            if let main = displays.first(where: \.isMain) { return [main] }
            return Array(displays.prefix(1))
        }
    }

    static func canvas(for display: DisplayDescriptor) -> RenderCanvas {
        var scale = max(display.scale, 1)
        let longest = max(display.pointSize.width, display.pointSize.height) * scale
        if longest > maxLongEdge { scale *= maxLongEdge / longest }
        return RenderCanvas(pixelWidth: max(1, Int((display.pointSize.width * scale).rounded())),
                            pixelHeight: max(1, Int((display.pointSize.height * scale).rounded())),
                            scale: scale,
                            safeInsets: display.safeInsets)
    }

    /// Deterministic file name: identical inputs reuse an existing render; any change
    /// (artwork, size, style) yields a new path, which also defeats macOS's habit of
    /// caching desktop pictures by path.
    static func fileName(artworkID: Int, canvas: RenderCanvas, style: WallpaperStyle) -> String {
        let insets = canvas.safeInsets
        let parts = [
            "\(artworkID)",
            "\(canvas.pixelWidth)x\(canvas.pixelHeight)",
            style.mode.rawValue,
            style.showText ? "t\(style.textSize.rawValue)" : "notext",
            style.backdrop.rawValue,
            style.isDark ? "dark" : "light",
            "i\(Int(insets.top))-\(Int(insets.bottom))-\(Int(insets.left))-\(Int(insets.right))",
        ]
        let ext = (style.mode == .gallery || style.showText) ? "png" : "jpg"
        return "wallpaper-" + parts.joined(separator: "_") + "." + ext
    }
}
