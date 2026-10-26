import XCTest

final class APIParsingTests: XCTestCase {
    /// Real records captured from the live API (highlight=1&cc0&has_image=1), Oct 2026.
    func testParsesRealMuseumRecords() throws {
        let response = try JSONDecoder().decode(CMAListResponse.self, from: Fixtures.data("cma_highlights_sample"))
        let records = response.data.compactMap { $0 }
        XCTAssertEqual(records.count, 5)

        let bellows = try XCTUnwrap(records.first { $0.id == 92937 })
        XCTAssertEqual(bellows.title, "Stag at Sharkey's")
        XCTAssertEqual(bellows.shareLicenseStatus, "CC0")
        XCTAssertEqual(bellows.isHighlight, true)
        // The API encodes image dimensions as strings.
        XCTAssertEqual(bellows.images?.print?.width, 3400)
        XCTAssertEqual(bellows.images?.print?.height, 2542)
        XCTAssertEqual(bellows.images?.full?.url?.hasSuffix(".tif"), true)
        XCTAssertEqual(bellows.creators.first?.description, "George Bellows (American, 1882–1925)")

        let nataraja = try XCTUnwrap(records.first { $0.id == 111811 })
        XCTAssertTrue(nataraja.creators.isEmpty, "Many works have no named maker")
        XCTAssertEqual(nataraja.culture.first?.hasPrefix("South India"), true)
    }

    func testMalformedRecordsDoNotBreakThePage() throws {
        let json = """
        {"info": {"total": "4"},
         "data": [
           {"id": "77", "title": 12, "creators": "not a list", "culture": "Single culture",
            "images": {"annotation": "text", "print": {"url": "https://x/y_print.jpg", "width": 3000, "height": "2000"}},
            "is_highlight": 1, "share_license_status": "CC0", "description": null},
           {"title": "no id at all"},
           "a string instead of an object",
           {"id": 78, "images": null, "description": ["wrong", "type"]}
         ]}
        """
        let response = try JSONDecoder().decode(CMAListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.data.count, 4)
        XCTAssertNil(response.info?.total, "Non-numeric total is tolerated as nil")
        let records = response.data.compactMap { $0 }
        XCTAssertEqual(records.map(\.id), [77, 78])
        XCTAssertEqual(records[0].title, "12")
        XCTAssertEqual(records[0].culture, ["Single culture"])
        XCTAssertTrue(records[0].creators.isEmpty)
        XCTAssertEqual(records[0].isHighlight, true)
        XCTAssertEqual(records[0].images?.print?.height, 2000)
        XCTAssertNil(records[1].images)
        XCTAssertNil(records[1].description)
    }

    func testListURLRequestsHighlightsCC0AndImages() {
        let client = ClevelandArtAPIClient(loader: MockLoader { _, _ in (Data(), 200) })
        let url = client.listURL(scope: .highlights, skip: 0, limit: 100).absoluteString
        XCTAssertTrue(url.contains("highlight=1"))
        XCTAssertTrue(url.contains("cc0"))
        XCTAssertTrue(url.contains("has_image=1"))
        XCTAssertTrue(url.contains("fields="))
        let expanded = client.listURL(scope: .expanded, skip: 0, limit: 100).absoluteString
        XCTAssertFalse(expanded.contains("highlight=1"))
    }
}

final class TextFormatterTests: XCTestCase {
    func testItalicsLineBreaksAndEntities() {
        let runs = MuseumTextFormatter.runs(fromHTML: "Like <em>Two Poplars</em>, it&rsquo;s&nbsp;bold &amp; new.<br>Second&#160;line &#x2014; end")
        XCTAssertEqual(runs.map(\.text).joined(), "Like Two Poplars, it’s bold & new.\nSecond line — end")
        XCTAssertEqual(runs.first { $0.isItalic }?.text, "Two Poplars")
    }

    func testParagraphsCollapseToOneBlankLine() {
        let text = MuseumTextFormatter.plainText(fromHTML: "<p>One</p>\r\n<p>Two</p><br><br><br>Three  ")
        XCTAssertEqual(text, "One\n\nTwo\n\nThree")
    }

    func testPreservesUnicodeAndLiteralAngleBrackets() {
        let text = MuseumTextFormatter.plainText(fromHTML: "Yūzū Nenbutsu (1185–1333) — size < 2 cm, café")
        XCTAssertEqual(text, "Yūzū Nenbutsu (1185–1333) — size < 2 cm, café")
    }

    func testDropsLinksAndCommentsButKeepsTheirText() {
        let text = MuseumTextFormatter.plainText(fromHTML: "<div><!--block-->See <a href=\"https://x\">the scroll</a>.</div>")
        XCTAssertEqual(text, "See the scroll.")
    }

    func testPlainTextNewlinesAreKept() {
        XCTAssertEqual(MuseumTextFormatter.plainText(fromHTML: "Line one\nLine two"), "Line one\nLine two")
    }

    func testWordsAreNeverChanged() throws {
        // The formatter may only strip markup; every word of the museum text must survive.
        for record in try Fixtures.realRecords() {
            guard let raw = record.description else { continue }
            let stripped = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            let expectedWords = stripped.split(whereSeparator: { $0.isWhitespace }).filter { !$0.contains("&") }
            let output = MuseumTextFormatter.plainText(fromHTML: raw)
            for word in expectedWords {
                XCTAssertTrue(output.contains(word), "Missing word \(word) in \(record.id)")
            }
        }
    }
}
