import Foundation
import Testing

@testable import DirnexCore

/// Every `curl` the FTP and S3 backends build starts with `-q`, so a user's `~/.curlrc` never
/// reaches a request. Measured 2026-10-23 with the system `curl` 8.7.1: a `.curlrc` holding
/// `--head` turned a GET into a HEAD that downloaded nothing and still exited 0, and `-q` only
/// worked as the **first** argument (``FTPProcessArguments/ignoreCurlrc``). So the assertion is on
/// `first`, not on `contains`: `-q` anywhere else is as good as absent. WebDAV's half is pinned in
/// `WebDAVProcessArgumentsTests`.
///
/// Enumerated by hand, like the credential tests beside it — a builder added without a line here
/// is one this suite silently stops covering.
@Suite("curl never reads ~/.curlrc")
struct CurlrcIsolationTests {
    /// The session with every optional flag on — TLS, a pin, the 1.2 retry and the IPv4 dial — so
    /// nothing a builder appends conditionally can end up ahead of `-q`.
    private static let ftp = FTPSession(
        location: FTPLocation(host: "nas.local", username: "sa", security: .explicit),
        dial: DialedHost(host: "nas.local", restrictsToIPv4: true),
        trust: .pinned(publicKey: "AAAA"),
        tls: .forceTLS12
    )

    private static let s3 = S3Session(
        location: S3Location(
            host: "s3.eu-central-1.amazonaws.com",
            bucket: "photos",
            region: "eu-central-1",
            accessKeyID: "AKIAEXAMPLE"
        )
    )

    private static let account = S3Account(
        host: "s3.amazonaws.com",
        region: "us-east-1",
        accessKeyID: "k"
    )

    private static let segments = (1...3).map {
        DownloadSegment(
            number: $0,
            localPath: "/tmp/seg\($0)",
            range: Int64($0 - 1) * 100..<Int64($0) * 100
        )
    }

    // MARK: - FTP

    @Test("every single FTP invocation starts with -q")
    func ftpInvocations() {
        let all = [
            FTPProcessArguments.list(session: Self.ftp, remotePath: "/pub"),
            FTPProcessArguments.download(
                session: Self.ftp, remotePath: "/a.bin", localPath: "/tmp/a", resume: true
            ),
            // The one that turns the meter on, and so the one whose first flag is `-S`, not `-sS`.
            FTPProcessArguments.upload(
                session: Self.ftp, localPath: "/tmp/a", remotePath: "/a.bin", resume: true
            ),
            FTPProcessArguments.createFile(
                session: Self.ftp, localPath: "/tmp/empty", remotePath: "/new.txt", append: true
            ),
            FTPProcessArguments.head(session: Self.ftp, remotePath: "/a.bin"),
            FTPProcessArguments.quote(session: Self.ftp, commands: ["MKD /x"])
        ]
        for arguments in all {
            #expect(arguments.first == "-q")
            #expect(arguments.count(where: { $0 == "-q" }) == 1)
        }
    }

    /// The probe assembles its own flags rather than going through `common`, so it is the one most
    /// likely to be left behind.
    @Test("the FTPS certificate probe starts with -q")
    func ftpCertificateProbe() {
        #expect(FTPProcessArguments.certificateProbe(session: Self.ftp).first == "-q")
    }

    /// A batch's options live in its stdin config, where `disable` does nothing (measured), so `-q`
    /// has to be in `argv` — and without it `curl` applied the `.curlrc` to the first section only.
    @Test("FTP's batched listings start with -q, and leave it out of the config")
    func ftpBatches() {
        let credentials = "user = \"sa:secret\"\n"
        let all = [
            FTPProcessArguments.listDirectories(
                session: Self.ftp,
                requests: [
                    FTPListingRequest(
                        remotePath: "/a",
                        outputPath: "/tmp/a",
                        factsOutputPath: "/tmp/fa"
                    ),
                    FTPListingRequest(remotePath: "/b", outputPath: "/tmp/b")
                ],
                credentials: credentials
            ),
            FTPProcessArguments.listingWithFacts(
                session: Self.ftp,
                remotePath: "/pub",
                rowsOutput: "/tmp/rows",
                factsOutput: "/tmp/facts",
                credentials: credentials
            )
        ]
        for invocation in all {
            #expect(invocation.arguments.first == "-q")
            #expect(!invocation.configuration.contains("disable"))
        }
    }

