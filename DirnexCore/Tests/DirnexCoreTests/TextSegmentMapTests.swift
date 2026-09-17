import Testing
@testable import DirnexCore

/// ``TextSegmentMap`` — the arithmetic that turns an offset into the joined text of a PDF's pages,
/// or of a page and its frames, back into the piece that holds it.
@Suite("Text segment map")
struct TextSegmentMapTests {
    /// The join a PDF is: pages separated by one newline apiece.
    private let pages = TextSegmentMap(lengths: [10, 5, 7])

    @Test("the total counts the separators between the segments and not past the last one")
    func total() {
        #expect(pages.totalLength == 24)
        #expect(TextSegmentMap(lengths: []).totalLength == 0)
        #expect(TextSegmentMap(lengths: [4]).totalLength == 4)
        #expect(TextSegmentMap(lengths: [4, 4], separator: 0).totalLength == 8)
    }

    @Test("an offset lands in the segment holding it, measured from that segment's own start")
    func locating() throws {
        let first = try #require(pages.segment(at: 0))
        #expect(first == (0, 0))
        let lastOfFirst = try #require(pages.segment(at: 9))
        #expect(lastOfFirst == (0, 9))
        let second = try #require(pages.segment(at: 11))
        #expect(second == (1, 0))
        let third = try #require(pages.segment(at: 17))
        #expect(third == (2, 0))
        let lastOfAll = try #require(pages.segment(at: 23))
        #expect(lastOfAll == (2, 6))
    }

    @Test("the separator between two segments belongs to neither")
    func separatorBelongsToNobody() {
        // Offset 10 is the newline after the first page, 16 the one after the second.
        #expect(pages.segment(at: 10) == nil)
        #expect(pages.segment(at: 16) == nil)
    }

    @Test("an offset past the end, or before it, lands nowhere")
    func outOfRange() {
        #expect(pages.segment(at: 24) == nil)
        #expect(pages.segment(at: 99) == nil)
        #expect(pages.segment(at: -1) == nil)
        #expect(TextSegmentMap(lengths: []).segment(at: 0) == nil)
    }

    @Test("a match inside one segment is one piece, in that segment's own offsets")
    func splitWithinOne() throws {
        let pieces = pages.split(2..<6)
        #expect(pieces.count == 1)
        let piece = try #require(pieces.first)
        #expect(piece.index == 0)
        #expect(piece.range == 2..<6)

        let later = pages.split(18..<21)
        #expect(later.count == 1)
        #expect(later.first?.index == 2)
        #expect(later.first?.range == 1..<4)
    }

    @Test("a match running across a page break is a piece per page, the separator dropped")
    func splitAcross() {
        let pieces = pages.split(8..<13)
        #expect(pieces.count == 2)
        #expect(pieces.first?.index == 0)
        #expect(pieces.first?.range == 8..<10)
        #expect(pieces.last?.index == 1)
        #expect(pieces.last?.range == 0..<2)
        // The separator is not covered: two pieces of 2 and 2 for a range of 5 units.
        #expect(pieces.map(\.range.count).reduce(0, +) == 4)
    }

    @Test("a match spanning three segments gives all three")
    func splitAcrossThree() {
        let pieces = pages.split(9..<18)
        #expect(pieces.map(\.index) == [0, 1, 2])
        #expect(pieces.map(\.range) == [9..<10, 0..<5, 0..<1])
    }

    @Test("a range that is only a separator, empty, or past the end gives nothing")
    func splitNothing() {
        #expect(pages.split(10..<11).isEmpty)
        #expect(pages.split(5..<5).isEmpty)
        #expect(pages.split(24..<30).isEmpty)
    }

    @Test("a range past the end keeps the part that is inside")
    func splitClamped() {
        let pieces = pages.split(22..<40)
        #expect(pieces.count == 1)
        #expect(pieces.first?.index == 2)
        #expect(pieces.first?.range == 5..<7)
    }

    @Test("with no separator the segments run straight into one another")
    func noSeparator() throws {
        let frames = TextSegmentMap(lengths: [3, 3], separator: 0)
        let boundary = try #require(frames.segment(at: 3))
        #expect(boundary == (1, 0))
        #expect(frames.split(2..<4).map(\.index) == [0, 1])
    }

    @Test("an empty segment is skipped rather than swallowing an offset")
    func emptySegments() throws {
        // A blank PDF page, or a frame with no text: it holds nothing, so nothing lands in it.
        let withBlank = TextSegmentMap(lengths: [4, 0, 4])
        let after = try #require(withBlank.segment(at: 6))
        #expect(after == (2, 0))
        #expect(withBlank.split(0..<4).map(\.index) == [0])
        #expect(withBlank.totalLength == 10)
    }
}
