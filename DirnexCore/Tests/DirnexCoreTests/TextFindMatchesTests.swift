import Foundation
import Testing

@testable import DirnexCore

/// Finding a query in a text preview (2026-09-17): the matches as the UTF-16 offsets a text view
/// addresses, found by the rule the table and tree filters match by, and the arithmetic of stepping
/// through them and of which ones a view has on screen.
@Suite("Text find matches")
struct TextFindMatchesTests {
    private func find(_ query: String, in text: String, limit: Int = TextFindMatches.limit) -> TextFindMatches? {
        TextFindMatches.find(FilterQuery(query), in: text, limit: limit)
    }

    private func ranges(_ query: String, in text: String) -> [Range<Int>] {
        find(query, in: text)?.ranges ?? []
    }

    /// Foundation's own answer for where a literal lies, which counts UTF-16 units independently of
    /// the scan under test.
    private func nsRange(of literal: String, in text: String, from start: Int = 0) -> Range<Int> {
        let ns = text as NSString
        let found = ns.range(of: literal, range: NSRange(location: start, length: ns.length - start))
        return found.location..<found.location + found.length
    }

    @Test("an ASCII query finds every occurrence, ignoring case, left to right without overlapping")
    func ascii() {
        #expect(ranges("inv", in: "Invoice-to-INVOICE") == [0..<3, 11..<14])
        #expect(ranges("aa", in: "aaaaa") == [0..<2, 2..<4])
        #expect(ranges("xyz", in: "Invoice").isEmpty)
        #expect(find("inv", in: "Invoice")?.isComplete == true)
    }

