import Foundation
import Testing

@testable import DirnexCore

/// Downloading one object over several connections at once — the *request* half (docs/HISTORY.md ▸ After M19).
///
/// The multipart upload's mirror image: which ranges are asked for, what one `curl` is told to do
/// with them, and how several answers arriving on one stream are told apart. What becomes of the
/// pieces is the other half, in `S3SegmentedAssemblyTests`. What neither can measure is the
/// throughput — that needs a real link, and the 6,7× the probe measured is the evidence the shape
/// rests on.
@Suite("S3 segmented download: the request")
struct S3SegmentedDownloadTests {
    private static let location = S3Location(
        host: "s3.eu-north-1.amazonaws.com",
        bucket: "photos",
        region: "eu-north-1",
        accessKeyID: "AKIAEXAMPLE"
    )
    private static let mebibyte: Int64 = 1024 * 1024

    // MARK: - Which ranges are asked for

    @Test("an object well over the threshold is cut into eight")
    func eightSegments() throws {
        let plan = try #require(S3DownloadPlan(totalSize: 100 * Self.mebibyte))
        #expect(plan.segmentCount == 8)
        #expect(plan.segmentSize == 13_107_200) // 100 MiB over 8, rounded up
        #expect(plan.length(ofSegment: 8) == 100 * Self.mebibyte - 7 * 13_107_200)
    }

    /// The floor is what keeps a barely-worthwhile object from being cut into eight pieces whose
    /// per-request overhead is larger than the transfer each performs.
    @Test("a small object takes as many segments as the floor allows, and no more")
    func floorBoundsTheCount() throws {
        let small = try #require(S3DownloadPlan(totalSize: 12 * Self.mebibyte))
        #expect(small.segmentCount == 3)
        #expect(small.segmentSize == 4 * Self.mebibyte)

        let barely = try #require(S3DownloadPlan(totalSize: 9 * Self.mebibyte))
        #expect(barely.segmentCount == 2)
    }

    @Test("no segment is ever under the floor, at any size")
    func segmentsClearTheFloor() throws {
        for megabytes in [9, 12, 17, 33, 64, 100, 512, 4096] {
            let plan = try #require(S3DownloadPlan(totalSize: Int64(megabytes) * Self.mebibyte))
            #expect(plan.segmentSize >= S3DownloadLimits.minimumSegmentSize)
            #expect(plan.segmentCount <= S3DownloadLimits.maximumSegments)
        }
    }

    /// The property the assembly rests on: the ranges are contiguous, start at zero, end at the
    /// object's last byte, and no byte is asked for twice.
    @Test("the segments cover every byte once, in order")
    func segmentsCoverTheObject() throws {
        for size in [10, 999, 1000, 1024, 65_536] {
            let plan = try #require(S3DownloadPlan(totalSize: Int64(size), segmentSize: 100))
            var expected: Int64 = 0
            for number in 1...plan.segmentCount {
                let range = try #require(plan.range(ofSegment: number))
                #expect(range.lowerBound == expected)
                expected = range.upperBound
            }
            #expect(expected == Int64(size))
            #expect(plan.range(ofSegment: plan.segmentCount + 1) == nil)
            #expect(plan.range(ofSegment: 0) == nil)
        }
    }

    /// One segment is the plain download in a more expensive spelling — a temp file, an assembly
    /// pass, and no second connection to show for it.
    @Test("nothing under the threshold is worth splitting")
    func thresholdIsTheFork() {
        #expect(!S3DownloadPlan.isWorthwhile(totalSize: 8 * Self.mebibyte))
        #expect(S3DownloadPlan.isWorthwhile(totalSize: 8 * Self.mebibyte + 1))
        #expect(!S3DownloadPlan.isWorthwhile(totalSize: 0))
    }

