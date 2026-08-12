import Foundation
import Testing

@testable import DirnexCore

/// The `curl` assembly for S3 — above all that no secret reaches `argv`, and that the query the
/// listing loop builds is the one the probes measured.
@Suite("S3 process arguments")
struct S3ProcessArgumentsTests {
    private let session = S3Session(
        location: S3Location(
            host: "s3.eu-central-1.amazonaws.com",
            bucket: "photos",
            region: "eu-central-1",
            accessKeyID: "AKIAEXAMPLE"
        )
    )

    // MARK: - The security invariant

    @Test("no secret ever reaches argv")
    func secretStaysOffTheCommandLine() {
        let secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        let everyInvocation = [
            S3ProcessArguments.list(session: session, prefix: "docs/"),
            S3ProcessArguments.download(
                session: session,
                key: "docs/a.txt",
                localPath: "/tmp/a.txt",
                resume: true
            ),
            S3ProcessArguments.head(session: session, key: "docs/a.txt")
        ]
        for arguments in everyInvocation {
            #expect(!arguments.contains { $0.contains(secret) })
            // `-u`, `--user` and a `user:pass` URL are the three ways it could leak.
            #expect(!arguments.contains("-u"))
            #expect(!arguments.contains("--user"))
            #expect(arguments.contains("-K"))
        }
    }

    @Test("the credential travels as a stdin config, escaped")
    func configFileEscapesTheSecret() {
        let config = S3ConfigFile.credentials(
            accessKeyID: "AKIAEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG"
        )
        #expect(config == "user = \"AKIAEXAMPLE:wJalrXUtnFEMI/K7MDENG\"\n")
    }

    @Test("a newline in a secret cannot start a second curl directive")
    func configFileRefusesInjection() {
        let config = S3ConfigFile.credentials(
            accessKeyID: "id",
            secretAccessKey: "a\ninsecure\nb\"c\\d"
        )
        // Exactly one physical line: everything that could end the value is escaped.
        #expect(config.split(whereSeparator: \.isNewline).count == 1)
        #expect(config.contains("\\n"))
        #expect(config.contains("\\\""))
        #expect(config.contains("\\\\"))
    }

    // MARK: - Common flags

    @Test("every invocation signs, times out, and reports its status")
    func commonFlags() {
        let arguments = S3ProcessArguments.common(session: session)
        #expect(arguments.contains("--aws-sigv4"))
        #expect(arguments.contains("aws:amz:eu-central-1:s3"))
        #expect(arguments.contains("--connect-timeout"))
        #expect(arguments.contains("--max-time"))
        #expect(arguments.contains(S3WriteOut.format))
    }

    /// Both absences are decisions, and both would look like tidying-up to add: `--fail` throws
    /// away the error document that *is* the classification, and `--location` follows a wrong-region
    /// 301 to a host the signature was not computed for.
    @Test("neither --fail nor --location is ever passed")
    func deliberateOmissions() {
        let arguments = S3ProcessArguments.list(session: session, prefix: "")
            + S3ProcessArguments.download(
                session: session,
                key: "k",
                localPath: "/tmp/k",
                resume: false
            )
        #expect(!arguments.contains("--fail"))
        #expect(!arguments.contains("-f"))
        #expect(!arguments.contains("--location"))
        #expect(!arguments.contains("-L"))
    }

    // MARK: - The listing URL

    @Test("a listing asks for v2, url encoding, and the delimiter")
    func listingQuery() throws {
        let url = try #require(S3ProcessArguments.list(session: session, prefix: "docs/").last)
        #expect(url.hasPrefix("https://photos.s3.eu-central-1.amazonaws.com/?"))
        #expect(url.contains("list-type=2"))
        #expect(url.contains("encoding-type=url"))
        #expect(url.contains("delimiter=%2F"))
        #expect(url.contains("prefix=docs%2F"))
        #expect(!url.contains("continuation-token"))
    }

    @Test("the bucket root asks for no prefix at all")
    func rootListingOmitsPrefix() throws {
        let url = try #require(S3ProcessArguments.list(session: session, prefix: "").last)
        #expect(!url.contains("prefix="))
    }

