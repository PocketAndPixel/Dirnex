import Foundation

/// A server's redirect of a folder named without its trailing slash, and the one request sent again
/// because of it (PLAN.md §M38).
///
/// Every request names its resource bare, since the backend is not told whether it is a file or a
/// folder, and a file named with a slash is refused (a 400 on Debian's Apache and the NAS). Most
/// servers take a folder named bare. A stock Debian or Ubuntu Apache does not: its `mod_dir` answers
/// any method naming a folder that way with **301 and `Location` set to the same URL plus `/`**,
/// before `mod_dav` sees the request, so nothing has been done (measured 2026-11-10 on 2.4.68, the
/// table in ``WebDAVProcessArguments``). That answer is the server saying what the resource is, so
/// the request goes once more with the slash. Only that answer moves a request onto the slash, M32's
/// rule that a capability is used where the server's own answer shows it: on a server that never
/// redirects, every request is byte for byte what it was.
///
/// A MOVE or COPY has a second URL, and `mod_dav` looks the `Destination` up as a request of its own.
/// When that names an existing folder bare, the lookup's redirect is the whole answer: **a 301 with
/// no `Location`**. Named with its slash, the same request answers 412, as macOS's Apache answers it
/// bare.
///
/// A PUT is never sent again. It creates what it names, so a redirect to the folder's spelling says a
/// folder already holds the name, and the caller reports that.
public enum WebDAVFolderRedirect {
    /// Whether `response` asks for `serverPath` to be named as a collection: a redirect whose
    /// `Location` names the same path with a trailing slash.
    ///
    /// Only the path is compared, decoded as an href's is (``WebDAVHref/serverPath(fromHref:)``):
    /// the authority is the server's opinion of its own name, which behind a proxy is not the one
    /// dialed, and Apache built it from the `Host` the request sent.
    public static func asksForCollection(
        _ response: WebDAVHTTPResponse,
        at serverPath: String
    ) -> Bool {
        guard isRedirect(response.status), let target = response.value("location") else {
            return false
        }
        return names(target, asCollectionOf: serverPath)
    }

    /// The end of a MOVE or COPY that a redirect asks to be named as a collection, or `nil` when the
    /// answer is not such a redirect.
    ///
    /// A `Location` naming the source with its slash is the source. No `Location` at all, or one
    /// naming the destination with its slash, is the destination. A redirect naming anywhere else
    /// is not about a folder's spelling, and is left as the answer.
    public static func redirectedEnd(
        _ response: WebDAVHTTPResponse,
        source: String,
        destination: String
    ) -> WebDAVCollectionEnds? {
        guard isRedirect(response.status) else { return nil }
        guard let target = response.value("location") else { return .destination }
        if names(target, asCollectionOf: source) { return .source }
        if names(target, asCollectionOf: destination) { return .destination }
        return nil
    }

    /// The statuses that send a client elsewhere with the same request. `mod_dir` sends 301; 302,
    /// 307 and 308 would mean the same thing here. A 303 asks for a GET instead, and 300 and 304
    /// are not redirects of a request at all.
    static func isRedirect(_ status: Int) -> Bool {
        status == 301 || status == 302 || status == 307 || status == 308
    }

    /// Whether `href` is `serverPath` with a trailing slash.
    private static func names(_ href: String, asCollectionOf serverPath: String) -> Bool {
        guard href.hasSuffix("/"), let target = WebDAVHref.serverPath(fromHref: href) else {
            return false
        }
        return WebDAVHref.samePath(target, serverPath)
    }
}

extension WebDAVBackend {
    /// One request naming `path` bare, and one more naming it with its slash when the server's
    /// answer to the first asks for that. A file, and a folder on a server that takes it bare, cost
    /// the one request they always did.
    func namingFolderIfAsked(
        _ path: VFSPath,
        _ send: (_ isCollection: Bool) throws -> WebDAVHTTPResponse
    ) throws -> WebDAVHTTPResponse {
        let response = try mapping(path) { try send(false) }
        guard asksForCollection(response, at: path) else { return response }
        return try mapping(path) { try send(true) }
    }

    /// A MOVE or COPY, sent again with each end a redirect asks to be named as a collection, at most
    /// once per end. A folder moved onto an existing folder is the longest case, three answers:
    /// the source's redirect, the destination's, and the 412 (measured).
    func transferNamingFolders(
        _ source: VFSPath,
        to destination: VFSPath,
        _ send: (WebDAVCollectionEnds) throws -> WebDAVHTTPResponse
    ) throws -> WebDAVHTTPResponse {
        var collections: WebDAVCollectionEnds = []
        var response = try mapping(source) { try send(collections) }
        while let end = WebDAVFolderRedirect.redirectedEnd(
            response,
            source: location.serverPath(forBackendPath: source.path),
            destination: location.serverPath(forBackendPath: destination.path)
        ), !collections.contains(end) {
            collections.insert(end)
            response = try mapping(source) { try send(collections) }
        }
        return response
    }

    /// Whether the server answered a request naming `path` bare by asking for its slash, which a PUT
    /// reads as a folder holding the name.
    func asksForCollection(_ response: WebDAVHTTPResponse, at path: VFSPath) -> Bool {
        WebDAVFolderRedirect.asksForCollection(
            response,
            at: location.serverPath(forBackendPath: path.path)
        )
    }
}
