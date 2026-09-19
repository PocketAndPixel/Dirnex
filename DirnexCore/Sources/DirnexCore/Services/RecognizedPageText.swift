import Foundation

/// What text recognition found on one page of a document that carries no text layer — a scan
/// (2026-09-19).
///
/// A PDF page made of a photograph has nothing for `PDFPage.string` to answer and nothing for
/// `PDFPage.selection(for:)` to build, so finding in one means reading the page with Vision and
/// keeping both halves of the answer: the text, which the find matches against exactly as it
/// matches any other preview's, and *where each piece of it sits*, which is what puts a highlight
/// over the right word.
///
/// **The geometry is per word, because that is the finest grain Vision has.** Measured against
/// `VNRecognizedText.boundingBox(for:)` a character at a time: every letter of `applicants`
/// answers the *same* box, the box of the whole word, and asking for a multi-character range
/// answers the union of the words it touches. Interpolating within a line was measured as an
/// alternative and is unusable — up to 65 pt of error on an A4 page, a tenth of its width, which
/// puts a highlight over the wrong words entirely. So a match covering part of a word is drawn
/// over that whole word: Vision's own granularity, and honest about it.
///
/// **A quad rather than a rectangle, because scans are not straight.** Measured over this Mac's
/// scanned fixtures, the worst word on a page is 6.2° off horizontal in a scanned book and 28.6°
/// in a phone photograph of a document; an axis-aligned box around a 28° word covers the lines
/// above and below it.
public struct RecognizedPageText: Sendable, Equatable {
    /// What joins two recognized lines in ``text``. Deliberately its own constant rather than
    /// ``PagedDocumentText/pageSeparator``, which happens to be the same character and answers a
    /// different question — how two *pages* are joined.
    public static let lineSeparator = "\n"

    /// The page's text: the recognized lines, in reading order, joined by a single newline — the
    /// same shape `PDFDocument.string` has for a page that has a text layer, so a document whose
    /// pages come from both sources reads as one text.
    public let text: String
    /// Where each word of `text` sits on the page, ascending by offset and not overlapping.
    public let words: [RecognizedWord]

    public init(text: String, words: [RecognizedWord]) {
        self.text = text
        self.words = words
    }

    /// How long `text` is in the units a find counts and a segment map joins.
    public var length: Int {
        text.utf16.count
    }

    /// Where on the page to draw a match lying at `range` — the quad of every word the range
    /// touches.
    ///
    /// Empty for a range that touches no word, which is a range lying entirely in the whitespace
    /// between them. Ascending, and may be several: a match running across a space is two words,
    /// and one running across a line break is two lines.
    public func quads(overlapping range: Range<Int>) -> [TextQuad] {
        guard !range.isEmpty else { return [] }
        return words.filter { $0.range.lowerBound < range.upperBound && range.lowerBound < $0.range.upperBound }
            .map(\.quad)
    }
}

/// One recognized word: where it lies in its page's text, and where it sits on the page.
public struct RecognizedWord: Sendable, Equatable {
    /// The word's UTF-16 offsets within its page's text.
    public let range: Range<Int>
    /// The word's outline on the page.
    public let quad: TextQuad

    public init(range: Range<Int>, quad: TextQuad) {
        self.range = range
        self.quad = quad
    }
}

/// A four-cornered outline on a page, in the page's own normalized coordinates: `0...1` across and
/// up, with the origin at the **bottom left**, which is both Vision's convention and the PDF
/// coordinate system's.
///
/// Four corners rather than a rectangle because a scanned line is rarely horizontal (measured: up
/// to 28.6° on a real fixture), and because the drawing side takes a quad — a PDF highlight
/// annotation is shaped by `quadrilateralPoints`.
///
/// `Double` rather than `CGFloat` for the reason ``MermaidRect`` gives: a geometry whose
/// assertions are exact numbers should not be measured in a type whose precision is decided
/// elsewhere.
public struct TextQuad: Sendable, Equatable {
    public var topLeft: TextPoint
    public var topRight: TextPoint
    public var bottomLeft: TextPoint
    public var bottomRight: TextPoint

    public init(
        topLeft: TextPoint,
        topRight: TextPoint,
        bottomLeft: TextPoint,
        bottomRight: TextPoint
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    /// The upright box that contains all four corners — what a caller that cannot draw a quad
    /// needs, and what decides where the whole outline lies on the page.
    public var boundingBox: TextBox {
        let xs = [topLeft.x, topRight.x, bottomLeft.x, bottomRight.x]
        let ys = [topLeft.y, topRight.y, bottomLeft.y, bottomRight.y]
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        return TextBox(
            x: minX,
            y: minY,
            width: (xs.max() ?? 0) - minX,
            height: (ys.max() ?? 0) - minY
        )
    }

    /// The same outline in the *unrotated* page's coordinates, for a page displayed turned by
    /// `rotation` degrees clockwise.
    ///
    /// A recognizer reads a page as it is displayed — a quarter-turned page has to be drawn
    /// quarter-turned or its text is sideways — while a PDF's annotations are addressed in the
    /// unrotated box, which `PDFAnnotation` reads its bounds back in whatever the rotation.
    ///
    /// Measured rather than derived, twice over. The point transform is `(1-y, x)` for 90°,
    /// `(1-x, 1-y)` for 180° and `(y, 1-x)` for 270° — the same word on the same page, turned by
    /// hand, read back where it really is. And the corner *labels* move with the points rather
    /// than being permuted, because Vision names them in the **text's own reading frame** rather
    /// than the image's: at all four rotations the labelled `topLeft`→`topRight` edge is the long
    /// one, 0.097–0.101 against 0.019 for `topLeft`→`bottomLeft`. Permuting them as well — the
    /// obvious reading, and what this did first — turns every quarter-turned word's outline on its
    /// side.
    public func unrotated(by rotation: Int) -> TextQuad {
        let turn = ((rotation % 360) + 360) % 360
        guard turn != 0 else { return self }
        let turned = { (point: TextPoint) -> TextPoint in
            switch turn {
            case 90: TextPoint(x: 1 - point.y, y: point.x)
            case 180: TextPoint(x: 1 - point.x, y: 1 - point.y)
            case 270: TextPoint(x: point.y, y: 1 - point.x)
            default: point
            }
        }
        return TextQuad(
            topLeft: turned(topLeft),
            topRight: turned(topRight),
            bottomLeft: turned(bottomLeft),
            bottomRight: turned(bottomRight)
        )
    }

    /// Whether this outline is one Vision really placed on the page.
    ///
    /// Asking `boundingBox(for:)` about a **single space** answers a degenerate box at the page's
    /// top-left corner — `x 0…0, y 1…1` — rather than nothing at all, measured, so a caller that
    /// unions boxes without checking drags the union to a corner of the page: the observed error
    /// was 484 pt, wider than the page it was drawn on. Nothing that has no area is worth drawing
    /// either, so one rule covers both.
    public var isDrawable: Bool {
        let box = boundingBox
        return box.width > 0 && box.height > 0
    }
}

/// A corner of a ``TextQuad``, in its page's normalized coordinates.
public struct TextPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// An upright box in a page's normalized coordinates — what a ``TextQuad`` covers.
public struct TextBox: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
