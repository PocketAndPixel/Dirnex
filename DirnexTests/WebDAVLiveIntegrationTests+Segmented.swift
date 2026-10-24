import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A large download in several ranges at once, against every endpoint (PLAN.md §M32, after
/// Slice 6). The core suites pin the rules against captured runs; what only a server can show is
/// that the ranges the builder asks for come back as the file, and that the guard each one carries
/// is honoured.
extension WebDAVLiveIntegrationTests {
    /// 16 MiB and an odd tail, so the plan cuts four ranges and the last is shorter than the rest.
    static let splitSize = 16 * 1_048_576 + 12345

    /// F5's download of a large file, the hint F5 passes included: one stat, then four guarded
    /// ranges in one `curl`, joined byte for byte. The same file fetched with no size hint is the
    /// control, and must go as one plain GET, so the count is shown to tell the two apart.
    @Test(
        "a large file comes down in four guarded ranges, byte-identical",
        arguments: WebDAVLiveEnvironment.endpoints
    )
    func aLargeFileIsSplit(_ endpoint: WebDAVLiveEndpoint) async throws {
        let payload = Self.largePayload(Self.splitSize)
        let run = try await offCooperativePool { () -> SplitRun in
            let (backend, counting) = endpoint.backend()
            let root = try endpoint.scratchFolder(backend, "split")
            defer { endpoint.discard(root, on: backend) }
            let remote = root.appending("large.bin")
            try WebDAVLive.upload(payload, to: remote, on: backend)
            var run = SplitRun()
            // The split needs a strong tag to guard its ranges, and Apache's is weak for the second
            // after a write; F5 on a file that old is the case being measured.
            guard try WebDAVLive.strongTag(of: remote, on: backend) != nil else { return run }
            run.sawStrongTag = true

            let local = WebDAVLive.scratchFile()
            defer { try? FileManager.default.removeItem(at: local) }
            let fetch = { (hint: Int64?) throws -> Fetch in
                try? FileManager.default.removeItem(at: local)
                counting.reset()
                var reported: Int64 = 0
                try backend.copyFile(
                    at: remote,
                    to: .local(local.path),
                    hint: CopySourceHint(expectedSize: hint),
                    progress: { reported += $0 },
                    isCancelled: { false }
                )
                return Fetch(
                    requests: counting.requests,
                    bytes: try Data(contentsOf: local),
                    reported: reported
                )
            }
            run.split = try fetch(Int64(payload.count))
            run.plain = try fetch(nil)
            return run
        }
        try #require(run.sawStrongTag, "no strong entity tag within five seconds of a write")
        #expect(run.split.requests == [.propfind(.zero), .getRanges(4)])
        #expect(run.split.bytes == payload)
        #expect(run.split.reported == Int64(payload.count), "each byte reported once")
        #expect(run.plain.requests == [.get(resume: false)], "the control: no hint, no split")
        #expect(run.plain.bytes == payload)
    }

    struct SplitRun: Sendable {
        var sawStrongTag = false
        var split = Fetch()
        var plain = Fetch()
    }

    /// One download of the file: the requests it sent, the bytes that landed and what it reported.
    struct Fetch: Sendable {
        var requests: [CountingWebDAVTransport.Request] = []
        var bytes = Data()
        var reported: Int64 = 0
    }

    /// The guard the split rests on, asked of the server directly through the transport: ranges
    /// carrying a tag the file no longer has are refused, each one, and write nothing — where the
    /// same ranges carrying the file's own tag come back as exactly their bytes.
    @Test(
        "a range guarded by a stale tag is refused and writes nothing",
        arguments: WebDAVLiveEnvironment.endpoints
    )
    func aStaleTagRefusesEveryRange(_ endpoint: WebDAVLiveEndpoint) async throws {
        let payload = Self.largePayload(Self.splitSize)
        let run = try await offCooperativePool { () -> GuardRun in
            let (backend, _) = endpoint.backend()
            let root = try endpoint.scratchFolder(backend, "guard")
            defer { endpoint.discard(root, on: backend) }
            let remote = root.appending("large.bin")
            try WebDAVLive.upload(payload, to: remote, on: backend)
            var run = GuardRun()
            guard let tag = try WebDAVLive.strongTag(of: remote, on: backend),
                  let plan = SegmentedDownloadPlan(
                      totalSize: Int64(payload.count),
                      limits: .webdav
                  ) else { return run }
            run.sawStrongTag = true

            let pieces = WebDAVLive.scratchFile()
            try FileManager.default.createDirectory(at: pieces, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: pieces) }
            let segments = plan.segments(under: pieces)
            let ask = { (tag: String) throws -> [WebDAVBatchAnswer] in
                let outcome = try endpoint.transport().downloadSegments(
                    segments,
                    of: WebDAVTaggedFile(backendPath: remote.path, entityTag: tag),
                    to: pieces.appendingPathComponent("whole").path,
                    progress: { _ in },
                    isCancelled: { false }
                )
                guard case let .segments(answers) = outcome else { return [] }
                return answers
            }
            // A tag of the same shape that the file never had: what a file rewritten since the stat
            // would present.
            run.stale = try ask(#""0-0""#)
            run.piecesAfterStale = segments.filter {
                FileManager.default.fileExists(atPath: $0.localPath)
            }.count
            run.current = try ask(tag)
            run.joined = try SegmentAssembly.assemble(
                segments,
                into: pieces.appendingPathComponent("joined").path
            )
            run.joinedBytes = try Data(contentsOf: pieces.appendingPathComponent("joined"))
            return run
        }
        try #require(run.sawStrongTag, "no strong entity tag within five seconds of a write")
        #expect(run.stale == Array(repeating: .response(WebDAVHTTPResponse(status: 412)), count: 4))
        #expect(run.piecesAfterStale == 0, "a refused range writes nothing")
        #expect(run.current.allSatisfy {
            if case let .response(response) = $0 { response.status == 206 } else { false }
        })
        #expect(run.joined == Int64(payload.count))
        #expect(run.joinedBytes == payload)
    }

    struct GuardRun: Sendable {
        var sawStrongTag = false
        var stale: [WebDAVBatchAnswer] = []
        var piecesAfterStale = -1
        var current: [WebDAVBatchAnswer] = []
        var joined: Int64 = 0
        var joinedBytes = Data()
    }

    /// `count` random bytes, filled in one call: ``WebDAVLive/payload(_:)`` draws byte by byte,
    /// which is slow at sixteen megabytes in a debug build.
    static func largePayload(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return data
    }
}
