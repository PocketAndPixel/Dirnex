import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// That a file whose name is not ASCII survives a real `bsdtar` in **both** directions.
///
/// `bsdtar` renders a name through `vis(3)`, exactly as `sftp` does, so with no locale set — which
/// is every LaunchServices-launched app (``ChildProcessLocale``) — a browsed archive lists
/// `./\320\237\320\260\320\275\320\276\321\200\320\260\320\274\320\260.txt` and every verb built
/// from that row addresses a member that is not there.
///
/// The **write** half is the one that outlives the session, and it is why this suite packs for real
/// rather than asserting an argv: under the `C` locale libarchive stores the right UTF-8 bytes with
/// the zip's UTF-8 flag **clear**, so the archive is correct by our own reading and mojibake to
/// everyone else. Measured 2026-09-09 on libarchive 3.7.4 — `╨ƒ╨░╨╜╨╛╤Ç╨░╨╝╨░.txt` in Python's
/// `zipfile`, which is the same rule Windows Explorer and Info-ZIP follow.
@Suite("Archive non-ASCII names")
struct ArchiveNonASCIINameTests {
    private static let cyrillic = "Панорама.txt"
    private static let japanese = "日本語.txt"

    @Test("a packed archive carries the real names, flagged so every other tool reads them too")
    func packCarriesNamesAndTheUTF8Flag() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.pack()

        // Read the zip's own central directory by hand rather than asking `bsdtar` what it wrote.
        // That is the whole point: `bsdtar` reads its own output back correctly under either
        // locale, so it agrees with a broken pack — only an independent reader can see the flag
        // that tells *other* tools how to decode the name.
        let entries = try ZipCentralDirectory.entries(ofArchiveAt: fixture.archivePath)
        let names = entries.map(\.name)
        #expect(names.contains(Self.cyrillic), "packed names were \(names)")
        #expect(names.contains(Self.japanese), "packed names were \(names)")
        for entry in entries where !entry.name.allSatisfy(\.isASCII) {
            #expect(entry.declaresUTF8, "\(entry.name) is stored without the UTF-8 flag")
        }
    }

    @Test("and the table of contents the pane draws lists them unescaped")
    func tableOfContentsIsNotEscaped() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.pack()

        // The real spawn site, not a re-implementation of its argv.
        let toc = try ArchiveMounter.readTableOfContents(ofArchiveAt: fixture.archivePath)
        let names = toc.children(inDirectory: "/").map(\.name)
        #expect(names.contains(Self.cyrillic), "listed names were \(names)")
        #expect(names.contains(Self.japanese), "listed names were \(names)")
        // The failure this replaces is a *plausible* name rather than a missing one, so assert the
        // escape is absent as well as the name being present.
        #expect(!names.contains { $0.contains("\\") }, "an escaped name survived: \(names)")
    }

    /// A directory holding the two names, and the archive packed from it.
    private struct Fixture {
        let root: URL
        var archivePath: String { root.appendingPathComponent("out.zip").path }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("dirnex_archive_utf8_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in [cyrillic, japanese, "plain.txt"] {
                try Data("x".utf8).write(to: root.appendingPathComponent(name))
            }
        }

        func pack() throws {
            try ArchivePacker().pack(
                PlainPackRequest(
                    sources: [cyrillic, japanese, "plain.txt"].map {
                        PackSource(directory: root.path, name: $0)
                    },
                    archiveOnDiskPath: archivePath,
                    format: .zip,
                    level: .normal
                ),
                onProgress: { _ in },
                isCancelled: { false }
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}

/// A minimal reader for a zip's central directory — enough to answer what name was stored and
/// whether it is flagged as UTF-8.
///
/// Written out by hand on purpose. The claim under test is about what a *stranger's* tool sees, so
/// borrowing the tool that wrote the archive would prove the two agree rather than that either is
/// right — the rule docs/NOTES.md states for minting a probe's payload, arriving on an oracle.
enum ZipCentralDirectory {
    struct Entry {
        let name: String
        /// General-purpose bit 11, which tells a reader the name is UTF-8 rather than CP437.
        let declaresUTF8: Bool
    }

    static func entries(ofArchiveAt path: String) throws -> [Entry] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let signature: [UInt8] = [0x50, 0x4B, 0x01, 0x02] // "PK\u{01}\u{02}", a central-directory header
        var entries: [Entry] = []
        var index = 0
        while index + 46 <= data.count {
            guard Array(data[index..<index + 4]) == signature else {
                index += 1
                continue
            }
            let flags = read16(data, at: index + 8)
            let nameLength = Int(read16(data, at: index + 28))
            let extraLength = Int(read16(data, at: index + 30))
            let commentLength = Int(read16(data, at: index + 32))
            let nameStart = index + 46
            guard nameStart + nameLength <= data.count else { break }
            let raw = data[nameStart..<nameStart + nameLength]
            entries.append(Entry(
                // Decoded as UTF-8 because that is what the flag claims; a name stored without the
                // flag is *reported* here as whatever its bytes say, which is what lets the test
                // distinguish "wrong bytes" from "right bytes, wrong flag".
                name: (String(bytes: raw, encoding: .utf8) ?? "<undecodable>")
                    .split(separator: "/").last.map(String.init) ?? "",
                declaresUTF8: flags & 0x800 != 0
            ))
            index = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func read16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }
}
