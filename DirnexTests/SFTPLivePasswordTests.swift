import DirnexCore
import Foundation
import Testing

@testable import Dirnex

// Password authentication is its own mechanism — `sftp` cannot use `-b` for it (that forces
// `BatchMode=yes`, which disables the prompt), so it runs interactively with `SSH_ASKPASS` answering
// out-of-band, exits zero on a failed command, and needs its own gating fixture and its own local
// probe. Split out of `SFTPLiveIntegrationTests` at SwiftLint's `file_length` ceiling, by concept
// rather than by shaving lines.

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
