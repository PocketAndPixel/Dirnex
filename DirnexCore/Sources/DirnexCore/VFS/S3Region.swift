import Foundation

/// What an S3 connection's region is when the user did not state one.
///
/// **An empty region is a real answer**, not a missing field, and it is the honest one for most of
/// the servers this backend exists to reach: measured 2026-08-13 against a real S3-compatible
/// endpoint, `us-east-1`, `lax`, `default` and `us-west-1` all signed and verified against the same
/// bucket, and it sent `x-amz-bucket-region` on no response at all. Its regions are fiction. Storing
/// `us-east-1` for such a server writes a fact the app does not know into the record, the sidebar
/// tooltip and the connect sheet — where the user, who deliberately cleared the field, meets it
/// again on the next edit and reasonably concludes the app ignored them (reported 2026-08-14).
///
/// Two places will not take the blank, and neither is a matter of taste:
///
/// - **SigV4 always names a region** in its credential scope, so a request needs *some* string.
///   ``signing(_:)`` is that string, applied at the moment of signing and never stored.
/// - **Amazon derives the host from the region** (`s3.<region>.amazonaws.com`), where an empty one
///   builds `s3..amazonaws.com` — not a wrong server but no server. The connect form therefore
///   resolves a blank field to ``fallback`` for the Amazon service *only*, since an S3-compatible
///   endpoint is typed in full and needs nothing derived.
///
/// So the split is: blank is preserved everywhere it is *recorded*, and resolved everywhere it is
/// *used*. One definition of the fallback, because a second spelling is how the signature and the
/// host would come to disagree about which region this connection is.
public enum S3Region {
    /// The region assumed when none was stated. AWS's own default, and what an S3-compatible server
    /// with no regions is usually configured with.
    public static let fallback = "us-east-1"

    /// The region to sign `region` with — itself, or ``fallback`` when it is unstated.
    public static func signing(_ region: String) -> String {
        region.isEmpty ? fallback : region
    }

    /// Whether `region` is one the service is being *told*, rather than one this app supplied.
    ///
    /// Read by everything that displays a region: an unstated one has nothing to show, and drawing
    /// the fallback there is exactly the claim this type exists to stop making.
    public static func isStated(_ region: String) -> Bool { !region.isEmpty }
}
