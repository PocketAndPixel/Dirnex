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

    /// The **in-process** writer flags its names too — a separate mechanism from the subprocess
    /// packer's, and one that no environment can fix.
    ///
    /// `EncryptedArchiveWriter` calls libarchive inside this process, so ``ChildProcessLocale``
    /// cannot reach it: there is no child to hand an environment to, and Dirnex never calls
    /// `setlocale` (it is process-global on a threaded GUI app). Measured 2026-09-09, an archive
    /// packed here — encrypted *or* not — stored `Панорама.txt` with the right UTF-8 bytes and
    /// **bit 11 clear**, so it read back perfectly in Dirnex and as `╨ƒ╨░╨╜╨╛╤Ç╨░╨╝╨░.txt`
    /// everywhere else. `hdrcharset=UTF-8` is the targeted equivalent.
    ///
    /// Both encryptions are asserted because they take different libarchive paths and the option is
    /// set once for both — a fix that reached only the plain one would be invisible on the archives
    /// the encryption feature exists for.
    @Test("the in-process writer flags its names as UTF-8, encrypted or not")
    func inProcessWriterFlagsUTF8() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex_inproc_utf8_\(UUID().uuidString)")
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in [Self.cyrillic, Self.japanese] {
            try Data("x".utf8).write(to: source.appendingPathComponent(name))
        }

        for (label, encryption) in [("plain", ArchiveEncryption.none), ("aes256", .aes256)] {
            let archive = directory.appendingPathComponent("\(label).zip").path
            try EncryptedArchiveWriter.write(
                items: try ArchiveSourceEnumerator.items(
                    inDirectory: source.path, names: [Self.cyrillic, Self.japanese]
                ),
                toArchiveAt: archive,
                encryption: encryption,
                passphrase: encryption.isEncrypted ? ArchivePassphrase("pw") : nil,
                namePrivacy: .visible
            )
            let entries = try ZipCentralDirectory.entries(ofArchiveAt: archive)
            let names = entries.map(\.name)
            #expect(names.contains(Self.cyrillic), "\(label) stored \(names)")
            for entry in entries where !entry.name.allSatisfy(\.isASCII) {
                #expect(
                    entry.declaresUTF8,
                    "\(label): \(entry.name) is stored without the UTF-8 flag"
                )
            }
        }
    }

    /// A zip whose names are in a **code page** with the UTF-8 flag clear — what Windows tools wrote
    /// for years — must still open, losing the one row it cannot name rather than the archive.
    ///
    /// This is the regression ``ChildProcessLocale`` introduced and ``SubprocessText`` repairs.
    /// Measured 2026-09-09: under the `C` locale `bsdtar` octal-escapes every non-ASCII byte, so its
    /// output is pure ASCII and decodes; under the pinned UTF-8 locale it escapes *some* bytes and
    /// passes others raw, so the whole stream failed `String(bytes:encoding:.utf8)` and the archive
    /// reported **`archiveUnreadable`**. Pinning the locale is still right — it is what makes every
    /// ordinary archive list correctly — and the all-or-nothing decode is what had to go.
    @Test("a legacy code-page archive still opens, losing only the row it cannot name")
    func legacyCodePageArchiveStillOpens() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex_legacy_zip_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("legacy.zip")
        try Data(base64Encoded: Self.legacyCodePageZip, options: .ignoreUnknownCharacters)
            .map { try $0.write(to: archive) } ?? { throw ZipFixtureError.undecodable }()

        let toc = try ArchiveMounter.readTableOfContents(ofArchiveAt: archive.path)
        let names = toc.children(inDirectory: "/").map(\.name)
        // The archive opens at all — this is the assertion that failed outright before.
        #expect(names.count == 2, "listed \(names)")
        // And the member whose name *is* representable is intact and untouched by its neighbour.
        #expect(names.contains("plain.txt"), "listed \(names)")
    }

    /// A real legacy zip, 218 bytes: two stored entries, one named `Панорама.txt` in **CP866** with
    /// general-purpose bit 11 **clear**, exactly as WinRAR and Explorer wrote them.
    ///
    /// Hand-minted rather than produced by anything in this repo, which is the point — what is under
    /// test is the *reader*, so a fixture built by our own writer would prove the two agree rather
    /// than that either is right (docs/NOTES.md ▸ Live verification).
    private static let legacyCodePageZip = """
    UEsDBBQAAAAAAAAAIQCDFtyMAQAAAAEAAAAMAAAAj6CtruCgrKAudHh0eFBLAwQUAAAAAAAAACEA
    gxbcjAEAAAABAAAACQAAAHBsYWluLnR4dHhQSwECFAMUAAAAAAAAACEAgxbcjAEAAAABAAAADAAA
    AAAAAAAAAAAAgAEAAAAAj6CtruCgrKAudHh0UEsBAhQDFAAAAAAAAAAhAIMW3IwBAAAAAQAAAAkA
    AAAAAAAAAAAAAIABKwAAAHBsYWluLnR4dFBLBQYAAAAAAgACAHEAAABTAAAAAAA=
    """

    private enum ZipFixtureError: Error { case undecodable }

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
