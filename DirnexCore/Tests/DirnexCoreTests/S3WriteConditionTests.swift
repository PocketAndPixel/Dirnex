import Foundation
import Testing

@testable import DirnexCore

/// Conditional writes — the precondition the *server* evaluates (PLAN.md §M21 Slice 17).
///
/// Three separable claims, and they fail in different places, which is why they are three groups
/// rather than one:
///
/// 1. **The header is spelled right and lands in the request.** Pure argument arithmetic, and the
///    only half a headless test can be certain about, since `curl`'s signing of it was settled by
///    probe (docs/NOTES.md ▸ curl for S3) and no test here spawns anything.
/// 2. **A refusal is read against what was asked.** The whole reason this is not a status map: a
///    412 means opposite things depending on the condition that produced it, and getting it
///    backwards tells a user their file was overwritten when it was not, or the reverse.
/// 3. **A condition can never be silently dropped.** The claim with the worst failure mode — a
///    caller believing a write was guarded when no precondition ever reached the wire.
@Suite("S3 conditional writes")
struct S3WriteConditionTests {
    private let location = S3Location(
        host: "s3.us-east-1.amazonaws.com",
        bucket: "1000genomes",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private var session: S3Session { S3Session(location: location) }

    private func backend(_ transport: FakeS3Transport) -> S3Backend {
        S3Backend(location: location, transport: transport)
    }

    private func path(_ value: String) -> VFSPath {
        VFSPath(backend: .s3(location), path: value)
    }

    private func failure(status: Int, code: String = "PreconditionFailed") -> S3ServiceError {
        S3ServiceError(
            status: status,
            code: code,
            message: "",
            correctEndpoint: nil,
            bucketRegion: nil
        )
    }

    // MARK: - 1. The header

    @Test("an unconditional write adds nothing at all")
    func unconditionalAddsNoHeader() {
        #expect(S3WriteCondition.unconditional.headerArguments.isEmpty)
        #expect(!S3WriteCondition.unconditional.isConditional)
    }

    @Test("create-if-absent is If-None-Match: *")
    func ifAbsentHeader() {
        #expect(S3WriteCondition.ifAbsent.headerArguments == ["-H", "If-None-Match: *"])
        #expect(S3WriteCondition.ifAbsent.isConditional)
    }

    /// The quoting is the measured finding and the one worth a test of its own: probed against the
    /// SigV4-verifying endpoint, an *unquoted* digest is a different byte string and does not
    /// match, so a well-meaning `trimmingCharacters(in: .init(charactersIn: "\""))` anywhere on
    /// this path turns every conditional save into a 412 — which reads as "somebody else changed
    /// this file", on every save, forever. `S3ListingParser` keeps the quotes; this pins that
    /// nothing between it and the wire takes them off again.
    @Test("an entity tag reaches the header exactly as the listing gave it, quotes included")
    func ifMatchesPassesTheTagVerbatim() {
        let tag = "\"f0c3ee288b98a8b9f7f87b43f6ea0772\""
        let condition = S3WriteCondition.ifMatches(entityTag: tag)
        #expect(
            condition.headerArguments == ["-H", "If-Match: \"f0c3ee288b98a8b9f7f87b43f6ea0772\""]
        )
        // The multipart spelling carries a part count after a hyphen and is just as opaque.
        let multipart = S3WriteCondition.ifMatches(entityTag: "\"abc-5\"")
        #expect(multipart.headerArguments == ["-H", "If-Match: \"abc-5\""])
    }

