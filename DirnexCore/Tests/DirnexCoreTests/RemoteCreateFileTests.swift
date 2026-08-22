import Foundation
import Testing

@testable import DirnexCore

/// `RemoteTransportBackend.createFile` — the ⇧F4 "Edit File…" route on a server (PLAN.md §M11).
///
/// Driven through **both** backends rather than one, because the rule has a single home and the
/// bug it exists to prevent is one of them quietly growing a second: FTP and SFTP inherit the same
/// implementation, so a suite that only asked SFTP would pass however far FTP had drifted. Every
/// claim here is made twice, once per protocol.
///
/// The transport half — which FTP verb, and why `put` rather than `/dev/null` — is measured against
/// real servers and lives in `FTPProcessArgumentsTests` and the transports' own doc comments; what
/// is pure, and so is what this pins, is the *guard*: an occupied name is refused before anything
/// is written.
@Suite("Remote createFile")
struct RemoteCreateFileTests {
    private let sftpLocation = SFTPLocation(host: "example.com", port: 22, username: "oleg")
    private let ftpLocation = FTPLocation(
        host: "nas.local",
        port: 21,
        username: "sa",
        security: .explicit
    )

    private func sftpPath(_ remote: String) -> VFSPath {
        VFSPath(backend: .sftp(sftpLocation), path: remote)
    }

    private func ftpPath(_ remote: String) -> VFSPath {
        VFSPath(backend: .ftp(ftpLocation), path: remote)
    }

    private func sftpBackend(_ transport: FakeSFTPTransport) -> SFTPBackend {
        SFTPBackend(location: sftpLocation, transport: transport)
    }

    private func ftpBackend(_ transport: FakeFTPTransport) -> FTPBackend {
        FTPBackend(location: ftpLocation, transport: transport)
    }

    // MARK: - The happy path

    @Test("SFTP: a free name is created, at the path that was asked for")
    func sftpCreatesFreeName() throws {
        let transport = FakeSFTPTransport()
        transport.listings["/home/oleg"] = "" // the directory exists and holds nothing
        try sftpBackend(transport).createFile(at: sftpPath("/home/oleg/notes.txt"))
        #expect(transport.createdFiles == ["/home/oleg/notes.txt"])
    }

    @Test("FTP: a free name is created, at the path that was asked for")
    func ftpCreatesFreeName() throws {
        let transport = FakeFTPTransport()
        transport.listings["/pub"] = ""
        try ftpBackend(transport).createFile(at: ftpPath("/pub/notes.txt"))
        #expect(transport.createdFiles == ["/pub/notes.txt"])
    }

    // MARK: - The guard

