import Foundation

/// An `.mhtml` (`.mht`) saved page, converted into the ``WebArchive`` WebKit can draw (PLAN.md §M39).
///
/// WebKit on macOS has no MHTML: loaded as `multipart/related` it draws the file's raw headers as text,
/// and `loadFileURL` refuses it ("Frame load interrupted"), measured 2026-11-12. But the format is a
/// webarchive in other clothes (RFC 2557): one MIME part per resource, each naming the URL it came from
/// in `Content-Location` or the name the page uses for it in `Content-ID`. So each part becomes a
/// resource, and WebKit draws the result as it draws a page Safari saved.
///
/// What Chrome writes, which is what the format is in practice (Edge is the same engine): CRLF lines,
/// every reference rewritten to an absolute URL, quoted-printable HTML and CSS, base64 images, no
/// scripts, an iframe as `src="cid:frame-…@mhtml.blink"` with a `Content-ID` and a `Content-Location`,
/// and a frame's own `<style>` as a `text/css` part whose `Content-Location` is itself a `cid:` URL.
public enum MHTMLArchive {
    /// The UTI macOS gives an `.mhtml` file.
    public static let contentType = "org.ietf.mhtml"
    /// The extensions saved pages carry, `.mht` being Internet Explorer's and Word's spelling.
    public static let fileExtensions: Set<String> = ["mhtml", "mht"]

    public enum Failure: Error, Equatable {
        /// Not MIME at all, or MIME with no part a browser could show as the page.
        case noPage
    }

    /// The page in `data`, as a webarchive.
    ///
    /// The page is the part the multipart's `start` parameter names, else the first part, which is
    /// RFC 2387's rule; when that is not HTML, the first HTML part. Every other HTML part is a frame
    /// (``frames(of:among:)``), and everything else a subresource of the page.
    public static func webArchive(from data: Data) throws(Failure) -> WebArchive {
        guard let message = MIMEEntity(parsing: data) else { throw .noPage }
        let base = message.header("Snapshot-Content-Location") ?? message.header("Content-Location")
        let parts = message.leaves.map { Part($0, base: base) }
        guard let page = rootIndex(of: message, among: parts) else { throw .noPage }

        let others = parts.indices.filter { $0 != page }
        let frameIndices = others.filter { parts[$0].isHTML }
        let resources = others.filter { !parts[$0].isHTML }.flatMap { parts[$0].resources }
        let frames = frames(of: parts[page], among: frameIndices.map { parts[$0] })
            .enumerated()
            .map { order, part in
                WebArchive(
                    mainResource: part.resource(url: part.frameURL),
                    frameName: "<!--frame\(order + 1)-->",
                    subresources: referenced(by: part, in: resources)
                )
            }
        return WebArchive(
            mainResource: parts[page].resource(url: parts[page].pageURL),
            subresources: resources,
            subframes: frames
        )
    }

    /// The part that is the page.
    private static func rootIndex(of message: MIMEEntity, among parts: [Part]) -> Int? {
        if !message.contentType.isMultipart {
            return parts.first?.isHTML == true ? 0 : nil
        }
        if let start = message.contentType.parameter("start").map(Part.contentID),
           let index = parts.firstIndex(where: { $0.contentID == start }), parts[index].isHTML {
            return index
        }
        if parts.first?.isHTML == true { return 0 }
        return parts.firstIndex(where: \.isHTML)
    }

    /// The frames in the order the page refers to them, which is the order WebKit names unnamed frames
    /// in: `<!--frame1-->`, `<!--frame2-->`, …. A frame the page never names follows, in file order.
    ///
    /// The name is a guess about WebKit's count, and a wrong guess draws an empty frame. It cannot do
    /// more: the archive is sealed (``WebArchiveSeal``), so a frame WebKit fails to find in it has
    /// nowhere else to come from. Frames inside frames are flattened into the page's list, since Chrome
    /// writes them flat, and draw empty for the same reason.
    private static func frames(of page: Part, among frames: [Part]) -> [Part] {
        let text = page.body
        let positions = frames.map { frame in
            frame.names.compactMap { firstRange(of: $0, in: text)?.lowerBound }.min() ?? Int.max
        }
        return frames.indices.sorted { positions[$0] < positions[$1] }.map { frames[$0] }
    }

