import Foundation
import Testing

@testable import DirnexCore

/// Case Sensitive and Whole Word, the two the find bar offers (2026-09-18).
///
/// One type decides what "contains" means for every surface — the table's in-place byte scan, the
/// three trees, and the text preview's UTF-16 scan — so what these pin is that all of them answer the
/// same question, on both of `FilterQuery`'s branches: an ASCII query compared a byte at a time, and
/// anything else compared as characters.
///
/// The default is the behaviour that shipped before the options existed, which is asserted rather than
/// assumed: every other suite in this package searches without options and must be unaffected.
@Suite("Filter query options")
struct FilterQueryOptionsTests {
    private func matches(_ query: String, _ options: FilterQuery.Options, in text: String) -> Bool {
        FilterQuery(query, options: options).matches(text)
    }

    private func find(_ query: String, _ options: FilterQuery.Options, in text: String) -> Int {
        TextFindMatches.find(FilterQuery(query, options: options), in: text)?.count ?? -1
    }

    // MARK: - Case

    @Test("without the option case is ignored, with it the text must match exactly")
    func caseSensitivity() {
        let text = "alpha Beta\nbeta gamma\nBETA delta\n"
        #expect(find("beta", [], in: text) == 3)
        #expect(find("beta", .caseSensitive, in: text) == 1)
        #expect(find("BETA", .caseSensitive, in: text) == 1)
        #expect(find("Beta", .caseSensitive, in: text) == 1)
        #expect(matches("Beta", .caseSensitive, in: text))
        #expect(!matches("bEtA", .caseSensitive, in: text))
    }

    /// The other branch: a non-ASCII query is compared as characters, and takes the same rule.
    @Test("case sensitivity holds for a non-ASCII query too")
    func caseSensitivityNonASCII() {
        let text = "Бета бета БЕТА"
        #expect(find("бета", [], in: text) == 3)
        #expect(find("бета", .caseSensitive, in: text) == 1)
        #expect(find("Бета", .caseSensitive, in: text) == 1)
        #expect(matches("БЕТА", .caseSensitive, in: text))
    }

    /// Accents still count, with the option and without it — the rule the filters have always had,
    /// and the reason `PDFDocument.findString` was turned down.
    @Test("accents count under either case rule")
    func accentsStillCount() {
        #expect(!matches("cafe", [], in: "café"))
        #expect(!matches("cafe", .caseSensitive, in: "café"))
        #expect(matches("café", [], in: "CAFÉ"))
        #expect(!matches("café", .caseSensitive, in: "CAFÉ"))
    }

    // MARK: - Whole word

    @Test("a whole-word search skips a match inside a longer word")
    func wholeWord() {
        let text = "beta betaOnly prebeta 'beta' beta_channel"
        #expect(find("beta", [], in: text) == 5)
        // The standalone one and the quoted one; `betaOnly`, `prebeta` and `beta_channel` are not.
        #expect(find("beta", .wholeWord, in: text) == 2)
        #expect(matches("beta", .wholeWord, in: text))
        #expect(!matches("beta", .wholeWord, in: "betaOnly prebeta beta_channel"))
    }

    /// `_` is a word character because this app previews source code more than anything else, and it
    /// is what every language means by one identifier.
    @Test("an underscore joins a word and a hyphen does not")
    func underscoreAndHyphen() {
        #expect(!matches("beta", .wholeWord, in: "_beta"))
        #expect(!matches("beta", .wholeWord, in: "beta_"))
        #expect(matches("beta", .wholeWord, in: "-beta-"))
        #expect(matches("beta", .wholeWord, in: "beta-channel"))
    }

    @Test("a digit joins a word")
    func digits() {
        #expect(!matches("beta", .wholeWord, in: "beta2"))
        #expect(!matches("beta", .wholeWord, in: "2beta"))
        #expect(matches("beta", .wholeWord, in: "2 beta 3"))
    }

    /// The case a byte-level boundary rule gets wrong, and gets wrong *silently*: non-ASCII
    /// punctuation is extremely common in prose, and reading "any non-ASCII byte is part of a word"
    /// would make a whole-word search miss every quoted word in a typeset document.
    @Test("non-ASCII punctuation is a boundary and a non-ASCII letter is not")
    func nonASCIIBoundaries() {
        #expect(matches("beta", .wholeWord, in: "\u{201C}beta\u{201D}"), "curly quotes")
        #expect(matches("beta", .wholeWord, in: "\u{2014}beta\u{2014}"), "em dashes")
        #expect(matches("beta", .wholeWord, in: "beta\u{2026}"), "an ellipsis")
        #expect(matches("beta", .wholeWord, in: "\u{00A0}beta\u{00A0}"), "a no-break space")
        #expect(!matches("beta", .wholeWord, in: "\u{03B2}beta"), "a Greek letter is part of a word")
        #expect(!matches("beta", .wholeWord, in: "beta\u{4E2D}"), "and so is a CJK character")
    }