    @Test("the upload keeps its -T shape and gains only the header")
    func uploadArgumentsCarryTheCondition() {
        let plain = S3ProcessArguments.upload(session: session, key: "a/b.txt", localPath: "/tmp/x")
        let guarded = S3ProcessArguments.upload(
            session: session,
            key: "a/b.txt",
            localPath: "/tmp/x",
            condition: .ifMatches(entityTag: "\"t\"")
        )
        #expect(guarded.count == plain.count + 2)
        #expect(guarded.contains("If-Match: \"t\""))
        // The two facts the upload builder exists to protect, unchanged by the addition: the file
        // still streams with `-T`, and the destination URL still does not end in a slash (`curl`
        // appends the local basename to one that does).
        #expect(guarded.contains("--upload-file"))
        #expect(!(guarded.last ?? "").hasSuffix("/"))
        #expect(plain == S3ProcessArguments.upload(
            session: session,
            key: "a/b.txt",
            localPath: "/tmp/x",
            condition: .unconditional
        ))
    }

    @Test("the zero-byte write can carry one, and does not by default")
    func putEmptyObjectArguments() {
        let plain = S3ProcessArguments.putEmptyObject(session: session, key: "a/b.txt")
        #expect(!plain.contains(where: { $0.hasPrefix("If-") }))
        let guarded = S3ProcessArguments.putEmptyObject(
            session: session,
            key: "a/b.txt",
            condition: .ifAbsent
        )
        #expect(guarded.contains("If-None-Match: *"))
        // Still `--data-binary ""` rather than `-T /dev/null`: the measured reason is that the
        // latter goes out chunked with UNSIGNED-PAYLOAD, which S3 refuses.
        #expect(guarded.contains("--data-binary"))
    }

    // MARK: - 2. Reading the refusal

    @Test("a 412 means opposite things depending on what was asked")
    func refusalDependsOnTheCondition() {
        let precondition = failure(status: 412)
        #expect(S3WriteCondition.ifAbsent.refusal(for: precondition) == .alreadyThere)
        #expect(
            S3WriteCondition.ifMatches(entityTag: "\"t\"").refusal(for: precondition)
                == .changedSince
        )
        // The control that makes the pair mean something: with no condition sent, a 412 is not
        // this vocabulary's to interpret at all.
        #expect(S3WriteCondition.unconditional.refusal(for: precondition) == nil)
    }

    @Test("a 409 is the other spelling of an occupied key")
    func conflictReadsAsOccupied() {
        let conflict = failure(status: 409, code: "BucketAlreadyOwnedByYou")
        #expect(S3WriteCondition.ifAbsent.refusal(for: conflict) == .alreadyThere)
    }

    /// A 404 can only mean this on a conditional write: an unconditional PUT to a key that is not
    /// there *creates* it, so the status has no other way to arrive.
    @Test("If-Match against a deleted object is gone, not changed")
    func missingObjectIsItsOwnAnswer() {
        let missing = failure(status: 404, code: "NoSuchKey")
        #expect(
            S3WriteCondition.ifMatches(entityTag: "\"t\"").refusal(for: missing) == .goneSince
        )
        #expect(S3WriteCondition.ifAbsent.refusal(for: missing) == nil)
    }

    /// The narrowness control, and the one that matters most in use: a conditional upload can fail
    /// for every ordinary reason too, and reporting a permissions problem as a conflict sends the
    /// user hunting for an edit nobody made.
    @Test("a refusal the precondition did not cause travels on untouched")
    func unrelatedFailuresAreNotConflicts() {
        let denied = failure(status: 403, code: "AccessDenied")
        #expect(S3WriteCondition.ifAbsent.refusal(for: denied) == nil)
        #expect(S3WriteCondition.ifMatches(entityTag: "\"t\"").refusal(for: denied) == nil)
        let serverError = failure(status: 500, code: "InternalError")
        #expect(S3WriteCondition.ifMatches(entityTag: "\"t\"").refusal(for: serverError) == nil)
    }

    @Test("both refusals reach the user as a named sentence, never a raw errno")
    func refusalsAreNamedReasons() {
        let changed = VFSUnsupportedReason.remoteFileChangedSinceFetch(name: "notes.txt")
        let gone = VFSUnsupportedReason.remoteFileGoneSinceFetch(name: "notes.txt")
        #expect(changed.sentence.contains("notes.txt"))
        #expect(gone.sentence.contains("notes.txt"))
        #expect(changed.key == "remoteFileChangedSinceFetch")
        #expect(gone.key == "remoteFileGoneSinceFetch")
        // Both must be in `allCases`, or the localization coverage tests never see them and they
        // ship English inside a translated build.
        let keys = VFSUnsupportedReason.allCases.map(\.key)
        #expect(keys.contains("remoteFileChangedSinceFetch"))
        #expect(keys.contains("remoteFileGoneSinceFetch"))
    }

    // MARK: - 3. The condition cannot be dropped

    @Test("create-if-absent is what F7's empty file now asks for")
    func createFileIsConditional() throws {
        let transport = FakeS3Transport()
        transport.headResponse = S3Response(status: 404)
        try backend(transport).createFile(at: path("/notes.txt"))
        #expect(transport.writes == [.putEmpty("notes.txt")])
        #expect(transport.conditions == [.ifAbsent])
    }

    /// The narrowness control, and it is a real decision rather than an omission: a folder marker
    /// is idempotent by construction — the same zero bytes at the same key leave one object — so
    /// `.ifAbsent` there would turn the second F7 in the same place into an error about nothing.
    @Test("a folder marker stays unconditional")
    func createDirectoryIsNotConditional() throws {
        let transport = FakeS3Transport()
        try backend(transport).createDirectory(at: path("/docs"))
        #expect(transport.writes == [.putEmpty("docs/")])
        #expect(transport.conditions.isEmpty)
    }

    @Test("a refused create reads as already-exists, not as an I/O error")
    func refusedCreateIsAlreadyExists() {
        let transport = FakeS3Transport()
        transport.headResponse = S3Response(status: 404)
        transport.writeResponse = S3Response(
            status: 412,
            body: Data("<Error><Code>PreconditionFailed</Code></Error>".utf8)
        )
        #expect(throws: VFSError.alreadyExists(path("/notes.txt"))) {
            try backend(transport).createFile(at: path("/notes.txt"))
        }
    }

    @Test("a stale tag on a save reads as somebody else's edit")
    func staleTagIsAConflict() throws {
        let transport = FakeS3Transport()
        transport.writeResponse = S3Response(
            status: 412,
            body: Data("<Error><Code>PreconditionFailed</Code></Error>".utf8)
        )
        let file = try temporaryFile(bytes: 32)
        defer { try? FileManager.default.removeItem(atPath: file) }

        #expect {
            try backend(transport).upload(
                localPath: file,
                over: path("/notes.txt"),
                condition: .ifMatches(entityTag: "\"stale\""),
                progress: { _ in },
                isCancelled: { false }
            )
        } throws: { error in
            guard case let VFSError.unsupported(reason) = error else { return false }
            return reason.key == "remoteFileChangedSinceFetch"
        }
    }

    @Test("a guarded upload says it was guarded, and carries the tag to the transport")
    func conditionalUploadReportsItself() throws {
        let transport = FakeS3Transport()
        let file = try temporaryFile(bytes: 32)
        defer { try? FileManager.default.removeItem(atPath: file) }

        let result = try backend(transport).upload(
            localPath: file,
            over: path("/notes.txt"),
            condition: .ifMatches(entityTag: "\"abc\""),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(result.conditionWasSent)
        #expect(transport.conditions == [.ifMatches(entityTag: "\"abc\"")])
    }

    /// The honest half, and the reason ``S3ConditionalWrite`` exists rather than a `Void` return:
    /// a multipart upload cannot carry the precondition yet, and the caller has to be *told* that
    /// rather than left believing the write was guarded. A silent `false` here — or no return
    /// value at all — is the failure this whole slice is about, one layer up.
    @Test("a multipart upload reports that it carried no condition")
    func multipartSaysItIsUnguarded() throws {
        let transport = FakeS3Transport()
        let big = try temporaryFile(bytes: Int(S3MultipartLimits.multipartThreshold) + 1024)
        defer { try? FileManager.default.removeItem(atPath: big) }

        let result = try backend(transport).upload(
            localPath: big,
            over: path("/big.bin"),
            condition: .ifMatches(entityTag: "\"abc\""),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(!result.conditionWasSent)
        // And it really did go the multipart way rather than quietly becoming a single PUT that
        // dropped the header — which would pass the assertion above for the wrong reason.
        #expect(transport.writes.contains { if case .createMultipart = $0 { true } else { false } })
        #expect(transport.conditions.isEmpty)
    }

    /// The seam's own safety property. A transport written before conditional writes existed — or
    /// one somebody adds later — must fail loudly rather than write without the precondition it
    /// was handed, because a caller that believes it is protected and is not is strictly worse
    /// than one that knows it is not.
    @Test("a transport that cannot carry a condition refuses rather than dropping it")
    func defaultImplementationRefusesAConditional() throws {
        let transport = UnconditionalTransport()
        #expect(throws: S3WriteConditionUnsupported(key: "a.txt")) {
            try transport.putEmptyObject(key: "a.txt", condition: .ifAbsent)
        }
        #expect(throws: S3WriteConditionUnsupported(key: "a.txt")) {
            try transport.upload(
                localPath: "/tmp/x",
                to: "a.txt",
                condition: .ifMatches(entityTag: "\"t\""),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        // The other half of additive: asking for nothing still works, and reaches the verb that
        // was already there.
        _ = try transport.putEmptyObject(key: "a.txt", condition: .unconditional)
        #expect(transport.unconditionalCalls == 1)
    }

    private func temporaryFile(bytes: Int) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3-condition-\(UUID().uuidString)")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url.path
    }
}

