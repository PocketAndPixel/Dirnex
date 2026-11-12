import Darwin
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The real Unix socket between the command and the app (PLAN.md §M37 Slice 6), in a scratch folder.
@Suite("git merge tool: the socket")
struct GitMergeSocketTests: GitMergeSocketTesting {
    @Test("a request crosses the socket and its answer comes back")
    func roundTrip() async throws {
        let scratch = try GitMergeScratch()
        defer { scratch.cleanup() }
        let received = GitMergeReceived()
        let listener = try GitMergeListener(path: scratch.socket) { received.add($0, $1) }
        defer { listener.stop() }
        let connection = try client(scratch.socket)
        try GitMergeWire.send(request, over: connection)
        try await wait { !received.all.isEmpty }
        #expect(received.all == [request])
        try GitMergeWire.send(GitMergeAnswer.refused("Nö"), over: #require(received.last))
        #expect(try GitMergeWire.receive(GitMergeAnswer.self, over: connection) == .refused("Nö"))
    }

    @Test("the whole client runs against the real listener")
    func wholeClient() async throws {
        let scratch = try GitMergeScratch()
        defer { scratch.cleanup() }
        let listener = try GitMergeListener(path: scratch.socket) { _, connection in
            try? GitMergeWire.send(GitMergeAnswer.saved, over: connection)
            connection.close()
        }
        defer { listener.stop() }
        let socket = scratch.socket
        let finished = await BlockingWork.run {
            GitMergeCommand.run(
                ["Dirnex", GitMergeArguments.flag, "./l", "./b", "./r", "m"],
                currentDirectory: "/repo",
                socket: socket,
                bundlePath: "/no/such/Dirnex.app"
            )
        }
        #expect(finished == GitMergeClient.Finished(exitCode: 0, message: nil))
    }

    @Test("the command's relative paths arrive absolute")
    func absoluteOnArrival() async throws {
        let scratch = try GitMergeScratch()
        defer { scratch.cleanup() }
        let received = GitMergeReceived()
        let listener = try GitMergeListener(path: scratch.socket) { request, connection in
            received.add(request, connection)
            try? GitMergeWire.send(GitMergeAnswer.notSaved, over: connection)
        }
        defer { listener.stop() }
        let socket = scratch.socket
        let finished = await BlockingWork.run {
            GitMergeCommand.run(
                [
                    "Dirnex",
                    GitMergeArguments.flag,
                    "./a_LOCAL_1.txt",
                    "./a_BASE_1.txt",
                    "./a_REMOTE_1.txt",
                    "sub/a.txt"
                ],
                currentDirectory: "/Users/me/repo",
                socket: socket,
                bundlePath: "/no/such/Dirnex.app"
            )
        }
        #expect(finished.exitCode == 1)
        #expect(received.all == [GitMergeRequest(
            local: "/Users/me/repo/a_LOCAL_1.txt",
            base: "/Users/me/repo/a_BASE_1.txt",
            remote: "/Users/me/repo/a_REMOTE_1.txt",
            merged: "/Users/me/repo/sub/a.txt"
        )])
    }

    @Test("wrong arguments print the usage without touching a socket")
    func usage() {
        let finished = GitMergeCommand.run(
            ["Dirnex", GitMergeArguments.flag, "only", "three", "paths"],
            currentDirectory: "/repo",
            socket: "/no/such/socket",
            bundlePath: "/no/such/Dirnex.app"
        )
        #expect(finished == GitMergeClient.Finished(exitCode: 1, message: GitMergeArguments.usage))
    }

    @Test("a socket path too long to use is said, not tried")
    func noSocket() {
        let finished = GitMergeCommand.run(
            ["Dirnex", GitMergeArguments.flag, "l", "b", "r", "m"],
            currentDirectory: "/repo",
            socket: nil,
            bundlePath: "/no/such/Dirnex.app"
        )
        #expect(finished.exitCode == 1)
        #expect(finished.message?.contains("socket") == true)
    }

    @Test("with nothing listening and no app to start, the command says so and exits 1")
    func noApp() async throws {
        let scratch = try GitMergeScratch()
        defer { scratch.cleanup() }
        let socket = scratch.socket
        let finished = await BlockingWork.run {
            GitMergeCommand.run(
                ["Dirnex", GitMergeArguments.flag, "l", "b", "r", "m"],
                currentDirectory: "/repo",
                socket: socket,
                bundlePath: scratch.folder.appendingPathComponent("Missing.app").path
            )
        }
        #expect(
            finished == GitMergeClient.Finished(exitCode: 1, message: "Dirnex couldn't be started.")
        )
    }

    @Test("no socket at the path is not listening")
    func absent() throws {
        let scratch = try GitMergeScratch()
        defer { scratch.cleanup() }
        guard case .notListening = GitMergeSocket.connect(to: scratch.socket) else {
            Issue.record("expected notListening")
            return
        }
    }
}
