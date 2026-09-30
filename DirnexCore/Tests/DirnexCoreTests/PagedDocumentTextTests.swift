import Testing
@testable import DirnexCore

/// ``PagedDocumentText`` — a document's text gathered a page at a time, where the scanned pages
/// have to be read before they have any.
@Suite("Paged document text")
struct PagedDocumentTextTests {
    private static func recognized(_ text: String) -> PagedDocumentText.PageText {
        .recognized(RecognizedPageText(
            text: text,
            words: [RecognizedWord(
                range: 0..<text.utf16.count,
                quad: TextQuad(
                    topLeft: TextPoint(x: 0.1, y: 0.8),
                    topRight: TextPoint(x: 0.9, y: 0.8),
                    bottomLeft: TextPoint(x: 0.1, y: 0.7),
                    bottomRight: TextPoint(x: 0.9, y: 0.7)
                )
            )]
        ))
    }

    @Test("a document whose pages all carry text is complete at once, joined by one newline")
    func everyPageHasText() {
        let document = PagedDocumentText(layerText: ["alpha", "beta", "gamma"])

        #expect(document.isComplete)
        #expect(!document.needsReading)
        #expect(document.unreadPageCount == 0)
        #expect(document.text == "alpha\nbeta\ngamma")
        #expect(document.unreadPages.isEmpty)
        #expect(document.segments.lengths == [5, 4, 5])
    }

    @Test("a page with no text layer, and one holding only whitespace, are both pages to read")
    func theReadingRule() {
        // Measured against the scanned books on this Mac: their pages are either absent,
        // whitespace-only, or a full page of text, with nothing in between.
        let document = PagedDocumentText(layerText: ["alpha", nil, "  \n ", "beta"])

        #expect(!document.isComplete)
        #expect(document.needsReading)
        #expect(document.unreadPageCount == 2)
        #expect(document.unreadPages == [1, 2])
    }

    @Test("a page waits for the ones before it, so an offset never moves once it is searchable")
    func strictlyInOrder() {
        var document = PagedDocumentText(layerText: [nil, nil, "gamma"])
        // Page 2's text was there all along and still waits: appending it now would put page 0 and
        // page 1 after it, and every offset a search had already answered would be wrong.
        #expect(document.readyCount == 0)
        #expect(document.text.isEmpty)

        document.set(Self.recognized("beta"), at: 1)
        #expect(document.readyCount == 0)
        #expect(document.text.isEmpty)

        document.set(Self.recognized("alpha"), at: 0)
        // Now all three become contiguous at once.
        #expect(document.readyCount == 3)
        #expect(document.text == "alpha\nbeta\ngamma")
        #expect(document.isComplete)
    }

    @Test("what was searchable stays where it was as later pages land")
    func offsetsOnlyEverGrow() {
        var document = PagedDocumentText(layerText: ["alpha", nil, nil])
        #expect(document.text == "alpha")
        let firstPageStart = document.offset(ofPage: 0)

        document.set(Self.recognized("beta"), at: 1)
        #expect(document.text == "alpha\nbeta")
        #expect(document.offset(ofPage: 0) == firstPageStart)
        #expect(document.offset(ofPage: 1) == 6)

        document.set(Self.recognized("gamma"), at: 2)
        #expect(document.text == "alpha\nbeta\ngamma")
        #expect(document.offset(ofPage: 1) == 6)
        #expect(document.offset(ofPage: 2) == 11)
    }

    @Test("an offset is only answered for a page that is searchable")
    func offsetOfAnUnknownPage() {
        let document = PagedDocumentText(layerText: ["alpha", nil, "gamma"])
        #expect(document.offset(ofPage: 0) == 0)
        #expect(document.offset(ofPage: 1) == nil)
        #expect(document.offset(ofPage: 2) == nil)
        #expect(document.offset(ofPage: -1) == nil)
    }

