import Foundation
import Testing

@testable import DirnexCore

/// Pattern search — the third option the find bar offers (2026-09-18).
///
/// What these pin is that a pattern reaches every surface by the same door an ordinary query does:
/// `matches` for a decoded value, `matchesBytes` for one read where it lies, `occurrences` for the
/// marks a cell draws, and `TextFindMatches` for the UTF-16 offsets a text view is scrolled by. The
/// engine is macOS's own (``PatternSearch``), so what is asserted here is *this app's* rules around
/// it — which options mean what, what an unusable pattern does, and that iterating cannot invent a
/// match at the seam between two of them.
@Suite("Pattern search")
struct PatternSearchTests {
    private func matches(_ pattern: String, _ options: FilterQuery.Options = [], in text: String) -> Bool {
        FilterQuery(pattern, options: options.union(.pattern)).matches(text)
    }

    private func found(
        _ pattern: String,
        _ options: FilterQuery.Options = [],
        in text: String
    ) -> [String] {
        let query = FilterQuery(pattern, options: options.union(.pattern))
        guard let matches = TextFindMatches.find(query, in: text) else { return ["cancelled"] }
        let utf16 = Array(text.utf16)
        return matches.ranges.map { String(decoding: utf16[$0], as: UTF16.self) }
    }

    // MARK: - What a pattern is

    @Test("a pattern is read as one rather than looked for literally")
    func patternIsRead() {
        #expect(found("b.ta", in: "beta bota bta") == ["beta", "bota"])
        #expect(found("be(ta|er)", in: "beta beer bear") == ["beta", "beer"])
        #expect(found("[0-9]+", in: "line 42 of 7") == ["42", "7"])
        // The same text without the option is a literal, which is what every other caller still gets.
        #expect(TextFindMatches.find(FilterQuery("b.ta"), in: "beta bota")?.isEmpty == true)
    }

    @Test("the enhanced escapes are the ones people type")
    func enhancedEscapes() {
        #expect(found("\\d+", in: "a1 bb 22") == ["1", "22"])
        #expect(found("\\bbeta\\b", in: "beta betaOnly the beta") == ["beta", "beta"])
        #expect(found("\\w+", in: "a-b c") == ["a", "b", "c"])
        #expect(found("a\\s+b", in: "a  b") == ["a  b"])
        // `\t` and `\n` are literals, which is how a one-line field reaches a line break at all.
        #expect(found("a\\nb", in: "a\nb") == ["a\nb"])
    }

    @Test("^ and $ are line anchors, and a dot does not cross a line")
    func lineAnchors() {
        let text = "alpha\nbeta\ngamma beta\n"
        #expect(found("^beta", in: text) == ["beta"])
        #expect(found("beta$", in: text) == ["beta", "beta"])
        #expect(found("alpha.beta", in: text).isEmpty)
        #expect(found("alpha\\nbeta", in: text) == ["alpha\nbeta"])
    }

    // MARK: - The options beside it

    @Test("Case Sensitive means the same thing for a pattern")
    func caseSensitive() {
        #expect(found("b.ta", in: "Beta beta") == ["Beta", "beta"])
        #expect(found("b.ta", .caseSensitive, in: "Beta beta") == ["beta"])
        #expect(found("[А-Я]+", in: "Панорама") == ["Панорама"])
        #expect(found("[А-Я]+", .caseSensitive, in: "панорама Дом") == ["Д"])
    }

    @Test("Whole Word holds a pattern's own matches to the same rule")
    func wholeWord() {
        #expect(found("bet.", in: "beta betaOnly") == ["beta", "beta"])
        #expect(found("bet.", .wholeWord, in: "beta betaOnly") == ["beta"])
        // The rule is this file's, not the engine's: a curly quote is not a word character, and an
        // accent is (docs/NOTES.md ▸ the two measurements behind `isWordScalar`).
        #expect(found("bet.", .wholeWord, in: "“beta”") == ["beta"])
        // A decomposed accent is a word character, so `caf.` stopping at the `e` is not a whole word.
        #expect(found("caf.", .wholeWord, in: "cafe\u{301}").isEmpty)
        #expect(found("caf.", in: "cafe\u{301}") == ["cafe"])
    }

    @Test("a pattern is matched under UTF-8, not byte by byte")
    func utf8() {
        // A GUI-launched app has no locale, so the process's is `C`; the pattern is compiled under a
        // UTF-8 one of its own, where `.` is a character and a Cyrillic class is a class.
        #expect(found("^.$", in: "б") == ["б"])
        // Case is ignored unless the option says otherwise, so a lowercase class takes `Д` too.
        #expect(found("[а-я]+", in: "Дом панорама") == ["Дом", "панорама"])
        #expect(found("[а-я]+", .caseSensitive, in: "Дом панорама") == ["ом", "панорама"])
        #expect(found("\\w+", in: "Панорама") == ["Панорама"])
        #expect(matches("ПАНОРАМА", in: "панорама"))
        #expect(!matches("ПАНОРАМА", .caseSensitive, in: "панорама"))
    }

