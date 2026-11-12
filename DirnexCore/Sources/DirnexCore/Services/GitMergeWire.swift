import CryptoKit
import Foundation

/// One end of a connection between `Dirnex --git-merge` and the app. The app holds a Unix socket
/// behind this, and a test holds bytes in memory. Blocking.
public protocol GitMergeConnection {
    /// Send all of `data`.
    func write(_ data: Data) throws(GitMergeWire.Failure)
    /// At most `count` bytes, and an empty `Data` once the other end has closed.
    func read(upTo count: Int) throws(GitMergeWire.Failure) -> Data
}

/// What crosses the socket (PLAN.md §M37 Slice 6): one request, then one answer, each a four-byte
/// big-endian length and that many bytes of JSON.
public enum GitMergeWire {
    public enum Failure: Error, Sendable, Equatable {
        /// The other end closed before the whole message arrived.
        case closed
        /// The bytes were not a message: a length past the limit, or JSON of the wrong shape.
        case malformed
        /// The connection failed, with the system's reason.
        case failed(String)
    }

    /// The most a message can hold. Four paths of `PATH_MAX`, every byte of them escaped, and a
    /// sentence fit many times over, so a length past it was not written by Dirnex.
    public static let messageByteLimit = 64 * 1024

    private static let headerByteCount = 4

    /// `value` as the bytes to send.
    public static func frame(_ value: some Encodable) throws(Failure) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let body = try? encoder.encode(value), body.count <= messageByteLimit else {
            throw .malformed
        }
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: headerByteCount) + body
    }

    /// Write `value` to `connection`.
    public static func send(
        _ value: some Encodable,
        over connection: some GitMergeConnection
    ) throws(Failure) {
        try connection.write(frame(value))
    }

    /// The next message on `connection`, however the bytes arrive.
    public static func receive<Value: Decodable>(
        _ type: Value.Type,
        over connection: some GitMergeConnection
    ) throws(Failure) -> Value {
        let header = try exactly(headerByteCount, from: connection)
        let length = header.reduce(0) { Int($0) << 8 | Int($1) }
        guard length <= messageByteLimit else { throw .malformed }
        let body = try exactly(length, from: connection)
        guard let value = try? JSONDecoder().decode(type, from: body) else { throw .malformed }
        return value
    }

    private static func exactly(
        _ count: Int,
        from connection: some GitMergeConnection
    ) throws(Failure) -> Data {
        var collected = Data()
        while collected.count < count {
            let more = try connection.read(upTo: count - collected.count)
            guard !more.isEmpty else { throw .closed }
            collected += more
        }
        return collected
    }
}

/// Where a copy of Dirnex listens for `--git-merge` (PLAN.md §M37 Slice 6).
///
/// Under Application Support rather than the per-user temporary folder, where macOS removes what
/// has gone unread for days and an app left running would stop being reachable. It is private
/// because `~/Library` is, and the socket is 0600 as well.
///
/// A socket per copy, named from the path of the app: the command belongs to the copy whose binary
/// it is, so a Debug build's command must not open its window in the copy in `/Applications`, which
/// has the same bundle id.
public enum GitMergeSocketPath {
    /// The longest path `sockaddr_un` holds on macOS, 104 bytes with its terminating NUL.
    public static let byteLimit = 103

    /// The socket for the app at `bundlePath`, in `supportDirectory`, or `nil` when that path is
    /// too long for a socket. The name is short because the whole path has to fit.
    public static func path(supportDirectory: String, bundlePath: String) -> String? {
        let digest = SHA256.hash(data: Data(VFSPath.local(bundlePath).path.utf8))
        let name = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        let path = VFSPath.local(supportDirectory).appending("gm-\(name).sock").path
        return path.utf8.count <= byteLimit ? path : nil
    }
}
