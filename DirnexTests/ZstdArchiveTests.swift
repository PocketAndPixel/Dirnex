import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A `.tar.zst` through the app's archive runners, in a test host whose `PATH` has no `zstd`, as a
/// Dock-launched Dirnex's has none (``ZstdTool``).
///
/// Before ``BsdtarEnvironment``, every `bsdtar` child inherited that `PATH`, and a Dock-launched
/// build answered *Couldn't read the archive* for any `.tar.zst` (measured 2026-10-26). These read
/// and rewrite the core's committed fixtures through the same three runners the pane uses, and the
/// refusal tests stand for a Mac with no `zstd` at all by pointing the search at nothing.
///
/// The refusal tests rely on the host's own `PATH` lacking `zstd`, which is launchd's: were it
/// there, `bsdtar` would find it without Dirnex and list the archive.
@Suite("Zstandard archives")
struct ZstdArchiveTests {
    /// A copy of one of the core's fixtures in a directory of its own, since a rewrite replaces it.
    private struct Fixture {
        let directory: URL
        let archive: String

        /// The core's fixtures, two folders up from this file.
        private static let source = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "DirnexCore/Tests/DirnexCoreTests/Fixtures")

        init(_ name: String) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ZstdArchive-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            archive = directory.appendingPathComponent("\(name).tar.zst").path
            try FileManager.default.copyItem(
                atPath: Self.source.appending(path: "\(name).tar.zst").path, toPath: archive
            )
        }

        func names(in directory: String = "/") throws -> [String] {
            try ArchiveMounter.readTableOfContents(ofArchiveAt: archive)
                .children(inDirectory: directory).map(\.name).sorted()
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - With zstd found

    @Test(
        "a .tar.zst lists and extracts",
        .enabled(if: ZstdTool.locate() != nil, "needs a zstd to find"),
        arguments: ["plain-bsdtar", "plain-pzstd"]
    )
    func listsAndExtracts(_ name: String) throws {
        let fixture = try Fixture(name)
        defer { fixture.remove() }

        #expect(try fixture.names() == ["alpha.txt", "docs"])
        #expect(try fixture.names(in: "/docs") == ["beta.txt"])
        let extraction = try ArchiveExtractor.extract(
            innerPaths: ["/docs/beta.txt"], fromArchiveAt: fixture.archive
        )
        defer { try? FileManager.default.removeItem(at: extraction.directory) }
        #expect(
            try String(contentsOfFile: extraction.extractedPaths[0], encoding: .utf8) == "beta\n"
        )
    }

    @Test(
        "deleting a member rewrites a .tar.zst as a .tar.zst",
        .enabled(if: ZstdTool.locate() != nil, "needs a zstd to find"),
        arguments: ["plain-bsdtar", "plain-pzstd"]
    )
    func rewriteKeepsZstandard(_ name: String) throws {
        let fixture = try Fixture(name)
        defer { fixture.remove() }

        try ArchiveWriter.delete(
            innerPaths: ["/docs/beta.txt"], fromArchiveAt: fixture.archive, undo: .none
        )
        #expect(try fixture.names() == ["alpha.txt", "docs"])
        #expect(try fixture.names(in: "/docs").isEmpty)
        // On the bytes, since a repack that fell back to another compression would hold exactly the
        // right members. `bsdtar` writes a plain frame whatever the original started with.
        let head = try FileHandle(forReadingFrom: URL(filePath: fixture.archive)).read(upToCount: 4)
        #expect(head.map(Array.init) == ZstdTool.frameSignature)
    }

    // MARK: - With no zstd anywhere

    @Test("listing a .tar.zst with no zstd says so by name")
    func listingRefusesByName() throws {
        let fixture = try Fixture("plain-bsdtar")
        defer { fixture.remove() }

        #expect(throws: VFSError.unsupported(.archiveNeedsZstd(archive: "plain-bsdtar.tar.zst"))) {
            try ZstdTool.$searchDirectoriesOverride.withValue([]) { try fixture.names() }
        }
    }

    @Test("extracting from a .tar.zst with no zstd says so by name")
    func extractionRefusesByName() throws {
        let fixture = try Fixture("plain-pzstd")
        defer { fixture.remove() }

        #expect(throws: VFSError.unsupported(.archiveNeedsZstd(archive: "plain-pzstd.tar.zst"))) {
            try ZstdTool.$searchDirectoriesOverride.withValue([]) {
                try ArchiveExtractor.extract(
                    innerPaths: ["/alpha.txt"],
                    fromArchiveAt: fixture.archive
                )
            }
        }
    }

    @Test("rewriting a .tar.zst with no zstd says so by name and leaves the archive alone")
    func rewriteRefusesByName() throws {
        let fixture = try Fixture("plain-bsdtar")
        defer { fixture.remove() }
        let before = try Data(contentsOf: URL(filePath: fixture.archive))

        #expect(throws: VFSError.unsupported(.archiveNeedsZstd(archive: "plain-bsdtar.tar.zst"))) {
            try ZstdTool.$searchDirectoriesOverride.withValue([]) {
                try ArchiveWriter.delete(
                    innerPaths: ["/alpha.txt"], fromArchiveAt: fixture.archive, undo: .none
                )
            }
        }
        #expect(try Data(contentsOf: URL(filePath: fixture.archive)) == before)
    }
}
