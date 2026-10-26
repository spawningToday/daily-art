import XCTest

final class NetworkAndCacheTests: XCTestCase {
    private let fastRetry = RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(1))

    func testTransientServerErrorsAreRetried() async throws {
        let body = try Fixtures.data("cma_highlights_sample")
        let loader = MockLoader { _, n in n < 3 ? (Data(), 503) : (body, 200) }
        let client = ClevelandArtAPIClient(loader: loader, retry: fastRetry)
        let page = try await client.fetchPage(scope: .highlights, skip: 0, limit: 100)
        XCTAssertEqual(page.records.count, 5)
        XCTAssertEqual(loader.callCount, 3)
    }

    func testPermanentErrorsAreNotRetried() async {
        let loader = MockLoader { _, _ in (Data(), 404) }
        let client = ClevelandArtAPIClient(loader: loader, retry: fastRetry)
        do {
            _ = try await client.fetchPage(scope: .highlights, skip: 0, limit: 100)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? NetworkError, .httpStatus(404))
            XCTAssertEqual(loader.callCount, 1)
        }
    }

    func testOfflineIsReportedClearly() async {
        let loader = MockLoader { _, _ in throw URLError(.notConnectedToInternet) }
        let client = ClevelandArtAPIClient(loader: loader, retry: fastRetry)
        do {
            _ = try await client.fetchPage(scope: .highlights, skip: 0, limit: 100)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? NetworkError, .offline)
            XCTAssertEqual(loader.callCount, 3, "Offline is transient, so it is retried before giving up")
        }
    }

    func testGarbageResponseIsADecodingError() async {
        let loader = MockLoader { _, _ in (Data("<html>maintenance</html>".utf8), 200) }
        let client = ClevelandArtAPIClient(loader: loader, retry: fastRetry)
        do {
            _ = try await client.fetchPage(scope: .highlights, skip: 0, limit: 100)
            XCTFail("Expected failure")
        } catch {
            guard case .decoding = error as? NetworkError else { return XCTFail("Got \(error)") }
        }
    }

    func testPaginationCollectsAllPages() async throws {
        let records = (1...5).map { i -> [String: Any] in ["id": i, "title": "W\(i)"] }
        let loader = MockLoader { request, _ in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let skip = Int(query.first { $0.name == "skip" }!.value!)!
            let limit = Int(query.first { $0.name == "limit" }!.value!)!
            let slice = Array(records.dropFirst(skip).prefix(limit))
            let json = try JSONSerialization.data(withJSONObject: ["info": ["total": 5], "data": slice])
            return (json, 200)
        }
        let client = ClevelandArtAPIClient(loader: loader, retry: fastRetry, pageSize: 2)
        let all = try await client.fetchAll(scope: .highlights)
        XCTAssertEqual(all.records.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(loader.callCount, 3)
    }

    func testOfflineStartupUsesCachedIndex() async throws {
        let paths = AppPaths(root: try Fixtures.temporaryDirectory())
        let body = try Fixtures.data("cma_highlights_sample")
        var online = true
        let loader = MockLoader { _, _ in
            guard online else { throw URLError(.notConnectedToInternet) }
            return (body, 200)
        }
        let first = ArtworkRepository(paths: paths, client: ClevelandArtAPIClient(loader: loader, retry: fastRetry))
        let pool = try await first.refreshPool(scope: .highlights)
        XCTAssertEqual(pool.artworks.count, 4)

        // "Relaunch" while offline: a new repository reads the disk cache.
        online = false
        let second = ArtworkRepository(paths: paths, client: ClevelandArtAPIClient(loader: loader, retry: fastRetry))
        let cached = await second.cachedPool(scope: .highlights)
        XCTAssertEqual(cached?.ids.sorted(), pool.ids.sorted())
        do {
            _ = try await second.refreshPool(scope: .highlights)
            XCTFail("Expected offline failure")
        } catch {
            let stillCached = await second.cachedPool(scope: .highlights)
            XCTAssertEqual(stillCached?.artworks.count, 4, "A failed refresh never discards the cached index")
        }
    }

    func testEmptyAPIResponseDoesNotReplaceCache() async throws {
        let paths = AppPaths(root: try Fixtures.temporaryDirectory())
        let good = try Fixtures.data("cma_highlights_sample")
        var serveEmpty = false
        let loader = MockLoader { _, _ in serveEmpty ? (Data(#"{"info":{"total":0},"data":[]}"#.utf8), 200) : (good, 200) }
        let repo = ArtworkRepository(paths: paths, client: ClevelandArtAPIClient(loader: loader, retry: fastRetry))
        _ = try await repo.refreshPool(scope: .highlights)
        serveEmpty = true
        do {
            _ = try await repo.refreshPool(scope: .highlights)
            XCTFail("Empty pool should be rejected")
        } catch {}
        let cached = await repo.cachedPool(scope: .highlights)
        XCTAssertEqual(cached?.artworks.count, 4)
    }

    func testImageCacheDownloadsOnceAndValidates() async throws {
        let dir = try Fixtures.temporaryDirectory()
        let jpegURL = dir.appendingPathComponent("source.jpg")
        try Fixtures.writeJPEG(width: 64, height: 48, to: jpegURL)
        let jpeg = try Data(contentsOf: jpegURL)
        let loader = MockLoader { _, _ in (jpeg, 200) }
        let cache = ArtworkImageCache(directory: dir.appendingPathComponent("Images"), loader: loader, retry: fastRetry)
        let artwork = Fixtures.artwork(id: 42)

        async let a = cache.image(for: artwork)
        async let b = cache.image(for: artwork)
        let (urlA, urlB) = try await (a, b)
        XCTAssertEqual(urlA, urlB)
        _ = try await cache.image(for: artwork)
        XCTAssertEqual(loader.callCount, 1, "Concurrent and repeated requests share one download")
        XCTAssertTrue(cache.isCached(42))
        let ids = await cache.cachedArtworkIDs()
        XCTAssertEqual(ids, [42])
    }

    func testImageCacheRejectsNonImagesAndMissingFiles() async throws {
        let dir = try Fixtures.temporaryDirectory()
        let html = ArtworkImageCache(directory: dir, loader: MockLoader { _, _ in (Data("<html>".utf8), 200) }, retry: fastRetry)
        do {
            _ = try await html.image(for: Fixtures.artwork(id: 1))
            XCTFail("Expected failure")
        } catch {
            XCTAssertTrue(error is ImageCacheError)
        }
        XCTAssertFalse(html.isCached(1), "Nothing is written for invalid data")

        let gone = ArtworkImageCache(directory: dir, loader: MockLoader { _, _ in (Data(), 404) }, retry: fastRetry)
        do {
            _ = try await gone.image(for: Fixtures.artwork(id: 2))
            XCTFail("Expected failure")
        } catch ImageCacheError.notFound {
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testPruneKeepsCurrentAndRecent() async throws {
        let dir = try Fixtures.temporaryDirectory()
        let jpegURL = dir.appendingPathComponent("source.jpg")
        try Fixtures.writeJPEG(width: 32, height: 32, to: jpegURL)
        let jpeg = try Data(contentsOf: jpegURL)
        let cache = ArtworkImageCache(directory: dir.appendingPathComponent("Images"),
                                      loader: MockLoader { _, _ in (jpeg, 200) }, retry: fastRetry)
        for id in 1...10 { _ = try await cache.image(for: Fixtures.artwork(id: id)) }
        await cache.prune(keeping: [1], maxCount: 4)
        let remaining = await cache.cachedArtworkIDs()
        XCTAssertTrue(remaining.contains(1))
        XCTAssertEqual(remaining.count, 4)
        await cache.clear(except: [1])
        let afterClear = await cache.cachedArtworkIDs()
        XCTAssertEqual(afterClear, [1])
    }

    func testScreensaverSnapshotRoundTrip() throws {
        let root = try Fixtures.temporaryDirectory()
        let image = root.appendingPathComponent("img.jpg")
        try Fixtures.writeJPEG(width: 16, height: 16, to: image)
        let dirs = [root.appendingPathComponent("A"), root.appendingPathComponent("B")]
        let artwork = Fixtures.artwork(id: 9)
        let failures = ScreensaverSnapshotStore.publish(artwork: artwork, imageURL: image, dayKey: "2026-10-25", to: dirs)
        XCTAssertTrue(failures.isEmpty)
        let found = try XCTUnwrap(ScreensaverSnapshotStore.read(from: [root.appendingPathComponent("missing")] + dirs))
        XCTAssertEqual(found.snapshot.artwork, artwork)
        XCTAssertTrue(FileManager.default.fileExists(atPath: found.imageURL.path))

        // Publishing a new artwork replaces the old image.
        ScreensaverSnapshotStore.publish(artwork: Fixtures.artwork(id: 10), imageURL: image, dayKey: "2026-10-26", to: dirs)
        let files = try FileManager.default.contentsOfDirectory(atPath: dirs[0].path)
        XCTAssertEqual(files.filter { $0.hasPrefix("artwork-") }, ["artwork-10.jpg"])
    }
}
