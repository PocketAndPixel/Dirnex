import Foundation
import Testing

@testable import DirnexCore

/// The backend end-to-end against a fake transport fed real bucket bytes: the pagination loop, the
/// stat rule, and the classification that reads a refusal out of a response `curl` called a
/// success.
@Suite("S3 backend")
struct S3BackendTests {
    private let location = S3Location(
        host: "s3.us-east-1.amazonaws.com",
        bucket: "1000genomes",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private func backend(
        _ transport: FakeS3Transport,
        pageLimit: Int = 1000
    ) -> S3Backend {
        S3Backend(location: location, transport: transport, pageLimit: pageLimit)
    }

    private var root: VFSPath { VFSPath(backend: .s3(location), path: "/") }

    // MARK: - Listing

    @Test("a listing renders folders and files from real bytes")
    func listsOnePage() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.finalPage)]
        let entries = try backend(transport).listDirectory(at: root)

        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.name == "CHANGELOG")
        #expect(entry.kind == .file)
        #expect(entry.byteSize == 257_098)
        #expect(entry.path == VFSPath(backend: .s3(location), path: "/CHANGELOG"))
        #expect(transport.listRequests == [
            .init(prefix: "", delimiter: "/", continuationToken: nil)
        ])
    }

    @Test("a directory listing asks for its key plus the delimiter")
    func listingPrefixCarriesTheDelimiter() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.finalPage)]
        _ = try backend(transport).listDirectory(
            at: VFSPath(backend: .s3(location), path: "/docs")
        )
        #expect(transport.listRequests.first?.prefix == "docs/")
    }

    @Test("a truncated page is followed with the token the server gave")
    func paginates() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.rootPage), .ok(S3Fixtures.finalPage)]
        let entries = try backend(transport).listDirectory(at: root)

        // Page one's folder and file, then page two's file.
        #expect(
            entries.map(\.name) == [
                "1000G_2504_high_coverage",
                "20131219.populations.tsv",
                "CHANGELOG"
            ]
        )
        #expect(entries.first?.kind == .directory)
        #expect(transport.listRequests.count == 2)
        #expect(transport.listRequests.last?.continuationToken == S3Fixtures.rootPageToken)
    }

    /// A server that hands back a token it already gave is disagreeing with itself, and the loop
    /// would otherwise spin forever against it. Loud, not quiet — a listing that stops silently
    /// would report a folder as smaller than it is.
    @Test("a repeated continuation token fails instead of spinning")
    func refusesANonAdvancingToken() {
        let transport = FakeS3Transport()
        // One page, repeated: the fake keeps handing out the last fixture.
        transport.listPages = [.ok(S3Fixtures.rootPage)]
        #expect(throws: VFSError.io(path: root, code: EIO)) {
            _ = try backend(transport).listDirectory(at: root)
        }
        // It asked exactly twice: once, then once more with the token, and then gave up.
        #expect(transport.listRequests.count == 2)
    }

    @Test("a listing past the page limit fails rather than truncating")
    func refusesAnUnboundedListing() {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.rootPage)]
        #expect(throws: VFSError.io(path: root, code: EFBIG)) {
            _ = try backend(transport, pageLimit: 1).listDirectory(at: root)
        }
    }

    /// The other side of the same guard: a listing that ends *on* the limit is not over it. Without
    /// this, an off-by-one would refuse the largest folder that legitimately fits.
    @Test("a listing that ends exactly on the page limit succeeds")
    func acceptsAListingAtTheLimit() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.rootPage), .ok(S3Fixtures.finalPage)]
        let entries = try backend(transport, pageLimit: 2).listDirectory(at: root)
        #expect(entries.count == 3)
    }

    // MARK: - Stat

    @Test("a file is stat'ed in one request")
    func statsAFile() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.statFile)]
        let path = VFSPath(backend: .s3(location), path: "/CHANGELOG")
        let entry = try backend(transport).stat(at: path)

        #expect(entry.kind == .file)
        #expect(entry.byteSize == 257_098)
        #expect(entry.path == path)
        #expect(transport.listRequests == [
            .init(prefix: "CHANGELOG", delimiter: "/", continuationToken: nil)
        ])
    }

    /// The trap the real bytes exist for: `prefix=README` returns `README.alignment_data` and
    /// friends and no `README`. A first-row reading would report a sibling's 15 977 bytes under the
    /// name that was asked about — a plausible answer about the wrong file.
    @Test("a prefix that matches only siblings is not found")
    func statRefusesASiblingMatch() {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.statAmbiguous), .ok(S3Fixtures.statMissing)]
        let path = VFSPath(backend: .s3(location), path: "/README")
        #expect(throws: VFSError.notFound(path)) {
            _ = try backend(transport).stat(at: path)
        }
    }

    @Test("a folder is stat'ed from its common prefix")
    func statsAFolder() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.statFolder)]
        let path = VFSPath(backend: .s3(location), path: "/LOCA")
        let entry = try backend(transport).stat(at: path)

        #expect(entry.kind == .directory)
        #expect(entry.name == "LOCA")
        #expect(transport.listRequests.count == 1)
    }

    /// A folder whose siblings fill the first page: `/` is 0x2F, so `docs.txt` and `docs-old` sort
    /// ahead of the `docs/` group. One extra request settles it rather than reporting "not found"
    /// for a folder that is plainly there.
    @Test("a folder pushed off a truncated first page is still found")
    func statFallsBackForATruncatedPage() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.statAmbiguous), .ok(S3Fixtures.finalPage)]
        let path = VFSPath(backend: .s3(location), path: "/README")
        let entry = try backend(transport).stat(at: path)

        #expect(entry.kind == .directory)
        #expect(transport.listRequests.map(\.prefix) == ["README", "README/"])
    }

    @Test("the bucket root asks the server nothing")
    func statsTheRoot() throws {
        let transport = FakeS3Transport()
        let entry = try backend(transport).stat(at: root)
        #expect(entry.kind == .directory)
        #expect(entry.name == "1000genomes")
        #expect(transport.listRequests.isEmpty)
    }

    @Test("a path belonging to another connection never reaches the wire")
    func refusesAForeignPath() {
        let transport = FakeS3Transport()
        let foreign = VFSPath(backend: .local, path: "/etc/passwd")
        #expect(throws: (any Error).self) {
            _ = try backend(transport).listDirectory(at: foreign)
        }
        #expect(transport.listRequests.isEmpty)
    }

    // MARK: - Classification

    /// `curl` exits 0 for all of these, so the status and the `<Code>` are the only classification
    /// there is. This is the inverse of the FTP rule and the single most expensive thing to get
    /// backwards: read the exit code and every S3 failure reads as success.
    @Test(
        "a refusal curl called a success is classified from the response",
        arguments: [
            (403, S3Fixtures.invalidAccessKey, "permissionDenied"),
            (404, "<Error><Code>NoSuchKey</Code></Error>", "notFound"),
            (301, S3Fixtures.wrongRegion, "io")
        ]
    )
    func classifiesServiceErrors(status: Int, body: String, expected: String) {
        let transport = FakeS3Transport()
        transport.listPages = [S3Response(status: status, body: Data(body.utf8))]
        let outcome: String
        do {
            _ = try backend(transport).listDirectory(at: root)
            outcome = "success"
        } catch VFSError.permissionDenied {
            outcome = "permissionDenied"
        } catch VFSError.notFound {
            outcome = "notFound"
        } catch VFSError.io {
            outcome = "io"
        } catch {
            outcome = "\(error)"
        }
        #expect(outcome == expected)
    }

    @Test("a request that never reached a server is plain I/O")
    func classifiesTransportFailure() {
        let transport = FakeS3Transport()
        transport.thrownError = .transport(.couldNotResolveHost)
        #expect(throws: VFSError.io(path: root, code: EIO)) {
            _ = try backend(transport).listDirectory(at: root)
        }
    }

    @Test("a 200 that is not a listing is I/O, not an empty folder")
    func refusesANonListingBody() {
        let transport = FakeS3Transport()
        transport.listPages = [.ok("<html><body>Sign in to the hotel wifi</body></html>")]
        #expect(throws: VFSError.io(path: root, code: EIO)) {
            _ = try backend(transport).listDirectory(at: root)
        }
    }

    @Test("the wrong-region redirect hands back the region that would have worked")
    func surfacesTheCorrectRegion() throws {
        let fromHeader = S3Response(
            status: 301,
            body: Data(S3Fixtures.wrongRegion.utf8),
            bucketRegion: "us-west-2"
        )
        let service = try #require(S3Backend.serviceError(from: fromHeader))
        #expect(service.isRegionRedirect)
        #expect(service.correctedRegion == "us-west-2")

        // A server that sends no header: the endpoint element is the fallback, and it is spelled
        // with a dash and prefixed with the bucket.
        let fromBody = S3Response(status: 301, body: Data(S3Fixtures.wrongRegion.utf8))
        let derived = try #require(S3Backend.serviceError(from: fromBody))
        #expect(derived.correctedRegion == "us-west-2")
    }

    @Test("a success is not an error")
    func successIsNotAnError() {
        #expect(S3Backend.serviceError(from: .ok(S3Fixtures.finalPage)) == nil)
        // A resumed download answers 206, which is a success. Reading `== 200` breaks exactly the
        // users whose transfer was interrupted once.
        #expect(S3Backend.serviceError(from: S3Response(status: 206)) == nil)
    }
}
