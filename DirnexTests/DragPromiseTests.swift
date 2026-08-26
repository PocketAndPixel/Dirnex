import AppKit
import DirnexCore
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import Dirnex

/// Dragging a row whose bytes are on a server out into Finder, Mail or Teams (PLAN.md §M23 Slice 4).
///
/// A real drag *session* cannot be synthesized — a synthetic event is not a gesture, which this
/// project has already paid for twice (docs/NOTES.md ▸ AppKit) — so what is pinned here is
/// everything on this side of the drop: which rows get a promise, what the promise advertises,
/// what a mixed board looks like to us and to everybody else, and that the two delegate methods
/// AppKit dispatches **by selector** are actually there.
///
/// **What is deliberately not here is a test that drives the *reporting* alert.** A failed drag-out
/// keeps `runModal` (the user made a gesture and is waiting — docs/NOTES.md ▸ AppKit), so covering it
/// means hosting the pane in a real window, and a live pane in a window does real pane work in the
/// test host: measured over 17 full runs, the windowed variant took the suite from **9/9 green** to
/// 7/8, and every failure it caused landed in `PanelPassiveRefreshTests` — a suite that measures
/// whether anything repainted and is documented as starving on exactly this. The claim it was making
/// is kept below without a window: the completion handler is answered with an error and the
/// destination is left empty.
///
/// That last one is not ceremony. `NSFilePromiseProviderDelegate` is an `@objc` protocol dispatched
/// through `respondsToSelector:`, and this codebase has shipped a delegate method that compiled,
/// conformed and was never emitted (`QuickViewWebView`, docs/NOTES.md ▸ AppKit) — so the assertion
/// is by **selector string**, since `#selector(SomeProtocol.method)` resolves against the protocol
/// and would keep naming the right selector after the class stopped implementing it. The Swift
/// spelling `writePromiseTo:` and the Objective-C `writePromiseToURL:` differing is exactly the gap
/// that swallowed the earlier one.
@MainActor
@Suite("Drag promise")
struct DragPromiseTests {
    private static let remoteID = VFSBackendID("sftp://user@host")

    private struct StubBackend: VFSBackend {
        let id: VFSBackendID = .local
        let capabilities: VFSCapabilities = [.read, .write]

