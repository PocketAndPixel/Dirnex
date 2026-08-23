import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The two app-side halves of a parallel part upload: how a batch's progress is read, and how long
/// the runner is willing to wait for one (docs/HISTORY.md ▸ After M19).
///
/// Both are invisible in a green run and both fail quietly. A progress source that reads nothing
/// leaves the bar still for the whole upload — the symptom this project has already paid for once,
/// measured as 99 seconds of silence — and a backstop derived from the wrong place kills a long
/// upload it was only ever meant to catch wedged.
@Suite("S3 parallel upload: progress and the wait")
struct S3ParallelUploadProgressTests {
    // MARK: - Progress

    /// A batch has no other observable: several transfers share one meter, and nothing on this
    /// machine grows the way a download's destination file does. So a part reports its whole
    /// length the moment its own write-out line lands.
    @Test("each part reports its length as its write-out line arrives")
    func partsReportAsTheyLand() {
        let watch = TransferProgressWatch(.uploadedParts(lengths: [1: 400, 2: 500, 3: 100]))
        var deltas: [Int64] = []

        watch.report(to: { deltas.append($0) })
        #expect(deltas.isEmpty) // nothing has landed yet

        watch.consume("\ns3-part2-status=200\ns3-part2-etag=\"e2\"\n")
        watch.report(to: { deltas.append($0) })
        #expect(deltas == [500])

        watch.consume("\ns3-part1-status=200\n\ns3-part3-status=200\n")
        watch.report(to: { deltas.append($0) })
        // Forward-only deltas, never a running total — what the operation queue adds up.
        #expect(deltas == [500, 500])
        #expect(deltas.reduce(0, +) == 1000)
    }

    /// The narrowness control: a part that has not landed contributes nothing, and a report with
    /// nothing new to say says nothing rather than repeating itself.
    @Test("a part still in flight is not counted, and a quiet turn reports nothing")
    func inFlightPartsAreNotCounted() {
        let watch = TransferProgressWatch(.uploadedParts(lengths: [1: 400, 2: 400]))
        watch.consume("\ns3-part1-status=200\n")
        var deltas: [Int64] = []
        watch.report(to: { deltas.append($0) })
        watch.report(to: { deltas.append($0) })
        #expect(deltas == [400])
    }

    /// A refused part has landed too — it is *done*, whatever it answered — and its bytes really
    /// were sent. Withholding them would leave the bar short by a part on every failed batch.
    @Test("a refused part still reports the bytes it sent")
    func refusedPartStillReports() {
        let watch = TransferProgressWatch(.uploadedParts(lengths: [1: 400]))
        watch.consume("\ns3-part1-status=403\ns3-part1-etag=\n")
        var reported: Int64 = 0
        watch.report(to: { reported += $0 })
        #expect(reported == 400)
    }

    // MARK: - The wait

    /// A batch puts every per-transfer option in its **config sections**, so `argv` carries no
    /// `--max-time` at all. Read only from the arguments, the backstop would fall back to the
    /// metadata timeout and terminate a perfectly healthy upload part-way through.
    @Test("the backstop reads the batch's time budget out of the configuration")
    func budgetComesFromTheConfiguration() {
        let invocation = S3ProcessArguments.uploadParts(
            session: S3Session(
                location: S3Location(
                    host: "s3.eu-north-1.amazonaws.com",
                    bucket: "backup",
                    region: "eu-north-1",
                    accessKeyID: "AKIAEXAMPLE"
                ),
                connectTimeout: 15,
                maxTime: 3600
            ),
            parts: [S3PartRequest(localPath: "/tmp/s1", key: "k", uploadID: "u", number: 1)],
            credentials: "user = \"id:secret\"\n"
        )
        #expect(!invocation.arguments.contains("--max-time"))
        #expect(S3CurlRunner.curlMaxTime(inConfiguration: invocation.configuration) == 3600)
    }

    @Test("a configuration naming no budget reports none, so the caller's own bound stands")
    func noBudgetInConfiguration() {
        #expect(S3CurlRunner.curlMaxTime(inConfiguration: "user = \"id:secret\"\n") == 0)
    }
}
