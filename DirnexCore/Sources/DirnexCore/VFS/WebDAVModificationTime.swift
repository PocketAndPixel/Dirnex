import Foundation

/// `X-OC-Mtime`, the header ownCloud and Nextcloud read on a PUT as the date to give the file, and
/// the answer that says whether a server did.
///
/// WebDAV itself cannot set a time: `getlastmodified` is read-only (409 on the NAS), and a
/// `Win32LastModifiedTime` PROPPATCH answers 200 and changes nothing (PLAN.md §M32). Nextcloud's
/// header is not a standard, so it is only ever **asked**, and the date counts as kept only when
/// the server **says** it kept it. Probed 2026-10-24 against Nextcloud 34.0.5:
///
/// - **A PUT carrying it gets the date, and says so** with `X-OC-MTime: accepted` on the response.
///   A 2020 time came back as the file's `getlastmodified`, and COPY and MOVE kept it after.
/// - **Apache ignores it and answers nothing about it**, on the NAS and on macOS's own, so sending
///   it everywhere costs a server that does not know it nothing.
/// - **A time the server will not take fails the request, and the bytes are written anyway.** `0`
///   and `-86400` answered **500** ("must be a valid positive unix timestamp greater than one
///   day"), and the file held the new bytes afterwards, over an existing file and as a new one. So
///   a time Nextcloud would refuse is never sent: the date is then counted as not kept, which is
///   true, and the PUT stays an ordinary one.
/// - **The value is whole seconds.** `1577880000.75` was accepted and kept as `1577880000`;
///   anything that is not a number answered 500 like `0`.
/// - **MKCOL ignores it**, so a recreated folder's date is still not carried.
public enum WebDAVModificationTime {
    /// The request header's name, as Nextcloud's own client spells it.
    static let headerName = "X-OC-Mtime"

    /// The earliest time sent: Nextcloud refuses one day or less after 1970, and failing the PUT
    /// over a date would cost the file.
    static let earliestSeconds: Int64 = 86400

    /// The header value for `date`: its whole seconds, or `nil` for a time no server measured
    /// would take, which is then not asked for at all.
    public static func headerValue(for date: Date) -> String? {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        guard seconds.isFinite, seconds > Double(earliestSeconds), seconds < Double(Int64.max)
        else { return nil }
        return String(Int64(seconds))
    }

    /// The `curl` arguments that ask for `date`, or none.
    static func headerArguments(for date: Date?) -> [String] {
        guard let value = date.flatMap(headerValue(for:)) else { return [] }
        return ["-H", "\(headerName): \(value)"]
    }

    /// Whether the server says it kept the date it was sent: `X-OC-MTime: accepted`, in any case.
    /// Any other answer, no answer included, is a date not kept.
    public static func wasKept(by response: WebDAVHTTPResponse) -> Bool {
        response.values(headerName).contains {
            $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("accepted") == .orderedSame
        }
    }
}
