import Foundation
import Testing

@testable import DirnexCore

/// A transport that answers `connect` from a script and keeps a clock of its own, which only
/// `sleep` moves, so a 60-second wait takes no time.
final class ScriptedGitMergeTransport: GitMergeClientTransport {
    /// What each `connect` answers, in order. The last one repeats.
    private var connects: [GitMergeConnectResult<FakeGitMergeConnection>]
    private let opens: Bool
    private var clock = 100.0
    private(set) var connectCount = 0
    private(set) var openCount = 0
    private(set) var slept: [Double] = []

    init(connects: [GitMergeConnectResult<FakeGitMergeConnection>], opens: Bool = true) {
        self.connects = connects
        self.opens = opens
    }

    func connect() -> GitMergeConnectResult<FakeGitMergeConnection> {
        connectCount += 1
        return connects.count > 1 ? connects.removeFirst() : connects[0]
    }

    func openApp() -> Bool {
        openCount += 1
        return opens
    }

    func sleep(seconds: Double) {
        slept.append(seconds)
        clock += seconds
    }

    func uptime() -> Double {
        clock
    }
}

/// The command's whole conversation with the app (PLAN.md §M37 Slice 6).
@Suite("git merge tool: the command")
struct GitMergeClientTests {
    private let request = GitMergeRequest(
        local: "/t/l",
        base: "/t/b",
        remote: "/t/r",
        merged: "/w/m"
    )

    private func answering(_ answer: GitMergeAnswer) throws -> FakeGitMergeConnection {
        try FakeGitMergeConnection(incoming: GitMergeWire.frame(answer))
    }

    @Test("with the app up, it is brought forward once and the request goes out")
    func appUp() throws {
        let connection = try answering(.saved)
        let transport = ScriptedGitMergeTransport(connects: [.connected(connection)])
        let finished = GitMergeClient.run(request, transport: transport)
        #expect(finished == GitMergeClient.Finished(exitCode: 0, message: nil))
        #expect(transport.openCount == 1)
        #expect(transport.connectCount == 1)
        #expect(try connection.written == GitMergeWire.frame(request))
    }

    @Test("an app that is up but can't be brought forward still gets the request")
    func cannotBringForward() throws {
        let connection = try answering(.saved)
        let transport = ScriptedGitMergeTransport(connects: [.connected(connection)], opens: false)
        #expect(GitMergeClient.run(request, transport: transport).exitCode == 0)
        #expect(try connection.written == GitMergeWire.frame(request))
    }

