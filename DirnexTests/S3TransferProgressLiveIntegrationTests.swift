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
    /// The **download** probe, which can be a fixed size because a download's progress does not come
    /// from `curl` at all: the destination file is watched at `ProcessWaiting`'s 100 ms poll, so
    /// even a two-second transfer reports twenty times. The upload's clock is an order of magnitude
    /// slower, which is why only it climbs the ladder below.
    private static let downloadProbeSize = 4 * 1024 * 1024

    /// `curl` prints a meter row about once a second, which is the floor under everything the
    /// upload test can observe (docs/NOTES.md ▸ curl for S3).
    private static let meterInterval: TimeInterval = 1

    /// Upload probes, smallest first — the test climbs this ladder until an attempt is
    /// ``Attempt/isObservable`` and asserts on that one.
    ///
    /// **Climbing beats calculating, and both cheaper designs were measured failing.** A fixed size
    /// is a duration expressed in bytes: 4 MiB was chosen against an S3-compatible server at
    /// ~285 KB/s (about fifteen seconds, a dozen meter rows) and against real AWS the same 4 MiB
    /// took **2.76 s**, so the first row landed at 1.82 s and the assertion failed on a transport
    /// that was reporting perfectly (2026-08-18). Sizing it from a measured rate fails more
    /// interestingly: one 1 MiB sample is mostly handshake and read 2.57 MB/s for a link doing
    /// nearer 9, and the two-point slope that removes the fixed cost is dominated by variance —
    /// green three runs alone, then **1 sighting** inside the full suite, where everything else on
    /// the machine is moving at once. A ladder needs no model of the link: the criterion is
    /// measured off the attempt itself. It is measured off the *meter* rather than off the
    /// transfer's total duration — see ``Attempt/reportingSpread``, which is the same lesson one
    /// level in, since a rung long enough overall can still spend nearly all of itself in a
    /// handshake that prints nothing.
    ///
    /// The top rung stops below `S3MultipartLimits.multipartThreshold` (64 MiB) on purpose — over
    /// it the bytes go out through a different verb, and this test is about the single `PUT`'s
    /// meter.
    private static let uploadProbes = [4, 16, 48].map { $0 * 1024 * 1024 }

    private func transport(_ config: S3LiveEnvironment.Config) -> S3CurlTransport {
        S3CurlTransport(
            location: config.account.bucketLocation(named: config.bucket),
            secretAccessKey: config.secretAccessKey
        )
    }

    /// A file of random bytes, so nothing upstream can compress the transfer into fewer seconds
    /// than the meter needs to say anything.
    private static func probeFile(bytes count: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-progress-probe-\(UUID().uuidString).bin")
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            arc4random_buf(base, buffer.count)
        }
        try bytes.write(to: url)
        return url
    }

    /// One meter row: how far in it arrived, and what it added.
    ///
    /// A named type rather than the tuple this was, because the whole attempt now comes back out of
    /// a `BlockingWork.run` and therefore has to be `Sendable`.
    private struct Sighting: Sendable {
        let elapsed: TimeInterval
        let delta: Int64
    }

    /// One upload, with every delta and the moment it arrived — the timing is half the claim, since
    /// a transport that reports everything at the end also reports "some" bytes.
    private struct Attempt: Sendable {
        let size: Int
        let finished: TimeInterval
        let sightings: [Sighting]
        let response: S3Response

        /// How long the transfer went on reporting *after* its first row.
        ///
        /// This, and not the total duration, is what every timing claim below is about — so it is
        /// what the ladder climbs on. The total is a proxy for it, and the proxy expires under
        /// load: a transfer's early seconds are DNS, connect, TLS and `Expect: 100-continue`, none
        /// of which print anything, so on a busy machine a 3.2 s upload can spend 2.4 s before the
        /// first meter row and leave 0.8 s of meter behind it. Measured that way 2026-08-20 under a
        /// Spotlight-sized CPU load, failing an assertion the transport was satisfying perfectly —
        /// the same shape as the fixed 4 MiB probe this ladder replaced, one level in.
        var reportingSpread: TimeInterval {
            guard let first = sightings.first else { return 0 }
            return finished - first.elapsed
        }

        /// Whether this rung can carry the claims at all: two rows at least, a meter interval
        /// apart at least. Both halves are asserted below, so both belong in the criterion — a
        /// ladder that stops on one of them hands the assertions a transfer that fails the other.
        var isObservable: Bool {
            sightings.count >= 2 && reportingSpread >= meterInterval
        }
    }

    /// Upload once, **off the cooperative pool**, and report what the meter said.
    ///
    /// `BlockingWork.run` for the reason its own doc comment gives, arriving here in test code
    /// rather than in the product: a synchronous body that blocks on `curl` holds a cooperative
    /// worker for the whole transfer, and the pool is only as wide as the machine's core count. A
    /// 48 MiB rung is a minute of one of those, and this suite is one of six live ones running at
    /// once — so the pool empties and every *other* suite's `await` is starved, which is the shape
    /// docs/NOTES.md records for `FileOperationQueue`. Measured here: the whole app suite under
    /// `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` went 16 s and green without these suites and 86 s
    /// with 5 failures with them, none of the failures in the live tests themselves.
    ///
    /// Everything the timing claims rest on stays inside the one closure, so the clock, the meter
    /// rows and the transfer are still measured on the thread that ran it.
    private static func attemptUpload(
        bytes count: Int, using wire: S3CurlTransport
    ) async throws -> Attempt {
        try await BlockingWork.run { () -> Result<Attempt, any Error> in
            Result {
                let source = try probeFile(bytes: count)
                defer { try? FileManager.default.removeItem(at: source) }
                let key = "dirnex-progress-probe/\(UUID().uuidString).bin"
                let start = Date()
                var sightings: [Sighting] = []
                let response = try wire.upload(
                    localPath: source.path,
                    to: key,
                    progress: {
                        sightings.append(
                            Sighting(elapsed: Date().timeIntervalSince(start), delta: $0)
                        )
                    },
                    isCancelled: { false }
                )
                let finished = Date().timeIntervalSince(start)
                _ = try? wire.deleteObject(key: key)
                return Attempt(
                    size: count, finished: finished, sightings: sightings, response: response
                )
            }
        }.get()
    }

    @Test("an upload reports its bytes while it is still running, not only when it ends")
    func uploadStreamsProgress() async throws {
        let config = try #require(S3LiveEnvironment.current)
        let wire = transport(config)

        var attempt = try await Self.attemptUpload(bytes: Self.uploadProbes[0], using: wire)
        for size in Self.uploadProbes.dropFirst() where !attempt.isObservable {
            attempt = try await Self.attemptUpload(bytes: size, using: wire)
        }

        #expect(attempt.response.isSuccess, "status \(attempt.response.status)")
        #expect(attempt.response.bytesTransferred == Int64(attempt.size))
        // Said before the timing claims rather than left implicit: past the top rung there is no
        // transfer left to grow, so a link this fast makes the rest of this test unanswerable —
        // which has to fail loudly rather than pass over one row that proves nothing.
        #expect(
            attempt.isObservable,
            """
            \(attempt.size) B gave \(attempt.sightings.count) row(s) over \
            \(attempt.reportingSpread)s of meter in a \(attempt.finished)s upload — \
            too fast for a once-a-second meter, so nothing below is answerable
            """
        )

        #expect(!attempt.sightings.isEmpty, "the upload reported nothing at all while it ran")
        let firstSighting = try #require(attempt.sightings.first).elapsed
        // What separates a streaming report from one burst delivered at EOF is that the rows are
        // spread over *time*, so the claim is made in the meter's own cadence rather than as a
        // fraction of the transfer: a run reporting as it goes leaves at least a whole meter
        // interval between its first row and the end, where a drain that read its pipe to EOF
        // delivers every row within milliseconds of the process exiting. The fraction form said the
        // same thing only for a transfer of one particular length, which is how it broke.
        #expect(
            attempt.reportingSpread >= Self.meterInterval,
            "first report at \(firstSighting)s of a \(attempt.finished)s upload — the end, not the middle"
        )
        #expect(
            attempt.sightings.count >= 2,
            "\(attempt.sightings.count) report(s) over \(attempt.finished)s at about one a second"
        )
        #expect(attempt.sightings.allSatisfy { $0.delta > 0 }, "a byte tally that only adds")
        let total = attempt.sightings.reduce(0) { $0 + $1.delta }
        #expect(total <= Int64(attempt.size), "never more than the file")
    }

    /// What a download probe measured. Same `Sendable` reason as ``Attempt``: the transfer runs on
    /// `BlockingWork`'s queue, so everything the assertions read has to come back out of it.
    private struct Download: Sendable {
        let finished: TimeInterval
        let sightings: [Sighting]
        let response: S3Response
        let landed: Int
    }

    /// The upload this probe needs never arrived where the test could see it fail, so it says so.
    private enum ProbeFailure: Error { case uploadFailed(status: Int) }

    /// Seed an object and download it, **off the cooperative pool** — see ``attemptUpload`` for why
    /// that matters here and not merely for tidiness.
    private static func attemptDownload(using wire: S3CurlTransport) async throws -> Download {
        try await BlockingWork.run { () -> Result<Download, any Error> in
            Result {
                let source = try probeFile(bytes: downloadProbeSize)
                defer { try? FileManager.default.removeItem(at: source) }
                let key = "dirnex-progress-probe/\(UUID().uuidString).bin"

                let uploaded = try wire.upload(
                    localPath: source.path, to: key, progress: { _ in }, isCancelled: { false }
                )
                defer { _ = try? wire.deleteObject(key: key) }
                guard uploaded.isSuccess else {
                    throw ProbeFailure.uploadFailed(status: uploaded.status)
                }

                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dirnex-progress-down-\(UUID().uuidString).bin")
                defer { try? FileManager.default.removeItem(at: destination) }

                let start = Date()
                var sightings: [Sighting] = []
                let response = try wire.download(
                    key: key,
                    to: destination.path,
                    resume: false,
                    progress: {
                        sightings.append(
                            Sighting(elapsed: Date().timeIntervalSince(start), delta: $0)
                        )
                    },
                    isCancelled: { false }
                )
                let finished = Date().timeIntervalSince(start)
                return Download(
                    finished: finished,
                    sightings: sightings,
                    response: response,
                    landed: try Data(contentsOf: destination).count
                )
            }
        }.get()
    }

    @Test("a download reports its bytes while it is still running")
    func downloadStreamsProgress() async throws {
        let config = try #require(S3LiveEnvironment.current)
        let probe = try await Self.attemptDownload(using: transport(config))
        let response = probe.response
        let sightings = probe.sightings
        let finished = probe.finished

        #expect(response.isSuccess, "status \(response.status)")
        #expect(!sightings.isEmpty, "the download reported nothing at all while it ran")
        let firstSighting = try #require(sightings.first).elapsed
        // A fraction of the duration is safe *here* and is not safe for the upload above, which is
        // the asymmetry worth stating because the two tests read as twins: this one's floor is
        // `ProcessWaiting`'s 100 ms poll, since the destination file's size is the observable and it
        // can be asked at any moment, where the upload's floor is whenever `curl` next chooses to
        // print. Same shape of assertion, two clocks an order of magnitude apart.
        #expect(firstSighting < finished / 2)
        // A download watches the destination file rather than the meter, so its deltas are exact
        // and must never claim more than what landed.
        let downloaded = Int64(Self.downloadProbeSize)
        #expect(sightings.reduce(0) { $0 + $1.delta } <= downloaded)
        #expect(
            probe.landed == Self.downloadProbeSize,
            """
            landed \(probe.landed) of \(Self.downloadProbeSize), \
            curl reported \(response.bytesTransferred)
            """
        )
    }
}
