import Darwin
import Foundation

/// The shipping ``TrashPerformer``: `FileManager.trashItem` for an ordinary item, and the rename
/// macOS would have made for one inside a File Provider domain, which `trashItem` refuses
/// (PLAN.md §M26).
///
/// **One performer routing on where the item lives, not two routes racing.** The rejected shape is
/// a *fallback* — try one, and on refusal try the other — which leaves the app's most ordinary
/// gesture depending on which spelling macOS happens to decline that day. This decides up front,
/// from a property of the path, the way `CompositeBackend` routes on `path.backend`; and it keeps
/// `trashItem` wherever `trashItem` works, so an ordinary delete is byte-for-byte what it always
/// was — Finder's collision naming, Finder's destination, and Finder's `ptbL`/`ptbN` **Put Back**
/// record, none of which this package can write.
///
/// What a provider item loses is exactly that Put Back record. **Dirnex's own ⌘Z is unaffected**:
/// `DeletePass.Restoration` rides the landing path returned here, not Finder's record, so undo
/// after an F8 puts the file back where it came from either way.
///
/// ### Where it lands, and why it is asked rather than tabulated
///
/// A provider's trash is *not* derivable from the provider (docs/NOTES.md): Google Drive keeps its
/// own at `<mount>/.Trash`, while Dropbox has that directory, carries the marker xattr, declares
/// the capability — and does not use it; OneDrive and Box have none at all. So the destination is
/// asked of Foundation and then **verified with a `stat`**, the same "cheap answer raises the
/// question, a check answers it" shape `S3AccountBackend.createDirectory` settled on. Measured
/// 2026-08-31 against all five live domains, the pair agrees with `trashItem`'s own destination
/// everywhere the lookup alone does not:
///
/// | domain | lookup names | exists | lands | `trashItem` |
/// |---|---|---|---|---|
/// | Box | `<mount>/.Trash` | **no** | `~/.Trash` | `~/.Trash` |
/// | OneDrive | `<mount>/.Trash` | **no** | `~/.Trash` | `~/.Trash` |
/// | Dropbox | *throws 3328* | — | `~/.Trash` | `~/.Trash` |
/// | Drive (streaming) | `<mount>/.Trash` | yes | `<mount>/.Trash` | `<mount>/.Trash` |
/// | Drive (mirror) | `~/.Trash` | yes | `~/.Trash` | `~/.Trash` |
/// | iCloud Drive | `~/Library/Mobile Documents/.Trash` | yes | that | that |
///
/// **Staying inside the domain is what protects an evicted placeholder, and it is the reason the
/// destination is worth this much care.** Measured on a 4 MB iCloud file evicted through
/// `evictUbiquitousItem`: renaming it into its provider's own trash took **0.001 s and left it
/// dataless**, exactly as `trashItem` does (0.019 s, still dataless) — while renaming it out to
/// `~/.Trash` **materialized it**, 4 MB in 1.15 s. On a 14 GB placeholder that is a download nobody
/// asked for, inside a delete, which is the hazard PLAN.md's M24 risk row names.
public struct ProviderAwareTrashPerformer: TrashPerformer {
    /// How many stamped names to try before giving up, after the plain one is taken.
    private static let collisionAttempts = 8

    private let ordinary: any TrashPerformer

    public init(ordinary: any TrashPerformer = FileManagerTrashPerformer()) {
        self.ordinary = ordinary
    }

    public func moveToTrash(_ url: URL) throws -> URL? {
        guard Self.isProviderItem(url) else { return try ordinary.moveToTrash(url) }
        return try Self.moveIntoTrash(url, trashDirectory: Self.trashDirectory(for: url))
    }

    // MARK: - Which route

    /// Asks the item itself, and falls back to where it lives only when the read gives no answer
    /// (▸ ``TrashLanding/isProviderItem(isUbiquitous:path:home:)``).
    ///
    /// One resource-value read per *deleted item* — a File Provider round trip, ~650–1000 µs
    /// (docs/NOTES.md) — which is a gesture cost, not a per-row listing cost.
    static func isProviderItem(_ url: URL, home: String = NSHomeDirectory()) -> Bool {
        // `do`/`catch` rather than `try?`, which flattens the two optionals into one and would
        // erase the distinction the routing rests on: a read that *succeeded* with the key absent
        // is an authoritative "not in a domain" (every ordinary file, and a mirror-mode Google
        // Drive file), while a read that *threw* is no answer at all and falls through to the path.
        let isUbiquitous: Bool?
        do {
            isUbiquitous = try url.resourceValues(forKeys: [.isUbiquitousItemKey])
                .isUbiquitousItem ?? false
        } catch {
            isUbiquitous = nil
        }
        return TrashLanding.isProviderItem(isUbiquitous: isUbiquitous, path: url.path, home: home)
    }

    // MARK: - Where it lands

    static func trashDirectory(for url: URL, home: String = NSHomeDirectory()) -> URL {
        let named = try? FileManager.default.url(
            for: .trashDirectory, in: .allDomainsMask, appropriateFor: url, create: false
        )
        return trashDirectory(
            preferring: named,
            fallback: URL(fileURLWithPath: home).appendingPathComponent(
                TrashLocations.trashDirectoryName
            )
        )
    }

    /// The verification half: a directory Foundation *names* is not a directory that is *there*.
    ///
    /// Box and OneDrive both have the lookup answer `<mount>/.Trash` for a mount that has no such
    /// directory and never grows one, and creating it would put a folder inside somebody's cloud
    /// account that then syncs — so a candidate that is not already a directory is discarded rather
    /// than made. The fallback is the volume trash, which is where `trashItem` sends those two
    /// providers' items anyway.
    static func trashDirectory(preferring candidate: URL?, fallback: URL) -> URL {
        guard let candidate else { return fallback }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: candidate.path,
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue ? candidate : fallback
    }

    // MARK: - The move

    /// `renamex_np` with `RENAME_EXCL`, so a name already in the Trash is **refused** rather than
    /// overwritten.
    ///
    /// A plain `rename(2)` replaces its destination silently, which here would destroy a file the
    /// user had already thrown away — the one direction a delete must never fail in. `RENAME_EXCL`
    /// turns that into `EEXIST`, which is the signal to stamp the name the way `trashItem` does.
    /// Measured working, and refusing, from every live domain (2026-08-31).
    ///
    /// - Returns: where the item landed, which the caller journals so ⌘Z can put it back.
    static func moveIntoTrash(
        _ url: URL,
        trashDirectory: URL,
        now: @Sendable () -> Date = { Date() }
    ) throws -> URL {
        let name = url.lastPathComponent
        var candidates = [name]
        // Fresh stamps rather than one reused: two deletes inside the same millisecond would
        // otherwise produce the same "unique" name and spend every attempt on it.
        candidates += (0..<collisionAttempts).map { _ in
            TrashLanding.collisionName(for: name, stamp: TrashLanding.stamp(for: now()))
        }

        var lastErrno: Int32 = EEXIST
        for candidate in candidates {
            let destination = trashDirectory.appendingPathComponent(candidate)
            let moved = url.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { target in
                    renamex_np(source, target, UInt32(RENAME_EXCL))
                }
            }
            if moved == 0 { return destination }
            lastErrno = errno
            guard lastErrno == EEXIST else { break }
            // A same-millisecond collision is the only way to get here twice; let the clock move.
            usleep(1000)
        }
        throw NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(lastErrno))
            ]
        )
    }
}
