import Foundation

/// Reading the `<href>` a WebDAV server names a resource with, and building the URL path a request
/// names it with. The two directions are different rules, and confusing them renames files.
///
/// What the server sends was measured rather than read off RFC 4918 (the NAS's Apache `mod_dav`
/// and macOS's own, 2026-10-22, the fixtures under `Fixtures/WebDAV`):
///
/// - Hrefs are percent-encoded in **lowercase** hex, while `curl` and this file send uppercase.
///   So a path is compared after decoding, never as the string that was sent: compared raw, the
///   folder being listed fails to recognize itself in its own listing.
/// - `;`, `+`, `=` and `&` stay literal, and `&` arrives as `&amp;` (the XML parser undoes that).
///   A `+` is a plus. Decoding it as a space, the way a form is decoded and the way
///   `S3Key.decodingURLEncoding` must, names a file that does not exist.
/// - A decomposed é stays decomposed (`cafe%cc%81`). The bytes are the name.
/// - A collection's href ends in `/` one level down and does **not** at the account root
///   (`/home`, `/share`). The slash says nothing about the type; `<resourcetype>` does.
public enum WebDAVHref {
    /// The decoded server path an href names, in the normalized form ``normalized(_:)`` gives, or
    /// `nil` when nothing usable can be made of it.
    ///
    /// An absolute URL is accepted as well as an absolute path: RFC 4918 allows either and some
    /// servers send the full URL. Only the path is kept — the authority is the server's opinion of
    /// its own name, which behind a proxy or a Bonjour fallback is not the one being dialed.
    ///
    /// Each segment is decoded on its own, and three things are refused rather than repaired:
    ///
    /// - **A segment that decodes to contain `/`** (`a%2Fb`). Decoded whole, it would become two
    ///   segments, and the row would name a file inside a folder that does not exist.
    /// - **A `.` or `..` segment.** A name is copied to the local disk with F5, and `..` there is
    ///   the parent directory.
    /// - **Bytes that are not UTF-8 once decoded.** No name can be made from them, and a lossy
    ///   decode would name a file the server does not have. The listing counts these instead of
    ///   dropping them in silence (``WebDAVMultistatus/unreadableHrefCount``).
    ///
    /// A relative href (no leading `/`) is refused too. It is legal in a URI reference and no
    /// server measured sends one, so resolving it would be a guess about a base nobody has seen.
    public static func serverPath(fromHref href: String) -> String? {
        var text = Substring(href.trimmingCharacters(in: .whitespacesAndNewlines))
        if let schemeEnd = text.range(of: "://"), isScheme(text[..<schemeEnd.lowerBound]) {
            let afterAuthority = text[schemeEnd.upperBound...]
            text = afterAuthority.firstIndex(of: "/").map { afterAuthority[$0...] } ?? "/"
        }
        // A literal `?` or `#` ends the path. Servers encode both inside a name (`%3f`, `%23`, as
        // measured), so a literal one can only be a query or a fragment.
        if let end = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = text[..<end] }
        guard text.hasPrefix("/") else { return nil }

        var segments: [String] = []
        for raw in text.split(separator: "/", omittingEmptySubsequences: true) {
            guard let segment = String(raw).removingPercentEncoding,
                  !segment.isEmpty, !segment.contains("/"),
                  segment != ".", segment != ".."
            else { return nil }
            segments.append(segment)
        }
        return "/" + segments.joined(separator: "/")
    }

    /// Whether `text` is a URI scheme (RFC 3986: a letter, then letters, digits, `+`, `-`, `.`), so
    /// a path segment that happens to contain `://` is not mistaken for one.
    private static func isScheme(_ text: Substring) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
    }

    /// `path` with a leading slash, no trailing slash and no empty segments, `/` for the root —
    /// and every byte of every name kept as it was.
    public static func normalized(_ path: String) -> String {
        "/" + path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    /// Whether two server paths name the same resource: equal **bytes** once normalized, so a
    /// trailing slash does not matter and Unicode normalization does.
    ///
    /// Swift's `==` on `String` compares by canonical equivalence, so `café` precomposed and
    /// decomposed are equal strings — and two different files on a server that keeps names as
    /// bytes, which the NAS does. The same trap M31 records for comparing lines.
    public static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs).utf8.elementsEqual(normalized(rhs).utf8)
    }

    /// The parent of a server path, or `nil` for the root. Bytes in, bytes out.
    static func parent(of path: String) -> String? {
        var segments = normalized(path).split(separator: "/", omittingEmptySubsequences: true)
        guard !segments.isEmpty else { return nil }
        segments.removeLast()
        return "/" + segments.joined(separator: "/")
    }

    /// The last segment of a server path — a row's name — or `nil` for the root.
    static func name(of path: String) -> String? {
        normalized(path).split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
    }

    /// Percent-encode a decoded server path for a request URL: every byte outside RFC 3986's
    /// unreserved set is encoded, and `/` stays literal because it is the separator.
    ///
    /// Stricter than `CharacterSet.urlPathAllowed` for the reason NOTES.md ▸ curl gives for FTP:
    /// that set lets `;`, `?` and `#` through, and a `?` or `#` in a name would end the path and
    /// change which resource the request names. Byte by byte rather than through
    /// `addingPercentEncoding`, whose `alphanumerics` include every script's letters, so the bytes
    /// on the wire are exactly the name's own — a decomposed é goes out as `e%CC%81`.
    public static func encodedPath(_ path: String) -> String {
        var out = ""
        for byte in path.utf8 {
            if unreserved.contains(byte) || byte == UInt8(ascii: "/") {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// RFC 3986's unreserved set, spelled out so it cannot drift with Foundation's idea of what is
    /// allowed where.
    private static let unreserved = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8
    )
}
