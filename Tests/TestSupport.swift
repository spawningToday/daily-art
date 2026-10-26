import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// Deterministic RNG so shuffle tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Scripted HTTP responses.
final class MockLoader: HTTPDataLoading, @unchecked Sendable {
    typealias Handler = (URLRequest, Int) throws -> (Data, Int)
    private let lock = NSLock()
    private var calls = 0
    private let handler: Handler

    init(handler: @escaping Handler) { self.handler = handler }

    var callCount: Int { lock.withLock { calls } }

    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let n = lock.withLock { () -> Int in calls += 1; return calls }
        let (data, status) = try handler(request, n)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

enum Fixtures {
    private final class Token {}

    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: Token.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"), "Missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    static func realRecords() throws -> [CMARecord] {
        try JSONDecoder().decode(CMAListResponse.self, from: data("cma_highlights_sample")).data.compactMap { $0 }
    }

    static func record(id: Int = 1,
                       license: String? = "CC0",
                       highlight: Bool? = true,
                       description: String? = "A long museum-written description that explains the artwork in detail.",
                       artlens: String? = nil,
                       didYouKnow: String? = nil,
                       printURL: String? = "https://openaccess-cdn.clevelandart.org/x/x_print.jpg",
                       width: Int? = 3400,
                       height: Int? = 2400) -> CMARecord {
        CMARecord(id: id, accessionNumber: "2000.\(id)", shareLicenseStatus: license, isHighlight: highlight,
                  title: "Work \(id)", tombstone: "Work \(id), 1900. Oil on canvas.", creationDate: "1900",
                  creators: [CMACreator(description: "Artist \(id) (French, 1850–1900)", role: "artist")],
                  culture: ["France"], technique: "oil on canvas", type: "Painting",
                  url: "https://clevelandart.org/art/2000.\(id)",
                  description: description, artlensDescription: artlens, didYouKnow: didYouKnow,
                  images: CMAImages(web: CMAImage(url: "https://openaccess-cdn.clevelandart.org/x/x_web.jpg", width: 900, height: 600, filesize: 1000),
                                    print: CMAImage(url: printURL, width: width, height: height, filesize: 1_000_000),
                                    full: CMAImage(url: "https://openaccess-cdn.clevelandart.org/x/x_full.tif", width: 9000, height: 6000, filesize: 200_000_000)))
    }

    static func artwork(id: Int, width: Int = 3400, height: Int = 2400, description: String? = nil) -> Artwork {
        var r = record(id: id, width: width, height: height)
        if let description { r.description = description }
        guard case .success(let artwork) = ArtworkEligibilityFilter().evaluate(r) else {
            fatalError("Fixture artwork \(id) unexpectedly ineligible")
        }
        return artwork
    }

    static func pool(count: Int, scope: CollectionScope = .highlights) -> ArtworkPool {
        let artworks = (1...count).map { artwork(id: $0) }
        return ArtworkPool(scope: scope, fetchedAt: Date(), artworks: artworks,
                           stats: PoolStats(apiTotal: count, recordsReceived: count, malformedRecords: 0, eligible: count, rejections: [:]))
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DailyArtTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a solid-color JPEG of the given size (with a distinct top-left quadrant so
    /// orientation/distortion problems are detectable).
    static func writeJPEG(width: Int, height: Int, to url: URL) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}

/// Reads one pixel (sRGB, 0...255) from a CGImage; y is measured from the top.
func pixel(of image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    var data = [UInt8](repeating: 0, count: 4)
    data.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    }
    return (Int(data[0]), Int(data[1]), Int(data[2]))
}
