import AppKit
import CoreImage
import CoreText
import ImageIO

enum WallpaperRenderError: Error, LocalizedError {
    case unreadableImage
    case contextCreationFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "The artwork image could not be read."
        case .contextCreationFailed: return "Not enough memory to compose the wallpaper."
        case .encodingFailed: return "The wallpaper image could not be saved."
        }
    }
}

struct WallpaperRenderRequest: Sendable {
    var artwork: Artwork
    var imageURL: URL
    var canvas: RenderCanvas
    var style: WallpaperStyle
}

/// Colors for the gallery wall and label text.
struct WallpaperPalette {
    var wall: CGColor
    var primary: CGColor
    var secondary: CGColor
    var tertiary: CGColor
    var shadow: CGColor

    static let light = WallpaperPalette(
        wall: CGColor(srgbRed: 0.949, green: 0.937, blue: 0.918, alpha: 1),
        primary: CGColor(srgbRed: 0.114, green: 0.106, blue: 0.098, alpha: 1),
        secondary: CGColor(srgbRed: 0.369, green: 0.349, blue: 0.325, alpha: 1),
        tertiary: CGColor(srgbRed: 0.549, green: 0.522, blue: 0.490, alpha: 1),
        shadow: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))

    static let dark = WallpaperPalette(
        wall: CGColor(srgbRed: 0.086, green: 0.082, blue: 0.078, alpha: 1),
        primary: CGColor(srgbRed: 0.929, green: 0.914, blue: 0.890, alpha: 1),
        secondary: CGColor(srgbRed: 0.702, green: 0.675, blue: 0.639, alpha: 1),
        tertiary: CGColor(srgbRed: 0.490, green: 0.467, blue: 0.435, alpha: 1),
        shadow: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6))

    /// Light text for the translucent caption card used over artwork in Immersive mode.
    static let caption = WallpaperPalette(
        wall: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.4),
        primary: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96),
        secondary: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.78),
        tertiary: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.58),
        shadow: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.4))
}

