import CryptoKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A file over `S3MultipartLimits.multipartThreshold`, through the real backend, against real AWS.
///
/// Slices 5 and 8 verified multipart by throwaway harness against a local endpoint and one
/// S3-compatible account; no *kept* suite has ever crossed the threshold, and the progress suite's
/// ladder deliberately stops below it. So the rules this path rests on — a part's exact
/// `Content-Length` with no chunked framing, ETags quoted back verbatim in the manifest, and a
/// completion that can refuse inside a 200 — have never been answered by Amazon.
@Suite("S3 multipart live integration", .serialized, .enabled(if: S3LiveEnvironment.current != nil))
struct S3MultipartLiveIntegrationTests {
    private static let size = 70 * 1024 * 1024

    private func backend(_ config: S3LiveEnvironment.Config) -> S3Backend {
        let location = config.account.bucketLocation(named: config.bucket)
        return S3Backend(
            location: location,
            transport: S3CurlTransport(location: location, secretAccessKey: config.secretAccessKey)
        )
    }

    /// What one round trip measured, carried back out of the blocking closure below — hence
    /// `Sendable`, and hence the digests compared *inside* rather than the bytes handed out.
    private struct RoundTrip: Sendable {
        let storedSize: Int64
        let reports: [Int64]
        let isByteExact: Bool
    }

    /// The whole 140 MiB round trip, **off the cooperative pool**.
    ///
    /// `BlockingWork.run` for the reason its own doc comment gives, arriving in test code rather
    /// than in the product: a synchronous test body that blocks on `curl` holds one of the
    /// cooperative pool's workers — the pool being only as wide as the machine's core count — for
    /// the whole transfer, and this is the longest-blocking test in the project. Six live suites
    /// run at once, so between them they can empty the pool and starve every *other* suite's
    /// `await`, which is the shape docs/NOTES.md records for `FileOperationQueue`. Measured: the
    /// app suite under `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` was 16 s and green without the live
    /// suites and 86 s with 5 failures with them, none of them in the live tests themselves.
    private static func roundTrip(through backend: S3Backend) async throws -> RoundTrip {
        try await BlockingWork.run { () -> Result<RoundTrip, any Error> in
            Result {
                let source = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dirnex-multipart-\(UUID().uuidString).bin")
                defer { try? FileManager.default.removeItem(at: source) }
                var bytes = Data(count: size)
                bytes.withUnsafeMutableBytes { buffer in
                    guard let base = buffer.baseAddress else { return }
                    arc4random_buf(base, buffer.count)
                }
                try bytes.write(to: source)
                let sent = SHA256.hash(data: bytes)

                let remote = VFSPath(backend: backend.id, path: "/dirnex-live-probe/multipart.bin")
                var reports: [Int64] = []
                try backend.copyFile(
                    at: .local(source.path),
                    to: remote,
                    progress: { reports.append($0) },
                    isCancelled: { false }
                )
                defer { try? backend.removeItem(at: remote) }

                let stored = try backend.stat(at: remote).byteSize

                let back = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dirnex-multipart-back-\(UUID().uuidString).bin")
                defer { try? FileManager.default.removeItem(at: back) }
                try backend.copyFile(
                    at: remote,
                    to: .local(back.path),
                    progress: { _ in },
                    isCancelled: { false }
                )
                return RoundTrip(
                    storedSize: stored,
                    reports: reports,
                    isByteExact: try SHA256.hash(data: Data(contentsOf: back)) == sent
                )
            }
        }.get()
    }

    @Test("a file over the threshold round-trips byte-identically through the real backend")
    func multipartRoundTrips() async throws {
        let config = try #require(S3LiveEnvironment.current)
        #expect(Int64(Self.size) > S3MultipartLimits.multipartThreshold, "probe must cross it")

        let trip = try await Self.roundTrip(through: backend(config))

        #expect(trip.storedSize == Int64(Self.size))
        #expect(!trip.reports.isEmpty, "a multipart upload reported nothing at all")
        #expect(trip.reports.reduce(0, +) <= Int64(Self.size), "never more than the file")
        #expect(trip.isByteExact, "round trip is not byte-exact")
    }
}
