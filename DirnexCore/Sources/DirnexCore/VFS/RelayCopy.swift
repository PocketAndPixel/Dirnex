import Foundation

/// Copies one file between two backends that can each only talk to **this machine**, by staging the
/// bytes on disk: download from the source, upload to the destination, delete the staged copy.
///
/// It exists because "copy" is not one operation on every backend. SFTP and FTP have no copy verb
/// at all — `sftp` offers `get` and `put`, `curl` a download and an upload — so their
/// ``VFSBackend/copyFile(at:to:progress:isCancelled:)`` is a *direction* rather than a duplication,
/// and both refuse a pair of ends that does not include the local disk. That refusal is honest at
/// the backend (neither one has ever heard of the other), and it reached the user as a dead end:
/// F5 from a bucket to a server, and even a duplicate **within one SFTP account**, failed per file
/// with "Copying directly between remote locations isn't supported".
///
/// Two ends and one staging file is the whole mechanism, and it is deliberately not a backend's:
/// only something holding *both* connections can run it, which in the app is the pane's composite
/// backend and here is the caller. ``VFSCapabilities/internalCopy`` is what tells a router which
/// pairs need it — a backend that can copy inside itself (the local disk, and S3's server-side
/// `x-amz-copy-source`) must be handed the copy whole rather than made to send its own bytes
/// through this machine.
///
/// **Progress counts the file once, not twice.** The queue's denominator is the file's size, so
/// reporting both legs would drive the bar to 200 %; each leg is therefore reported at half weight
/// and the tail tops the count up to the staged file's exact size. A leg that reports nothing while
/// it runs — an SFTP upload has no observable at all, which is `sftp`'s own limitation
/// (docs/NOTES.md ▸ sftp / ssh) — leaves the bar resting at half until it finishes, which is what
/// is actually known about it.
public enum RelayCopy {
    /// One end of a relayed copy: a path, and the backend that owns it. The pair travels together
    /// because neither half is usable without the other here — the whole point is that no single
    /// backend can be asked about both ends.
    public struct Endpoint {
        public let path: VFSPath
        public let backend: any VFSBackend

        public init(_ path: VFSPath, on backend: any VFSBackend) {
            self.path = path
            self.backend = backend
        }
    }

    /// Move `source`'s bytes to `destination` through a temporary file under `stagingRoot`.
    ///
    /// - Parameters:
    ///   - source: the file to copy, with the backend that performs the download leg — the staged
    ///     path is handed to it as an ordinary `.local` destination.
    ///   - destination: where it lands, with the backend that performs the upload leg.
    ///   - stagingRoot: the directory each transfer's private staging directory is made under. The
    ///     caller owns it (and purging what a crash leaves behind); nothing here is reused between
    ///     calls, so two relays can run concurrently under one root.
    ///   - expectedSize: the source file's size when the caller already knows it, passed to the
    ///     download leg as a hint. Nothing here depends on it being right, or on it being given.
    ///   - progress: forward-only deltas, summing to the file's size — never twice it.
    ///   - isCancelled: polled between the legs and passed into both, so a cancel lands inside a
    ///     transfer rather than only between files.
    ///
    /// Throws whatever either leg throws — a download failure names the source, an upload failure
    /// the destination — or `CancellationError`. The staged copy is removed on every exit. A
    /// **partial upload** is left where the destination backend left it, exactly as a direct upload
    /// leaves one: it is the partial a resumed transfer picks up from, and removing it here would
    /// be this one path deciding otherwise.
    public static func copyFile(
        from source: Endpoint,
        to destination: Endpoint,
        stagingRoot: URL,
        expectedSize: Int64? = nil,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        if isCancelled() { throw CancellationError() }
        let staged = try stagingFile(
            named: source.path.lastComponent,
            under: stagingRoot,
            for: source.path
        )
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }

        var tally = TransferProgressTally()
        var downloaded: Int64 = 0
        var uploaded: Int64 = 0
        // Half weight per leg: the two move the same bytes, and the caller is counting the file
        // once. `TransferProgressTally` keeps the result forward-only, so integer division rounding
        // can never emit a negative delta.
        func report() {
            if let delta = tally.delta(movedSoFar: (downloaded + uploaded) / 2) { progress(delta) }
        }

        try source.backend.copyFile(
            at: source.path,
            to: .local(staged.path),
            // The download leg is an ordinary download and gets the same hint one would — a relayed
            // copy out of a bucket should be split like any other (docs/HISTORY.md ▸ After M19). The *upload* leg
            // reads the staged file's own size, which cannot be stale, so it needs nothing.
            expectedSize: expectedSize,
            progress: { delta in
                downloaded += delta
                report()
            },
            isCancelled: isCancelled
        )
        if isCancelled() { throw CancellationError() }

        try destination.backend.copyFile(
            at: .local(staged.path),
            to: destination.path,
            progress: { delta in
                uploaded += delta
                report()
            },
            isCancelled: isCancelled
        )
        if isCancelled() { throw CancellationError() }

        // The staged file is what actually arrived, so it — not the sum of two estimates — is the
        // count the job settles on, the same reconciliation every remote transport makes.
        let exact = stagedSize(at: staged) ?? downloaded
        if let remainder = tally.remainder(against: exact) { progress(remainder) }
    }

    /// A fresh, private directory under `stagingRoot` holding the file's **real name**.
    ///
    /// A directory per transfer rather than a unique file name, so the staged copy keeps the name
    /// the user is looking at: it is what an error message and any tool that reads the path will
    /// show, and it is what a name-sensitive upload would send if one ever needed the basename.
    ///
    /// The name is a **remote listing's**, which is to say a stranger's choice — the same reason
    /// this project refuses a CR or LF in an FTP path rather than escaping it. A component that
    /// could climb out of the staging directory (`.`, `..`, anything carrying a separator) is
    /// replaced rather than sanitized in place, since there is nothing to preserve about it.
    private static func stagingFile(
        named name: String,
        under stagingRoot: URL,
        for source: VFSPath
    ) throws -> URL {
        let directory = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw VFSError.io(path: source, code: EIO)
        }
        return directory.appendingPathComponent(safeName(name), isDirectory: false)
    }

    /// `name` if it is a plain file name, and a fixed stand-in otherwise.
    private static func safeName(_ name: String) -> String {
        let rejected = name.isEmpty || name == "." || name == ".."
            || name.contains("/") || name.contains("\0")
        return rejected ? "dirnex-relay" : name
    }

    /// The staged file's size, or `nil` when it can't be read — in which case the caller falls back
    /// to what the download leg reported, which is the only other thing known about it.
    private static func stagedSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.size] as? Int64
    }
}