/// Composes wallpapers with Core Graphics / Core Text / Core Image. Thread-safe and
/// independent of any window, so it runs off the main thread and inside the screensaver.
enum WallpaperRenderer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    // MARK: - Public API

    static func render(_ request: WallpaperRenderRequest) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(request.imageURL as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary),
              let pixelSize = sourcePixelSize(source)
        else { throw WallpaperRenderError.unreadableImage }

        let canvas = request.canvas
        let style = request.style
        let layout = WallpaperLayoutEngine.layout(canvas: canvas, imagePixelSize: pixelSize, style: style)

        // Decode only as many pixels as will be drawn (ImageIO never upsamples here), which
        // keeps memory bounded even for very large source files.
        let needed = Int(ceil(max(layout.imageRect.width, layout.imageRect.height)))
        guard let art = thumbnail(source, maxPixelSize: max(needed, 64)) else {
            throw WallpaperRenderError.unreadableImage
        }

        guard let ctx = makeContext(width: canvas.pixelWidth, height: canvas.pixelHeight) else {
            throw WallpaperRenderError.contextCreationFailed
        }
        let bounds = CGRect(origin: .zero, size: canvas.size)
        let palette: WallpaperPalette = style.isDark ? .dark : .light
        ctx.interpolationQuality = .high

        // Background
        switch style.mode {
        case .gallery:
            ctx.setFillColor(palette.wall)
            ctx.fill(bounds)
        case .immersive:
            if layout.placement == .fit {
                drawBackdrop(in: ctx, bounds: bounds, source: source, style: style, palette: palette)
            }
        }

        // Artwork
        if layout.placement == .fit {
            ctx.saveGState()
            let s = canvas.scale
            ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 36 * s, color: palette.shadow)
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(layout.imageRect.insetBy(dx: 1, dy: 1))
            ctx.restoreGState()
        }
        ctx.draw(art, in: layout.imageRect)

        // Text
        if let textRect = layout.textRect {
            if layout.isCaptionCard {
                drawCaptionCard(in: ctx, area: textRect, artwork: request.artwork, typeScale: layout.typeScale, scale: canvas.scale)
            } else {
                drawLabel(in: ctx, column: textRect, imageRect: layout.imageRect, artwork: request.artwork,
                          palette: palette, typeScale: layout.typeScale, scale: canvas.scale)
            }
        }

        guard let output = ctx.makeImage() else { throw WallpaperRenderError.contextCreationFailed }
        return output
    }

    /// Renders and writes the wallpaper. PNG keeps label text crisp; immersive images
    /// (no text) use high-quality JPEG to keep files small.
    static func renderToFile(_ request: WallpaperRenderRequest, url: URL) throws {
        let image = try render(request)
        let usePNG = request.style.mode == .gallery || request.style.showText
        try write(image, to: url, png: usePNG)
    }

    static func write(_ image: CGImage, to url: URL, png: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let type = (png ? "public.png" : "public.jpeg") as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw WallpaperRenderError.encodingFailed
        }
        let options: [CFString: Any] = png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.94]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw WallpaperRenderError.encodingFailed }
    }

    /// A downsampled CGImage suitable for previews (used by the menu bar UI).
    static func loadImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return thumbnail(source, maxPixelSize: maxPixelSize)
    }

    // MARK: - Image helpers

    /// Pixel size after applying EXIF orientation.
    static func sourcePixelSize(_ source: CGImageSource) -> CGSize? {
        guard CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0
        else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    static func thumbnail(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.setAllowsFontSmoothing(false)
        ctx?.setShouldSubpixelPositionFonts(true)
        return ctx
    }

    // MARK: - Backdrops

    private static func drawBackdrop(in ctx: CGContext, bounds: CGRect, source: CGImageSource,
                                     style: WallpaperStyle, palette: WallpaperPalette) {
        guard style.backdrop != .neutral, let tiny = thumbnail(source, maxPixelSize: 96) else {
            ctx.setFillColor(palette.wall)
            ctx.fill(bounds)
            return
        }
        switch style.backdrop {
        case .colorMatched:
            ctx.setFillColor(mutedColor(averageColor(of: tiny) ?? palette.wall, dark: style.isDark))
            ctx.fill(bounds)
        case .blurred:
            guard let blurred = blurredBackdrop(tiny, canvas: bounds.size) else {
                ctx.setFillColor(palette.wall)
                ctx.fill(bounds)
                return
            }
            ctx.draw(blurred, in: aspectFill(CGSize(width: blurred.width, height: blurred.height), in: bounds))
            // A tone wash keeps the backdrop quiet so the artwork stays the focus.
            ctx.setFillColor(style.isDark ? CGColor(gray: 0, alpha: 0.42) : CGColor(gray: 1, alpha: 0.22))
            ctx.fill(bounds)
        case .neutral:
            break
        }
    }

    private static func blurredBackdrop(_ tiny: CGImage, canvas: CGSize) -> CGImage? {
        let input = CIImage(cgImage: tiny)
        // Work at ~1/6 of the canvas: plenty for a heavy blur and cheap to compute.
        let factor = max(canvas.width / input.extent.width, canvas.height / input.extent.height) / 6
        let scaled = input.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let extent = scaled.extent.integral
        let blurred = scaled
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(extent.width / 22))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85])
            .cropped(to: extent)
        return ciContext.createCGImage(blurred, from: extent)
    }

    static func averageColor(of image: CGImage) -> CGColor? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)]),
              let output = filter.outputImage,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: srgb)
        return CGColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    /// Desaturates and darkens/lightens a color so it reads as a calm mat, not a poster.
    static func mutedColor(_ color: CGColor, dark: Bool) -> CGColor {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3
        else { return color }
        let luma = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        func mix(_ v: CGFloat) -> CGFloat {
            let desaturated = v * 0.7 + luma * 0.3
            return dark ? desaturated * 0.45 : desaturated * 0.55 + 0.45
        }
        return CGColor(srgbRed: mix(c[0]), green: mix(c[1]), blue: mix(c[2]), alpha: 1)
    }

    static func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
        let scale = max(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: - Labels

    private static func drawLabel(in ctx: CGContext, column: CGRect, imageRect: CGRect, artwork: Artwork,
                                  palette: WallpaperPalette, typeScale: CGFloat, scale: CGFloat) {
        let fitted = LabelTypesetter.fit(artwork: artwork, palette: palette, style: .gallery,
                                         typeScale: typeScale, width: column.width, maxHeight: column.height)
        let height = fitted.size.height
        let y: CGFloat
        if column.maxX <= imageRect.minX {
            // Beside the artwork: align the label's bottom with the artwork's bottom edge,
            // as exhibition labels are hung, unless it would run off the top.
            y = max(column.minY, min(imageRect.minY, column.maxY - height))
        } else {
            y = column.maxY - height
        }
        // A short rule above the label.
        let ruleY = y + height + 22 * typeScale
        if ruleY + scale <= column.maxY {
            ctx.setFillColor(palette.tertiary)
            ctx.fill(CGRect(x: column.minX, y: ruleY, width: 34 * typeScale, height: max(1, scale)))
        }
        LabelTypesetter.draw(fitted, in: ctx, origin: CGPoint(x: column.minX, y: y), width: column.width)
    }

    private static func drawCaptionCard(in ctx: CGContext, area: CGRect, artwork: Artwork, typeScale: CGFloat, scale: CGFloat) {
        let padding = 22 * typeScale
        let fitted = LabelTypesetter.fit(artwork: artwork, palette: .caption, style: .caption, typeScale: typeScale,
                                         width: area.width - 2 * padding, maxHeight: area.height - 2 * padding)
        let card = CGRect(x: area.minX, y: area.minY, width: area.width, height: fitted.size.height + 2 * padding).integral
        let radius = 14 * scale
        let path = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Frosted glass: blur what's already been drawn underneath the card.
        if let snapshot = ctx.makeImage() {
            let imageHeight = CGFloat(snapshot.height)
            let cropRect = CGRect(x: card.minX, y: imageHeight - card.maxY, width: card.width, height: card.height)
            if let region = snapshot.cropping(to: cropRect) {
                let ci = CIImage(cgImage: region)
                let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(24 * scale)).cropped(to: ci.extent)
                if let frosted = ciContext.createCGImage(blurred, from: ci.extent) {
                    ctx.saveGState()
                    ctx.addPath(path)
                    ctx.clip()
                    ctx.draw(frosted, in: card)
                    ctx.restoreGState()
                }
            }
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(WallpaperPalette.caption.wall)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        ctx.setLineWidth(max(1, scale * 0.5))
        ctx.strokePath()
        ctx.restoreGState()

        LabelTypesetter.draw(fitted, in: ctx, origin: CGPoint(x: card.minX + padding, y: card.minY + padding),
                             width: area.width - 2 * padding)
    }
}