/// A transport that implements only the unconditional verbs, so the protocol's default
/// implementations are the code under test.
///
/// It cannot be ``FakeS3Transport`` — that one implements the conditional verbs, which is exactly
/// what has to be *absent* here.
private final class UnconditionalTransport: S3Transport, @unchecked Sendable {
    var unconditionalCalls = 0

    func listObjects(
        prefix: String,
        delimiter: String?,
        continuationToken: String?
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func download(
        key: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func head(key: String) throws -> S3Response { S3Response(status: 200) }

    func upload(
        localPath: String,
        to key: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        unconditionalCalls += 1
        return S3Response(status: 200)
    }

    func putEmptyObject(key: String) throws -> S3Response {
        unconditionalCalls += 1
        return S3Response(status: 200)
    }

    func copyObject(from sourceKey: String, to destinationKey: String) throws -> S3Response {
        S3Response(status: 200)
    }

    func deleteObject(key: String) throws -> S3Response { S3Response(status: 200) }

    func deleteObjects(keys: [String]) throws -> S3Response { S3Response(status: 200) }

    func createMultipartUpload(key: String) throws -> S3Response { S3Response(status: 200) }

    func uploadPart(
        _ part: S3PartRequest,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [S3UploadedPart]
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func abortMultipartUpload(key: String, uploadID: String) throws -> S3Response {
        S3Response(status: 200)
    }
}