    /// The resources a frame's text names, and the ones *their* text names, since a frame finds
    /// resources only in its own archive (measured: a frame drew unstyled until its stylesheet was
    /// copied in). A name is matched as written, which is how Chrome writes every reference: absolute,
    /// or a `cid:`. A relative reference inside a frame from some other writer is not found, and that
    /// one resource is missing from the frame.
    private static func referenced(
        by frame: Part,
        in resources: [WebArchive.Resource]
    ) -> [WebArchive.Resource] {
        var included = Set<Int>()
        var queue: [Data] = [frame.body]
        while let text = queue.popLast() {
            for (index, resource) in resources.enumerated() where !included.contains(index) {
                guard firstRange(of: resource.url, in: text) != nil else { continue }
                included.insert(index)
                if WebArchiveSeal.isText(resource) { queue.append(resource.data) }
            }
        }
        return resources.indices.filter(included.contains).map { resources[$0] }
    }

    /// Where `needle` first occurs in `haystack`, ASCII case ignored.
    private static func firstRange(of needle: String, in haystack: Data) -> Range<Int>? {
        let pattern = Array(needle.utf8).map(asciiLowercase)
        guard !pattern.isEmpty, haystack.count >= pattern.count else { return nil }
        return haystack.withUnsafeBytes { raw -> Range<Int>? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let first = pattern[0]
            var index = 0
            let last = bytes.count - pattern.count
            while index <= last {
                if asciiLowercase(bytes[index]) == first {
                    var offset = 1
                    while offset < pattern.count, asciiLowercase(bytes[index + offset]) == pattern[
                        offset
                    ] {
                        offset += 1
                    }
                    if offset == pattern.count { return index..<(index + pattern.count) }
                }
                index += 1
            }
            return nil
        }
    }

    private static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte | 0x20 : byte
    }

    /// One MIME part, with the names a page may use for it.
    private struct Part {
        let mimeType: String
        let charset: String?
        let body: Data
        /// `Content-Location`, resolved against the message's own location when it is relative.
        let location: String?
        /// `Content-ID` without its angle brackets.
        let contentID: String?

        init(_ entity: MIMEEntity, base: String?) {
            let type = entity.contentType
            mimeType = type.type
            charset = type.parameter("charset").flatMap { $0.isEmpty ? nil : $0 }
            body = entity.body
            contentID = entity.header("Content-ID").map(Self.contentID)
            location = entity.header("Content-Location").flatMap { Self.resolve($0, against: base) }
        }

        var isHTML: Bool { mimeType == "text/html" || mimeType == "application/xhtml+xml" }

        /// The part's `cid:` URL, the form a page refers to a `Content-ID` by (RFC 2392).
        var cidURL: String? { contentID.map { "cid:" + $0 } }

        /// Every name the page may refer to this part by.
        var names: [String] { [cidURL, location].compactMap(\.self) }

        /// The page's own URL: where it came from, which is what its relative references resolve
        /// against. A page that says nothing gets a `cid:` of its own.
        var pageURL: String { location ?? cidURL ?? "cid:dirnex-page" }

        /// A frame's URL is the one its `<iframe src>` names, which is the `cid:` in Chrome's files.
        var frameURL: String { cidURL ?? location ?? "cid:dirnex-frame" }

        /// The resource under each name the page may use: a part Chrome gives both a `Content-ID`
        /// and a `Content-Location` is in the archive twice, once per name.
        var resources: [WebArchive.Resource] {
            names.map(resource(url:))
        }

        func resource(url: String) -> WebArchive.Resource {
            WebArchive.Resource(url: url, mimeType: mimeType, textEncodingName: charset, data: body)
        }

        static func contentID(_ value: String) -> String {
            var id = value.trimmingCharacters(in: .whitespaces)
            if id.hasPrefix("<"), id.hasSuffix(">") { id = String(id.dropFirst().dropLast()) }
            return id
        }

        /// `location` made absolute. One that is already absolute, a `cid:` included, is kept exactly
        /// as written, because that is how the page refers to it.
        static func resolve(_ location: String, against base: String?) -> String? {
            let trimmed = location.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if WebArchiveSeal.scheme(of: trimmed) != nil { return trimmed }
            guard let base, let baseURL = URL(string: base),
                  let resolved = URL(string: trimmed, relativeTo: baseURL)
            else { return trimmed }
            return resolved.absoluteString
        }
    }
}