/// Builds and fits museum-label typography with Core Text.
enum LabelTypesetter {
    enum Style {
        case gallery
        case caption
    }

    struct Fitted {
        var string: NSAttributedString
        var size: CGSize
        var isTruncated: Bool
    }

    /// Fits the label into `maxHeight`: first by gently reducing the type size, then (only
    /// for very long texts) by ending the description at a word boundary with an ellipsis.
    /// The full text always remains available in the app.
    static func fit(artwork: Artwork, palette: WallpaperPalette, style: Style, typeScale: CGFloat,
                    width: CGFloat, maxHeight: CGFloat) -> Fitted {
        let total = artwork.primaryText.plainText.count
        var last: Fitted?
        for factor in [1.0, 0.94, 0.88, 0.82] as [CGFloat] {
            let string = build(artwork: artwork, palette: palette, style: style, k: typeScale * factor, descriptionLimit: nil)
            let size = measure(string, width: width)
            last = Fitted(string: string, size: size, isTruncated: false)
            if size.height <= maxHeight { return last! }
        }
        let k = typeScale * 0.82
        var low = 0, high = total
        var best = Fitted(string: build(artwork: artwork, palette: palette, style: style, k: k, descriptionLimit: 0),
                          size: .zero, isTruncated: true)
        best.size = measure(best.string, width: width)
        while low < high {
            let mid = (low + high + 1) / 2
            let string = build(artwork: artwork, palette: palette, style: style, k: k, descriptionLimit: mid)
            let size = measure(string, width: width)
            if size.height <= maxHeight {
                low = mid
                best = Fitted(string: string, size: size, isTruncated: true)
            } else {
                high = mid - 1
            }
        }
        return best.size.height > 0 ? best : (last ?? best)
    }

