import Darwin
import DirnexCore
import Foundation

/// The Unix socket between `Dirnex --git-merge` and the app (PLAN.md §M37 Slice 6): what is on it
/// is the core's (`GitMergeWire`), and this only moves the bytes.
enum GitMergeSocket {
    /// `path`'s address, handed to `body`, or `nil` when it is too long for a socket.
    static func withAddress<Result>(
        of path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result
    ) -> Result? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// A new socket that a child process does not inherit and a closed peer cannot kill with
    /// `SIGPIPE`, or `nil` with `errno` set.
    static func make() -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        configure(descriptor)
        return descriptor
    }

    /// Set what every socket here has, the accepted ones included.
    static func configure(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &on,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }

    /// The system's sentence for `code`.
    static func reason(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    /// Try the socket at `path` once.
    static func connect(to path: String) -> GitMergeConnectResult<GitMergeSocketConnection> {
        guard let descriptor = make() else { return .failed(reason(errno)) }
        let status = withAddress(of: path) { Darwin.connect(descriptor, $0, $1) }
        guard status == 0 else {
            let code = errno
            Darwin.close(descriptor)
            guard status != nil else { return .failed(reason(ENAMETOOLONG)) }
            // No socket yet, or one left behind by a copy that died.
            return code == ENOENT || code == ECONNREFUSED ? .notListening : .failed(reason(code))
        }
        return .connected(GitMergeSocketConnection(descriptor: descriptor))
    }
}

/// One end of the socket. Each is read on one thread at a time; the lock is for `close`, which the
/// listener's stop can call from another.
final class GitMergeSocketConnection: GitMergeConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close()
    }

    func close() {
        lock.withLock {
            if let descriptor { Darwin.close(descriptor) }
            descriptor = nil
        }
    }

    /// Give up on a read after `seconds`, so a client that says nothing can't hold the connection.
    func setReadTimeout(seconds: Int) {
        guard let descriptor = lock.withLock({ descriptor }) else { return }
        var limit = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &limit,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    /// Whether the process at the other end is this user's.
    var isSameUser: Bool {
        guard let descriptor = lock.withLock({ descriptor }) else { return false }
        var user = uid_t.max
        var group = gid_t.max
        return getpeereid(descriptor, &user, &group) == 0 && user == geteuid()
    }

    func write(_ data: Data) throws(GitMergeWire.Failure) {
        guard let descriptor = lock.withLock({ descriptor }) else { throw .closed }
        var offset = 0
        while offset < data.count {
            let sent = data[offset...].withUnsafeBytes { send(
                descriptor,
                $0.baseAddress,
                $0.count,
                0
            ) }
            if sent >= 0 {
                offset += sent
            } else if errno != EINTR {
                throw errno == EPIPE ? .closed : .failed(GitMergeSocket.reason(errno))
            }
        }
    }

    func read(upTo count: Int) throws(GitMergeWire.Failure) -> Data {
        guard let descriptor = lock.withLock({ descriptor }) else { throw .closed }
        var buffer = Data(count: count)
        while true {
            let received = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, count, 0) }
            if received >= 0 { return buffer.prefix(received) }
            if errno != EINTR {
                throw errno == ECONNRESET ? .closed : .failed(GitMergeSocket.reason(errno))
            }
        }
    }
}

/// The app's end: listens at a path, and hands each request that arrives to `handler`, off the main
/// thread, with the connection its answer goes back on.
final class GitMergeListener: @unchecked Sendable {
    struct Failure: Error, Equatable {
        let reason: String
    }

    typealias Handler = @Sendable (GitMergeRequest, GitMergeSocketConnection) -> Void

    /// How long a client gets to send its request once it has connected.
    static let requestTimeoutSeconds = 5

    private let path: String
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var isStopped = false

    /// Start listening at `path`, taking over from a socket a copy that died left there.
    init(path: String, handler: @escaping Handler) throws(Failure) {
        self.path = path
        guard let descriptor = GitMergeSocket.make() else {
            throw Failure(reason: GitMergeSocket.reason(errno))
        }
        func fail() -> Failure {
            let failure = Failure(reason: GitMergeSocket.reason(errno))
            close(descriptor)
            return failure
        }
        unlink(path)
        guard GitMergeSocket.withAddress(of: path, { bind(descriptor, $0, $1) }) == 0 else { throw fail(
        ) }
        // Readable by no one else, and inside `~/Library`, which already is.
        guard chmod(path, S_IRUSR | S_IWUSR) == 0, listen(descriptor, 8) == 0 else { throw fail() }
        let flags = fcntl(descriptor, F_GETFL)
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw fail() }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "app.dirnex.git-merge.listener", qos: .userInitiated)
        )
        self.source = source
        source.setEventHandler {
            Self.acceptAll(on: descriptor, handler: handler)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    /// Stop listening and remove the socket. Connections already open stay open.
    func stop() {
        let wasStopped = lock.withLock {
            defer { isStopped = true }
            return isStopped
        }
        guard !wasStopped else { return }
        source.cancel()
        unlink(path)
    }

    private static func acceptAll(on descriptor: Int32, handler: @escaping Handler) {
        while true {
            let accepted = accept(descriptor, nil, nil)
            guard accepted >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            GitMergeSocket.configure(accepted)
            // A socket accepted from a non-blocking one is non-blocking too on macOS.
            let flags = fcntl(accepted, F_GETFL)
            _ = fcntl(accepted, F_SETFL, flags & ~O_NONBLOCK)
            let connection = GitMergeSocketConnection(descriptor: accepted)
            // Its own queue, so a client that says nothing does not hold up the next one.
            DispatchQueue.global(qos: .userInitiated).async {
                receive(on: connection, handler: handler)
            }
        }
    }

    private static func receive(on connection: GitMergeSocketConnection, handler: Handler) {
        guard connection.isSameUser else { return }
        connection.setReadTimeout(seconds: requestTimeoutSeconds)
        guard let request = try? GitMergeWire.receive(GitMergeRequest.self, over: connection) else { return }
        handler(request, connection)
    }
}
