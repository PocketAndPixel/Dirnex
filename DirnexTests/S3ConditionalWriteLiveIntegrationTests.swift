import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The conditional write, refused by **real Amazon S3** (PLAN.md §M21 Slices 17–19).
///
/// Slices 17 and 19 measured everything a client can measure on its own: the header travels, `curl`
/// signs it on both verbs, the quotes survive, and a doomed conditional `PUT` ends at the `Expect`
/// before the body moves. What none of it could answer is the one question
/// ``S3WriteConditionUnsupported`` names — *whether a given server honours any of it* — because a
/// store that ignores `If-Match` answers 200 and overwrites, which is indistinguishable from having
/// obeyed. Only the service can say, and until this suite nothing had asked Amazon.
///
/// **No race is needed to ask, which is what makes the suite possible at all.** PLAN.md carried the
/// remaining step as "arranging the race", and a race is not what a 412 rests on: the precondition
/// is a *stale tag*, a value, and staleness is arrangeable in a straight line. The window in
/// production sits between ``RemoteFileRevision``'s re-`stat` and the PUT; what that window
/// *produces* is an object whose tag is no longer the one we hold, and a second sequential write
/// produces exactly that state. The other writer collapses into the test.
///
/// **Every refusal here is paired with the write that must succeed**, and that pairing is the whole
/// evidence rather than a courtesy. docs/NOTES.md records that an *unquoted but otherwise correct*
/// tag is refused with the identical 412 — so "stale tag → refused" passes just as well against a
/// client whose tags AWS can never match, i.e. against a build in which every save-back is refused.
/// The control separates "AWS honours `If-Match`" from "we send something AWS cannot match", and
/// only one of those is the claim being made.
@Suite(
    "S3 conditional write live integration",
    .serialized,
    .enabled(if: S3LiveEnvironment.current != nil)
)
struct S3ConditionalWriteLiveIntegrationTests {
    // MARK: - Fixtures

    private func backend(_ config: S3LiveEnvironment.Config) -> S3Backend {
        let location = config.account.bucketLocation(named: config.bucket)
        return S3Backend(
            location: location,
            transport: S3CurlTransport(location: location, secretAccessKey: config.secretAccessKey)
        )
    }

    private func transport(_ config: S3LiveEnvironment.Config) -> S3CurlTransport {
        let location = config.account.bucketLocation(named: config.bucket)
        return S3CurlTransport(location: location, secretAccessKey: config.secretAccessKey)
    }

    /// A unique key per test, under one prefix, so a failed run leaves something identifiable
    /// rather than colliding with the next.
    private func probeKey(_ label: String) -> String {
        "/dirnex-live-probe/conditional-\(label)-\(UUID().uuidString).bin"
    }

    private func localFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-conditional-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// The tag as the listing gives it — quotes included, which is load-bearing all the way to the
    /// wire (``S3WriteCondition/ifMatches(entityTag:)``).
    private func entityTag(of remote: VFSPath, using backend: S3Backend) throws -> String {
        let entry = try backend.stat(at: remote)
        return try #require(entry.entityTag, "the listing gave the object no ETag")
    }

    private func put(
        _ contents: String,
        at remote: VFSPath,
        using backend: S3Backend
    ) throws {
        let file = try localFile(contents)
        defer { try? FileManager.default.removeItem(at: file) }
        try backend.copyFile(
            at: .local(file.path),
            to: remote,
            progress: { _ in },
            isCancelled: { false }
        )
    }

