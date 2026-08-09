import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Everything an archive costs is remembered under its on-disk path — the `bsdtar -tvf` behind a
/// mount, and the extraction behind a preview — and deleting an archive to pack a new one under the
/// same name is the ordinary way to redo one. These pin that the caches notice (PLAN.md §M4).
///
/// Reported live: an archive repacked with one file went on listing the two the previous archive
/// held, for the life of the window. It is the quietest possible failure — the pane shows a
/// plausible listing, nothing logs, and the archive on disk is perfectly correct — so what is
/// pinned here is a *real* zip replaced on disk between two reads, never a stubbed one.
@MainActor
@Suite("Archive cache freshness")
struct ArchiveCacheFreshnessTests {
    // MARK: - The mount

    @Test("an archive repacked under the same name is re-read, not served from the old mount")
    func repackedArchiveIsRemounted() throws {
        let archive = try Fixture(entries: ["one.txt": "first", "two.txt": "second"])
        let backend = CompositeBackend(local: LocalBackend())
        let root = VFSPath(backend: .archive(forArchiveAt: archive.path), path: "/")

        #expect(try backend.listDirectory(at: root).map(\.name).sorted() == ["one.txt", "two.txt"])

        try archive.repack(entries: ["one.txt": "first"])

        #expect(try backend.listDirectory(at: root).map(\.name) == ["one.txt"])
    }

    @Test("an untouched archive is still served from its mount rather than re-read")
    func untouchedArchiveIsNotRemounted() throws {
        let archive = try Fixture(entries: ["one.txt": "first"])
        let backend = CompositeBackend(local: LocalBackend())
        let root = VFSPath(backend: .archive(forArchiveAt: archive.path), path: "/")
        #expect(try backend.listDirectory(at: root).count == 1)

        // Withdraw read permission: `stat` still answers (so the identity is unchanged) while
        // `bsdtar` could not open the file. A second listing that succeeds therefore could only
        // have come from the mount — the freshness check must not cost a spawn per list.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: archive.path)

        #expect(try backend.listDirectory(at: root).map(\.name) == ["one.txt"])
    }

    @Test("an archive deleted out from under a mount reports the failure instead of the snapshot")
    func deletedArchiveStopsAnswering() throws {
        let archive = try Fixture(entries: ["one.txt": "first"])
        let backend = CompositeBackend(local: LocalBackend())
        let root = VFSPath(backend: .archive(forArchiveAt: archive.path), path: "/")
        #expect(try backend.listDirectory(at: root).count == 1)

        try FileManager.default.removeItem(atPath: archive.path)

        // A file with no identity is a miss, never "unchanged" — otherwise a pane could browse a
        // ghost archive, and its F5 copy-out would fail with no listing to explain why.
        #expect(throws: (any Error).self) { try backend.listDirectory(at: root) }
    }

    // MARK: - The preview extraction

    @Test("a repacked archive's member previews its new bytes, not the extraction it replaced")
    func repackedArchiveDropsItsExtractions() async throws {
        let archive = try Fixture(entries: ["one.txt": "first"])
        let cache = ArchivePreviewCache()
        let member = ArchiveMember(archivePath: archive.path, innerPath: "one.txt")

        let before = try await cache.extractedURL(for: member)
        #expect(try String(contentsOf: before, encoding: .utf8) == "first")

        try archive.repack(entries: ["one.txt": "rewritten"])

        // Worse than the stale listing above, because the user is looking at file *bytes* — a
        // preview of the previous archive's member under the new archive's name.
        #expect(cache.cachedURL(for: member) == nil)
        let after = try await cache.extractedURL(for: member)
        #expect(try String(contentsOf: after, encoding: .utf8) == "rewritten")
    }

    @Test("an untouched archive's member is still served from its extraction")
    func untouchedArchiveKeepsItsExtraction() async throws {
        let archive = try Fixture(entries: ["one.txt": "first"])
        let cache = ArchivePreviewCache()
        let member = ArchiveMember(archivePath: archive.path, innerPath: "one.txt")

        let url = try await cache.extractedURL(for: member)
        // The synchronous hit is what the preview surfaces read on every cursor movement; losing
        // it would re-spawn `bsdtar` on a keystroke.
        #expect(cache.cachedURL(for: member) == url)
    }

    /// A real zip, packed by `bsdtar` from real files, that can be deleted and packed again under
    /// the same name — which is the gesture under test, so it must be the gesture the fixture makes.
    private final class Fixture {
        let directory: URL
        let path: String

        init(entries: [String: String]) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveCacheFreshnessTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appendingPathComponent("pkg.zip").path
            try repack(entries: entries)
        }

        func repack(entries: [String: String]) throws {
            let staging = directory.appendingPathComponent("staging-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            for (name, contents) in entries {
                try Data(contents.utf8).write(to: staging.appendingPathComponent(name))
            }
            if FileManager.default.fileExists(atPath: path) {
                // Permission is withdrawn by one of the tests; the parent directory is what a
                // delete needs, so this only has to survive the mode, not restore it.
                try FileManager.default.removeItem(atPath: path)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            process.arguments = ["-c", "--format", "zip", "-f", path, "-C", staging.path]
                + entries.keys.sorted()
            try process.run()
            process.waitUntilExit()
            try FileManager.default.removeItem(at: staging)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
