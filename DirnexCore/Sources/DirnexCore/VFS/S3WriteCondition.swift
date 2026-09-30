import Foundation

/// A precondition attached to a write, so the server decides whether it may land instead of the
/// client deciding a moment earlier and hoping (PLAN.md §M21 Slice 17).
///
/// Two races this closes, and they are the two the write half shipped with stated in prose:
///
/// - **`createFile` checks with a `stat` and then writes**, and ``S3Backend/createFile(at:)``'s own
///   doc comment said the gap between them was "unavoidable and accepted" because S3 had no
///   create-if-absent. That stopped being true — `If-None-Match: *` is the conditional PUT — and a
///   limitation stated in prose is a feature request with a date on it.
/// - **A save-back re-`stat`s and then uploads.** ``RemoteFileRevision`` turns "somebody else wrote
///   this" into a question the user answers, which is the important half and is unchanged; what it
///   cannot cover is the window *after* the answer, where the whole point is that a whole-object
///   PUT has nothing standing behind it.
///
/// ## What is measured, and what is not
///
/// Probed 2026-08-16 against an endpoint that recomputes SigV4 by hand, driven the way the app
/// drives it (`-K -` on stdin, `--aws-sigv4`, `-T`):
///
/// - **`curl` signs both headers and needs nothing new to do it.** They arrive in `SignedHeaders`
///   as `host;if-match;x-amz-content-sha256;x-amz-date`, and the signature verified against a
///   hand-recomputed SigV4 every time — with a wrong-secret control refused in the same run, which
///   is what makes the pass evidence rather than a permissive server agreeing. Same finding as
///   `x-amz-copy-source` and `Content-MD5` (docs/NOTES.md ▸ curl for S3): the header is ours to
///   spell, the signing is not ours to write.
/// - **A doomed conditional PUT costs nothing.** `curl` sends `Expect: 100-continue` above ~1 KiB,
///   and a server answering the precondition there ends it before the body moves: measured, a
///   64 MiB upload against a stale tag reported `size_upload=0` in **0.0009 s**. That is a second
///   reason for a header ``S3ProcessArguments/upload(session:key:localPath:condition:)`` already
///   keeps for the 403 case, and it is what makes conditioning a *large* save-back free.
/// - **What is NOT measured is whether a given server honours any of it.** The endpoint above is
///   ours, so its 412s are our own code answering; only AWS and a real S3-compatible account can
///   say what they do. That is why this is built as protection that is **strictly additive** —
///   see ``S3WriteConditionUnsupported``.
public enum S3WriteCondition: Sendable, Equatable {
    /// Write regardless of what is there. What every existing call site does and goes on doing.
    case unconditional

    /// Write only if nothing is at this key — `If-None-Match: *`.
    case ifAbsent

    /// Write only if the object still carries this entity tag — `If-Match: <tag>`.
    ///
    /// The tag is passed through **exactly as the listing gave it**, quotes included, and that is
    /// load-bearing rather than tidy: measured on the same run, an unquoted digest is a different
    /// byte string and does not match, so stripping the quotes turns every conditional write into
    /// a 412. That failure is the quiet direction twice over — a 412 reads as *"somebody else
    /// changed this file"*, so the app would confidently report a conflict that never happened, on
    /// every save. ``S3ListingParser`` already keeps the quotes for exactly this reason
    /// (PLAN.md §M21 Slice 10, the ETag producer), so the value arrives in the right shape and the
    /// rule here is to leave it alone.
    case ifMatches(entityTag: String)

    /// The header arguments this condition adds to a `curl` invocation, or none.
    public var headerArguments: [String] {
        switch self {
        case .unconditional:
            return []
        case .ifAbsent:
            return ["-H", "If-None-Match: *"]
        case let .ifMatches(entityTag):
            return ["-H", "If-Match: \(entityTag)"]
        }
    }

    /// Whether this condition asks the server for anything at all.
    ///
    /// Read by the transport seam rather than by comparing against `.unconditional` at each call
    /// site, so a condition added later is covered by whatever already asks this.
    public var isConditional: Bool { self != .unconditional }
}

/// Why a precondition refused a write.
///
/// Separate from ``S3ServiceError/vfsError(for:)`` on purpose: that maps a status with no idea what
/// was asked, and here the *same* status means opposite things. A 412 against `.ifAbsent` is "there
/// is already a file here"; against `.ifMatches` it is "somebody else has written this since you
/// downloaded it" — one is `alreadyExists`, the other is a sentence about a conflict, and nothing
/// in the response separates them.
///
/// There is deliberately no `.wrote` case. This type is only ever produced by reading a *failed*
/// response, so a success case here would be unconstructible in practice and would invite a
/// `switch` arm nobody can reach; success is the absence of one of these.
public enum S3WriteConditionRefusal: Sendable, Equatable {
    /// The key was already occupied, refusing an `.ifAbsent` write.
    case alreadyThere
    /// The object has changed since the tag was read, refusing an `.ifMatches` write.
    case changedSince
    /// `.ifMatches` against a key that is no longer there at all — the object was deleted rather
    /// than rewritten. Worth its own case because the sentence differs: there is nothing to
    /// compare against and nothing to merge with.
    case goneSince
}

