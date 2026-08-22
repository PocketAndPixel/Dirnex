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
