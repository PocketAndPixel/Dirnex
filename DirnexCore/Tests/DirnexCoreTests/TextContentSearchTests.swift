import Foundation
import Testing

@testable import DirnexCore

/// "Content contains" where Spotlight does not index, answered by reading the file (PLAN.md §M40
/// Slice 3).
///
/// Most of these cut a text into chunks at **every** byte, because the hard half of a streaming grep
/// is the boundary: a character the cut splits, and a match the cut splits. One split point that
/// happens to work proves nothing about the others.
@Suite("Text content search")
struct TextContentSearchTests {
    // MARK: - Helpers

    /// Search `pieces` as one text, chunked exactly as given.
    private func search(_ pieces: [Data], for needle: String) -> Bool {
        var remaining = pieces.makeIterator()
        return TextContentSearch.chunks(contain: needle) { remaining.next() }
    }

    /// Every way of cutting `data` in two, plus the uncut whole.
    private func everyCut(of data: Data) -> [[Data]] {
        [[data]] + (1..<data.count).map { [data.prefix($0), data.dropFirst($0)] }
    }

    /// Each search in `everyCut(of:)`, with the cut that answered differently named in the failure.
    private func expectEveryCut(
        of data: Data,
        for needle: String,
        toFind expected: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for (cut, pieces) in everyCut(of: data).enumerated() {
            #expect(
                search(pieces, for: needle) == expected,
                "cut \(cut) of \(data.count)",
                sourceLocation: sourceLocation
            )
        }
    }

    private func utf16(_ text: String, bigEndian: Bool = false, mark: Bool = false) -> Data {
        var data = Data(mark ? (bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]) : [])
        data.append(text.data(using: bigEndian ? .utf16BigEndian : .utf16LittleEndian) ?? Data())
        return data
    }

    // MARK: - What a file's start says

    @Test("plain text, and UTF-8 with a mark, read as UTF-8")
    func utf8() {
        #expect(TextEncodingSniff.classify(Data("hello".utf8))?.encoding == .utf8)
        let marked = TextEncodingSniff.classify(Data([0xEF, 0xBB, 0xBF] + Array("hi".utf8)))
        #expect(marked?.encoding == .utf8)
        #expect(marked?.byteOrderMarkLength == 3)
    }

    @Test("UTF-16 with a mark, in either byte order")
    func utf16WithMark() {
        let little = TextEncodingSniff.classify(utf16("Привет", mark: true))
        #expect(little?.encoding == .utf16LittleEndian)
        #expect(little?.byteOrderMarkLength == 2)
        let big = TextEncodingSniff.classify(utf16("Привет", bigEndian: true, mark: true))
        #expect(big?.encoding == .utf16BigEndian)
    }

    /// The NULs of Latin text in UTF-16 are its high bytes, so they all fall on one side of each pair.
    @Test("UTF-16 without a mark is told from where its NULs fall")
    func utf16WithoutMark() {
        #expect(TextEncodingSniff.classify(utf16("plain words"))?.encoding == .utf16LittleEndian)
        let big = TextEncodingSniff.classify(utf16("plain words", bigEndian: true))
        #expect(big?.encoding == .utf16BigEndian)
        #expect(TextEncodingSniff.classify(utf16("plain words"))?.byteOrderMarkLength == 0)
    }

    @Test("a NUL anywhere else makes a file binary")
    func binary() {
        // A PNG's signature and the start of its header chunk.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48])
        #expect(TextEncodingSniff.classify(png) == nil)
        #expect(TextEncodingSniff.classify(Data("text\0with a NUL".utf8)) == nil)
    }

    @Test("UTF-32's mark is not taken for UTF-16's")
    func utf32() {
        let utf32 = Data([0xFF, 0xFE, 0, 0, 0x41, 0, 0, 0])
        #expect(TextEncodingSniff.classify(utf32) == nil)
    }

    // MARK: - Matching

    /// The `cd` on Spotlight's `kMDItemTextContent` clause, which is the rule the walk keeps.
    @Test("case and diacritics are ignored, as in Spotlight's content clause")
    func caseAndDiacritics() {
        let cases: [(text: String, needle: String)] = [
            ("Café au lait", "CAFE"),
            ("ПРИВЕТ мир", "привет"),
            ("Straße", "STRASSE"),
            ("Їжак", "іжак"),
            ("e\u{301}cole", "École")
        ]
        for (text, needle) in cases {
            #expect(search([Data(text.utf8)], for: needle), "\(needle) in \(text)")
        }
        #expect(!search([Data("Café".utf8)], for: "tea"))
    }

    @Test("an empty needle finds nothing")
    func emptyNeedle() {
        #expect(!search([Data("anything".utf8)], for: ""))
    }

    // MARK: - Chunk boundaries

    @Test("a needle cut by a chunk boundary is found at every cut")
    func needleAcrossBoundary() {
        expectEveryCut(of: Data("before the needle after".utf8), for: "needle", toFind: true)
    }

    /// Without the carry, a cut inside a two-byte Cyrillic letter fails the whole chunk's decoding.
    @Test("a character cut by a chunk boundary is not lost")
    func characterAcrossBoundary() {
        expectEveryCut(of: Data("Съешь ещё этих булок".utf8), for: "булок", toFind: true)
        expectEveryCut(of: Data("emoji 😀 here".utf8), for: "😀", toFind: true)
    }

    /// A match need not be as long as its needle, so the join keeps more than the needle's length.
    @Test("a match longer or shorter than its needle is found across a join")
    func unevenMatchAcrossBoundary() {
        expectEveryCut(of: Data("Die Straße hier".utf8), for: "STRASSE", toFind: true)
        expectEveryCut(of: Data("une e\u{301}cole".utf8), for: "école", toFind: true)
    }

    @Test("UTF-16 cut at an odd byte or inside a surrogate pair")
    func utf16AcrossBoundary() {
        expectEveryCut(of: utf16("Привет 😀 мир", mark: true), for: "мир", toFind: true)
        expectEveryCut(of: utf16("Привет 😀 мир", mark: true), for: "😀", toFind: true)
        expectEveryCut(
            of: utf16("Hello world", bigEndian: true, mark: true),
            for: "WORLD",
            toFind: true
        )
        expectEveryCut(of: utf16("Hello world"), for: "world", toFind: true)
    }

    /// The decoder's own half of the UTF-16 cuts above, which the join alone would also cover:
    /// `NSString` keeps a lone surrogate as it is, so a join puts a cut pair back together. Holding the
    /// first half back keeps every decoded chunk whole characters, and this pins that it does.
    @Test("the decoder holds back half a surrogate pair and an odd byte")
    func decoderHoldsBackHalves() {
        var decoder = TextChunkDecoder(encoding: .utf16LittleEndian)
        #expect(decoder.decode(Data([0x41, 0x00, 0x3D, 0xD8])) == "A")
        #expect(decoder.decode(Data([0x00, 0xDE, 0x42])) == "😀")
        #expect(decoder.decode(Data([0x00])) == "B")
        #expect(decoder.finish().length == 0)

        var utf8 = TextChunkDecoder(encoding: .utf8)
        let letter = Array("ж".utf8)
        #expect(utf8.decode(Data([0x41, letter[0]])) == "A")
        #expect(utf8.decode(Data([letter[1]])) == "ж")
    }

    /// The control for the cuts above: a needle that is not there must not appear at any cut either,
    /// or the join would be inventing text.
    @Test("no cut finds what is not there")
    func noFalseMatchAtJoins() {
        expectEveryCut(of: Data("need le".utf8), for: "needle", toFind: false)
        expectEveryCut(of: utf16("need le", mark: true), for: "needle", toFind: false)
    }

    /// A Latin-1 or Windows-1252 file is not UTF-8. Its bad bytes read as U+FFFD, so ASCII is still
    /// found and the accented letter, which is not UTF-8 here, is not.
    @Test("text that is not valid UTF-8 still answers an ASCII needle")
    func invalidUTF8() throws {
        let latin1 = try #require("Le café au lait".data(using: .isoLatin1))
        expectEveryCut(of: latin1, for: "lait", toFind: true)
        #expect(!search([latin1], for: "café"))
    }

    @Test("Stop between chunks abandons the text")
    func stopBetweenChunks() {
        var asked = 0
        var pieces = [Data("first chunk ".utf8), Data("then the needle".utf8)].makeIterator()
        let found = TextContentSearch.chunks(
            contain: "needle",
            isCancelled: {
                asked += 1
                return asked > 1
            },
            next: { pieces.next() }
        )
        #expect(!found)
    }

    // MARK: - Files

    @Test("a file's text is found, and a binary file's is not")
    func files() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let text = try tree.writeFile("notes.txt", contents: "Meeting notes: Квартальный отчёт")
        #expect(TextContentSearch.file(at: text, contains: "квартальный"))
        #expect(!TextContentSearch.file(at: text, contains: "absent"))

        let binary = tree.path("image.bin")
        var bytes = Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0x0D])
        bytes.append(Data("notes".utf8))
        try bytes.write(to: URL(fileURLWithPath: binary))
        #expect(!TextContentSearch.file(at: binary, contains: "notes"))
    }

    @Test("a UTF-16 file written with a mark is read")
    func utf16File() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = tree.path("export.reg")
        try utf16("Windows Registry Editor Version 5.00", mark: true)
            .write(to: URL(fileURLWithPath: path))
        #expect(TextContentSearch.file(at: path, contains: "registry editor"))
    }

    /// Several chunks, with the needle placed across the first boundary and at the very end.
    @Test("a file longer than a chunk is read to its end, joins included")
    func multiChunkFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let chunk = TextContentSearch.chunkSize
        var text = Data(repeating: UInt8(ascii: "a"), count: chunk - 3)
        text.append(Data("BOUNDARY".utf8))
        text.append(Data(repeating: UInt8(ascii: "b"), count: chunk * 2))
        text.append(Data("the end".utf8))
        let path = tree.path("big.log")
        try text.write(to: URL(fileURLWithPath: path))

        #expect(TextContentSearch.file(at: path, contains: "boundary"))
        #expect(TextContentSearch.file(at: path, contains: "THE END"))
        #expect(!TextContentSearch.file(at: path, contains: "absent"))
    }

    @Test("a long file stops when asked")
    func fileStops() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        var text = Data(repeating: UInt8(ascii: "a"), count: TextContentSearch.chunkSize * 2)
        text.append(Data("needle".utf8))
        let path = tree.path("long.txt")
        try text.write(to: URL(fileURLWithPath: path))

        var asked = 0
        let found = TextContentSearch.file(at: path, contains: "needle") {
            asked += 1
            return asked > 1
        }
        #expect(!found)
        // The control: the same file, not stopped, does hold it.
        #expect(TextContentSearch.file(at: path, contains: "needle"))
    }

    @Test("a symlink is not followed, and a missing file is not a match")
    func symlinkAndMissing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let target = try tree.writeFile("target.txt", contents: "secret text")
        try tree.symlink("link.txt", to: target)
        #expect(!TextContentSearch.file(at: tree.path("link.txt"), contains: "secret"))
        #expect(TextContentSearch.file(at: target, contains: "secret"))
        #expect(!TextContentSearch.file(at: tree.path("ghost.txt"), contains: "secret"))
    }
}
