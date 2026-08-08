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

    /// The linked library's version, e.g. `libarchive 3.7.4`. Read from the dylib rather than
    /// assumed, so a diagnostic report names what actually ran.
    static var versionString: String {
        String(cString: archive_version_string())
    }

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

    init?() {
        guard let handle = archive_read_new() else { return nil }
        raw = handle
    }

    deinit {
        archive_read_free(raw)
    }
}
