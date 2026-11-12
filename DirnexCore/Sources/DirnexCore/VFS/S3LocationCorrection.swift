import Foundation

/// The two ways a connection to a bucket corrects itself without asking anyone (PLAN.md §M21), as
/// rules rather than as steps of the app's connect.
///
/// They were the app's alone while a connect was the only thing that reached a bucket. A search
/// across an account's buckets (PLAN.md §M38 Slice 5) reaches one bucket after another with no
/// connect in sight, and it meets the same two answers: a bucket in another region than the account,
/// and a bucket name one label too deep for the endpoint's certificate. So the rules moved here, and
/// both callers ask them, rather than the search growing a second spelling of each — this project's
/// most repeated finding (docs/NOTES.md ▸ Design lessons).
///
/// Each answers **one** step. Counting the steps is the caller's, because the caller is what knows
/// it already took one: a server that keeps redirecting would otherwise redirect forever.
public enum S3LocationCorrection {
    /// The connection to try instead after `service` refused one at `location`, or `nil` when the
    /// refusal is not one re-aiming can fix.
    ///
    /// Only the wrong-region redirect qualifies, and only when it names a region other than the one
    /// already used: addressing a bucket through the wrong region answers 301 naming the region that
    /// would have worked (probed 2026-08-12), and re-signing for the region the *service itself*
    /// named is not a trust decision.
    public static func afterRefusal(
        _ service: S3ServiceError,
        at location: S3Location
    ) -> S3Location? {
        guard service.isRegionRedirect,
              let region = service.correctedRegion,
              region != location.region
        else { return nil }
        return location.movingRegion(to: region)
    }

    /// The connection to try instead after a request to `location` failed below HTTP with `error`,
    /// or `nil` when re-addressing cannot fix it.
    ///
    /// Under virtual-host addressing the name TLS verifies is `<bucket>.<host>`, one label deeper
    /// than a wildcard certificate covers, so a valid publicly-issued certificate fails at `curl`
    /// exit 60 (measured 2026-08-13). Path-style still verifies, against the host the user typed, so
    /// nothing is traded away. Any other failure, or a connection already path-style, has nothing
    /// for this to correct.
    public static func afterTransportFailure(
        _ error: Error,
        at location: S3Location
    ) -> S3Location? {
        guard let responseError = error as? S3ResponseError,
              case .transport(.certificateNotTrusted) = responseError,
              location.addressing == .virtualHost
        else { return nil }
        return location.addressed(.path)
    }
}

public extension S3Location {
    /// The same connection signed for `region` — and, for an AWS endpoint, addressed at that
    /// region's host too.
    ///
    /// Both halves are needed and only one is obvious. AWS's 301 is a complaint about the *host*:
    /// re-signing for the right region while still addressing `s3.<wrong>.amazonaws.com` earns the
    /// same redirect again. An S3-compatible endpoint is left exactly where the user put it, since
    /// its host has no region in it to correct — rebuilding one from a region would point the
    /// request at an Amazon host the user never named.
    func movingRegion(to region: String) -> S3Location {
        let wasDerived = host == Self.awsHost(region: self.region)
        return S3Location(
            host: wasDerived ? Self.awsHost(region: region) : host,
            port: wasDerived ? nil : port,
            bucket: bucket,
            region: region,
            accessKeyID: accessKeyID,
            addressing: addressing,
            usesTLS: wasDerived ? true : usesTLS
        )
    }
}
