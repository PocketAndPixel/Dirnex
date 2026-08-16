import Foundation

/// Uploading an object **only if the server still holds the version we started from**
/// (PLAN.md §M21 Slice 17).
///
/// This is the write half of ``RemoteFileRevision``. That type turns "somebody else has written
/// this" into a question the user answers, which is the important protection and is unchanged; what
/// it cannot cover is the window *after* the answer — a re-`stat` and then a whole-object PUT with
/// nothing standing behind it. `If-Match` hands that last step to the server.
///
/// Deliberately **not** folded into `copyFile`. That verb is the queue's, and its contract is
/// "move these bytes there"; a save-back is a different act with a different failure — it can be
/// *refused for a reason the user has to read*, where a copy that fails is a copy that failed.
/// Giving `copyFile` a condition parameter would put that vocabulary in front of every F5 as well,
/// which is the shape this project keeps naming: one question, several spellings.
public extension S3Backend {
    /// Upload `localPath` over `destination`, only if the precondition still holds.
    ///
    /// **The single-`PUT` path carries the condition and the multipart path does not**, and the
    /// return value is what says which happened rather than a comment nobody reads at the call
    /// site. A silently-unconditional write is exactly the failure this slice exists to remove, so
    /// it is not available: the caller is told, and can word what it shows accordingly.
    ///
    /// The multipart half is left for its own pass rather than guessed at. `If-Match` on
    /// `CompleteMultipartUpload` is what AWS documents, and `curl` would sign it as readily as it
    /// signs this one — but a completion can already fail *inside a 200*
    /// (``S3MultipartDocument/completionFailure(from:status:)``), so a refusal there has two
    /// shapes to read rather than one, and none of it is measurable against an endpoint that is
    /// ours. Naming it beats shipping an unmeasured branch on the path where a wrong answer costs
    /// somebody a large upload.
    @discardableResult
    func upload(
        localPath: String,
        over destination: VFSPath,
        condition: S3WriteCondition,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3ConditionalWrite {
        try requireOwnBackend(destination)
        let key = S3Key.key(for: destination)
        guard !key.isEmpty else { throw VFSError.unsupported(.copyFile) }
        if isCancelled() { throw CancellationError() }

        let size = localFileSize(localPath)
        guard !S3MultipartPlan.isWorthwhile(totalSize: size) else {
            try uploadObject(
                localPath: localPath,
                key: key,
                at: destination,
                progress: progress,
                isCancelled: isCancelled
            )
            return S3ConditionalWrite(conditionWasSent: false)
        }

        var streamed: Int64 = 0
        let response = try conditionallyWrite(at: destination, condition: condition) {
            try transport.upload(
                localPath: localPath,
                to: key,
                condition: condition,
                progress: { delta in
                    streamed += delta
                    progress(delta)
                },
                isCancelled: isCancelled
            )
        }
        if isCancelled() { throw CancellationError() }
        reportRemainder(of: response.bytesTransferred, streamed: streamed, to: progress)
        return S3ConditionalWrite(conditionWasSent: condition.isConditional)
    }
}

/// What a conditional write actually did — specifically, whether the precondition travelled with
/// it.
///
/// A `Bool` in a named box rather than a bare one, because the question it answers is easy to read
/// backwards at a call site (`true` = guarded, not `true` = refused) and because the honest caveat
/// belongs on the type: **`conditionWasSent` is a claim about this client, never about the
/// server.** A store that ignores `If-Match` answers 200 and overwrites, which is indistinguishable
/// from having honoured it, so nothing downstream may promise the user that a write was guarded —
/// only that it was *asked* to be. The protection the app shows a sentence for goes on resting on
/// ``RemoteFileRevision``'s re-`stat`, which works everywhere.
public struct S3ConditionalWrite: Sendable, Equatable {
    /// Whether a precondition was attached to the request that moved the bytes.
    ///
    /// `false` for an unconditional caller, and `false` for a multipart upload, which cannot carry
    /// one yet. The second is the reason this exists.
    public let conditionWasSent: Bool

    public init(conditionWasSent: Bool) {
        self.conditionWasSent = conditionWasSent
    }
}