    @Test("FTP's segmented download starts with -q, ahead of -Z")
    func ftpSegments() {
        let invocation = FTPProcessArguments.downloadSegments(
            session: Self.ftp,
            remotePath: "/clip.mov",
            segments: Self.segments,
            credentials: "user = \"sa:secret\"\n"
        )
        #expect(invocation.arguments.first == "-q")
    }

    // MARK: - S3

    @Test("every single S3 object invocation starts with -q")
    func s3Invocations() {
        let all = [
            S3ProcessArguments.list(session: Self.s3, prefix: "docs/"),
            S3ProcessArguments.download(
                session: Self.s3, key: "docs/a.txt", localPath: "/tmp/a.txt", resume: true
            ),
            S3ProcessArguments.head(session: Self.s3, key: "docs/a.txt"),
            S3ProcessArguments.upload(session: Self.s3, key: "docs/a.txt", localPath: "/tmp/a.txt"),
            S3ProcessArguments.putEmptyObject(session: Self.s3, key: "docs/"),
            S3ProcessArguments.copyObject(
                session: Self.s3, sourceKey: "docs/a.txt", destinationKey: "docs/b.txt"
            ),
            S3ProcessArguments.deleteObject(session: Self.s3, key: "docs/a.txt"),
            S3ProcessArguments.deleteObjects(
                session: Self.s3, bodyPath: "/tmp/delete.xml",
                contentMD5: "1B2M2Y8AsgTpgAmY7PhCfg=="
            ),
            S3ProcessArguments.createMultipartUpload(session: Self.s3, key: "docs/big.bin"),
            S3ProcessArguments.uploadPart(
                session: Self.s3, key: "docs/big.bin", uploadID: "u", partNumber: 2,
                localPath: "/tmp/part.bin"
            ),
            S3ProcessArguments.completeMultipartUpload(
                session: Self.s3, key: "docs/big.bin", uploadID: "u", bodyPath: "/tmp/complete.xml"
            ),
            S3ProcessArguments.abortMultipartUpload(
                session: Self.s3,
                key: "docs/big.bin",
                uploadID: "u"
            )
        ]
        for arguments in all {
            #expect(arguments.first == "-q")
            #expect(arguments.count(where: { $0 == "-q" }) == 1)
        }
    }

    @Test("every S3 account invocation starts with -q")
    func s3AccountInvocations() {
        let all = [
            S3ProcessArguments.listBuckets(account: Self.account),
            S3ProcessArguments.createBucket(account: Self.account, name: "photos"),
            S3ProcessArguments.deleteBucket(account: Self.account, name: "photos"),
            S3ProcessArguments.headBucket(account: Self.account, name: "photos")
        ]
        for arguments in all {
            #expect(arguments.first == "-q")
        }
    }

    @Test("S3's parallel runs start with -q, ahead of -Z")
    func s3Parallel() {
        let credentials = S3ConfigFile.credentials(
            accessKeyID: "AKIAEXAMPLE",
            secretAccessKey: "s3cr3t"
        )
        let all = [
            S3ProcessArguments.uploadParts(
                session: Self.s3,
                parts: (1...3).map {
                    S3PartRequest(localPath: "/tmp/s\($0)", key: "k", uploadID: "u", number: $0)
                },
                credentials: credentials
            ),
            S3ProcessArguments.downloadSegments(
                session: Self.s3, key: "holiday.mov", segments: Self.segments,
                credentials: credentials
            )
        ]
        for invocation in all {
            #expect(invocation.arguments.first == "-q")
            #expect(!invocation.configuration.contains("disable"))
        }
    }
}
