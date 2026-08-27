import Foundation

/// Where a pack builds its archive, and how it gets from there to where it was asked for
/// (PLAN.md §M24 Slice 6).
///
/// **A local destination is written in place and this is nothing at all** — the same path
/// ``PackJob/archive`` names, no temp directory, no transfer, no sweep — which is what keeps the
/// ordinary ⌥F5 byte-identical to what it has always been. `EncryptedArchiveWriter` already builds
/// under a temporary name beside its target and renames on success, so a cancelled or failed pack
/// leaves nothing behind, and putting a second staging layer in front of that would only move where
/// the nothing is.
///
/// **A destination on a server is built in a temp directory and transferred afterwards**, which is
/// `ChecksumCreateRun`'s shape for a manifest that belongs beside a bucket's objects and the mirror
/// of the download `MaterializeRunner` performs in the other direction. Two details are load-bearing
/// and both are borrowed rather than reinvented: the staged file carries the archive's **real name**
/// inside a directory of its own, because a transport told a destination path is free to look at the
/// local file's name and there is nothing to gain from letting the two disagree; and the sweep is
/// unconditional, because a cancelled transfer must not leave somebody's whole archive in a temp
/// directory they will never look in.
///
/// **Both pack paths use it, which is the reason it is a type rather than four lines inside the
/// runner.** An encrypted pack runs here on the operation queue; a plain one is a `bsdtar` spawn in
/// the app (PLAN.md §M19 drew that boundary — `bsdtar` cannot be handed a passphrase that is not
/// readable by any `ps`). Two spellings of *where does the archive go* is exactly the shape this
/// project keeps paying for, and the two would drift on the first change to either.
public struct PackStaging: Sendable {
    /// The absolute local path the writer builds at — the destination itself when it is local.
    public let buildPath: String

    /// Whether the archive has to be transferred once it is written — `false` for a local
    /// destination, which the writer already landed on.
    public var needsDelivery: Bool { holder != nil }

    /// The temp directory to remove afterwards, or `nil` when nothing was staged.
    private let holder: URL?

    /// Throws only when the temp directory cannot be made, which is a full or read-only disk and is
    /// the one thing here that stops a pack before it starts.
    public init(for archive: VFSPath) throws {
        guard archive.backend != .local else {
            buildPath = archive.path
            holder = nil
            return
        }
        let holder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        self.holder = holder
        buildPath = holder.appendingPathComponent(archive.lastComponent).path
    }

    /// The size of what the writer built, or `0` when it cannot be `stat`-ed.
    ///
    /// Read from the file that exists here rather than from the destination, which for a server is
    /// another round trip — and it is only ever a number for a status line and a transfer's
    /// `expectedSize`, so a failed `stat` must not fail a pack that has just succeeded.
    public var builtByteSize: Int64 {
        var status = stat()
        guard lstat(buildPath, &status) == 0 else { return 0 }
        return Int64(status.st_size)
    }

    /// Put the finished archive where the job asked for it. A no-op for a local destination, which
    /// the writer already landed on.
    ///
    /// **Whether the destination may already exist is the caller's question, not this one's** — the
    /// gesture `stat`s and asks before it queues anything, and past that point every transport here
    /// replaces (a `PUT` overwrites, `sftp`'s `put` truncates, `STOR` truncates). Deleting first
    /// would turn a refused write into a lost file.
    /// `onBytes` reports the running total moved so far, not each chunk — the shape every progress
    /// consumer in this project takes, and the one a `@Sendable` closure can serve without
    /// accumulating state of its own.
    public func deliver(
        to archive: VFSPath,
        byteSize: Int64,
        using backend: any VFSBackend,
        onBytes: @escaping @Sendable (Int64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        guard needsDelivery else { return }
        let moved = Counter()
        try backend.copyFile(
            at: .local(buildPath),
            to: archive,
            expectedSize: byteSize,
            progress: { onBytes(moved.add($0)) },
            isCancelled: isCancelled
        )
    }

    /// Remove whatever was staged. Best effort and silent: it runs on every exit path including the
    /// failing ones, where the error worth reporting is the one that got here.
    public func clean() {
        guard let holder else { return }
        try? FileManager.default.removeItem(at: holder)
    }
}

/// A running total a `@Sendable` progress closure may keep.
///
/// `VFSBackend.copyFile` reports each *chunk*, and every consumer of a bar wants the sum — so the
/// accumulator has to live somewhere the closure may capture, which a local `var` in a synchronous
/// function is not once the closure is `@Sendable`. A class rather than an actor because the caller
/// is the one blocking thread the transfer runs on: `MaterializeRunner` keeps its own with a plain
/// `var` for the same reason, one layer up, where the closure is not crossing a boundary.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0

    func add(_ chunk: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        total += chunk
        return total
    }
}
