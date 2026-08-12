import Foundation
import Testing

@testable import DirnexCore

@Suite("S3 multipart planning")
struct S3MultipartPlanTests {
    // MARK: - The single-PUT fork

    @Test("a file at or below the threshold is not worth cutting up")
    func smallFileStaysOnePut() {
        #expect(!S3MultipartPlan.isWorthwhile(totalSize: 0))
        #expect(!S3MultipartPlan.isWorthwhile(totalSize: 1))
        #expect(!S3MultipartPlan.isWorthwhile(totalSize: S3MultipartLimits.multipartThreshold))
    }

    @Test("a file over the threshold is")
    func largeFileGoesMultipart() {
        #expect(S3MultipartPlan.isWorthwhile(totalSize: S3MultipartLimits.multipartThreshold + 1))
    }

    // MARK: - Ranges

    @Test("parts tile the file exactly, with the remainder in the last one")
    func partsTileTheFile() throws {
        let total: Int64 = 100 * 1024 * 1024
        let plan = try #require(S3MultipartPlan(totalSize: total))

        #expect(plan.partSize == S3MultipartLimits.preferredPartSize)
        #expect(plan.partCount == 7) // 6 × 16 MiB + 4 MiB

        var covered: Int64 = 0
        var expectedStart: Int64 = 0
        for number in 1...plan.partCount {
            let range = try #require(plan.range(ofPart: number))
            // Contiguous: each part begins exactly where the previous one ended, so no byte is sent
            // twice and none is skipped — the two ways an assembled object goes wrong silently.
            #expect(range.lowerBound == expectedStart)
            expectedStart = range.upperBound
            covered += range.upperBound - range.lowerBound
        }
        #expect(covered == total)
        #expect(plan.length(ofPart: plan.partCount) == 4 * 1024 * 1024)
    }

    @Test("a part number outside the plan has no range")
    func outOfRangePartNumber() throws {
        let plan = try #require(S3MultipartPlan(totalSize: 100 * 1024 * 1024))
        #expect(plan.range(ofPart: 0) == nil)
        #expect(plan.range(ofPart: plan.partCount + 1) == nil)
        #expect(plan.length(ofPart: 0) == 0)
    }

    @Test("a file that is one byte over the threshold is still two parts at most")
    func justOverThreshold() throws {
        let plan = try #require(
            S3MultipartPlan(totalSize: S3MultipartLimits.multipartThreshold + 1)
        )
        #expect(plan.partCount == 5) // 64 MiB + 1 byte in 16 MiB parts
        #expect(plan.length(ofPart: 5) == 1)
    }

    // MARK: - Scaling against S3's own limits

    @Test("the part size grows so the part count never passes S3's ceiling")
    func partSizeScalesWithTheFile() throws {
        // Every size a user could plausibly reach, plus the exact ceiling. The claim is the one
        // that makes the whole scheme work: whatever the file, the plan fits inside 10 000 parts
        // and no part is below S3's 5 MiB floor or above its 5 GiB one.
        let sizes: [Int64] = [
            65 * 1024 * 1024,
            1024 * 1024 * 1024,
            50 * 1024 * 1024 * 1024,
            160 * 1024 * 1024 * 1024,
            1024 * 1024 * 1024 * 1024,
            S3MultipartLimits.maximumObjectSize
        ]
        for size in sizes {
            let plan = try #require(S3MultipartPlan(totalSize: size), "no plan for \(size)")
            #expect(
                plan.partCount <= S3MultipartLimits.maximumPartCount,
                "too many parts for \(size)"
            )
            #expect(plan.partCount >= 1)
            #expect(plan.partSize >= S3MultipartLimits.minimumPartSize, "part too small for \(size)")
            #expect(plan.partSize <= S3MultipartLimits.maximumPartSize, "part too large for \(size)")
            // Every part but the last must clear S3's floor; the last is allowed to be short.
            if plan.partCount > 1 {
                #expect(plan.length(ofPart: 1) >= S3MultipartLimits.minimumPartSize)
            }
        }
    }

    @Test("a file past what S3 can hold has no plan at all")
    func beyondTheObjectCeiling() {
        #expect(S3MultipartPlan(totalSize: S3MultipartLimits.maximumObjectSize + 1) == nil)
        #expect(S3MultipartPlan(totalSize: 0) == nil)
        #expect(S3MultipartPlan(totalSize: -1) == nil)
    }

    @Test("a stated part size that would need too many parts is refused")
    func statedPartSizeIsValidated() {
        #expect(S3MultipartPlan(totalSize: 1000, partSize: 0) == nil)
        #expect(S3MultipartPlan(totalSize: 1000, partSize: -5) == nil)
        // 10 001 parts of 1 byte — one over the ceiling.
        #expect(S3MultipartPlan(totalSize: 10_001, partSize: 1) == nil)
        #expect(S3MultipartPlan(totalSize: 10_000, partSize: 1) != nil)
    }
}

