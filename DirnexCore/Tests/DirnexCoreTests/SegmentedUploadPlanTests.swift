import Foundation
import Testing

@testable import DirnexCore

/// The arithmetic behind a segmented upload, and the two rules that keep it from being a slower
/// spelling of a single `put`: equal parts where they finish together, and a refusal where only one
/// could be in flight.
@Suite("SegmentedUploadPlan")
struct SegmentedUploadPlanTests {
    private let mib: Int64 = 1024 * 1024

    @Test("a file at or under the threshold is not split")
    func belowTheThreshold() {
        let limits = SegmentedUploadLimits.sftp
        #expect(!SegmentedUploadPlan.isWorthwhile(totalSize: limits.threshold, limits: limits))
        #expect(SegmentedUploadPlan.isWorthwhile(totalSize: limits.threshold + 1, limits: limits))
    }

    @Test("a file just over the threshold is cut into equal parts, not preferred-size ones")
    func equalPartsForASmallFile() throws {
        // 48 MiB over four connections is 12 MiB apiece, which is under the floor — so it lands on
        // the floor and gives three parts of 16, not two of 32 and a runt.
        let plan = try #require(SegmentedUploadPlan(totalSize: 48 * mib, limits: .sftp))
        #expect(plan.partSize == 16 * mib)
        #expect(plan.partCount == 3)
        #expect(plan.partsInFlight == 3)
        #expect(plan.length(ofPart: 3) == 16 * mib)
    }

    @Test("a file large enough for four even parts gets four even parts")
    func evenPartsFillEveryConnection() throws {
        let plan = try #require(SegmentedUploadPlan(totalSize: 100 * mib, limits: .sftp))
        #expect(plan.partCount == 4)
        #expect(plan.partsInFlight == 4)
        // The point of dividing evenly rather than by the preferred size: with four connections and
        // parts of 32, 32 and 36 MiB the run takes as long as its largest part.
        #expect(plan.partSize == 25 * mib)
        #expect(plan.length(ofPart: 4) == 25 * mib)
    }

    @Test("a large file uses the preferred part size and runs in batches")
    func batchesForALargeFile() throws {
        let plan = try #require(SegmentedUploadPlan(totalSize: 1024 * mib, limits: .sftp))
        #expect(plan.partSize == 32 * mib)
        #expect(plan.partCount == 32)
        #expect(plan.partsInFlight == 4)
        #expect(plan.batches.count == 8)
        #expect(plan.batches.first == [1, 2, 3, 4])
        #expect(plan.batches.last == [29, 30, 31, 32])
    }

    @Test("the ranges tile the file exactly, with the remainder in the last part")
    func rangesTileTheFile() throws {
        let total = 100 * mib + 7
        let plan = try #require(SegmentedUploadPlan(totalSize: total, limits: .sftp))
        var next: Int64 = 0
        for number in 1...plan.partCount {
            let range = try #require(plan.range(ofPart: number))
            #expect(range.lowerBound == next)
            next = range.upperBound
        }
        #expect(next == total)
        #expect(plan.range(ofPart: 0) == nil)
        #expect(plan.range(ofPart: plan.partCount + 1) == nil)
        #expect(plan.length(ofPart: plan.partCount + 1) == 0)
    }

    @Test("the scratch a run occupies is one batch, whatever the file's size")
    func stagingIsBoundedByTheBatch() throws {
        let small = try #require(SegmentedUploadPlan(totalSize: 100 * mib, limits: .sftp))
        let large = try #require(SegmentedUploadPlan(totalSize: 200 * 1024 * mib, limits: .sftp))
        #expect(small.stagingPeak == 100 * mib)
        #expect(large.stagingPeak == 128 * mib)
        #expect(large.stagingPeak <= SegmentedUploadLimits.sftp.stagingBudget)
    }

