import Foundation
import Testing

@testable import DirnexCore

/// A binary property list, shown as the XML it converts to (docs/HISTORY.md, 2026-09-16). The
/// conversion is `PropertyListSerialization`'s; what is tested here is when it is asked and what the
/// limits refuse.
@Suite("TextPreview for a binary property list")
struct TextPreviewPropertyListTests {
    /// Written by Python's `plistlib` with `sort_keys=False`, so the keys are stored `zeta`, `alpha`,
    /// `mid` — a writer other than the converter, and an order the converter does not keep.
    private static let unsortedBinary = Data(hex: """
    62706c6973743030d3010203040506547a65746155616c706861536d6964100110021003080f141a1e2022000000\
    0000000101000000000000000700000000000000000000000000000024
    """)

    @Test("a binary plist becomes its XML, with every value type and a non-ASCII string")
    func convertsToXML() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let object: [String: Any] = [
            "Name": "Панорама",
            "Count": 3,
            "Ratio": 1.5,
            "Enabled": true,
            "Items": ["one", "two"],
            "Nested": ["Inner": false],
            "Blob": Data([0x01, 0x02, 0x03])
        ]
        let url = tree.root.appendingPathComponent("Settings.plist")
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
            .write(to: url)

        let preview = try #require(TextPreview.readBinaryPropertyList(contentsOf: url))
        #expect(preview.text.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        for fragment in [
            "<key>Name</key>", "<string>Панорама</string>", "<integer>3</integer>",
            "<real>1.5</real>", "<true/>", "<false/>", "<string>two</string>",
            // Data is base64, on lines of its own.
            "<data>\n\tAQID\n\t</data>"
        ] {
            #expect(preview.text.contains(fragment), "missing \(fragment)")
        }
        #expect(!preview.isTruncated)
        // Nothing is lost on the way: the XML reads back to the same property list.
        let reread = try PropertyListSerialization.propertyList(
            from: Data(preview.text.utf8),
            format: nil
        )
        #expect((reread as? NSDictionary)?.isEqual(to: object) == true)
    }

    @Test("a dictionary's keys come out sorted, as plutil and Quick Look show them")
    func keysAreSorted() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("Order.plist")
        try Self.unsortedBinary.write(to: url)

        let preview = try #require(TextPreview.readBinaryPropertyList(contentsOf: url))
        let keys = preview.text.components(separatedBy: "<key>").dropFirst()
            .compactMap { $0.components(separatedBy: "</key>").first }
        #expect(keys == ["alpha", "mid", "zeta"])
    }

    @Test("an XML plist, text and a binary that is not a plist are not converted")
    func onlyBinaryPlists() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let xml = try PropertyListSerialization.data(
            fromPropertyList: ["a": 1],
            format: .xml,
            options: 0
        )
        let cases: [(String, Data)] = [
            ("Info.plist", xml),
            // Text that happens to open with the magic's six letters.
            ("notes.txt", Data("bplist is only a word here\n".utf8)),
            ("empty.plist", Data()),
            ("Mach-O", Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x00])),
            // Text that opens with the magic and parses as an old-style plist, which is not binary.
            ("Words.txt", Data("bplist00 = x;".utf8)),
            // The magic and then nothing a parser can read.
            ("Broken.plist", Data("bplist00".utf8) + Data(repeating: 0x7F, count: 40))
        ]
        for (name, data) in cases {
            let url = tree.root.appendingPathComponent(name)
            try data.write(to: url)
            #expect(
                TextPreview.readBinaryPropertyList(contentsOf: url) == nil,
                "\(name) should be nil"
            )
        }
    }

    @Test("a file that is not a binary plist costs its first six bytes")
    func refusalReadsOnlyTheMagic() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("blob")
        // A Mach-O's shape, as in `TextPreviewTests`: the magic, a NUL, then a long body.
        let bytes = Data([0xCF, 0xFA, 0xED, 0xFE, 0x00]) + Data(repeating: 0x41, count: 64 * 1024)
        try bytes.write(to: url)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #expect(
            TextPreview.readBinaryPropertyList(from: handle, byteLimit: TextPreview.byteLimit) == nil
        )
        #expect(handle.offsetInFile == UInt64(TextPreview.binaryPropertyListMagic.count))
    }

    /// A binary plist cannot be read in part, so over the limit the answer is Quick Look. Its XML is
    /// always the larger of the two, so the XML's limit is the one a fixture can reach on its own.
    @Test("a file or its XML over the limit is refused, and a file exactly at it is not")
    func limits() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("Order.plist")
        try Self.unsortedBinary.write(to: url)
        let size = Self.unsortedBinary.count
        let xmlSize = try #require(TextPreview.readBinaryPropertyList(contentsOf: url)).text.utf8.count
        try #require(xmlSize > size + 1)

        #expect(TextPreview.readBinaryPropertyList(contentsOf: url, byteLimit: size - 1) == nil)
        // The file fits and its XML does not.
        #expect(TextPreview.readBinaryPropertyList(contentsOf: url, byteLimit: size) == nil)
        #expect(TextPreview.readBinaryPropertyList(contentsOf: url, byteLimit: xmlSize) != nil)
    }
}

private extension Data {
    /// Bytes from a hex string, for a fixture minted by a writer other than the code under test.
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), index < hex.endIndex {
            if let byte = UInt8(hex[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        self.init(bytes)
    }
}