    /// The scan walks UTF-8 and counts UTF-16: a two- and three-byte scalar is one unit, a four-byte
    /// one (an emoji) is two, and a continuation byte is none.
    @Test("an ASCII match after multi-byte text lands at its UTF-16 offset")
    func asciiOffsetsCountUTF16() {
        let text = "\u{E9}\u{20AC}\u{1F600} inv \u{1F1FA}\u{1F1F8}INV"
        #expect(
            ranges("inv", in: text) == [nsRange(of: "inv", in: text), nsRange(of: "INV", in: text)]
        )
        #expect(ranges("inv", in: text) == [5..<8, 13..<16])
        // A decomposed é: its `e` is a byte of its own, as in the filters.
        #expect(ranges("e", in: "Cafe\u{301} cafe") == [3..<4, 9..<10])
    }

    @Test("any other query finds by characters, at their UTF-16 offsets")
    func characters() {
        let upper = "\u{41F}\u{410}\u{41D}\u{41E}\u{420}\u{410}\u{41C}\u{410}"
        #expect(ranges("\u{43D}\u{43E}\u{440}", in: "\u{1F600} " + upper) == [5..<8])
        // CRLF is one character and two UTF-16 units.
        let lines = "a\r\n\u{431}\u{435}\u{433}\r\n\u{411}\u{415}\u{413}"
        #expect(ranges("\u{431}\u{435}\u{433}", in: lines) == [3..<6, 8..<11])
        #expect(ranges("\u{43D}\u{43E}\u{440}", in: "\u{438}\u{43D}\u{432}").isEmpty)
    }

    @Test("a lowercasing that lengthens a scalar still maps back over the characters matched")
    func lengtheningLowercase() {
        let text = "\u{130}zmir \u{130}stanbul"
        #expect(ranges("\u{130}STAN", in: text) == [6..<11])
    }

    /// Both branches are code of their own, so hold them to the marks the filters draw, over texts
    /// where the byte and character readings part company.
    @Test("the matches are the filters' marks, in UTF-16")
    func agreesWithTheFilterMarks() {
        let texts = [
            "Invoice INVOICE invoice", "Cafe\u{301} caf\u{E9} CAFE", "\u{212A}elvin kelvin",
            "stra\u{DF}e STRASSE", "\u{130}stanbul istanbul", "\u{1F1FA}\u{1F1F8} flag \u{1F1FA}",
            "\u{41F}\u{410}\u{41D}\u{41E}\u{420}\u{410}\u{41C}\u{410} \u{43F}\u{430}\u{43D}",
            "a\r\nb\r\nab",
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} family"
        ]
        let queries = [
            "inv",
            "e",
            "caf\u{E9}",
            "k",
            "\u{DF}",
            "i",
            "\u{1F1FA}",
            "\u{43D}",
            "ab",
            "b",
            "fam"
        ]
        for text in texts {
            for query in queries {
                let marks = FilterQuery(query).occurrences(in: text).map { range -> Range<Int> in
                    let ns = NSRange(range, in: text)
                    return ns.location..<ns.location + ns.length
                }
                #expect(ranges(query, in: text) == marks, "\(query) in \(text)")
            }
        }
    }

    @Test("a search stops at its limit and says there is more, and only when there is")
    func limit() {
        let stopped = find("a", in: "aaaaa", limit: 3)
        #expect(stopped?.ranges == [0..<1, 1..<2, 2..<3])
        #expect(stopped?.isComplete == false)
        #expect(find("a", in: "aaaaa", limit: 5)?.isComplete == true)

        let cyrillic = find("\u{436}", in: "\u{416}\u{436}\u{436}\u{436}", limit: 2)
        #expect(cyrillic?.ranges == [0..<1, 1..<2])
        #expect(cyrillic?.isComplete == false)
        #expect(find("\u{436}", in: "\u{416}\u{436}", limit: 2)?.isComplete == true)
    }

    @Test("a cancelled search answers nothing")
    func cancellation() {
        let long = String(repeating: "abc ", count: 40000)
        #expect(TextFindMatches.find(FilterQuery("abc"), in: long) { true } == nil)
        #expect(TextFindMatches.find(FilterQuery("\u{436}"), in: "\u{436}\u{436}") { true } == nil)
        #expect(TextFindMatches.find(FilterQuery("abc"), in: long) { false }?.count == 40000)
    }

    @Test("an empty query finds nothing")
    func emptyQuery() {
        let found = find("", in: "anything")
        #expect(found?.isEmpty == true)
        #expect(found?.isComplete == true)
    }

    @Test(
        "a search begins at the first match from where the reader is, wrapping to the first of all"
    )
    func startingIndex() {
        let matches = TextFindMatches(ranges: [2..<4, 10..<12, 20..<22], isComplete: true)
        #expect(matches.index(atOrAfter: 0) == 0)
        #expect(matches.index(atOrAfter: 3) == 1)
        #expect(matches.index(atOrAfter: 10) == 1)
        #expect(matches.index(atOrAfter: 21) == 0)
        #expect(TextFindMatches(ranges: [], isComplete: true).index(atOrAfter: 0) == nil)
    }

    @Test("stepping wraps past either end")
    func stepping() {
        let matches = TextFindMatches(ranges: [2..<4, 10..<12, 20..<22], isComplete: true)
        #expect(matches.index(0, steppedBy: 1) == 1)
        #expect(matches.index(2, steppedBy: 1) == 0)
        #expect(matches.index(0, steppedBy: -1) == 2)
        #expect(matches.index(1, steppedBy: 4) == 2)
        #expect(matches.index(1, steppedBy: -4) == 0)
    }

    @Test("the matches a window overlaps, a match cut by either edge included")
    func overlapping() {
        let matches = TextFindMatches(ranges: [2..<4, 10..<12, 20..<22], isComplete: true)
        #expect(matches.indices(overlapping: 3..<11) == 0..<2)
        #expect(matches.indices(overlapping: 4..<10).isEmpty)
        #expect(matches.indices(overlapping: 0..<100) == 0..<3)
        #expect(matches.indices(overlapping: 21..<21).isEmpty)
        #expect(matches.indices(overlapping: 30..<40).isEmpty)
    }

    @Test("what one run of indices holds that another does not, in at most two runs")
    func difference() {
        #expect(TextFindMatches.indices(0..<5, notIn: 2..<3) == [0..<2, 3..<5])
        #expect(TextFindMatches.indices(0..<5, notIn: 0..<5).isEmpty)
        #expect(TextFindMatches.indices(3..<8, notIn: 0..<5) == [5..<8])
        #expect(TextFindMatches.indices(0..<3, notIn: 5..<9) == [0..<3])
        #expect(TextFindMatches.indices(5..<9, notIn: 0..<3) == [5..<9])
        #expect(TextFindMatches.indices(2..<4, notIn: 7..<7) == [2..<4])
        #expect(TextFindMatches.indices(4..<4, notIn: 0..<2).isEmpty)
    }
}