    private func download(_ remote: VFSPath, using backend: S3Backend) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-conditional-back-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try backend.copyFile(
            at: remote,
            to: .local(url.path),
            progress: { _ in },
            isCancelled: { false }
        )
        let data = try Data(contentsOf: url)
        return try #require(String(bytes: data, encoding: .utf8), "the object is not UTF-8")
    }

    // MARK: - .ifMatches

    @Test("a stale entity tag is refused, and the tag AWS currently holds is not")
    func staleEntityTagIsRefused() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let config = try #require(S3LiveEnvironment.current)
            let backend = backend(config)
            let remote = VFSPath(backend: backend.id, path: probeKey("stale"))
            defer { try? backend.removeItem(at: remote) }

            try put("one", at: remote, using: backend)
            let first = try entityTag(of: remote, using: backend)

            // The control. A guarded write with the *current* tag must land, or every assertion below
            // is about our own quoting rather than about Amazon's answer.
            let second = try localFile("two")
            defer { try? FileManager.default.removeItem(at: second) }
            let guarded = try backend.upload(
                localPath: second.path,
                over: remote,
                condition: .ifMatches(entityTag: first),
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(guarded.conditionWasSent)
            let landed = try download(remote, using: backend)
            #expect(landed == "two", "a guarded write with the current tag did not land")

            let updated = try entityTag(of: remote, using: backend)
            #expect(
                updated != first,
                "the second write left the tag unchanged, so nothing is stale yet"
            )

            // The refusal: `first` is now a version AWS no longer holds. This is the state the race
            // produces, reached without one.
            let third = try localFile("three")
            defer { try? FileManager.default.removeItem(at: third) }
            var refusal: VFSError?
            do {
                _ = try backend.upload(
                    localPath: third.path,
                    over: remote,
                    condition: .ifMatches(entityTag: first),
                    progress: { _ in },
                    isCancelled: { false }
                )
            } catch let error as VFSError {
                refusal = error
            }
            #expect(
                refusal == .unsupported(.remoteFileChangedSinceFetch(name: remote.lastComponent)),
                "real AWS did not refuse a stale If-Match: \(String(describing: refusal))"
            )

            // A refused write must not have written. The status says refused; the object says whether
            // that was true.
            let after = try download(remote, using: backend)
            #expect(after == "two", "the refused write changed the object anyway")
            let tagAfter = try entityTag(of: remote, using: backend)
            #expect(tagAfter == updated)
        }
    }

    @Test("a tag for an object that has since been deleted is refused as gone, not as changed")
    func deletedObjectIsRefusedAsGone() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let config = try #require(S3LiveEnvironment.current)
            let backend = backend(config)
            let remote = VFSPath(backend: backend.id, path: probeKey("gone"))
            defer { try? backend.removeItem(at: remote) }

            try put("one", at: remote, using: backend)
            let tag = try entityTag(of: remote, using: backend)
            try backend.removeItem(at: remote)

            let replacement = try localFile("two")
            defer { try? FileManager.default.removeItem(at: replacement) }
            var refusal: VFSError?
            do {
                _ = try backend.upload(
                    localPath: replacement.path,
                    over: remote,
                    condition: .ifMatches(entityTag: tag),
                    progress: { _ in },
                    isCancelled: { false }
                )
            } catch let error as VFSError {
                refusal = error
            }
            // The half ``S3WriteCondition/refusal(for:)`` calls inferred rather than measured: a 404 on
            // a conditional write can only be this, since an unconditional PUT to a missing key creates
            // it. The two cases are separate because the user's options differ — there is nothing to
            // merge with.
            #expect(
                refusal == .unsupported(.remoteFileGoneSinceFetch(name: remote.lastComponent)),
                "real AWS did not refuse a tag for a deleted key as gone: \(String(describing: refusal))"
            )

            let stat = try? backend.stat(at: remote)
            #expect(stat == nil, "the refused write re-created the object")
        }
    }

    // MARK: - .ifAbsent

    @Test("an occupied key refuses If-None-Match, and a free one accepts it")
    func occupiedKeyRefusesIfAbsent() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let config = try #require(S3LiveEnvironment.current)
            let backend = backend(config)
            let transport = transport(config)

            // This one has to go one level down, and that is the finding rather than a shortcut:
            // ``S3Backend/createFile(at:)`` does its own `stat` and throws `alreadyExists` *before* the
            // conditional PUT is ever sent, so the app's own path can never exercise the server's
            // `If-None-Match: *` at all.
            let free = VFSPath(backend: backend.id, path: probeKey("absent"))
            defer { try? backend.removeItem(at: free) }
            let key = S3Key.key(for: free)

            let created = try transport.putEmptyObject(key: key, condition: .ifAbsent)
            #expect(
                (200..<300).contains(created.status),
                "a guarded create on a free key was refused: \(created.status)"
            )

            let again = try transport.putEmptyObject(key: key, condition: .ifAbsent)
            #expect(
                !(200..<300).contains(again.status),
                "real AWS accepted If-None-Match: * on a key it already holds (status \(again.status))"
            )
            let service = try #require(
                S3Backend.serviceError(from: again),
                "a refused conditional create carried no readable error"
            )
            #expect(
                S3WriteCondition.ifAbsent.refusal(for: service) == .alreadyThere,
                "AWS refused with a shape the reader does not classify: \(service)"
            )
        }
    }

    // MARK: - The multipart completion

    @Test("a stale tag refuses the completion of a multipart upload, and publishes nothing")
    func staleTagRefusesMultipartCompletion() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let config = try #require(S3LiveEnvironment.current)
            let backend = backend(config)
            let remote = VFSPath(backend: backend.id, path: probeKey("multipart"))
            defer { try? backend.removeItem(at: remote) }

            // Two cheap writes make the tag stale; only the *refused* upload needs to cross the
            // threshold, so this costs one large transfer rather than two.
            try put("one", at: remote, using: backend)
            let first = try entityTag(of: remote, using: backend)
            try put("two", at: remote, using: backend)
            let current = try entityTag(of: remote, using: backend)
            #expect(current != first)

            let size = 70 * 1024 * 1024
            #expect(
                Int64(size) > S3MultipartLimits.multipartThreshold,
                "the probe must cross the threshold or it is not testing the completion"
            )
            let big = FileManager.default.temporaryDirectory
                .appendingPathComponent("dirnex-conditional-multipart-\(UUID().uuidString).bin")
            defer { try? FileManager.default.removeItem(at: big) }
            var bytes = Data(count: size)
            bytes.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                arc4random_buf(base, buffer.count)
            }
            try bytes.write(to: big)

            var refusal: VFSError?
            do {
                _ = try backend.upload(
                    localPath: big.path,
                    over: remote,
                    condition: .ifMatches(entityTag: first),
                    progress: { _ in },
                    isCancelled: { false }
                )
            } catch let error as VFSError {
                refusal = error
            }
            // The shape AWS uses is the open question here, not whether it refuses: a completion may
            // answer 412, or **200 carrying `<Code>PreconditionFailed</Code>`**, and the second reading
            // exists only because the probe endpoint could be driven into it. Both land on this one
            // error, which is what the two readings are for.
            #expect(
                refusal == .unsupported(.remoteFileChangedSinceFetch(name: remote.lastComponent)),
                "real AWS did not refuse a guarded completion: \(String(describing: refusal))"
            )

            let after = try download(remote, using: backend)
            #expect(after == "two", "a refused completion published the object anyway")
        }
    }
}
