import Foundation

/// A document's text gathered a page at a time, where some of those pages have to be *read* before
/// their text exists (2026-09-19).
///
/// A PDF's pages carry their own text and a find searches the lot as one string. A **scanned** page
/// carries none, and the only way to get it is to recognize the page — ~0.2–0.5 s of Vision per
/// page, measured, and 40–65 s for a 142-page book. Nobody waits a minute at a find bar with
/// nothing on screen, so the pages arrive one at a time and the search is re-run as they do.
///
/// **What makes that affordable is that the text only ever grows at its end.** A page's offsets are
/// fixed the moment every page before it is known, so a match found in an early page keeps its
/// offsets, its highlight and its place in the count while later pages are still being read — no
/// renumbering, and nothing on screen moving under the reader. The price is the strict order: a
/// page whose predecessors are not known yet waits, even when its own text was there all along.
/// That costs a mixed document a moment and buys every surface above it the right to assume that
/// offsets mean one thing.
///
/// Which pages need reading is this type's own rule rather than the caller's: a page whose text
/// layer is **empty or nothing but whitespace**. Measured against the scanned books on this Mac,
/// that rule splits them exactly — their pages are either empty, whitespace-only, or carry a full
/// page of text, with nothing in between for a heuristic to get wrong.
public struct PagedDocumentText: Sendable, Equatable {
    /// Where one page's text came from — which is also how a match on it is drawn: a page with a
    /// text layer has a `PDFSelection` behind every offset, and a recognized one has only the
    /// outlines Vision reported.
    public enum PageText: Sendable, Equatable {
        /// The page's own text layer, verbatim. Verbatim because its offsets are spent on
        /// `PDFPage.selection(for:)`, which counts them in exactly this string.
        case layer(String)
        /// What recognizing the page found.
        case recognized(RecognizedPageText)

        public var text: String {
            switch self {
            case let .layer(text): text
            case let .recognized(page): page.text
            }
        }

        public var length: Int {
            switch self {
            case let .layer(text): text.utf16.count
            case let .recognized(page): page.length
            }
        }
    }

    /// Where a match lies and what can draw it there.
    public enum MatchPlacement: Sendable, Equatable {
        /// On a page with a text layer, at these offsets into that page's own text.
        case layer(page: Int, range: Range<Int>)
        /// On a recognized page, under these outlines.
        case recognized(page: Int, quads: [TextQuad])
    }

    /// The separator between two pages — one newline, which is exactly what `PDFDocument.string`
    /// joins its pages with (measured on documents of 1, 78 and 231 pages).
    public static let pageSeparator = "\n"

    /// How many pages the document has.
    public let pageCount: Int
    /// How many pages had no text of their own and have to be read. Fixed when the document is
    /// opened, so progress counts against a total that does not move.
    public let unreadPageCount: Int

    /// The text of every page known so far, joined — what a find searches.
    public private(set) var text = ""
    /// How many pages from the front are known, and so how much of `text` there is.
    public private(set) var readyCount = 0
    /// How many of the pages that needed reading have been read.
    public private(set) var readCount = 0

    private var pages: [PageText?]
    private var lengths: [Int] = []

    /// A document whose pages carry `layerText` — `nil` for a page with no text layer at all.
    ///
    /// Every page that carries text is known immediately; the rest are the ones to read.
    public init(layerText: [String?]) {
        pageCount = layerText.count
        pages = Array(repeating: nil, count: layerText.count)
        var unread = 0
        for (index, text) in layerText.enumerated() {
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages[index] = .layer(text)
            } else {
                unread += 1
            }
        }
        unreadPageCount = unread
        advanceReady()
    }

    /// Every page that still has to be read, in the order to read them — page order, because that
    /// is the order the text can be appended in.
    public var unreadPages: [Int] {
        pages.indices.filter { pages[$0] == nil }
    }

    /// Whether every page's text is known, so a search over `text` is a search over the document.
    public var isComplete: Bool {
        readyCount == pageCount
    }

    /// Whether anything has to be read before a find can answer for the whole document.
    public var needsReading: Bool {
        unreadPageCount > 0
    }

    /// How `text` is cut back into the pages it was joined from.
    public var segments: TextSegmentMap {
        TextSegmentMap(lengths: lengths, separator: Self.pageSeparator.utf16.count)
    }

    /// Take what reading page `index` found. Ignored for a page that is already known, so a
    /// duplicate answer cannot renumber a text that has already been searched.
    public mutating func set(_ page: PageText, at index: Int) {
        guard pages.indices.contains(index), pages[index] == nil else { return }
        pages[index] = page
        readCount += 1
        advanceReady()
    }

    /// The offset `text` would start a page at, for a page that is already known. Where a search
    /// with no current match begins: the top of the page in front of the reader.
    public func offset(ofPage index: Int) -> Int? {
        guard index >= 0, index < readyCount else { return nil }
        return lengths.prefix(index).reduce(0) { $0 + $1 + Self.pageSeparator.utf16.count }
    }

    /// Where to draw a match lying at `range` in `text` — a piece per page it touches, each
    /// carrying what that page can be drawn with.
    ///
    /// A page with a text layer hands back offsets into its own string, which is what
    /// `PDFPage.selection(for:)` counts in. A recognized page hands back outlines, because there is
    /// no selection to be had: `PDFPage.selection(for:)` on a page with no text does not fail, it
    /// answers a selection whose bounds are `(inf, inf, 0, 0)` and whose string is `nil` — measured
    /// — which draws nothing and reports nothing.
    public func placement(of range: Range<Int>) -> [MatchPlacement] {
        segments.split(range).compactMap { piece in
            switch pages[piece.index] {
            case .layer:
                .layer(page: piece.index, range: piece.range)
            case let .recognized(recognized):
                .recognized(
                    page: piece.index,
                    quads: recognized.quads(overlapping: piece.range).filter(\.isDrawable)
                )
            case nil:
                nil
            }
        }
    }

    // MARK: - Private

    /// Append every page that has become contiguous with the ones already in `text`.
    private mutating func advanceReady() {
        while readyCount < pages.count, let page = pages[readyCount] {
            if readyCount > 0 { text += Self.pageSeparator }
            text += page.text
            lengths.append(page.length)
            readyCount += 1
        }
    }
}
