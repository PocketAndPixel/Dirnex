import Foundation

/// RFC 9110's two readings of an entity tag (§8.8.3), for the two questions a save-back asks of one.
///
/// A tag is `"opaque"` or `W/"opaque"`. The `W/` says the server will not promise the bytes are
/// identical, only equivalent, and the two questions treat it differently:
///
/// - **Has the file changed between two readings?** That is the **weak** comparison: the opaque
///   parts match, whatever either marker says. It has to be, because one unchanged file reads both
///   ways. Measured on macOS's Apache 2026-10-23 (and on the NAS in Slice 1): a file read in the
///   same second it was written reads `W/"6-65e85e19ba840"`, and two seconds later, untouched,
///   `"6-65e85e19ba840"`. Compared as strings, the rebaseline Dirnex takes right after its own
///   upload would read the next save's check as "somebody else has edited it".
/// - **May this tag guard a write?** Only a **strong** one. `If-Match` uses the strong comparison,
///   so a weak tag matches nothing. Measured on the same server: within that first second, `If-Match`
///   answered 412 with the tag as read *and* with its `W/` dropped, so no spelling of it can pass;
///   two seconds later the strong tag answered 204. So a save-back holding a weak tag sends no
///   condition at all and rests on the re-`stat`, which is where SFTP and FTP always are (taken
///   2026-10-23: a guard that refuses every quick second save is worse than no guard).
///
/// Neither reading looks at who made the tag. An S3 tag is never weak, so both are the identity
/// there.
public enum HTTPEntityTag {
    /// The weakness marker. Case-sensitive: RFC 9110 spells it `%s"W/"`.
    static let weakPrefix = "W/"

    /// Whether `tag` is weak.
    public static func isWeak(_ tag: String) -> Bool { tag.hasPrefix(weakPrefix) }

    /// `tag` without its weakness marker — the opaque part, quotes and all.
    public static func opaque(_ tag: String) -> Substring {
        isWeak(tag) ? tag.dropFirst(weakPrefix.count) : tag[...]
    }

    /// RFC 9110's weak comparison: the opaque parts match character for character, whatever either
    /// marker says. Compared as UTF-8 bytes, since an opaque tag is not text to normalize.
    public static func weaklyEqual(_ lhs: String, _ rhs: String) -> Bool {
        opaque(lhs).utf8.elementsEqual(opaque(rhs).utf8)
    }
}
