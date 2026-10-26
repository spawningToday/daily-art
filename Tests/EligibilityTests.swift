import XCTest

final class EligibilityTests: XCTestCase {
    let filter = ArtworkEligibilityFilter()

    func testRealHighlightsAreEligibleAndHandScrollIsExcluded() throws {
        let records = try Fixtures.realRecords()
        let pool = ArtworkRepository.buildPool(records: records, malformed: 0, apiTotal: 5, scope: .highlights, fetchedAt: Date())
        XCTAssertEqual(Set(pool.ids), [102578, 92937, 111811, 122979])
        XCTAssertEqual(pool.stats.rejections[ArtworkEligibilityFilter.Rejection.extremeAspectRatio.rawValue], 1,
                       "The 3400×79 px hand scroll can't be shown legibly")

        let bellows = try XCTUnwrap(pool.artwork(id: 92937))
        XCTAssertEqual(bellows.primaryText.field, .description)
        XCTAssertTrue(bellows.primaryText.plainText.hasPrefix("Bellows was no stranger to Sharkey’s Athletic Club"))
        XCTAssertFalse(bellows.primaryText.plainText.contains("<"))
        XCTAssertTrue(bellows.primaryText.runs.contains { $0.isItalic })
        XCTAssertEqual(bellows.didYouKnow?.field, .didYouKnow)
        XCTAssertEqual(bellows.image.url.lastPathComponent, "1922.1133_print.jpg")
        XCTAssertEqual(bellows.webURL?.absoluteString, "https://clevelandart.org/art/1922.1133")

        let nataraja = try XCTUnwrap(pool.artwork(id: 111811))
        XCTAssertEqual(nataraja.attribution, "South India, Tamil Nadu, Chola period (900–1200s)")

        let spirit = try XCTUnwrap(pool.artwork(id: 122979))
        XCTAssertEqual(spirit.primaryText.field, .description, "description is preferred over artlens_description")
        XCTAssertEqual(spirit.additionalTexts.map(\.field), [.artlensDescription, .didYouKnow])
    }

    func testCC0IsEnforcedClientSide() {
        for license in ["Copyrighted", "", nil] as [String?] {
            XCTAssertEqual(rejection(Fixtures.record(license: license)), .notCC0)
        }
        XCTAssertNotNil(try? filter.evaluate(Fixtures.record(license: " cc0 ")).get())
    }

    func testNonHighlightsExcludedByDefault() {
        XCTAssertEqual(rejection(Fixtures.record(highlight: false)), .notHighlight)
        XCTAssertEqual(rejection(Fixtures.record(highlight: nil)), .notHighlight)
        let expanded = ArtworkEligibilityFilter(scope: .expanded)
        XCTAssertNotNil(try? expanded.evaluate(Fixtures.record(highlight: false)).get())
    }

    func testMissingOrEmptyDescriptions() {
        XCTAssertEqual(rejection(Fixtures.record(description: nil)), .missingText)
        XCTAssertEqual(rejection(Fixtures.record(description: "   ")), .missingText)
        XCTAssertEqual(rejection(Fixtures.record(description: "<p><br></p>")), .missingText)
        XCTAssertEqual(rejection(Fixtures.record(description: "Too short.")), .missingText)
        // Catalog metadata copied into a text field is not an explanation.
        XCTAssertEqual(rejection(Fixtures.record(description: "Work 1, 1900. Oil on canvas.")), .missingText)
    }

    func testTextFallbackOrder() throws {
        let longArtlens = "An ArtLens text written by the museum's educators about this particular work."
        let longFact = "Did you know that this painting was once hidden in a barn for several decades?"
        let a = try filter.evaluate(Fixtures.record(description: nil, artlens: longArtlens, didYouKnow: longFact)).get()
        XCTAssertEqual(a.primaryText.field, .artlensDescription)
        XCTAssertEqual(a.primaryText.plainText, longArtlens)
        let b = try filter.evaluate(Fixtures.record(description: "", artlens: nil, didYouKnow: longFact)).get()
        XCTAssertEqual(b.primaryText.field, .didYouKnow)
    }

    func testUnavailableOrUnsuitableImages() {
        XCTAssertEqual(rejection(Fixtures.record(printURL: nil)), .missingImage)
        XCTAssertEqual(rejection(Fixtures.record(printURL: "not a url")), .missingImage)
        XCTAssertEqual(rejection(Fixtures.record(printURL: "http://insecure.example/x.jpg")), .missingImage)
        XCTAssertEqual(rejection(Fixtures.record(printURL: "https://x.example/master.tif")), .missingImage)
        XCTAssertEqual(rejection(Fixtures.record(width: nil)), .missingImage)
        XCTAssertEqual(rejection(Fixtures.record(width: 0, height: 0)), .missingImage)
        XCTAssertEqual(rejection(Fixtures.record(width: 1200, height: 900)), .imageTooSmall)
        XCTAssertEqual(rejection(Fixtures.record(width: 3400, height: 700)), .extremeAspectRatio)
    }

    func testDuplicateRecordsAreCountedOnce() {
        let records = [Fixtures.record(id: 5), Fixtures.record(id: 5), Fixtures.record(id: 6)]
        let pool = ArtworkRepository.buildPool(records: records, malformed: 0, apiTotal: 3, scope: .highlights, fetchedAt: Date())
        XCTAssertEqual(pool.ids, [5, 6])
    }

    private func rejection(_ record: CMARecord) -> ArtworkEligibilityFilter.Rejection? {
        if case .failure(let reason) = filter.evaluate(record) { return reason }
        return nil
    }
}
