import AppKit
import DirnexCore
import PDFKit
import Testing

@testable import Dirnex

/// Reading a PDF's scanned pages: whether it happens, in what order, and when it stops
/// (2026-09-19).
///
/// What Vision reads is not this suite's subject — that is a framework, measured before any of this
/// was written and exercised once against a real page below. What is here is everything around it,
/// because recognizing a book is 40–65 s of somebody's machine: that a query is what starts it and
/// nothing else is, that the pages are read in order so a match keeps its offsets while the rest
/// arrive, that any of the three ways of saying "I am no longer asking" ends it where it stands, and
/// that one abandoned reading cannot leave the next one running twice. What the reader sees while it
/// happens is the suite beside this one (`QuickViewPDFScanFindTests`).
@Suite("Quick View PDF scan reading", .serialized)
@MainActor
struct QuickViewPDFScanReadingTests {
    private typealias Typing = QuickViewTableFilterFixtures
    private typealias Scans = QuickViewPDFScanFixtures

    @Test("a scanned page is read only once something is typed, never on opening the bar")
    func readingWaitsForAQuery() async throws {
        let fixture = try await Scans.scanned()
        let surface = fixture.surface

        surface.beginFiltering()
        await surface.filterTask?.value
        #expect(fixture.recognizer.asked.isEmpty)

        try await Typing.type("beta", into: surface)
        await Scans.finishReading(surface)
        #expect(!fixture.recognizer.asked.isEmpty)
    }

    /// The guard the test above cannot see. Opening the bar reads nothing because nothing asks for
    /// the text at all — so with that rule deliberately removed, the test above still passes. What
    /// it protects is the race it *can* be reached through: a query typed and then cleared while
    /// the document's own text layer is still being read, where the search that is already in
    /// flight arrives at `findableText()` with nobody waiting any more.
    @Test("with the bar up and nothing typed, asking to read refuses")
    func nothingIsReadWithNoQuery() async throws {
        let fixture = try await Scans.scanned()
        let surface = fixture.surface

        surface.beginFiltering()
        _ = await surface.findableText()
        #expect(!surface.isReadingWanted)

        surface.startReadingScannedPages()
        await surface.recognitionTask?.value
        #expect(fixture.recognizer.asked.isEmpty)
    }

    @Test("the pages are read in order, so a match keeps its offsets while the rest arrive")
    func readInOrder() async throws {
        let fixture = try await Scans.scanned()
        let surface = fixture.surface

        try await Typing.type("beta", into: surface)
        await Scans.finishReading(surface)

        #expect(fixture.recognizer.asked == [1, 2])
    }

    @Test("clearing the query stops the reading where it stands")
    func clearingTheQueryStops() async throws {
        let fixture = try await Scans.scanned()
        let surface = fixture.surface
        fixture.recognizer.holdEachPage = true

        try await Typing.type("beta", into: surface)
        try await settleUntil { fixture.recognizer.asked.count == 1 }

        try await Typing.type("", into: surface)
        fixture.recognizer.releaseAll()
        await surface.recognitionTask?.value

        // The page being read when the query went is finished; the next one is never started.
        #expect(fixture.recognizer.asked == [1])
    }

    @Test("closing the bar stops the reading too")
    func closingTheBarStops() async throws {
        let fixture = try await Scans.scanned()
        let surface = fixture.surface
        fixture.recognizer.holdEachPage = true

        try await Typing.type("beta", into: surface)
        try await settleUntil { fixture.recognizer.asked.count == 1 }

        surface.endFiltering()
        fixture.recognizer.releaseAll()
        await surface.recognitionTask?.value

        #expect(fixture.recognizer.asked == [1])
    }

    @Test("another file under the cursor stops the reading and forgets what it was for")
    func anotherDocumentStops() async throws {
        let fixture = try await Scans.scanned()
        let surface = fixture.surface
        fixture.recognizer.holdEachPage = true

        try await Typing.type("beta", into: surface)
        try await settleUntil { fixture.recognizer.asked.count == 1 }

        surface.documentDidChange()
        fixture.recognizer.releaseAll()
        await surface.recognitionTask?.value

        #expect(fixture.recognizer.asked == [1])
        #expect(surface.find.matches == nil)
        #expect(!surface.hasReadPages)
    }

