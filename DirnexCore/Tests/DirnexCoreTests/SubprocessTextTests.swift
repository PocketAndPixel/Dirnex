import Foundation
import Testing

@testable import DirnexCore

/// That one unrepresentable name costs its own row rather than the whole listing.
///
/// `String(bytes:encoding:.utf8)` is all-or-nothing, and every subprocess reader carried a `?? ""`
/// behind it — so a single file whose name is not valid UTF-8 turned a directory into an empty one,
/// or an archive into "cannot be read". Measured 2026-09-09 against a real legacy zip
/// (``ArchiveNonASCIINameTests``), where it was reachable end to end.
@Suite("Subprocess text")
struct SubprocessTextTests {
    @Test("ordinary UTF-8 comes back exactly, so nothing about a healthy listing changes")
    func validUTF8IsUnchanged() {
        let listing = "-rw-r--r-- 1 oleg staff 10 Sep 9 00:00 Панорама.jpg\n"
        #expect(SubprocessText.lossyUTF8(Data(listing.utf8)) == listing)
    }

    @Test("a row that is not valid UTF-8 no longer discards the rows around it")
    func oneBadNameDoesNotCostTheListing() {
        // `8f a0 ad ae` is `Пано` in CP866 — a real legacy-zip name, and not valid UTF-8.
        var bytes = Data("first.txt\n".utf8)
        bytes.append(contentsOf: [0x8F, 0xA0, 0xAD, 0xAE])
        bytes.append(contentsOf: Data(".txt\nlast.txt\n".utf8))

        // The old spelling, kept here as the control: it answers nil for the whole stream.
        #expect(String(bytes: bytes, encoding: .utf8) == nil)

        let text = SubprocessText.lossyUTF8(bytes)
        let lines = text.split(whereSeparator: \.isNewline)
        #expect(lines.count == 3)
        #expect(lines.first == "first.txt")
        #expect(lines.last == "last.txt")
    }

    @Test("and the undecodable bytes are replaced rather than dropped")
    func badBytesBecomeReplacements() {
        // Substituted, not silently deleted — a name that lost its characters without a trace is
        // the FTP `0x7F` failure over again, where a plausible shorter name is worse than a
        // visibly broken one.
        let text = SubprocessText.lossyUTF8(Data([0x8F, 0xA0]))
        #expect(text.contains("\u{FFFD}"))
        #expect(!text.isEmpty)
    }

    @Test("empty input is empty text, not a surprise")
    func emptyIsEmpty() {
        #expect(SubprocessText.lossyUTF8(Data()).isEmpty)
    }
}