    // MARK: - What cannot be run

    @Test("a back reference is refused, because it is the one shape that backtracks")
    func backReference() {
        let query = FilterQuery("(a+)\\1", options: .pattern)
        #expect(query.patternProblem == .backReference)
        #expect(!query.matches("aa"))
        #expect(PatternSearch.containsBackReference("(a)\\1"))
        #expect(PatternSearch.containsBackReference("x\\9y"))
        // A backslash consumed by the escape before it is not a reference, and neither is a digit
        // inside a bracket expression, where the enhanced escapes do not operate at all.
        #expect(!PatternSearch.containsBackReference("a\\\\1"))
        #expect(!PatternSearch.containsBackReference("[\\1]"))
        #expect(!PatternSearch.containsBackReference("[]\\1]"))
        #expect(!PatternSearch.containsBackReference("\\d+"))
        #expect(!PatternSearch.containsBackReference("a\\0b"))
    }

    @Test("a pattern that will not compile finds nothing and says why")
    func invalidPattern() {
        for pattern in ["(unclosed", "[unclosed", "a{2,", "*leading", "trailing\\"] {
            let query = FilterQuery(pattern, options: .pattern)
            #expect(query.patternProblem == .invalid, "\(pattern)")
            #expect(!query.matches("anything at all"), "\(pattern)")
            #expect(
                TextFindMatches.find(query, in: "anything at all")?.isEmpty == true,
                "\(pattern)"
            )
        }
        // A pattern that compiles says nothing, and neither does text that is not a pattern at all.
        #expect(FilterQuery("a+b", options: .pattern).patternProblem == nil)
        #expect(FilterQuery("(unclosed").patternProblem == nil)
        #expect(FilterQuery("", options: .pattern).patternProblem == nil)
        #expect(FilterQuery("", options: .pattern).isEmpty)
    }

    // MARK: - Ranges

    /// The one thing libc gets wrong rather than merely differently: its bracket range compares the
    /// low 8 bits of a character, so `[A-Z]` takes `я` (U+044F) and `[А-Я]` takes a space. The ranges
    /// are expanded into their characters before the pattern is compiled, and these are the answers
    /// that changes — every one of them wrong in the build that hands the range over as it is typed.
    @Test("a range is the characters between its ends, not the ones with a byte in between")
    func ranges() {
        #expect(found("[A-Z]+", .caseSensitive, in: "beta я ё Zed") == ["Z"])
        #expect(found("[А-Я]+", .caseSensitive, in: "панорама Дом") == ["Д"])
        #expect(found("[А-Я]+", .caseSensitive, in: "Дом! 中") == ["Д"])
        #expect(found("[а-я]+", .caseSensitive, in: "Дом 09 Az") == ["ом"])
        #expect(found("[א-ת]+", .caseSensitive, in: "café שלום") == ["שלום"])
        // The ordinary ASCII ranges answer as they always did.
        #expect(found("[a-z]+", .caseSensitive, in: "AB cd") == ["cd"])
        #expect(found("[0-9]+", in: "x42") == ["42"])
        #expect(found("[^0-9 ]+", .caseSensitive, in: "ab 12 cd") == ["ab", "cd"])
    }

    @Test("expanding a range leaves everything else in the bracket alone")
    func bracketRewriting() {
        #expect(PatternSearch.expandingRanges("[a-c]") == "[abc]")
        #expect(PatternSearch.expandingRanges("x[a-c]+y") == "x[abc]+y")
        #expect(PatternSearch.expandingRanges("[^a-c]") == "[^abc]")
        #expect(PatternSearch.expandingRanges("[a-cx]") == "[abcx]")
        #expect(PatternSearch.expandingRanges("[А-В]") == "[АБВ]")
        // Nothing to expand, nothing rewritten — including the classes and the escapes that are not
        // escapes inside a bracket at all.
        #expect(PatternSearch.expandingRanges("[[:upper:]]") == "[[:upper:]]")
        #expect(PatternSearch.expandingRanges("[abc]") == "[abc]")
        #expect(PatternSearch.expandingRanges("\\d+") == "\\d+")
        #expect(PatternSearch.expandingRanges("a-c") == "a-c")
        #expect(PatternSearch.expandingRanges("\\[a-c\\]") == "\\[a-c\\]")
        #expect(PatternSearch.expandingRanges("[unterminated") == "[unterminated")
        // A `-` or a `]` of its own keeps the position that makes it a character.
        #expect(PatternSearch.expandingRanges("[a-c-]") == "[abc-]")
        #expect(PatternSearch.expandingRanges("[]a-c]") == "[]abc]")
        #expect(PatternSearch.expandingRanges("[[:digit:]a-c]") == "[[:digit:]abc]")
        // Wider than the engine's own ceiling for one bracket expression: left as it was typed,
        // since expanding it would fail to compile at all.
        #expect(PatternSearch.expandingRanges("[\u{4E00}-\u{9FA5}]") == "[\u{4E00}-\u{9FA5}]")
        #expect(FilterQuery("[\u{4E00}-\u{9FA5}]", options: .pattern).patternProblem == nil)
    }

    // MARK: - Iterating

    @Test("the seam between two matches is not a word boundary")
    func seam() {
        // Sliced naively this reports two: the rest of a buffer has nothing before it, so `\b` holds
        // at its start. One character of context is what makes it one (measured 2026-09-18).
        #expect(found("\\bbeta", in: "betabeta") == ["beta"])
        #expect(found("\\bbeta", in: "beta beta") == ["beta", "beta"])
        #expect(found("^b", in: "b\nb") == ["b", "b"])
        // And a match that abuts the previous one is still found.
        #expect(found("aa", in: "aaaa") == ["aa", "aa"])
        #expect(found("a{2}", in: "aaaaa") == ["aa", "aa"])
    }

    @Test("a pattern that can match nothing at all is stepped past, never reported")
    func emptyMatches() {
        #expect(found("a*", in: "baab") == ["aa"])
        #expect(found("x*", in: "abc").isEmpty)
        // Stepping past an empty match moves a whole character, so a multi-byte one is never split.
        #expect(found("я*", in: "дядя") == ["я", "я"])
    }

    @Test("matches come back as UTF-16 offsets a text view can address")
    func utf16Offsets() {
        let text = "дядя beta 🐿 beta"
        let query = FilterQuery("beta", options: .pattern)
        let matches = TextFindMatches.find(query, in: text)
        #expect(matches?.ranges.count == 2)
        let utf16 = Array(text.utf16)
        for range in matches?.ranges ?? [] {
            #expect(String(decoding: utf16[range], as: UTF16.self) == "beta")
        }
        // The emoji is two UTF-16 units, and the offsets count it as two.
        #expect(matches?.ranges.last?.lowerBound == 13)
    }

    @Test("the search stops at its limit and says it was not complete")
    func limit() {
        let text = String(repeating: "ab ", count: 500)
        let query = FilterQuery("a.", options: .pattern)
        let capped = TextFindMatches.find(query, in: text, limit: 10)
        #expect(capped?.count == 10)
        #expect(capped?.isComplete == false)
        #expect(TextFindMatches.find(query, in: text)?.count == 500)
        #expect(TextFindMatches.find(query, in: text)?.isComplete == true)
    }

    @Test("a search that is no longer wanted stops")
    func cancellation() {
        let text = String(repeating: "beta ", count: 10_000)
        let query = FilterQuery("b.ta", options: .pattern)
        #expect(TextFindMatches.find(query, in: text) { true } == nil)
        #expect(TextFindMatches.find(query, in: text) { false }?.count == 10_000)
    }

    // MARK: - The other doors into the same rule

    @Test("a value read where it lies answers the same as one decoded first")
    func bytesAndText() {
        let query = FilterQuery("b.ta", options: .pattern)
        let bytes = Array("alpha,beta,gamma".utf8)
        #expect(query.matchesBytes(bytes, from: 6, to: 10))
        #expect(!query.matchesBytes(bytes, from: 0, to: 5))
        #expect(query.matches("beta"))
        // The bounds are the value's, which is what makes an anchor mean the value's own edges.
        let anchored = FilterQuery("^beta$", options: .pattern)
        #expect(anchored.matchesBytes(bytes, from: 6, to: 10))
        #expect(!anchored.matchesBytes(bytes, from: 0, to: 16))
        // Bounds that cross — an empty quoted cell is `start + 1 ..< end - 1` — are an answer, not a trap.
        #expect(!query.matchesBytes(bytes, from: 5, to: 4))
    }

    @Test("the marks a cell draws are the pattern's own matches")
    func occurrences() {
        let query = FilterQuery("[0-9]+", options: .pattern)
        let text = "order 42, line 7"
        let marks = query.occurrences(in: text).map { String(text[$0]) }
        #expect(marks == ["42", "7"])
        #expect(FilterQuery("(unclosed", options: .pattern).occurrences(in: text).isEmpty)
        // Non-ASCII text, where an offset that was not a character boundary would be a wrong mark.
        #expect(FilterQuery("[а-я]+", options: .pattern).occurrences(in: "Дом и дым")
            .map { String("Дом и дым"[$0]) } == ["Дом", "и", "дым"])
    }

    @Test("a table's rows are filtered by the pattern, in place")
    func tableRows() throws {
        let csv = "name,size\nalpha.txt,10\nbeta.log,20\ngamma.txt,30\n"
        let table = try #require(DelimitedTable.parse(csv))
        let rows = table.rowsMatching("\\.txt$", options: .pattern)
        #expect(rows == [true, false, true])
        #expect(table.rowsMatching("^[ab]", options: .pattern) == [true, true, false])
        #expect(table.rowsMatching("(unclosed", options: .pattern) == [false, false, false])
    }
}
