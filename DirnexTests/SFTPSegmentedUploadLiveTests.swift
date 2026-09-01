import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A segmented upload against a **real** server: real `sftp` children sending real parts, a real
/// server-side `cat`, and the bytes read back to say whether the file the account ends up with is
/// the file that was sent (PLAN.md §4 ▸ *Still open*).
///
/// It is here rather than in a throwaway script for the reason docs/NOTES.md gives: a checked-in
/// live suite is repeatable, is reviewed, and does not evaporate when the shell history does. Gated
/// on the same `/tmp/dirnex_sftp_live_test.json` every other SFTP live suite reads, so CI — which
/// has no server — skips it.
///
/// **The limits are shrunk and the reason matters.** The shipped threshold is 32 MiB, so a fixture
/// at real sizes would put tens of megabytes across the wire per test to exercise machinery whose
/// *policy* is already unit-tested. What only a server can answer is whether the route works at all
/// — whether four concurrent `sftp` children land four parts, whether `cat` joins them in the right
/// order, whether the size comes back readable, and whether the rename leaves the account holding
/// exactly one file — and every one of those is answered at 1 MiB.
@Suite("SFTP segmented upload, live", .enabled(if: SFTPLiveEnvironment.current != nil), .serialized)
struct SFTPSegmentedUploadLiveTests {
    /// Four parts of 256 KiB: enough concurrency to be the real route, small enough to be quick.
    private static let limits = SegmentedUploadLimits(
        threshold: 512 * 1024,
        minimumPartSize: 128 * 1024,
        preferredPartSize: 256 * 1024,
        maximumPartsInFlight: 4,
        stagingBudget: 8 << 20,
        maximumParts: 10_000
    )

    @Test("a split upload lands the file byte for byte, in order, with nothing left behind")
    func splitUploadLandsTheFile() async throws {
        try await offCooperativePool {
            let (backend, directory) = try Self.connected()
            defer { try? backend.removeItem(at: directory) }

            // Every part distinguishable from every other, so a join that reordered or repeated one
            // produces a *different file* rather than a plausible one — which a fixture of one
            // repeated byte could not tell apart.
            let contents = Data((0..<(1024 * 1024)).map { UInt8(($0 / 4096) % 251) })
            let source = try Self.localFile(contents)
            defer { try? FileManager.default.removeItem(atPath: source) }

            let destination = directory.appending("disk.img")
            var deltas: [Int64] = []
            try backend.copyFile(
                at: .local(source),
                to: destination,
                progress: { deltas.append($0) },
                isCancelled: { false }
            )
            // **The evidence that the split ran at all**, and it is needed: a single-stream fallback
            // would land the same bytes and leave the same empty directory, so every other assertion
            // here is true of the route this test exists to distinguish itself from. What only the
            // split produces is *four reports* — `sftp` gives an upload no observable, so one stream
            // can report exactly once, at the end.
            #expect(deltas.filter { $0 > 0 } == Array(repeating: 256 * 1024, count: 4))
            #expect(deltas.reduce(0, +) == Int64(contents.count))

            // The bytes, read back off the server through the ordinary download.
            let landed = try Self.localPath()
            defer { try? FileManager.default.removeItem(atPath: landed) }
            try backend.copyFile(
                at: destination,
                to: .local(landed),
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(try Data(contentsOf: URL(fileURLWithPath: landed)) == contents)

            // And nothing of the run is still on the server: no parts, no staging file. `rm -f` in
            // the commit is what sweeps them, and a leftover would be an invisible dot-file the
            // user pays for forever.
            let names = try backend.listDirectory(at: directory).map(\.name)
            #expect(names == ["disk.img"])
        }
    }

    @Test("the same file over one stream produces the same bytes")
    func theSingleStreamControl() async throws {
        // The narrowness control, and it is what makes the test above evidence about *splitting*
        // rather than about copying: same fixture, same server, threshold raised out of reach.
        try await offCooperativePool {
            var (backend, directory) = try Self.connected()
            backend.segmentedUploadLimits = SegmentedUploadLimits(
                threshold: .max,
                minimumPartSize: 128 * 1024,
                preferredPartSize: 256 * 1024,
                maximumPartsInFlight: 4,
                stagingBudget: 8 << 20,
                maximumParts: 10_000
            )
            defer { try? backend.removeItem(at: directory) }

            let contents = Data((0..<(1024 * 1024)).map { UInt8(($0 / 4096) % 251) })
            let source = try Self.localFile(contents)
            defer { try? FileManager.default.removeItem(atPath: source) }

            let destination = directory.appending("disk.img")
            var deltas: [Int64] = []
            try backend.copyFile(
                at: .local(source),
                to: destination,
                progress: { deltas.append($0) },
                isCancelled: { false }
            )
            // The other half of the A/B: one report rather than four, from the same fixture against
            // the same server. Without this the test above could be measuring a fallback.
            #expect(deltas.filter { $0 > 0 } == [Int64(contents.count)])
            let landed = try Self.localPath()
            defer { try? FileManager.default.removeItem(atPath: landed) }
            try backend.copyFile(
                at: destination,
                to: .local(landed),
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(try Data(contentsOf: URL(fileURLWithPath: landed)) == contents)
        }
    }

    @Test("a file under the threshold is not split, and the account is not asked to join anything")
    func belowTheThresholdNothingIsJoined() async throws {
        try await offCooperativePool {
            let (backend, directory) = try Self.connected()
            defer { try? backend.removeItem(at: directory) }

            let contents = Data(repeating: 7, count: 4096)
            let source = try Self.localFile(contents)
            defer { try? FileManager.default.removeItem(atPath: source) }

            try backend.copyFile(
                at: .local(source),
                to: directory.appending("small.bin"),
                progress: { _ in },
                isCancelled: { false }
            )
            // A small file must cost exactly what it always did — one `put`, and no staging name
            // ever created.
            #expect(try backend.listDirectory(at: directory).map(\.name) == ["small.bin"])
        }
    }

    // MARK: - Helpers

    /// A backend on the live account, and a fresh directory of its own to work in — so two runs, or
    /// a run beside another suite, cannot see each other's files.
    private static func connected() throws -> (SFTPBackend, VFSPath) {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        var backend = SFTPBackend(location: config.location, transport: transport)
        backend.segmentedUploadLimits = limits
        let root = VFSPath(backend: .sftp(config.location), path: config.remotePath)
        let directory = root.appending("dirnex-upload-live-\(UUID().uuidString.prefix(8))")
        try backend.createDirectory(at: directory)
        return (backend, directory)
    }

    private static func localPath() throws -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-live-\(UUID().uuidString)").path
    }

    private static func localFile(_ contents: Data) throws -> String {
        let path = try localPath()
        try contents.write(to: URL(fileURLWithPath: path))
        return path
    }
}
