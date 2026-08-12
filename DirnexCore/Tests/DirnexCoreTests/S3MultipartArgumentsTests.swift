import Foundation
import Testing

@testable import DirnexCore

/// The `curl` assembly for a multipart upload — the four verbs a file too big for one `PUT` needs.
@Suite("S3 multipart arguments")
struct S3MultipartArgumentsTests {
    private let session = S3Session(
        location: S3Location(
            host: "s3.eu-central-1.amazonaws.com",
            bucket: "photos",
            region: "eu-central-1",
            accessKeyID: "AKIAEXAMPLE"
        )
    )

    /// An upload id is an opaque server-chosen token, so it is the same shape of value as the
    /// continuation token that was *measured* to need encoding — and it fails the same way, for one
    /// server, on one upload, whenever the id happens to carry `/`, `+` or `=`.
    @Test("an upload id is percent-encoded wherever it appears in a query")
    func uploadIDIsEncoded() {
        let raw = "2~mZ8kR9tPq/LxV+3nD4bW5cYgH1jF6sA="
        let invocations = [
            S3ProcessArguments.uploadPart(
                session: session,
                key: "big.bin",
                uploadID: raw,
                partNumber: 3,
                localPath: "/tmp/part.bin"
            ),
            S3ProcessArguments.completeMultipartUpload(
                session: session,
                key: "big.bin",
                uploadID: raw,
                bodyPath: "/tmp/complete.xml"
            ),
            S3ProcessArguments.abortMultipartUpload(
                session: session,
                key: "big.bin",
                uploadID: raw
            )
        ]
        for arguments in invocations {
            let url = try? #require(arguments.last)
            #expect(url?.contains("uploadId=2~mZ8kR9tPq%2FLxV%2B3nD4bW5cYgH1jF6sA%3D") == true)
            #expect(url?.contains(raw) == false)
        }
    }

    @Test("a part is streamed to a numbered URL")
    func uploadPartURL() throws {
        let arguments = S3ProcessArguments.uploadPart(
            session: session,
            key: "docs/big.bin",
            uploadID: "abc",
            partNumber: 7,
            localPath: "/tmp/part.bin"
        )
        // `-T`, so memory stays flat whatever the part size — the measurement the whole slicing
        // design rests on.
        #expect(arguments.contains("--upload-file"))
        #expect(arguments.contains("/tmp/part.bin"))
        let url = try #require(arguments.last)
        #expect(url.contains("partNumber=7"))
        #expect(url.contains("uploadId=abc"))
    }

    @Test("opening and closing an upload aim at the right verbs")
    func multipartVerbs() throws {
        let create = S3ProcessArguments.createMultipartUpload(session: session, key: "docs/big.bin")
        #expect(create.contains("-X"))
        #expect(create.contains("POST"))
        // `--data-binary ""` rather than a bare `-X POST`: it states its own `Content-Length: 0`
        // and a real payload digest instead of falling back to chunked framing.
        #expect(create.contains("--data-binary"))
        #expect(try #require(create.last).hasSuffix("?uploads"))

        let complete = S3ProcessArguments.completeMultipartUpload(
            session: session,
            key: "docs/big.bin",
            uploadID: "abc",
            bodyPath: "/tmp/complete.xml"
        )
        #expect(complete.contains("--data-binary"))
        #expect(complete.contains("@/tmp/complete.xml"))
        // No `Content-MD5`: S3 requires that on `DeleteObjects` and not on this verb.
        #expect(!complete.contains { $0.hasPrefix("Content-MD5") })

        let abort = S3ProcessArguments.abortMultipartUpload(
            session: session,
            key: "docs/big.bin",
            uploadID: "abc"
        )
        #expect(abort.contains("DELETE"))
    }

    @Test("a part's ETag comes back through the write-out")
    func writeOutCarriesETag() {
        // `%header{etag}` rather than a `-D -` header dump, which would compete with `--output`.
        #expect(S3WriteOut.format.contains("s3-etag=%header{etag}"))
        let fields = S3WriteOut.parse(
            stderr: "s3-status=200\ns3-up=5242880\ns3-etag=\"f804fb237efd0e539f99f64aa7299653\"\n"
        )
        // Verbatim, quotes included: S3 compares the value byte for byte when it assembles.
        #expect(fields.etag == "\"f804fb237efd0e539f99f64aa7299653\"")
        #expect(fields.bytesUploaded == 5_242_880)
    }
}
