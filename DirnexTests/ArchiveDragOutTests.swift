import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A file inside an archive dragged out to another application (PLAN.md §M36 Slice 2).
///
/// A drag session cannot be synthesized, so these pin the three things on this side of the drop,
/// against real archives: which members are offered (decision A — a locked archive's are not), that
/// Finder's promise is answered with the member's bytes, and that the handoff to every other app
/// extracts where it would have downloaded. The archives are packed off the main actor, the lesson
/// `ArchiveAddReachTests` paid for (docs/NOTES.md ▸ Testing).
@MainActor
@Suite("Archive drag out")
struct ArchiveDragOutTests {
    private static let passphrase = ArchivePassphrase("correct horse")

    private func member(_ archive: String, _ inner: String, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: .archive(forArchiveAt: archive), path: inner),
            name: (inner as NSString).lastPathComponent,
            kind: kind,
            byteSize: 5,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 4
        )
    }

    private func hostedPane() -> (PanelViewController, StubPanelHost) {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: .local("/tmp"),
            restorationKey: nil
        )
        let host = StubPanelHost()
        pane.host = host
        return (pane, host)
    }

    // MARK: - Which members are offered

    @Test("a member of a plain archive is extracted for another app")
    func plainMemberIsOffered() async throws {
        let archive = try await DragOutArchive.plain(["one.txt": "first"])
        defer { archive.remove() }
        let (pane, host) = hostedPane()
        let row = member(archive.path, "/one.txt")

        #expect(pane.dragOutRoutes(for: [row])[row.path] == .extract)
        withExtendedLifetime(host) {}
    }

    /// Decision A, against a real AES-256 archive: the lock is the header's encryption flag and the
    /// session's passphrase store, and nothing else.
    @Test("an encrypted archive's member is offered only once its passphrase is held")
    func encryptedMemberWaitsForItsPassphrase() async throws {
        let archive = try await DragOutArchive.encrypted(["one.txt": "first"], Self.passphrase)
        defer { archive.remove() }
        let (pane, host) = hostedPane()
        let row = member(archive.path, "/payload/one.txt")

        #expect(pane.dragOutRoutes(for: [row])[row.path] == .insideDirnexOnly(.lockedArchive))
        host.archivePassphrases.remember(Self.passphrase, forArchiveAt: archive.path)
        #expect(pane.dragOutRoutes(for: [row])[row.path] == .extract)
    }

    // MARK: - Finder's promise

    @Test("Finder's promise is answered once, with the member's bytes where Finder asked")
    func promiseLandsTheMember() async throws {
        let archive = try await DragOutArchive.plain(["one.txt": "first", "two.txt": "second"])
        defer { archive.remove() }
        let (pane, host) = hostedPane()
        let row = member(archive.path, "/two.txt")
        let destination = archive.directory.appendingPathComponent("dropped/two.txt")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let answered = PromiseAnswer()
        let provider = RemoteFilePromiseProvider.promise(
            for: row, payload: Data("{}".utf8), delegate: pane
        )
        pane.filePromiseProvider(provider, writePromiseTo: destination) { answered.record($0) }

        #expect(await Self.settle { !answered.isEmpty })
        #expect(answered.count == 1)
        #expect(answered.error == nil)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "second")
        // The extraction is the window's own, so a later preview or drag of the member costs nothing.
        #expect(host.archivePreviewCache.cachedURL(
            for: ArchiveMember(archivePath: archive.path, innerPath: "/two.txt")
        ) != nil)
    }

    @Test("an encrypted member's promise uses the passphrase the session holds, and asks for none")
    func promiseUsesTheHeldPassphrase() async throws {
        let archive = try await DragOutArchive.encrypted(["one.txt": "first"], Self.passphrase)
        defer { archive.remove() }
        let (pane, host) = hostedPane()
        host.archivePassphrases.remember(Self.passphrase, forArchiveAt: archive.path)
        let destination = archive.directory.appendingPathComponent("one.txt")

        let answered = PromiseAnswer()
        let provider = RemoteFilePromiseProvider.promise(
            for: member(archive.path, "/payload/one.txt"), payload: Data("{}".utf8), delegate: pane
        )
        pane.filePromiseProvider(provider, writePromiseTo: destination) { answered.record($0) }

        #expect(await Self.settle { !answered.isEmpty })
        #expect(answered.error == nil)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "first")
    }

    /// The path that starts nothing still answers, and answers with an error rather than `nil`,
    /// which would leave a zero-byte file under the right name (`DragPromiseTests` says why).
    @Test("a promise a pane cannot extract is answered with an error and leaves nothing behind")
    func unextractablePromiseStillAnswers() {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: .local("/tmp"),
            restorationKey: nil
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-member-\(UUID().uuidString).txt")
        let answered = PromiseAnswer()
        let provider = RemoteFilePromiseProvider.promise(
            for: member("/tmp/absent.zip", "/x.txt"), payload: Data("{}".utf8), delegate: pane
        )
        pane.filePromiseProvider(provider, writePromiseTo: destination) { answered.record($0) }

        #expect(answered.count == 1)
        #expect(answered.error != nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Every other app

    @Test("over another app the member is extracted and its file URL handed over")
    func handoffExtractsTheMember() async throws {
        let archive = try await DragOutArchive.plain(["one.txt": "first"])
        defer { archive.remove() }
        let (pane, host) = hostedPane()
        let row = member(archive.path, "/one.txt")
        let routes = pane.dragOutRoutes(for: [row])
        let board = NSPasteboard(name: NSPasteboard.Name("app.dirnex.tests.member-handoff"))
        board.clearContents()

        let controller = RemoteDragHandoffController(
            board: board,
            entries: [row],
            cache: host.remoteFileCache,
            backend: CompositeBackend(local: LocalBackend()),
            holdLimit: .seconds(30),
            surfaceUnderPointer: { .otherApp(processID: 20) },
            showStatus: { _ in },
            onLanded: {},
            onFailure: { _ in },
            offer: DragOutOffer(
                routes: routes,
                extractions: pane.dragOutExtractions(for: [row], routes: routes),
                alreadyHere: { _ in nil },
                onLockedRowsLeaving: {}
            )
        )
        controller.pointerMoved()

        // The read holds until the extraction lands, as it would for a download.
        let read = try #require(board.pasteboardItems?.first?.string(forType: .fileURL))
        let url = try #require(URL(string: read))
        #expect(try String(contentsOf: url, encoding: .utf8) == "first")
        // Dirnex's own drop still reads the payload, so it never waits on this.
        #expect(PanelPasteboard.payloads(in: board).map(\.path) == [row.path])
        withExtendedLifetime(controller) {}
    }

    /// Decision A's other half: the row stays behind, and the user is told once, at the moment it
    /// stayed behind — not for a drag that never leaves Dirnex, and not on every move.
    @Test("a locked member is mentioned once, the first time the pointer is over another app")
    func lockedRowIsMentionedOnce() {
        let row = member("/tmp/locked.zip", "/x.txt")
        var surface = RemoteDragHandoff.Surface.neutral
        var mentions = 0
        let board = NSPasteboard(name: NSPasteboard.Name("app.dirnex.tests.member-locked"))
        board.clearContents()
        let controller = RemoteDragHandoffController(
            board: board,
            entries: [row],
            cache: RemoteFileCache(),
            backend: CompositeBackend(local: LocalBackend()),
            surfaceUnderPointer: { surface },
            showStatus: { _ in },
            onLanded: {},
            onFailure: { _ in },
            offer: DragOutOffer(
                routes: [row.path: .insideDirnexOnly(.lockedArchive)],
                extractions: [:],
                alreadyHere: { _ in nil },
                onLockedRowsLeaving: { mentions += 1 }
            )
        )

        controller.pointerMoved()
        #expect(mentions == 0)
        surface = .finder(processID: 10)
        controller.pointerMoved()
        #expect(mentions == 1)
        surface = .otherApp(processID: 20)
        controller.pointerMoved()
        #expect(mentions == 1)
    }

    // MARK: - Helpers

    private static func settle(
        within budget: Duration = .seconds(60),
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}

/// What a promise's completion handler was told, and how often (`DragPromiseTests` has the twin).
private final class PromiseAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(any Error)?] = []

    func record(_ error: (any Error)?) { lock.withLock { recorded.append(error) } }
    var count: Int { lock.withLock { recorded.count } }
    var isEmpty: Bool { lock.withLock { recorded.isEmpty } }
    var error: (any Error)? { lock.withLock { recorded.first.flatMap { $0 } } }
}

