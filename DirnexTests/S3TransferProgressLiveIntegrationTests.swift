import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Whether a real transfer, over a real `curl`, actually reports where it has got to.
///
/// This is the one claim in the progress work that no headless test can make. Everything below the
/// app — the meter parse, the delta arithmetic, the reconciliation — is pinned against fixtures in
/// `DirnexCore`, and all of it would go on passing if `curl` printed its meter in a shape this
/// project has never seen, or if the arguments silenced it again, or if the stderr drain read to EOF
/// and delivered the whole thing after the process exited. Each of those is invisible from inside
/// and each brings back exactly the bug this fixed: a copy that reports nothing for its entire
/// duration (measured 2026-08-14 as 99 seconds for 29 MB, reported by a user as the copy not
/// working).
///
/// Gated on the same config file as ``S3AccountLiveIntegrationTests``, since `xcodebuild` does not
/// forward the shell environment to the test runner (docs/NOTES.md ▸ Testing). `.serialized` for the
/// reason that suite records: one endpoint, and these tests move real bytes over it.
@Suite(
    "S3 transfer progress live integration",
    .serialized,
    .enabled(if: S3LiveEnvironment.current != nil)
)
struct S3TransferProgressLiveIntegrationTests {
    /// Big enough that the transfer outlives several of `curl`'s once-a-second meter rows, small
    /// enough that the suite is not a coffee break: at the ~285 KB/s measured against this endpoint,
    /// 4 MB is about fifteen seconds.
    private static let probeSize = 4 * 1024 * 1024

    private func transport(_ config: S3LiveEnvironment.Config) -> S3CurlTransport {
        S3CurlTransport(
            location: config.account.bucketLocation(named: config.bucket),
            secretAccessKey: config.secretAccessKey
        )
    }

    /// A file of random bytes, so nothing upstream can compress the transfer into fewer seconds
    /// than the meter needs to say anything.
    private func probeFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-progress-probe-\(UUID().uuidString).bin")
        var bytes = Data(count: Self.probeSize)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            arc4random_buf(base, buffer.count)
        }
        try bytes.write(to: url)
        return url
    }

    @Test("an upload reports its bytes while it is still running, not only when it ends")
    func uploadStreamsProgress() throws {
        let config = try #require(S3LiveEnvironment.current)
        let source = try probeFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let key = "dirnex-progress-probe/\(UUID().uuidString).bin"
        let wire = transport(config)

        // Every delta, with the moment it arrived — the timing is half the claim, since a transport
        // that reports everything at the end also reports "some" bytes.
        let start = Date()
        var sightings: [(elapsed: TimeInterval, delta: Int64)] = []
        let response = try wire.upload(
            localPath: source.path,
            to: key,
            progress: { sightings.append((Date().timeIntervalSince(start), $0)) },
            isCancelled: { false }
        )
        defer { _ = try? wire.deleteObject(key: key) }

        #expect(response.isSuccess, "status \(response.status)")
        let uploaded = Int64(Self.probeSize)
        #expect(response.bytesTransferred == uploaded)

        let finished = Date().timeIntervalSince(start)
        #expect(!sightings.isEmpty, "the upload reported nothing at all while it ran")
        let firstSighting = try #require(sightings.first).elapsed
        // The assertion that separates a streaming report from a report at the end: something has to
        // arrive before the transfer is over. Half is a wide margin around "not at the end" — the
        // meter's first row lands within a second or two of the connection opening.
        #expect(
            firstSighting < finished / 2,
            "first report at \(firstSighting)s of a \(finished)s upload — that is the end, not the middle"
        )
        #expect(sightings.allSatisfy { $0.delta > 0 }, "a byte tally that only adds")
        #expect(sightings.reduce(0) { $0 + $1.delta } <= uploaded, "never more than the file")
    }

    @Test("a download reports its bytes while it is still running")
    func downloadStreamsProgress() throws {
        let config = try #require(S3LiveEnvironment.current)
        let source = try probeFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let key = "dirnex-progress-probe/\(UUID().uuidString).bin"
        let wire = transport(config)

        let uploaded = try wire.upload(
            localPath: source.path,
            to: key,
            progress: { _ in },
            isCancelled: { false }
        )
        try #require(uploaded.isSuccess)
        defer { _ = try? wire.deleteObject(key: key) }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-progress-down-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        let start = Date()
        var sightings: [(elapsed: TimeInterval, delta: Int64)] = []
        let response = try wire.download(
            key: key,
            to: destination.path,
            resume: false,
            progress: { sightings.append((Date().timeIntervalSince(start), $0)) },
            isCancelled: { false }
        )
        let finished = Date().timeIntervalSince(start)

        #expect(response.isSuccess, "status \(response.status)")
        #expect(!sightings.isEmpty, "the download reported nothing at all while it ran")
        let firstSighting = try #require(sightings.first).elapsed
        #expect(firstSighting < finished / 2)
        // A download watches the destination file rather than the meter, so its deltas are exact
        // and must never claim more than what landed.
        let downloaded = Int64(Self.probeSize)
        #expect(sightings.reduce(0) { $0 + $1.delta } <= downloaded)
        let landed = try Data(contentsOf: destination).count
        #expect(
            landed == Self.probeSize,
            "landed \(landed) of \(Self.probeSize), curl reported \(response.bytesTransferred)"
        )
    }
}