@Suite("S3 multipart documents")
struct S3MultipartDocumentTests {
    // MARK: - The manifest

    @Test("the manifest lists parts in ascending order however they were collected")
    func manifestSortsParts() throws {
        let parts = [
            S3UploadedPart(number: 3, etag: "\"ccc\""),
            S3UploadedPart(number: 1, etag: "\"aaa\""),
            S3UploadedPart(number: 2, etag: "\"bbb\"")
        ]
        let xml = try #require(
            String(data: S3MultipartDocument.manifest(parts: parts), encoding: .utf8)
        )

        let first = try #require(xml.range(of: "<PartNumber>1</PartNumber>"))
        let second = try #require(xml.range(of: "<PartNumber>2</PartNumber>"))
        let third = try #require(xml.range(of: "<PartNumber>3</PartNumber>"))
        #expect(first.lowerBound < second.lowerBound)
        #expect(second.lowerBound < third.lowerBound)
    }

    @Test("an ETag reaches the manifest with its quotes intact")
    func manifestKeepsETagQuotes() throws {
        let xml = try #require(
            String(
                data: S3MultipartDocument.manifest(
                    parts: [S3UploadedPart(number: 1, etag: "\"f804fb237efd0e539f99f64aa7299653\"")]
                ),
                encoding: .utf8
            )
        )
        // S3 compares the value byte for byte, so stripping the quotes to tidy it up fails the
        // completion with `InvalidPart` for every part.
        #expect(xml.contains("<ETag>\"f804fb237efd0e539f99f64aa7299653\"</ETag>"))
    }

    @Test("XML metacharacters in an ETag cannot break the document")
    func manifestEscapesETag() throws {
        let xml = try #require(
            String(
                data: S3MultipartDocument.manifest(
                    parts: [S3UploadedPart(number: 1, etag: "a&b<c>")]
                ),
                encoding: .utf8
            )
        )
        #expect(xml.contains("<ETag>a&amp;b&lt;c&gt;</ETag>"))
        // It still parses, which is the claim escaping exists for.
        let parser = XMLParser(data: Data(xml.utf8))
        #expect(parser.parse())
    }

    // MARK: - Reading the answers

    @Test("the upload id comes out of a real initiate response")
    func readsUploadID() {
        #expect(
            S3MultipartDocument.uploadID(from: Data(S3Fixtures.initiateMultipart.utf8))
                == S3Fixtures.initiateUploadID
        )
    }

    @Test("a body that is not an initiate result yields no upload id")
    func refusesWrongInitiateBody() {
        // Without an id there is nothing to upload against and nothing to abort, so proceeding
        // would create parts this code could never clean up.
        #expect(S3MultipartDocument.uploadID(from: Data(S3Fixtures.invalidAccessKey.utf8)) == nil)
        #expect(S3MultipartDocument.uploadID(from: Data()) == nil)
        #expect(S3MultipartDocument.uploadID(from: Data("not xml at all".utf8)) == nil)
    }

    @Test("a completion that really completed reports no failure")
    func completionSuccess() {
        #expect(
            S3MultipartDocument.completionFailure(
                from: Data(S3Fixtures.completeMultipart.utf8),
                status: 200
            ) == nil
        )
    }

    @Test("a completion that failed inside a 200 is caught")
    func completionFailureInside200() throws {
        // The quiet direction: the status says yes and the object does not exist.
        let failure = try #require(
            S3MultipartDocument.completionFailure(
                from: Data(S3Fixtures.completeMultipartFailed.utf8),
                status: 200
            )
        )
        #expect(failure.code == "InternalError")
        #expect(failure.status == 200)
    }

    @Test("an empty or unreadable completion body is not invented into a failure")
    func completionUnreadableBody() {
        #expect(S3MultipartDocument.completionFailure(from: Data(), status: 200) == nil)
        #expect(
            S3MultipartDocument.completionFailure(from: Data("<html>hi</html>".utf8), status: 200)
                == nil
        )
    }
}
