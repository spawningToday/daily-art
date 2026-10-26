import XCTest

final class SelectionTests: XCTestCase {
    func testEveryArtworkShownOnceBeforeAnyRepeat() {
        let pool = Fixtures.pool(count: 50)
        var rng = SeededGenerator(seed: 1)
        var manager = ArtworkSelectionManager()
        manager.reconcile(poolIDs: pool.ids, scope: .highlights, using: &rng)

        var firstCycle: [Int] = []
        for day in 0..<50 {
            let entry = manager.drawNext(pool: pool, dayKey: "d\(day)", reason: .daily, using: &rng)
            firstCycle.append(entry!.artwork.id)
        }
        XCTAssertEqual(Set(firstCycle).count, 50, "No repeats within a cycle")
        XCTAssertNotEqual(firstCycle, pool.ids, "Order is shuffled, not API order")

        let next = manager.drawNext(pool: pool, dayKey: "d50", reason: .daily, using: &rng)!
        XCTAssertNotEqual(next.artwork.id, firstCycle.last, "No back-to-back repeat across cycles")
        XCTAssertEqual(manager.state.cycle, 2)

        var secondCycle = [next.artwork.id]
        for day in 51..<100 {
            secondCycle.append(manager.drawNext(pool: pool, dayKey: "d\(day)", reason: .daily, using: &rng)!.artwork.id)
        }
        XCTAssertEqual(Set(secondCycle).count, 50)
    }

    func testShuffleIsUniformEnoughAcrossPositions() {
        // Each of 10 works should lead a cycle roughly 1/10 of the time.
        let pool = Fixtures.pool(count: 10)
        var rng = SeededGenerator(seed: 7)
        var counts = [Int: Int]()
        for _ in 0..<5000 {
            var manager = ArtworkSelectionManager()
            let first = manager.drawNext(pool: pool, dayKey: "x", reason: .daily, using: &rng)!.artwork.id
            counts[first, default: 0] += 1
        }
        for id in pool.ids {
            XCTAssertEqual(Double(counts[id] ?? 0), 500, accuracy: 100)
        }
    }

    func testPersistenceAcrossLaunchesContinuesTheSameCycle() throws {
        let dir = try Fixtures.temporaryDirectory()
        let store = ArtworkHistoryStore(fileURL: dir.appendingPathComponent("State/selection.json"))
        let pool = Fixtures.pool(count: 20)
        var rng = SeededGenerator(seed: 3)

        var seen: [Int] = []
        for launch in 0..<4 {
            var manager = ArtworkSelectionManager(state: store.load())
            manager.reconcile(poolIDs: pool.ids, scope: .highlights, using: &rng)
            for day in 0..<5 {
                seen.append(manager.drawNext(pool: pool, dayKey: "l\(launch)d\(day)", reason: .daily, using: &rng)!.artwork.id)
            }
            try store.save(manager.state)
        }
        XCTAssertEqual(seen.count, 20)
        XCTAssertEqual(Set(seen).count, 20, "Restarting the app must not cause repeats")
        let reloaded = ArtworkSelectionManager(state: store.load())
        XCTAssertEqual(reloaded.current?.artwork.id, seen.last)
        XCTAssertEqual(reloaded.state.history.count, 20)
    }

