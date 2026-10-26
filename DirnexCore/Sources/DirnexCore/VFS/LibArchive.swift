import CArchiveShim
import Foundation

/// The thin Swift layer over the system libarchive — constants, handle lifetimes, and the one
/// error classification that has to read a message.
///
/// Everything above this file talks in Swift values; everything below it is C. Keeping that seam in
/// one place is what makes the rest of the encrypted path ordinary testable Swift, and it is why
/// `CArchiveShim` defines no functions of its own: a wrapper written in C would be a second home for
/// this logic where `swift test` cannot reach it.
enum LibArchive {
    // MARK: - Return codes
    //
    // Declared here rather than imported from C. They are plain integers with no ABI, and the
    // negative ones import inconsistently as macros; spelling them in Swift also lets them carry the
    // doc comments the C header cannot.

    /// The call succeeded.
    static let ok: Int32 = 0
    /// End of archive — `archive_read_next_header`'s normal terminating answer, not a failure.
    static let eof: Int32 = 1
    /// The operation succeeded but something is worth reporting. libarchive considers the handle
    /// usable, and so does Dirnex: a warning on one entry must not abandon the archive.
    static let warn: Int32 = -20
    /// This operation failed; the handle is still usable for others.
    static let failed: Int32 = -25
    /// The handle is dead. Nothing further may be attempted on it.
    static let fatal: Int32 = -30

    // MARK: - Entry types
    //
    // libarchive's `AE_IF*`, which are the POSIX `S_IF*` values by another name.

    static let regularFileType: mode_t = 0o100_000
    static let directoryType: mode_t = 0o040_000
    static let symbolicLinkType: mode_t = 0o120_000

    /// libarchive's message for `handle`, or `nil` when it has nothing to say.
    ///
    /// Never shown to a user — the sentences in `EncryptedArchiveError` are Dirnex's, in the user's
    /// language. This exists for ``isIncorrectPassphrase(_:)`` and for diagnostics.
    static func errorMessage(_ handle: OpaquePointer) -> String? {
        guard let raw = archive_error_string(handle) else { return nil }
        let message = String(cString: raw)
        return message.isEmpty ? nil : message
    }

    /// Whether `handle`'s failure was a wrong passphrase rather than a damaged archive.
    ///
    /// **This reads libarchive's English message, and there is no better signal available.** Probed
    /// against a real AES-256 archive: a wrong passphrase gives `archive_errno` of `-1` — the same
    /// "unknown" it gives for other internal failures — while the message reads
    /// `Incorrect passphrase: Unknown error: -1`. So the return code cannot separate the two cases
    /// and the message can.
    ///
    /// The distinction is worth the fragility, because the two failures need opposite responses from
    /// the user: retype the passphrase, or accept that the file is damaged. The fragility is
    /// contained two ways — the match is a case-insensitive substring rather than the whole
    /// sentence, so libarchive rewording the tail costs nothing; and
    /// `EncryptedArchiveReaderTests.wrongPassphraseIsReportedAsSuch` drives a real archive with a
    /// real wrong passphrase, so a wording change that *does* break it fails the suite rather than
    /// silently degrading every wrong passphrase into "this archive is damaged".
    static func isIncorrectPassphrase(_ handle: OpaquePointer) -> Bool {
        guard let message = errorMessage(handle) else { return false }
        return message.lowercased().contains("passphrase")
    }
}

// MARK: - Write handle

/// An `archive_write` handle that frees itself.
///
/// libarchive's write handle owns an open file descriptor and a compression context, and every
/// failure path in the writer is a `throw`. A `defer { archive_write_free(...) }` at each of them is
/// the kind of thing that is correct on the day it is written and wrong after the next edit, so the
/// lifetime belongs to an object instead.
final class ArchiveWriteHandle {
    let raw: OpaquePointer

    /// `nil` when libarchive could not allocate — the only way `archive_write_new` fails.
    init?() {
        guard let handle = archive_write_new() else { return nil }
        raw = handle
    }

    deinit {
        // Frees the handle and, if `close` was never reached, abandons the partial file. The writer
        // deletes that file itself; libarchive does not.
        archive_write_free(raw)
    }
}

// MARK: - Read handle

/// An `archive_read` handle that frees itself. Same reasoning as ``ArchiveWriteHandle``.
final class ArchiveReadHandle {
    let raw: OpaquePointer

    /// The byte source when the archive was opened through callbacks rather than a file name
    /// (``ArchiveByteWindow``). Held here because libarchive holds only an unretained pointer to it,
    /// and released only after `deinit` has freed the handle — stored properties outlive the body of
    /// `deinit`, so the close callback `archive_read_free` makes still finds it alive.
    var window: ArchiveByteWindow?

    /// Whether this handle holds ``externalProgramTurn``, given back once `deinit` has freed it.
    private var holdsExternalProgramTurn = false

    init?() {
        guard let handle = archive_read_new() else { return nil }
        raw = handle
    }

    deinit {
        archive_read_free(raw)
        if holdsExternalProgramTurn { Self.externalProgramTurn.signal() }
    }

    /// One reader at a time may have libarchive run an external program, because libarchive's
    /// spawn leaks the pipes of every child already running into the next.
    ///
    /// libarchive creates a child's two pipes with no `FD_CLOEXEC` and spawns with no
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT`, so each child inherits both ends of every live sibling's
    /// pipes. A child holding a sibling's stdin keeps that sibling from ever seeing end of input,
    /// and `archive_read_free` waits for its child in `waitpid`. Measured 2026-10-26 with
    /// `zstd -d -qq` over the `.tar.zst` fixture: four threads reading 25 times each completed **0
    /// of 100**, and so did two threads, every run, hung on four `zstd` children each holding the
    /// others' pipes. With this turn held from open to free, 100 of 100 in all three runs.
    /// Foundation's `Process` does not leak this way: a `Process` child of a process holding a
    /// stray pipe had only its own three descriptors (measured), so `bsdtar` and `sftp` children
    /// never hold a reader's child open.
    ///
    /// Held for the handle's whole life rather than only for the spawn, since a later child that
    /// inherited this one's stdin would make this read wait for that one to finish. Not re-entrant:
    /// nothing may open a second such handle while holding one, which is why `extract` gives its
    /// outer handle back before unwrapping a hidden-names archive.
    func takeExternalProgramTurn() {
        Self.externalProgramTurn.wait()
        holdsExternalProgramTurn = true
    }

    private static let externalProgramTurn = DispatchSemaphore(value: 1)
}
