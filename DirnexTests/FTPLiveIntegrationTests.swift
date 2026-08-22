import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// End-to-end FTP/FTPS **writes** against a real server, exercising the actual `FTPCurlTransport`
/// (spawning `curl`) → `FTPBackend` chain, for the one verb whose behaviour is decided by the
/// server rather than by us: ⇧F4's `createFile` (PLAN.md §M11).
///
/// Gated on a config file so it never runs in CI, exactly as `SFTPLiveIntegrationTests` is: drop a
/// JSON file at `/tmp/dirnex_ftp_live_test.json` with
/// `{ "host": …, "port": 21, "user": …, "password": …, "security": "plain"|"explicit"|"implicit",
/// "remotePath": …, "trustedPublicKey": … }` for a reachable, **writable** account. The pin is
/// optional and is what an FTPS server usually needs: a NAS's certificate is self-signed, so
/// verification against the system store can never pass and trust is granted by fingerprint
/// instead (PLAN.md §M13) — `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der |
/// openssl dgst -sha256 -binary | base64` is the value. A file rather than environment
/// variables, because `xcodebuild` does not forward the shell environment to the test runner
/// (docs/NOTES.md ▸ Testing).
///
/// `pyftpdlib` on `127.0.0.1:2121` is enough to run it, and it is also the only way to reach the
/// `STOR` fallback deliberately: withdraw the append permission from the account (pyftpdlib's `a`
/// in its `perm` string) and this suite must still pass, because `APPE` is then refused with 550
/// while `STOR` succeeds on the same connection. Both configurations were run 2026-08-23.
///
/// **What is deliberately *not* asserted here is that a create leaves an existing file's bytes
/// alone**, even though that is the whole reason `APPE` is preferred. It is true on a server that
/// offers `APPE` and false on one that does not, so as a live assertion it is a claim about the
/// endpoint wearing a claim about the code — the shape docs/NOTES.md records as the kind that
/// expires the day the suite meets a different server. It was measured directly against both
/// (`APPE` leaves 5 bytes standing, `STOR` truncates them), and what this project can actually
/// hold itself to — that the non-destructive verb is the one tried first — is pinned
/// deterministically in `FTPProcessArgumentsTests`.
@Suite("FTP live integration", .enabled(if: FTPLiveEnvironment.current != nil))
struct FTPLiveIntegrationTests {
    private func makeBackend() throws -> (FTPBackend, FTPLiveEnvironment.Config) {
        let config = try #require(FTPLiveEnvironment.current)
        let transport = FTPCurlTransport(
            location: config.location,
            authentication: config.authentication,
            password: config.password,
            trustedPublicKey: config.trustedPublicKey
        )
        return (FTPBackend(location: config.location, transport: transport), config)
    }

    /// ⇧F4 end to end. The claims are the same three the SFTP live test makes, and one of them
    /// lands differently here on purpose: `curl` refuses an upload onto a directory with 550 where
    /// `sftp` quietly fills it, so this asserts the *refusal* comes from our own guard by checking
    /// the error is `.alreadyExists` rather than whatever the server would have said.
    @Test("creates an empty file, and refuses a name a file or a directory already holds")
    func createsEmptyFile() async throws {
        // Off the cooperative pool: every verb below blocks on `curl` for a real network round
        // trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let base = VFSPath(backend: .ftp(config.location), path: config.remotePath)
            let dir = base.appending("dirnex_create_test_\(UUID().uuidString)")
            try backend.createDirectory(at: dir)
            defer { try? backend.removeItem(at: dir) }

            // A free name is created, empty, and is a *file*. On a server that offers `APPE` this
            // went out as one; on one that does not, the `STOR` fallback did — the assertion cannot
            // tell, which is the point of having the fallback at all.
            let file = dir.appending("notes.txt")
            try backend.createFile(at: file)
            let created = try backend.stat(at: file)
            #expect(created.kind == .file)
            #expect(created.byteSize == 0)

            // The same name again is refused by our own guard, and the existing file survives —
            // `STOR` would have truncated it, and this is the assertion that says it did not.
            #expect(throws: VFSError.alreadyExists(file)) {
                try backend.createFile(at: file)
            }
            #expect(try backend.stat(at: file).byteSize == 0)

            // A name held by a directory is refused before any upload is attempted.
            let occupied = dir.appending("photos")
            try backend.createDirectory(at: occupied)
            #expect(throws: VFSError.alreadyExists(occupied)) {
                try backend.createFile(at: occupied)
            }
            #expect(try backend.listDirectory(at: occupied).isEmpty)
        }
    }

    /// FTP's refusal for a taken name is **550**, its single ambiguous "file unavailable", which the
    /// classifier reads as `.notFound` — the wrong answer in the most confusing direction, since the
    /// name is refused precisely because it is there. The backend disambiguates with a `stat`.
    @Test("a directory name that is taken answers alreadyExists")
    func createDirectoryRefusesATakenName() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let base = VFSPath(backend: .ftp(config.location), path: config.remotePath)
            let dir = base.appending("dirnex_mkdir_test_\(UUID().uuidString)")
            try backend.createDirectory(at: dir)
            defer { try? backend.removeItem(at: dir) }

            #expect(throws: VFSError.alreadyExists(dir)) {
                try backend.createDirectory(at: dir)
            }
            // Live narrowness control: a refusal that is not about the name keeps its own error.
            let orphan = dir.appending("no_such_parent/child")
            #expect(throws: VFSError.notFound(orphan)) {
                try backend.createDirectory(at: orphan)
            }
        }
    }
}

/// The opt-in configuration for the live FTP suite — the same file-gated shape
/// `SFTPLiveEnvironment` uses, for the same reason.
enum FTPLiveEnvironment {
    struct Config {
        let location: FTPLocation
        let authentication: FTPAuthentication
        let password: String
        let trustedPublicKey: String?
        let remotePath: String
    }

    /// The opt-in config path. A file here turns the suite on; its absence keeps it off in CI.
    static let configPath = "/tmp/dirnex_ftp_live_test.json"

    private struct File: Decodable {
        let host: String
        let port: Int?
        let user: String
        let password: String?
        let security: String?
        let trustedPublicKey: String?
        let remotePath: String
    }

    static var current: Config? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        let security: FTPSecurity
        switch file.security {
        case "plain": security = .plain
        case "implicit": security = .implicit
        default: security = .explicit
        }
        return Config(
            location: FTPLocation(
                host: file.host,
                port: file.port,
                username: file.user,
                security: security
            ),
            authentication: file.user == "anonymous" ? .anonymous : .password,
            password: file.password ?? "",
            trustedPublicKey: file.trustedPublicKey,
            remotePath: file.remotePath
        )
    }
}