    func testCorruptStateFileIsBackedUpNotFatal() throws {
        let dir = try Fixtures.temporaryDirectory()
        let file = dir.appendingPathComponent("selection.json")
        try Data("{ not json".utf8).write(to: file)
        let state = ArtworkHistoryStore(fileURL: file).load()
        XCTAssertTrue(state.history.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.contains("corrupt") })
    }

    func testPreviousAndNextNavigateHistoryWithoutLosingIt() {
        let pool = Fixtures.pool(count: 10)
        var rng = SeededGenerator(seed: 11)
        var manager = ArtworkSelectionManager()
        let a = manager.drawNext(pool: pool, dayKey: "1", reason: .daily, using: &rng)!
        let b = manager.drawNext(pool: pool, dayKey: "2", reason: .daily, using: &rng)!
        let c = manager.drawNext(pool: pool, dayKey: "2", reason: .manual, using: &rng)!

        XCTAssertEqual(manager.goBack()?.id, b.id)
        XCTAssertEqual(manager.goBack()?.id, a.id)
        XCTAssertNil(manager.goBack())
        XCTAssertTrue(manager.isViewingPast)
        XCTAssertEqual(manager.state.history.count, 3)
        XCTAssertEqual(manager.goForwardInHistory()?.id, b.id)
        XCTAssertEqual(manager.goForwardInHistory()?.id, c.id)
        XCTAssertFalse(manager.isViewingPast)
        XCTAssertNil(manager.goForwardInHistory())
        XCTAssertEqual(manager.state.lastDailyDayKey, "2", "Manual picks don't count as the day's selection")
    }

    func testPoolChangesAreReconciled() {
        var rng = SeededGenerator(seed: 5)
        var manager = ArtworkSelectionManager()
        let pool = Fixtures.pool(count: 10)
        for i in 0..<4 { _ = manager.drawNext(pool: pool, dayKey: "\(i)", reason: .daily, using: &rng) }
        let shown = Set(manager.state.history.map(\.artwork.id))

        // Museum removes work 1..2 (if unseen they vanish) and adds 11, 12.
        let newIDs = Array(3...12)
        manager.reconcile(poolIDs: newIDs, scope: .highlights, using: &rng)
        XCTAssertFalse(manager.state.bag.contains(1))
        XCTAssertFalse(manager.state.bag.contains(2))
        XCTAssertTrue(manager.state.bag.contains(11))
        XCTAssertTrue(manager.state.bag.contains(12))
        XCTAssertTrue(Set(manager.state.bag).isDisjoint(with: shown), "Already-shown works stay out of this cycle")
    }

    func testOfflineFallsBackToADownloadedWork() {
        let pool = Fixtures.pool(count: 10)
        var rng = SeededGenerator(seed: 9)
        var manager = ArtworkSelectionManager()
        _ = manager.upcoming(count: 1, poolIDs: pool.ids, using: &rng)
        let downloaded = manager.state.bag[4]
        let entry = manager.drawNext(pool: pool, dayKey: "1", reason: .daily, using: &rng) { $0 == downloaded }
        XCTAssertEqual(entry?.artwork.id, downloaded)
        XCTAssertEqual(manager.state.bag.count, 9, "Skipped works remain for later")

        let none = manager.drawNext(pool: pool, dayKey: "2", reason: .daily, using: &rng) { _ in false }
        XCTAssertNil(none, "With nothing available the current artwork is kept")
        XCTAssertEqual(manager.current?.artwork.id, downloaded)
        XCTAssertEqual(manager.state.lastDailyDayKey, "1")
    }

    func testUnavailableImageLeavesCycle() {
        let pool = Fixtures.pool(count: 3)
        var rng = SeededGenerator(seed: 2)
        var manager = ArtworkSelectionManager()
        let head = manager.upcoming(count: 1, poolIDs: pool.ids, using: &rng)[0]
        manager.markUnavailable(head)
        let a = manager.drawNext(pool: pool, dayKey: "1", reason: .daily, using: &rng)!
        let b = manager.drawNext(pool: pool, dayKey: "2", reason: .daily, using: &rng)!
        XCTAssertFalse([a.artwork.id, b.artwork.id].contains(head))
        XCTAssertEqual(manager.state.cycle, 1)
    }

    func testResetKeepsCurrentArtwork() {
        let pool = Fixtures.pool(count: 5)
        var rng = SeededGenerator(seed: 4)
        var manager = ArtworkSelectionManager()
        for i in 0..<3 { _ = manager.drawNext(pool: pool, dayKey: "\(i)", reason: .daily, using: &rng) }
        let current = manager.current
        manager.reset()
        XCTAssertEqual(manager.state.history.count, 1)
        XCTAssertEqual(manager.current, current)
        XCTAssertEqual(manager.state.shownInCycle, [current!.artwork.id])
    }

    func testHistoryIsCapped() {
        let pool = Fixtures.pool(count: 3)
        var rng = SeededGenerator(seed: 8)
        var manager = ArtworkSelectionManager()
        for i in 0..<(ArtworkSelectionManager.historyLimit + 20) {
            _ = manager.drawNext(pool: pool, dayKey: "\(i)", reason: .manual, using: &rng)
        }
        XCTAssertEqual(manager.state.history.count, ArtworkSelectionManager.historyLimit)
        XCTAssertEqual(manager.state.cursor, ArtworkSelectionManager.historyLimit - 1)
    }

    func testEmptyPoolSelectsNothing() {
        var rng = SeededGenerator(seed: 1)
        var manager = ArtworkSelectionManager()
        let empty = ArtworkPool(scope: .highlights, fetchedAt: Date(), artworks: [],
                                stats: PoolStats(apiTotal: 0, recordsReceived: 0, malformedRecords: 0, eligible: 0, rejections: [:]))
        XCTAssertNil(manager.drawNext(pool: empty, dayKey: "1", reason: .daily, using: &rng))
    }
}

