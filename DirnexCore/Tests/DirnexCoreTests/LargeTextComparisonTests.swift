import Foundation
import Testing
@testable import DirnexCore

/// What lets the compare window take a large text pair (PLAN.md §M37 Slice 3): the limit, the cheap
/// look before a whole read, the column count's shortcut, and the sample the encoding detector is
/// shown.
@Suite("A large text pair")
struct LargeTextComparisonTests {
    private static let mebibyte: UInt64 = 1024 * 1024
    private static let gibibyte: UInt64 = 1024 * mebibyte

    private func file(_ data: Data, named name: String = "a.txt") throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("large-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return (url, folder)
    }

    // MARK: - The limit

    @Test("The limit is a thirty-second of the memory")
    func limitFollowsMemory() {
        #expect(
            ComparedText.windowByteLimit(physicalMemory: 64 * Self.gibibyte) == Int64(
                2 * Self.gibibyte
            )
        )
        #expect(
            ComparedText.windowByteLimit(physicalMemory: 16 * Self.gibibyte) == Int64(
                512 * Self.mebibyte
            )
        )
    }

    @Test("The limit never falls under today's 64 MiB")
    func limitHasAFloor() {
        let floor = ByteComparator.prescanByteLimit
        #expect(ComparedText.windowByteLimit(physicalMemory: 2 * Self.gibibyte) == floor)
        #expect(ComparedText.windowByteLimit(physicalMemory: 0) == floor)
    }

    @Test("A memory size past Int64 gives a limit, not a crash")
    func limitClamps() {
        #expect(ComparedText.windowByteLimit(physicalMemory: .max) == Int64(UInt64.max / 32))
    }

    // MARK: - Before a whole read

    @Test("A look before the read gives the file's size")
    func precheckGivesSize() throws {
        let (url, folder) = try file(Data("hello\n".utf8))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try ComparedText.precheck(contentsOf: url, byteLimit: 100) == 6)
    }

    @Test("An empty file passes the look before the read")
    func precheckEmpty() throws {
        let (url, folder) = try file(Data())
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try ComparedText.precheck(contentsOf: url, byteLimit: 100) == 0)
    }

    @Test("Past the limit is refused before a byte is read")
    func precheckTooLarge() throws {
        let (url, folder) = try file(Data("hello\n".utf8))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: ComparedText.Failure.tooLarge(byteSize: 6, limit: 5)) {
            try ComparedText.precheck(contentsOf: url, byteLimit: 5)
        }
    }

    @Test("A file with a NUL near its start is refused as binary")
    func precheckBinary() throws {
        let (url, folder) = try file(Data([0x7F, 0x45, 0x00, 0x46]))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: ComparedText.Failure.binary) {
            try ComparedText.precheck(contentsOf: url, byteLimit: 100)
        }
    }

    @Test("The look reads no further than its sniff")
    func precheckStopsAtTheSniff() throws {
        var bytes = Data(repeating: UInt8(ascii: "a"), count: TextPreview.sniffLength)
        bytes.append(0)
        let (url, folder) = try file(bytes)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try ComparedText.precheck(contentsOf: url, byteLimit: .max) == Int64(bytes.count))
    }

    @Test("A UTF-16 file with its mark is not called binary by the look")
    func precheckByteOrderMark() throws {
        var bytes = Data([0xFF, 0xFE])
        bytes.append(try #require("hi".data(using: .utf16LittleEndian)))
        let (url, folder) = try file(bytes)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try ComparedText.precheck(contentsOf: url, byteLimit: 100) == Int64(bytes.count))
    }

    @Test("A file that isn't there is unreadable")
    func precheckMissing() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        #expect(throws: ComparedText.Failure.unreadable) {
            try ComparedText.precheck(contentsOf: url, byteLimit: 100)
        }
    }

    // MARK: - The column count

    private static let columnCases = [
        "",
        "plain",
        "\ttab first",
        "a\tb\t\tc",
        "1234\t5",
        "control \u{01}\u{1F} characters",
        "café",
        "cafe\u{301}",
        "e\u{301}\t1",
        "日本語",
        "a日\tb",
        "🙂 smile",
        "👩‍💻 joined",
        "🇺🇦 flag",
        "cr\rinside",
        "crlf\r\nis one character",
        "\r\n",
        "\u{2424}stand-in"
    ]

    @Test("The shortcut counts what a walk over the characters counts", arguments: columnCases)
    func columnsAgree(text: String) {
        #expect(ComparisonPaneText.columns(of: text) == ComparisonPaneText.graphemeColumns(of: text))
    }

    @Test("A tab goes to the next multiple of four, as it did")
    func tabs() {
        #expect(ComparisonPaneText.columns(of: "\t") == 4)
        #expect(ComparisonPaneText.columns(of: "ab\tc") == 5)
        #expect(ComparisonPaneText.columns(of: "abcd\t") == 8)
    }

    @Test("Text not stored as UTF-8 is still counted")
    func bridged() {
        let bridged = NSString(string: "ab\tc") as String
        #expect(ComparisonPaneText.columns(of: bridged) == 5)
    }

    // MARK: - The sample the detector sees

    private func sample(_ text: [UInt8]) -> [UInt8] {
        Array(TextPreview.detectionSample(of: Data(text)))
    }

    @Test("Only the lines with a non-ASCII byte are kept, each with its break")
    func sampleKeepsNonASCIILines() {
        let first: [UInt8] = Array("plain\n".utf8)
        let second: [UInt8] = [0xCF, 0xF0, UInt8(ascii: "\n")]
        let third: [UInt8] = Array("plain again\r\n".utf8)
        let fourth: [UInt8] = [0xE0, UInt8(ascii: "\r")]
        #expect(sample(first + second + third + fourth) == second + fourth)
    }

    @Test("A last line with no break is kept")
    func sampleKeepsAnUnterminatedLastLine() {
        let line: [UInt8] = [UInt8(ascii: "a"), 0xCF, 0xF0]
        #expect(sample(Array("plain\n".utf8) + line) == line)
    }

    @Test("Text with nothing but ASCII gives no sample")
    func sampleOfASCII() {
        #expect(sample(Array("one\ntwo\n".utf8)).isEmpty)
    }

    @Test("The sample holds as many whole lines as fit")
    func sampleIsBounded() {
        let line: [UInt8] = Array(repeating: 0xCF, count: 99) + [UInt8(ascii: "\n")]
        let many = Array(repeating: line, count: 10000).flatMap(\.self)
        #expect(sample(many).count == TextPreview.detectionSampleLength / 100 * 100)
    }

    @Test("A long ASCII stretch before the first non-ASCII byte is left out of a long line")
    func sampleOfALongLineStartsAtItsFirstHighByte() {
        let length = TextPreview.detectionSampleLength
        let line = Array(repeating: UInt8(ascii: "a"), count: length * 2) + [0xCF, 0xF0]
        #expect(sample(line) == [0xCF, 0xF0])
    }

    @Test("A long line after a short one is not cut to fit")
    func sampleLeavesOutWhatDoesNotFit() {
        let first: [UInt8] = [0xCF, UInt8(ascii: "\n")]
        let long = Array(repeating: UInt8(0xF0), count: TextPreview.detectionSampleLength * 2)
        #expect(sample(first + long + [UInt8(ascii: "\n")]) == first)
    }

    @Test("One line past the length is cut after its last ASCII byte")
    func sampleCutsALongLineAtACharacterBoundary() {
        let length = TextPreview.detectionSampleLength
        var line = Array(repeating: UInt8(0xCF), count: length - 8)
        line += [UInt8(ascii: "x")]
        // A double-byte lead with its trail past the sample's end.
        line += Array(repeating: UInt8(0x81), count: 100)
        #expect(sample(line).count == length - 7)
        #expect(sample(line).last == UInt8(ascii: "x"))
    }

    @Test("One line with no ASCII at all gives the sample's length")
    func sampleOfOneLongLineWithNoASCII() {
        let line = Array(repeating: UInt8(0xCF), count: TextPreview.detectionSampleLength * 3)
        #expect(sample(line).count == TextPreview.detectionSampleLength)
    }

    // MARK: - Detection on a large file

    /// A Windows-1251 file of `lines` lines, with its Russian only at the end: the shape a sample of
    /// the file's start reads as ASCII.
    private func legacyFile(asciiLines: Int, russianLines: Int) throws -> (data: Data, text: String) {
        let ascii = String(
            repeating: "2026-11-08 12:00:00 INFO nothing unusual on this line\n",
            count: asciiLines
        )
        let russian = String(
            repeating: "Привет, это обычная строка на русском языке\n",
            count: russianLines
        )
        let text = ascii + russian
        return (try #require(text.data(using: .windowsCP1251)), text)
    }

    @Test("A large file that opens in English is read by its later lines")
    func largeLegacyFile() throws {
        let (data, text) = try legacyFile(asciiLines: 100_000, russianLines: 2000)
        #expect(data.count > TextPreview.byteLimit)
        let decoded = try #require(TextPreview.decodedText(data, isTruncated: false))
        #expect(decoded.encoding == .windowsCP1251)
        #expect(decoded.text == text)
        #expect(!decoded.hasByteOrderMark)
    }

    @Test("A file no larger than Quick View reads goes through the whole-file detector")
    func smallLegacyFileIsUnchanged() throws {
        let (data, text) = try legacyFile(asciiLines: 100, russianLines: 2000)
        #expect(data.count <= TextPreview.byteLimit)
        let decoded = try #require(TextPreview.decodedText(data, isTruncated: false))
        #expect(decoded.encoding == .windowsCP1251)
        #expect(decoded.text == text)
    }

    @Test("A large legacy file reads as a document that can be saved")
    func largeLegacyDocumentRoundTrips() throws {
        let (data, _) = try legacyFile(asciiLines: 100_000, russianLines: 2000)
        let document = try ComparedDocument.decode(data)
        #expect(document.encoding == .windowsCP1251)
        #expect(document.isSavable)
    }
}

