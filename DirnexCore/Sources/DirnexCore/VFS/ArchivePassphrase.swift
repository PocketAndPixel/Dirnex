import Foundation

/// A passphrase held as bytes Dirnex owns, rather than as a `String`.
///
/// The type exists for two reasons, and it is worth being precise about which is which, because
/// only one of them is airtight.
///
/// **It cannot be printed.** There is no `description`, no `CustomStringConvertible`, no
/// `Encodable`, and the bytes are reachable only through ``withUnsafeCString(_:)``. A passphrase
/// therefore cannot be interpolated into a log line, an error message, a JSON journal entry or —
/// the one that started this — a subprocess argument, by the ordinary accident of someone writing
/// `"\(passphrase)"`. That is a compile-time property, and it is the whole reason the encrypted
/// path links libarchive instead of shelling out to `bsdtar`, whose only interface for this is
/// `--passphrase` in argv where any `ps` on the machine can read it (docs/NOTES.md forbids exactly
/// this for `curl`).
///
/// **Its buffer is wiped when it goes away.** ``deinit`` zeroes the allocation before freeing it,
/// so the passphrase does not sit in a freed heap page for the rest of the session. This is a real
/// but *partial* improvement, and overclaiming it would be worse than not doing it: the `String`
/// the caller built this from is still the caller's — an `NSTextField`'s contents, and whatever
/// copies Swift made along the way, are not ours to zero. The honest summary is that this shortens
/// the passphrase's life, and does not end it at a knowable moment.
///
/// Deliberately immutable after `init`. That is what makes `@unchecked Sendable` honest here rather
/// than a lock waiting to be forgotten: nothing mutates the buffer while the object is alive, and
/// `deinit` runs only once the last reference is gone, so no reader can be inside
/// ``withUnsafeCString(_:)`` when the wipe happens.
public final class ArchivePassphrase: @unchecked Sendable {
    /// NUL-terminated UTF-8, the shape libarchive's `const char *` parameters want.
    private let storage: UnsafeMutablePointer<CChar>
    private let capacity: Int

    /// Copies `text`'s UTF-8 into a private buffer.
    ///
    /// An empty passphrase is representable and is *not* rejected here — ``isEmpty`` reports it and
    /// the callers refuse it with a named error, because "you must choose a passphrase" is a
    /// sentence the user needs to read, not a precondition failure.
    public init(_ text: String) {
        var bytes = Array(text.utf8CString)
        capacity = bytes.count
        storage = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        storage.update(from: bytes, count: capacity)
        // The temporary array held it too. Zero it before it is deallocated — `memset_s` is the
        // spelling the optimizer is not allowed to elide, which a plain loop or `memset` is.
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = memset_s(base, raw.count, 0, raw.count)
        }
    }

    /// Copies raw bytes into a private buffer — what comes back out of the Keychain.
    ///
    /// Separate from `init(_: String)` so a stored passphrase never becomes a `String` on the way
    /// home: the Keychain hands over `Data`, this takes it, and ``withUnsafeBytes(_:)`` hands the
    /// same bytes to `hdiutil`'s stdin, with no point in between where anything could interpolate or
    /// log it. `bytes` is **not** trimmed or re-encoded — a passphrase is a byte string, and the one
    /// filed is the one that was used.
    public init(bytes: Data) {
        capacity = bytes.count + 1
        storage = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            storage.withMemoryRebound(to: UInt8.self, capacity: bytes.count) { target in
                target.update(from: base.assumingMemoryBound(to: UInt8.self), count: bytes.count)
            }
        }
        storage[bytes.count] = 0
    }

    deinit {
        _ = memset_s(storage, capacity, 0, capacity)
        storage.deallocate()
    }

    /// Whether there is no passphrase at all. `capacity` counts the terminating NUL, so a buffer of
    /// one byte is the empty string.
    public var isEmpty: Bool { capacity <= 1 }

    /// The number of UTF-8 *bytes*, not characters — enough to tell "short" from "long" for a
    /// strength hint without exposing the value itself.
    public var byteLength: Int { max(0, capacity - 1) }

    /// Runs `body` with a NUL-terminated pointer to the bytes.
    ///
    /// The pointer is valid only for the duration of the call. libarchive copies the passphrase into
    /// its own state during `archive_write_set_passphrase` / `archive_read_add_passphrase`, so the
    /// borrow does not have to outlive the call that hands it over.
    func withUnsafeCString<R>(_ body: (UnsafePointer<CChar>) throws -> R) rethrows -> R {
        try body(UnsafePointer(storage))
    }

    /// Runs `body` with the passphrase's bytes **without** the terminating NUL — what a caller
    /// writing to another process's standard input needs (`hdiutil -stdinpass`, PLAN.md §M19).
    ///
    /// Separate from ``withUnsafeCString(_:)`` rather than derived from it at the call site, because
    /// the two differ by exactly the byte that would break this use, and both spellings look right.
    /// `hdiutil` takes **everything** on that pipe as the passphrase, verbatim to EOF: probed on
    /// macOS 26, an image created with a trailing newline on the pipe cannot be attached without one
    /// (`hdiutil: attach failed - Authentication error`), and vice versa. So a stray NUL — or the
    /// newline it is even more tempting to append when writing to a pipe — becomes a permanent,
    /// invisible part of the passphrase, and the vault stops opening to the phrase its owner typed
    /// the moment anything else (Disk Utility, Finder, another Mac) asks for it. There is no
    /// recovery from that, which is why the byte range is a method here rather than arithmetic
    /// wherever the pipe is.
    ///
    /// The pointer is valid only for the duration of the call.
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: storage, count: byteLength))
    }

    /// Whether two passphrases are the same — the "type it twice to confirm" check.
    ///
    /// Compared in **constant time** over the full buffer rather than with `==` on two `String`s.
    /// The threat here is not really a timing attacker; it is that the obvious implementation is to
    /// compare the two text fields' `String`s at the call site, which puts the passphrase back into
    /// the ordinary value world this type exists to keep it out of. Giving the confirmation its own
    /// method is what removes the reason to ever unwrap one.
    public func matches(_ other: ArchivePassphrase) -> Bool {
        guard capacity == other.capacity else { return false }
        var difference: UInt8 = 0
        for index in 0..<capacity {
            difference |= UInt8(bitPattern: storage[index]) ^ UInt8(bitPattern: other.storage[index])
        }
        return difference == 0
    }
}
