import Foundation
import Testing

@testable import DirnexCore

/// The `curl` assembly for the S3 **write** verbs (PLAN.md §M21).
///
/// Split from `S3ProcessArgumentsTests` by concept rather than to shave lines: that suite is about
/// the query a listing builds and the stream a status comes back on, and this one is about the
/// shapes a probe measured against a live endpoint on 2026-08-13 — each of which is a spelling that
/// works next to one that silently does not.
@Suite("S3 write arguments")
struct S3WriteArgumentsTests {
    private let session = S3Session(
        location: S3Location(
            host: "s3.eu-central-1.amazonaws.com",
            bucket: "photos",
            region: "eu-central-1",
            accessKeyID: "AKIAEXAMPLE"
        )
    )

    // MARK: - The upload counter

    @Test("an upload's byte count comes back on its own field")
    func writeOutReadsTheUploadCounter() {
        let fields = S3WriteOut.parse(stderr: S3Fixtures.uploadStderr)
        #expect(fields.status == 200)
        #expect(fields.bytesUploaded == 3_145_728)
        #expect(fields.bytesDownloaded == 0)
    }

    /// Why the two counters are separate fields rather than one "transferred" number: a refused
    /// upload sends the whole file *and* receives the refusal, so a sum would report a failed
    /// 3 MiB upload as having moved 3 MiB plus the 153-byte `<Error>` document that rejected it.
    @Test("a refused upload reports both directions, so neither can stand for the other")
    func writeOutSeparatesTheDirections() {
        let fields = S3WriteOut.parse(stderr: S3Fixtures.refusedUploadStderr)
        #expect(fields.status == 403)
        #expect(fields.bytesUploaded == 3_145_728)
        #expect(fields.bytesDownloaded == 153)
    }

    @Test("an invocation that uploaded nothing reports zero rather than nothing")
    func writeOutDefaultsTheUploadCounter() {
        let fields = S3WriteOut.parse(stderr: "s3-status=200\n")
        #expect(fields.bytesUploaded == 0)
    }

    // MARK: - Shapes

    /// The shape measured 2026-08-13: `-T` streams (5.3 MB resident for a 512 MiB file, against
    /// 1.08 GB for `--data-binary @`), which is what makes it the only viable upload — and the
    /// reason the request signs `UNSIGNED-PAYLOAD`, since `curl` cannot hash a stream it has not
    /// read.
    @Test("an upload streams the file rather than buffering it")
    func uploadStreams() {
        let arguments = S3ProcessArguments.upload(
            session: session,
            key: "docs/a.txt",
            localPath: "/tmp/a.txt"
        )
        #expect(arguments.contains("--upload-file"))
        #expect(!arguments.contains { $0.hasPrefix("--data-binary") })
        #expect(!arguments.contains { $0.hasPrefix("@") })
    }

    /// `curl` appends the *local* file's basename to a `-T` URL that ends in `/` — measured, and it
    /// writes a real object under a name nobody chose. Nothing in the key translation would catch
    /// it, since the key is right and the URL is what changes.
    @Test("an upload URL never ends in a slash")
    func uploadURLHasNoTrailingSlash() {
        for key in ["docs/a.txt", "a.txt", "deep/nested/name.bin"] {
            let arguments = S3ProcessArguments.upload(
                session: session,
                key: key,
                localPath: "/tmp/x"
            )
            let url = try? #require(arguments.last)
            #expect(url?.hasSuffix("/") == false)
        }
    }

    /// Three spellings of "write nothing" and only one is safe: `-T /dev/null` cannot state a
    /// length so `curl` falls back to chunked with `UNSIGNED-PAYLOAD` (which S3 rejects outright),
    /// and a bare `-X PUT` sends no `Content-Length` at all.
    @Test("a zero-byte object states its own emptiness")
    func emptyObjectSendsAnExplicitBody() {
        let arguments = S3ProcessArguments.putEmptyObject(session: session, key: "docs/")
        #expect(arguments.contains("--data-binary"))
        #expect(arguments.contains(""))
        #expect(!arguments.contains("/dev/null"))
        #expect(!arguments.contains("--upload-file"))
    }

    /// The one URL that *may* end in a slash — that trailing slash is the whole content of a folder
    /// marker — and it is safe precisely because `-T` is not involved.
    @Test("a folder marker keeps its trailing slash")
    func markerKeepsItsSlash() throws {
        let arguments = S3ProcessArguments.putEmptyObject(session: session, key: "docs/sub/")
        let url = try #require(arguments.last)
        #expect(url.hasSuffix("/docs/sub/"))
    }

    /// `curl` signs `x-amz-copy-source` (measured: it appears in `SignedHeaders`) but passes the
    /// value through byte for byte, so the encoding is ours. A raw `+` or `#` in a key would name a
    /// different object than the one being renamed.
    @Test("the copy source is bucket-qualified and encoded to the path rule")
    func copySourceIsEncoded() throws {
        let arguments = S3ProcessArguments.copyObject(
            session: session,
            sourceKey: "docs/a b+c#d.txt",
            destinationKey: "docs/renamed.txt"
        )
        let header = try #require(arguments.first { $0.hasPrefix("x-amz-copy-source:") })
        #expect(header == "x-amz-copy-source: /photos/docs/a%20b%2Bc%23d.txt")
        // The slash between components survives; everything reserved does not.
        #expect(header.contains("/docs/"))
    }

    @Test("a batch delete posts its body as a file, with the integrity header S3 requires")
    func batchDeleteShape() throws {
        let arguments = S3ProcessArguments.deleteObjects(
            session: session,
            bodyPath: "/tmp/delete.xml",
            contentMD5: "1B2M2Y8AsgTpgAmY7PhCfg=="
        )
        #expect(arguments.contains("POST"))
        // A file, not inline: 1000 long keys approach ARG_MAX, so an inline body is a batch size
        // that works until somebody's file names are long.
        #expect(arguments.contains("@/tmp/delete.xml"))
        #expect(arguments.contains("Content-MD5: 1B2M2Y8AsgTpgAmY7PhCfg=="))
        let url = try #require(arguments.last)
        #expect(url.hasSuffix("?delete"))
    }

    /// A write's error document is its classification, exactly as a listing's is — and unlike a
    /// download, there is no `--output` file for the refusal to land in, which is the only reason
    /// `--fail` was ever wanted.
    @Test("no write throws away the error document")
    func writesKeepTheErrorBody() {
        let writes = [
            S3ProcessArguments.upload(session: session, key: "a", localPath: "/tmp/a"),
            S3ProcessArguments.putEmptyObject(session: session, key: "a/"),
            S3ProcessArguments.copyObject(session: session, sourceKey: "a", destinationKey: "b"),
            S3ProcessArguments.deleteObject(session: session, key: "a"),
            S3ProcessArguments.deleteObjects(session: session, bodyPath: "/tmp/d", contentMD5: "x")
        ]
        for arguments in writes {
            #expect(!arguments.contains("--fail"))
            #expect(!arguments.contains("--output"))
        }
    }
}
