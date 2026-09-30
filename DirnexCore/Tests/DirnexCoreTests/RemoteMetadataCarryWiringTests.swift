import Foundation
import Testing

@testable import DirnexCore

/// What a remote transfer carries besides bytes, wired end to end through the two backends
/// (PLAN.md §M25 Slice 2).
///
/// The rule these all turn on is that **a carry nobody made must be reported, never assumed**: the
/// failure this milestone exists to close is the quiet one, where a copy lands with the umask's mode
/// and today's date and says nothing. So most assertions here are about what the backend *asked for*
/// and what it *recorded as lost*, which no assertion about the resulting file can make.
@Suite("Remote metadata carry ▸ wiring")
struct RemoteMetadataCarryWiringTests {
    private let sftp = SFTPLocation(host: "example.com", port: 22, username: "oleg")
    private let ftp = FTPLocation(host: "nas.local", port: 21, username: "sa", security: .explicit)

    private func remote(_ path: String) -> VFSPath { VFSPath(backend: .sftp(sftp), path: path) }
    private func ftpRemote(_ path: String) -> VFSPath { VFSPath(backend: .ftp(ftp), path: path) }
    private func local(_ path: String) -> VFSPath { VFSPath(backend: .local, path: path) }

    // MARK: - The transport decides, not the protocol

    @Test("a transport that declares no carry makes the backend report the loss, never claim it")
    func undeclaredTransportReportsLoss() throws {
        let transport = FakeSFTPTransport() // metadataCapabilities defaults to []
        let backend = SFTPBackend(location: sftp, transport: transport)
        let source = try TempFile(mode: 0o640)

        try backend.copyFile(
            at: local(source.path),
            to: remote("/srv/x.txt"),
            hint: CopySourceHint(
                metadata: RemoteSourceMetadata(permissions: 0o640, modificationTime: Date())
            ),
            progress: { _ in },
            isCancelled: { false }
        )

        let loss = try #require(backend.metadata.loss)
        #expect(loss.aspects.contains(.mode))
        #expect(loss.aspects.contains(.modificationTime))
        #expect(loss.itemCount == 1)
    }

    @Test("a transport that never mentions metadata inherits the empty set, not SFTP's")
    func theDefaultCarriesNothing() throws {
        // The invariant behind every other test here: declaring a capability is an *obligation* to
        // implement the verbs, so the default has to be the empty set. A default of `.sftp` would
        // make a transport that never implemented the carry claim a mode it never wrote — the one
        // failure this milestone exists to close — and nothing in the compiler would say so.
        let transport = MinimalSFTPTransport()
        #expect(transport.metadataCapabilities.isEmpty)

        let backend = SFTPBackend(location: sftp, transport: transport)
        #expect(backend.metadata.capabilities.isEmpty)
    }

    @Test("an ordinary upload rides the preserve flag alone and costs no extra step")
    func ordinaryUploadRidesPreserveFlag() throws {
        let transport = FakeSFTPTransport()
        transport.metadataCapabilities = .sftp
        let backend = SFTPBackend(location: sftp, transport: transport)
        let source = try TempFile(mode: 0o644)

        try backend.copyFile(
            at: local(source.path),
            to: remote("/srv/x.txt"),
            hint: CopySourceHint(
                metadata: RemoteSourceMetadata(permissions: 0o644, modificationTime: Date())
            ),
            progress: { _ in },
            isCancelled: { false }
        )

        let plan = try #require(transport.carriedPlans.first)
        #expect(plan.usesPreserveFlag)
        // `-p` carries the nine bits and both timestamps exactly, so a corrective `chmod` would be a
        // round trip for nothing — the narrowness control on the whole design.
        #expect(plan.followUp.isEmpty)
        #expect(backend.metadata.loss == nil)
    }

    @Test("a set-uid source adds the corrective chmod the preserve flag cannot express")
    func setUidUploadAddsCorrectiveChmod() throws {
        let transport = FakeSFTPTransport()
        transport.metadataCapabilities = .sftp
        let backend = SFTPBackend(location: sftp, transport: transport)
        let source = try TempFile(mode: 0o644)

        try backend.copyFile(
            at: local(source.path),
            to: remote("/srv/x.txt"),
            hint: CopySourceHint(
                metadata: RemoteSourceMetadata(permissions: 0o4755, modificationTime: nil)
            ),
            progress: { _ in },
            isCancelled: { false }
        )

        let plan = try #require(transport.carriedPlans.first)
        #expect(plan.usesPreserveFlag)
        #expect(plan.followUp == [.setMode(POSIXPermissions(rawValue: 0o4755))])
        #expect(backend.metadata.loss == nil)
    }

