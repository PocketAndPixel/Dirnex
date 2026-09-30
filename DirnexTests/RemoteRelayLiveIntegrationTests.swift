import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A copy whose **both ends are on servers**, against two real ones (docs/HISTORY.md ▸ After M19).
///
/// This is the only place the staged relay meets real transports. `RelayCopyTests` pins the rules
/// with fakes and `CompositeTransferRouteTests` pins the routing decision; neither can see the
/// thing that actually broke — that `sftp`'s `get` and `curl`'s upload compose into one copy, that
/// what lands is byte-identical, and that the staged file does not survive the transfer.
///
/// Gated on **both** live config files, exactly as its two single-protocol neighbours are, so it is
/// skipped in CI and on any Mac without them. Two servers are enough to run it and both are local:
/// `/usr/sbin/sshd -f <config>` on a high port (no Remote Login needed) and `pyftpdlib` on 2121 —
/// the same pair `SFTPLiveIntegrationTests` and `FTPLiveIntegrationTests` are each written for.
/// Run against exactly that pair on 2026-08-23.
///
/// `.serialized` because every test here writes into two shared server directories and reads the
/// one staging root back, which is state a parallel neighbour would move under it.
@Suite(
    "Remote-to-remote relay live integration",
    .enabled(if: SFTPLiveEnvironment.current != nil && FTPLiveEnvironment.current != nil),
    .serialized
)
struct RemoteRelayLiveIntegrationTests {
    // MARK: - Across two protocols

    @Test("a file copies from an SFTP server to an FTP server, byte for byte")
    func relaysSFTPToFTP() async throws {
        try await offCooperativePool {
            let fixture = try RelayFixture()
            let payload = "relayed \(UUID().uuidString)"
            try fixture.seed(payload, at: fixture.sftpPath("relay-out.txt"))

            var reported: Int64 = 0
            try fixture.backend.copyFile(
                at: fixture.sftpPath("relay-out.txt"),
                to: fixture.ftpPath("relay-out.txt"),
                progress: { reported += $0 },
                isCancelled: { false }
            )

            #expect(try fixture.read(fixture.ftpPath("relay-out.txt")) == payload)
            // The file's size once, not the two legs' sum — what the queue's bar is drawn from.
            #expect(reported == Int64(payload.utf8.count))
            #expect(fixture.stagingIsEmpty)
        }
    }

    @Test("and back the other way, from FTP to SFTP")
    func relaysFTPToSFTP() async throws {
        try await offCooperativePool {
            let fixture = try RelayFixture()
            let payload = "returned \(UUID().uuidString)"
            try fixture.seed(payload, at: fixture.ftpPath("relay-back.txt"))

            try fixture.backend.copyFile(
                at: fixture.ftpPath("relay-back.txt"),
                to: fixture.sftpPath("relay-back.txt"),
                progress: { _ in },
                isCancelled: { false }
            )

            #expect(try fixture.read(fixture.sftpPath("relay-back.txt")) == payload)
            #expect(fixture.stagingIsEmpty)
        }
    }

    // MARK: - Within one account

    /// The case that reads as though it should never have needed anything: SFTP has no copy verb,
    /// so duplicating a file on one server is as unexpressible in that backend as a copy between
    /// two, and it failed the same way before the relay.
    @Test("a duplicate inside one SFTP account lands too")
    func duplicatesWithinOneAccount() async throws {
        try await offCooperativePool {
            let fixture = try RelayFixture()
            let payload = "duplicated \(UUID().uuidString)"
            try fixture.seed(payload, at: fixture.sftpPath("dup-source.txt"))

            try fixture.backend.copyFile(
                at: fixture.sftpPath("dup-source.txt"),
                to: fixture.sftpPath("dup-copy.txt"),
                progress: { _ in },
                isCancelled: { false }
            )

            #expect(try fixture.read(fixture.sftpPath("dup-copy.txt")) == payload)
            #expect(try fixture.read(fixture.sftpPath("dup-source.txt")) == payload)
        }
    }