/// A real archive to drag members out of, packed off the main actor.
private struct DragOutArchive: Sendable {
    let directory: URL
    let path: String

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// A zip `bsdtar` packed, with `files` at its root.
    static func plain(_ files: [String: String]) async throws -> DragOutArchive {
        try await BlockingWork.run { () -> Result<DragOutArchive, any Error> in
            Result {
                let archive = try staged(files)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
                process.arguments = [
                    "-c",
                    "--format",
                    "zip",
                    "-f",
                    archive.path,
                    "-C",
                    archive.directory.appendingPathComponent("payload").path
                ]
                    + files.keys.sorted()
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                return archive
            }
        }.get()
    }

    /// An AES-256 zip written by the app's own encrypted writer, with `files` under `payload/`.
    static func encrypted(
        _ files: [String: String],
        _ passphrase: ArchivePassphrase
    ) async throws -> DragOutArchive {
        try await BlockingWork.run { () -> Result<DragOutArchive, any Error> in
            Result {
                let archive = try staged(files)
                try EncryptedArchiveWriter.write(
                    items: try ArchiveSourceEnumerator.items(
                        inDirectory: archive.directory.path, names: ["payload"]
                    ),
                    toArchiveAt: archive.path,
                    encryption: .aes256,
                    passphrase: passphrase
                )
                return archive
            }
        }.get()
    }

    private static func staged(_ files: [String: String]) throws -> DragOutArchive {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveDragOut-\(UUID().uuidString)")
        let payload = directory.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: payload.appendingPathComponent(name))
        }
        return DragOutArchive(
            directory: directory,
            path: directory.appendingPathComponent("pkg.zip").path
        )
    }
}