    @Test("a part is grown rather than the count being exceeded")
    func partsGrowRatherThanMultiply() throws {
        let limits = SegmentedUploadLimits(
            threshold: 0,
            minimumPartSize: mib,
            preferredPartSize: mib,
            maximumPartsInFlight: 4,
            stagingBudget: 512 * mib,
            maximumParts: 10
        )
        let plan = try #require(SegmentedUploadPlan(totalSize: 100 * mib, limits: limits))
        #expect(plan.partCount <= 10)
        #expect(plan.partSize == 10 * mib)
    }

    @Test("a plan that could only run one part at a time is refused")
    func oneInFlightIsRefused() {
        // A part so large that the staging budget affords exactly one of them: sending it is the
        // single `put` plus a slice, a second copy on the server and an extra connection.
        let limits = SegmentedUploadLimits(
            threshold: 0,
            minimumPartSize: 64 * mib,
            preferredPartSize: 64 * mib,
            maximumPartsInFlight: 4,
            stagingBudget: 64 * mib,
            maximumParts: 10_000
        )
        #expect(SegmentedUploadPlan(totalSize: 512 * mib, limits: limits) == nil)
        // And a file with only one part in it, whatever the budget.
        #expect(SegmentedUploadPlan(totalSize: 10 * mib, limits: .sftp) == nil)
    }

    @Test("an empty or impossible file has no plan")
    func nothingToSplit() {
        #expect(SegmentedUploadPlan(totalSize: 0, limits: .sftp) == nil)
        #expect(SegmentedUploadPlan(totalSize: -1, limits: .sftp) == nil)
        #expect(SegmentedUploadPlan(totalSize: 100, partSize: 0, partsInFlight: 2) == nil)
        #expect(SegmentedUploadPlan(totalSize: 100, partSize: 10, partsInFlight: 0) == nil)
    }

    @Test("a part's remote name sits beside the destination, hidden and tokened")
    func remoteNamesSitBesideTheDestination() throws {
        let plan = try #require(SegmentedUploadPlan(totalSize: 100 * mib, limits: .sftp))
        let parts = plan.parts(
            stagingIn: URL(fileURLWithPath: "/tmp/scratch"),
            destination: "/srv/backup/disk.img",
            token: "abcd1234"
        )
        #expect(parts.count == 4)
        #expect(parts[0].remotePath == "/srv/backup/.dirnex-upload-abcd1234-disk.img.1")
        #expect(parts[3].remotePath == "/srv/backup/.dirnex-upload-abcd1234-disk.img.4")
        #expect(parts[0].localPath == "/tmp/scratch/1")
        // Every part names a distinct file at both ends, or a run would overwrite its own bytes.
        #expect(Set(parts.map(\.remotePath)).count == parts.count)
        #expect(Set(parts.map(\.localPath)).count == parts.count)
    }

    @Test("a destination at the root still names its parts inside the root")
    func remoteNamesAtTheRoot() throws {
        let plan = try #require(SegmentedUploadPlan(totalSize: 100 * mib, limits: .sftp))
        let parts = plan.parts(
            stagingIn: URL(fileURLWithPath: "/tmp/scratch"),
            destination: "/disk.img",
            token: "abcd1234"
        )
        #expect(parts[0].remotePath == "/.dirnex-upload-abcd1234-disk.img.1")
        #expect(SFTPBackend.stagingPath(for: "/disk.img", token: "abcd1234")
            == "/.dirnex-upload-abcd1234-disk.img.joined")
        #expect(SFTPBackend.stagingPath(for: "/srv/x/disk.img", token: "t")
            == "/srv/x/.dirnex-upload-t-disk.img.joined")
    }

    @Test("the staging file is not one of the parts")
    func stagingIsItsOwnName() throws {
        let plan = try #require(SegmentedUploadPlan(totalSize: 100 * mib, limits: .sftp))
        let parts = plan.parts(
            stagingIn: URL(fileURLWithPath: "/tmp/s"),
            destination: "/srv/disk.img",
            token: "t"
        )
        let staging = SFTPBackend.stagingPath(for: "/srv/disk.img", token: "t")
        #expect(!parts.map(\.remotePath).contains(staging))
    }
}
