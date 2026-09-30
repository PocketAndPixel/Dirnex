import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A directory sync with one side on a **real server** (PLAN.md §M25 Slice 5c), driving the actual
/// `SFTPProcessTransport` → `SFTPBackend` → `SFTPListingParser` chain rather than any double.
///
/// It is the half no headless suite can reach, and there are two claims in it. That the comparison
/// runs at all across two backends — until this slice the gate refused a remote side outright — and
/// that the numbers it rests on are the *server's*: a file uploaded with byte-exact metadata still
/// lists back at minute resolution over `sftp`, which is precisely why comparing by size is the
/// honest thing to offer and comparing by date is not.
///
/// Gated on the same config file as `SFTPLiveIntegrationTests`, so CI — which has no server — skips
/// it. Every fixture is minted here under a UUID-named subtree; nothing has to be prepared on the
/// server, which is the precondition `PackLiveIntegrationTests` shipped without and failed on.
@Suite("Sync live integration", .enabled(if: SFTPLiveEnvironment.current != nil), .serialized)
struct SyncLiveIntegrationTests {
    private struct Fixture {
        let backend: SFTPBackend
        let remoteRoot: VFSPath
        let localRoot: URL
    }

    /// A matching pair of trees, one here and one on the server, differing in exactly one file.
    private func fixture() throws -> Fixture {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        let backend = SFTPBackend(location: config.location, transport: transport)
        let name = "sync-\(UUID().uuidString)"

        let localRoot = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: localRoot.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try Data("same".utf8).write(to: localRoot.appendingPathComponent("top.txt"))
        // Same length, different bytes — the pair *only* a content comparison can tell apart, and
        // the reason the mode is worth its downloads (M25 Slice 5d).
        try Data("aaaaa".utf8).write(to: localRoot.appendingPathComponent("same-size.bin"))
        try Data("same".utf8).write(to: localRoot.appendingPathComponent("docs/guide.md"))
        try Data("the local body".utf8).write(to: localRoot.appendingPathComponent("docs/note.txt"))
        try Data("here only".utf8).write(to: localRoot.appendingPathComponent("only-here.txt"))

        let remoteRoot = VFSPath(backend: .sftp(config.location), path: config.remotePath)
            .appending(name)
        try backend.createDirectory(at: remoteRoot)
        try backend.createDirectory(at: remoteRoot.appending("docs"))
        for (relative, body) in [
            ("top.txt", "same"),
            ("same-size.bin", "bbbbb"),
            ("docs/guide.md", "same"),
            ("docs/note.txt", "a body of another length entirely"),
            ("only-there.txt", "there only")
        ] {
            let staged = localRoot.appendingPathComponent("staged")
            try Data(body.utf8).write(to: staged)
            var destination = remoteRoot
            for component in relative.split(separator: "/") {
                destination = destination.appending(String(component))
            }
            try backend.copyFile(
                at: .local(staged.path),
                to: destination,
                progress: { _ in },
                isCancelled: { false }
            )
        }
        try FileManager.default.removeItem(at: localRoot.appendingPathComponent("staged"))
        return Fixture(backend: backend, remoteRoot: remoteRoot, localRoot: localRoot)
    }

    /// An hour ago, on a whole minute plus **37 seconds**.
    ///
    /// Deterministic on purpose: with an arbitrary "now" the seconds-in-the-minute are whatever the
    /// clock happened to hold, so a run landing near :00 would see the listing agree and the
    /// assertions below would pass for the wrong reason about once in thirty. The hour keeps it well
    /// inside the window where `ls` still prints a time of day at all — past about six months it
    /// prints a year instead and the drift becomes the file's whole time of day.
    static func anchoredStamp() -> Date {
        let now = floor(Date().timeIntervalSince1970)
        return Date(timeIntervalSince1970: now - now.truncatingRemainder(dividingBy: 60) - 3600 + 37)
    }

