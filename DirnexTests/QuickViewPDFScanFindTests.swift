import AppKit
import DirnexCore
import PDFKit
import Testing

@testable import Dirnex

/// What a reader *sees* when the PDF in front of them is a picture of a page (2026-09-19).
///
/// Whether the pages are read at all, and when, is the suite beside this one
/// (`QuickViewPDFScanReadingTests`); what is here is what the reading is for. That the count line
/// does not answer "No matches" about a document most of which it has not read, and says so with
/// the `+` that already means "and more to come" once something *has* been found. That a match on a
/// read page is drawn where there is no selection to be made of it. And the rule about scrolling,
/// from all three directions: a page landing must not pull a reader who has moved away, a match that
/// only turns up on a later page must still be gone to when it does, and a search the reader asked
/// for scrolls to its answer whether or not that answer has moved.
@Suite("Quick View PDF scan find", .serialized)
@MainActor
struct QuickViewPDFScanFindTests {
    private typealias Typing = QuickViewTableFilterFixtures
    private typealias Scans = QuickViewPDFScanFixtures

    @Test("a page landing does not scroll the reader back to the current match")
    func readingDoesNotScrollTheReaderBack() async throws {
        let fixture = try await Scans.scanned()
        let surface = fixture.surface
        fixture.recognizer.holdEachPage = true

        try await Typing.type("beta", into: surface)
        try await settleUntil { surface.find.matches?.isEmpty == false }

        // The reader goes somewhere else while the pages are still being read. Three pages a
        // second, each re-running the search, would otherwise yank them back to the current match
        // for the length of the book.
        let document = try #require(surface.pdfView.document)
        let last = try #require(document.page(at: document.pageCount - 1))
        surface.pdfView.go(to: last)
        let before = document.index(for: try #require(surface.pdfView.currentPage))

        fixture.recognizer.releaseAll()
        await Scans.finishReading(surface)

        let after = document.index(for: try #require(surface.pdfView.currentPage))
        #expect(after == before)
    }

    @Test("a match that only turns up on a later page is scrolled to when it does")
    func aLateMatchIsRevealed() async throws {
        let fixture = try await Scans.scanned()
        let surface = fixture.surface
        // Held, or the fake's instant answers can land before the first assertion is read.
        fixture.recognizer.holdEachPage = true

        // Only on the last page, so the reader waits out both readings for their answer — and the
        // rule that keeps a landing page from scrolling them must not swallow the one that does.
        try await Typing.type("omega", into: surface)
        try await settleUntil { fixture.recognizer.asked.count == 1 }
        #expect(surface.find.matches?.isEmpty == true)
        let document = try #require(surface.pdfView.document)
        #expect(document.index(for: try #require(surface.pdfView.currentPage)) == 0)

        fixture.recognizer.releaseAll()
        await Scans.finishReading(surface)

        #expect(surface.find.matches?.count == 1)
        #expect(document.index(for: try #require(surface.pdfView.currentPage)) == 2)
    }

    /// The other side of `readingDoesNotScrollTheReaderBack`, and what stops "do not scroll on a
    /// re-run" from quietly becoming "do not scroll". A search the reader asked for goes to its
    /// match whether or not that match has moved — here it has not, since the same word is still
    /// found in the same place.
    @Test("a search the reader asked for still scrolls to a match that has not moved")
    func anAskedForSearchStillReveals() async throws {
        let fixture = try await Scans.textOnly()
        let surface = fixture.surface

        try await Typing.type("beta", into: surface)
        let found = try #require(surface.find.currentRange)
        #expect(surface.pdfView.currentSelection != nil)

        // Take the witness away, then ask for a search that lands on the very same match.
        surface.pdfView.setCurrentSelection(nil, animate: false)
        surface.filterBar.applyOptions(.caseSensitive)
        await surface.filterTask?.value

        #expect(surface.find.currentRange == found)
        #expect(surface.pdfView.currentSelection != nil)
    }

    @Test("what a scanned page was read as is searched, and found")
    func findsWhatWasRead() async throws {
        let fixture = try await Scans.scanned()
        let surface = fixture.surface

        try await Typing.type("beta", into: surface)
        await Scans.finishReading(surface)

        // Page 0 carries its own text and holds one; the two scanned pages hold one each.
        #expect(surface.find.matches?.count == 3)
        #expect(surface.filterBar.countLabel.stringValue.contains("3"))
    }

    @Test("while pages are still unread the count says so rather than answering No matches")
    func theCountLineDoesNotLie() async throws {
        let fixture = try await Scans.scanned()
        let surface = fixture.surface
        fixture.recognizer.holdEachPage = true

        // A word that is only on the last page, so nothing is found until the reading gets there.
        try await Typing.type("omega", into: surface)
        try await settleUntil { fixture.recognizer.asked.count == 1 }

        let line = surface.filterBar.countLabel.stringValue
        #expect(!line.isEmpty)
        #expect(!line.contains("No matches"))
        // "Reading 0 of 2 scanned pages" — the total is what has to be read, not the page count.
        #expect(line.contains("2"))

        fixture.recognizer.releaseAll()
        await Scans.finishReading(surface)
        #expect(surface.find.matches?.count == 1)
    }

    @Test("a count found before the reading has finished promises more to come")
    func anIncompleteCountSaysSo() async throws {
        let fixture = try await Scans.scanned()
        let surface = fixture.surface
        fixture.recognizer.holdEachPage = true

        try await Typing.type("beta", into: surface)
        try await settleUntil { surface.find.matches?.isEmpty == false }

        // Page 0's own text has already been searched, so there is a match — and two pages are
        // still unread, so the count must not read as final.
        #expect(surface.filterBar.countLabel.stringValue.contains("+"))

        fixture.recognizer.releaseAll()
        await Scans.finishReading(surface)
        #expect(!surface.filterBar.countLabel.stringValue.contains("+"))
    }

    @Test("a match on a read page is drawn over the words it covers, the current one in orange")
    func drawsOnAReadPage() async throws {
        let fixture = try await Scans.scanned()
        let surface = fixture.surface

        try await Typing.type("beta", into: surface)
        await Scans.finishReading(surface)
        // The current match is on page 0, which has text; step onto one that had to be read.
        surface.stepFilterResult(by: 1)

        let drawn = surface.recognizedHighlights
        #expect(!drawn.isEmpty)
        #expect(drawn.allSatisfy { $0.annotation.type == "Highlight" })
        #expect(drawn.contains { $0.annotation.color == .systemOrange })
        // The outline has to be shaped in the annotation's own coordinates: measured, points in
        // page space draw nothing at all.
        let quads = try #require(drawn.first?.annotation.quadrilateralPoints)
        #expect(quads.count == 4)
        let bounds = try #require(drawn.first?.annotation.bounds)
        #expect(quads.allSatisfy { $0.pointValue.x <= bounds.width + 0.001 })
        #expect(quads.allSatisfy { $0.pointValue.y <= bounds.height + 0.001 })
    }

    @Test("a drawn outline sits where the word is, not at the corner of the page")
    func drawnWhereTheWordIs() async throws {
        let fixture = try await Scans.scanned()
        let surface = fixture.surface

        try await Typing.type("beta", into: surface)
        await Scans.finishReading(surface)
        surface.stepFilterResult(by: 1)

        let drawn = try #require(surface.recognizedHighlights.first)
        let media = drawn.page.bounds(for: .mediaBox)
        // The fake puts its word across the middle of the page: a highlight at the origin would be
        // the space-sentinel bug, and one covering the page would be a missing transform.
        #expect(drawn.annotation.bounds.minY > media.height * 0.2)
        #expect(drawn.annotation.bounds.height < media.height * 0.5)
    }

    @Test("a new search takes the previous search's outlines off the page")
    func outlinesAreTakenOff() async throws {
        let fixture = try await Scans.scanned()
        let surface = fixture.surface

        try await Typing.type("beta", into: surface)
        await Scans.finishReading(surface)
        surface.stepFilterResult(by: 1)
        let page = try #require(surface.recognizedHighlights.first?.page)
        #expect(!page.annotations.isEmpty)

        try await Typing.type("", into: surface)
        #expect(surface.recognizedHighlights.isEmpty)
        #expect(page.annotations.isEmpty)
    }
}
