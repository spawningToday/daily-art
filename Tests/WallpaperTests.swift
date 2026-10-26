import XCTest

/// Common Mac display canvases (pixels, scale).
private let fiveK = RenderCanvas(pixelWidth: 5120, pixelHeight: 2880, scale: 2, safeInsets: Insets(top: 25, bottom: 70))
private let macBook16x10 = RenderCanvas(pixelWidth: 3024, pixelHeight: 1890, scale: 2, safeInsets: Insets(top: 38))
private let fullHD = RenderCanvas(pixelWidth: 1920, pixelHeight: 1080, scale: 1, safeInsets: Insets(top: 25))
private let portraitDisplay = RenderCanvas(pixelWidth: 1440, pixelHeight: 2560, scale: 1, safeInsets: Insets(top: 25))
private let canvases = [fiveK, macBook16x10, fullHD, portraitDisplay]

final class WallpaperLayoutTests: XCTestCase {
    private func assertAspectPreserved(_ layout: WallpaperLayout, image: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        let expected = image.width / image.height
        let actual = layout.imageRect.width / layout.imageRect.height
        XCTAssertEqual(actual, expected, accuracy: expected * 0.01, "Artwork must never be stretched", file: file, line: line)
    }

    func testLandscapeFillsWideScreenWithBoundedCrop() {
        let image = CGSize(width: 3400, height: 2125) // 16:10
        let style = WallpaperStyle(mode: .immersive, showText: false)
        let layout = WallpaperLayoutEngine.layout(canvas: macBook16x10, imagePixelSize: image, style: style)
        XCTAssertEqual(layout.placement, .fill)
        XCTAssertTrue(layout.imageRect.contains(CGRect(origin: .zero, size: macBook16x10.size).insetBy(dx: 1, dy: 1)))
        XCTAssertLessThanOrEqual(layout.cropFraction, WallpaperLayoutEngine.maxFillCrop)
        assertAspectPreserved(layout, image: image)
    }

    func testFourByThreeOn16x9IsNotCroppedExcessively() {
        let image = CGSize(width: 3400, height: 2550) // 4:3 would lose 25% on 16:9
        let layout = WallpaperLayoutEngine.layout(canvas: fullHD, imagePixelSize: image,
                                                  style: WallpaperStyle(mode: .immersive, showText: false))
        XCTAssertEqual(layout.placement, .fit)
        assertAspectPreserved(layout, image: image)
    }

    func testPortraitAndSquareAreShownCompletely() {
        for image in [CGSize(width: 2545, height: 3400), CGSize(width: 3400, height: 3254)] {
            for canvas in canvases {
                for mode in WallpaperMode.allCases {
                    let layout = WallpaperLayoutEngine.layout(canvas: canvas, imagePixelSize: image,
                                                              style: WallpaperStyle(mode: mode, showText: true))
                    if canvas.pixelWidth > canvas.pixelHeight {
                        XCTAssertEqual(layout.placement, .fit, "\(image) on \(canvas.size) in \(mode)")
                    }
                    XCTAssertTrue(CGRect(origin: .zero, size: canvas.size).contains(layout.imageRect) || layout.placement == .fill,
                                  "Whole artwork visible: \(image) on \(canvas.size) \(mode)")
                    assertAspectPreserved(layout, image: image)
                }
            }
        }
    }

    func testLowResolutionImagesAreNotOverEnlarged() {
        let image = CGSize(width: 1957, height: 1300)
        for canvas in canvases {
            for mode in WallpaperMode.allCases {
                let layout = WallpaperLayoutEngine.layout(canvas: canvas, imagePixelSize: image,
                                                          style: WallpaperStyle(mode: mode, showText: false))
                XCTAssertLessThanOrEqual(layout.upscale, WallpaperLayoutEngine.maxFillUpscale + 0.001)
                if layout.placement == .fit {
                    XCTAssertLessThanOrEqual(layout.upscale, WallpaperLayoutEngine.maxUpscale + 0.001)
                }
            }
        }
    }

    func testGalleryLabelSitsBesideArtworkWithoutOverlap() {
        let image = CGSize(width: 3400, height: 2542)
        for canvas in [fiveK, macBook16x10, fullHD] {
            let layout = WallpaperLayoutEngine.layout(canvas: canvas, imagePixelSize: image, style: WallpaperStyle(mode: .gallery))
            let text = try! XCTUnwrap(layout.textRect)
            XCTAssertFalse(text.intersects(layout.imageRect))
            XCTAssertLessThan(text.maxX, layout.imageRect.minX, "Label on the left; desktop icons live on the right")
            // Menu bar and Dock areas are left clear.
            XCTAssertLessThanOrEqual(layout.imageRect.maxY, canvas.size.height - canvas.safeInsets.top * canvas.scale)
            XCTAssertGreaterThanOrEqual(layout.imageRect.minY, canvas.safeInsets.bottom * canvas.scale)
        }
    }

