import Foundation

/// A saved page made unable to reach the network: every origin it was saved from moved to a URL
/// scheme of Dirnex's own before WebKit sees it (PLAN.md §M39).
///
/// ## Why not let WebKit's archive answer
///
/// A previewed file is untrusted input that renders as the cursor passes over it, and Quick View's rule
/// is that the network is off unconditionally (`QuickViewWebView`). WebKit draws a page from its archive
/// without asking the network for anything the archive holds, but it asks for whatever it does *not*
/// find there, and what it finds is up to the file: measured 2026-11-12 against a server's access log,
/// a missing image, a script's `fetch` and an `Image()` pixel all went out from an archive with no
/// rules, and a frame whose archived name did not match the one WebKit generates was fetched from the
/// server even with a rule list that re-admitted exactly the archive's own URLs. A crafted file writes
/// both the names and the page, so a rule list over real URLs is only as safe as WebKit's lookup.
///
/// ## The seal
///
/// So nothing in a sealed archive points at a real origin. `http://example.com:8080/a/b.css` becomes
/// `x-dirnex-archive://o1/a/b.css`: the origin is replaced and the path kept, so the page's relative
/// references still resolve to the resources they meant. The same rewrite runs over the bytes of every
/// text resource, so an absolute reference — `src="https://example.com/x.png"`, `url(//example.com/y)`
/// — moves with the resource it names. A `cid:` reference (an MHTML part) becomes
/// `x-dirnex-archive://cid/<id>`.
///
/// Under one rule that re-admits ``scheme`` and blocks everything else, WebKit drew a sealed archive's
/// script, web font, CSS background, SVG and subframe from the archive with zero requests, and a frame
/// whose name was deliberately wrong came up **empty**, still with zero requests: a miss in this scheme
/// has no network path at all, not even a DNS lookup. And every reference the rewrite fails to find —
/// an escaped one in a script, a host spelled with a default port — keeps its real origin, which the
/// rule blocks. So the seal fails closed: it can lose a resource, and it cannot leak one.
public enum WebArchiveSeal {
    /// The scheme every sealed URL is in. Not registered with WebKit — nothing serves it but the
    /// archive, which is the point.
    public static let scheme = "x-dirnex-archive"

    /// The host `cid:` references move to.
    static let cidHost = "cid"

    /// A sealed archive, and how to undo the seal for one URL.
    public struct Sealed: Sendable, Equatable {
        public let archive: WebArchive
        /// Each synthetic origin, `x-dirnex-archive://o1`, and the origin it stands for, as the
        /// archive first wrote it.
        public let origins: [String: String]

        /// The real URL behind `sealedURL`, or `nil` for a URL that is not one of this archive's —
        /// for a link the user clicked, which should open where its author pointed it.
        public func originalURL(for sealedURL: String) -> String? {
            guard let split = WebArchiveSeal.splitOrigin(sealedURL),
                  split.origin.lowercased().hasPrefix(WebArchiveSeal.scheme + "://")
            else { return nil }
            let host = split.origin.dropFirst(WebArchiveSeal.scheme.count + 3).lowercased()
            if host == WebArchiveSeal.cidHost {
                let id = split.rest.dropFirst().removingPercentEncoding ?? String(
                    split.rest.dropFirst()
                )
                return "cid:" + id
            }
            guard let original = origins[WebArchiveSeal.scheme + "://" + host] else { return nil }
            return original + split.rest
        }
    }

    /// `archive` with every origin and `cid:` it holds moved into ``scheme``, in its resources' URLs and
    /// in the bytes of its text resources.
    ///
    /// Origins are numbered in the order ``WebArchive/allResources`` meets them, the page's own first,
    /// so a page saved from one site is `o1` throughout.
    public static func seal(_ archive: WebArchive) -> Sealed {
        var table = OriginTable()
        for url in archive.allURLs {
            table.add(url)
        }
        let rewriter = TextRewriter(table: table)
        let sealed = archive.mappingResources { resource in
            var resource = resource
            resource.url = table.sealedURL(for: resource.url)
            if isText(resource), !isWideEncoding(resource) {
                resource.data = rewriter.rewrite(resource.data)
            }
            return resource
        }
        return Sealed(archive: sealed, origins: table.originalOrigins)
    }

    // MARK: Which resources are text

    /// Whether `resource` is text a reference can sit in: a page, a stylesheet, a script, an SVG.
    /// An image or a font is bytes, and rewriting inside it would corrupt it.
    static func isText(_ resource: WebArchive.Resource) -> Bool {
        let type = resource.mimeType.lowercased()
        if type.hasPrefix("text/") || type.hasSuffix("+xml") { return true }
        return [
            "application/javascript", "application/x-javascript", "application/ecmascript",
            "application/json", "application/xml", "application/xhtml+xml"
        ].contains(type)
    }