    static func measure(_ string: NSAttributedString, width: CGFloat) -> CGSize {
        let framesetter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    static func draw(_ fitted: Fitted, in ctx: CGContext, origin: CGPoint, width: CGFloat) {
        let framesetter = CTFramesetterCreateWithAttributedString(fitted.string as CFAttributedString)
        // A little slack so Core Text never drops the last line due to rounding.
        let slack: CGFloat = 4
        let rect = CGRect(x: origin.x, y: origin.y - slack, width: width, height: fitted.size.height + slack)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    // MARK: Building

    static func build(artwork: Artwork, palette: WallpaperPalette, style: Style, k: CGFloat, descriptionLimit: Int?) -> NSAttributedString {
        let sizes: (attribution: CGFloat, title: CGFloat, meta: CGFloat, body: CGFloat, footer: CGFloat)
        switch style {
        case .gallery: sizes = (15, 30, 14, 16.5, 11.5)
        case .caption: sizes = (13, 22, 12, 14, 10.5)
        }
        let out = NSMutableAttributedString()

        out.append(paragraph(artwork.attribution, font: sansFont(sizes.attribution * k, weight: .semibold),
                             color: palette.primary, spacingAfter: 6 * k, lineHeight: 1.15, kern: 0.2 * k))
        out.append(paragraph(artwork.title, font: serifFont(sizes.title * k, weight: .medium),
                             color: palette.primary, spacingAfter: 8 * k, lineHeight: 1.08))

        let meta = [artwork.creationDate, artwork.technique].compactMap { $0 }.joined(separator: "  ·  ")
        if !meta.isEmpty {
            out.append(paragraph(meta, font: sansFont(sizes.meta * k, weight: .regular),
                                 color: palette.secondary, spacingAfter: 18 * k, lineHeight: 1.2))
        }

        var runs = artwork.primaryText.runs
        if let limit = descriptionLimit {
            runs = limit > 0 ? truncate(runs, toCharacters: limit) : []
        }
        if !runs.isEmpty {
            let body = NSMutableAttributedString()
            let regular = serifFont(sizes.body * k, weight: .regular)
            let italic = serifFont(sizes.body * k, weight: .regular, italic: true)
            for run in runs {
                // Paragraph spacing replaces the blank lines between paragraphs.
                let text = run.text.replacingOccurrences(of: "\n\n", with: "\n")
                body.append(NSAttributedString(string: text, attributes: [
                    .font: run.isItalic ? italic : regular,
                    foregroundKey: palette.primary,
                ]))
            }
            body.append(NSAttributedString(string: "\n"))
            let style = paragraphStyle(lineHeight: 1.36, paragraphSpacing: 9 * k)
            body.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: body.length))
            out.append(body)
        }

        var footer = "The Cleveland Museum of Art"
        if let accession = artwork.accessionNumber { footer += "  ·  \(accession)" }
        out.append(paragraph(footer, font: sansFont(sizes.footer * k, weight: .regular),
                             color: palette.tertiary, spacingAfter: 0, lineHeight: 1.2, kern: 0.15 * k, isLast: true))
        return out
    }

    /// Cuts text at a word boundary before `limit` characters and appends an ellipsis.
    static func truncate(_ runs: [TextRun], toCharacters limit: Int) -> [TextRun] {
        let flat: [(Character, Bool)] = runs.flatMap { run in run.text.map { ($0, run.isItalic) } }
        guard flat.count > limit else { return runs }
        var cut = Array(flat.prefix(max(0, limit)))
        if let space = cut.lastIndex(where: { $0.0 == " " || $0.0 == "\n" }), space > 0 {
            cut = Array(cut[..<space])
        }
        while let last = cut.last, ",;:—–- \n".contains(last.0) { cut.removeLast() }
        guard !cut.isEmpty else { return [] }
        cut.append(("\u{2026}", cut.last?.1 ?? false))
        var result: [TextRun] = []
        for (ch, italic) in cut {
            if var last = result.last, last.isItalic == italic {
                last.text.append(ch)
                result[result.count - 1] = last
            } else {
                result.append(TextRun(text: String(ch), isItalic: italic))
            }
        }
        return result
    }

    private static let foregroundKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

    private static func paragraph(_ text: String, font: NSFont, color: CGColor, spacingAfter: CGFloat,
                                  lineHeight: CGFloat, kern: CGFloat = 0, isLast: Bool = false) -> NSAttributedString {
        NSAttributedString(string: isLast ? text : text + "\n", attributes: [
            .font: font,
            foregroundKey: color,
            .kern: kern,
            .paragraphStyle: paragraphStyle(lineHeight: lineHeight, paragraphSpacing: spacingAfter),
        ])
    }

    private static func paragraphStyle(lineHeight: CGFloat, paragraphSpacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeight
        style.paragraphSpacing = paragraphSpacing
        style.lineBreakMode = .byWordWrapping
        style.alignment = .left
        style.hyphenationFactor = 0.2
        return style
    }

    static func serifFont(_ size: CGFloat, weight: NSFont.Weight, italic: Bool = false) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        var descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        if italic { descriptor = descriptor.withSymbolicTraits(.italic) }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func sansFont(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
}
