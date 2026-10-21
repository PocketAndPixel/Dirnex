import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A tree over FTP refreshes over **one** login (reported 2026-10-19: a file written to a folder
/// open in an FTP tree did not appear until the tab was closed and opened again).
///
/// Measured on the reporting server, each refresh of a tree with two folders open was three `curl`
/// runs of ~1 s — a login apiece — and the poll, which spaces its rounds by what the last one cost,
/// waited 59 s between them. `FTPBackend.listDirectories` lists them all over one login; what is
/// pinned here is the wiring either side of it, since both halves can go missing with no symptom at
/// all: the composite inheriting the protocol's list-each-in-turn default, and the tree refresh
/// never asking. Either one leaves every row correct and every login still paid.
///
/// Installed straight into `ftpConnections` rather than through `connectFTP`, which would build a
/// real `curl` transport: what is under test is the routing, not the connect.
private enum FTPTreeFixture {
    static let location = FTPLocation(host: "etevip.example", username: "syn")

    static func path(_ remotePath: String) -> VFSPath {
        VFSPath(backend: .ftp(location), path: remotePath)
    }

    static func composite(with transport: RecordingFTPTransport) -> CompositeBackend {
        let composite = CompositeBackend(local: LocalBackend())
        composite.ftpConnections[location.descriptor] = FTPBackend(
            location: location, transport: transport
        )
        return composite
    }

    static func transport() -> RecordingFTPTransport {
        let transport = RecordingFTPTransport()
        transport.listings["/"] = "drwxr-xr-x 2 syn users 4096 Jun 14  2024 SYNERGIE"
        transport.listings["/SYNERGIE"] = "drwxr-xr-x 2 syn users 4096 Oct 19 14:36 AGENCE"
        transport.listings["/SYNERGIE/AGENCE"] =
            "-rw-r--r-- 1 syn users 876544 Oct 19 01:00 Agences_e-Testing.xml"
        return transport
    }
}

@Suite("CompositeBackend ▸ batched listing routing")
struct CompositeBackendListingTests {
    /// The forward. The default would answer the same rows through one single listing per folder,
    /// so the rows cannot tell the two apart and the transport's record is the only discriminator.
    @Test("several folders on one FTP connection reach its batch")
    func ftpFoldersReachTheBatch() throws {
        let transport = FTPTreeFixture.transport()
        let composite = FTPTreeFixture.composite(with: transport)
        let folders = ["/", "/SYNERGIE", "/SYNERGIE/AGENCE"]

        let answers = try composite.listDirectories(
            at: folders.map(FTPTreeFixture.path), isCancelled: { false }
        )

        #expect(answers.map { $0?.map(\.name) } == [
            ["SYNERGIE"], ["AGENCE"], ["Agences_e-Testing.xml"]
        ])
        #expect(transport.batches == [folders])
        #expect(transport.singleListings.isEmpty)
    }

    /// The narrowness control: routing is not answering. A local folder still comes off the disk,
    /// in its place among the others, and a folder on a connection that is not there is a folder
    /// nothing could list rather than an error that loses the rest.
    @Test("local folders are listed from disk, and an unconnected one answers nil, in order")
    func mixedFoldersKeepTheirPlaces() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-batch-route-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("inside"), withIntermediateDirectories: true
        )
        let transport = FTPTreeFixture.transport()
        let composite = FTPTreeFixture.composite(with: transport)
        let unconnected = VFSPath(
            backend: .ftp(FTPLocation(host: "gone.example", username: "syn")), path: "/"
        )

        let answers = try composite.listDirectories(
            at: [
                FTPTreeFixture.path("/"),
                .local(root.path),
                unconnected,
                FTPTreeFixture.path("/SYNERGIE")
            ],
            isCancelled: { false }
        )

        #expect(answers.map { $0?.map(\.name) } == [["SYNERGIE"], ["inside"], nil, ["AGENCE"]])
        #expect(transport.batches == [["/", "/SYNERGIE"]])
    }
}

