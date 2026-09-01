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
    /// **Both sizes carry the condition, since Slice 19.** It used to be the single-`PUT` path
    /// alone, with the multipart half named as parked rather than guessed at — a completion can
    /// fail *inside a 200* (``S3MultipartDocument/completionFailure(from:status:)``), so a refusal
    /// there has two shapes to read rather than one. Both shapes have now been measured against the
    /// endpoint that recomputes SigV4 by hand, and `curl` was measured signing the header on the
    /// completion's own canonical request, so the branch is no longer unmeasured.
    ///
    /// What the return value still says is worth keeping: `conditionWasSent` is a claim about this
    /// **client**, never about the server. It is `false` for an unconditional caller and for a
    /// transport that cannot carry one, and no server anywhere can be asked whether it honoured
    /// what it was sent (``S3WriteConditionUnsupported``).
    ///
    /// The size fork itself lives in ``S3Backend/uploadObject(localPath:key:at:condition:progress:isCancelled:)``
    /// and deliberately not here: the precondition rides on a different request either side of it,
    /// so choosing where to attach one is the same decision as choosing the path.
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

        try uploadObject(
            localPath: localPath,
            key: key,
            at: destination,
            condition: condition,
            progress: progress,
            isCancelled: isCancelled
        )
        if isCancelled() { throw CancellationError() }
        return S3ConditionalWrite(conditionWasSent: condition.isConditional)
    }
}

/// The routed spelling of the method above (PLAN.md §4 ▸ *Still open*, taken 2026-09-01).
///
/// One line, and it earns its place by being the *only* thing that lets the write-back job live in
/// the core: a queue runner holds `any VFSBackend` and cannot reach a concrete `S3Backend`, which
/// is what the app used to do with an `as? CompositeBackend` cast and a `conditionalWriter(for:)`
/// lookup. Everything the write actually does is still `upload(localPath:over:condition:…)`, so
/// there is no second implementation of a conditional PUT — only a second way in.
public extension S3Backend {
    @discardableResult
    func writeBack(
        localPath: String,
        to destination: VFSPath,
        condition: S3WriteCondition,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Bool {
        try upload(
            localPath: localPath,
            over: destination,
            condition: condition,
            progress: progress,
            isCancelled: isCancelled
        ).conditionWasSent
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
    /// Whether a precondition was attached to the request the object's existence hangs on.
    ///
    /// `false` for an unconditional caller, and `false` for a transport that cannot carry one at
    /// all — which is what the type exists to report, and it is now the *only* thing that makes it
    /// `false` for a caller who asked. It used to be `false` for every large file too, before the
    /// multipart completion learned to carry one (PLAN.md §M21 Slice 19).
    ///
    /// Note "the request the object's existence hangs on" rather than "the request that moved the
    /// bytes": a multipart upload's bytes are sent by requests that carry no condition, and the
    /// completion that publishes them is the one that does.
    public let conditionWasSent: Bool

    public init(conditionWasSent: Bool) {
        self.conditionWasSent = conditionWasSent
    }
}