        func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }
        func stat(at path: VFSPath) throws -> FileEntry { throw VFSError.notFound(path) }
    }

    private func entry(_ path: VFSPath, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: 4096,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 11
        )
    }

    private func local(_ path: String) -> FileEntry { entry(.local(path)) }
    private func remote(_ path: String, kind: FileEntry.Kind = .file) -> FileEntry {
        entry(VFSPath(backend: Self.remoteID, path: path), kind: kind)
    }

    private func board(_ name: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("com.dirnex.tests.promise.\(name)"))
        board.clearContents()
        return board
    }

    private func pane() -> PanelViewController {
        PanelViewController(
            backend: StubBackend(),
            restoration: nil,
            defaultPath: .local("/tmp"),
            restorationKey: nil
        )
    }

    /// A pane wired to a real `RemoteFileCache` over `backend` — the shape a fulfilment needs,
    /// since the cache is the window's and a hostless pane starts no transfer at all.
    ///
    /// **The host must be kept alive by the caller**: `PanelViewController.host` is `weak`, so
    /// binding it to `_` deallocates it before the fetch starts and every test then measures the
    /// no-host path instead of the one it named. Each test below holds it by asserting on its cache,
    /// which is a claim worth making anyway.
    private func hostedPane(
        _ backend: any VFSBackend,
        in window: NSWindow? = nil
    ) -> (PanelViewController, StubPanelHost) {
        let pane = PanelViewController(
            backend: backend,
            restoration: nil,
            defaultPath: VFSPath(backend: backend.id, path: "/"),
            restorationKey: nil
        )
        let host = StubPanelHost()
        pane.host = host
        if let window {
            window.contentViewController = pane
            pane.loadViewIfNeeded()
        }
        return (pane, host)
    }

    /// Wait for `answered` to be filled in. Polls with `await Task.sleep` rather than spinning the
    /// run loop: the transfer's result lands through a continuation, which a run-loop spin never
    /// resumes — the trap this project has already paid for (docs/NOTES.md ▸ Testing).
    private func settle(_ answered: Answer) async {
        for _ in 0..<200 where answered.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: - Which rows are promised

    @Test("only a file on a server is promised")
    func promisedRows() {
        #expect(RemoteFilePromiseProvider.canPromise(remote("/srv/report.pdf")))
        // A local row already has real bytes and a real URL: promising it would put a second,
        // slower path in front of a file Finder can already take.
        #expect(!RemoteFilePromiseProvider.canPromise(local("/tmp/a.txt")))
    }

    @Test("a remote folder is not promised — a promise is one file")
    func remoteFolderIsNotPromised() {
        // Deliberately out of scope (PLAN.md §M23): a recursive fetch behind a Finder drop has no
        // progress surface and no way to stop it. The row still drags inside Dirnex on its payload.
        #expect(!RemoteFilePromiseProvider.canPromise(remote("/srv/photos", kind: .directory)))

        let writers = PanelPasteboard.dragWriters(
            for: [remote("/srv/photos", kind: .directory)], promisedTo: pane()
        )
        #expect(writers.count == 1)
        #expect(!(writers.first is NSFilePromiseProvider))
    }

    @Test("the promised type comes off the extension, and an extension-less name still drags")
    func promisedFileType() {
        #expect(RemoteFilePromiseProvider.fileType(for: "report.pdf") == UTType.pdf.identifier)
        // `NSFilePromiseProvider` **raises** for a type conforming to neither `public.data` nor
        // `public.directory`, and a name with no extension resolves to no type at all — so the
        // floor is what stops a file called README from throwing while its neighbour drags fine.
        #expect(RemoteFilePromiseProvider.fileType(for: "README") == UTType.data.identifier)
        let resolved = try? #require(UTType(RemoteFilePromiseProvider.fileType(for: "x.qqzz")))
        #expect(resolved?.conforms(to: .data) == true)
    }

    // MARK: - What goes on the board

    @Test("a promised row still carries the payload, so the drag reads the same inside Dirnex")
    func promiseCarriesPayload() throws {
        let board = board("remote")
        #expect(
            PanelPasteboard.writeDrag([remote("/srv/report.pdf")], promisedTo: pane(), to: board)
        )

        let item = try #require(board.pasteboardItems?.first)
        #expect(item.data(forType: PanelPasteboard.locationsType) != nil)
        #expect(PanelPasteboard.payloads(in: board).map(\.name) == ["report.pdf"])
        // Nothing another app could mistake for a file already on this Mac.
        #expect(PanelPasteboard.fileURLs(in: board).isEmpty)
    }

    @Test("a mixed drag is one board: every row to us, the local subset to everybody else")
    func mixedDrag() throws {
        let board = board("mixed")
        let rows = [local("/tmp/x.txt"), remote("/srv/big.bin"), local("/tmp/y.txt")]
        #expect(PanelPasteboard.writeDrag(rows, promisedTo: pane(), to: board))

        #expect(PanelPasteboard.payloads(in: board).map(\.name) == ["x.txt", "big.bin", "y.txt"])
        #expect(PanelPasteboard.fileURLs(in: board).map(\.lastPathComponent) == ["x.txt", "y.txt"])
        // The promise has to be advertised at board level or no other app offers to take the drop.
        let types = try #require(board.types).map(\.rawValue)
        #expect(types.contains("com.apple.pasteboard.promised-file-content-type"))
    }

    @Test("an archive member goes on no board at all, drag or clipboard")
    func archiveMemberIsNotDragged() {
        let member = entry(
            VFSPath(backend: VFSBackendID.archive(forArchiveAt: "/tmp/a.zip"), path: "/inner.txt")
        )
        #expect(PanelPasteboard.dragWriters(for: [member], promisedTo: pane()).isEmpty)
        #expect(!PanelPasteboard.writeDrag([member], promisedTo: pane(), to: board("archive")))
    }

    // MARK: - The delegate AppKit dispatches by selector

    @Test("the pane implements both promise callbacks under the selectors AppKit sends")
    func delegateSelectorsExist() {
        let pane = pane()
        #expect(pane.responds(to: NSSelectorFromString("filePromiseProvider:fileNameForType:")))
        #expect(pane.responds(to: NSSelectorFromString(
            "filePromiseProvider:writePromiseToURL:completionHandler:"
        )))
    }

    @Test("a promise that cannot be fulfilled answers with an error, never with silence")
    func unfulfillablePromiseStillAnswers() throws {
        // The failure the plan calls the hard part, and the one nothing else in the app has: a
        // promise runs **outside the queue bar**, so the receiving app is blocked on this callback
        // and there is no queue row to look at. Unanswered is a beachball in somebody else's app;
        // answered with `nil` is a **zero-byte file** under the right name, which is worse, because
        // nothing anywhere then says the bytes are missing.
        //
        // The pane here has no window controller, so the fetch funnel starts nothing at all — which
        // is exactly the shape of a path that returns early and reports to nobody.
        let pane = pane()
        let provider = try #require(RemoteFilePromiseProvider.promise(
            for: remote("/srv/report.pdf"), payload: Data("{}".utf8), delegate: pane
        ))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-promise-\(UUID().uuidString).pdf")
        let answered = Answer()
        pane.filePromiseProvider(provider, writePromiseTo: destination) { answered.record($0) }

        #expect(answered.count == 1)
        #expect(answered.error != nil)
        // The other half, and the one that decides whether the receiving app is misled: an answer
        // that is not `nil` and a destination that stays empty. Answering `nil` here would leave a
        // **zero-byte file** under the right name, with nothing anywhere saying the bytes never came.
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("a promise Dirnex did not build is answered too")
    func foreignProviderStillAnswers() {
        // Unreachable — only `RemoteFilePromiseProvider.promise` builds one — and answered rather
        // than dropped for the same reason: the caller is blocked either way.
        let pane = pane()
        let answered = Answer()
        pane.filePromiseProvider(
            NSFilePromiseProvider(fileType: UTType.data.identifier, delegate: pane),
            writePromiseTo: URL(fileURLWithPath: "/tmp/dirnex-promise-foreign.dat")
        ) { answered.record($0) }
        #expect(answered.count == 1)
        #expect(answered.error != nil)
    }

    /// What the completion handler was told, and how often. The **count** is half the claim: a
    /// promise answered twice is as wrong as one answered never, and only a counter separates them.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(any Error)?] = []

        func record(_ error: (any Error)?) { lock.withLock { recorded.append(error) } }
        var count: Int { lock.withLock { recorded.count } }
        var isEmpty: Bool { lock.withLock { recorded.isEmpty } }
        var error: (any Error)? { lock.withLock { recorded.first.flatMap { $0 } } }
    }

    // MARK: - The bytes actually landing

    @Test("a fulfilled promise puts the real bytes where the receiving app asked for them")
    func fulfilledPromiseWritesTheFile() async throws {
        // The whole substance of the slice, and the one claim no other test here reaches: the fetch
        // runs, and the file is placed at the URL the promise machinery chose — not at the cache's
        // own path, which is where the bytes actually land first.
        let backend = CountingBackend(outcome: .succeed)
        let (pane, host) = hostedPane(backend)
        let entry = Fixture.entry("report.pdf")
        let provider = try #require(RemoteFilePromiseProvider.promise(
            for: entry, payload: Data("{}".utf8), delegate: pane
        ))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-promise-\(UUID().uuidString)")
            .appendingPathComponent(entry.name)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let answered = Answer()
        pane.filePromiseProvider(provider, writePromiseTo: destination) { answered.record($0) }
        await settle(answered)

        #expect(answered.count == 1)
        #expect(answered.error == nil)
        let landed = try String(contentsOf: destination, encoding: .utf8)
        #expect(landed == CountingBackend.body)
        // The copy stays in the cache, which is what makes dragging the same row out twice — or
        // previewing it and then dragging it — cost one transfer rather than two.
        #expect(host.remoteFileCache.cachedURL(for: entry) != nil)
    }

    @Test("a stopped fetch answers too, rather than leaving the other app waiting")
    func stoppedPromiseStillAnswers() async throws {
        // `RemoteFetchPrompt` deliberately reports nothing when the user presses Stop — there is
        // nothing to tell somebody about their own answer. That is right for every gesture but this
        // one, which is holding another application's completion handler open, and it is why
        // `onCancel` exists at all.
        let (pane, host) = hostedPane(CountingBackend(outcome: .block))
        let provider = try #require(RemoteFilePromiseProvider.promise(
            for: Fixture.entry("report.pdf"), payload: Data("{}".utf8), delegate: pane
        ))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-promise-stop-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: destination) }

        let answered = Answer()
        pane.filePromiseProvider(provider, writePromiseTo: destination) { answered.record($0) }
        for _ in 0..<200 where host.remoteFileCache
            .previewFetchProgress(for: Fixture.entry("report.pdf")) == nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        host.remoteFileCache.stopPreviewFetch()
        await settle(answered)

        #expect(answered.count == 1)
        #expect(answered.error is CancellationError)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("the promised name is the row's own")
    func promisedName() throws {
        let pane = pane()
        let provider = try #require(RemoteFilePromiseProvider.promise(
            for: remote("/srv/report.pdf"), payload: Data("{}".utf8), delegate: pane
        ))
        #expect(pane.filePromiseProvider(provider, fileNameForType: provider.fileType)
            == "report.pdf")
    }
}
