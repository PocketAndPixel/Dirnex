import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The sentence a finished copy leaves on the status line (PLAN.md §M25 Slice 5b).
///
/// Pure and window-free on purpose: the parts worth pinning are *what it says* and *where it points*,
/// and a test that hosts a live pane makes it do real pane work and destabilizes its neighbours
/// (docs/NOTES.md ▸ Testing).
@Suite("Metadata loss sentence")
struct MetadataLossSentenceTests {
    private func loss(_ aspects: Set<RemoteMetadataAspect>, _ count: Int = 3) -> RemoteMetadataLoss {
        RemoteMetadataLoss(aspects: aspects, itemCount: count)
    }

    private func sentence(_ aspects: Set<RemoteMetadataAspect>, _ count: Int = 3) -> String {
        BrowserWindowController.metadataLossSentence(for: loss(aspects, count))
    }

    // MARK: - What it says

    @Test("the four aspects collapse into the two families a user can act on")
    func aspectsCollapseIntoTwoFamilies() {
        // The carry has to tell `mode` from `specialModeBits` (only an explicit `chmod` reaches the
        // special ones) and `modificationTime` from `accessTime` (only `-p` carries an atime); a
        // reader can act on neither distinction, so the line does not draw it.
        #expect(sentence([.mode]) == sentence([.specialModeBits]))
        #expect(sentence([.mode, .specialModeBits]) == sentence([.mode]))
        #expect(sentence([.modificationTime]) == sentence([.accessTime]))
    }

    @Test("each family says something different, and both together say a third thing")
    func familiesAreDistinguished() {
        let permissions = sentence([.mode])
        let dates = sentence([.modificationTime])
        let both = sentence([.mode, .modificationTime])
        #expect(permissions != dates)
        #expect(both != permissions)
        #expect(both != dates)
    }

    @Test("an aspect in neither family still produces a sentence")
    func unknownAspectIsStillWorded() {
        // The catch-all is unreachable today — `RemoteMetadataLoss` is never built empty — and it
        // exists so a *later* aspect landing in neither family degrades to a true sentence rather
        // than to an empty status line.
        #expect(!BrowserWindowController.metadataLossSentence(
            for: RemoteMetadataLoss(aspects: [], itemCount: 1)
        ).isEmpty)
    }

    @Test("the count reaches the sentence")
    func countIsInterpolated() {
        // Not a wording assertion — the app test target inherits the developer's own `AppleLanguages`
        // pin, so asserting English text fails on a machine set to Russian (docs/NOTES.md ▸
        // Localization). What holds in every language is that the number appears and that a
        // different number reads differently.
        #expect(sentence([.mode], 7).contains("7"))
        #expect(sentence([.mode], 7) != sentence([.mode], 8))
    }

    @Test("one item and many items are not the same sentence")
    func pluralsAreDistinguished() {
        // Pinned because the catalog carries plural variations for all fourteen languages, and a
        // missing `one` form is invisible in English's own build only if the two happen to match.
        #expect(sentence([.modificationTime], 1) != sentence([.modificationTime], 5))
    }

    // MARK: - Where it points

    @Test("the destination comes from where items actually landed")
    func landingDirectoryIsRead() {
        let landed = VFSPath.local("/tmp/dst/a.txt")
        let report = OperationReport(
            completedItems: 1,
            completedBytes: 5,
            skipped: [],
            failures: [],
            wasCancelled: false,
            outcomes: [OperationItemOutcome(
                source: .local("/tmp/src/a.txt"),
                landedAt: landed,
                replacedExisting: false
            )]
        )
        #expect(BrowserWindowController.landingDirectory(of: report) == .local("/tmp/dst"))
    }

    @Test("a report whose items all skipped points nowhere rather than at a phantom")
    func skippedItemsHaveNoLanding() {
        // `landedAt` is `nil` for an item the conflict policy declined, so a reader taking the first
        // outcome unconditionally would name a directory nothing was written to.
        let report = OperationReport(
            completedItems: 0,
            completedBytes: 0,
            skipped: [.local("/tmp/src/a.txt")],
            failures: [],
            wasCancelled: false,
            outcomes: [OperationItemOutcome(
                source: .local("/tmp/src/a.txt"),
                landedAt: nil,
                replacedExisting: false
            )]
        )
        #expect(BrowserWindowController.landingDirectory(of: report) == nil)
    }

    @Test("a report with no outcomes at all points nowhere")
    func emptyReportHasNoLanding() {
        #expect(BrowserWindowController.landingDirectory(of: .empty) == nil)
    }
}

/// An SFTP transport that moves nothing and promises nothing.
///
/// `metadataCapabilities` is empty on purpose: a plan built against it can carry neither a mode nor
/// a date, so every transfer through it records a loss — which is what gives a connection a
/// **non-zero tally** with no server anywhere. That is the only way to tell a routed answer from the
/// inherited default, since a healthy connection's tally and a missing forward's are both zero.
private final class LosingTransport: SFTPTransport, @unchecked Sendable {
    func listDirectory(_ remotePath: String) throws -> String { "" }
    func makeDirectory(_ remotePath: String) throws {}
    func createEmptyFile(_ remotePath: String) throws {}
    func rename(_ source: String, to destination: String) throws {}
    func removeFile(_ remotePath: String) throws {}
    func removeDirectory(_ remotePath: String) throws {}
    func createSymbolicLink(_ remotePath: String, target: String) throws {}