@MainActor
@Suite("A tree refresh over FTP")
struct FTPTreeRefreshTests {
    private static func directory(_ name: String, at path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: name,
            kind: .directory,
            byteSize: 0,
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: 0o755,
            inode: 0
        )
    }

    /// The reported tree, as the pane held it before the file was written: the root, SYNERGIE open
    /// under it, and AGENCE open under that, showing one file.
    private static func pane(over transport: RecordingFTPTransport) -> PanelViewController {
        let root = FTPTreeFixture.path("/")
        let synergie = root.appending("SYNERGIE")
        let agence = synergie.appending("AGENCE")
        let pane = PanelViewController(
            backend: FTPTreeFixture.composite(with: transport),
            restoration: nil,
            defaultPath: root,
            restorationKey: nil
        )
        var panel = Panel(model: DirectoryModel(listing: DirectoryListing(
            path: root, entries: [directory("SYNERGIE", at: synergie)]
        )))
        panel.enterTreeMode()
        panel.setTreeChildListing(synergie, entries: [directory("AGENCE", at: agence)])
        panel.expand(synergie)
        panel.setTreeChildListing(agence, entries: [])
        panel.expand(agence)
        pane.panel = panel
        return pane
    }

    /// Poll rather than spin the run loop: the refresh's listing is `await`ed, and a run-loop spin
    /// never lets a continuation land (docs/NOTES.md ▸ Testing).
    private static func waitForNames(
        _ pane: PanelViewController, under directory: VFSPath, toContain name: String
    ) async -> [String] {
        var names: [String] = []
        for _ in 0..<100 {
            names = (pane.panel.tree?.entries(in: directory) ?? []).map(\.name)
            if names.contains(name) { return names }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return names
    }

    @Test("re-lists every open folder over one connection, and the new file appears")
    func refreshIsOneConnection() async {
        let transport = FTPTreeFixture.transport()
        let pane = Self.pane(over: transport)
        transport.listings["/SYNERGIE/AGENCE"] = [
            "-rw-r--r-- 1 syn users  876544 Oct 19 01:00 Agences_e-Testing.xml",
            "-rw-r--r-- 1 syn users 2936012 Oct 19 14:36 Agences_SYNERGIE_ATS.xml"
        ].joined(separator: "\n")

        pane.refreshTree()

        let agence = FTPTreeFixture.path("/SYNERGIE/AGENCE")
        let names = await Self.waitForNames(
            pane, under: agence, toContain: "Agences_SYNERGIE_ATS.xml"
        )
        #expect(names.contains("Agences_SYNERGIE_ATS.xml"))
        #expect(transport.batches.count == 1)
        #expect(Set(transport.batches.first ?? []) == ["/", "/SYNERGIE", "/SYNERGIE/AGENCE"])
        #expect(transport.singleListings.isEmpty)
    }
}

// MARK: - Double

/// An FTP transport that answers from a table and records which verb every listing went through —
/// the one place a batch and a run of single listings differ.
private final class RecordingFTPTransport: FTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: String] = [:]
    private var recordedBatches: [[String]] = []
    private var recordedSingles: [String] = []

    var listings: [String: String] {
        get { lock.withLock { table } }
        set { lock.withLock { table = newValue } }
    }

    var batches: [[String]] { lock.withLock { recordedBatches } }
    var singleListings: [String] { lock.withLock { recordedSingles } }

    func listDirectory(_ remotePath: String) throws -> String {
        try lock.withLock {
            recordedSingles.append(remotePath)
            guard let listing = table[remotePath] else { throw FTPTransportError.notFound }
            return listing
        }
    }

    func listDirectories(_ remotePaths: [String], isCancelled: () -> Bool) throws -> [String?] {
        lock.withLock {
            recordedBatches.append(remotePaths)
            return remotePaths.map { table[$0] }
        }
    }

    func makeDirectory(_ remotePath: String) throws {}
    func createEmptyFile(_ remotePath: String) throws {}
    func rename(_ source: String, to destination: String) throws {}
    func removeFile(_ remotePath: String) throws {}
    func removeDirectory(_ remotePath: String) throws {}
    func fileSize(_ remotePath: String) throws -> Int64 { 0 }

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
    ) throws -> Int64 { 0 }
}
