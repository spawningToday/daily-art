import Foundation

struct HistoryEntry: Codable, Hashable, Identifiable, Sendable {
    enum Reason: String, Codable, Sendable {
        case daily
        case manual
    }

    var id: UUID
    /// A full copy, so history stays viewable offline and if the museum later edits the index.
    var artwork: Artwork
    var shownAt: Date
    var dayKey: String
    var reason: Reason
}

/// Everything needed to resume selection exactly where it left off after a restart.
struct SelectionState: Codable, Sendable {
    var scope: CollectionScope = .highlights
    /// Number of complete shuffles started.
    var cycle = 0
    /// Remaining artwork IDs for the current cycle, already in random order.
    var bag: [Int] = []
    /// IDs shown during the current cycle (never re-added to the bag until it's exhausted).
    var shownInCycle: Set<Int> = []
    var history: [HistoryEntry] = []
    /// Index into `history` of the artwork currently displayed.
    var cursor: Int?
    /// The artwork day for which the automatic daily selection last ran.
    var lastDailyDayKey: String?
}

/// Random selection without replacement ("shuffle bag").
///
/// Each cycle is a uniform random permutation of the eligible pool, so every work is shown
/// exactly once per cycle with no bias toward any period, region, medium or API order.
struct ArtworkSelectionManager: Sendable {
    static let historyLimit = 500

    var state: SelectionState

    init(state: SelectionState = SelectionState()) {
        self.state = state
    }

    var current: HistoryEntry? {
        guard let cursor = state.cursor, state.history.indices.contains(cursor) else { return nil }
        return state.history[cursor]
    }

    var canGoBack: Bool { (state.cursor ?? 0) > 0 }

    var isViewingPast: Bool {
        guard let cursor = state.cursor else { return false }
        return cursor < state.history.count - 1
    }

    var remainingInCycle: Int { state.bag.count }

    /// Brings the bag in line with a (possibly changed) pool: removed works are dropped,
    /// newly added works are inserted at random positions of the current cycle.
    mutating func reconcile<R: RandomNumberGenerator>(poolIDs: [Int], scope: CollectionScope, using rng: inout R) {
        if state.scope != scope {
            // Switching collections starts a fresh cycle but keeps the viewing history.
            state.scope = scope
            state.bag = []
            state.shownInCycle = []
        }
        let poolSet = Set(poolIDs)
        state.bag.removeAll { !poolSet.contains($0) }
        state.shownInCycle.formIntersection(poolSet)
        guard !state.bag.isEmpty || !state.shownInCycle.isEmpty else {
            // Nothing in progress: the next draw will start a cycle from the full pool.
            return
        }
        let bagSet = Set(state.bag)
        let newIDs = poolIDs.filter { !bagSet.contains($0) && !state.shownInCycle.contains($0) }
        for id in newIDs.shuffled(using: &rng) {
            state.bag.insert(id, at: Int.random(in: 0...state.bag.count, using: &rng))
        }
    }

    /// Upcoming artwork IDs in order (used for opportunistic prefetching).
    mutating func upcoming<R: RandomNumberGenerator>(count: Int, poolIDs: [Int], using rng: inout R) -> [Int] {
        if state.bag.isEmpty { startNewCycle(poolIDs: poolIDs, using: &rng) }
        return Array(state.bag.prefix(count))
    }

    /// Draws the next artwork from the bag. If an artwork's image isn't available (e.g.
    /// offline and not yet downloaded) the first *available* one in the bag is taken
    /// instead, so the user still gets a new work; skipped ones stay in the bag.
    @discardableResult
    mutating func drawNext<R: RandomNumberGenerator>(pool: ArtworkPool, dayKey: String, reason: HistoryEntry.Reason,
                                                    now: Date = Date(), using rng: inout R,
                                                    isAvailable: (Int) -> Bool = { _ in true }) -> HistoryEntry? {
        guard !pool.artworks.isEmpty else { return nil }
        if state.bag.isEmpty { startNewCycle(poolIDs: pool.ids, using: &rng) }

        var lookup: [Int: Artwork] = [:]
        for artwork in pool.artworks { lookup[artwork.id] = artwork }
        guard let index = state.bag.firstIndex(where: { lookup[$0] != nil && isAvailable($0) }),
              let artwork = lookup[state.bag[index]]
        else { return nil }

        state.bag.remove(at: index)
        state.shownInCycle.insert(artwork.id)
        let entry = HistoryEntry(id: UUID(), artwork: artwork, shownAt: now, dayKey: dayKey, reason: reason)
        state.history.append(entry)
        if state.history.count > Self.historyLimit {
            state.history.removeFirst(state.history.count - Self.historyLimit)
        }
        state.cursor = state.history.count - 1
        if reason == .daily { state.lastDailyDayKey = dayKey }
        return entry
    }

    /// Takes a work out of the current cycle (e.g. its image is no longer served).
    mutating func markUnavailable(_ id: Int) {
        state.bag.removeAll { $0 == id }
        state.shownInCycle.insert(id)
    }

    /// Revisit the preceding work. History itself is never modified.
    @discardableResult
    mutating func goBack() -> HistoryEntry? {
        guard let cursor = state.cursor, cursor > 0 else { return nil }
        state.cursor = cursor - 1
        return current
    }

    /// Step forward through history (only meaningful after `goBack`).
    @discardableResult
    mutating func goForwardInHistory() -> HistoryEntry? {
        guard isViewingPast, let cursor = state.cursor else { return nil }
        state.cursor = cursor + 1
        return current
    }

    @discardableResult
    mutating func select(historyEntryID: UUID) -> HistoryEntry? {
        guard let index = state.history.firstIndex(where: { $0.id == historyEntryID }) else { return nil }
        state.cursor = index
        return current
    }

    /// Clears history and the no-repeat memory, keeping the current artwork on screen.
    mutating func reset() {
        let keep = current
        let scope = state.scope
        state = SelectionState()
        state.scope = scope
        if let keep {
            state.history = [keep]
            state.cursor = 0
            state.shownInCycle = [keep.artwork.id]
            state.lastDailyDayKey = keep.dayKey
        }
    }

    private mutating func startNewCycle<R: RandomNumberGenerator>(poolIDs: [Int], using rng: inout R) {
        var bag = poolIDs.shuffled(using: &rng)
        // Avoid showing the same work twice in a row across a cycle boundary.
        if bag.count > 1, let last = state.history.last?.artwork.id, bag.first == last {
            bag.swapAt(0, Int.random(in: 1..<bag.count, using: &rng))
        }
        state.bag = bag
        state.shownInCycle = []
        state.cycle += 1
    }
}

/// Loads and saves `SelectionState`.
struct ArtworkHistoryStore: Sendable {
    var fileURL: URL

    func load() -> SelectionState {
        do {
            return try JSONFileStore.load(SelectionState.self, from: fileURL) ?? SelectionState()
        } catch {
            // Keep the unreadable file for inspection rather than silently discarding it.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            Log.general.error("Selection state unreadable, starting fresh. Backup at \(backup.path, privacy: .public)")
            return SelectionState()
        }
    }

    func save(_ state: SelectionState) throws {
        try JSONFileStore.save(state, to: fileURL)
    }
}