    func testPortraitDisplayStacksLabelBelow() {
        let layout = WallpaperLayoutEngine.layout(canvas: portraitDisplay, imagePixelSize: CGSize(width: 3400, height: 2542),
                                                  style: WallpaperStyle(mode: .gallery))
        let text = try! XCTUnwrap(layout.textRect)
        XCTAssertLessThanOrEqual(text.maxY, layout.imageRect.minY)
    }

    func testHidingTextGivesArtworkTheWholeWall() {
        let image = CGSize(width: 2545, height: 3400)
        let with = WallpaperLayoutEngine.layout(canvas: fiveK, imagePixelSize: image, style: WallpaperStyle(mode: .gallery, showText: true))
        let without = WallpaperLayoutEngine.layout(canvas: fiveK, imagePixelSize: image, style: WallpaperStyle(mode: .gallery, showText: false))
        XCTAssertNil(without.textRect)
        XCTAssertGreaterThanOrEqual(without.imageRect.height, with.imageRect.height)
        XCTAssertEqual(without.imageRect.midX, fiveK.size.width / 2, accuracy: 1)
    }
}

final class WallpaperRendererTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try Fixtures.temporaryDirectory()
    }

    private func image(_ w: Int, _ h: Int) throws -> URL {
        let url = dir.appendingPathComponent("src-\(w)x\(h).jpg")
        try Fixtures.writeJPEG(width: w, height: h, to: url)
        return url
    }

    func testRendersEveryShapeOnEveryDisplay() throws {
        let shapes = [(3400, 2267), (2545, 3400), (3400, 3254)]
        for (w, h) in shapes {
            let source = try image(w, h)
            for canvas in canvases {
                for mode in WallpaperMode.allCases {
                    for backdrop in BackdropStyle.allCases {
                        let style = WallpaperStyle(mode: mode, showText: true, backdrop: backdrop, isDark: backdrop == .blurred)
                        let request = WallpaperRenderRequest(artwork: Fixtures.artwork(id: 1, width: w, height: h),
                                                             imageURL: source, canvas: canvas, style: style)
                        let output = try WallpaperRenderer.render(request)
                        XCTAssertEqual(output.width, canvas.pixelWidth)
                        XCTAssertEqual(output.height, canvas.pixelHeight)
                    }
                }
            }
        }
    }

    func testArtworkPixelsAreNotDistortedOrFlipped() throws {
        let source = try image(2400, 3200)
        let canvas = fullHD
        let style = WallpaperStyle(mode: .immersive, showText: false, backdrop: .neutral)
        let output = try WallpaperRenderer.render(WallpaperRenderRequest(
            artwork: Fixtures.artwork(id: 2, width: 2400, height: 3200), imageURL: source, canvas: canvas, style: style))
        let layout = WallpaperLayoutEngine.layout(canvas: canvas, imagePixelSize: CGSize(width: 2400, height: 3200), style: style)
        let r = layout.imageRect
        // Top-left quadrant of the source is blue, the rest red.
        let topLeft = pixel(of: output, x: Int(r.minX + r.width * 0.25), y: Int(CGFloat(canvas.pixelHeight) - r.maxY + r.height * 0.25))
        let bottomRight = pixel(of: output, x: Int(r.minX + r.width * 0.75), y: Int(CGFloat(canvas.pixelHeight) - r.maxY + r.height * 0.75))
        XCTAssertGreaterThan(topLeft.b, 150)
        XCTAssertLessThan(topLeft.r, 80)
        XCTAssertGreaterThan(bottomRight.r, 150)
        XCTAssertLessThan(bottomRight.b, 80)
    }

    func testVeryLongDescriptionIsFittedNotClipped() {
        let long = String(repeating: "The museum’s description continues with many careful observations about this work. ", count: 80)
        let artwork = Fixtures.artwork(id: 3, description: long)
        let fitted = LabelTypesetter.fit(artwork: artwork, palette: .light, style: .gallery, typeScale: 2, width: 800, maxHeight: 1600)
        XCTAssertTrue(fitted.isTruncated)
        XCTAssertLessThanOrEqual(fitted.size.height, 1600)
        XCTAssertTrue(fitted.string.string.contains("\u{2026}"))
        XCTAssertTrue(fitted.string.string.contains(artwork.title), "Title is never dropped")

        let short = LabelTypesetter.fit(artwork: Fixtures.artwork(id: 4), palette: .light, style: .gallery, typeScale: 2, width: 800, maxHeight: 1600)
        XCTAssertFalse(short.isTruncated)
    }

    func testTruncationEndsAtWordBoundary() {
        let runs = [TextRun(text: "Alpha beta ", isItalic: false), TextRun(text: "gamma delta", isItalic: true)]
        let cut = LabelTypesetter.truncate(runs, toCharacters: 14)
        XCTAssertEqual(cut.map(\.text).joined(), "Alpha beta\u{2026}")
        XCTAssertEqual(LabelTypesetter.truncate(runs, toCharacters: 100), runs)
    }

    func testUnreadableImageFailsLoudly() throws {
        let bad = dir.appendingPathComponent("bad.jpg")
        try Data("not an image".utf8).write(to: bad)
        let request = WallpaperRenderRequest(artwork: Fixtures.artwork(id: 5), imageURL: bad, canvas: fullHD, style: WallpaperStyle())
        XCTAssertThrowsError(try WallpaperRenderer.render(request))
    }

    func testWritesPNGAndJPEG() throws {
        let source = try image(3400, 2267)
        let artwork = Fixtures.artwork(id: 6)
        for style in [WallpaperStyle(mode: .gallery), WallpaperStyle(mode: .immersive, showText: false)] {
            let name = WallpaperPlanner.fileName(artworkID: 6, canvas: fullHD, style: style)
            let url = dir.appendingPathComponent(name)
            try WallpaperRenderer.renderToFile(WallpaperRenderRequest(artwork: artwork, imageURL: source, canvas: fullHD, style: style), url: url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertNotNil(WallpaperRenderer.loadImage(at: url, maxPixelSize: 100))
        }
    }
}

