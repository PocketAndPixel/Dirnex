import Foundation
import Testing

@testable import DirnexCore

/// The pure half: which attributes are worth showing, and how a value is classified for display.
/// Every fixture here is a **real** value captured from this Mac (2026-07-31) rather than invented,
/// because the whole point of the classifier is that one ordinary download carries all three shapes.
@Suite("ExtendedAttribute")
struct ExtendedAttributeTests {
    @Test("provenance is filtered out — it is on essentially every file, so it says nothing")
    func filtersProvenance() {
        let provenance = ExtendedAttribute(
            name: "com.apple.provenance",
            data: Data([0x01, 0x02, 0x00, 0xC5, 0x77, 0x75, 0x25, 0xA4, 0x98, 0x75, 0x0A])
        )
        #expect(!provenance.isWorthShowing)
    }

    @Test("the other com.apple attributes are kept — quarantine is the one users act on")
    func keepsNamedAppleAttributes() {
        for name in [
            "com.apple.quarantine",
            "com.apple.metadata:kMDItemWhereFroms",
            "com.apple.macl",
            "com.apple.metadata:_kMDItemUserTags"
        ] {
            #expect(ExtendedAttribute(name: name, data: Data()).isWorthShowing)
        }
    }

    @Test("a real quarantine value classifies as text")
    func classifiesQuarantineAsText() throws {
        let raw = "0281;6a5c94dc;Chrome;4EB3AC05-B90D-48EE-863A-732DD85D48FC"
        let attribute = ExtendedAttribute(name: "com.apple.quarantine", data: Data(raw.utf8))
        #expect(attribute.value == .text(raw))
    }

    @Test("a binary property list classifies as a property list, not as text")
    func classifiesPropertyList() throws {
        // The leading bytes of the real `kMDItemWhereFroms` captured from a download.
        var data = Data("bplist00".utf8)
        data.append(contentsOf: [0xD4, 0x01, 0x02, 0x03, 0x04])
        #expect(ExtendedAttribute(name: "com.apple.metadata:kMDItemWhereFroms", data: data).value
            == .propertyList)
    }

    @Test("opaque bytes classify as binary even when they decode as UTF-8")
    func classifiesBinary() {
        // The real `com.apple.provenance` value. It decodes as UTF-8 perfectly well — which is the
        // trap: a UTF-8 decode alone would render control characters into the panel, so the
        // classifier requires the result to be *printable*.
        let data = Data([0x01, 0x02, 0x00, 0xC5, 0x77, 0x75, 0x25, 0xA4, 0x98, 0x75, 0x0A])
        #expect(ExtendedAttribute(name: "com.apple.provenance", data: data).value == .binary)
    }

    @Test("an empty value is binary, not empty text")
    func classifiesEmpty() {
        #expect(ExtendedAttribute(name: "com.apple.macl", data: Data()).value == .binary)
    }

    @Test("a multi-line text value stays text — newlines and tabs are legitimate content")
    func allowsWhitespaceInText() {
        let raw = "first line\n\tsecond\r\n"
        #expect(ExtendedAttribute(name: "com.example.notes", data: Data(raw.utf8))
            .value == .text(raw))
    }

    @Test("the hex preview matches what `xattr -px` prints, and elides past the limit")
    func hexPreview() {
        let attribute = ExtendedAttribute(
            name: "com.apple.provenance",
            data: Data([0x01, 0x02, 0x00, 0xC5, 0x77, 0x75, 0x25, 0xA4, 0x98, 0x75, 0x0A])
        )
        #expect(attribute.hexPreview() == "01 02 00 C5 77 75 25 A4 98 75 0A")
        #expect(attribute.hexPreview(limit: 4) == "01 02 00 C5 …")
    }
}