    /// The reading is held by one handle, and a task that has been abandoned must not clear it. A
    /// new document nils it and bumps the generation, so a page landing half a second later would
    /// otherwise find no reading in flight and start a second loop over the *new* document — two
    /// loops racing to read the same pages, at half a second of Vision apiece.
    ///
    /// Nothing here counts pages, and that is deliberate: PDFKit runs Live Text on a page it is
    /// *displaying* and fills its text layer, so a page or two of any freshly shown document may
    /// have text of its own by the time the bar is typed into and is rightly not read
    /// (docs/NOTES.md ▸ Vision). The first version of this test expected exactly two unread pages
    /// and failed one full run in five for that reason — a fact about the framework wearing a
    /// product defect's clothes. Five scanned pages, and every wait relative to what came before it.
    @Test("a reading abandoned for another file does not leave the next one reading twice")
    func anAbandonedReadingDoesNotStartASecond() async throws {
        let fixture = try await Scans.scanned()
        let surface = fixture.surface
        fixture.recognizer.holdEachPage = true

        try await Typing.type("beta", into: surface)
        try await settleUntil { fixture.recognizer.asked.count == 1 }
        let ofTheOldDocument = fixture.recognizer.asked.count

        // Another file under the cursor while the first reading is still inside the page it was on,
        // and a query typed against it, so there is a second reading for the first to interfere
        // with.
        fixture.recognizer.answers = Dictionary(
            uniqueKeysWithValues: (0..<5).map { ($0, Scans.recognizedLine("beta \($0)")) }
        )
        fixture.preview.showPDFDocument(Scans.document(
            pages: (0..<5).map { .scanned("beta \($0)") }
        ))
        try await Typing.type("beta", into: surface)
        try await settleUntil { fixture.recognizer.asked.count > ofTheOldDocument }
        let readingTheNewDocument = surface.recognitionTask
        let afterTheFirstPage = fixture.recognizer.asked.count

        // Both held pages finish: the abandoned one returns, having been told its generation is
        // gone, while the new reading takes its next page and is held on that. So the handle is
        // read while there really is a reading in flight for it to belong to.
        fixture.recognizer.releaseHeld()
        try await settleUntil { fixture.recognizer.asked.count > afterTheFirstPage }
        #expect(
            surface.recognitionTask == readingTheNewDocument,
            "the handle is not somebody else's to clear"
        )

        fixture.recognizer.releaseAll()
        await Scans.finishReading(surface)
        let asked = Array(fixture.recognizer.asked.dropFirst(ofTheOldDocument))
        #expect(asked.count >= 2)
        #expect(Set(asked).count == asked.count, "no page is read twice")
    }

    @Test("a page that cannot be read counts as read and empty, so the rest are not stalled")
    func anUnreadablePageDoesNotStall() async throws {
        let fixture = try await Scans.scanned()
        let surface = fixture.surface
        // Page 1 answers nothing at all — the whole document is behind it, because the text can
        // only grow at its end.
        fixture.recognizer.answers.removeValue(forKey: 1)

        try await Typing.type("beta", into: surface)
        await Scans.finishReading(surface)

        #expect(surface.pages.isComplete)
        #expect(fixture.recognizer.asked == [1, 2])
        // Page 0's own and page 2's, but not the page that could not be read.
        #expect(surface.find.matches?.count == 2)
    }

    @Test("an ordinary PDF reads nothing and says nothing about reading")
    func anOrdinaryDocumentIsUntouched() async throws {
        let fixture = try await Scans.textOnly()
        let surface = fixture.surface

        try await Typing.type("beta", into: surface)
        await Scans.finishReading(surface)

        #expect(fixture.recognizer.asked.isEmpty)
        #expect(surface.findReadingProgress == nil)
        #expect(surface.filterBar.countLabel.stringValue.contains("1"))
    }

    /// The one test that runs the real thing, so the pieces in between — the render, Vision, the
    /// word ranges and the turn back into page coordinates — are covered by something other than a
    /// fake agreeing with itself.
    @Test("the real recognizer reads a rasterized page and puts the word where it was drawn")
    func theRealRecognizerReads() async throws {
        let document = try #require(
            QuickViewPDFScanFixtures.document(pages: [.scanned("beta gamma")])
        )
        let read = try #require(
            await VisionPageTextRecognizer.shared.recognizeText(ofPage: 0, in: document)
        )

        #expect(read.text.lowercased().contains("beta"))
        let word = try #require(read.words.first)
        let box = word.quad.boundingBox
        // Drawn across the middle of the page, so it is neither at the origin (the space sentinel)
        // nor the whole page (a missing transform).
        #expect(box.y > 0.2)
        #expect(box.y < 0.8)
        #expect(box.width < 0.9)
        #expect(word.quad.isDrawable)
    }
}