public extension S3WriteCondition {
    /// The HTTP status a refused precondition carries.
    ///
    /// RFC 9110's own code, and it is what both AWS and the probe endpoint answer. Named rather
    /// than spelled inline because ``S3ServiceError/vfsError(for:)`` maps everything it does not
    /// recognize onto `.io(code: EIO)` — "The system reported an error (code 5)" — which is the raw
    /// errno shape this milestone has already had to name once, for `EXDEV` on a folder rename.
    static let preconditionFailedStatus = 412

    /// The `<Code>` a refused precondition carries, which on one verb is the **only** readable
    /// signal there is (PLAN.md §M21 Slice 19).
    ///
    /// A `CompleteMultipartUpload` may answer **200 with an `<Error>` document**: AWS begins the
    /// response before it has finished assembling, so a late failure arrives under a status the
    /// service already committed to. Measured on the probe endpoint driven into that shape — the
    /// identical refusal came back `HTTP=200` carrying `<Code>PreconditionFailed</Code>` — which is
    /// exactly the "two shapes rather than one" Slice 17 named as the reason to park the multipart
    /// half. A status-only reading answers `nil` there, so the write reports as *successful* and
    /// the object silently does not exist: the quiet direction, on the one request whose entire job
    /// is to say the file arrived.
    static let preconditionFailedCode = "PreconditionFailed"

    /// Read a failed request against what this condition asked for.
    ///
    /// Answers `nil` when the failure has nothing to do with the precondition, which is the common
    /// case and must stay distinguishable: a 403 on a conditional upload is still a permissions
    /// problem, and reporting it as a conflict would send the user to look for an edit nobody made.
    ///
    /// **The status and the code are both read, and neither is redundant.** Every verb but one
    /// refuses with a status; the completion above may refuse with only a code. The two are read as
    /// alternatives rather than as a pair for that reason — requiring both would make a refusal
    /// unreadable on whichever half a given server omits, and requiring the status alone is what
    /// this slice's probe measured as unreadable.
    func refusal(for error: S3ServiceError) -> S3WriteConditionRefusal? {
        switch self {
        case .unconditional:
            return nil
        case .ifAbsent:
            // 409 is included because a server may answer either: the probe endpoint and AWS say
            // 412, and 409 is S3's own "this already exists" elsewhere in the vocabulary. Both mean
            // the same thing here, and the reason `.ifAbsent` exists is to make that mean something
            // rather than to distinguish two spellings of it.
            guard error.status == Self.preconditionFailedStatus
                || error.status == 409
                || error.code == Self.preconditionFailedCode else {
                return nil
            }
            return .alreadyThere
        case .ifMatches:
            if error.status == Self.preconditionFailedStatus { return .changedSince }
            if error.code == Self.preconditionFailedCode { return .changedSince }
            // A 404 is only ever *this* on a conditional write: an unconditional PUT to a key that
            // does not exist creates it, so the status cannot arrive for any other reason. The
            // code-only twin is the inferred half rather than the measured one — a refusal
            // committed to a 200 was measured only for `PreconditionFailed`, and nothing names what
            // a deleted key answers there — but it is the same reading applied to the same shape,
            // and its cost when wrong is a sentence rather than a lost write.
            if error.status == 404 || error.code == "NoSuchKey" { return .goneSince }
            return nil
        }
    }
}

/// Whether a transport can carry a condition to the server.
///
/// The point of this type is that the protection is **strictly additive**, and saying so is not a
/// disclaimer — it is what decides the design. A server that ignores `If-Match` answers 200 and
/// overwrites, which is indistinguishable from having honoured it, so no client can tell whether it
/// is protected. Two consequences follow and both are load-bearing:
///
/// - **Nothing the user reads may claim the write was guarded.** The conflict sentence a save-back
///   shows goes on resting on ``RemoteFileRevision``'s re-`stat`, which works on every server and
///   in every direction. The condition closes the window *after* that check on servers that honour
///   it, and on servers that do not the app is exactly where it was before this slice — never
///   worse, and never claiming more.
/// - **A transport that cannot carry one must say so loudly rather than dropping it.** The default
///   implementation of the conditional verbs throws ``S3WriteConditionUnsupported`` instead of
///   quietly writing unconditionally, because a silently-dropped precondition is the failure this
///   whole slice exists to prevent, one layer lower. It is unreachable in the shipped app —
///   `S3CurlTransport` implements them — and it is exactly what a fake in a test, or a transport
///   somebody adds later, will hit first.
public struct S3WriteConditionUnsupported: Error, Sendable, Equatable {
    public let key: String

    public init(key: String) {
        self.key = key
    }
}
