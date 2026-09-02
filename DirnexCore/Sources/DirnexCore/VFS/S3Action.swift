import Foundation

/// The IAM action behind one S3 request, so a refusal can name the permission that is missing.
///
/// It exists because `403 AccessDenied` is otherwise the least actionable answer this backend can
/// give: the shared mapping turns it into `permissionDenied`, whose sentence is "the server refused
/// that, this account may not have permission for it" — true, hedged, and silent about *which*
/// permission, which is the one thing the user has to know to fix it. Measured against real AWS
/// 2026-09-02 on a key scoped to one bucket: `CreateBucket` came back
/// *"not authorized to perform: s3:CreateBucket … because no identity-based policy allows the
/// s3:CreateBucket action"*, three different names refused identically, while the byte-identical
/// request for the one name that account's policy does grant answered **200**. So the refusal is
/// exactly a missing action, and the account holder can act on its name and on nothing else.
///
/// **Named by the caller, never scraped from the response.** AWS's message says the action outright
/// and is still the wrong source: it is the remote's English, in a language nobody chose (the rule
/// ``S3ServiceError/message`` already states), and an S3-compatible endpoint need not phrase it that
/// way — or at all. The request's own verb is known here, on this machine, before it is sent.
///
/// **These are IAM actions, not REST verbs, and the two do not correspond one-to-one.** There is no
/// `s3:HeadBucket` or `s3:HeadObject`: `HeadBucket` and `ListObjectsV2` are both authorized by
/// `s3:ListBucket`, and `HeadObject` by `s3:GetObject`. Naming the verb instead would hand the user
/// a token that does not exist to paste into a policy, which is worse than naming nothing.
public enum S3Action: String, Sendable, Equatable, CaseIterable {
    /// `CreateBucket`.
    case createBucket = "s3:CreateBucket"
    /// `DeleteBucket`.
    case deleteBucket = "s3:DeleteBucket"
    /// `ListAllMyBuckets` — the account's own bucket list, which a bucket-scoped key cannot ask for.
    case listAllMyBuckets = "s3:ListAllMyBuckets"
    /// `ListObjectsV2` **and** `HeadBucket`; there is no separate head permission.
    case listBucket = "s3:ListBucket"
    /// `GetObject` and `HeadObject`, including the source half of a server-side `CopyObject`.
    case getObject = "s3:GetObject"
    /// `PutObject`, every multipart request, and the destination half of a `CopyObject`.
    case putObject = "s3:PutObject"
    /// `DeleteObject` and `DeleteObjects`.
    case deleteObject = "s3:DeleteObject"

    /// The token as an IAM policy spells it — the value shown to the user and pasted into a policy.
    public var iamName: String { rawValue }
}
