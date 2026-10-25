import Foundation
import Testing

@testable import DirnexCore

@Suite("ComparedDocument")
struct ComparedDocumentTests {
    static func document(_ text: String) throws -> ComparedDocument {
        try ComparedDocument.decode(Data(text.utf8))
    }

    static func document(_ text: String, encoding: String.Encoding) -> ComparedDocument {
        ComparedDocument(
            lines: TextLines.split(text),
            encoding: encoding,
            hasByteOrderMark: false,
            isSavable: true
        )
    }

    /// The document's text, line endings included: what a save of it says.
    static func text(_ document: ComparedDocument) -> String {
        document.lines.map { $0.content + $0.terminator.text }.joined()
    }

    /// Copy the first change of a fresh comparison across to `side`, as the window does.
    @discardableResult
    static func copyFirstChange(
        to side: ComparisonPaneText.Side,
        _ left: inout ComparedDocument,
        _ right: inout ComparedDocument,
        options: LineDiffOptions = LineDiffOptions()
    ) throws -> LineEdit {
        let change = try #require(TextComparison(left, right, options: options).diff.changes.first)
        let edit = LineEdit.copying(change, to: side, left: left, right: right)
        return side == .right ? right.apply(edit) : left.apply(edit)
    }

    // MARK: - Reading and writing back

    private static func bytes(_ mark: [UInt8], _ text: String, _ encoding: String.Encoding) -> Data {
        Data(mark) + (text.data(using: encoding) ?? Data())
    }

    /// A file in each encoding the decoder names, with each line ending among them.
    static let encodedFiles: [(String, Data)] = [
        ("UTF-8", bytes([], "ä\r\nb\rc\n", .utf8)),
        ("UTF-8 with a mark", bytes([0xEF, 0xBB, 0xBF], "ä\r\nb", .utf8)),
        ("UTF-16LE", bytes([0xFF, 0xFE], "ä\r\nb\n", .utf16LittleEndian)),
        ("UTF-16BE", bytes([0xFE, 0xFF], "ä\r\nb\n", .utf16BigEndian)),
        ("UTF-32LE", bytes([0xFF, 0xFE, 0, 0], "ä\nb", .utf32LittleEndian)),
        ("UTF-32BE", bytes([0, 0, 0xFE, 0xFF], "ä\nb", .utf32BigEndian)),
        (
            "Windows-1251",
            bytes([], "Привет, мир! Это проверка.\r\nВторая строка.\r\n", .windowsCP1251)
        ),
        ("Windows-1252", bytes([], "Café crème, naïve façade, “quotes” €\n", .windowsCP1252)),
        ("Shift JIS", bytes([], "日本語のテキストです。これはテストです。\n", .shiftJIS)),
        ("EUC-JP", bytes([], "日本語のテキストです。これはテストです。\n", .japaneseEUC))
    ]

    @Test(
        "an unedited file comes back byte for byte, in every encoding the decoder names",
        arguments: encodedFiles
    )
    func roundTrip(_ name: String, _ data: Data) throws {
        let document = try ComparedDocument.decode(data)
        #expect(document.isSavable, "\(name)")
        #expect(try document.encoded() == data, "\(name)")
        #expect(!document.isEdited)
    }

