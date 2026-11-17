import Foundation

/// A saved web page in the shape WebKit reads it: a `.webarchive` property list (PLAN.md §M39).
///
/// The page's own bytes, every subresource it loaded, and an archive of its own for each frame, each
/// resource keyed by the URL it was fetched from. WebKit draws a page from one of these without asking
/// the network for anything the archive holds — measured 2026-11-12 against a server's access log —
/// which is what lets Quick View show a saved page at all. What it asks for when the archive *lacks*
/// something is the reason ``WebArchiveSeal`` exists.
///
/// Read and written here rather than handed to WebKit as-is, for two reasons. An `.mhtml` is converted
/// to one (``MHTMLArchive``), since WebKit has no MHTML. And every archive is sealed before WebKit
/// sees it, which rewrites URLs.
///
/// Only the keys WebKit needs survive a round trip. `WebResourceResponse` is dropped: it is an archived
/// `NSURLResponse` naming the resource's original URL, which the seal changes, and WebKit drew a
/// converted MHTML (which never had one) from its MIME type alone. Dropping it also keeps one keyed
/// archive from a file somebody else wrote away from WebKit's unarchiver.
public struct WebArchive: Sendable, Equatable {
    /// One resource: the page itself, or something it loaded.
    public struct Resource: Sendable, Equatable {
        /// The URL it was fetched from, as WebKit wrote it, and what the page refers to it by.
        public var url: String
        public var mimeType: String
        /// The text encoding the resource was served with, or `nil` for none. A page with none
        /// honours its own `<meta charset>`, measured on a windows-1252 page.
        public var textEncodingName: String?
        public var data: Data

        public init(url: String, mimeType: String, textEncodingName: String? = nil, data: Data) {
            self.url = url
            self.mimeType = mimeType
            self.textEncodingName = textEncodingName
            self.data = data
        }
    }

    /// The document of this page or frame.
    public var mainResource: Resource
    /// The name WebKit finds a frame's archive by: empty for the page, and `<!--frameN-->` for a
    /// frame its page did not name, which is what WebKit itself writes. A frame whose name does not
    /// match is not drawn from the archive at all.
    public var frameName: String
    public var subresources: [Resource]
    /// One archive per frame. **A frame finds resources only in its own archive**, not its parent's
    /// (measured: a frame drew unstyled until its stylesheet was copied in).
    public var subframes: [WebArchive]

    public init(
        mainResource: Resource,
        frameName: String = "",
        subresources: [Resource] = [],
        subframes: [WebArchive] = []
    ) {
        self.mainResource = mainResource
        self.frameName = frameName
        self.subresources = subresources
        self.subframes = subframes
    }

    /// How deep frames nest before the rest are dropped. A page of frames inside frames inside frames
    /// is not something anybody saved on purpose, and the reader recurses.
    public static let maximumFrameDepth = 16

    /// The UTI macOS gives a `.webarchive`.
    public static let contentType = "com.apple.webarchive"
    /// The MIME type `WKWebView.load(_:mimeType:…)` takes one under.
    public static let mimeType = "application/x-webarchive"

    /// Every resource in the archive, frames included, depth first: each archive's page, then its
    /// subresources, then its frames.
    public var allResources: [Resource] {
        [mainResource] + subresources + subframes.flatMap(\.allResources)
    }

    /// Every resource's URL, frames included, in ``allResources`` order.
    public var allURLs: [String] { allResources.map(\.url) }

    /// This archive with `transform` applied to every resource, frames included.
    public func mappingResources(_ transform: (Resource) -> Resource) -> WebArchive {
        WebArchive(
            mainResource: transform(mainResource),
            frameName: frameName,
            subresources: subresources.map(transform),
            subframes: subframes.map { $0.mappingResources(transform) }
        )
    }
}

// MARK: - The property list

extension WebArchive {
    private enum Key {
        static let mainResource = "WebMainResource"
        static let subresources = "WebSubresources"
        static let subframes = "WebSubframeArchives"
        static let data = "WebResourceData"
        static let url = "WebResourceURL"
        static let mimeType = "WebResourceMIMEType"
        static let textEncodingName = "WebResourceTextEncodingName"
        static let frameName = "WebResourceFrameName"
    }

    /// Read a `.webarchive`, or `nil` when `data` is not one: not a property list, or no main
    /// resource with bytes, a URL and a MIME type.
    ///
    /// A subresource missing any of the three is skipped rather than failing the page, since the page
    /// draws without it. Frames past ``maximumFrameDepth`` are dropped.
    public init?(propertyList data: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
        else { return nil }
        self.init(dictionary: plist, depth: 0)
    }

    private init?(dictionary: [String: Any], depth: Int) {
        guard let main = dictionary[Key.mainResource] as? [String: Any],
              let mainResource = Self.resource(main)
        else { return nil }
        self.mainResource = mainResource
        frameName = main[Key.frameName] as? String ?? ""
        subresources = (dictionary[Key.subresources] as? [[String: Any]] ?? [])
            .compactMap(Self.resource)
        if depth + 1 < Self.maximumFrameDepth {
            subframes = (dictionary[Key.subframes] as? [[String: Any]] ?? [])
                .compactMap { WebArchive(dictionary: $0, depth: depth + 1) }
        } else {
            subframes = []
        }
    }

    private static func resource(_ dictionary: [String: Any]) -> Resource? {
        guard let data = dictionary[Key.data] as? Data,
              let url = dictionary[Key.url] as? String,
              let mimeType = dictionary[Key.mimeType] as? String
        else { return nil }
        let encoding = (dictionary[Key.textEncodingName] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Resource(url: url, mimeType: mimeType, textEncodingName: encoding, data: data)
    }

    /// The archive as a binary property list, the bytes `WKWebView` loads under ``mimeType``.
    public func propertyListData() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .binary,
            options: 0
        )
    }

    private var dictionary: [String: Any] {
        var main = Self.dictionary(mainResource)
        main[Key.frameName] = frameName
        var archive: [String: Any] = [Key.mainResource: main]
        if !subresources.isEmpty {
            archive[Key.subresources] = subresources.map(Self.dictionary)
        }
        if !subframes.isEmpty {
            archive[Key.subframes] = subframes.map(\.dictionary)
        }
        return archive
    }

    private static func dictionary(_ resource: Resource) -> [String: Any] {
        var dictionary: [String: Any] = [
            Key.data: resource.data,
            Key.url: resource.url,
            Key.mimeType: resource.mimeType
        ]
        if let encoding = resource.textEncodingName {
            dictionary[Key.textEncodingName] = encoding
        }
        return dictionary
    }
}
