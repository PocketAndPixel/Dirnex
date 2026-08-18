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

    @Test("a file over the threshold round-trips byte-identically through the real backend")
    func multipartRoundTrips() throws {
        let config = try #require(S3LiveEnvironment.current)
        #expect(Int64(Self.size) > S3MultipartLimits.multipartThreshold, "probe must cross it")
        let backend = backend(config)

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-multipart-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: source) }
        var bytes = Data(count: Self.size)
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

        let stat = try backend.stat(at: remote)
        #expect(stat.byteSize == Int64(Self.size))
        #expect(!reports.isEmpty, "a multipart upload reported nothing at all")
        #expect(reports.reduce(0, +) <= Int64(Self.size), "never more than the file")

        let back = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-multipart-back-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: back) }
        try backend.copyFile(
            at: remote,
            to: .local(back.path),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(
            try SHA256.hash(data: Data(contentsOf: back)) == sent,
            "round trip is not byte-exact"
        )
    }
}