    /// Whether `resource` is in an encoding where an ASCII URL is not its ASCII bytes. The rewrite works
    /// on bytes, so such a resource is left as it is, and its absolute references fail closed.
    static func isWideEncoding(_ resource: WebArchive.Resource) -> Bool {
        let name = (resource.textEncodingName ?? "").lowercased()
        if name.contains("16") || name.contains("32") || name.contains("ucs-2") || name == "unicode" {
            return true
        }
        let head = [UInt8](resource.data.prefix(4))
        return head.starts(with: [0xFE, 0xFF]) || head.starts(with: [0xFF, 0xFE])
            || head.starts(with: [0x00, 0x00, 0xFE, 0xFF])
    }

    // MARK: URL anatomy

    /// The scheme of `url` — the letters before the first `:` — or `nil` when it has none, which makes it
    /// a relative reference (RFC 3986 §3.1).
    static func scheme(of url: String) -> String? {
        guard let colon = url.firstIndex(of: ":"), colon != url.startIndex else { return nil }
        let scheme = url[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }
        return String(scheme)
    }

    /// `url` split into its origin — `scheme://authority` — and the rest, for a URL that has an
    /// authority. `nil` for one that does not: `cid:`, `data:`, `about:blank`, a relative path.
    static func splitOrigin(_ url: String) -> (origin: String, rest: String)? {
        guard let scheme = scheme(of: url) else { return nil }
        let afterScheme = url.index(url.startIndex, offsetBy: scheme.count + 1)
        guard url[afterScheme...].hasPrefix("//") else { return nil }
        let authorityStart = url.index(afterScheme, offsetBy: 2)
        let end = url[authorityStart...].firstIndex { "/?#".contains($0) } ?? url.endIndex
        return (String(url[..<end]), String(url[end...]))
    }
}

// MARK: - The origin table

extension WebArchiveSeal {
    /// Which synthetic origin stands for which real one, and which `cid:` names the archive holds.
    struct OriginTable {
        /// Lowercased real origin → synthetic origin. Scheme and host compare without regard to case.
        private(set) var synthetic: [String: String] = [:]
        /// Synthetic origin → the real origin as the archive first wrote it.
        private(set) var originalOrigins: [String: String] = [:]
        /// The real origins in the order they were met, as written.
        private(set) var origins: [String] = []
        /// The `cid:` identifiers the archive's resources are named by.
        private(set) var contentIDs: [String] = []

        mutating func add(_ url: String) {
            if let id = WebArchiveSeal.contentID(of: url) {
                if !contentIDs.contains(id) { contentIDs.append(id) }
                return
            }
            guard let origin = WebArchiveSeal.splitOrigin(url)?.origin else { return }
            let key = origin.lowercased()
            guard synthetic[key] == nil else { return }
            let name = WebArchiveSeal.scheme + "://o\(origins.count + 1)"
            synthetic[key] = name
            originalOrigins[name] = origin
            origins.append(origin)
        }

        /// `url` sealed: its origin replaced, or its `cid:` moved under ``WebArchiveSeal/cidHost``. A URL
        /// with neither — `data:`, `about:blank` — cannot reach the network and is kept.
        func sealedURL(for url: String) -> String {
            if let id = WebArchiveSeal.contentID(of: url) {
                return WebArchiveSeal.sealedCID(id)
            }
            guard let split = WebArchiveSeal.splitOrigin(url),
                  let replacement = synthetic[split.origin.lowercased()]
            else { return url }
            return replacement + split.rest
        }
    }

    /// The identifier in a `cid:` URL, or `nil` for any other URL.
    static func contentID(of url: String) -> String? {
        guard url.count > 4, url.prefix(4).lowercased() == "cid:" else { return nil }
        return String(url.dropFirst(4))
    }

    /// The sealed URL a `cid:` identifier moves to, percent-encoded so that an identifier holding a `/`
    /// or a `#` stays one path segment.
    static func sealedCID(_ id: String) -> String {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: cidAllowed) ?? id
        return scheme + "://" + cidHost + "/" + encoded
    }

    /// RFC 3986's unreserved characters and the sub-delimiters, ASCII only: a path segment's own.
    private static let cidAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~@$!&'()*+,;=:"
    )
}

// MARK: - Rewriting text