    /// The claim that matters, and the one the whole feature rests on: an occupied name is refused
    /// **without a write being issued**. Asserting only the throw would pass against a backend that
    /// truncated the file and then complained — over both protocols a create is a plain upload, so
    /// "did anything get written" is the only question that separates a guard from an apology.
    @Test("SFTP: an existing file is refused and nothing is written")
    func sftpRefusesExistingFile() {
        let transport = FakeSFTPTransport()
        transport.listings["/home/oleg/notes.txt"] =
            "-rw-r--r-- ? oleg staff 128 Jul 13 00:09 /home/oleg/notes.txt"
        #expect(throws: VFSError.alreadyExists(sftpPath("/home/oleg/notes.txt"))) {
            try sftpBackend(transport).createFile(at: sftpPath("/home/oleg/notes.txt"))
        }
        #expect(transport.createdFiles.isEmpty)
    }

    @Test("FTP: an existing file is refused and nothing is written")
    func ftpRefusesExistingFile() {
        let transport = FakeFTPTransport()
        transport.listings["/pub"] = "-rw-r--r-- 1 sa users 6 Jul 25 20:55 notes.txt"
        #expect(throws: VFSError.alreadyExists(ftpPath("/pub/notes.txt"))) {
            try ftpBackend(transport).createFile(at: ftpPath("/pub/notes.txt"))
        }
        #expect(transport.createdFiles.isEmpty)
    }

    /// A **directory** of that name is the half a file-only test cannot see, and over SFTP it is the
    /// expensive one: `put <local> <an existing directory>` exits 0 having created
    /// `<directory>/<the local file's basename>` (measured 2026-08-23 against a real `sshd`), so an
    /// unguarded create aimed at a folder reports success and leaves a file named after a temporary
    /// file inside a folder nobody was editing. `curl` refuses the same thing with 550, which is
    /// exactly why the claim is asserted for both: the two protocols fail differently and the guard
    /// is what makes them behave the same.
    @Test("SFTP: an existing directory is refused and nothing is written")
    func sftpRefusesExistingDirectory() {
        let transport = FakeSFTPTransport()
        transport.listings["/home/oleg/photos"] =
            "drwxr-xr-x ? oleg staff 64 Jul 13 00:09 /home/oleg/photos/."
        #expect(throws: VFSError.alreadyExists(sftpPath("/home/oleg/photos"))) {
            try sftpBackend(transport).createFile(at: sftpPath("/home/oleg/photos"))
        }
        #expect(transport.createdFiles.isEmpty)
    }

    @Test("FTP: an existing directory is refused and nothing is written")
    func ftpRefusesExistingDirectory() {
        let transport = FakeFTPTransport()
        transport.listings["/pub"] = "drwxr-xr-x 2 sa users 4096 Jul 25 20:55 photos"
        #expect(throws: VFSError.alreadyExists(ftpPath("/pub/photos"))) {
            try ftpBackend(transport).createFile(at: ftpPath("/pub/photos"))
        }
        #expect(transport.createdFiles.isEmpty)
    }

    /// The connection root is a directory by construction and has no parent to be stat'd through,
    /// so it is refused before anything is asked. Over FTP it would otherwise reach `stat`'s own
    /// root branch, which answers a synthesized entry and never fails.
    @Test("SFTP: the connection root is refused")
    func sftpRefusesRoot() {
        let transport = FakeSFTPTransport()
        #expect(throws: VFSError.alreadyExists(sftpPath("/"))) {
            try sftpBackend(transport).createFile(at: sftpPath("/"))
        }
        #expect(transport.createdFiles.isEmpty)
    }

    @Test("FTP: the connection root is refused")
    func ftpRefusesRoot() {
        let transport = FakeFTPTransport()
        #expect(throws: VFSError.alreadyExists(ftpPath("/"))) {
            try ftpBackend(transport).createFile(at: ftpPath("/"))
        }
        #expect(transport.createdFiles.isEmpty)
    }

    // MARK: - Failures

    /// A write that fails arrives as this protocol's own transport error and must come back out in
    /// the shared vocabulary, carrying the path the transport never knew — the same mapping every
    /// other write verb goes through, asserted here because a new verb inherits nothing by default.
    ///
    /// The fake throws from `stat`'s listing too, which is what the `try?` around the guard absorbs:
    /// a name whose existence cannot be established is not thereby taken, so the create is attempted
    /// and it is the *write's* failure the user is told about.
    @Test("SFTP: a transport failure maps onto the shared error vocabulary")
    func sftpMapsFailure() {
        let transport = FakeSFTPTransport()
        transport.error = .permissionDenied
        #expect(throws: VFSError.permissionDenied(sftpPath("/home/oleg/notes.txt"))) {
            try sftpBackend(transport).createFile(at: sftpPath("/home/oleg/notes.txt"))
        }
    }

    @Test("FTP: a transport failure maps onto the shared error vocabulary")
    func ftpMapsFailure() {
        let transport = FakeFTPTransport()
        transport.error = .permissionDenied
        #expect(throws: VFSError.permissionDenied(ftpPath("/pub/notes.txt"))) {
            try ftpBackend(transport).createFile(at: ftpPath("/pub/notes.txt"))
        }
    }

    /// A path belonging to another account never reaches the transport — the guard every write verb
    /// on a connection-scoped backend opens with.
    @Test("a path on another backend is refused before anything is asked")
    func refusesForeignPath() {
        let transport = FakeSFTPTransport()
        #expect(throws: (any Error).self) {
            try sftpBackend(transport).createFile(at: .local("/tmp/notes.txt"))
        }
        #expect(transport.createdFiles.isEmpty)
    }
}

/// `RemoteTransportBackend.createDirectory` — the sibling of the above, and the one with a caller
/// that genuinely believed the contract.
///
/// Neither wire protocol says "already exists": `sftp` answers a bare `Failure` (OpenSSH's SFTP v3
/// has no such status) and FTP answers 550, its one ambiguous refusal — measured 2026-08-23. So
/// `PanelViewController+Copy.submitBranchTransfer`, which skips an existing intermediate directory
/// by catching `.alreadyExists`, never caught anything on a server and failed the whole transfer;
/// and F7 reported the wrong sentence for a taken name. Driven through both backends for the same
/// reason the file suite is: the implementation is shared, so asking one proves nothing about the
/// other.
@Suite("Remote createDirectory")
struct RemoteCreateDirectoryTests {
    private let sftpLocation = SFTPLocation(host: "example.com", port: 22, username: "oleg")
    private let ftpLocation = FTPLocation(
        host: "nas.local",
        port: 21,
        username: "sa",
        security: .explicit
    )

    private func sftpPath(_ remote: String) -> VFSPath {
        VFSPath(backend: .sftp(sftpLocation), path: remote)
    }

    private func ftpPath(_ remote: String) -> VFSPath {
        VFSPath(backend: .ftp(ftpLocation), path: remote)
    }

    private func sftpBackend(_ transport: FakeSFTPTransport) -> SFTPBackend {
        SFTPBackend(location: sftpLocation, transport: transport)
    }

    private func ftpBackend(_ transport: FakeFTPTransport) -> FTPBackend {
        FTPBackend(location: ftpLocation, transport: transport)
    }

    // MARK: - The refusal a caller can act on

