import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// End-to-end SFTP browse *and write* against a real server, exercising the actual
/// `SFTPProcessTransport` (spawning `sftp`) → `SFTPBackend` → `SFTPListingParser` chain, including a
/// mkdir/upload/download/recursive-remove round trip. Gated on a config file so it never runs in CI
/// (which has no server): drop a JSON file at `/tmp/dirnex_sftp_live_test.json` with
/// `{ "host": …, "port": 22, "user": …, "identityFile": …, "remotePath": … }` for a reachable
/// key-auth account (a file, not env vars, because `xcodebuild` doesn't forward the shell
/// environment to the test runner). Without the file the suite is skipped.
@Suite("SFTP live integration", .enabled(if: SFTPLiveEnvironment.current != nil))
struct SFTPLiveIntegrationTests {
    private func makeBackend() throws -> (SFTPBackend, SFTPLiveEnvironment.Config) {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        return (SFTPBackend(location: config.location, transport: transport), config)
    }

    @Test("resolves the remote home directory (proves auth + connection)")
    func resolvesHome() throws {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        let home = try transport.resolveHomeDirectory()
        #expect(home.hasPrefix("/"))
    }

    @Test("lists a real remote directory into FileEntry rows under the sftp backend")
    func listsRemoteDirectory() throws {
        let (backend, config) = try makeBackend()
        let path = VFSPath(backend: .sftp(config.location), path: config.remotePath)
        let entries = try backend.listDirectory(at: path)

        #expect(!entries.isEmpty)
        // The `.`/`..` self/parent rows are dropped; every child carries the sftp backend id.
        #expect(!entries.contains { $0.name == "." || $0.name == ".." })
        for entry in entries {
            #expect(entry.path.backend == .sftp(config.location))
            #expect(entry.path == path.appending(entry.name))
        }
    }

    @Test("stats the queried directory as a directory")
    func statsRemoteDirectory() throws {
        let (backend, config) = try makeBackend()
        let path = VFSPath(backend: .sftp(config.location), path: config.remotePath)
        let entry = try backend.stat(at: path)
        #expect(entry.isDirectory)
        #expect(entry.path == path)
    }

    @Test("browses through CompositeBackend routing after connectSFTP")
    func browsesThroughCompositeBackend() throws {
        let config = try #require(SFTPLiveEnvironment.current)
        let composite = CompositeBackend(local: LocalBackend())
        composite.connectSFTP(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        let path = VFSPath(backend: .sftp(config.location), path: config.remotePath)
        // The composite must route the sftp path to the connection registered above (not the local
        // backend) and report its writable-but-Trash-less capabilities.
        #expect(composite.capabilities(for: path) == [.read, .write, .rename])
        let entries = try composite.listDirectory(at: path)
        #expect(!entries.isEmpty)
    }

    @Test("round-trips a write end-to-end: mkdir → upload → list → download → recursive remove")
    func writeRoundTrip() throws {
        let (backend, config) = try makeBackend()
        let base = VFSPath(backend: .sftp(config.location), path: config.remotePath)
        // A unique scratch subtree under the remote path so a stray run never clobbers real data.
        let dir = base.appending("dirnex_write_test_\(UUID().uuidString)")

        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("dirnex_sftp_\(UUID().uuidString)")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let localSource = scratch.appendingPathComponent("hello.txt")
        let payload = Data("hello over sftp \(UUID().uuidString)".utf8)
        try payload.write(to: localSource)

        // mkdir on the remote, then upload the local file into it.
        try backend.createDirectory(at: dir)
        let remoteFile = dir.appending("hello.txt")
        try backend.copyFile(
            at: .local(localSource.path),
            to: remoteFile,
            progress: { _ in },
            isCancelled: { false }
        )

        // Listing the new remote directory shows the upload with its true size.
        let listed = try backend.listDirectory(at: dir)
        let uploaded = try #require(listed.first { $0.name == "hello.txt" })
        #expect(uploaded.byteSize == Int64(payload.count))

        // Download it back and confirm the bytes survived the round trip.
        let localDest = scratch.appendingPathComponent("roundtrip.txt")
        try backend.copyFile(
            at: remoteFile,
            to: .local(localDest.path),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(try Data(contentsOf: localDest) == payload)

        // Recursive remove empties and deletes the subtree; the directory is gone afterwards.
        try backend.removeItem(at: dir)
        #expect(throws: (any Error).self) {
            try backend.listDirectory(at: dir)
        }
    }

    @Test("resumes a partial transfer both ways: put -a then get -a reconstruct the whole file")
    func resumesPartialTransfer() throws {
        let (_, config) = try makeBackend()
        let transport = SFTPProcessTransport(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        let base = VFSPath(backend: .sftp(config.location), path: config.remotePath)
        let remote = base.appending("dirnex_resume_test_\(UUID().uuidString).bin").path

        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("dirnex_resume_\(UUID().uuidString)")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: scratch)
            try? transport.removeFile(remote)
        }

        // A known 300-byte payload, and a 120-byte prefix standing in for an interrupted transfer.
        let full = Data((0..<300).map { UInt8($0 % 256) })
        let prefix = full.prefix(120)
        let localFull = scratch.appendingPathComponent("full.bin")
        let localPrefix = scratch.appendingPathComponent("prefix.bin")
        try full.write(to: localFull)
        try Data(prefix).write(to: localPrefix)

        // Upload the prefix, then resume with the full file: `put -a` sends only bytes 120…300.
        try transport.upload(localPrefix.path, to: remote, resume: false)
        try transport.upload(localFull.path, to: remote, resume: true)

        // Download resume: a local 120-byte partial is filled to 300 by `get -a`.
        let localDownload = scratch.appendingPathComponent("download.bin")
        try Data(prefix).write(to: localDownload)
        try transport.download(remote, to: localDownload.path, resume: true)
        #expect(try Data(contentsOf: localDownload) == full)
    }

