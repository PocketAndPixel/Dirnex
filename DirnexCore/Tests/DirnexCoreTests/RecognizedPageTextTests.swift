import Foundation
import Testing
@testable import DirnexCore

/// ``RecognizedPageText`` — what recognizing a scanned page found, and where on the page a match in
/// it is drawn.
@Suite("Recognized page text")
struct RecognizedPageTextTests {
    /// A line of three words, laid out left to right across the middle of a page. Offsets are the
    /// UTF-16 ones a find counts in: `"job applicants here"`.
    private static func quad(x: Double, width: Double) -> TextQuad {
        TextQuad(
            topLeft: TextPoint(x: x, y: 0.52),
            topRight: TextPoint(x: x + width, y: 0.52),
            bottomLeft: TextPoint(x: x, y: 0.50),
            bottomRight: TextPoint(x: x + width, y: 0.50)
        )
    }

    private let page = RecognizedPageText(
        text: "job applicants here",
        words: [
            RecognizedWord(range: 0..<3, quad: quad(x: 0.10, width: 0.05)),
            RecognizedWord(range: 4..<14, quad: quad(x: 0.16, width: 0.14)),
            RecognizedWord(range: 15..<19, quad: quad(x: 0.31, width: 0.06))
        ]
    )

    @Test("a match inside one word is drawn over that whole word, which is the grain Vision has")
    func partOfAWord() {
        // "applic" — Vision answers the same box for every character of a word (measured), so
        // there is no finer outline to draw and the word is what is marked.
        let quads = page.quads(overlapping: 4..<10)
        #expect(quads.count == 1)
        let box = quads.first?.boundingBox
        #expect(box?.x == 0.16)
        // A tolerance because the fixture's right edge is a sum: 0.16 + 0.14 back out to 0.14 is
        // 0.14000000000000001, which is the arithmetic-on-the-right trap this project records.
        #expect(abs((box?.width ?? 0) - 0.14) < 1e-9)
    }

    @Test("a match running across a space is drawn over both words")
    func acrossASpace() {
        // "job applicants"
        #expect(page.quads(overlapping: 0..<14).count == 2)
    }

    @Test("a match lying only in the space between two words is drawn nowhere")
    func betweenWords() {
        #expect(page.quads(overlapping: 3..<4).isEmpty)
    }

    @Test("an empty range is drawn nowhere")
    func emptyRange() {
        #expect(page.quads(overlapping: 5..<5).isEmpty)
    }

    @Test("a range past the end of the page finds nothing rather than the last word")
    func pastTheEnd() {
        #expect(page.quads(overlapping: 40..<50).isEmpty)
    }

    @Test("the length is the one a find counts and a page join adds up")
    func length() {
        #expect(page.length == 19)
        #expect(RecognizedPageText(text: "Панорама", words: []).length == 8)
    }
}

/// ``TextQuad`` — a word's outline on a page, and the one answer Vision gives that must never be
/// drawn.
@Suite("Text quad")
struct TextQuadTests {
    @Test("the bounding box contains all four corners, whatever the line's slope")
    func boundingBoxOfASkewedWord() {
        // A word 20° off horizontal — measured up to 28.6° on a real scan.
        let skewed = TextQuad(
            topLeft: TextPoint(x: 0.10, y: 0.50),
            topRight: TextPoint(x: 0.30, y: 0.57),
            bottomLeft: TextPoint(x: 0.10, y: 0.47),
            bottomRight: TextPoint(x: 0.30, y: 0.54)
        )
        let box = skewed.boundingBox
        #expect(box.x == 0.10)
        #expect(box.y == 0.47)
        #expect(abs(box.width - 0.20) < 1e-9)
        #expect(abs(box.height - 0.10) < 1e-9)
    }

    @Test("Vision's answer for a single space is refused, because it names the corner of the page")
    func theSpaceSentinel() {
        // Measured: `boundingBox(for:)` over one space answers x 0…0, y 1…1 rather than nothing at
        // all, so a caller that unions outlines without checking drags the union to the page's
        // corner — 484 pt of error on a 595 pt page, in the run that found this.
        let space = TextQuad(
            topLeft: TextPoint(x: 0, y: 1),
            topRight: TextPoint(x: 0, y: 1),
            bottomLeft: TextPoint(x: 0, y: 1),
            bottomRight: TextPoint(x: 0, y: 1)
        )
        #expect(!space.isDrawable)
    }

    @Test("a word with real area is drawable")
    func aRealWord() {
        let word = TextQuad(
            topLeft: TextPoint(x: 0.2, y: 0.77),
            topRight: TextPoint(x: 0.3, y: 0.77),
            bottomLeft: TextPoint(x: 0.2, y: 0.75),
            bottomRight: TextPoint(x: 0.3, y: 0.75)
        )
        #expect(word.isDrawable)
    }

