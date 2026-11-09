import Darwin
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The socket's life and its refusals (PLAN.md §M37 Slice 6): what a copy that died leaves, what a
/// client that misbehaves can do, and what each descriptor is set up with.
@Suite("git merge tool: the socket's edges")
struct GitMergeSocketEdgeTests: GitMergeSocketTesting {
    /// Leave a socket file after closing its listener, as a copy that crashed does.
    private func leaveStaleSocket(at path: String) throws {
        let descriptor = try #require(GitMergeSocket.make())
        #expect(GitMergeSocket.withAddress(of: path) { bind(descriptor, $0, $1) } == 0)
        #expect(listen(descriptor, 1) == 0)
        close(descriptor)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("a socket left by a copy that died is not listening, and the next copy takes it over")
    func stale() async throws {
        let scratch = try GitMergeScratch()
        defer { scratch.cleanup() }
        try leaveStaleSocket(at: scratch.socket)
        // A concurrent spawn can still hold the listener until exec. If it accepts a connection,
        // wait for that connection to end. Repeated connects can fill the backlog and be refused
        // while the listener is still open, which would be a false witness that it is stale.
        if case let .connected(connection) = GitMergeSocket.connect(to: scratch.socket) {
            defer { connection.close() }
            connection.setReadTimeout(seconds: 30)
            let end = try await offCooperativePool {
                do {
                    return try connection.read(upTo: 1)
                } catch GitMergeWire.Failure.closed {
                    return Data()
                }
            }
            try #require(end.isEmpty)
        }
        guard case .notListening = GitMergeSocket.connect(to: scratch.socket) else {
            Issue.record("expected notListening")
            return
        }
        let received = GitMergeReceived()
        let listener = try GitMergeListener(path: scratch.socket) { received.add($0, $1) }
        defer { listener.stop() }
        try GitMergeWire.send(request, over: client(scratch.socket))
        try await wait { received.all == [request] }
    }

    @Test("the socket is readable by this user alone")
    func permissions() throws {
        let scratch = try GitMergeScratch()
        defer { scratch.cleanup() }
        let listener = try GitMergeListener(path: scratch.socket) { _, _ in }
        defer { listener.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: scratch.socket)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("a stopped listener takes its socket away, and stopping twice is harmless")
    func stopping() throws {
        let scratch = try GitMergeScratch()
        defer { scratch.cleanup() }
        let listener = try GitMergeListener(path: scratch.socket) { _, _ in }
        listener.stop()
        #expect(!FileManager.default.fileExists(atPath: scratch.socket))
        listener.stop()
    }

    @Test("a folder that does not exist is a failure to listen, with the system's reason")
    func cannotListen() {
        #expect(throws: GitMergeListener.Failure.self) {
            _ = try GitMergeListener(path: "/tmp/gm-no-such-folder/s") { _, _ in }
        }
    }

    @Test("a client that says nothing does not hold up the next one")
    func silentClient() async throws {
        let scratch = try GitMergeScratch()
        defer { scratch.cleanup() }
        let received = GitMergeReceived()
        let listener = try GitMergeListener(path: scratch.socket) { received.add($0, $1) }
        defer { listener.stop() }
        let silent = try client(scratch.socket)
        defer { silent.close() }
        try GitMergeWire.send(request, over: client(scratch.socket))
        // Well inside the time the silent one could hold a serial queue for.
        try await wait(within: .seconds(GitMergeListener.requestTimeoutSeconds - 2)) {
            received.all == [request]
        }
    }

    @Test("bytes that are not a request get no answer and reach nothing")
    func garbage() async throws {
        let scratch = try GitMergeScratch()
        defer { scratch.cleanup() }
        let received = GitMergeReceived()
        let listener = try GitMergeListener(path: scratch.socket) { received.add($0, $1) }
        defer { listener.stop() }
        let connection = try client(scratch.socket)
        // So a wrong answer fails here rather than waiting forever.
        connection.setReadTimeout(seconds: 10)
        try connection.write(Data([0, 0, 0, 3, 0xFF, 0xFE, 0xFD]))
        let answer = await BlockingWork.run { () -> Result<GitMergeAnswer, GitMergeWire.Failure> in
            do throws(GitMergeWire.Failure) {
                return try .success(GitMergeWire.receive(GitMergeAnswer.self, over: connection))
            } catch {
                return .failure(error)
            }
        }
        #expect(answer == .failure(.closed))
        #expect(received.all.isEmpty)
    }

    @Test("answering a command that has gone is not fatal")
    func answerToNobody() async throws {
        let scratch = try GitMergeScratch()
        defer { scratch.cleanup() }
        let received = GitMergeReceived()
        let listener = try GitMergeListener(path: scratch.socket) { received.add($0, $1) }
        defer { listener.stop() }
        let connection = try client(scratch.socket)
        try GitMergeWire.send(request, over: connection)
        try await wait { !received.all.isEmpty }
        connection.close()
        let server = try #require(received.last)
        // A concurrent posix_spawn briefly holds the peer until exec closes its descriptors,
        // even with FD_CLOEXEC. Wait for EOF before asserting EPIPE (docs/NOTES.md ▸ Testing).
        server.setReadTimeout(seconds: 30)
        let end = try await offCooperativePool { try server.read(upTo: 1) }
        try #require(end.isEmpty)
        // SO_NOSIGPIPE must turn the broken pipe into an error instead of ending the test host.
        #expect(throws: GitMergeWire.Failure.closed) {
            try GitMergeWire.send(GitMergeAnswer.saved, over: server)
        }
    }

    @Test("a socket is not inherited by a child and raises no SIGPIPE")
    func configured() throws {
        let descriptor = try #require(GitMergeSocket.make())
        defer { close(descriptor) }
        #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &value, &length) == 0)
        #expect(value != 0)
    }

    @Test("a closed connection refuses both ways")
    func closedConnection() throws {
        let descriptor = try #require(GitMergeSocket.make())
        let connection = GitMergeSocketConnection(descriptor: descriptor)
        connection.close()
        connection.close()
        #expect(throws: GitMergeWire.Failure.closed) { try connection.write(Data([1])) }
        #expect(throws: GitMergeWire.Failure.closed) { try connection.read(upTo: 1) }
        #expect(!connection.isSameUser)
    }

    @Test("a path too long for a socket is reported, not cut")
    func tooLong() {
        let path = "/tmp/" + String(repeating: "a", count: 200)
        guard case let .failed(reason) = GitMergeSocket.connect(to: path) else {
            Issue.record("expected a failure")
            return
        }
        #expect(!reason.isEmpty)
        #expect(GitMergeSocket.withAddress(of: path) { _, _ in true } == nil)
    }

    @Test("this copy's socket is under its own support folder")
    func location() throws {
        let path = try #require(GitMergeSocketLocation.path)
        let support = try #require(GitMergeSocketLocation.supportDirectory)
        #expect(path.hasPrefix(support.path + "/gm-"))
    }
}