final class DisplayPlanTests: XCTestCase {
    let displays = [
        DisplayDescriptor(id: "1", name: "Built-in", pointSize: CGSize(width: 1512, height: 982), scale: 2,
                          safeInsets: Insets(top: 38), isMain: false),
        DisplayDescriptor(id: "2", name: "Studio Display", pointSize: CGSize(width: 2560, height: 1440), scale: 2,
                          safeInsets: Insets(top: 25, bottom: 70), isMain: true),
        DisplayDescriptor(id: "3", name: "Rotated", pointSize: CGSize(width: 1080, height: 1920), scale: 1,
                          safeInsets: Insets(top: 25), isMain: false),
    ]

    func testPolicies() {
        XCTAssertEqual(WallpaperPlanner.targets(for: displays, policy: .allDisplays).map(\.id), ["1", "2", "3"])
        XCTAssertEqual(WallpaperPlanner.targets(for: displays, policy: .mainOnly).map(\.id), ["2"])
        XCTAssertTrue(WallpaperPlanner.targets(for: [], policy: .mainOnly).isEmpty)
    }

    func testEachDisplayGetsItsOwnResolutionAndFile() {
        let style = WallpaperStyle()
        let canvases = displays.map(WallpaperPlanner.canvas(for:))
        XCTAssertEqual(canvases.map(\.pixelWidth), [3024, 5120, 1080])
        XCTAssertEqual(canvases.map(\.pixelHeight), [1964, 2880, 1920])
        let names = Set(canvases.map { WallpaperPlanner.fileName(artworkID: 1, canvas: $0, style: style) })
        XCTAssertEqual(names.count, 3)
    }

    func testHugeFramebuffersAreCapped() {
        let sixK = DisplayDescriptor(id: "x", name: "Pro Display", pointSize: CGSize(width: 3360, height: 1890), scale: 2,
                                     safeInsets: .zero, isMain: true)
        let canvas = WallpaperPlanner.canvas(for: sixK)
        XCTAssertLessThanOrEqual(CGFloat(canvas.pixelWidth), WallpaperPlanner.maxLongEdge)
        XCTAssertEqual(Double(canvas.pixelWidth) / Double(canvas.pixelHeight), 3360.0 / 1890.0, accuracy: 0.01)
    }

    func testFileNameChangesWithStyle() {
        let canvas = WallpaperPlanner.canvas(for: displays[1])
        var style = WallpaperStyle()
        let a = WallpaperPlanner.fileName(artworkID: 1, canvas: canvas, style: style)
        style.isDark = true
        XCTAssertNotEqual(a, WallpaperPlanner.fileName(artworkID: 1, canvas: canvas, style: style))
        XCTAssertNotEqual(a, WallpaperPlanner.fileName(artworkID: 2, canvas: canvas, style: WallpaperStyle()))
    }
}
