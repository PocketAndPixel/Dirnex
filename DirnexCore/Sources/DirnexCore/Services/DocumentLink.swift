import Foundation

/// Where a link in a previewed document leads (PLAN.md §M39 ▸ Slice 4).
///
/// Quick View's decision is that a link to another file **moves the pane**: its cursor lands on the
/// target, the preview follows the cursor, and the pane's own Back is the way back, so the file list
/// stays the navigation and the preview gains no history of its own. A web link opens in the user's
/// browser. This type answers the question underneath both: given what was clicked and where the
/// document is, which of those is it.
///
/// ## Resolved against the document's backend, not this disk
///
/// A Markdown file on an SFTP server is rendered from a local copy, so the copy's folder is no use
/// for resolving `../other.md`: the author meant the server's folder. So a document's links resolve
/// against its own ``VFSPath``, and a relative target is a place on the **same backend**: a sibling
/// on the server, a member of the same archive, a key in the same bucket.
///
/// ## The base URL WebKit is handed
///
/// WebKit gives `decidePolicyFor` only the URL it has already resolved, never the `href` the author
/// wrote, so the app cannot simply pass the raw reference here. ``baseURL(for:)`` is what makes the
/// resolved URL readable: a generated page loaded with the document's own path in ``scheme`` as its
/// base resolves every relative link to a URL whose path *is* the backend path. Measured 2026-11-12
/// with `loadHTMLString` and synthetic clicks: every click reached `decidePolicyFor` as such a URL,
/// `#anchor` arrived against the document and scrolled the page, `""` was the document and `.` its
/// folder, a name holding a space, `é` or `#` round-tripped, `file:///…` stayed a `file:` URL, and
/// `//host/x` arrived with `host` as the host. The same page with the `file://` folder the preview
/// uses today resolved `""`, `.` and `#anchor` all to the folder, and the clicks never reached the
/// delegate at all.
///
/// So ``resolve(_:from:)`` reads either form, the reference as written or the URL WebKit made of it,
/// and gives the same answer for both (pinned against WebKit's own answers in the tests).
///
/// ## Why the resolution is written out rather than asked of Foundation
///
/// `URL(string:relativeTo:)` agreed with WebKit on every reference above but one family, and that one
/// corrupts names: **one invalid character anywhere in the string makes Foundation re-encode every
/// `%` in it**, valid escapes included. Measured 2026-11-12: `…/My%20Docs/100%.md` parsed as
/// `My%2520Docs/100%25.md`, so the folder came back as a name with `%20` in it, and a `\` did the
/// same. So the hierarchical references, the only ones that become a ``VFSPath``, are split and
/// merged by RFC 3986's own steps (§5.2), and each name is decoded on its own. A web link still
/// becomes a `URL`, with only its invalid characters encoded first (``webURL(_:)``).
///
/// ## What climbs past the root
///
/// `../../..` past the top of the backend stops at its root, which is what RFC 3986's
/// remove_dot_segments says and what WebKit did with the base above. It is not refused: WebKit
/// clamps before the app sees the URL, so a refusal here could only ever answer for references the
/// app never passes. A target that is really somewhere else is refused instead, by what it names:
/// another computer (``Refusal/anotherHost(_:)``), this Mac's own disk from a document that is not
/// on it (``Refusal/localFile``), or a scheme Dirnex hands to no app (``Refusal/scheme(_:)``).
///
/// The core picks the answer and the app picks the words, which is why a refusal carries facts and
/// no sentence (docs/NOTES.md ▸ Localization).
public enum DocumentLink: Equatable, Sendable {
    /// The document itself: scroll to `fragment`, or stay where it is when there is none.
    case sameDocument(fragment: String?)
    /// Another place on the document's own backend, lexically resolved — `..` and `.` are folded
    /// away, symlinks are not followed. `fragment` is scrolled to once the target renders.
    case location(VFSPath, fragment: String?)
    /// A web page or a mail address, for the app the user has chosen for it.
    case external(URL)
    /// Nowhere Dirnex will take the user, and the reason.
    case refused(Refusal)

    /// Why a link leads nowhere Dirnex will go.
    public enum Refusal: Equatable, Sendable {
        /// A `file:` URL in a document that is not on this Mac's disk: a server's file, or an
        /// archive's member. It names a file on whichever computer the author wrote it on, which is
        /// not a place on the document's backend.
        case localFile
        /// `//host/…`, or a `file:` URL naming a host other than `localhost`: another computer.
        case anotherHost(String)
        /// A scheme Dirnex passes to no app, lowercased: `javascript`, `data`, `ftp`, a Windows drive
        /// letter. Only the web and mail go out (``externalSchemes``), since a click on a custom
        /// scheme can launch an app and run what the URL says.
        case scheme(String)
        /// Not a place: a name that decodes to hold `/` or NUL, a `file:` URL with a relative path, a
        /// web URL with no host, or text no URL parser reads.
        case malformed
    }

    /// The scheme a generated page's base URL is in. Like ``WebArchiveSeal/scheme``, not registered
    /// with WebKit: nothing serves it, so a resource the page names in it loads nothing, and the
    /// content rules block it before that (`QuickViewWebView`).
    public static let scheme = "x-dirnex-document"

