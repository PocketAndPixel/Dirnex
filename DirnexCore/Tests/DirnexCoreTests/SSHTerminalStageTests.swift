import Foundation
import Testing

@testable import DirnexCore

@Suite("What Open in Terminal leaves on disk")
struct SSHTerminalStageTests {
    private static let secret = "s3cret-Pässword"

    private func session(_ authentication: SFTPAuthentication) -> SSHTerminalSession {
        SSHTerminalSession(
            location: SFTPLocation(host: "files.example", port: 22, username: "me"),
            dial: DialedHost(host: "files.example", restrictsToIPv4: false),
            authentication: authentication,
            directory: "/srv/www",
            connectTimeout: 15
        )
    }

    private func stage(
        in fixture: SSHTerminalFixture,
        authentication: SFTPAuthentication = .password,
        secret: String? = SSHTerminalStageTests.secret,
        patience: TimeInterval = 20
    ) throws -> SSHTerminalStage {
        try SSHTerminalStage(
            session: session(authentication),
            secret: secret,
            closePrompt: "Close",
            root: fixture.path("root"),
            patience: patience
        )
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        #expect(lstat(path, &info) == 0)
        return info.st_mode & 0o777
    }

    private func gone(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) != 0
    }

    @Test("a password stage is private and carries no secret in any file")
    func passwordStageIsPrivateAndSecretFree() throws {
        let fixture = try SSHTerminalFixture()
        defer { fixture.remove() }
        let stage = try stage(in: fixture)
        defer { stage.discard() }

        #expect(mode(stage.directory) == 0o700)
        #expect(mode(stage.scriptPath) == 0o700)
        let names = try FileManager.default.contentsOfDirectory(atPath: stage.directory).sorted()
        #expect(names == ["askpass", "secret", "session.command"])
        #expect(mode((stage.directory as NSString).appendingPathComponent("askpass")) == 0o700)

        for name in ["askpass", "session.command"] {
            let contents = try Data(
                contentsOf: URL(fileURLWithPath: stage.directory).appendingPathComponent(name)
            )
            #expect(contents.range(of: Data(Self.secret.utf8)) == nil)
        }
        var info = stat()
        #expect(lstat(try #require(stage.secretPipe?.path), &info) == 0)
        #expect(info.st_size == 0)
    }

    @Test("a key stage is only the script")
    func keyStageIsOnlyTheScript() throws {
        let fixture = try SSHTerminalFixture()
        defer { fixture.remove() }
        let stage = try stage(in: fixture, authentication: .key(identityFile: "/k"), secret: nil)
        defer { stage.discard() }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: stage.directory) == [
                "session.command"
            ]
        )
        #expect(
            try !String(contentsOfFile: stage.scriptPath, encoding: .utf8).contains("SSH_ASKPASS")
        )
    }

    @Test("the password reaches ssh's helper once, stays out of its arguments, and nothing is left")
    func passwordReachesTheHelper() async throws {
        let fixture = try SSHTerminalFixture()
        defer { fixture.remove() }
        let stage = try stage(in: fixture)
        try fixture.substituteStandIn(in: stage.scriptPath)

        async let delivered = BlockingWork.run { stage.finish() }
        try fixture.run(stage.scriptPath)

        #expect(await delivered)
        #expect(try fixture.recorded("answer") == Self.secret + "\n")
        #expect(try !fixture.recordedArguments().joined(separator: " ").contains(Self.secret))
        #expect(gone(stage.directory))
    }

    @Test("a key stage waits for the script to run, then removes itself")
    func keyStageWaitsForTheScript() async throws {
        let fixture = try SSHTerminalFixture()
        defer { fixture.remove() }
        let stage = try stage(in: fixture, authentication: .key(identityFile: "/k"), secret: nil)
        try fixture.substituteStandIn(in: stage.scriptPath)

        async let taken = BlockingWork.run { stage.finish() }
        try fixture.run(stage.scriptPath)

        #expect(await taken)
        #expect(gone(stage.directory))
    }

    @Test(
        "a terminal that never comes costs nothing but the wait",
        arguments: [SFTPAuthentication.password, .key(identityFile: "/k")]
    )
    func terminalThatNeverComes(authentication: SFTPAuthentication) throws {
        let fixture = try SSHTerminalFixture()
        defer { fixture.remove() }
        let secret = authentication == .password ? Self.secret : nil
        let stage = try stage(
            in: fixture,
            authentication: authentication,
            secret: secret,
            patience: 0.1
        )
        #expect(!stage.finish())
        #expect(gone(stage.directory))
    }

    @Test("a terminal that could not be launched leaves nothing")
    func discardRemovesEverything() throws {
        let fixture = try SSHTerminalFixture()
        defer { fixture.remove() }
        let stage = try stage(in: fixture)
        stage.discard()
        #expect(gone(stage.directory))
    }
}
