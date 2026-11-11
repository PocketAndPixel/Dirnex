import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A real zip, packed by `bsdtar` from real files, and packed again under the same name the way
/// another app's save of the archive replaces it.
final class ArchiveZipFixture {
    let directory: URL
    let path: String

    init(_ entries: [String: String]) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveWriteBackMergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("pkg.zip").path
        try repack(entries)
    }

    /// Another writer's save: a new archive under the same name.
    func repack(_ entries: [String: String]) throws {
        let staging = directory.appendingPathComponent("staging-\(UUID().uuidString)")
        for (name, contents) in entries {
            let file = staging.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: file)
        }
        let packed = directory.appendingPathComponent("packed-\(UUID().uuidString).zip").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-c", "--format", "zip", "-f", packed, "-C", staging.path]
            + entries.keys.sorted()
        try process.run()
        process.waitUntilExit()
        try FileManager.default.removeItem(at: staging)
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: packed)
            )
        } else {
            try FileManager.default.moveItem(atPath: packed, toPath: path)
        }
    }

    /// One member's bytes as the archive holds them, read by `bsdtar` rather than by the code under
    /// test.
    func member(_ name: String) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-x", "-O", "-f", path, name]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? "<not UTF-8>"
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// An edit of one member: extracted by the window's cache, as F4 extracts it.
@MainActor
struct ArchiveMemberEditRig {
    let cache: ArchivePreviewCache
    let pending: PendingArchiveWriteBack

    init(
        _ fixture: ArchiveZipFixture,
        name: String,
        in innerDirectory: String = "/",
        cache: ArchivePreviewCache = ArchivePreviewCache()
    ) async throws {
        self.cache = cache
        let innerPath = innerDirectory == "/" ? "/\(name)" : "\(innerDirectory)/\(name)"
        let copy = try await cache.extractedURL(
            for: ArchiveMember(archivePath: fixture.path, innerPath: innerPath)
        )
        pending = PendingArchiveWriteBack(
            edit: EditedFile(
                destination: .archiveMember(
                    archivePath: fixture.path,
                    innerDirectory: innerDirectory
                ),
                temporaryURL: copy,
                name: name
            ),
            archivePath: fixture.path,
            innerDirectory: innerDirectory
        )
    }

    var copy: URL { pending.edit.temporaryURL }

    func write(_ contents: String) throws {
        try Data(contents.utf8).write(to: copy)
    }

    var base: ArchiveMemberBase? { cache.memberBase(ofCopy: copy) }

    func verdict(_ fixture: ArchiveZipFixture) -> ArchiveMemberVerdict {
        BrowserWindowController.archiveMemberCheck(
            for: fixture.path, passphrase: nil, nameEncoding: nil
        ).verdicts(for: [.init(innerPath: pending.innerPath, base: base)])[0]
    }

    func cleanup() {
        cache.dropBase(ofCopy: copy)
    }
}

func readArchiveTestFile(_ url: URL?) -> String {
    url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "<none>"
}

/// The bases kept for edits of archive members (PLAN.md §M37 Slice 4).
///
/// A base has to be the member's bytes as they were in the archive it names, or a merge reads the
/// archive's change as one the user made and drops it in silence. So each rule that moves a copy's
/// base is pinned for what it does: the watch starting, a merge saved, and the copy going back.
@MainActor
@Suite("Archive member bases")
struct ArchiveMemberBaseTests {
    @Test("a member's watch keeps its copy as extracted, with the archive it came out of, once")
    func watchKeepsTheExtraction() async throws {
        let fixture = try ArchiveZipFixture(["docs/notes.txt": "as packed\n"])
        let edit = try await ArchiveMemberEditRig(fixture, name: "notes.txt", in: "/docs")
        defer { edit.cleanup() }
        let archive = try #require(ArchiveIdentity.current(ofFileAt: fixture.path))

        edit.cache.keepBase(for: edit.pending.edit)
        let base = try #require(edit.base)
        #expect(readArchiveTestFile(base.base) == "as packed\n")
        #expect(base.archive == archive)
        #expect(base.base.path.hasPrefix(ArchivePreviewCache.basesRoot.path))
        #expect(
            !base.base.path.hasPrefix(edit.copy.deletingLastPathComponent().path),
            "outside the folder the edit watch watches"
        )