    /// What ``SyncSide`` rests on over SFTP: the server walks its own tree over the exec channel and
    /// hands back a **complete** subtree, so a scan costs one command instead of a connection per
    /// directory (measured 76 ms against 1010 ms for seventeen directories on loopback).
    ///
    /// Asserted directly because it is invisible from the comparison's own result — the rows are the
    /// same either way, and the only difference is how many times this Mac connected.
    ///
    /// **Both branches are claims**, which is what keeps this test honest against whatever server the
    /// config names: an account confined by `ForceCommand internal-sftp` has no exec channel at all,
    /// and there the shortcut must answer `nil` — "walk instead" — rather than a partial listing a
    /// mirror would delete files over. Which branch applies is decided by an independent probe
    /// rather than by the code under test, or the test would agree with itself whichever way it went.
    @Test("the server walks its own tree completely, or says it cannot")
    func theSubtreeShortcutAnswers() async throws {
        try await offCooperativePool {
            let config = try #require(SFTPLiveEnvironment.current)
            let transport = SFTPProcessTransport(
                location: config.location,
                authentication: .key(identityFile: config.identityFile)
            )
            // Hand-minted, so what is measured is the account rather than our own agreement with it:
            // an `sftp`-only account answers exec requests with prose on stdout instead of this.
            let echoed = try? transport.runCommand(
                "/usr/bin/env echo dirnex-exec-probe",
                isCancelled: { false }
            )
            let hasExecChannel = echoed?.contains("dirnex-exec-probe") == true

            let fixture = try fixture()
            defer { cleanUp(fixture) }
            let answered = try fixture.backend.subtreeListing(
                at: fixture.remoteRoot,
                isCancelled: { false }
            )

            guard hasExecChannel else {
                #expect(
                    answered == nil,
                    "an account with no exec channel must fall back to the walk, not half-answer"
                )
                return
            }
            let listing = try #require(
                answered,
                "the exec channel answers, and the shortcut did not"
            )
            #expect(listing.isComplete)
            let names = listing.entries.map(\.name)
            #expect(names.contains("note.txt"), "the shortcut stopped short of the second level")
            #expect(names.contains("only-there.txt"))
        }
    }

    private func cleanUp(_ fixture: Fixture) {
        try? fixture.backend.removeItem(at: fixture.remoteRoot)
        try? FileManager.default.removeItem(at: fixture.localRoot)
    }

    /// The whole slice, end to end: a local tree against a server's, compared by size, with the two
    /// sides walked through two different backends.
    @Test("a local tree and a server's compare across two backends")
    func comparesAcrossTwoBackends() async throws {
        try await offCooperativePool {
            let fixture = try fixture()
            defer { cleanUp(fixture) }

            let results = try DirectorySync.compare(
                left: .local(fixture.localRoot.path),
                right: fixture.remoteRoot,
                leftBackend: LocalBackend(),
                rightBackend: fixture.backend,
                comparison: .size
            )

            // `same-size.bin` is deliberately absent: by size the two are equal, which is exactly
            // what the content test below goes on to disagree with.
            #expect(results.map(\.relativePath).sorted()
                == ["docs/note.txt", "only-here.txt", "only-there.txt"])
            let byPath = Dictionary(uniqueKeysWithValues: results.map { ($0.relativePath, $0) })
            #expect(byPath["only-here.txt"]?.status == .leftOnly)
            #expect(byPath["only-there.txt"]?.status == .rightOnly)
            // The size difference is real and is deliberately **not** ranked: neither side's stamp
            // could have decided which is newer.
            #expect(byPath["docs/note.txt"]?.status == .differ)
            // The files that really are the same are omitted, which is the claim a mirror rests on:
            // an equal file must not be copied over the network for nothing.
            #expect(!results.contains { $0.relativePath == "top.txt" })
            #expect(!results.contains { $0.relativePath == "docs/guide.md" })
        }
    }

    /// Why comparing by date is withdrawn, measured rather than asserted from a man page: a file is
    /// uploaded carrying its modification time exactly (M25 Slice 1) and the server's own listing
    /// hands it back **coarsened**. Comparing the two sides by that stamp would report a difference
    /// in a file nothing has touched.
    @Test("the server's listing loses the seconds a transfer carried exactly")
    func theListingIsCoarserThanTheTransfer() async throws {
        try await offCooperativePool {
            let fixture = try fixture()
            defer { cleanUp(fixture) }

            let source = fixture.localRoot.appendingPathComponent("top.txt")
            let stamped = Self.anchoredStamp()
            try FileManager.default.setAttributes(
                [.modificationDate: stamped],
                ofItemAtPath: source.path
            )
            let destination = fixture.remoteRoot.appending("stamped.txt")
            try fixture.backend.copyFile(
                at: .local(source.path),
                to: destination,
                progress: { _ in },
                isCancelled: { false }
            )

            let listed = try fixture.backend.stat(at: destination).modificationDate
            let drift = abs(listed.timeIntervalSince(stamped))
            // The stamp carries a known 37 seconds and the listing rounds to the minute, so the
            // drift is that 37 — eighteen times `DirectorySync.defaultTolerance`, and entirely the
            // listing's doing: the transfer itself carried the time exactly (M25 Slice 1).
            #expect(drift > DirectorySync.defaultTolerance)
            #expect(drift < 60)
        }
    }

    /// Comparing that same pair by **date** is what the sheet no longer offers, and this is why: the
    /// two sides are byte-identical and the clock says otherwise.
    @Test("comparing by date reports a difference in a file nothing has touched")
    func comparingByDateIsDishonest() async throws {
        try await offCooperativePool {
            let fixture = try fixture()
            defer { cleanUp(fixture) }
            let stamped = Self.anchoredStamp()
            let source = fixture.localRoot.appendingPathComponent("top.txt")
            try FileManager.default.setAttributes(
                [.modificationDate: stamped],
                ofItemAtPath: source.path
            )
            try fixture.backend.copyFile(
                at: .local(source.path),
                to: fixture.remoteRoot.appending("top.txt"),
                progress: { _ in },
                isCancelled: { false }
            )

            let bySize = try DirectorySync.compare(
                left: .local(fixture.localRoot.path),
                right: fixture.remoteRoot,
                leftBackend: LocalBackend(),
                rightBackend: fixture.backend,
                comparison: .size
            )
            let byDate = try DirectorySync.compare(
                left: .local(fixture.localRoot.path),
                right: fixture.remoteRoot,
                leftBackend: LocalBackend(),
                rightBackend: fixture.backend,
                comparison: .sizeAndDate
            )
            #expect(!bySize.contains { $0.relativePath == "top.txt" })
            #expect(byDate.contains { $0.relativePath == "top.txt" })
            // And the honest comparison is not simply blind: the file that really differs is found
            // by both, so "compare by size" has not quietly become "compare nothing".
            #expect(bySize.contains { $0.relativePath == "docs/note.txt" })
        }
    }

    // MARK: - Comparing contents across two backends (M25 Slice 5d)

    /// The whole of Slice 5d against a real server, in the order the sheet runs it: walk once,
    /// name the pairs whose bytes decide the answer, fetch **those** through the real transport,
    /// and re-answer the same rows with the copies that arrived.
    ///
    /// The claim no cheaper comparison can make is `same-size.bin`: five bytes on both sides and
    /// different bytes, so a size scan calls it identical and only reading it disagrees. And the
    /// claim that keeps it affordable is what is *not* fetched — the pair whose sizes already
    /// differ, the one-sided files, and the folder are in no candidate set and cost no transfer.
    @Test(
        "a content comparison across two backends finds what size cannot, and fetches only what it reads"
    )
    func comparesContentsAcrossTwoBackends() async throws {
        try await offCooperativePool {
            let fixture = try fixture()
            defer { cleanUp(fixture) }
            let localRoot = VFSPath.local(fixture.localRoot.path)

            // Phase one: one walk, every row, classified by size.
            let surveyed = try DirectorySync.survey(
                left: localRoot,
                right: fixture.remoteRoot,
                leftBackend: LocalBackend(),
                rightBackend: fixture.backend
            )
            let candidates = DirectorySync.contentCandidates(in: surveyed)
            #expect(
                candidates.map(\.relativePath).sorted() == [
                    "docs/guide.md",
                    "same-size.bin",
                    "top.txt"
                ],
                "only the same-size regular-file pairs are worth reading"
            )

            // Phase two: fetch the server's half of each candidate, exactly as the gesture does,
            // and hand the comparison the map rather than the objects on the server.
            let staging = fixture.localRoot.appendingPathComponent("staged", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var localPaths: [VFSPath: String] = [:]
            for candidate in candidates {
                let remote = try #require(candidate.right)
                // One directory per row, for the reason `MaterializeRunner` gives: two candidates
                // can share a name from two prefixes.
                let directory = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let copy = directory.appendingPathComponent(remote.name)
                try fixture.backend.copyFile(
                    at: remote.path,
                    to: .local(copy.path),
                    progress: { _ in },
                    isCancelled: { false }
                )
                localPaths[remote.path] = copy.path
            }

            let rows = try DirectorySync.recompare(
                surveyed,
                between: localRoot.backend,
                and: fixture.remoteRoot.backend,
                comparison: .content,
                contentsEqual: { left, right in
                    let paths = MaterializedPaths(localPaths)
                    return try ByteComparator.localFilesEqual(
                        try #require(paths.localPath(for: left)),
                        try #require(paths.localPath(for: right))
                    )
                }
            )

            #expect(rows.map(\.relativePath).sorted()
                == ["docs/note.txt", "only-here.txt", "same-size.bin", "only-there.txt"].sorted())
            let byPath = Dictionary(uniqueKeysWithValues: rows.map { ($0.relativePath, $0.status) })
            // The row size could not see, found by its bytes — and still not ranked, because
            // neither listing keeps a clock that could say which came later.
            #expect(byPath["same-size.bin"] == .differ)
            // The narrowness half: the pairs that really are byte-identical were read and dropped.
            #expect(!rows.contains { $0.relativePath == "top.txt" })
            #expect(!rows.contains { $0.relativePath == "docs/guide.md" })
        }
    }
}
