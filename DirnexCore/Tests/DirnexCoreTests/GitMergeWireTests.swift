import Foundation
import Testing

@testable import DirnexCore

/// A connection over bytes in memory: what the other end will send, and what this end has written.
/// Hands bytes back `chunk` at a time, as a socket may.
final class FakeGitMergeConnection: GitMergeConnection {
    private var incoming: Data
    private let chunk: Int
    private let writeFailure: GitMergeWire.Failure?
    private(set) var written = Data()
    private(set) var reads = 0

    init(incoming: Data = Data(), chunk: Int = .max, writeFailure: GitMergeWire.Failure? = nil) {
        self.incoming = incoming
        self.chunk = chunk
        self.writeFailure = writeFailure
    }

    func write(_ data: Data) throws(GitMergeWire.Failure) {
        if let writeFailure { throw writeFailure }
        written += data
    }

    func read(upTo count: Int) throws(GitMergeWire.Failure) -> Data {
        reads += 1
        let taken = incoming.prefix(min(count, chunk))
        incoming.removeFirst(taken.count)
        return Data(taken)
    }
}

/// What crosses the socket, and where the socket is (PLAN.md §M37 Slice 6).
@Suite("git merge tool: the wire")
struct GitMergeWireTests {
    private let request = GitMergeRequest(
        local: "/t/l",
        base: "/t/b",
        remote: "/t/r",
        merged: "/w/é m"
    )

    private func header(_ length: UInt32) -> Data {
        var bigEndian = length.bigEndian
        return Data(bytes: &bigEndian, count: 4)
    }

    @Test("a message is its length, big-endian, then JSON of that length")
    func frameShape() throws {
        let frame = try GitMergeWire.frame(GitMergeAnswer.saved)
        let body = frame.dropFirst(4)
        #expect(Array(frame.prefix(4)) == Array(header(UInt32(body.count))))
        #expect(try JSONDecoder().decode(GitMergeAnswer.self, from: Data(body)) == .saved)
    }

    @Test("a message comes back whole however the bytes arrive", arguments: [1, 2, 3, 5, 4096])
    func chunks(size: Int) throws {
        let connection = try FakeGitMergeConnection(
            incoming: GitMergeWire.frame(request),
            chunk: size
        )
        #expect(try GitMergeWire.receive(GitMergeRequest.self, over: connection) == request)
    }

    @Test("only the one message is read, so an answer can follow a request on the same bytes")
    func exactly() throws {
        let incoming = try GitMergeWire.frame(request) + GitMergeWire.frame(
            GitMergeAnswer.refused("nope")
        )
        let connection = FakeGitMergeConnection(incoming: incoming)
        #expect(try GitMergeWire.receive(GitMergeRequest.self, over: connection) == request)
        #expect(try GitMergeWire.receive(GitMergeAnswer.self, over: connection) == .refused("nope"))
    }

    @Test("sending writes the frame")
    func sending() throws {
        let connection = FakeGitMergeConnection()
        try GitMergeWire.send(request, over: connection)
        #expect(try connection.written == GitMergeWire.frame(request))
    }