    /// HTTP's `Range` is **inclusive at both ends** where the Swift range is half-open. One
    /// character, and it is the difference between a correct assembly and a byte missing at every
    /// seam.
    @Test("the header value is inclusive at both ends")
    func headerValueIsInclusive() {
        let segment = S3DownloadSegment(number: 1, localPath: "/tmp/1", range: 0..<1024)
        #expect(segment.headerValue == "0-1023")
        #expect(segment.length == 1024)
        #expect(
            S3DownloadSegment(number: 2, localPath: "/tmp/2", range: 1024..<2048).headerValue
                == "1024-2047"
        )
    }

    // MARK: - What curl is told

    @Test("the invocation runs the sections in parallel, immediately, with the meter off")
    func invocationFlags() {
        #expect(Self.invocation(segments: 3).arguments == [
            "-Z", "--parallel-immediate", "--parallel-max", "3", "-sS", "-K", "-"
        ])
    }

    /// The flag whose absence is silent: without it `curl` runs the first transfer alone before
    /// starting the rest, so a run costs two rounds instead of one and nothing says so.
    @Test("--parallel-immediate is not optional")
    func parallelImmediateIsPresent() {
        #expect(Self.invocation(segments: 8).arguments.contains("--parallel-immediate"))
    }

    @Test("each segment is its own section, with its own credential, range, file and write-out")
    func configurationSections() {
        let sections = Self.invocation(segments: 2).configuration.components(separatedBy: "next\n")
        #expect(sections.count == 2)
        for (index, section) in sections.enumerated() {
            let number = index + 1
            #expect(section.contains("user = \"AKIAEXAMPLE:s3cr3t\""))
            #expect(section.contains("aws-sigv4 = \"aws:amz:eu-north-1:s3\""))
            #expect(section.contains("connect-timeout = 15"))
            #expect(section.contains("max-time = 3600"))
            #expect(section.contains("output = \"/tmp/seg\(number)\""))
            #expect(section.contains("s3-seg\(number)-status="))
            #expect(section.contains(
                "url = \"https://photos.s3.eu-north-1.amazonaws.com/holiday.mov\""
            ))
        }
        #expect(sections[0].contains("range = \"0-99\""))
        #expect(sections[1].contains("range = \"100-199\""))
    }

    /// `fail` is the one flag a transfer carries that a listing must not: without it a refused
    /// section writes the `<Error>` document into the segment's file, and assembly would splice it
    /// into the middle of the user's file.
    @Test("every section fails rather than saving a refusal")
    func everySectionFails() {
        let sections = Self.invocation(segments: 3).configuration.components(separatedBy: "next\n")
        #expect(sections.allSatisfy { $0.contains("fail\n") })
    }

    /// Resume belongs to the single-stream path. A segment is a range request into a file this code
    /// created for it, so there is never a partial to continue from.
    @Test("nothing resumes")
    func nothingResumes() {
        let invocation = Self.invocation(segments: 4)
        #expect(!invocation.arguments.contains("--continue-at"))
        #expect(!invocation.configuration.contains("continue-at"))
    }

    /// The security assertion this project makes of every builder: the secret travels on **stdin**
    /// and is nowhere any `ps` could read it.
    @Test("no secret reaches argv")
    func noSecretInArguments() {
        let invocation = Self.invocation(segments: 4)
        #expect(!invocation.arguments.contains { $0.contains("s3cr3t") })
        #expect(invocation.configuration.contains("s3cr3t"))
    }

    // MARK: - Telling several answers apart on one stream

    /// The shape a real run produces: sections finishing in whatever order the network gives them,
    /// each naming itself.
    private static let capturedStderr = """

    s3-seg3-status=206
    s3-seg3-down=4194304

    s3-seg1-status=206
    s3-seg1-down=4194304

    s3-seg2-status=206
    s3-seg2-down=4194304

    """

    @Test("every segment's answer is read back from the one stream")
    func parsesCapturedRun() throws {
        let reported = S3SegmentWriteOut.parse(stderr: Self.capturedStderr)
        #expect(reported.completedSegments == [1, 2, 3])
        for number in 1...3 {
            let fields = try #require(reported.fields(forSegment: number))
            #expect(fields.status == 206)
            #expect(fields.bytesDownloaded == 4_194_304)
        }
    }

    @Test("a reader fed in arbitrary chunks reads the same thing")
    func parsesChunked() throws {
        var reader = S3SegmentWriteOut()
        var remaining = Substring(Self.capturedStderr)
        while !remaining.isEmpty {
            let end = remaining.index(
                remaining.startIndex,
                offsetBy: 5,
                limitedBy: remaining.endIndex
            ) ?? remaining.endIndex
            reader.consume(String(remaining[..<end]))
            remaining = remaining[end...]
        }
        #expect(reader.completedSegments == [1, 2, 3])
        #expect(reader.fields(forSegment: 2)?.bytesDownloaded == 4_194_304)
    }

    /// A section `curl` never ran prints nothing at all, and that is not a status of 0: the caller
    /// has to tell "the invocation died before this segment" from "this segment was refused".
    @Test("a segment that never ran reports nothing, where a refused one reports its status")
    func missingSegmentIsNotAStatus() throws {
        let reported = S3SegmentWriteOut.parse(stderr: """
        curl: (22) The requested URL returned error: 404

        s3-seg1-status=404
        s3-seg1-down=0
        """)
        #expect(reported.fields(forSegment: 2) == nil)
        let refused = try #require(reported.fields(forSegment: 1))
        #expect(refused.status == 404)
        #expect(refused.bytesDownloaded == 0)
    }

    @Test("curl's own prose on the same stream is ignored")
    func proseIsIgnored() {
        let reported = S3SegmentWriteOut.parse(stderr: """
        curl: (6) Could not resolve host: example.invalid
        s3-status=206
        s3-part1-status=206
        s3-segX-status=206
        not-a-label
        """)
        #expect(reported.completedSegments.isEmpty)
    }

    /// The two indexed readers must not read each other's labels — they share one mechanism and
    /// nothing else, and a batch upload's stream is a batch upload's.
    @Test("the segment reader ignores a part's labels, and the part reader a segment's")
    func readersDoNotCross() {
        #expect(S3SegmentWriteOut.parse(stderr: "\ns3-part1-status=200\n").completedSegments.isEmpty)
        #expect(S3PartWriteOut.parse(stderr: "\ns3-seg1-status=206\n").completedParts.isEmpty)
    }

    // MARK: - Helpers

    private static func invocation(segments count: Int) -> S3ParallelInvocation {
        S3ProcessArguments.downloadSegments(
            session: S3Session(location: location, connectTimeout: 15, maxTime: 3600),
            key: "holiday.mov",
            segments: (1...count).map {
                S3DownloadSegment(
                    number: $0,
                    localPath: "/tmp/seg\($0)",
                    range: Int64($0 - 1) * 100..<Int64($0) * 100
                )
            },
            credentials: S3ConfigFile.credentials(
                accessKeyID: "AKIAEXAMPLE",
                secretAccessKey: "s3cr3t"
            )
        )
    }
}