extension WebArchiveSeal {
    /// The single pass that moves every reference in a text resource into the sealed scheme.
    ///
    /// It matches three kinds of token, without regard to ASCII case, and each only where it stands
    /// alone, so `http://a.com` is not found inside `http://a.com.evil` or `http://a.com:8080`:
    ///
    /// - an origin, `http://example.com:8080`, becoming its synthetic origin;
    /// - a protocol-relative authority, `//example.com`, becoming `//o1`, only where a reference can
    ///   start (after a quote, a parenthesis, `=`, a comma or whitespace), since a `//` elsewhere is
    ///   part of some other URL's path;
    /// - a `cid:` reference, becoming its sealed URL.
    ///
    /// The output is never scanned again, so a replacement cannot itself be rewritten, whatever the
    /// archive calls its hosts.
    struct TextRewriter {
        /// The tokens by their first byte, lowercased, longest first.
        private let tokens: [UInt8: [RewriteToken]]

        init(table: OriginTable) {
            var all: [RewriteToken] = []
            var authorities: Set<String> = []
            let pageScheme = table.origins.first.flatMap(WebArchiveSeal.scheme(of:))?.lowercased()
            // The page's own scheme first, so a host saved under both picks the page's.
            let ordered = table.origins.filter { WebArchiveSeal.scheme(of: $0)?.lowercased() == pageScheme }
                + table.origins.filter { WebArchiveSeal.scheme(of: $0)?.lowercased() != pageScheme }
            for origin in ordered {
                guard let synthetic = table.synthetic[origin.lowercased()] else { continue }
                all.append(
                    RewriteToken(
                        pattern: Self.lowered(origin),
                        replacement: Array(synthetic.utf8),
                        kind: .origin
                    )
                )
                guard let slashes = origin.range(of: "//"),
                      let syntheticSlashes = synthetic.range(of: "//")
                else { continue }
                let authority = String(origin[slashes.lowerBound...])
                guard authority.count > 2, authorities.insert(authority.lowercased()).inserted else { continue }
                all.append(RewriteToken(
                    pattern: Self.lowered(authority),
                    replacement: Array(synthetic[syntheticSlashes.lowerBound...].utf8),
                    kind: .protocolRelative
                ))
            }
            for id in table.contentIDs {
                all.append(RewriteToken(
                    pattern: Self.lowered("cid:" + id),
                    replacement: Array(WebArchiveSeal.sealedCID(id).utf8),
                    kind: .contentID
                ))
            }
            tokens = Dictionary(grouping: all) { $0.pattern[0] }
                .mapValues { $0.sorted { $0.pattern.count > $1.pattern.count } }
        }

        func rewrite(_ data: Data) -> Data {
            guard !tokens.isEmpty else { return data }
            let bytes = [UInt8](data)
            var out: [UInt8] = []
            var copied = 0
            var index = 0
            while index < bytes.count {
                guard let candidates = tokens[Self.lower(bytes[index])],
                      let token = candidates.first(where: { matches($0, in: bytes, at: index) })
                else {
                    index += 1
                    continue
                }
                if out.isEmpty { out.reserveCapacity(bytes.count + 64) }
                out += bytes[copied..<index]
                out += token.replacement
                index += token.pattern.count
                copied = index
            }
            guard copied > 0 else { return data }
            out += bytes[copied...]
            return Data(out)
        }

        private func matches(_ token: RewriteToken, in bytes: [UInt8], at start: Int) -> Bool {
            let end = start + token.pattern.count
            guard end <= bytes.count else { return false }
            for offset in 1..<token.pattern.count {
                guard Self.lower(bytes[start + offset]) == token.pattern[offset] else { return false }
            }
            let before = start > 0 ? bytes[start - 1] : nil
            let after = end < bytes.count ? bytes[end] : nil
            if let after, Self.continuesName(after) { return false }
            guard let before else { return true }
            switch token.kind {
            case .origin, .contentID: return !Self.isSchemeByte(before)
            case .protocolRelative: return Self.canStartReference(before)
            }
        }

        /// A byte that would make the token a prefix of a longer host, port or identifier.
        private static func continuesName(_ byte: UInt8) -> Bool {
            isAlphanumeric(byte) || "-._~%:@$+".utf8.contains(byte)
        }

        private static func isSchemeByte(_ byte: UInt8) -> Bool {
            isAlphanumeric(byte) || "+-.".utf8.contains(byte)
        }

        private static func canStartReference(_ byte: UInt8) -> Bool {
            "\"'(=, \t\r\n`".utf8.contains(byte)
        }

        private static func isAlphanumeric(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(lower(byte))
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }

        private static func lower(_ byte: UInt8) -> UInt8 {
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte | 0x20 : byte
        }

        private static func lowered(_ string: String) -> [UInt8] {
            string.utf8.map(lower)
        }
    }
}

/// One thing ``WebArchiveSeal/TextRewriter`` looks for, and what it writes instead.
private struct RewriteToken {
    enum Kind {
        case origin, protocolRelative, contentID
    }

    let pattern: [UInt8]
    let replacement: [UInt8]
    let kind: Kind
}
