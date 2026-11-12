import Foundation
import Testing

@testable import DirnexCore

@Suite("An ssh session for Open in Terminal")
struct SSHTerminalSessionTests {
    private static let hostile = "/srv/it's a $dir \"x\" `touch y`; *\nline"
    private let location = SFTPLocation(host: "files.example", port: 2200, username: "me")

    private func session(
        authentication: SFTPAuthentication = .key(identityFile: "/keys/id"),
        directory: String = "/srv/www",
        dial: DialedHost = DialedHost(host: "files.example", restrictsToIPv4: false)
    ) -> SSHTerminalSession {
        SSHTerminalSession(
            location: location,
            dial: dial,
            authentication: authentication,
            directory: directory,
            connectTimeout: 15
        )
    }

    // MARK: - What ssh is told

    @Test("it asks for a terminal, and ends on the command that lands in the folder")
    func argumentsFrameTheSession() {
        let arguments = session().arguments
        #expect(arguments.first == "-t")
        #expect(arguments.last == #"cd '/srv/www'; exec "$SHELL" -l"#)
    }

    @Test("a key may ask a person, where the unattended channels may not")
    func onlyTheTerminalMayPrompt() {
        let dial = DialedHost(host: "h", restrictsToIPv4: false)
        let key = SFTPAuthentication.key(identityFile: "/keys/id")
        #expect(!session().arguments.contains("BatchMode=yes"))
        #expect(session().arguments.contains("/keys/id"))
        #expect(SFTPProcessArguments.exec(
            location: location, dial: dial, authentication: key, connectTimeout: 15, command: "x"
        ).contains("BatchMode=yes"))
        #expect(SFTPProcessArguments.batch(
            location: location, dial: dial, authentication: key, connectTimeout: 15
        ).contains("BatchMode=yes"))
    }

    @Test("a password account offers only the password method, once")
    func passwordOffersOneMethodOnce() {
        let arguments = session(authentication: .password).arguments
        #expect(arguments.contains("PreferredAuthentications=password"))
        #expect(arguments.contains("PubkeyAuthentication=no"))
        #expect(arguments.contains("NumberOfPasswordPrompts=1"))
        #expect(!arguments.contains("-i"))
    }

    @Test("it spells the port for ssh and keeps the browsing channel's host key policy")
    func portAndHostKeyPolicy() throws {
        let arguments = session().arguments
        let port = try #require(arguments.firstIndex(of: "-p"))
        #expect(arguments[port + 1] == "2200")
        #expect(!arguments.contains("-P"))
        #expect(arguments.contains("StrictHostKeyChecking=accept-new"))
        #expect(arguments.contains("ConnectTimeout=15"))
    }

    @Test("it dials the name that resolved, not the one typed")
    func dialsTheResolvedName() {
        let arguments = session(dial: DialedHost(host: "nas.local", restrictsToIPv4: true)).arguments
        #expect(arguments.contains("me@nas.local"))
        #expect(!arguments.contains("me@files.example"))
        #expect(arguments.contains("AddressFamily=inet"))
    }

    // MARK: - What the server's shell makes of it

    /// Run the remote command in a real shell, whose "login shell" writes down where it woke up.
    private func runRemoteCommand(in directory: String, fixture: SSHTerminalFixture) throws -> Bool {
        let shell = fixture.path("login-shell")
        try "#!/bin/sh\npwd -P > \"$RECORD/landed\"\nprintf '%s' \"$1\" > \"$RECORD/flag\"\n"
            .write(toFile: shell, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", session(directory: directory).remoteCommand]
        process.environment = ["SHELL": shell, "RECORD": fixture.directory, "PATH": "/usr/bin:/bin"]
        process.currentDirectoryURL = URL(fileURLWithPath: fixture.directory)
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @Test("a folder with a hostile name is entered, and nothing in the name runs")
    func hostileFolderIsEntered() throws {
        let fixture = try SSHTerminalFixture()
        defer { fixture.remove() }
        let name = "it's a $dir `touch CANARY`; \"x\"\nline"
        let folder = fixture.path(name)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        #expect(try runRemoteCommand(in: folder, fixture: fixture))

        let resolved = try #require(realpath(folder, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        #expect(try fixture.recorded("landed") == resolved + "\n")
        #expect(try fixture.recorded("flag") == "-l")
        #expect(!FileManager.default.fileExists(atPath: fixture.path("CANARY")))
    }

    @Test("a folder that has gone still gives a shell")
    func missingFolderStillGivesAShell() throws {
        let fixture = try SSHTerminalFixture()
        defer { fixture.remove() }
        #expect(try runRemoteCommand(in: fixture.path("gone"), fixture: fixture))
        #expect(try fixture.recorded("flag") == "-l")
    }

    // MARK: - The script

    @Test("through a real shell, ssh receives exactly these arguments")
    func shellHandsOverTheExactArguments() throws {
        let fixture = try SSHTerminalFixture()
        defer { fixture.remove() }
        let session = session(directory: Self.hostile)
        let script = try fixture.scriptFile(
            session.launchScript(askpassPath: nil, closePrompt: "Close")
        )
        try fixture.run(script)
        #expect(try fixture.recordedArguments() == session.arguments)
    }

    @Test("it deletes itself before anything else")
    func scriptDeletesItself() throws {
        let fixture = try SSHTerminalFixture()
        defer { fixture.remove() }
        let script = try fixture.scriptFile(
            session().launchScript(askpassPath: nil, closePrompt: "Close")
        )
        #expect(FileManager.default.fileExists(atPath: script))
        try fixture.run(script)
        #expect(!FileManager.default.fileExists(atPath: script))
    }

    @Test("a key account arms no askpass")
    func keyArmsNoAskpass() throws {
        let fixture = try SSHTerminalFixture()
        defer { fixture.remove() }
        let script = try fixture.scriptFile(
            session().launchScript(askpassPath: nil, closePrompt: "Close")
        )
        try fixture.run(script)
        #expect(try fixture.recorded("askpass") == "unset")
        #expect(try fixture.recorded("require") == "unset")
    }

    @Test("a password account forces the helper even with a terminal attached")
    func passwordForcesTheHelper() throws {
        let fixture = try SSHTerminalFixture()
        defer { fixture.remove() }
        let helper = fixture.path("it's askpass")
        try "#!/bin/sh\nprintf answered\n".write(toFile: helper, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper)
        let script = try fixture.scriptFile(
            session(authentication: .password).launchScript(
                askpassPath: helper,
                closePrompt: "Close"
            )
        )
        try fixture.run(script)
        #expect(try fixture.recorded("askpass") == helper)
        #expect(try fixture.recorded("require") == "force")
        #expect(try fixture.recorded("answer") == "answered")
    }

    @Test(
        "only ssh's own failure waits for a Return, and the status comes through",
        arguments: [(Int32(255), true), (Int32(0), false), (Int32(1), false), (Int32(130), false)]
    )
    func onlyFailureToConnectPauses(status: Int32, pauses: Bool) throws {
        let fixture = try SSHTerminalFixture()
        defer { fixture.remove() }
        let script = try fixture.scriptFile(
            session().launchScript(askpassPath: nil, closePrompt: "It's time to go")
        )
        let result = try fixture.run(script, standInStatus: status)
        #expect(result.status == status)
        #expect(result.output.contains("It's time to go") == pauses)
    }
}
