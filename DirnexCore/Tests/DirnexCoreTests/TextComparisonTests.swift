import Foundation
import Testing

@testable import DirnexCore

@Suite("TextComparison")
struct TextComparisonTests {
    private func unshown(
        _ left: ComparedText,
        _ right: ComparedText,
        options: LineDiffOptions = LineDiffOptions()
    ) -> [TextComparison.UnshownDifference] {
        TextComparison(left, right, options: options).unshownDifferences
    }

    @Test("files that say the same thing in different encodings name both, with nothing to show")
    func encodings() {
        let left = ComparedText(text: "a\nb\n", encoding: .utf8)
        let right = ComparedText(
            text: "a\nb\n",
            encoding: .utf16LittleEndian,
            hasByteOrderMark: true
        )
        let result = TextComparison(left, right)
        #expect(result.diff.isIdentical)
        #expect(result.unshownDifferences == [
            .encoding(left: .utf8, right: .utf16LittleEndian),
            .byteOrderMark(left: false, right: true)
        ])
    }

    @Test("a byte-order mark on one side only is named, even in the same encoding")
    func byteOrderMark() {
        let left = ComparedText(text: "a\n", encoding: .utf8, hasByteOrderMark: true)
        let right = ComparedText(text: "a\n", encoding: .utf8)
        #expect(unshown(left, right) == [.byteOrderMark(left: true, right: false)])
    }

    @Test("lines matched only because an option overlooked something name what it overlooked")
    func overlooked() {
        let whitespace = LineDiffOptions(whitespace: .ignoreAll)
        #expect(
            unshown(ComparedText(text: "a b\n"), ComparedText(text: "ab\n"), options: whitespace)
                == [.whitespace]
        )
        let letterCase = LineDiffOptions(ignoresCase: true)
        #expect(
            unshown(
                ComparedText(text: "Hello\n"),
                ComparedText(text: "hello\n"),
                options: letterCase
            )
                == [.letterCase]
        )
        let both = LineDiffOptions(whitespace: .ignoreAll, ignoresCase: true)
        #expect(
            unshown(
                ComparedText(text: "Hello you\n"),
                ComparedText(text: "helloyou\n"),
                options: both
            )
                == [.whitespace, .letterCase]
        )
        let endings = LineDiffOptions(ignoresLineEndings: true)
        #expect(unshown(ComparedText(text: "a\r\n"), ComparedText(text: "a"), options: endings)
            == [.lineEndings])
    }

    @Test("an overlooked difference is named even when other lines differ visibly")
    func overlookedBesideAVisibleChange() {
        let result = TextComparison(
            ComparedText(text: "a b\nx\n"),
            ComparedText(text: "ab\ny\n"),
            options: LineDiffOptions(whitespace: .ignoreAll)
        )
        #expect(!result.diff.isIdentical)
        #expect(result.unshownDifferences == [.whitespace])
    }

    @Test("nothing is named when the shown differences are all there is")
    func nothingUnshown() {
        #expect(unshown(ComparedText(text: "a\n"), ComparedText(text: "b\n")).isEmpty)
        // Under the default options a CRLF line is a changed row, which shows it, so it is not
        // named again here.
        #expect(unshown(ComparedText(text: "a\r\n"), ComparedText(text: "a\n")).isEmpty)
    }
}

@Suite("ComparedText")
struct ComparedTextTests {
    @Test(
        "UTF-8 decodes as UTF-8 with no mark, and a UTF-8 mark is reported and left out of the text"
    )
    func utf8() throws {
        let plain = try ComparedText.decode(Data("héllo\n".utf8))
        #expect(plain.text == "héllo\n")
        #expect(plain.encoding == .utf8)
        #expect(!plain.hasByteOrderMark)
        let marked = try ComparedText.decode(Data([0xEF, 0xBB, 0xBF] + Array("héllo\n".utf8)))
        #expect(marked.text == "héllo\n")
        #expect(marked.encoding == .utf8)
        #expect(marked.hasByteOrderMark)
    }

    @Test("UTF-16 with a mark decodes, and says which byte order it was")
    func utf16() throws {
        let data = try #require("hi\n".data(using: .utf16LittleEndian))
        let decoded = try ComparedText.decode(Data([0xFF, 0xFE]) + data)
        #expect(decoded.text == "hi\n")
        #expect(decoded.encoding == .utf16LittleEndian)
        #expect(decoded.hasByteOrderMark)
    }

    @Test("a legacy 8-bit file decodes by detection and reports the encoding it settled on")
    func legacyEncoding() throws {
        let data = try #require("Привет, мир\n".data(using: .windowsCP1251))
        let decoded = try ComparedText.decode(data)
        #expect(decoded.text == "Привет, мир\n")
        #expect(decoded.encoding != .utf8)
        #expect(!decoded.hasByteOrderMark)
    }

    @Test("a NUL with no byte-order mark is a binary, not text")
    func binary() {
        #expect(throws: ComparedText.Failure.binary) {
            try ComparedText.decode(Data([0x61, 0x00, 0x62]))
        }
    }

    @Test("a file is read whole, past Quick View's limit, and refused past the comparison's own")
    func readLimits() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let size = TextPreview.byteLimit + 10
        let line = String(repeating: "x", count: 99) + "\n"
        let text = String(String(repeating: line, count: size / 100 + 1).prefix(size))
        let path = try tree.writeFile("big.txt", contents: text)
        let url = URL(fileURLWithPath: path)
        #expect(try ComparedText.read(contentsOf: url).text.utf8.count == size)
        #expect(throws: ComparedText.Failure.tooLarge(byteSize: Int64(size), limit: 1024)) {
            try ComparedText.read(contentsOf: url, byteLimit: 1024)
        }
        #expect(throws: ComparedText.Failure.unreadable) {
            try ComparedText.read(contentsOf: url.appendingPathExtension("missing"))
        }
    }
}
