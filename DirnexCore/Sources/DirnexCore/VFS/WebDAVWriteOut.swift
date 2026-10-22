import Foundation

/// The `--write-out` template every WebDAV invocation carries, and the reader that turns one `curl`
/// run into a ``WebDAVHTTPResponse`` — or into the transport failure it really was.
///
/// The labelled lines on stderr are S3's design (``S3WriteOut``) and for its reason: the status is
/// the classification, the body owns stdout, and `curl`'s own prose lands on stderr first.
///
/// What differs is the headers. They arrive as **`%{header_json}`**, every header with every value,
/// rather than as `%header{name}` per header, and that was measured rather than chosen for
/// tidiness: `%header{}` gives only the **first** of several headers with one name. The NAS sends
/// two `DAV` headers (`1,2` and Apache's `propset` URI), and a server offering several schemes sends
/// several `WWW-Authenticate` headers — macOS's Apache, configured as IIS commonly is, answered
/// `["Negotiate","NTLM","Basic realm=…"]` in the JSON and `Negotiate` alone through `%header{}`,
/// which would have read a Basic server as one Dirnex cannot log in to (2026-10-23). The JSON runs
/// over several lines, so it goes last and is read to the end of the stream.
public enum WebDAVWriteOut {
    /// The `-w` argument. `\n` is the two characters `curl` expands, so it survives `argv`.
    public static let format = [
        "%{stderr}",
        "dav-status=%{http_code}\\n",
        "dav-size=%{size_download}\\n",
        "dav-up=%{size_upload}\\n",
        "dav-headers=%{header_json}\\n"
    ].joined()

    /// The marker the header JSON follows.
    static let headersLabel = "dav-headers="

    /// What one invocation reported about its response.
    public struct Fields: Sendable, Equatable {
        /// The HTTP status, or 0 when nothing answered (`curl` prints `000`).
        public let status: Int
        /// Bytes this invocation received — the delta, for a resumed download.
        public let bytesDownloaded: Int64
        /// Bytes this invocation sent.
        public let bytesUploaded: Int64
        /// Every response header, names lowercased, each with all its values in order.
        public let headers: [String: [String]]
    }

    /// Read the labelled lines and the header JSON out of a stderr stream, ignoring anything else in
    /// it. A JSON block that does not parse leaves the headers empty rather than failing the read:
    /// the status is the classification, and a header is only ever a refinement of it.
    public static func parse(stderr: String) -> Fields {
        let (lines, json) = split(stderr)
        var values: [String: String] = [:]
        for line in lines.split(whereSeparator: \.isNewline) where line.hasPrefix("dav-") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            values[String(line[..<separator])] = value
        }
        return Fields(
            status: values["dav-status"].flatMap(Int.init) ?? 0,
            bytesDownloaded: values["dav-size"].flatMap(Int64.init) ?? 0,
            bytesUploaded: values["dav-up"].flatMap(Int64.init) ?? 0,
            headers: json.map(headers(fromJSON:)) ?? [:]
        )
    }

    /// The stream before the header marker, and the JSON after it. The *last* marker, so the
    /// labels are always the write-out's own: `curl`'s prose comes first and could, in principle,
    /// quote anything.
    private static func split(_ stderr: String) -> (lines: Substring, json: Substring?) {
        guard let marker = stderr.range(of: headersLabel, options: .backwards) else {
            return (stderr[...], nil)
        }
        return (stderr[..<marker.lowerBound], stderr[marker.upperBound...])
    }

    private static func headers(fromJSON text: Substring) -> [String: [String]] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let dictionary = object as? [String: Any]
        else { return [:] }
        // `curl` gives every header an array, even a header sent once.
        var headers: [String: [String]] = [:]
        for (name, value) in dictionary {
            guard let values = value as? [Any] else { continue }
            headers[name.lowercased(), default: []] += values.compactMap { $0 as? String }
        }
        return headers
    }

    /// One finished `curl` run as the response the backend classifies, or the transport failure it
    /// was.
    ///
    /// **A status is not enough to call it a response.** Measured on the NAS 2026-10-23: a download
    /// that ran out of `--max-time` part-way reported `dav-status=200` and exit **28**, and left
    /// 584 179 bytes of a 3 129 010-byte file on disk. Read the way S3's runner reads a run — any
    /// status means the server answered — that is a successful copy of a sixth of a photo. So the
    /// exit code decides first: 0 is a response, 22 is `--fail`'s refusal and a response too (the
    /// write-out still carries its 4xx or 5xx), and anything else is a transfer that stopped,
    /// whatever status it had seen by then.
    public static func response(
        exitCode: Int32,
        standardOutput: Data,
        standardError: String
    ) throws -> WebDAVHTTPResponse {
        let fields = parse(stderr: standardError)
        let answered = fields.status != 0
            && (exitCode == 0 || (exitCode == 22 && fields.status >= 400))
        guard answered else {
            throw WebDAVResponseError.transport(.classify(curlExit: exitCode))
        }
        return WebDAVHTTPResponse(
            status: fields.status,
            body: standardOutput,
            headers: fields.headers,
            bytesDownloaded: fields.bytesDownloaded,
            bytesUploaded: fields.bytesUploaded
        )
    }
}
