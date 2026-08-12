import Foundation

/// Why an S3 request failed, read from the response rather than from `curl`'s exit status.
///
/// This is the exact inverse of the rule `FTPBackend` follows, and getting it backwards costs the
/// whole error vocabulary. NOTES.md ▸ curl states it for FTP: "the exit code is the classification
/// — do not scrape stderr", because every FTP failure that matters has its own documented code.
/// S3 speaks HTTP, so **`curl` exits 0** for a missing key, a denied bucket, a bad signature and a
/// wrong region alike (measured against real AWS 2026-08-12 — 404, 403, 403 and 301, all exit 0).
/// The classification lives in the HTTP status and the `<Code>` element of the error document.
///
/// The exit status is still read, but for a narrower question: whether the request reached a server
/// at all.
public enum S3ResponseError: Error, Sendable, Equatable {
    /// The request never got an answer — `curl`'s own failure, classified by its exit code the way
    /// the FTP backend does.
    case transport(S3TransportFailure)
    /// The server answered, and said no.
    case service(S3ServiceError)
}

/// A failure that happened below HTTP, named by `curl`'s exit code.
public enum S3TransportFailure: Int32, Sendable, Equatable {
    case couldNotResolveHost = 6
    case couldNotConnect = 7
    case operationTimedOut = 28
    case certificateNotTrusted = 60
    /// Anything else `curl` reported. The raw code rides along in ``S3ResponseError`` diagnostics
    /// rather than being flattened away, since an unrecognized code is still worth showing.
    case other = -1

    public static func classify(curlExit code: Int32) -> S3TransportFailure {
        S3TransportFailure(rawValue: code) ?? .other
    }
}

/// The server's own refusal: the HTTP status, S3's error `<Code>`, and whatever else the document
/// carried that the app can act on.
public struct S3ServiceError: Sendable, Equatable {
    /// The HTTP status line's code.
    public let status: Int
    /// S3's machine-readable error code — `NoSuchKey`, `AccessDenied`, `SignatureDoesNotMatch`.
    /// Empty when the body was not an S3 error document, which a proxy or a captive portal can
    /// easily produce; the status alone still classifies those.
    public let code: String
    /// The server's English message. Diagnostic only — never shown as the user-facing sentence,
    /// for the reason NOTES.md ▸ Localization gives for `sftp`'s stderr: it is the *remote's*
    /// words, in a language nobody chose.
    public let message: String
    /// The endpoint a `PermanentRedirect` names as the correct one for this bucket.
    ///
    /// This is the field worth having and the reason the whole document is parsed rather than just
    /// the status: addressing a bucket through the wrong region answers **301** with the right host
    /// in the body (probed 2026-08-12 — `sentinel-s2-l1c.s3.eu-central-1.amazonaws.com` came back
    /// from a request aimed at `eu-west-2`). So the connect form can *correct* a mistyped region
    /// instead of reporting a failure the user has no way to diagnose — "wrong region" is otherwise
    /// indistinguishable from "no such bucket" from outside.
    public let correctEndpoint: String?

    public init(status: Int, code: String, message: String, correctEndpoint: String? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.correctEndpoint = correctEndpoint
    }
}

public extension S3ServiceError {
    /// Parse S3's `<Error>` document. Falls back to a code-less value carrying just the status, so
    /// a non-S3 body (a proxy's HTML, an empty 500) still classifies rather than throwing.
    static func parse(_ data: Data, status: Int) -> S3ServiceError {
        let delegate = ErrorDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return S3ServiceError(
            status: status,
            code: delegate.values["Code"] ?? "",
            message: delegate.values["Message"] ?? "",
            correctEndpoint: delegate.values["Endpoint"]
        )
    }

    /// Whether this is the wrong-region redirect, which the caller can retry against
    /// ``correctEndpoint`` rather than report.
    var isRegionRedirect: Bool {
        status == 301 || code == "PermanentRedirect"
    }

    /// Whether the credentials are the problem, as opposed to the permissions on them.
    ///
    /// Worth separating because the two send the user to different places: a bad key or a bad
    /// secret is something they retype, while `AccessDenied` on a key that authenticated fine is a
    /// bucket policy they have to go and change. Both arrive as HTTP 403, so the status cannot tell
    /// them apart and the `<Code>` is the only thing that can.
    var isCredentialFailure: Bool {
        code == "InvalidAccessKeyId" || code == "SignatureDoesNotMatch"
    }

    /// The closest `VFSError`, for the paths that must answer in the shared vocabulary.
    ///
    /// Deliberately maps onto the cases that already exist rather than growing
    /// `VFSUnsupportedReason`: a new reason needs a translated sentence in the app's catalog, and
    /// this slice is core-only. The named sentences land with the app wiring, where the catalog
    /// entries can land in the same commit — a reason without one compiles to its own key and
    /// renders as `vfs.unsupported.…` on screen (NOTES.md ▸ Localization).
    func vfsError(for path: VFSPath) -> VFSError {
        switch status {
        case 404: return .notFound(path)
        case 403, 401: return .permissionDenied(path)
        case 409: return .alreadyExists(path)
        default: return .io(path: path, code: EIO)
        }
    }
}

private final class ErrorDelegate: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    private var element = ""
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        element = elementName
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // First writer wins: `<Error>` nests nothing, but a `Message` inside a retried document or
        // a proxy's wrapper would otherwise overwrite the real one.
        if !value.isEmpty, values[elementName] == nil {
            values[elementName] = value
        }
        text = ""
    }
}