    /// The schemes a click hands to another app: the web and mail, which a browser also opens on a
    /// click without asking. `http` and `https` must also name a host.
    static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    /// The base URL to load a generated page under: `document`'s path in ``scheme``, each name
    /// percent-encoded, so WebKit resolves the page's links to backend paths (see the type's
    /// documentation).
    public static func baseURL(for document: VFSPath) -> URL {
        let names = document.path.split(separator: "/", omittingEmptySubsequences: true).map {
            $0.addingPercentEncoding(withAllowedCharacters: nameAllowed) ?? ""
        }
        return URL(string: scheme + ":///" + names.joined(separator: "/")) ?? rootURL
    }

    /// Where `reference` leads from `document`.
    ///
    /// `reference` is either what the author wrote (`../b.md#x`, `https://…`) or the URL WebKit made
    /// of it against ``baseURL(for:)``, and the two give the same answer. A query is dropped from a
    /// path, since it means nothing to a file (GitHub's `?plain=1` is the common one). Names and the
    /// fragment are percent-decoded; one that is not valid percent-encoding is taken as written,
    /// which is what `100%.md` needs.
    public static func resolve(_ reference: String, from document: VFSPath) -> DocumentLink {
        let text = cleaned(reference)
        let (body, rawFragment) = split(text, at: "#")
        let fragment = rawFragment.flatMap { $0.isEmpty ? nil : decoded($0) }
        guard let scheme = scheme(of: body) else {
            return hierarchical(body[...], fragment: fragment, from: document, isRelative: true)
        }
        let rest = body.dropFirst(scheme.count + 1)
        switch scheme {
        case Self.scheme:
            return hierarchical(rest, fragment: fragment, from: document, isRelative: false)
        case "file":
            // `localhost` is this Mac, the one host a `file:` URL may name.
            if let host = host(of: rest), !host.isEmpty, host.lowercased() != "localhost" {
                return .refused(.anotherHost(host))
            }
            guard document.backend == .local else { return .refused(.localFile) }
            return hierarchical(
                withoutHost(rest),
                fragment: fragment,
                from: document,
                isRelative: false
            )
        default:
            guard externalSchemes.contains(scheme) else { return .refused(.scheme(scheme)) }
            guard let url = webURL(text) else { return .refused(.malformed) }
            if scheme != "mailto", (url.host() ?? "").isEmpty { return .refused(.malformed) }
            return .external(url)
        }
    }

    /// `reference` as WHATWG's URL parser reads it before parsing: leading and trailing C0 controls
    /// and spaces trimmed, every tab and line feed and carriage return removed. The second is a
    /// safety rule as much as a parsing one — `java⇥script:` is `javascript:` to WebKit, and has to
    /// be refused as the scheme it is.
    static func cleaned(_ reference: String) -> String {
        let scalars = reference.unicodeScalars
        let isTrimmed: (Unicode.Scalar) -> Bool = { $0.value <= 0x20 }
        guard let first = scalars.firstIndex(where: { !isTrimmed($0) }),
              let last = scalars.lastIndex(where: { !isTrimmed($0) })
        else { return "" }
        var result = String.UnicodeScalarView()
        for scalar in scalars[first...last] where !["\t", "\n", "\r"].contains(scalar) {
            result.append(scalar)
        }
        return String(result)
    }