    /// A combining mark is alphabetic, so a decomposed `café` is one word — which is the answer the
    /// accent-counting rule beside it already gives.
    @Test("a combining mark joins a word")
    func combiningMark() {
        let decomposed = "cafe\u{0301}"
        #expect(!matches("cafe", .wholeWord, in: decomposed))
        #expect(matches("cafe", .wholeWord, in: "cafe"))
    }

    /// Why the predicate names the mark categories instead of resting on `isAlphabetic`, which reads
    /// like it would be enough: probed 2026-09-18, the property is **false** for U+0301 and **true**
    /// for U+05B4, two scalars of the same general category. Pinned so that simplifying the predicate
    /// back to the property goes red rather than quietly changing what a word is.
    @Test("isAlphabetic alone does not answer for combining marks")
    func alphabeticIsNotEnoughForMarks() throws {
        let acute = try #require(Unicode.Scalar(UInt32(0x0301)))
        let hiriq = try #require(Unicode.Scalar(UInt32(0x05B4)))
        #expect(!acute.properties.isAlphabetic, "the property that looked sufficient")
        #expect(hiriq.properties.isAlphabetic, "and is inconsistent across one category")
        #expect(FilterQuery.isWordScalar(acute))
        #expect(FilterQuery.isWordScalar(hiriq))
    }

    @Test("whole word holds for a non-ASCII query too")
    func wholeWordNonASCII() {
        #expect(matches("бета", .wholeWord, in: "\u{201C}бета\u{201D}"))
        #expect(!matches("бета", .wholeWord, in: "бетаканал"))
        #expect(find("бета", .wholeWord, in: "бета бетаканал бета") == 2)
    }

    @Test("the two options combine")
    func combined() {
        let text = "beta Beta betaOnly BetaOnly"
        #expect(find("Beta", [.caseSensitive, .wholeWord], in: text) == 1)
        #expect(find("beta", [.caseSensitive, .wholeWord], in: text) == 1)
        #expect(find("beta", .wholeWord, in: text) == 2)
        #expect(find("Beta", .caseSensitive, in: text) == 2)
    }

    // MARK: - The edges of a value

    /// A value's own bounds are boundaries, which is what makes the rule right inside a CSV cell: the
    /// comma and the quotes around a value are not part of it, so a cell holding exactly the query is
    /// a whole word rather than something wedged between punctuation.
    @Test("the bounds handed over are boundaries")
    func boundsAreBoundaries() {
        let bytes = Array("xxbetaxx".utf8)
        let query = FilterQuery("beta", options: .wholeWord)
        #expect(!query.matchesBytes(bytes, from: 0, to: bytes.count))
        #expect(query.matchesBytes(bytes, from: 2, to: 6), "bounded to the value, it stands alone")
    }

    @Test("marks follow the same rule as the match")
    func occurrencesFollowTheOptions() {
        let text = "beta betaOnly Beta"
        #expect(FilterQuery("beta").occurrences(in: text).count == 3)
        #expect(FilterQuery("beta", options: .wholeWord).occurrences(in: text).count == 2)
        #expect(FilterQuery("beta", options: .caseSensitive).occurrences(in: text).count == 2)
        #expect(
            FilterQuery("beta", options: [.caseSensitive, .wholeWord]).occurrences(in: text).count == 1
        )
    }

    // MARK: - The default

    /// The property every other suite in this package rests on: asking for nothing is what shipped.
    @Test("no options is the behaviour that shipped before them")
    func defaultIsUnchanged() {
        let text = "alpha Beta betaOnly 'beta' БЕТА café"
        for query in ["beta", "Beta", "БЕТА", "café", "a"] {
            #expect(
                FilterQuery(query).matches(text) == FilterQuery(query, options: []).matches(text)
            )
            #expect(FilterQuery(query).needle == query.lowercased())
            #expect(FilterQuery(query).options.isEmpty)
        }
        #expect(find("beta", [], in: text) == 3)
    }
}