/// Stopping a comparison partway (PLAN.md §M37 Slice 3).
@Suite("Stopping a comparison")
struct ComparisonStopTests {
    /// Answers true from its `n`th question on, and counts them.
    private final class StopAfter {
        let limit: Int
        private(set) var asked = 0

        init(_ limit: Int) {
            self.limit = limit
        }

        func ask() -> Bool {
            asked += 1
            return asked >= limit
        }
    }

    private func document(_ text: String) throws -> ComparedDocument {
        try ComparedDocument.decode(Data(text.utf8))
    }

    /// Two texts with lines changed all the way down, so each stage has work to do.
    private func densePair(lines: Int) throws -> (ComparedDocument, ComparedDocument) {
        var left = ""
        var right = ""
        for index in 0..<lines {
            let line = "line \(index) has some words in it\n"
            left += line
            right += index % 3 == 1 ? "line \(index) has other words in it\n" : line
        }
        return try (document(left), document(right))
    }

    @Test("Not stopped, it gives the comparison an ordinary one gives")
    func unstoppedMatches() throws {
        let (left, right) = try densePair(lines: 3000)
        let plain = TextComparison(left, right)
        let stoppable = try TextComparison(left, right, isCancelled: { false })
        #expect(stoppable.rows == plain.rows)
        #expect(stoppable.changeRows == plain.changeRows)
        #expect(stoppable.diff == plain.diff)
        #expect(stoppable.unshownDifferences == plain.unshownDifferences)
    }