    func download(
        _ remotePath: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 { 0 }

    func upload(
        _ localPath: String,
        to remotePath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        // The bytes are irrelevant here; what matters is that the backend then records what the
        // (empty) capabilities could not carry.
        (try? Data(contentsOf: URL(fileURLWithPath: localPath)).count).map(Int64.init) ?? 0
    }
}

/// The routing forward `CopyEngine` reads to work out what a job lost (PLAN.md §M25 Slice 5b).
///
/// **Its own suite because this forward shipped missing and nothing said so.** Written, built, both
/// full suites green, and the status line simply never appeared: `CompositeBackend` inherited
/// `VFSBackend`'s `.zero` default, so every job's delta was zero and every copy looked lossless. It
/// took a live run against a real server to notice — which is the M22 `subtreeListing` failure
/// exactly, one milestone later and in the same shape.
///
/// The discriminator is the hard part and is why the fake transport above declares **no**
/// capabilities: a connection that has lost nothing answers zero, and so does a forward that does
/// not exist, so a test built on a healthy connection cannot tell them apart.
@Suite("CompositeBackend ▸ metadata tally routing")
@MainActor
struct MetadataTallyRoutingTests {
    private let location = SFTPLocation(host: "srv.example", username: "oleg")

    /// A composite holding one connection that cannot carry metadata, and a file to send through it.
    ///
    /// A struct rather than a tuple because four members trips SwiftLint's `large_tuple` — and
    /// because naming them is what stops `remote` and `source` being handed over the wrong way round.
    struct Fixture {
        let composite: CompositeBackend
        /// A directory on the connection that can carry nothing.
        let remote: VFSPath
        /// A real file on this disk, to send through it.
        let source: FileEntry
        /// The temp tree holding it, for the caller to remove.
        let root: URL
    }

    private func connected() throws -> Fixture {
        let composite = CompositeBackend(local: LocalBackend())
        let backend = SFTPBackend(location: location, transport: LosingTransport())
        // Inserted directly rather than through `connectSFTP`, which would build a real process
        // transport: what is under test is the routing, not the connect.
        composite.sftpConnections[location.descriptor] = backend

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-tally-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("a.txt")
        try Data("bytes".utf8).write(to: file)
        return Fixture(
            composite: composite,
            remote: VFSPath(backend: .sftp(location), path: "/home/oleg"),
            source: try composite.stat(at: .local(file.path)),
            root: root
        )
    }

    @Test("the composite answers from the connection that owns the path")
    func tallyIsRouted() throws {
        let fixture = try connected()
        let (composite, remote, entry, root) = (
            fixture.composite,
            fixture.remote,
            fixture.source,
            fixture.root
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try composite.copyFile(
            at: entry.path,
            to: remote.appending("a.txt"),
            hint: CopySourceHint(entry),
            progress: { _ in },
            isCancelled: { false }
        )
        // Non-zero only if the answer came from the SFTP connection. The inherited default is zero,
        // which is also what a healthy connection reports — hence a transport that can carry nothing.
        #expect(composite.metadataTally(at: remote).itemCount == 1)
    }

    @Test("a local path answers zero, so the forward has not become 'everything'")
    func localPathIsZero() throws {
        let fixture = try connected()
        let (composite, remote, entry, root) = (
            fixture.composite,
            fixture.remote,
            fixture.source,
            fixture.root
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try composite.copyFile(
            at: entry.path,
            to: remote.appending("a.txt"),
            hint: CopySourceHint(entry),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(composite.metadataTally(at: .local("/tmp")).itemCount == 0)
    }

    /// End to end, and the test that would have caught the shipped bug: a real `CopyEngine` run over
    /// the routing backend must put the loss on its report.
    @Test("a job's report carries what the copy could not keep")
    func reportCarriesTheLoss() throws {
        let fixture = try connected()
        let (composite, remote, entry, root) = (
            fixture.composite,
            fixture.remote,
            fixture.source,
            fixture.root
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let report = CopyEngine.run(
            FileOperation(kind: .copy, sources: [entry], destinationDirectory: remote),
            using: composite
        )
        let loss = try #require(report.metadataLoss)
        #expect(loss.itemCount == 1)
        #expect(loss.aspects.contains(.modificationTime))
        #expect(!BrowserWindowController.metadataLossSentence(for: loss).isEmpty)
    }

    @Test("an ordinary local copy reports no loss at all")
    func localCopyIsClean() throws {
        // The narrowness control: without it "report a loss" could quietly become "report one on
        // every copy", which on this app's commonest operation would be a permanent false alarm.
        let fixture = try connected()
        let (composite, entry, root) = (fixture.composite, fixture.source, fixture.root)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let report = CopyEngine.run(
            FileOperation(
                kind: .copy,
                sources: [entry],
                destinationDirectory: .local(destination.path)
            ),
            using: composite
        )
        #expect(report.metadataLoss == nil)
        #expect(report.failures.isEmpty)
    }
}