    /// `sftp`'s real refusal, verbatim, which classifies as `.failure` → `.io` and is the error the
    /// dead `catch` was silently receiving.
    @Test("SFTP: a taken name answers alreadyExists, not the server's generic Failure")
    func sftpTakenNameIsAlreadyExists() {
        let transport = FakeSFTPTransport()
        transport.makeDirectoryError = .failure(#"remote mkdir "/home/oleg/photos": Failure"#)
        transport.listings["/home/oleg/photos"] =
            "drwxr-xr-x ? oleg staff 64 Jul 13 00:09 /home/oleg/photos/."
        #expect(throws: VFSError.alreadyExists(sftpPath("/home/oleg/photos"))) {
            try sftpBackend(transport).createDirectory(at: sftpPath("/home/oleg/photos"))
        }
    }

    /// FTP's 550 reads as `.notFound` — the wrong answer in the most confusing direction, since the
    /// name is refused precisely because it *is* there.
    @Test("FTP: a taken name answers alreadyExists, not notFound")
    func ftpTakenNameIsAlreadyExists() {
        let transport = FakeFTPTransport()
        transport.makeDirectoryError = .notFound
        transport.listings["/pub"] = "drwxr-xr-x 2 sa users 4096 Jul 25 20:55 photos"
        #expect(throws: VFSError.alreadyExists(ftpPath("/pub/photos"))) {
            try ftpBackend(transport).createDirectory(at: ftpPath("/pub/photos"))
        }
    }

    /// A **file** holding the name is `.alreadyExists` too: the contract is "something is already
    /// there", and a caller that means to create a directory cannot proceed either way.
    @Test("a name held by a file is alreadyExists as well")
    func fileHoldingTheNameIsAlreadyExists() {
        let transport = FakeSFTPTransport()
        transport.makeDirectoryError = .failure("remote mkdir: Failure")
        transport.listings["/home/oleg/notes.txt"] =
            "-rw-r--r-- ? oleg staff 128 Jul 13 00:09 /home/oleg/notes.txt"
        #expect(throws: VFSError.alreadyExists(sftpPath("/home/oleg/notes.txt"))) {
            try sftpBackend(transport).createDirectory(at: sftpPath("/home/oleg/notes.txt"))
        }
    }

    // MARK: - Narrowness

    /// The half that keeps the fix from becoming "every refusal is a collision". A `mkdir` refused
    /// for a reason that is *not* the name — a missing parent, a read-only directory — must keep
    /// its own error, or the user is sent to pick a different name for a folder that is free.
    @Test("SFTP: a refusal on a name that is free keeps the server's own error")
    func sftpFreeNameKeepsItsError() {
        let transport = FakeSFTPTransport()
        transport.makeDirectoryError = .permissionDenied
        // No listing for the path: the disambiguating stat finds nothing.
        #expect(throws: VFSError.permissionDenied(sftpPath("/home/oleg/new"))) {
            try sftpBackend(transport).createDirectory(at: sftpPath("/home/oleg/new"))
        }
    }

    @Test("FTP: a refusal on a name that is free keeps the server's own error")
    func ftpFreeNameKeepsItsError() {
        let transport = FakeFTPTransport()
        transport.makeDirectoryError = .permissionDenied
        transport.listings["/pub"] = "" // the parent lists, and the name is not in it
        #expect(throws: VFSError.permissionDenied(ftpPath("/pub/new"))) {
            try ftpBackend(transport).createDirectory(at: ftpPath("/pub/new"))
        }
    }

    /// The happy path pays nothing: a create that succeeds asks no second question, which is the
    /// whole reason the disambiguation sits in the `catch` rather than in front of the call.
    @Test("SFTP: a successful create costs no extra round trip")
    func sftpSuccessAsksNothingExtra() throws {
        let transport = FakeSFTPTransport()
        try sftpBackend(transport).createDirectory(at: sftpPath("/home/oleg/new"))
        #expect(transport.madeDirectories == ["/home/oleg/new"])
    }

    @Test("FTP: a successful create costs no extra round trip")
    func ftpSuccessAsksNothingExtra() throws {
        let transport = FakeFTPTransport()
        try ftpBackend(transport).createDirectory(at: ftpPath("/pub/new"))
        #expect(transport.madeDirectories == ["/pub/new"])
        #expect(transport.listedPaths.isEmpty)
    }

    /// A `stat` that cannot be had must not read as "the name is free" *or* as "the name is taken":
    /// the original error stands. Arranged with the fake's blanket `error`, which fails the listing
    /// too — a server that refused the `mkdir` and then dropped the connection.
    @Test("a stat that fails leaves the original error standing")
    func unanswerableStatKeepsTheOriginalError() {
        let transport = FakeSFTPTransport()
        transport.error = .permissionDenied
        #expect(throws: VFSError.permissionDenied(sftpPath("/home/oleg/new"))) {
            try sftpBackend(transport).createDirectory(at: sftpPath("/home/oleg/new"))
        }
    }
}
