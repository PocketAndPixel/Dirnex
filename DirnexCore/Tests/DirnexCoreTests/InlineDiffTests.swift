import Foundation
import Testing

@testable import DirnexCore

@Suite("InlineDiff")
struct InlineDiffTests {
    private func marks(
        _ left: String,
        _ right: String,
        options: LineDiffOptions = LineDiffOptions()
    ) -> InlineDifference? {
        InlineDiff.difference(left[...], right[...], options: options)
    }

    @Test("a changed word is marked whole on both sides, and nothing else is")
    func changedWord() {
        #expect(marks("count + 1", "total + 1") == InlineDifference(left: [0..<5], right: [0..<5]))
    }

    @Test("an addition is marked only on the side that has it")
    func addition() {
        #expect(marks("foo(a)", "foo(a, b)") == InlineDifference(left: [], right: [5..<8]))
    }

    @Test("two marked words with only whitespace between them are one stretch")
    func joinedAcrossWhitespace() {
        #expect(marks("x = a b;", "x = c d;") == InlineDifference(left: [4..<7], right: [4..<7]))
    }

    @Test("two marked words with an unchanged word between them stay apart")
    func apartAcrossAWord() {
        #expect(
            marks("a b c", "x b y") == InlineDifference(left: [0..<1, 4..<5], right: [0..<1, 4..<5])
        )
    }

    @Test(
        "offsets are UTF-16 units, so text past an emoji or Cyrillic lands where a text view puts it"
    )
    func utf16Offsets() {
        #expect(marks("😀 a", "😀 b") == InlineDifference(left: [3..<4], right: [3..<4]))
        #expect(
            marks("привет мир", "привет миф") == InlineDifference(left: [7..<10], right: [7..<10])
        )
    }

    @Test("whitespace is marked unless the options overlook it")
    func whitespace() {
        #expect(marks("a  b", "a b") == InlineDifference(left: [1..<3], right: [1..<2]))
        #expect(marks("a  b", "a b", options: LineDiffOptions(whitespace: .ignoreChanges))
            == InlineDifference(left: [], right: []))
        #expect(marks("a b  ", "a b") == InlineDifference(left: [3..<5], right: []))
        #expect(marks("a b  ", "a b", options: LineDiffOptions(whitespace: .ignoreTrailing))
            == InlineDifference(left: [], right: []))
        #expect(marks("ab", "a b", options: LineDiffOptions(whitespace: .ignoreAll))
            == InlineDifference(left: [0..<2], right: [0..<3]))
    }

    @Test("case is marked unless it is ignored")
    func letterCase() {
        #expect(
            marks("Hello world", "hello world") == InlineDifference(left: [0..<5], right: [0..<5])
        )
        #expect(marks("Hello world", "hello world", options: LineDiffOptions(ignoresCase: true))
            == InlineDifference(left: [], right: []))
    }

    @Test("words compare as bytes, so é precomposed and decomposed is a marked change")
    func canonicalEquivalents() {
        #expect(
            marks("caf\u{E9} ok", "cafe\u{301} ok") == InlineDifference(
                left: [0..<4],
                right: [0..<5]
            )
        )
    }

    @Test("a line too long to compare inside is left whole")
    func longLine() {
        let long = String(repeating: "x", count: InlineDiff.maximumLineLength + 1)
        #expect(marks(long, "x") == nil)
        #expect(marks(String(long.dropLast()), "x") != nil)
    }
}