    @Test("an upload's source is read from disk when the caller passes no hint")
    func uploadReadsItsLocalSource() throws {
        let transport = FakeSFTPTransport()
        transport.metadataCapabilities = .sftp
        let backend = SFTPBackend(location: sftp, transport: transport)
        let source = try TempFile(mode: 0o4711)

        try backend.copyFile(
            at: local(source.path),
            to: remote("/srv/x.txt"),
            hint: CopySourceHint(metadata: nil),
            progress: { _ in },
            isCancelled: { false }
        )

        // The special bit could only have come from the file itself — an upload's source is on this
        // machine, so leaving it out for want of a parameter would drop a carry that costs a syscall.
        let plan = try #require(transport.carriedPlans.first)
        #expect(plan.followUp == [.setMode(POSIXPermissions(rawValue: 0o4711))])
    }

    // MARK: - A refusal is not a failed copy

    @Test("a refused metadata step is recorded as a loss and does not fail the transfer")
    func refusedStepDoesNotFailTheCopy() throws {
        let transport = FakeSFTPTransport()
        transport.metadataCapabilities = .sftp
        transport.metadataRefusals = [
            .itemRefused("remote setstat \"/srv/x.txt\": Permission denied")
        ]
        let backend = SFTPBackend(location: sftp, transport: transport)
        let source = try TempFile(mode: 0o644)

        // The bytes landed; a server that will not keep a mode has not failed the copy.
        try backend.copyFile(
            at: local(source.path),
            to: remote("/srv/x.txt"),
            hint: CopySourceHint(
                metadata: RemoteSourceMetadata(permissions: 0o4755, modificationTime: nil)
            ),
            progress: { _ in },
            isCancelled: { false }
        )

        let loss = try #require(backend.metadata.loss)
        #expect(loss.aspects.contains(.mode))
    }

    @Test("an item's own refusal latches nothing, so the next file still tries")
    func itemRefusalDoesNotLatch() throws {
        let support = RemoteMetadataSupport(offering: .ftp)
        support.record(dropped: [.mode])
        // The narrowness that keeps one unwritable file from costing every later copy its metadata.
        #expect(support.capabilities == .ftp)
    }

    @Test("a verb the server does not implement is latched, so no later file pays to find out")
    func unimplementedVerbLatches() throws {
        let support = RemoteMetadataSupport(offering: .ftp)
        support.recordUnsupported(.setModificationTime)
        #expect(support.capabilities == .changeMode)
    }

    // MARK: - The download direction lands on this machine

    @Test("a download still carries what the *server* has already refused to keep")
    func ftpDownloadCarriesTimeLocally() throws {
        let transport = FakeFTPTransport()
        transport.metadataCapabilities = .ftp
        let backend = FTPBackend(location: ftp, transport: transport)
        let destination = try TempFile(mode: 0o644)
        let when = Date(timeIntervalSince1970: 1_528_358_950)
        // This connection's server has already refused both verbs, so an *upload* over it can carry
        // nothing. A download is not bound by that at all — it lands on this machine, where `chmod`
        // and `utimes` always work. Reading the wire's limits into this direction is the mistake
        // `RemoteMetadataCapabilities.localDestination` exists to prevent, and with the two sets
        // otherwise identical this latch is the only thing that can tell them apart.
        backend.metadata.recordUnsupported([.changeMode, .setModificationTime])

        try backend.copyFile(
            at: ftpRemote("/pub/x.txt"),
            to: local(destination.path),
            hint: CopySourceHint(
                metadata: RemoteSourceMetadata(permissions: 0o754, modificationTime: when)
            ),
            progress: { _ in },
            isCancelled: { false }
        )

        // The destination is local, so `chmod` and `utimes` do all of it — reading the wire's limits
        // into this direction would drop a time the disk was perfectly able to take.
        #expect(destination.mode == 0o754)
        #expect(abs(destination.modificationTime.timeIntervalSince(when)) < 1)
        #expect(backend.metadata.loss == nil)
    }

