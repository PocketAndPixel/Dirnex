import Foundation

/// The space a WebDAV server says is left, read at a connection's root for the tooltip on its
/// sidebar row (RFC 4331, PLAN.md §M38 Slice 7).
///
/// Measured 2026-11-10. Which servers answer at all:
///
/// - **Nextcloud 34** answers on every folder. The number is the account's free space wherever it
///   is asked, so a root saved below the account's own reads the same as the account root.
/// - **Apache's `mod_dav`** answers 404 for the property inside its 207, the NAS's and macOS's
///   2.4.67 and Debian's 2.4.68 alike. Neither module has any quota code in it.
/// - **Finder's own WebDAV client never asks.** A volume mounted with `mount_webdav` sent sixteen
///   PROPFINDs naming no quota property, and `df` read the volume as zero bytes of zero. So the Mac
///   has no precedent to follow here.
///
/// Only the space left is kept, and the sentence is "available" with no total, unlike a volume's
/// "of": ``WebDAVProcessArguments/quotaPropfindBody`` gives the reason. The sidebar holds it as a
/// ``ServerSpace``, beside an SFTP server's, and asks on ``ServerSpace/isDue(lastAsked:now:)``.
public struct WebDAVQuota: Sendable, Equatable {
    /// Bytes the server will still store. Zero for an account at or past its quota: with 6 MB stored
    /// and the quota cut to 5 MB, Nextcloud answered `0`, not a negative, and a PUT then answered
    /// 507 (``WebDAVServiceError``).
    public let availableBytes: Int64

    public init(availableBytes: Int64) {
        self.availableBytes = availableBytes
    }

    /// What a quota request's answer says about the folder at `serverPath`, or `nil` when it says
    /// nothing: a body that is not a multistatus, which is what every refusal measured carries
    /// (Nextcloud's 401 is a sabre `<d:error>`), a property answered 404, or no number in it, which
    /// includes Nextcloud's `-3` for an account without a quota (``WebDAVResponse/quotaAvailableBytes``).
    ///
    /// The row is found as a listing finds its folder (``WebDAVMultistatus/listing(of:)``), so a
    /// reverse proxy that answers under another prefix still names it.
    public init?(_ response: WebDAVHTTPResponse, folder serverPath: String) {
        guard let multistatus = try? WebDAVMultistatusParser.parse(response.body),
              let listing = try? multistatus.listing(of: serverPath),
              let available = listing.folder.quotaAvailableBytes
        else { return nil }
        availableBytes = available
    }
}

public extension WebDAVBackend {
    /// The quota at this connection's root, or `nil` when the server reports none. One `Depth: 0`
    /// request.
    ///
    /// Throws only when no answer came, the transport's own failure. A refusal, a redirect and a
    /// 207 without the property are each an answer, and each means no quota to show.
    func quota() throws -> WebDAVQuota? {
        let response = try transport.propfindQuota("/")
        return WebDAVQuota(response, folder: location.serverPath(forBackendPath: "/"))
    }
}