    @Test("a file the model cannot write back unchanged is not savable, and says so before any edit")
    func notSavable() throws {
        // Foundation drops the second mark, so the text would be written with one.
        let doubled = Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF] + Array("hi\n".utf8))
        // Foundation drops the odd byte at the end.
        let oddUTF16 = Data([0xFF, 0xFE, 0x68, 0x00, 0x69])
        for data in [doubled, oddUTF16] {
            let document = try ComparedDocument.decode(data)
            #expect(!document.isSavable)
            #expect(try document.encoded() != data)
        }
        // The controls: one mark, and an even count.
        #expect(try ComparedDocument.decode(Data(doubled.dropFirst(3))).isSavable)
        #expect(try ComparedDocument.decode(Data(oddUTF16.dropLast())).isSavable)
    }

    @Test("what ComparedText refuses, a document refuses too")
    func refusals() {
        #expect(throws: ComparedText.Failure.binary) {
            try ComparedDocument.decode(Data([0x61, 0x00, 0x62]))
        }
        #expect(throws: ComparedText.Failure.unreadable) {
            try ComparedDocument.read(contentsOf: URL(fileURLWithPath: "/nonexistent/dirnex"))
        }
    }

    @Test("a character the encoding has no bytes for is named with its line, never replaced")
    func unencodable() throws {
        var latin1 = Self.document("one\ntwo\n", encoding: .isoLatin1)
        latin1.apply(LineEdit(
            range: 1..<1,
            replacement: TextLines.split("costs 5 €, not £5\n")
        ))
        #expect(throws: ComparedDocument.EncodingFailure.unencodable(line: 1, character: "€")) {
            try latin1.encoded()
        }
        // A character of several scalars is named whole.
        var cyrillic = Self.document("строка\n", encoding: .windowsCP1251)
        cyrillic.apply(LineEdit(range: 1..<1, replacement: TextLines.split("флаг 🇺🇦\n")))
        #expect(throws: ComparedDocument.EncodingFailure.unencodable(line: 1, character: "🇺🇦")) {
            try cyrillic.encoded()
        }
        // The control: what Latin-1 holds is written.
        var control = Self.document("one\n", encoding: .isoLatin1)
        control.apply(LineEdit(range: 1..<1, replacement: TextLines.split("£5\n")))
        #expect(try control.encoded() == Data([0x6F, 0x6E, 0x65, 0x0A, 0xA3, 0x35, 0x0A]))
    }

    @Test("a decomposed character is written as the encoding's one character for it")
    func decomposedIntoLegacy() throws {
        let document = Self.document("e\u{301}\n", encoding: .isoLatin1)
        #expect(try document.encoded() == Data([0xE9, 0x0A]))
    }

    // MARK: - Line endings

    @Test("the common line ending is the most frequent, the first met on a tie, nil with none")
    func commonLineEnding() throws {
        #expect(try Self.document("a\nb\n").commonLineEnding == .lf)
        #expect(try Self.document("a\r\nb\r\nc\nd").commonLineEnding == .crlf)
        #expect(try Self.document("a\rb\r").commonLineEnding == .cr)
        #expect(try Self.document("a\r\nb\nc").commonLineEnding == .crlf)
        #expect(try Self.document("a\nb\r\nc").commonLineEnding == .lf)
        #expect(try Self.document("a").commonLineEnding == nil)
        #expect(try Self.document("").commonLineEnding == nil)
    }

    @Test("a block copied out of a CRLF file takes the LF of the file it lands in, either way")
    func copiedLinesTakeDestinationEnding() throws {
        var left = try Self.document("one\r\ntwo\r\nthree\r\n")
        var right = try Self.document("one\nchanged\nthree\n")
        let options = LineDiffOptions(ignoresLineEndings: true)
        try Self.copyFirstChange(to: .right, &left, &right, options: options)
        #expect(Self.text(right) == "one\ntwo\nthree\n")
        right = try Self.document("one\nchanged\nthree\n")
        try Self.copyFirstChange(to: .left, &left, &right, options: options)
        #expect(Self.text(left) == "one\r\nchanged\r\nthree\r\n")
    }

    @Test("a copied last line with no line break gains one, unless it lands last too")
    func lastLineWithoutBreak() throws {
        // It lands last: it stays without.
        var left = try Self.document("a\nb")
        var right = try Self.document("a\nc\n")
        try Self.copyFirstChange(to: .right, &left, &right)
        #expect(Self.text(right) == "a\nb")
        // It lands ahead of another line: it gains the destination's ending.
        left = try Self.document("x\r\ny")
        right = try Self.document("a\r\nb\r\nc\r\n")
        let edit = LineEdit.copying(
            LineDiff.Change(left: 1..<2, right: 0..<1),
            to: .right,
            left: left,
            right: right
        )
        right.apply(edit)
        #expect(Self.text(right) == "y\r\nb\r\nc\r\n")
    }

    @Test("a block landing after a last line with no line break gives that line one")
    func insertedAfterUnterminatedLastLine() throws {
        // Overlooking line endings, "a" matches "a\n", so the change is "b" alone, after it.
        var left = try Self.document("a\nb")
        var right = try Self.document("a")
        let options = LineDiffOptions(ignoresLineEndings: true)
        let inverse = try Self.copyFirstChange(to: .right, &left, &right, options: options)
        #expect(Self.text(right) == "a\nb")
        right.apply(inverse)
        #expect(Self.text(right) == "a")
        // The same with a line that has a break of its own, landing ahead of nothing.
        left = try Self.document("a\r\nb\r\n")
        right = try Self.document("a")
        try Self.copyFirstChange(to: .right, &left, &right, options: options)
        #expect(Self.text(right) == "a\r\nb\r\n")
    }

    @Test("a destination with no line break takes the source's; neither having one gives LF")
    func endingFallbacks() throws {
        var left = try Self.document("a\r\nb\r\n")
        var right = try Self.document("x")
        try Self.copyFirstChange(to: .right, &left, &right)
        #expect(Self.text(right) == "a\r\nb\r\n")
        let one = LineEdit.copying(
            LineDiff.Change(left: 0..<1, right: 0..<0),
            to: .right,
            left: try Self.document("a\nb"),
            right: try Self.document("z")
        )
        #expect(one.replacement.map(\.terminator) == [.lf])
        let none = LineEdit.copying(
            LineDiff.Change(left: 0..<1, right: 0..<1),
            to: .left,
            left: try Self.document("z"),
            right: try Self.document("q")
        )
        #expect(none.replacement.map(\.terminator) == [.none])
    }

    @Test("copying an empty side deletes the block, and a copy of a whole file is the file")
    func deletionsAndWholeFiles() throws {
        var left = try Self.document("a\nc\n")
        var right = try Self.document("a\nb\nc\n")
        try Self.copyFirstChange(to: .right, &left, &right)
        #expect(Self.text(right) == "a\nc\n")
        left = try Self.document("")
        right = try Self.document("x\ny")
        try Self.copyFirstChange(to: .right, &left, &right)
        #expect(right.lines.isEmpty)
        #expect(try right.encoded().isEmpty)
    }

    @Test("lines shown as the same under an option are not copied, and still differ")
    func copyActsOnWhatIsShown() throws {
        var left = try Self.document("a  b\nkeep\nnew\n")
        var right = try Self.document("a b\nkeep\nold\n")
        let options = LineDiffOptions(whitespace: .ignoreChanges)
        try Self.copyFirstChange(to: .right, &left, &right, options: options)
        #expect(Self.text(right) == "a b\nkeep\nnew\n")
        let after = TextComparison(left, right, options: options)
        #expect(after.diff.isIdentical)
        #expect(after.unshownDifferences == [.whitespace])
    }

    // MARK: - Edits

    @Test("an edit returns its inverse, the inverse returns the edit, and isEdited follows")
    func inverseAndEdited() throws {
        var document = try Self.document("a\nb\nc\n")
        let edit = LineEdit(range: 1..<2, replacement: TextLines.split("x\ny\n"))
        let inverse = document.apply(edit)
        #expect(Self.text(document) == "a\nx\ny\nc\n")
        #expect(document.isEdited)
        #expect(inverse.range == 1..<3)
        let redo = document.apply(inverse)
        #expect(Self.text(document) == "a\nb\nc\n")
        #expect(!document.isEdited)
        document.apply(redo)
        #expect(Self.text(document) == "a\nx\ny\nc\n")
        // Put back by hand rather than by the inverse: unedited all the same.
        document.apply(LineEdit(range: 1..<3, replacement: TextLines.split("b\n")))
        #expect(!document.isEdited)
    }

    @Test("isEdited compares bytes: a decomposed é in place of a precomposed one is an edit")
    func editedByBytes() throws {
        var document = try Self.document("caf\u{E9}\n")
        document.apply(LineEdit(range: 0..<1, replacement: TextLines.split("cafe\u{301}\n")))
        #expect(document.lines[0].content == "caf\u{E9}")
        #expect(document.isEdited)
        // A line ending is part of a line.
        var ending = try Self.document("a\n")
        ending.apply(LineEdit(range: 0..<1, replacement: TextLines.split("a\r\n")))
        #expect(ending.isEdited)
    }

    @Test("two unedited documents compare as their texts do")
    func comparisonOfDocuments() throws {
        let leftText = "one\ntwo\r\nthree\nfour"
        let rightText = "one\n2\nthree\nfour\n"
        let fromDocuments = try TextComparison(Self.document(leftText), Self.document(rightText))
        let fromTexts = TextComparison(ComparedText(text: leftText), ComparedText(text: rightText))
        #expect(fromDocuments.diff == fromTexts.diff)
        #expect(fromDocuments.rows == fromTexts.rows)
        #expect(fromDocuments.unshownDifferences == fromTexts.unshownDifferences)
    }
}