    /// The word `applicants` as the page-20 fixture of a scanned book reads it, unturned:
    /// x 0.204…0.302, y 0.749…0.770 — the numbers the four rotations below were measured against.
    private static let asDrawnStraight = TextQuad(
        topLeft: TextPoint(x: 0.204, y: 0.770),
        topRight: TextPoint(x: 0.302, y: 0.770),
        bottomLeft: TextPoint(x: 0.204, y: 0.749),
        bottomRight: TextPoint(x: 0.302, y: 0.749)
    )

    @Test("an unturned page needs no transform at all")
    func noRotation() {
        #expect(Self.asDrawnStraight.unrotated(by: 0) == Self.asDrawnStraight)
        #expect(Self.asDrawnStraight.unrotated(by: 360) == Self.asDrawnStraight)
    }

    @Test("a quarter-turned page's outline comes back where the word really is")
    func quarterTurns() {
        // Measured: the same word, on the same page, read after setting `page.rotation`. Note the
        // corner labels — Vision names them in the text's own reading frame, so at 90° the
        // labelled top edge runs *down* the image.
        let readAt90 = TextQuad(
            topLeft: TextPoint(x: 0.769, y: 0.797),
            topRight: TextPoint(x: 0.767, y: 0.696),
            bottomLeft: TextPoint(x: 0.750, y: 0.797),
            bottomRight: TextPoint(x: 0.748, y: 0.696)
        )
        let back = readAt90.unrotated(by: 90)
        #expect(abs(back.topLeft.x - 0.205) < 0.005)
        #expect(abs(back.topLeft.y - 0.770) < 0.005)
        #expect(abs(back.topRight.x - 0.302) < 0.005)
        #expect(abs(back.bottomLeft.y - 0.751) < 0.005)
    }

    @Test("a half-turned page's outline comes back where the word really is")
    func halfTurn() {
        // Measured at rotation 180.
        let readAt180 = TextQuad(
            topLeft: TextPoint(x: 0.797, y: 0.230),
            topRight: TextPoint(x: 0.696, y: 0.231),
            bottomLeft: TextPoint(x: 0.797, y: 0.249),
            bottomRight: TextPoint(x: 0.696, y: 0.250)
        )
        let back = readAt180.unrotated(by: 180)
        #expect(abs(back.topLeft.x - 0.203) < 0.005)
        #expect(abs(back.topLeft.y - 0.770) < 0.005)
        #expect(abs(back.topRight.x - 0.304) < 0.005)
    }

    @Test("three quarter turns come back too, and 270 is not 90 with a sign changed")
    func threeQuarterTurn() {
        // Measured at rotation 270.
        let readAt270 = TextQuad(
            topLeft: TextPoint(x: 0.229, y: 0.206),
            topRight: TextPoint(x: 0.230, y: 0.304),
            bottomLeft: TextPoint(x: 0.248, y: 0.205),
            bottomRight: TextPoint(x: 0.249, y: 0.303)
        )
        let back = readAt270.unrotated(by: 270)
        #expect(abs(back.topLeft.x - 0.206) < 0.005)
        #expect(abs(back.topLeft.y - 0.771) < 0.005)
        #expect(abs(back.topRight.x - 0.304) < 0.005)
    }

    @Test("a turn moves the points and leaves the labels, so a word never comes back on its side")
    func theReadingEdgeSurvivesATurn() {
        // The control for the corner labels: permuting them as well as the points — the obvious
        // reading — swaps a word's long edge for its short one. Vision labels by the text's own
        // reading direction, measured at all four rotations, so the long edge stays the top one.
        let readAt90 = TextQuad(
            topLeft: TextPoint(x: 0.769, y: 0.797),
            topRight: TextPoint(x: 0.767, y: 0.696),
            bottomLeft: TextPoint(x: 0.750, y: 0.797),
            bottomRight: TextPoint(x: 0.748, y: 0.696)
        )
        let back = readAt90.unrotated(by: 90)
        let reading = hypot(back.topRight.x - back.topLeft.x, back.topRight.y - back.topLeft.y)
        let down = hypot(back.bottomLeft.x - back.topLeft.x, back.bottomLeft.y - back.topLeft.y)
        #expect(reading > 0.09)
        #expect(down < 0.03)
    }

    @Test("an outline with no height is not drawable either")
    func zeroHeight() {
        let flat = TextQuad(
            topLeft: TextPoint(x: 0.2, y: 0.5),
            topRight: TextPoint(x: 0.4, y: 0.5),
            bottomLeft: TextPoint(x: 0.2, y: 0.5),
            bottomRight: TextPoint(x: 0.4, y: 0.5)
        )
        #expect(!flat.isDrawable)
    }
}
