import Foundation
import Testing

@testable import DirnexCore

/// Where a filter's query lies in a value — what Quick View's table and tree mark — found by the rule
/// the filters match by.
@Suite("Filter query")
struct FilterQueryTests {
    /// Each occurrence as the characters it starts and ends at.
    private func offsets(_ query: String, in text: String) -> [Range<Int>] {
        FilterQuery(query).occurrences(in: text).map {
            text.distance(from: text.startIndex, to: $0.lowerBound)
                ..< text.distance(from: text.startIndex, to: $0.upperBound)
        }
    }

    /// Each occurrence as the UTF-8 bytes it covers.
    private func byteOffsets(_ query: String, in text: String) -> [Range<Int>] {
        FilterQuery(query).occurrences(in: text).map {
            text.utf8.distance(from: text.startIndex, to: $0.lowerBound)
                ..< text.utf8.distance(from: text.startIndex, to: $0.upperBound)
        }
    }

    @Test("an ASCII query marks every occurrence, ignoring case, left to right without overlapping")
    func ascii() {
        #expect(offsets("inv", in: "Invoice-to-INVOICE") == [0..<3, 11..<14])
        #expect(offsets("aa", in: "aaaaa") == [0..<2, 2..<4])
        #expect(offsets("xyz", in: "Invoice").isEmpty)
    }

    @Test("any other query marks by characters, in the text lowercased")
    func characters() {
        let upper = "\u{41F}\u{410}\u{41D}\u{41E}\u{420}\u{410}\u{41C}\u{410}"
        let lower = "\u{43F}\u{430}\u{43D}\u{43E}\u{440}\u{430}\u{43C}\u{430}"
        #expect(offsets("\u{41D}\u{41E}\u{420}", in: upper + " " + lower) == [2..<5, 11..<14])
        #expect(offsets("\u{43D}\u{43E}\u{440}", in: "\u{438}\u{43D}\u{432}").isEmpty)
    }

    /// `İ` lowercases to `i` and a combining dot: one character still, two scalars and two UTF-16
    /// units, so a mark found in the lowercased text has to come back by character, not by offset.
    @Test("a match whose lowercasing lengthens the text comes back over the characters it covers")
    func lengtheningLowercase() {
        let text = "\u{130}zmir \u{130}stanbul"
        #expect(offsets("i\u{307}s", in: text) == [6..<8])
        #expect(offsets("\u{130}STAN", in: text) == [6..<11])
    }

    @Test("an empty query matches everything and marks nothing")
    func emptyQuery() {
        #expect(FilterQuery("").matches("anything"))
        #expect(FilterQuery("").occurrences(in: "anything").isEmpty)
    }

    /// Where the two ways of comparing part: an ASCII query folds `A`–`Z` a byte at a time, so `e` is
    /// found in a decomposed `é` and `k` is not found in the Kelvin sign, while any other query compares
    /// whole characters, so half a flag is not in a flag.
    @Test("the marks follow the same branch as the match, where the two branches part")
    func marksFollowTheMatch() {
        #expect(FilterQuery("e").matches("Cafe\u{301}"))
        #expect(byteOffsets("e", in: "Cafe\u{301}") == [3..<4])
        #expect(FilterQuery("\u{E9}").matches("Cafe\u{301}"))
        #expect(offsets("\u{E9}", in: "Cafe\u{301}") == [3..<4])
        #expect(!FilterQuery("k").matches("\u{212A}elvin"))
        #expect(offsets("k", in: "\u{212A}elvin").isEmpty)
        #expect(!FilterQuery("\u{1F1FA}").matches("\u{1F1FA}\u{1F1F8}"))
        #expect(offsets("\u{1F1FA}", in: "\u{1F1FA}\u{1F1F8}").isEmpty)
    }

    /// The filters read a file's bytes in place wherever they can, which is code of their own, so this
    /// holds the marks to what they keep rather than to `matches`.
    @Test("a value either filter keeps is exactly a value with something to mark")
    func agreesWithTheFilters() throws {
        let texts = [
            "Invoice", "Cafe\u{301}", "\u{212A}elvin", "stra\u{DF}e", "\u{130}stanbul",
            "\u{41F}\u{410}\u{41D}\u{41E}\u{420}\u{410}\u{41C}\u{410}", "\u{1F1FA}\u{1F1F8}",
            "plain"
        ]
        let queries = [
            "inv", "ELV", "e", "\u{E9}", "k", "ss", "i\u{307}s", "\u{43D}\u{43E}\u{440}",
            "\u{1F1FA}", "ain"
        ]
        let csv = "id,value\n" + texts.enumerated().map { "\($0.offset),\($0.element)" }
            .joined(separator: "\n") + "\n"
        let table = try #require(DelimitedTable.parse(csv))
        #expect(table.rowCount == texts.count)
        let document = try #require(JSONDocument.parse("[" + texts.map { "\"\($0)\"" }
                .joined(separator: ",") + "]"))
        let elements = try document.children(of: #require(document.roots.first))
        for query in queries {
            let marked = texts.map { !FilterQuery(query).occurrences(in: $0).isEmpty }
            #expect(table.rowsMatching(query, inColumn: 1) == marked, "\(query)")
            let filter = try #require(document.filter(matching: query, in: .values))
            #expect(elements.map(filter.isMatch) == marked, "\(query)")
        }
    }
}