    @Test("maps a missing remote path to VFSError.notFound")
    func missingPathIsNotFound() throws {
        let (backend, config) = try makeBackend()
        let missing = VFSPath(
            backend: .sftp(config.location),
            path: config.remotePath + "/dirnex_definitely_missing_xyz"
        )
        #expect(throws: VFSError.notFound(missing)) {
            try backend.listDirectory(at: missing)
        }
    }
}

/// Exercises the real `SFTPProcessTransport` password path against the machine's own sshd, needing
/// no credential: a bogus account with a wrong password must fail *fast* as `.permissionDenied`
/// rather than hang waiting for a TTY, which only happens if the `SSH_ASKPASS` wiring answered the
/// prompt. Gated on `localhost:22` being reachable, so it runs where Remote Login is on and skips in
/// CI. (That the helper actually fires was also confirmed by a marker-file probe during development;
/// this guards the transport's argument/environment assembly end-to-end.)
@Suite("SFTP password auth mechanism", .enabled(if: LocalSSHDProbe.isReachable))
struct SFTPPasswordMechanismTests {
    @Test("the SSH_ASKPASS helper is written and executable")
    func askpassHelperIsExecutable() throws {
        let path = try SFTPAskpassHelper.scriptPath()
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }

    @Test("a wrong password classifies as permissionDenied through the real transport (no TTY hang)")
    func wrongPasswordIsPermissionDenied() {
        // The real account, so the server runs the full auth dance (a non-existent user is dropped
        // with a bare "Connection closed" instead) — askpass answers with the wrong password, the
        // server rejects it, and we classify it: a fast, deterministic failure, never a TTY hang.
        // (Costs one failed-auth log line on the loopback sshd per run — harmless on one's own Mac.)
        let location = SFTPLocation(host: "localhost", port: 22, username: NSUserName())
        let transport = SFTPProcessTransport(
            location: location,
            authentication: .password,
            password: "definitely-not-correct-\(UUID().uuidString)",
            connectTimeout: 10
        )
        #expect(throws: SFTPTransportError.permissionDenied) {
            _ = try transport.resolveHomeDirectory()
        }
    }
}

/// End-to-end *password* auth against a real server through the actual `SFTPProcessTransport`
/// (spawning `sftp` with `SSH_ASKPASS`). Gated on a JSON file at
/// `/tmp/dirnex_sftp_password_test.json` — `{ "host": …, "port": 22, "user": …, "password": … }` —
/// so a real credential never lives in the repo and CI skips it. The counterpart to the key-auth
/// suite above, for the password path.
@Suite("SFTP live password auth", .enabled(if: SFTPLivePasswordEnvironment.current != nil))
struct SFTPLivePasswordTests {
    @Test("authenticates with a password and resolves the remote home through the real transport")
    func authenticatesWithPassword() throws {
        let config = try #require(SFTPLivePasswordEnvironment.current)
        var transport = SFTPProcessTransport(
            location: config.location,
            authentication: .password,
            password: config.password
        )
        transport.passwordTimeout = 15 // some servers hold the channel; tolerateChannelHold covers it
        let home = try transport.resolveHomeDirectory()
        // Reaching a real remote path proves the password was accepted (a wrong one throws first).
        #expect(home.hasPrefix("/"))
    }
}

/// Reads live password-auth coordinates from a well-known JSON file; `nil` disables the suite.
enum SFTPLivePasswordEnvironment {
    static let configPath = "/tmp/dirnex_sftp_password_test.json"
    struct Config {
        let location: SFTPLocation
        let password: String
    }

    private struct File: Decodable {
        let host: String
        let port: Int?
        let user: String
        let password: String
    }

    static var current: Config? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return Config(
            location: SFTPLocation(
                host: file.host,
                port: file.port ?? SFTPLocation.defaultPort,
                username: file.user
            ),
            password: file.password
        )
    }
}

/// Whether the local machine's sshd is accepting connections on `localhost:22`, gating the password
/// mechanism suite. A blocking connect to loopback resolves immediately (accepted or refused).
enum LocalSSHDProbe {
    static var isReachable: Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(22).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }
}

/// Reads the live-SFTP test coordinates from a well-known JSON file; `nil` disables the suite.
enum SFTPLiveEnvironment {
    struct Config {
        let location: SFTPLocation
        let identityFile: String
        let remotePath: String
    }

    /// The opt-in config path. A file here turns the suite on; its absence keeps it off in CI.
    static let configPath = "/tmp/dirnex_sftp_live_test.json"

    private struct File: Decodable {
        let host: String
        let port: Int?
        let user: String
        let identityFile: String
        let remotePath: String
    }

    static var current: Config? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return Config(
            location: SFTPLocation(
                host: file.host,
                port: file.port ?? SFTPLocation.defaultPort,
                username: file.user
            ),
            identityFile: file.identityFile,
            remotePath: file.remotePath
        )
    }
}