    @Test("Stopped from the start, it throws at once")
    func stoppedAtOnce() throws {
        let (left, right) = try densePair(lines: 100)
        let asked = StopAfter(1)
        #expect(throws: CancellationError.self) {
            try TextComparison(left, right, isCancelled: asked.ask)
        }
        #expect(asked.asked == 1)
    }

    @Test("Wherever it is asked to stop, it stops", arguments: [2, 3, 4, 5, 8, 13, 40, 200, 700])
    func stoppedPartway(after count: Int) throws {
        let (left, right) = try densePair(lines: 3000)
        let asked = StopAfter(count)
        #expect(throws: CancellationError.self) {
            try TextComparison(left, right, isCancelled: asked.ask)
        }
        #expect(asked.asked == count)
    }

    @Test("A dense pair is asked once per change at least")
    func densePairAsksPerChange() throws {
        let (left, right) = try densePair(lines: 3000)
        let asked = StopAfter(.max)
        let comparison = try TextComparison(left, right, isCancelled: asked.ask)
        #expect(asked.asked >= comparison.changeRows.count)
    }

    @Test("Changes with nothing alike in them are asked per change too")
    func unalikeChangesAreAsked() throws {
        var left = ""
        var right = ""
        for index in 0..<3000 {
            left += "\(index) kept\n"
            right += "\(index) kept\n"
            left += "aaaa\(index)bbbb\n"
            right += "\(index * 7)zzzz@@@@\n"
        }
        let leftDocument = try document(left)
        let rightDocument = try document(right)
        let diff = LineDiff.compare(leftDocument.lines, rightDocument.lines)
        #expect(diff.changes.count == 3000)
        let asked = StopAfter(.max)
        _ = try RowAlignment.layout(
            left: leftDocument.lines,
            right: rightDocument.lines,
            diff: diff,
            options: LineDiffOptions()
        ) { () throws(CancellationError) in
            if asked.ask() { throw CancellationError() }
        }
        #expect(asked.asked >= 3000)
    }

    @Test("A stage that walks only lines is asked within its first stretch")
    func walksAreAskedPartway() throws {
        var text = ""
        for index in 0..<(ComparisonStop.linesBetweenChecks * 3) {
            text += "\(index)\n"
        }
        let same = try document(text)
        let asked = StopAfter(.max)
        _ = try TextComparison(same, same, isCancelled: asked.ask)
        // Three for each side's identities, three for the walk over the rows, and the three between
        // the search's stages.
        #expect(asked.asked >= 12)
    }

    @Test("A block of alike lines is asked per pair")
    func alikePairsAreAsked() throws {
        let count = 2000
        let left = try document((0..<count).map { "value \($0) = alpha\n" }.joined())
        let right = try document((0..<count).map { "value \($0) = gamma\n" }.joined())
        let diff = LineDiff.compare(left.lines, right.lines)
        #expect(diff.changes.count == 1)
        let asked = StopAfter(.max)
        _ = try RowAlignment.layout(
            left: left.lines,
            right: right.lines,
            diff: diff,
            options: LineDiffOptions()
        ) { () throws(CancellationError) in
            if asked.ask() { throw CancellationError() }
        }
        #expect(asked.asked >= count)
    }

    @Test("One rewritten block is asked while it is being laid out")
    func oneHugeBlockIsAsked() throws {
        let count = ComparisonStop.linesBetweenChecks * 2
        let left = try document((0..<count).map { "left line number \($0)\n" }.joined())
        let right = try document((0..<count).map { "\($0) completely unrelated text\n" }.joined())
        let diff = LineDiff.compare(left.lines, right.lines)
        #expect(diff.changes.count == 1)
        let asked = StopAfter(.max)
        _ = try RowAlignment.layout(
            left: left.lines,
            right: right.lines,
            diff: diff,
            options: LineDiffOptions()
        ) { () throws(CancellationError) in
            if asked.ask() { throw CancellationError() }
        }
        // One for the block, and two walks of each side's fingerprints with one over the pairs.
        #expect(asked.asked >= 7)
    }

    @Test("Stopping a search with many steps lands inside it")
    func searchIsAskedAsItGoes() throws {
        let left = (0..<4000).map { Int32($0 * 2) }
        let right = (0..<4000).map { Int32($0 * 2 + 1) }
        let asked = StopAfter(.max)
        _ = try MyersDiff.changes(left, right, costLimit: Int.max) { () throws(CancellationError) in
            if asked.ask() { throw CancellationError() }
        }
        #expect(asked.asked > 8)
    }

    @Test("A pane can be stopped, and otherwise is the ordinary pane")
    func paneStops() throws {
        let (left, right) = try densePair(lines: ComparisonStop.linesBetweenChecks + 10)
        let comparison = TextComparison(left, right)
        #expect(throws: CancellationError.self) {
            try ComparisonPaneText(comparison, side: .left, isCancelled: { true })
        }
        let plain = ComparisonPaneText(comparison, side: .right)
        let asked = StopAfter(.max)
        let stoppable = try ComparisonPaneText(comparison, side: .right, isCancelled: asked.ask)
        #expect(stoppable.text == plain.text)
        #expect(stoppable.rowStarts == plain.rowStarts)
        #expect(stoppable.widestColumns == plain.widestColumns)
        #expect(asked.asked >= 2)
    }

    @Test("A read is stopped between its steps", arguments: [1, 2, 3])
    func readStops(after count: Int) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("stop-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("a.txt")
        try Data("one\ntwo\n".utf8).write(to: url)
        let asked = StopAfter(count)
        #expect(throws: ComparedText.Failure.stopped) {
            try ComparedDocument.read(contentsOf: url, isCancelled: asked.ask)
        }
        #expect(asked.asked == count)
    }

    @Test("A read nothing stops gives the document")
    func readRuns() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("stop-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("a.txt")
        try Data("one\ntwo\n".utf8).write(to: url)
        let asked = StopAfter(.max)
        let document = try ComparedDocument.read(contentsOf: url, isCancelled: asked.ask)
        #expect(document.lines.count == 2)
        #expect(asked.asked == 3)
    }

    @Test("A document with no lines is the one a window starts from")
    func emptyDocument() {
        #expect(ComparedDocument.empty.lines.isEmpty)
        #expect(!ComparedDocument.empty.isEdited)
        #expect(!ComparedDocument.empty.isSavable)
    }

    @Test("A document is edited by what its lines say, however it got there")
    func editedFollowsBytes() throws {
        var document = try document("one\ntwo\n")
        #expect(!document.isEdited)
        let original = document.lines[0]
        let undo = document.apply(LineEdit(
            range: 0..<1,
            replacement: [TextLine(content: "other", terminator: .lf)]
        ))
        #expect(document.isEdited)
        document.apply(undo)
        #expect(document.lines[0] == original)
        #expect(!document.isEdited)
    }
}