final class ArtworkDayTests: XCTestCase {
    private func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    private func date(_ s: String, _ cal: Calendar) -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func testMidnightRollover() {
        let cal = calendar("America/New_York")
        XCTAssertEqual(ArtworkDay.key(for: date("2026-10-25 23:59", cal), changeTime: .midnight, calendar: cal), "2026-10-25")
        XCTAssertEqual(ArtworkDay.key(for: date("2026-10-26 00:00", cal), changeTime: .midnight, calendar: cal), "2026-10-26")
    }

    func testCustomChangeTime() {
        let cal = calendar("Europe/Paris")
        let seven = ChangeTime(hour: 7, minute: 0)
        XCTAssertEqual(ArtworkDay.key(for: date("2026-10-26 06:59", cal), changeTime: seven, calendar: cal), "2026-10-25")
        XCTAssertEqual(ArtworkDay.key(for: date("2026-10-26 07:00", cal), changeTime: seven, calendar: cal), "2026-10-26")
        XCTAssertEqual(ArtworkDay.nextChange(after: date("2026-10-26 06:00", cal), changeTime: seven, calendar: cal),
                       date("2026-10-26 07:00", cal))
        XCTAssertEqual(ArtworkDay.nextChange(after: date("2026-10-26 07:00", cal), changeTime: seven, calendar: cal),
                       date("2026-10-27 07:00", cal))
    }

    func testWakeAfterMissedChangeTimeSeesNewDay() {
        // Mac asleep across the change time: the first check after wake has a new key.
        let cal = calendar("America/Los_Angeles")
        let six = ChangeTime(hour: 6, minute: 0)
        let beforeSleep = ArtworkDay.key(for: date("2026-10-25 22:00", cal), changeTime: six, calendar: cal)
        let afterWake = ArtworkDay.key(for: date("2026-10-26 09:30", cal), changeTime: six, calendar: cal)
        XCTAssertNotEqual(beforeSleep, afterWake)
        XCTAssertTrue(afterWake > beforeSleep, "Keys sort chronologically")
    }

    func testDaylightSavingGap() {
        // 02:30 doesn't exist on 8 March 2026 in New York; the change happens at 03:00.
        let cal = calendar("America/New_York")
        let t = ChangeTime(hour: 2, minute: 30)
        let next = ArtworkDay.nextChange(after: date("2026-03-08 01:00", cal), changeTime: t, calendar: cal)
        XCTAssertEqual(next, date("2026-03-08 03:00", cal))
        XCTAssertEqual(ArtworkDay.key(for: date("2026-03-08 03:01", cal), changeTime: t, calendar: cal), "2026-03-08")
    }

    func testMonthAndYearBoundaries() {
        let cal = calendar("UTC")
        XCTAssertEqual(ArtworkDay.key(for: date("2027-01-01 03:00", cal), changeTime: ChangeTime(hour: 5, minute: 0), calendar: cal), "2026-12-31")
    }
}
