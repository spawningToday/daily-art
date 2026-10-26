import Foundation
import ImageIO

enum ImageCacheError: Error, LocalizedError {
    case invalidImageData
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidImageData: return "The downloaded file is not a readable image."
        case .notFound: return "The museum no longer serves this image."
        }
    }
}

/// Downloads artwork JPEGs once and keeps them on disk (Application Support, not Caches,
/// so macOS won't purge the images the app relies on for offline use).
actor ArtworkImageCache {
    private let directory: URL
    private let loader: HTTPDataLoading
    private let retry: RetryPolicy
    private var inFlight: [Int: Task<URL, Error>] = [:]

    init(directory: URL, loader: HTTPDataLoading = URLSession(configuration: .default), retry: RetryPolicy = RetryPolicy()) {
        self.directory = directory
        self.loader = loader
        self.retry = retry
    }

    /// A session for background prefetching that stays off expensive/low-data networks.
    static func prefetchSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }

    nonisolated func fileURL(for artworkID: Int) -> URL {
        directory.appendingPathComponent("\(artworkID)-print.jpg")
    }

    nonisolated func isCached(_ artworkID: Int) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: artworkID).path)
    }

    /// Returns the local file for an artwork, downloading it if needed. Concurrent requests
    /// for the same artwork share one download.
    func image(for artwork: Artwork) async throws -> URL {
        let destination = fileURL(for: artwork.id)
        if FileManager.default.fileExists(atPath: destination.path) {
            touch(destination)
            return destination
        }
        if let task = inFlight[artwork.id] { return try await task.value }

        let loader = self.loader
        let retry = self.retry
        let directory = self.directory
        let task = Task<URL, Error>.detached {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data: Data = try await retry.run {
                var request = URLRequest(url: artwork.image.url)
                request.timeoutInterval = 120
                let (data, response) = try await loader.fetchData(for: request)
                guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
                if http.statusCode == 404 || http.statusCode == 410 { throw ImageCacheError.notFound }
                guard (200..<300).contains(http.statusCode) else { throw NetworkError.httpStatus(http.statusCode) }
                return data
            }
            guard Self.isDecodableImage(data) else { throw ImageCacheError.invalidImageData }
            // Write to a temp name first so a crash never leaves a truncated file behind.
            let temp = directory.appendingPathComponent(".\(artwork.id)-\(UUID().uuidString).part")
            try data.write(to: temp, options: .atomic)
            do {
                try FileManager.default.moveItem(at: temp, to: destination)
            } catch {
                // Another downloader (e.g. the prefetcher) finished first; its file is equivalent.
                try? FileManager.default.removeItem(at: temp)
                guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
            }
            return destination
        }
        inFlight[artwork.id] = task
        defer { inFlight[artwork.id] = nil }
        return try await task.value
    }

    static func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0
        else { return false }
        return true
    }

    /// Deletes cached images except `keep`, retaining at most `maxCount` (most recently used first).
    func prune(keeping keep: Set<Int>, maxCount: Int) {
        let files = cachedFiles()
        var retained = 0
        for file in files.sorted(by: { $0.modified > $1.modified }) {
            if keep.contains(file.artworkID) { continue }
            if retained < max(0, maxCount - keep.count) {
                retained += 1
                continue
            }
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    /// Removes everything except the listed artworks (normally today's image).
    func clear(except keep: Set<Int>) {
        for file in cachedFiles() where !keep.contains(file.artworkID) {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    func diskUsage() -> Int64 {
        cachedFiles().reduce(0) { $0 + $1.size }
    }

    func cachedArtworkIDs() -> Set<Int> {
        Set(cachedFiles().map(\.artworkID))
    }

    private struct CachedFile {
        var url: URL
        var artworkID: Int
        var modified: Date
        var size: Int64
    }

    private func cachedFiles() -> [CachedFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "jpg",
                  let id = Int(url.deletingPathExtension().lastPathComponent.split(separator: "-").first ?? "")
            else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return CachedFile(url: url, artworkID: id, modified: values?.contentModificationDate ?? .distantPast,
                              size: Int64(values?.fileSize ?? 0))
        }
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}