        // The editor's save leaves it, and a second watch keeps the base it has.
        try edit.write("edited\n")
        edit.cache.keepBase(for: edit.pending.edit)
        #expect(edit.base == base)
        #expect(readArchiveTestFile(base.base) == "as packed\n")
    }

    @Test("no base for a copy written before its watch, a server file, or a copy not extracted here")
    func keepsNoneItCannotVouchFor() async throws {
        let fixture = try ArchiveZipFixture(["notes.txt": "as packed\n"])
        let edit = try await ArchiveMemberEditRig(fixture, name: "notes.txt")
        defer { edit.cleanup() }

        // Bytes nothing can vouch for are not the archive's, so no merge is offered from them.
        try edit.write("written by the compare window\n")
        edit.cache.keepBase(for: edit.pending.edit)
        #expect(edit.base == nil)

        let other = try await ArchiveMemberEditRig(
            try ArchiveZipFixture(["b.txt": "b"]),
            name: "b.txt"
        )
        defer { other.cleanup() }
        let server = VFSPath(
            backend: .sftp(SFTPLocation(host: "srv", username: "me")),
            path: "/b.txt"
        )
        other.cache.keepBase(for: EditedFile(
            destination: .remoteFile(server), temporaryURL: other.copy, name: "b.txt"
        ))
        #expect(other.base == nil, "RemoteFileCache keeps a server file's")

        let elsewhere = ArchivePreviewCache()
        elsewhere.keepBase(for: other.pending.edit)
        #expect(elsewhere.memberBase(ofCopy: other.copy) == nil, "no extraction this cache made")

        // The control: the same copy, through the cache that extracted it.
        other.cache.keepBase(for: other.pending.edit)
        #expect(readArchiveTestFile(other.base?.base) == "b")
    }

    @Test("a merge's version replaces the base, and a copy put back drops it")
    func adoptAndDrop() async throws {
        let fixture = try ArchiveZipFixture(["notes.txt": "as packed\n"])
        let edit = try await ArchiveMemberEditRig(fixture, name: "notes.txt")
        defer { edit.cleanup() }
        edit.cache.keepBase(for: edit.pending.edit)
        let first = try #require(edit.base)

        let merged = try #require(edit.cache.baseStore.keep(edit.copy))
        let stamp = try #require(ArchiveIdentity.current(ofFileAt: fixture.path))
        edit.cache.adoptBase(ofCopy: edit.copy, ArchiveMemberBase(base: merged, archive: stamp))
        #expect(edit.base?.base == merged)
        #expect(!FileManager.default.fileExists(atPath: first.base.path))

        edit.cache.dropBase(ofCopy: edit.copy)
        #expect(edit.base == nil)
        #expect(!FileManager.default.fileExists(atPath: merged.path))
    }

    /// The one call F4, ⏎, a user script and the compare window's Edit make as an edit begins.
    @Test("a host's watch on an edit watches the copy and keeps the base of either kind")
    func hostWatchKeepsTheBase() async throws {
        let host = StubPanelHost()
        let fixture = try ArchiveZipFixture(["notes.txt": "as packed\n"])
        let edit = try await ArchiveMemberEditRig(
            fixture, name: "notes.txt", cache: host.archivePreviewCache
        )
        defer {
            edit.cleanup()
            host.editedFiles.stopWatching(edit.copy)
        }
        host.watchEdit(edit.pending.edit)
        #expect(host.editedFiles.isWatching(edit.copy))
        #expect(readArchiveTestFile(edit.base?.base) == "as packed\n")
    }
}

/// The check over a real archive, through the extractor F4 extracts with (PLAN.md §M37 Slice 4).
@MainActor
@Suite("Archive member check, live")
struct ArchiveMemberCheckLiveTests {
    @Test("an archive nobody wrote is unmoved, and one rewritten around the member is same")
    func untouchedMember() async throws {
        let fixture = try ArchiveZipFixture(["notes.txt": "as packed\n", "other.txt": "other\n"])
        let edit = try await ArchiveMemberEditRig(fixture, name: "notes.txt")
        defer { edit.cleanup() }
        edit.cache.keepBase(for: edit.pending.edit)
        try edit.write("edited\n")
        #expect(edit.verdict(fixture) == .unmoved)

        // Another member's save, Dirnex's own included: the archive moved, the member did not.
        try fixture.repack(["notes.txt": "as packed\n", "other.txt": "other, edited\n"])
        #expect(edit.verdict(fixture) == .same)
    }