    @Test("a stream that ends in the header is closed", arguments: [0, 1, 3])
    func closedInHeader(count: Int) {
        let connection = FakeGitMergeConnection(incoming: Data(repeating: 0, count: count))
        #expect(throws: GitMergeWire.Failure.closed) {
            try GitMergeWire.receive(GitMergeAnswer.self, over: connection)
        }
    }

    @Test("a stream that ends in the body is closed")
    func closedInBody() throws {
        let frame = try GitMergeWire.frame(request)
        let connection = FakeGitMergeConnection(incoming: frame.dropLast())
        #expect(throws: GitMergeWire.Failure.closed) {
            try GitMergeWire.receive(GitMergeRequest.self, over: connection)
        }
    }

    @Test("a length past the limit is refused before its body is waited for")
    func tooLong() {
        let limit = UInt32(GitMergeWire.messageByteLimit)
        let connection = FakeGitMergeConnection(incoming: header(limit + 1))
        #expect(throws: GitMergeWire.Failure.malformed) {
            try GitMergeWire.receive(GitMergeAnswer.self, over: connection)
        }
        #expect(connection.reads == 1)
    }

    @Test("a length at the limit is read")
    func atLimit() throws {
        let padding = String(repeating: " ", count: GitMergeWire.messageByteLimit - 2)
        let body = Data("{\(padding)}".utf8)
        struct Empty: Decodable, Equatable {}
        let connection = FakeGitMergeConnection(incoming: header(UInt32(body.count)) + body)
        #expect(try GitMergeWire.receive(Empty.self, over: connection) == Empty())
    }

    @Test("JSON of the wrong shape is refused")
    func wrongShape() {
        let body = Data("{\"local\":\"/a\"}".utf8)
        let connection = FakeGitMergeConnection(incoming: header(UInt32(body.count)) + body)
        #expect(throws: GitMergeWire.Failure.malformed) {
            try GitMergeWire.receive(GitMergeRequest.self, over: connection)
        }
    }

    @Test("bytes that are not JSON are refused")
    func notJSON() {
        let body = Data([0xFF, 0x00, 0x7B])
        let connection = FakeGitMergeConnection(incoming: header(UInt32(body.count)) + body)
        #expect(throws: GitMergeWire.Failure.malformed) {
            try GitMergeWire.receive(GitMergeAnswer.self, over: connection)
        }
    }

    @Test("a message over the limit is not sent")
    func oversized() {
        let answer = GitMergeAnswer.refused(
            String(repeating: "x", count: GitMergeWire.messageByteLimit)
        )
        #expect(throws: GitMergeWire.Failure.malformed) { try GitMergeWire.frame(answer) }
    }

    @Test("four of the longest paths there are fit in a message, every byte of them escaped")
    func longestPaths() throws {
        let path = "/" + String(repeating: "\"", count: 1023)
        let longest = GitMergeRequest(local: path, base: path, remote: path, merged: path)
        #expect(try GitMergeWire.frame(longest).count < GitMergeWire.messageByteLimit)
    }

    // MARK: - Where the socket is

    private let support = "/Users/me/Library/Application Support/Dirnex"

    @Test("a socket is named from the copy's path, in the same place every time")
    func socketPath() throws {
        let path = try #require(
            GitMergeSocketPath.path(
                supportDirectory: support,
                bundlePath: "/Applications/Dirnex.app"
            )
        )
        #expect(path.hasPrefix(support + "/gm-"))
        #expect(path.hasSuffix(".sock"))
        #expect(
            path == GitMergeSocketPath.path(
                supportDirectory: support,
                bundlePath: "/Applications/Dirnex.app"
            )
        )
    }

    @Test("two copies have two sockets")
    func socketPerCopy() {
        #expect(
            GitMergeSocketPath.path(
                supportDirectory: support,
                bundlePath: "/Applications/Dirnex.app"
            ) !=
                GitMergeSocketPath.path(
                    supportDirectory: support,
                    bundlePath: "/Users/me/build/Dirnex.app"
                )
        )
    }

    @Test("the same copy spelled with a trailing slash is the same socket")
    func socketSpelling() {
        #expect(
            GitMergeSocketPath.path(
                supportDirectory: support + "/",
                bundlePath: "/Applications/Dirnex.app/"
            ) ==
                GitMergeSocketPath.path(
                    supportDirectory: support,
                    bundlePath: "/Applications/Dirnex.app"
                )
        )
    }

    @Test("a path that fits a socket is kept, and one byte more is refused")
    func socketLimit() throws {
        let bundle = "/Applications/Dirnex.app"
        let probe = try #require(GitMergeSocketPath.path(supportDirectory: "/a", bundlePath: bundle))
        let room = GitMergeSocketPath.byteLimit - probe.utf8.count
        let fits = "/a" + String(repeating: "b", count: room)
        let path = try #require(GitMergeSocketPath.path(supportDirectory: fits, bundlePath: bundle))
        #expect(path.utf8.count == GitMergeSocketPath.byteLimit)
        #expect(GitMergeSocketPath.path(supportDirectory: fits + "c", bundlePath: bundle) == nil)
    }

    @Test("a socket's limit counts bytes, not characters")
    func socketLimitInBytes() throws {
        let bundle = "/Applications/Dirnex.app"
        let probe = try #require(GitMergeSocketPath.path(supportDirectory: "/a", bundlePath: bundle))
        let room = GitMergeSocketPath.byteLimit - probe.utf8.count
        let wide = "/a" + String(repeating: "é", count: room / 2 + 1)
        #expect(GitMergeSocketPath.path(supportDirectory: wide, bundlePath: bundle) == nil)
    }
}
