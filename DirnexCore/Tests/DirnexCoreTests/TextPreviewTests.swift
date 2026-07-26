import Foundation
import Testing

@testable import DirnexCore

/// The Quick View text decoder. Every case here was first observed against real bytes with a
/// throwaway probe — the encodings Foundation gets right, the one it gets wrong, and the two shapes
/// (a NUL-carrying binary, a prefix cut mid-character) that make a naive decode put garbage on
/// screen.
@Suite("TextPreview")
struct TextPreviewTests {
    private static let cyrillic = "Привет, мир! Это текст.\nВторая строка.\n"

    // MARK: - Encodings

    @Test("plain ASCII decodes verbatim")
    func ascii() throws {
        let preview = try #require(TextPreview.decode(Data("test 01\n".utf8), isTruncated: false))
        #expect(preview.text == "test 01\n")
        #expect(!preview.isTruncated)
    }

    @Test("UTF-8 decodes, with or without a BOM")
    func utf8() throws {
        let bytes = Data(Self.cyrillic.utf8)
        let plain = try #require(TextPreview.decode(bytes, isTruncated: false))
        let marked = try #require(
            TextPreview.decode(Data([0xEF, 0xBB, 0xBF]) + bytes, isTruncated: false)
        )
        #expect(plain.text == Self.cyrillic)
        // The BOM is the encoding's statement about itself, not content: it must not survive into
        // what the user selects and copies.
        #expect(marked.text == Self.cyrillic)
    }

    @Test("a BOM settles UTF-16 in either byte order")
    func utf16() throws {
        let little = try #require(Self.cyrillic.data(using: .utf16LittleEndian))
        let big = try #require(Self.cyrillic.data(using: .utf16BigEndian))

        let le = try #require(TextPreview.decode(Data([0xFF, 0xFE]) + little, isTruncated: false))
        let be = try #require(TextPreview.decode(Data([0xFE, 0xFF]) + big, isTruncated: false))
        #expect(le.text == Self.cyrillic)
        #expect(be.text == Self.cyrillic)
    }

    @Test("UTF-16 with no BOM is refused, not rendered with a gap between every character")
    func utf16WithoutByteOrderMark() throws {
        let bytes = try #require(Self.cyrillic.data(using: .utf16LittleEndian))
        // The trap: those bytes are *valid UTF-8* — the NULs are legal — so a UTF-8-first decode
        // succeeds and puts `П\0р\0и\0в…` on screen. Nothing identifies them (probed: Foundation's
        // own detector answers nothing), so the NUL guard refuses them and Quick Look takes over.
        #expect(String(data: bytes, encoding: .utf8) != nil)
        #expect(TextPreview.decode(bytes, isTruncated: false) == nil)
    }

    @Test("UTF-32's little-endian BOM is not read as UTF-16's")
    func utf32() throws {
        let body = try #require(Self.cyrillic.data(using: .utf32LittleEndian))
        let preview = try #require(
            TextPreview.decode(Data([0xFF, 0xFE, 0x00, 0x00]) + body, isTruncated: false)
        )
        #expect(preview.text == Self.cyrillic)
    }

    @Test("a legacy 8-bit file decodes by detection")
    func legacyEncodings() throws {
        let cp1251 = try #require(Self.cyrillic.data(using: .windowsCP1251))
        let latin1 = try #require("Café naïve grösser\n".data(using: .isoLatin1))

        let cyrillic = try #require(TextPreview.decode(cp1251, isTruncated: false))
        let western = try #require(TextPreview.decode(latin1, isTruncated: false))
        #expect(cyrillic.text == Self.cyrillic)
        #expect(western.text == "Café naïve grösser\n")
    }

    @Test("bytes no encoding claims are refused rather than shown as mojibake")
    func lossyDetectionRefused() throws {
        // MacRoman is the measured case: Foundation answers "Japanese (Windows, DOS)" and converts
        // lossily, i.e. it would put `Caf<?> na夫e` on screen for a file that says `Café naïve`.
        let macRoman = try #require("Café naïve\n".data(using: .macOSRoman))
        #expect(TextPreview.decode(macRoman, isTruncated: false) == nil)
    }

    @Test("an empty file previews as empty text, not as a failure")
    func empty() throws {
        let preview = try #require(TextPreview.decode(Data(), isTruncated: false))
        #expect(preview.text.isEmpty)
    }

    // MARK: - Binaries

    @Test("a NUL byte means binary, whatever the extension claimed")
    func binaryRefused() {
        let data = Data([0x66, 0x6F, 0x6F, 0x00, 0x01, 0x02, 0xFF, 0xFE])
        #expect(TextPreview.decode(data, isTruncated: false) == nil)
    }

    @Test("a real executable is refused")
    func executableRefused() throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: "/bin/ls")).prefix(65536)
        #expect(TextPreview.decode(bytes, isTruncated: false) == nil)
    }

    // MARK: - Truncation

    @Test("a prefix cut mid-character loses the partial character, not the tail of the text")
    func truncatedMidCharacter() throws {
        let whole = Data(Self.cyrillic.utf8)
        // "Привет" is 2 bytes per character, so an odd count lands inside one.
        let cut = whole.prefix(9)
        #expect(String(data: cut, encoding: .utf8) == nil)

        let preview = try #require(TextPreview.decode(cut, isTruncated: true))
        #expect(preview.text == "Прив")
        #expect(preview.isTruncated)
        #expect(!preview.text.contains("\u{FFFD}"))
    }

    @Test("a UTF-16 prefix cut mid code unit still decodes")
    func truncatedUTF16() throws {
        let body = try #require(Self.cyrillic.data(using: .utf16LittleEndian))
        let cut = (Data([0xFF, 0xFE]) + body).prefix(13) // BOM + 5½ code units
        let preview = try #require(TextPreview.decode(cut, isTruncated: true))
        #expect(preview.text == "Приве")
    }

    // MARK: - Reading a file

    @Test("a file under the limit is read whole and reported untruncated")
    func readsWholeFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("notes.txt", contents: "test 01\n")

        let preview = try #require(
            TextPreview.read(contentsOf: tree.root.appendingPathComponent("notes.txt"))
        )
        #expect(preview.text == "test 01\n")
        #expect(!preview.isTruncated)
    }

    @Test("a file over the limit is cut to it and says so")
    func readsPrefixOfLargeFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("big.log", contents: String(repeating: "x", count: 5000))

        let url = tree.root.appendingPathComponent("big.log")
        let preview = try #require(TextPreview.read(contentsOf: url, byteLimit: 1000))
        #expect(preview.text.count == 1000)
        #expect(preview.isTruncated)
    }

    @Test("a file exactly at the limit is not reported as truncated")
    func fileExactlyAtLimit() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("exact.txt", contents: String(repeating: "x", count: 1000))

        let url = tree.root.appendingPathComponent("exact.txt")
        let preview = try #require(TextPreview.read(contentsOf: url, byteLimit: 1000))
        #expect(!preview.isTruncated)
    }

    @Test("an unreadable path is nil, so the caller falls back to Quick Look")
    func missingFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        #expect(TextPreview.read(contentsOf: tree.root.appendingPathComponent("nope.txt")) == nil)
    }
}