    @Test("an FTP upload asks the server to keep the mode and the time, in its own invocation")
    func ftpUploadAsksTheServer() throws {
        let transport = FakeFTPTransport()
        transport.metadataCapabilities = .ftp
        let backend = FTPBackend(location: ftp, transport: transport)
        let source = try TempFile(mode: 0o754)
        let when = Date(timeIntervalSince1970: 1_528_358_950)

        try backend.copyFile(
            at: local(source.path),
            to: ftpRemote("/pub/x.txt"),
            hint: CopySourceHint(
                metadata: RemoteSourceMetadata(permissions: 0o754, modificationTime: when)
            ),
            progress: { _ in },
            isCancelled: { false }
        )

        let applied = try #require(transport.appliedMetadata.first)
        #expect(applied.path == "/pub/x.txt")
        #expect(applied.steps.contains(.setMode(POSIXPermissions(rawValue: 0o754))))
        #expect(applied.steps.contains(.setModificationTime(when)))
    }

    @Test("a two-step refusal latches nothing, because curl cannot say which step it was")
    func ambiguousRefusalLatchesNothing() throws {
        let transport = FakeFTPTransport()
        transport.metadataCapabilities = .ftp
        transport.metadataRefusals = [.verbUnimplemented("QUOT command failed with 500")]
        let backend = FTPBackend(location: ftp, transport: transport)
        let source = try TempFile(mode: 0o754)

        try backend.copyFile(
            at: local(source.path),
            to: ftpRemote("/pub/x.txt"),
            hint: CopySourceHint(metadata: RemoteSourceMetadata(
                permissions: 0o754,
                modificationTime: Date(timeIntervalSince1970: 1_528_358_950)
            )),
            progress: { _ in },
            isCancelled: { false }
        )

        // Latching both would stop attempting a verb the server honours — the dishonest direction.
        // Not latching costs one wasted round trip per file, which is the cheap one.
        #expect(backend.metadata.capabilities == .ftp)
        #expect(backend.metadata.loss != nil)
    }

    @Test("a single-step refusal is unambiguous, so it does latch")
    func singleStepRefusalLatches() throws {
        let transport = FakeFTPTransport()
        transport.metadataCapabilities = .ftp
        transport.metadataRefusals = [.verbUnimplemented("QUOT command failed with 500")]
        let backend = FTPBackend(location: ftp, transport: transport)
        let source = try TempFile(mode: 0o644)

        try backend.copyFile(
            at: local(source.path),
            to: ftpRemote("/pub/x.txt"),
            // A mode and no time: one step, so the refusal can only be about that step.
            hint: CopySourceHint(
                metadata: RemoteSourceMetadata(permissions: 0o644, modificationTime: nil)
            ),
            progress: { _ in },
            isCancelled: { false }
        )

        #expect(!backend.metadata.capabilities.contains(.changeMode))
    }

    // MARK: - The directory the engine recreates by hand

    @Test("copyMetadata is no longer a no-op: a recreated directory keeps its mode")
    func copyMetadataCarriesADirectory() throws {
        let transport = FakeSFTPTransport()
        transport.metadataCapabilities = .sftp
        let backend = SFTPBackend(location: sftp, transport: transport)
        let destination = try TempFile(mode: 0o700)

        try backend.copyMetadata(
            at: remote("/srv/docs"),
            to: local(destination.path),
            sourceMetadata: RemoteSourceMetadata(permissions: 0o2750, modificationTime: nil)
        )

        // Every SFTP directory copy used to land with the umask's mode and say nothing.
        #expect(destination.mode == 0o2750)
    }
}

/// A real file on disk with a mode we chose, for the assertions that can only be made against the
/// filesystem — `chmod` and `utimes` are what a download's carry actually runs, so a fake would
/// prove the two halves agree rather than that either is right.
private final class TempFile {
    let path: String

    init(mode: mode_t) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-carry-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        path = url.path
        #expect(chmod(path, mode) == 0)
    }

    var mode: UInt16 {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return UInt16(info.st_mode) & 0o7777
    }

    var modificationTime: Date {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }
}

/// An `SFTPTransport` that implements only what the protocol demands — the shape a transport written
/// before the metadata carry existed has, and the one whose default answer must be "I carry
/// nothing".
private struct MinimalSFTPTransport: SFTPTransport {
    func listDirectory(_: String) throws -> String { "" }
    func createSymbolicLink(_: String, target _: String) throws {}
    func makeDirectory(_: String) throws {}
    func createEmptyFile(_: String) throws {}
    func rename(_: String, to _: String) throws {}
    func removeFile(_: String) throws {}
    func removeDirectory(_: String) throws {}

    func download(
        _: String, to _: String, resume _: Bool,
        progress _: (Int64) -> Void, isCancelled _: () -> Bool
    ) throws -> Int64 { 0 }

    func upload(
        _: String, to _: String, resume _: Bool,
        progress _: (Int64) -> Void, isCancelled _: () -> Bool
    ) throws -> Int64 { 0 }
}
