import Darwin
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A folder short enough for a socket's path, and a path for the socket in it.
struct GitMergeScratch {
    let folder: URL
    var socket: String { folder.appendingPathComponent("s").path }

    init() throws {
        folder = URL(fileURLWithPath: "/tmp/gm-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// What a listener's handler got, for a test to wait on.
final class GitMergeReceived: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [GitMergeRequest] = []
    private var connections: [GitMergeSocketConnection] = []

    var all: [GitMergeRequest] { lock.withLock { requests } }
    var last: GitMergeSocketConnection? { lock.withLock { connections.last } }

    func add(_ request: GitMergeRequest, _ connection: GitMergeSocketConnection) {
        lock.withLock {
            requests.append(request)
            connections.append(connection)
        }
    }
}

/// What the socket suites share.
protocol GitMergeSocketTesting {}

struct GitMergeNotListening: Error {}

extension GitMergeSocketTesting {
    var request: GitMergeRequest {
        GitMergeRequest(local: "/t/l", base: "/t/b", remote: "/t/r", merged: "/w/m")
    }

    /// The other end of a listener, connected.
    func client(_ path: String) throws -> GitMergeSocketConnection {
        guard case let .connected(connection) = GitMergeSocket.connect(to: path) else {
            throw GitMergeNotListening()
        }
        return connection
    }

    /// Wait off the main thread, since nothing here needs it.
    func wait(
        within limit: Duration = .seconds(30),
        until predicate: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + limit
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate())
    }
}
