import Foundation

/// A secret handed to one reader through a named pipe, and gone once it has been read (PLAN.md §M38
/// Slice 3).
///
/// For a process Dirnex does not spawn, so that its environment and its stdin are out of reach: a
/// terminal runs the `ssh` of Open in Terminal. A pipe's bytes live in the kernel while they wait,
/// so the secret is never in a file, and what sits on disk is a name with a size of zero.
public struct OneShotSecretPipe: Sendable {
    public let path: String

    /// Create the pipe at `path`, readable and writable by this user alone.
    public init(path: String) throws {
        guard mkfifo(path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.path = path
    }

    /// Wait for a reader, hand it `secret`, and remove the pipe. Answers whether a reader got it.
    ///
    /// Blocks for up to `timeout`, so call it off the main thread. The pipe is removed whatever
    /// happens, so a reader that arrives later finds no such file instead of waiting forever on a
    /// pipe nobody will write to.
    @discardableResult
    public func deliver(
        _ secret: Data,
        timeout: TimeInterval,
        isCancelled: () -> Bool = { false }
    ) -> Bool {
        defer { unlink(path) }
        let deadline = Date().addingTimeInterval(timeout)
        guard let descriptor = openForReader(until: deadline, isCancelled: isCancelled) else {
            return false
        }
        defer { close(descriptor) }
        return Self.send(secret, to: descriptor, until: deadline)
    }

    /// `O_NONBLOCK` is what makes the wait boundable: a plain `open` for writing blocks until a
    /// reader arrives, with no way to give up, while this one answers `ENXIO` until then.
    private func openForReader(until deadline: Date, isCancelled: () -> Bool) -> Int32? {
        while true {
            let descriptor = open(path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 { return descriptor }
            guard errno == ENXIO || errno == EINTR, Date() < deadline, !isCancelled() else {
                return nil
            }
            usleep(Self.pollMicroseconds)
        }
    }

    /// Internal so a test can hand it a pipe whose reader has already gone.
    ///
    /// `F_SETNOSIGPIPE` because a reader that leaves between the open and the write would otherwise
    /// end this whole process with `SIGPIPE`.
    static func send(_ secret: Data, to descriptor: Int32, until deadline: Date) -> Bool {
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        return secret.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var sent = 0
            while sent < bytes.count {
                let written = write(descriptor, base + sent, bytes.count - sent)
                if written > 0 {
                    sent += written
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN, Date() < deadline {
                    usleep(pollMicroseconds)
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static let pollMicroseconds: UInt32 = 20000
}
