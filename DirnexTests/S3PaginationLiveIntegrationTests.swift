import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The page loop, and the token encoding under it, against **real Amazon S3** (PLAN.md §M21).
///
/// `S3Backend` lists a folder by asking for one page and following the `NextContinuationToken`
/// until the service stops handing one back, and the token it sends must be percent-encoded going
/// back. That rule has been in `S3ProcessArguments` since the first slice and had never run against
/// Amazon through the app's own path, because at the shipped page size of 1000 it takes a folder of
/// more than a thousand objects to reach a second page at all. `S3CurlTransport.pageSize` is what
/// makes it reachable over five — the same "a constant nothing hits makes its own rule untestable"
/// fork docs/NOTES.md records for M22's result cap.
///
/// **Every claim here is paired with its control**, because both halves fail quietly on their own:
/// a listing that silently stops at one page looks like a small folder, and a token that AWS
/// refuses reads as a *credentials* problem rather than as an encoding one — measured, a raw token
/// answers `403 SignatureDoesNotMatch`, not the `400 InvalidArgument` this project had recorded.
/// It is also **intermittent**: AWS mints a fresh token per request (40 requests at one page
/// boundary gave 40 distinct tokens), and only some of them carry a character that breaks the
/// signature, so the same folder lists correctly on one attempt and refuses on the next.
@Suite(
    "S3 pagination live integration",
    .serialized,
    .enabled(if: S3LiveEnvironment.current != nil)
)
struct S3PaginationLiveIntegrationTests {
    // MARK: - Fixtures

    /// The page size the two tests page at. Small on purpose: the loop, the real tokens and their
    /// encoding are what is under test, and none of them cares how many keys a page holds.
    private static let pageSize = 2
    private static let fixtureCount = 5

    private func backend(_ config: S3LiveEnvironment.Config, pageSize: Int) -> S3Backend {
        let location = config.account.bucketLocation(named: config.bucket)
        var transport = S3CurlTransport(
            location: location,
            secretAccessKey: config.secretAccessKey
        )
        transport.pageSize = pageSize
        return S3Backend(location: location, transport: transport)
    }

    /// A prefix per test run, so a run that dies half-way leaves something identifiable rather than
    /// colliding with the next one.
    private func probePrefix(_ label: String) -> String {
        "/dirnex-live-probe/pagination-\(label)-\(UUID().uuidString)"
    }

    private func names(_ count: Int) -> [String] {
        (1...count).map { String(format: "k%03d.txt", $0) }
    }

    /// Upload `fixtureCount` tiny objects under `folder` and hand back their remote paths.
    @discardableResult
    private func seed(
        _ folder: VFSPath,
        using backend: S3Backend
    ) throws -> [VFSPath] {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-pagination-\(UUID().uuidString).txt")
        try Data("hi\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        return try names(Self.fixtureCount).map { name in
            let remote = folder.appending(name)
            try backend.copyFile(
                at: .local(file.path),
                to: remote,
                progress: { _ in },
                isCancelled: { false }
            )
            return remote
        }
    }

    // MARK: - The loop

    @Test("a folder wider than one page lists whole, and a page holds what it was asked for")
    func multiPageFolderListsWhole() throws {
        let config = try #require(S3LiveEnvironment.current)
        let paged = backend(config, pageSize: Self.pageSize)
        let folder = VFSPath(backend: paged.id, path: probePrefix("whole"))

        let seeded = try seed(folder, using: paged)
        defer { for remote in seeded { try? paged.removeItem(at: remote) } }

        let entries = try paged.listDirectory(at: folder)
        let listed = entries.map(\.name).sorted()
        #expect(listed == names(Self.fixtureCount), "the paged listing lost or repeated a row")
        #expect(Set(listed).count == listed.count, "a row arrived twice")
        #expect(entries.allSatisfy { $0.byteSize == 3 })

        // The control that says the pages were real. A page size larger than the folder needs no
        // continuation token at all, so if it agrees with the run above, the loop above genuinely
        // walked three pages rather than one wide one — and if the token had been dropped, this is
        // the reading that would still have been right.
        let whole = backend(config, pageSize: 1000)
        let inOneGo = try whole.listDirectory(at: folder).map(\.name).sorted()
        #expect(inOneGo == listed, "one page and three pages disagree about the same folder")
    }

    // MARK: - The encoding under it

    @Test("the continuation token is refused unless it is encoded going back")
    func rawContinuationTokenIsRefused() throws {
        let config = try #require(S3LiveEnvironment.current)
        let location = config.account.bucketLocation(named: config.bucket)
        let paged = backend(config, pageSize: Self.pageSize)
        let folder = VFSPath(backend: paged.id, path: probePrefix("token"))

        let seeded = try seed(folder, using: paged)
        defer { for remote in seeded { try? paged.removeItem(at: remote) } }

        // Ask for the first page the way the app does, and take the token AWS hands back.
        let session = S3Session(location: location, maxTime: 30)
        let prefix = S3Key.listingPrefix(for: folder)
        let runner = S3CurlRunner(
            accessKeyID: location.accessKeyID,
            secretAccessKey: config.secretAccessKey
        )
        let first = try runner.perform(S3ProcessArguments.list(
            session: session,
            prefix: prefix,
            maxKeys: Self.pageSize
        ))
        #expect(first.status == 200)
        let page = try S3ListingParser.parse(first.body)
        #expect(page.isTruncated, "the fixture fits one page, so nothing here is about paging")
        let token = try #require(page.nextContinuationToken, "AWS handed back no token to page with")

        // The request the app makes, with its token encoded — the half that must succeed, or the
        // refusal below would be evidence about our credentials rather than about the encoding.
        let arguments = S3ProcessArguments.list(
            session: session,
            prefix: prefix,
            continuationToken: token,
            maxKeys: Self.pageSize
        )
        let encoded = try runner.perform(arguments)
        #expect(encoded.status == 200, "AWS refused the token the app actually sends")
        let secondPage = try S3ListingParser.parse(encoded.body)
        #expect(!secondPage.objects.isEmpty, "the second page came back empty")

        // The identical request with exactly one substitution: the token unencoded. Measured
        // 2026-08-18, AWS answers 403 `SignatureDoesNotMatch` — `curl` signs the query as written
        // and the service re-derives it, so a token carrying `+` or `=` makes the two disagree.
        // Note what that does to the diagnosis: a *pagination* bug arrives wearing the sentence for
        // a bad key, on a folder that lists fine on the next attempt.
        let raw = arguments.map {
            $0.replacingOccurrences(of: S3Key.encodedForQuery(token), with: token)
        }
        #expect(raw != arguments, "the token needed no encoding, so this run proves nothing")
        let refused = try runner.perform(raw)
        #expect(refused.status == 403, "AWS accepted a raw continuation token")
        let error = S3ServiceError.parse(refused.body, status: refused.status)
        #expect(error.code == "SignatureDoesNotMatch")
        #expect(error.isCredentialFailure, "the refusal does not read as a credential failure")
    }
}
