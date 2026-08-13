import DirnexCore
import Foundation

/// Asks an S3 account which buckets its key can see, for the connect sheet's bucket picker
/// (PLAN.md §M21 Slice 7).
///
/// It is deliberately **not** an `S3Transport`: that protocol is a connection to one bucket, and
/// this request exists precisely because the bucket is the thing not yet known. It shares the
/// process plumbing through ``S3CurlRunner`` and the page loop through `S3BucketEnumeration`, so
/// what is left here is one call.
///
/// It runs **off the main thread** and therefore names no strings. Every outcome is a reason the
/// picker turns into a sentence, which is the rule docs/NOTES.md states for the core — a layer that
/// authors words is a layer whose words nobody can translate — and here it is also what makes the
/// type usable at all: `ConnectText` is `@MainActor`.
enum S3BucketLister {
    /// What asking an account for its buckets can come back with.
    ///
    /// The split between the last two is the measurement this feature rests on: probed 2026-08-13,
    /// a key without `s3:ListAllMyBuckets` and a key with a **wrong secret** both answer HTTP 403,
    /// and only the `<Code>` element separates `AccessDenied` from `SignatureDoesNotMatch`. That is
    /// the inverted-classifier rule this backend is built on, arriving at one more site — and it
    /// decides who is told they have a problem.
    enum Outcome: Equatable {
        /// The account answered with its buckets. Possibly none, which is an answer and not a
        /// failure: an account with no buckets is a thing that exists, and the picker says so.
        case buckets([S3Bucket])
        /// The key authenticated and is not allowed to list buckets.
        ///
        /// **The ordinary case, and it must not read as a failure.** A key scoped to one bucket is
        /// how these are normally issued — it is the very reason PLAN.md declined to make the
        /// account the *root* — so a user whose credentials are set up properly has done nothing
        /// wrong and must not be shown an error for it. It is still *said*, because the picker is
        /// reached by an explicit click and a gesture that answers with nothing is the no-op that
        /// looks like it worked; what it says names the way forward (type the bucket), which is
        /// what the form did before this existed and still does.
        case notPermitted
        /// The credentials themselves were refused. Worth reporting, and worth reporting *here*,
        /// because it is not specific to listing: Connect is about to fail the same way, so saying
        /// it now saves the user a round trip they would otherwise make blind.
        case badCredentials
        /// Nothing usable came back — the endpoint is unreachable, or answered with something that
        /// is neither a bucket list nor an S3 error document (a proxy's HTML, a captive portal).
        case unreachable
    }

    /// One account-level `ListAllMyBuckets`, walked to the end. Blocks on the network; call it off
    /// the main thread.
    static func buckets(for account: S3Account, secretAccessKey: String) -> Outcome {
        let runner = S3CurlRunner(
            accessKeyID: account.accessKeyID,
            secretAccessKey: secretAccessKey
        )
        do {
            let buckets = try S3BucketEnumeration.allBuckets { token in
                let arguments = S3ProcessArguments.listBuckets(
                    account: account,
                    continuationToken: token
                )
                let response = try runner.perform(arguments)
                guard response.isSuccess else {
                    throw S3ResponseError.service(
                        S3ServiceError.parse(
                            response.body,
                            status: response.status,
                            bucketRegion: response.bucketRegion
                        )
                    )
                }
                return try S3BucketListParser.parse(response.body)
            }
            return .buckets(buckets)
        } catch let S3ResponseError.service(error) {
            return classify(error)
        } catch {
            return .unreachable
        }
    }

    /// Which of the three refusals a server's answer is. Split out so it is reachable from a test
    /// with a hand-made `S3ServiceError`, since the two 403s are the whole point and neither is
    /// producible without a server.
    static func classify(_ error: S3ServiceError) -> Outcome {
        if error.isCredentialFailure { return .badCredentials }
        // 403 with any other code — `AccessDenied` above all — is the permission answer. Keyed on
        // the status as well as the code so a server refusing with its own vocabulary still lands
        // here rather than in an alarming sentence about credentials that are fine.
        if error.status == 403 { return .notPermitted }
        return .unreachable
    }
}
