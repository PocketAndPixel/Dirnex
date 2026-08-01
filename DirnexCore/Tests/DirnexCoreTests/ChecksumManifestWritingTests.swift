import Foundation
import Testing

@testable import DirnexCore

/// The writing half of the manifest round-trip: what Dirnex puts on disk, and whether the stock
/// tools can read it back. The interop claim was also checked live — `shasum -c`, `/sbin/sha256sum
/// -c` and `/sbin/md5sum -c` all verify a file written here (PLAN.md §M14).
@Suite("ChecksumManifest writing")
struct ChecksumManifestWritingTests {
    private static let helloSHA256 =
        "54b546dd1abc7108f73affc828b0771155ac437c380a245f1f183ca4d455c5fc"

    @Test("GNU round-trip")
    func gnuRoundTrip() throws {
        let manifest = ChecksumManifest(
            algorithm: .sha256,
            entries: [
                ChecksumManifestEntry(name: "plain.txt", digest: Self.helloSHA256),
                ChecksumManifestEntry(name: "name with spaces.txt", digest: Self.helloSHA256)
            ]
        )
        let text = manifest.serialized()
        #expect(text == """
        \(Self.helloSHA256)  plain.txt
        \(Self.helloSHA256)  name with spaces.txt

        """)

        let reparsed = try ChecksumManifest.parse(text)
        #expect(reparsed.entries == manifest.entries)
        #expect(reparsed.algorithm == .sha256)
    }

    @Test("the binary marker round-trips")
    func binaryRoundTrip() throws {
        let manifest = ChecksumManifest(
            algorithm: .sha256,
            entries: [ChecksumManifestEntry(
                name: "disk.iso",
                digest: Self.helloSHA256,
                isBinary: true
            )]
        )
        #expect(manifest.serialized() == "\(Self.helloSHA256) *disk.iso\n")
        #expect(try ChecksumManifest.parse(manifest.serialized()).entries == manifest.entries)
    }

    /// Measured against both checkers Apple ships: `shasum -c` reads a raw backslash name fine,
    /// while `/sbin/sha256sum -c` *rejects* the escaped form ("improperly formatted") and checks
    /// one file fewer. So a backslash goes out raw — escaping it would cost compatibility for
    /// nothing.
    @Test("a backslash in a name is written raw, and round-trips")
    func backslashWrittenRaw() throws {
        let manifest = ChecksumManifest(
            algorithm: .sha256,
            entries: [ChecksumManifestEntry(name: "back\\slash.txt", digest: Self.helloSHA256)]
        )
        let text = manifest.serialized()
        #expect(text == "\(Self.helloSHA256)  back\\slash.txt\n")
        #expect(try ChecksumManifest.parse(text).entries.first?.name == "back\\slash.txt")
    }

    /// A newline has no raw form any parser can split, so there the escape is the only way to say
    /// it — and backslashes ride along escaped once the line is marked.
    @Test("a newline in a name is escaped, and round-trips")
    func newlineWrittenEscaped() throws {
        let manifest = ChecksumManifest(
            algorithm: .sha256,
            entries: [ChecksumManifestEntry(name: "new\nline\\odd.txt", digest: Self.helloSHA256)]
        )
        let text = manifest.serialized()
        #expect(text == "\\\(Self.helloSHA256)  new\\nline\\\\odd.txt\n")
        #expect(try ChecksumManifest.parse(text).entries.first?.name == "new\nline\\odd.txt")
    }

    @Test("CRC32 serializes as .sfv and round-trips")
    func sfvRoundTrip() throws {
        let manifest = ChecksumManifest(
            algorithm: .crc32,
            entries: [
                ChecksumManifestEntry(name: "plain.txt", digest: "4dbf2cc1"),
                ChecksumManifestEntry(name: "name with spaces.txt", digest: "485e125e")
            ]
        )
        #expect(manifest.serialized() == """
        plain.txt 4dbf2cc1
        name with spaces.txt 485e125e

        """)
        #expect(try ChecksumManifest.parse(manifest.serialized()).entries == manifest.entries)
    }

    @Test("every serialized file ends with a newline")
    func trailingNewline() {
        for algorithm in ChecksumAlgorithm.allCases {
            let manifest = ChecksumManifest(
                algorithm: algorithm,
                entries: [ChecksumManifestEntry(
                    name: "a.txt",
                    digest: String(repeating: "a", count: algorithm.hexDigitCount)
                )]
            )
            #expect(manifest.serialized().hasSuffix("\n"))
        }
    }

    // MARK: - File names

    @Test("a manifest's file name appends the algorithm's extension")
    func suggestedFileName() {
        #expect(ChecksumManifest.suggestedFileName(for: "disk.iso", algorithm: .sha256)
            == "disk.iso.sha256")
        #expect(ChecksumManifest.suggestedFileName(for: "parts", algorithm: .crc32)
            == "parts.sfv")
    }

    /// What makes Total Commander's single-hex `.crc` companion readable: the name it describes
    /// exists nowhere but in the manifest's own file name.
    @Test("a bare-digest manifest implies its subject from its own name")
    func impliedName() {
        #expect(ChecksumManifest.impliedName(forManifestFileName: "disk.iso.crc") == "disk.iso")
        #expect(ChecksumManifest.impliedName(forManifestFileName: "disk.iso.sha256") == "disk.iso")
        #expect(ChecksumManifest.impliedName(forManifestFileName: "parts.SFV") == "parts")
        #expect(ChecksumManifest.impliedName(forManifestFileName: "notes.txt") == nil)
        #expect(ChecksumManifest.impliedName(forManifestFileName: "sha256") == nil)
    }
}