    @Test("a member another writer changed is different, and one taken out is unreadable")
    func changedAndGone() async throws {
        let fixture = try ArchiveZipFixture(["docs/notes.txt": "as packed\n", "keep.txt": "k"])
        let edit = try await ArchiveMemberEditRig(fixture, name: "notes.txt", in: "/docs")
        defer { edit.cleanup() }
        edit.cache.keepBase(for: edit.pending.edit)

        try fixture.repack(["docs/notes.txt": "AS PACKED\n", "keep.txt": "k"])
        #expect(edit.verdict(fixture) == .different(byteSize: 10))

        try fixture.repack(["keep.txt": "k"])
        #expect(edit.verdict(fixture) == .unreadable)
    }

    /// The milestone's own sentence: a member changed behind its edit merges and repacks with both
    /// edits in it. Every step but the window's take and the question is the shipped one: the cache's
    /// extraction and base, the check, the offer, the archive's version kept, the three reads, the
    /// merge's adoption, and the rewrite the question's Save Back runs.
    @Test("a member changed behind its edit merges and repacks with both edits in it")
    func mergesAndRepacks() async throws {
        let base = "one\ntwo\nthree\nfour\nfive\n"
        let fixture = try ArchiveZipFixture(["docs/notes.txt": base, "keep.txt": "k"])
        let edit = try await ArchiveMemberEditRig(fixture, name: "notes.txt", in: "/docs")
        defer { edit.cleanup() }
        edit.cache.keepBase(for: edit.pending.edit)
        try edit.write("one\nTWO\nthree\nfour\nfive\n")
        try fixture.repack(["docs/notes.txt": "one\ntwo\nthree\nfour\nFIVE\n", "keep.txt": "k"])

        let verdict = edit.verdict(fixture)
        let offered = await BrowserWindowController.archiveMergeBase(
            edit.base?.base, yours: edit.copy, verdict: verdict
        )
        #expect(offered == edit.base?.base)

        let check = BrowserWindowController.archiveMemberCheck(
            for: fixture.path, passphrase: nil, nameEncoding: nil
        )
        let theirs = try check.keep(edit.pending.innerPath, in: edit.cache.baseStore)
        #expect(readArchiveTestFile(theirs.base) == "one\ntwo\nthree\nfour\nFIVE\n")
        let documents = try BrowserWindowController.readMerge(
            base: try #require(edit.base).base, yours: edit.copy, theirs: theirs.base
        ).get()
        let merge = TextMerge(base: documents.base, yours: documents.yours, theirs: documents.theirs)
        #expect(merge.isResolved)
        try merge.result.encoded().write(to: edit.copy)

        // The window's first save: the archive's version is the base, so the save that carries
        // the merge back finds nothing more to say.
        var carried = 0
        let saving = BrowserWindowController.archiveMergeSaving(
            edit.pending.edit, theirs: theirs, cache: edit.cache
        ) { _, _ in carried += 1 }
        _ = await saving.carry?(nil)
        #expect(carried == 1)
        #expect(edit.base?.base == theirs.base)
        #expect(edit.verdict(fixture) == .unmoved)

        try ArchiveWriter.add(
            ArchiveWriteBackGroup(archivePath: fixture.path, items: [edit.pending]).additions,
            ofArchiveAt: fixture.path,
            undo: .none
        )
        #expect(try fixture.member("docs/notes.txt") == "one\nTWO\nthree\nfour\nFIVE\n")
        #expect(try fixture.member("keep.txt") == "k")
    }

    @Test("two moved members are read in one pass, each against its own base")
    func twoMembers() async throws {
        let fixture = try ArchiveZipFixture(["a.txt": "a\n", "docs/b.txt": "b\n"])
        let cache = ArchivePreviewCache()
        let first = try await ArchiveMemberEditRig(fixture, name: "a.txt", cache: cache)
        let second = try await ArchiveMemberEditRig(
            fixture,
            name: "b.txt",
            in: "/docs",
            cache: cache
        )
        defer {
            first.cleanup()
            second.cleanup()
        }
        cache.keepBase(for: first.pending.edit)
        cache.keepBase(for: second.pending.edit)
        try fixture.repack(["a.txt": "a\n", "docs/b.txt": "B, changed\n"])

        let verdicts = BrowserWindowController.archiveMemberCheck(
            for: fixture.path, passphrase: nil, nameEncoding: nil
        ).verdicts(for: [first, second].map {
            .init(innerPath: $0.pending.innerPath, base: $0.base)
        })
        #expect(verdicts == [.same, .different(byteSize: 11)])
    }
}