    // MARK: - Through the queue

    /// The gesture rather than the primitive: `CopyEngine` is what F5 runs, so this is the one
    /// assertion that covers the pre-scan, the conflict check and the transfer together — each of
    /// which asks a *remote* backend a question a local one answers for free.
    @Test("F5's engine carries a whole item between two servers and reports it done")
    func copyEngineTransfersBetweenServers() async throws {
        try await offCooperativePool {
            let fixture = try RelayFixture()
            let payload = "queued \(UUID().uuidString)"
            let source = fixture.sftpPath("engine-source.txt")
            try fixture.seed(payload, at: source)
            // The engine's default conflict policy is `.fail`, so a previous run's landing has to
            // go: without this the suite passes once and reports `alreadyExists` ever after.
            try? fixture.backend.removeItem(at: fixture.ftpPath("engine-source.txt"))

            let operation = FileOperation(
                kind: .copy,
                sources: [try fixture.backend.stat(at: source)],
                destinationDirectory: fixture.ftpRoot
            )
            let report = CopyEngine.run(operation, using: fixture.backend)

            #expect(report.failures.isEmpty)
            #expect(report.completedItems == 1)
            #expect(!report.wasCancelled)
            #expect(try fixture.read(fixture.ftpPath("engine-source.txt")) == payload)
            #expect(fixture.stagingIsEmpty)
        }
    }
}

// MARK: - Fixture

/// Both live accounts, connected, plus the local scratch a seed/read round trip needs. Every verb
/// here goes through the real transports — there is no other way to put a file on either server.
private struct RelayFixture {
    let backend = CompositeBackend(local: LocalBackend())
    let sftp: SFTPLiveEnvironment.Config
    let ftp: FTPLiveEnvironment.Config
    let scratch: URL

    init() throws {
        sftp = try #require(SFTPLiveEnvironment.current)
        ftp = try #require(FTPLiveEnvironment.current)
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-relay-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        backend.connectSFTP(
            location: sftp.location,
            authentication: .key(identityFile: sftp.identityFile)
        )
        backend.connectFTP(
            location: ftp.location,
            authentication: ftp.authentication,
            password: ftp.password,
            trustedPublicKey: ftp.trustedPublicKey
        )
    }

    var sftpRoot: VFSPath { VFSPath(backend: .sftp(sftp.location), path: sftp.remotePath) }
    var ftpRoot: VFSPath { VFSPath(backend: .ftp(ftp.location), path: ftp.remotePath) }

    func sftpPath(_ name: String) -> VFSPath { sftpRoot.appending(name) }
    func ftpPath(_ name: String) -> VFSPath { ftpRoot.appending(name) }

    /// Put `contents` on whichever server `remote` names, by uploading a local file — the direct
    /// route, so a seed that failed would be a failure of something this suite is not testing.
    func seed(_ contents: String, at remote: VFSPath) throws {
        let local = scratch.appendingPathComponent("seed-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: local)
        try? backend.removeItem(at: remote) // a rerun's leftover, which an upload would append to
        try backend.copyFile(
            at: .local(local.path),
            to: remote,
            progress: { _ in },
            isCancelled: { false }
        )
    }

    /// Read a remote file back by downloading it — the only way to see what actually landed.
    func read(_ remote: VFSPath) throws -> String {
        let local = scratch.appendingPathComponent("read-\(UUID().uuidString)")
        try backend.copyFile(
            at: remote,
            to: .local(local.path),
            progress: { _ in },
            isCancelled: { false }
        )
        return try String(contentsOf: local, encoding: .utf8)
    }

    /// Whether the relay left nothing behind. Absent counts: the root is only created by a transfer
    /// that needs it, and purged at launch.
    var stagingIsEmpty: Bool {
        let root = CompositeBackend.relayStagingRoot.path
        guard FileManager.default.fileExists(atPath: root) else { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: root))?.isEmpty ?? false
    }
}
