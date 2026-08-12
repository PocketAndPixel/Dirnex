import Foundation

/// The translation between a `VFSPath` and an S3 object key — the whole of "S3 is not a
/// filesystem", kept in one pure place.
///
/// S3 has no directories. A bucket is a flat map from key to bytes, and the folder tree every
/// client draws is a *query convention*: list with `delimiter=/` and the server groups everything
/// sharing a leading run into `CommonPrefixes`, which are the rows a file manager shows as folders.
/// So `/docs/report.pdf` is the key `docs/report.pdf`, and the folder `/docs` is not an object at
/// all — it is the prefix `docs/`.
///
/// Everything here is string work with no I/O, which is the point: the rules below are the ones
/// that decide whether a listing is correct, and they are all testable without a network.
public enum S3Key {
    /// The object key naming `path`, which is its path with the leading slash removed.
    ///
    /// The bucket root is the empty key — not `/`, which S3 would take as a one-character key whose
    /// name is a slash. Such a key is legal to create and is not what the root means.
    public static func key(for path: VFSPath) -> String {
        let raw = path.path
        return raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
    }

    /// The `prefix=` a listing of the directory `path` asks for: its key plus the delimiter, or the
    /// empty string at the bucket root.
    ///
    /// The trailing slash is load-bearing rather than cosmetic. Listing `prefix=doc` would match
    /// `docs/` *and* `document.txt` *and* `doctor/`, because a prefix is a string comparison and
    /// knows nothing about path components — so a folder named `doc` would show its siblings'
    /// contents as its own.
    public static func listingPrefix(for path: VFSPath) -> String {
        let key = key(for: path)
        if key.isEmpty { return "" }
        return key.hasSuffix("/") ? key : "\(key)/"
    }

    /// The last component of `key` — what the row is called, given that S3 hands back whole keys
    /// (`tiles/1/GENERAL_QUALITY.xml`) rather than leaf names, at every depth. Probed against a
    /// real bucket 2026-08-12: a listing of `prefix=tiles/` returns `CommonPrefixes` of `tiles/1/`,
    /// not `1/`, so a parser that renders the key verbatim draws the full path in every row.
    ///
    /// A trailing slash is dropped first, so the folder prefix `docs/sub/` is named `sub`.
    public static func displayName(ofKey key: String) -> String {
        let trimmed = key.hasSuffix("/") ? String(key.dropLast()) : key
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    /// Whether `key` is the *directory marker* for `prefix` — the zero-byte object whose key is the
    /// prefix itself.
    ///
    /// These exist because a flat store has no other way to hold an **empty** folder: the S3
    /// console, `aws s3api put-object --key docs/`, and Dirnex's own `createDirectory` all write
    /// one. The catch is that a listing of `prefix=docs/` returns that marker as an ordinary
    /// `Contents` row, so a parser that renders it draws a nameless zero-byte file inside every
    /// folder that has one — and `displayName` of `docs/` is `docs`, so it draws a *duplicate of
    /// the folder itself*, inside itself. Drop it.
    public static func isDirectoryMarker(key: String, forPrefix prefix: String) -> Bool {
        key == prefix && key.hasSuffix("/")
    }

    /// Percent-encode a key for use in a **URL path**, to the rule S3 signs against: only the
    /// RFC 3986 unreserved set survives, plus `/`, which stays literal because it is the path
    /// separator the request is built from.
    ///
    /// Deliberately stricter than `CharacterSet.urlPathAllowed`, exactly as `FTPBackend`'s is and
    /// for the same class of reason (NOTES.md ▸ curl): that set permits the sub-delimiters, so a
    /// key containing `?` or `#` would end the path and turn the rest of a legal object name into a
    /// query or a fragment — changing *which object* the request names.
    public static func encodedForPath(_ key: String) -> String {
        encode(key, keepingSlash: true)
    }

    /// Percent-encode a value for use in a **query string**, where `/` must go too.
    ///
    /// This is the one that was measured rather than reasoned about, and it decides pagination.
    /// A `NextContinuationToken` is base64 and routinely contains `+`, `/` and `=`; handed back
    /// raw, AWS answers `InvalidArgument` — "The continuation token provided is incorrect"
    /// (probed against a real bucket 2026-08-12, with the encoded form succeeding on the same
    /// token in the same run). It fails intermittently, which is what makes it worth a named
    /// function: a token that happens to be alphanumeric round-trips raw perfectly, so a bucket
    /// small enough never to paginate — or a lucky first page — hides it completely.
    public static func encodedForQuery(_ value: String) -> String {
        encode(value, keepingSlash: false)
    }

    /// The unreserved set, spelled out rather than taken from a `CharacterSet` constant so it
    /// cannot drift with Foundation's idea of what is allowed where.
    private static let unreserved = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func encode(_ value: String, keepingSlash: Bool) -> String {
        var out = ""
        for byte in Array(value.utf8) {
            let scalar = Unicode.Scalar(byte)
            if unreserved.contains(Character(scalar)) || (keepingSlash && byte == UInt8(ascii: "/")) {
                out.unicodeScalars.append(scalar)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// Undo the percent-encoding AWS applies to keys when a listing was asked for with
    /// `encoding-type=url`.
    ///
    /// Worth asking for on every listing rather than never: a key may legally contain characters
    /// that cannot appear in XML at all (a control character), and an unencoded listing carrying
    /// one is malformed XML — so the alternative to decoding here is a whole page that fails to
    /// parse because of one object somebody uploaded years ago. Returns `nil` for input that is not
    /// valid UTF-8 once decoded, which is a key no name can be made from.
    public static func decodingURLEncoding(_ value: String) -> String? {
        value.removingPercentEncoding
    }
}
