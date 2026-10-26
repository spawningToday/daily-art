import Foundation

struct PoolStats: Codable, Hashable, Sendable {
    /// `info.total` reported by the API for the query.
    var apiTotal: Int?
    var recordsReceived: Int
    var malformedRecords: Int
    var eligible: Int
    /// Rejection reason (`ArtworkEligibilityFilter.Rejection.rawValue`) → count.
    var rejections: [String: Int]
}

/// The set of eligible artworks for one collection scope, cached on disk.
struct ArtworkPool: Codable, Sendable {
    var scope: CollectionScope
    var fetchedAt: Date
    var artworks: [Artwork]
    var stats: PoolStats

    var ids: [Int] { artworks.map(\.id) }

    func artwork(id: Int) -> Artwork? { artworks.first { $0.id == id } }
}

/// Fetches, filters and caches the eligible artwork index.
actor ArtworkRepository {
    static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60

    private let paths: AppPaths
    private let client: ClevelandArtAPIClient
    private var memory: [CollectionScope: ArtworkPool] = [:]

    init(paths: AppPaths, client: ClevelandArtAPIClient = ClevelandArtAPIClient()) {
        self.paths = paths
        self.client = client
    }

    /// The last pool saved to disk, if any. Works fully offline.
    func cachedPool(scope: CollectionScope) -> ArtworkPool? {
        if let pool = memory[scope] { return pool }
        do {
            let pool = try JSONFileStore.load(ArtworkPool.self, from: paths.poolIndexFile(for: scope))
            memory[scope] = pool
            return pool
        } catch {
            Log.general.error("Cached artwork index unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func needsRefresh(scope: CollectionScope, now: Date = Date()) -> Bool {
        guard let pool = cachedPool(scope: scope) else { return true }
        return now.timeIntervalSince(pool.fetchedAt) > Self.refreshInterval || pool.artworks.isEmpty
    }

    /// Downloads the index from the museum. On failure the cached pool is left untouched.
    func refreshPool(scope: CollectionScope, now: Date = Date()) async throws -> ArtworkPool {
        Log.network.info("Refreshing \(scope.rawValue, privacy: .public) artwork index")
        let page = try await client.fetchAll(scope: scope)
        let pool = Self.buildPool(records: page.records, malformed: page.malformedCount, apiTotal: page.total, scope: scope, fetchedAt: now)
        guard !pool.artworks.isEmpty else {
            // An empty result is far more likely an API problem than an empty museum.
            throw NetworkError.decoding("no eligible artworks in response")
        }
        try JSONFileStore.save(pool, to: paths.poolIndexFile(for: scope))
        memory[scope] = pool
        Log.network.info("Index refreshed: \(pool.artworks.count) eligible of \(page.records.count) records")
        return pool
    }

    static func buildPool(records: [CMARecord], malformed: Int, apiTotal: Int?, scope: CollectionScope, fetchedAt: Date) -> ArtworkPool {
        let filter = ArtworkEligibilityFilter(scope: scope)
        var seen = Set<Int>()
        var artworks: [Artwork] = []
        var rejections: [String: Int] = [:]
        for record in records where seen.insert(record.id).inserted {
            switch filter.evaluate(record) {
            case .success(let artwork): artworks.append(artwork)
            case .failure(let reason): rejections[reason.rawValue, default: 0] += 1
            }
        }
        let stats = PoolStats(apiTotal: apiTotal, recordsReceived: records.count, malformedRecords: malformed,
                              eligible: artworks.count, rejections: rejections)
        return ArtworkPool(scope: scope, fetchedAt: fetchedAt, artworks: artworks, stats: stats)
    }
}
