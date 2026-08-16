import Foundation
import Testing

@testable import DirnexCore

/// What an FTP or SFTP transfer reports *while* it runs, and what it settles on when it stops.
///
/// One suite for both protocols rather than one per backend, for the same reason
/// `RemoteTransferCancellationTests` is: the rule is remote-generic, and this milestone's most
/// repeated finding is one rule spelled several ways. It is the third instance of the defect S3's
/// own progress tests were written for — measured 2026-08-16 against a throttled local server, an
/// 8 MB FTP upload reported its bytes **once, 8 seconds after it started**, which is a motionless
/// bar for the whole transfer.
///
/// Both halves are asserted everywhere, because they pull opposite ways: the deltas have to arrive
/// as the bytes move, **and** they have to sum to the count the tool measured rather than to a
/// sum of one-per-cent estimates.
@Suite("remote transfer progress")
struct RemoteTransferProgressTests {
    private let ftpLocation = FTPLocation(
        host: "nas.local",
        port: 21,
        username: "sa",
        security: .explicit
    )
    private let sftpLocation = SFTPLocation(host: "nas.local", port: 22, username: "sa")

    private func ftpPath(_ remote: String) -> VFSPath {
        VFSPath(backend: .ftp(ftpLocation), path: remote)
    }

    private func sftpPath(_ remote: String) -> VFSPath {
        VFSPath(backend: .sftp(sftpLocation), path: remote)
    }

    // MARK: - The flag that makes an FTP upload observable at all

    /// `-s` silences the progress meter, which for an upload is the only observable there is —
    /// nothing local changes as the bytes go out. A download keeps `-sS` deliberately: its
    /// destination is a file on this machine that grows, so the transport reports exact bytes by
    /// watching it, where the meter could only offer a rounded percentage.
    @Test("only the FTP upload lets curl's progress meter through")
    func onlyTheUploadShowsTheProgressMeter() {
        let session = FTPSession(
            location: ftpLocation,
            trust: .systemDefault,
            tls: .negotiate,
            connectTimeout: 15,
            maxTime: 30
        )
        let upload = FTPProcessArguments.upload(
            session: session,
            localPath: "/tmp/a.bin",
            remotePath: "/pub/a.bin",
            resume: false
        )
        #expect(upload.contains("-S"))
        #expect(!upload.contains("-sS"), "the meter has to reach stderr to be read at all")

        let quiet = [
            FTPProcessArguments.download(
                session: session,
                remotePath: "/pub/a.bin",
                localPath: "/tmp/a.bin",
                resume: false
            ),
            FTPProcessArguments.list(session: session, remotePath: "/pub"),
            FTPProcessArguments.head(session: session, remotePath: "/pub/a.bin"),
            FTPProcessArguments.quote(session: session, commands: ["DELE a.bin"])
        ]
        for arguments in quiet {
            #expect(arguments.contains("-sS"))
        }
    }

    // MARK: - FTP

    @Test("an FTP download reports as it goes, and still ends on the exact byte count")
    func ftpDownloadStreamsAndReconciles() throws {
        let transport = FakeFTPTransport()
        transport.transferBytes = 8_388_608
        // What watching the destination file yields on a throttled server: a report per poll.
        transport.streamedProgress = [2_097_152, 2_097_152, 2_097_152]

        var reported: [Int64] = []
        try FTPBackend(location: ftpLocation, transport: transport).copyFile(
            at: ftpPath("/pub/payload.bin"),
            to: .local(NSTemporaryDirectory() + "ftp-progress-\(UUID().uuidString)"),
            progress: { reported.append($0) },
            isCancelled: { false }
        )

        #expect(reported.count == 4, "three sightings while it ran, then the remainder")
        #expect(reported.allSatisfy { $0 >= 0 }, "the queue's tally only adds")
        let exact: Int64 = 8_388_608
        #expect(reported.reduce(0, +) == exact)
    }

    @Test("an FTP upload reports as it goes, and still ends on the exact byte count")
    func ftpUploadStreamsAndReconciles() throws {
        let transport = FakeFTPTransport()
        transport.transferBytes = 8_388_608
        // What a one-per-cent meter yields: sightings that are close and never exact.
        transport.streamedProgress = [4_026_531, 3_355_443]
        let source = try TemporaryFile(bytes: 42)
        defer { source.remove() }

        var reported: [Int64] = []
        try FTPBackend(location: ftpLocation, transport: transport).copyFile(
            at: .local(source.path),
            to: ftpPath("/pub/payload.bin"),
            progress: { reported.append($0) },
            isCancelled: { false }
        )

        #expect(reported.count == 3)
        let exact: Int64 = 8_388_608
        #expect(
            reported.reduce(0, +) == exact,
            "the deltas add up to the measured count, not to the estimates"
        )
    }

    @Test("an FTP transfer that streamed nothing reports the whole count once, as it always did")
    func ftpWithoutAMeterIsUnchanged() throws {
        let transport = FakeFTPTransport()
        transport.transferBytes = 4096

        var reported: [Int64] = []
        try FTPBackend(location: ftpLocation, transport: transport).copyFile(
            at: ftpPath("/pub/small.bin"),
            to: .local(NSTemporaryDirectory() + "ftp-silent-\(UUID().uuidString)"),
            progress: { reported.append($0) },
            isCancelled: { false }
        )

        // The estimate is an addition to this path, never a replacement for it: a server too fast to
        // report on, or a `curl` that printed nothing usable, must still report its bytes.
        let whole: Int64 = 4096
        #expect(reported == [whole])
    }

    // MARK: - SFTP

    @Test("an SFTP download reports as it goes, and still ends on the exact byte count")
    func sftpDownloadStreamsAndReconciles() throws {
        let transport = FakeSFTPTransport()
        transport.downloadBytes = 1_048_576
        transport.streamedProgress = [262_144, 262_144]

        var reported: [Int64] = []
        try SFTPBackend(location: sftpLocation, transport: transport).copyFile(
            at: sftpPath("/home/sa/payload.bin"),
            to: .local(NSTemporaryDirectory() + "sftp-progress-\(UUID().uuidString)"),
            progress: { reported.append($0) },
            isCancelled: { false }
        )

        #expect(reported.count == 3)
        let exact: Int64 = 1_048_576
        #expect(reported.reduce(0, +) == exact)
    }

    /// **The asymmetry is `sftp`'s and is deliberately pinned**, so nobody later reads the silence as
    /// a gap in the wiring and "fixes" it by inventing a number. An upload has no local observable,
    /// and OpenSSH draws its meter only for a foreground process group on a controlling terminal —
    /// probed six ways over a 1 GiB transfer (2026-08-16), including with its own `progress` batch
    /// command explicitly enabling it. What the backend owes is the exact count, once, at the end.
    @Test("an SFTP upload reports once, at the end, because sftp offers nothing to watch")
    func sftpUploadReportsAtTheEnd() throws {
        let transport = FakeSFTPTransport()
        transport.uploadBytes = 1_048_576
        let source = try TemporaryFile(bytes: 42)
        defer { source.remove() }

        var reported: [Int64] = []
        try SFTPBackend(location: sftpLocation, transport: transport).copyFile(
            at: .local(source.path),
            to: sftpPath("/home/sa/payload.bin"),
            progress: { reported.append($0) },
            isCancelled: { false }
        )

        let whole: Int64 = 1_048_576
        #expect(reported == [whole])
    }
}