    @Test("a recursive sweep asks for no delimiter")
    func recursiveListingOmitsDelimiter() throws {
        let url = try #require(
            S3ProcessArguments.list(session: session, prefix: "docs/", delimiter: nil).last
        )
        #expect(!url.contains("delimiter="))
    }

    /// The measured one. A token carrying `+`, `/` or `=` is rejected raw with `InvalidArgument`,
    /// and one that happens to be alphanumeric round-trips raw perfectly — so it fails
    /// intermittently, which is why it is pinned against a real token rather than a made-up one.
    @Test("a continuation token is percent-encoded going back")
    func continuationTokenIsEncoded() throws {
        let url = try #require(
            S3ProcessArguments.list(
                session: session,
                prefix: "",
                continuationToken: S3Fixtures.rootPageToken
            ).last
        )
        #expect(url.contains("continuation-token=1PS1Je8Je9%2BfEnmTJ94R3S298dc9ST1JnbEKoQSuyxjj"))
        #expect(url.hasSuffix("%2Bf1Eg8%3D"))
        #expect(!url.contains("+"))
        #expect(!url.contains("token=1PS1Je8Je9+"))
    }

    @Test("a path-style location puts the bucket in the path")
    func pathStyleListing() throws {
        let minio = S3Session(
            location: S3Location(
                host: "192.168.1.50",
                port: 9000,
                bucket: "photos",
                region: "us-east-1",
                accessKeyID: "minioadmin",
                addressing: .path,
                usesTLS: false
            )
        )
        let url = try #require(S3ProcessArguments.list(session: minio, prefix: "").last)
        #expect(url.hasPrefix("http://192.168.1.50:9000/photos/?"))
    }

    // MARK: - Transfers

    @Test("download resumes only when asked")
    func downloadArguments() {
        let plain = S3ProcessArguments.download(
            session: session,
            key: "a b/c.txt",
            localPath: "/tmp/c.txt",
            resume: false
        )
        #expect(plain.contains("--output"))
        #expect(plain.contains("/tmp/c.txt"))
        #expect(!plain.contains("--continue-at"))
        // The key is encoded into the URL; the local path is a real path and must not be.
        #expect(plain.last == "https://photos.s3.eu-central-1.amazonaws.com/a%20b/c.txt")

        let resumed = S3ProcessArguments.download(
            session: session,
            key: "a.txt",
            localPath: "/tmp/a.txt",
            resume: true
        )
        #expect(resumed.contains("--continue-at"))
    }

    @Test("a head transfers nothing")
    func headArguments() {
        let arguments = S3ProcessArguments.head(session: session, key: "a.txt")
        #expect(arguments.contains("--head"))
        #expect(arguments.contains("/dev/null"))
    }

    // MARK: - Reading the response back

    @Test("the write-out is read off a successful stderr")
    func writeOutParsesSuccess() {
        let fields = S3WriteOut.parse(stderr: S3Fixtures.successStderr)
        #expect(fields.status == 200)
        #expect(fields.bucketRegion == "us-west-2")
        #expect(fields.contentLength == 451)
        #expect(fields.bytesDownloaded == 451)
    }

    /// The reason the fields are labelled: `curl` writes its own prose to the same stream, ahead of
    /// them. A reader that took the first line — or the whole stream — would read "curl: (6) Could
    /// not resolve host" as a status.
    @Test("curl's own error text on the same stream is ignored")
    func writeOutIgnoresCurlProse() {
        let fields = S3WriteOut.parse(stderr: S3Fixtures.failureStderr)
        #expect(fields.status == 0)
        #expect(fields.bucketRegion == nil)
        #expect(fields.contentLength == nil)
        #expect(fields.bytesDownloaded == 0)
    }

    @Test("an absent header reads as absent, not as empty text")
    func writeOutTreatsEmptyFieldsAsAbsent() {
        let fields = S3WriteOut.parse(stderr: "s3-status=200\ns3-region=\ns3-length=\n")
        #expect(fields.status == 200)
        #expect(fields.bucketRegion == nil)
        #expect(fields.contentLength == nil)
    }

    /// The template is passed through `argv` to `curl`, which expands `\n` itself — so the Swift
    /// string has to carry the two characters, not a newline. A literal newline here would make
    /// every field but the first unreadable.
    @Test("the write-out template carries curl's own escape, not a newline")
    func writeOutFormatIsEscaped() {
        #expect(S3WriteOut.format.hasPrefix("%{stderr}"))
        #expect(!S3WriteOut.format.contains("\n"))
        #expect(S3WriteOut.format.contains("\\n"))
    }
}