    /// The scheme `reference` opens with, lowercased: RFC 3986's ASCII letter, then letters, digits,
    /// `+`, `-` and `.`, up to a `:`. `nil` when a `/`, `?` or anything else comes first, which makes
    /// it a relative reference — `./a:b.md` is a file, `C:/x.md` is a scheme.
    static func scheme(of reference: String) -> String? {
        guard let colon = reference.firstIndex(of: ":") else { return nil }
        let candidate = reference[..<colon]
        guard let first = candidate.unicodeScalars.first, isASCIILetter(first),
              candidate.unicodeScalars.allSatisfy({ isASCIILetter($0) || schemeMarks.contains($0) })
        else { return nil }
        return candidate.lowercased()
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// What a scheme may hold after its first letter, besides more letters.
    private static let schemeMarks = Set("0123456789+-.".unicodeScalars)

    /// A path reference — `//authority/path?query`, `/path`, `path` or nothing — resolved against
    /// `document` by RFC 3986 §5.2.2: an authority must be empty (it names another computer
    /// otherwise), an empty path is the document itself, a relative one is merged with the
    /// document's folder, and the query is dropped.
    private static func hierarchical(
        _ reference: Substring,
        fragment: String?,
        from document: VFSPath,
        isRelative: Bool
    ) -> DocumentLink {
        var rest = split(String(reference), at: "?").before[...]
        // An authority, even an empty one (`///x`, `//`), makes the path absolute (§5.2.2).
        let hasAuthority = rest.hasPrefix("//")
        if let host = host(of: rest), !host.isEmpty { return .refused(.anotherHost(host)) }
        if hasAuthority { rest = rest.dropFirst(2) }
        guard let names = decodedNames(of: rest) else { return .refused(.malformed) }
        let merged: [String]
        if hasAuthority || rest.hasPrefix("/") {
            merged = names
        } else if isRelative {
            let own = document.path.split(separator: "/").map(String.init)
            // An empty path keeps the document's own; anything else replaces its last name.
            merged = rest.isEmpty ? own : own.dropLast() + names
        } else {
            // `file:etc/x`: a URL with a scheme and a path that is not rooted names nothing.
            return .refused(.malformed)
        }
        let target = VFSPath(
            backend: document.backend,
            path: "/" + folded(merged).joined(separator: "/")
        )
        return target == document
            ? .sameDocument(fragment: fragment)
            : .location(target, fragment: fragment)
    }

    /// Each name of `path`, percent-decoded on its own, so `%2F` cannot smuggle a separator into
    /// one name; `nil` when a name decodes to hold `/` or NUL, which no backend has a name for.
    private static func decodedNames(of path: Substring) -> [String]? {
        var names: [String] = []
        for encoded in path.split(separator: "/", omittingEmptySubsequences: false) {
            let name = decoded(String(encoded))
            guard !name.contains("/"), !name.contains("\0") else { return nil }
            names.append(name)
        }
        return names
    }

    /// RFC 3986's remove_dot_segments over decoded names, as WHATWG does it: an encoded `%2E%2E` is a
    /// `..` too, and `..` past the root stops there. Empty names go, since a ``VFSPath`` has none.
    private static func folded(_ names: [String]) -> [String] {
        var result: [String] = []
        for name in names {
            switch name {
            case "", ".": continue
            case "..": _ = result.popLast()
            default: result.append(name)
            }
        }
        return result
    }

    /// The host of a `//authority…` reference, decoded: what follows any `user@` and comes before
    /// any `:port`, brackets kept around an IPv6 address. `nil` when there is no authority.
    private static func host(of reference: Substring) -> String? {
        guard reference.hasPrefix("//") else { return nil }
        let authority = reference.dropFirst(2).prefix(while: { $0 != "/" })
        let hostAndPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
        if hostAndPort.hasPrefix("["), let close = hostAndPort.firstIndex(of: "]") {
            return decoded(String(hostAndPort[...close]))
        }
        return decoded(String(hostAndPort.prefix(while: { $0 != ":" })))
    }

    /// `//localhost/x` as `///x`, an empty authority and a rooted path, for a `file:` URL whose host
    /// has been checked; anything without an authority as it is.
    private static func withoutHost(_ reference: Substring) -> Substring {
        guard reference.hasPrefix("//") else { return reference }
        return Substring("//" + reference.dropFirst(2).drop(while: { $0 != "/" }))
    }

    /// A web or mail link as a `URL`, with only the characters a URL cannot hold encoded first: not
    /// what `URL(string:)` does on its own, which re-encodes every `%` once it finds one such
    /// character (see the type's documentation). Every non-ASCII scalar, control, space and the
    /// characters RFC 3986 excludes are encoded; a `%` is left alone when two hex digits follow it.
    static func webURL(_ text: String) -> URL? {
        let scalars = Array(text.unicodeScalars)
        var encoded = ""
        var hasFragment = false
        for (index, scalar) in scalars.enumerated() {
            if scalar == "%" {
                let isEscape = index + 2 < scalars.count
                    && scalars[index + 1].properties.isASCIIHexDigit
                    && scalars[index + 2].properties.isASCIIHexDigit
                encoded += isEscape ? "%" : "%25"
            } else if scalar == "#" {
                // The first `#` opens the fragment; one inside it is a character like any other.
                encoded += hasFragment ? "%23" : "#"
                hasFragment = true
            } else if scalar.isASCII, scalar.value > 0x20, scalar.value < 0x7F, !excluded.contains(
                scalar
            ) {
                encoded.unicodeScalars.append(scalar)
            } else {
                encoded += String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
            }
        }
        return URL(string: encoded, encodingInvalidCharacters: false)
    }

    /// The printable ASCII characters RFC 3986 leaves out of a URL.
    private static let excluded = Set(#""<>\^`{|}"#.unicodeScalars)

    /// `text` percent-decoded, or as written when it is not valid percent-encoding.
    private static func decoded(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    /// `text` before and after the first `separator`, `nil` after when there is none.
    private static func split(_ text: String, at separator: Character) -> (
        before: String,
        after: String?
    ) {
        guard let index = text.firstIndex(of: separator) else { return (text, nil) }
        return (String(text[..<index]), String(text[text.index(after: index)...]))
    }

    /// What a name may hold unencoded in ``baseURL(for:)``: a URL path's characters less `/`. `?`,
    /// `#` and `%` are outside the path set already, so a name holding one cannot end the path early
    /// or read as an escape.
    private static let nameAllowed = CharacterSet.urlPathAllowed.subtracting(
        CharacterSet(charactersIn: "/")
    )

    /// The backend root in ``scheme``, the fallback for a path no URL can be made of — which every name
    /// encoded by ``nameAllowed`` can.
    private static let rootURL = URL(string: scheme + ":///")!
}