    @Test("a window closed without saving exits 1, with nothing to print")
    func notSaved() throws {
        let transport = try ScriptedGitMergeTransport(connects: [.connected(answering(.notSaved))])
        #expect(GitMergeClient.run(request, transport: transport) ==
            GitMergeClient.Finished(exitCode: 1, message: nil))
    }

    @Test("a refusal exits 1 and prints the app's sentence")
    func refused() throws {
        let transport = try ScriptedGitMergeTransport(
            connects: [.connected(answering(.refused("Not text.")))]
        )
        #expect(GitMergeClient.run(request, transport: transport) ==
            GitMergeClient.Finished(exitCode: 1, message: "Not text."))
    }

    @Test("with nothing listening the app is launched once, and the socket tried until it answers")
    func launches() throws {
        let transport = try ScriptedGitMergeTransport(connects: [
            .notListening,
            .notListening,
            .notListening,
            .connected(answering(.saved))
        ])
        let finished = GitMergeClient.run(request, transport: transport)
        #expect(finished.exitCode == 0)
        #expect(transport.openCount == 1)
        #expect(transport.connectCount == 4)
        #expect(transport.slept == [GitMergeClient.pollInterval, GitMergeClient.pollInterval])
    }

    @Test("an app that never listens is given up on after the wait, and says so")
    func neverListens() throws {
        let transport = ScriptedGitMergeTransport(connects: [.notListening])
        let finished = GitMergeClient.run(request, transport: transport)
        #expect(finished.exitCode == 1)
        #expect(finished.message == "Dirnex was started but didn't answer within 60 seconds.")
        #expect(transport.openCount == 1)
        // A sum of many small sleeps, so about the wait rather than exactly it.
        #expect(
            abs(transport.slept.reduce(0, +) - GitMergeClient.launchWait) <= GitMergeClient.pollInterval * 2
        )
    }

    @Test("an app that can't be launched is not waited for")
    func cannotLaunch() {
        let transport = ScriptedGitMergeTransport(connects: [.notListening], opens: false)
        let finished = GitMergeClient.run(request, transport: transport)
        #expect(
            finished == GitMergeClient.Finished(exitCode: 1, message: "Dirnex couldn't be started.")
        )
        #expect(transport.slept.isEmpty)
        #expect(transport.connectCount == 1)
    }

    @Test("a socket that fails is reported and nothing is opened")
    func connectFails() {
        let transport = ScriptedGitMergeTransport(connects: [.failed("Permission denied")])
        let finished = GitMergeClient.run(request, transport: transport)
        #expect(finished == GitMergeClient.Finished(
            exitCode: 1,
            message: "Dirnex couldn't be reached: Permission denied"
        ))
        #expect(transport.openCount == 0)
    }

    @Test("a socket that fails during the wait stops the wait")
    func connectFailsWhileWaiting() {
        let transport = ScriptedGitMergeTransport(
            connects: [.notListening, .failed("Too many open files")]
        )
        let finished = GitMergeClient.run(request, transport: transport)
        #expect(finished.message == "Dirnex couldn't be reached: Too many open files")
        #expect(transport.connectCount == 2)
        #expect(transport.slept.isEmpty)
    }

    @Test("an app that goes away before answering exits 1, since nothing says a result was saved")
    func closedBeforeAnswer() {
        let transport = ScriptedGitMergeTransport(connects: [.connected(FakeGitMergeConnection())])
        #expect(GitMergeClient.run(request, transport: transport) == GitMergeClient.Finished(
            exitCode: 1,
            message: "Dirnex closed before the merge was finished."
        ))
    }

    @Test("an answer that can't be read exits 1")
    func unreadableAnswer() throws {
        let frame = try GitMergeWire.frame(["outcome": "maybe"])
        let transport = ScriptedGitMergeTransport(
            connects: [.connected(FakeGitMergeConnection(incoming: frame))]
        )
        let finished = GitMergeClient.run(request, transport: transport)
        #expect(
            finished == GitMergeClient.Finished(
                exitCode: 1,
                message: "Dirnex sent an answer that couldn't be read."
            )
        )
    }

    @Test("the app launched from here starts with a Dock launch's environment, not git's")
    func launchEnvironment() {
        let kept = GitMergeClient.launchEnvironment(from: [
            "HOME": "/Users/me",
            "USER": "me",
            "LOGNAME": "me",
            "SHELL": "/bin/zsh",
            "TMPDIR": "/var/folders/x/T/",
            "SSH_AUTH_SOCK": "/private/tmp/agent",
            "__CF_USER_TEXT_ENCODING": "0x1F5:0:0",
            "PATH": "/Users/me/venv/bin:/usr/bin",
            "GIT_EXEC_PATH": "/x/git-core",
            "GIT_EDITOR": "true",
            "GIT_PREFIX": ".",
            "GIT_DIR": "/repo/.git",
            "GIT_WORK_TREE": "/repo",
            "VIRTUAL_ENV": "/Users/me/venv",
            "LANG": "de_DE.UTF-8"
        ])
        #expect(kept == [
            "HOME": "/Users/me",
            "USER": "me",
            "LOGNAME": "me",
            "SHELL": "/bin/zsh",
            "TMPDIR": "/var/folders/x/T/",
            "SSH_AUTH_SOCK": "/private/tmp/agent",
            "__CF_USER_TEXT_ENCODING": "0x1F5:0:0",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ])
    }

    @Test("a request that can't be written exits 1, and no answer is waited for")
    func writeFails() throws {
        let connection = try FakeGitMergeConnection(
            incoming: GitMergeWire.frame(GitMergeAnswer.saved),
            writeFailure: .failed("Broken pipe")
        )
        let transport = ScriptedGitMergeTransport(connects: [.connected(connection)])
        let finished = GitMergeClient.run(request, transport: transport)
        #expect(
            finished == GitMergeClient.Finished(
                exitCode: 1,
                message: "Dirnex couldn't be reached: Broken pipe"
            )
        )
        #expect(connection.reads == 0)
    }
}