    @Test("reading a page twice does not renumber a text that has already been searched")
    func aDuplicateAnswerIsIgnored() {
        var document = PagedDocumentText(layerText: [nil, "beta"])
        document.set(Self.recognized("alpha"), at: 0)
        #expect(document.text == "alpha\nbeta")
        #expect(document.readCount == 1)

        document.set(Self.recognized("something else entirely"), at: 0)
        #expect(document.text == "alpha\nbeta")
        #expect(document.readCount == 1)
    }

    @Test("reading is counted against a total that does not move")
    func progress() {
        var document = PagedDocumentText(layerText: [nil, "beta", nil, nil])
        #expect(document.unreadPageCount == 3)
        #expect(document.readCount == 0)

        document.set(Self.recognized("alpha"), at: 0)
        document.set(Self.recognized("gamma"), at: 2)
        #expect(document.readCount == 2)
        #expect(document.unreadPageCount == 3)
        #expect(!document.isComplete)

        document.set(Self.recognized("delta"), at: 3)
        #expect(document.readCount == 3)
        #expect(document.isComplete)
    }

    @Test("a match on a page with a text layer is placed by offsets into that page's own text")
    func placingOnALayerPage() {
        let document = PagedDocumentText(layerText: ["alpha", "beta"])
        // "eta" in page 1, whose own text is "beta": document offsets 7..<10.
        #expect(document.placement(of: 7..<10) == [.layer(page: 1, range: 1..<4)])
    }

    @Test("a match on a read page is placed by the outlines of the words it covers")
    func placingOnARecognizedPage() {
        var document = PagedDocumentText(layerText: ["alpha", nil])
        document.set(Self.recognized("beta"), at: 1)

        let placed = document.placement(of: 6..<10)
        #expect(placed.count == 1)
        guard case let .recognized(page, quads) = placed.first else {
            Issue.record("expected a recognized placement, got \(String(describing: placed.first))")
            return
        }
        #expect(page == 1)
        #expect(quads.count == 1)
    }

    @Test("a match running across a page break is placed on both pages, by whatever each can draw")
    func placingAcrossAPageBreak() {
        var document = PagedDocumentText(layerText: ["alpha", nil])
        document.set(Self.recognized("beta"), at: 1)

        // "a\nb" — the last character of page 0, the separator, and the first of page 1.
        let placed = document.placement(of: 4..<7)
        #expect(placed.count == 2)
        #expect(placed.first == .layer(page: 0, range: 4..<5))
        if case let .recognized(page, _) = placed.last {
            #expect(page == 1)
        } else {
            Issue.record("expected the second piece to be a recognized placement")
        }
    }

    @Test("nothing is placed on a page that has not been read")
    func placingOnAnUnknownPage() {
        let document = PagedDocumentText(layerText: [nil, "beta"])
        #expect(document.placement(of: 0..<3).isEmpty)
    }

    @Test("a word whose outline Vision placed at the page corner is not drawn")
    func theSpaceSentinelIsNotPlaced() {
        var document = PagedDocumentText(layerText: [nil])
        document.set(.recognized(RecognizedPageText(
            text: "a b",
            words: [RecognizedWord(
                range: 1..<2,
                quad: TextQuad(
                    topLeft: TextPoint(x: 0, y: 1),
                    topRight: TextPoint(x: 0, y: 1),
                    bottomLeft: TextPoint(x: 0, y: 1),
                    bottomRight: TextPoint(x: 0, y: 1)
                )
            )]
        )), at: 0)

        guard case let .recognized(_, quads) = document.placement(of: 1..<2).first else {
            Issue.record("expected a recognized placement")
            return
        }
        #expect(quads.isEmpty)
    }

    @Test("a document with no pages is complete and searchable, and finds nothing")
    func noPages() {
        let document = PagedDocumentText(layerText: [])
        #expect(document.isComplete)
        #expect(document.text.isEmpty)
        #expect(document.placement(of: 0..<1).isEmpty)
    }
}
