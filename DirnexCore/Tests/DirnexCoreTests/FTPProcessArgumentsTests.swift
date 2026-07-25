import Foundation
import Testing

@testable import DirnexCore

@Suite("FTPProcessArguments")
struct FTPProcessArgumentsTests {
    private let plain = FTPLocation(host: "nas.local", username: "sa", security: .plain)
    private let explicitTLS = FTPLocation(host: "nas.local", username: "sa", security: .explicit)
    private let implicitTLS = FTPLocation(host: "nas.local", username: "sa", security: .implicit)

    private func session(
        _ location: FTPLocation,
        trust: FTPTrust = .systemDefault,
        tls: FTPTLSCompatibility = .negotiate
    ) -> FTPSession {
        FTPSession(location: location, trust: trust, tls: tls)
    }

    // MARK: - The credential never reaches argv

    /// The single most important assertion in this file. `-u user:pass` would be readable by any
    /// `ps` on the machine, which is why the credential travels on stdin instead.
    @Test("no builder ever places a credential in the arguments")
    func credentialsNeverAppearInArguments() {
        let secret = "hunter2"
        let all: [[String]] = [
            FTPProcessArguments.list(session: session(explicitTLS), remotePath: "/pub"),
            FTPProcessArguments.download(
                session: session(explicitTLS), remotePath: "/a.bin", localPath: "/tmp/a",
                resume: true
            ),
            FTPProcessArguments.upload(
                session: session(explicitTLS), localPath: "/tmp/a", remotePath: "/a.bin",
                resume: false
            ),
            FTPProcessArguments.head(session: session(explicitTLS), remotePath: "/a.bin"),
            FTPProcessArguments.quote(session: session(explicitTLS), commands: ["MKD /x"]),
            FTPProcessArguments.certificateProbe(session: session(explicitTLS))
        ]
        for arguments in all {
            #expect(!arguments.contains { $0.contains(secret) })
            #expect(!arguments.contains { $0.contains("sa:") })
            #expect(!arguments.contains("-u"))
            #expect(!arguments.contains("--user"))
            // Every one reads its credential from stdin instead.
            #expect(arguments.contains("-K"))
        }
    }

    // MARK: - The trust invariant

    /// `--insecure` without a pin is the exact thing PLAN.md §M13 forbids ("never a blanket 'don't
    /// verify'"), so it is asserted directly rather than left to review.
    @Test("verification is never suppressed without a pin to replace it")
    func insecureIsNeverEmittedAlone() {
        for location in [plain, explicitTLS, implicitTLS] {
            let arguments = FTPProcessArguments.list(
                session: session(location), remotePath: "/"
            )
            #expect(!arguments.contains("--insecure"))
            #expect(!arguments.contains("-k"))
        }
    }

    @Test("a pinned key suppresses store verification and pins, together")
    func pinnedTrustEmitsBothFlags() {
        let arguments = FTPProcessArguments.list(
            session: session(explicitTLS, trust: .pinned(publicKey: "ABC123=")),
            remotePath: "/"
        )
        #expect(arguments.contains("--insecure"))
        let index = try? #require(arguments.firstIndex(of: "--pinnedpubkey"))
        #expect(index != nil)
        #expect(arguments.contains("sha256//ABC123="))
    }

    @Test("a pin on a plain-FTP location is ignored — there is no TLS to pin")
    func pinIsIgnoredWithoutTLS() {
        let arguments = FTPProcessArguments.list(
            session: session(plain, trust: .pinned(publicKey: "ABC123=")),
            remotePath: "/"
        )
        #expect(!arguments.contains("--insecure"))
        #expect(!arguments.contains("--pinnedpubkey"))
    }

    // MARK: - Security modes

    @Test("explicit FTPS requires the upgrade; implicit uses the ftps:// scheme; plain does neither")
    func securityModeFlags() {
        let explicitArguments = FTPProcessArguments.list(
            session: session(explicitTLS),
            remotePath: "/"
        )
        // `--ssl-reqd`, not `--ssl`: the latter continues in cleartext when the server declines,
        // which would hand the password to a downgrade.
        #expect(explicitArguments.contains("--ssl-reqd"))
        #expect(explicitArguments.last?.hasPrefix("ftp://") == true)

        let implicitArguments = FTPProcessArguments.list(
            session: session(implicitTLS),
            remotePath: "/"
        )
        #expect(!implicitArguments.contains("--ssl-reqd"))
        #expect(implicitArguments.last?.hasPrefix("ftps://") == true)

        let plainArguments = FTPProcessArguments.list(session: session(plain), remotePath: "/")
        #expect(!plainArguments.contains("--ssl-reqd"))
        #expect(plainArguments.last?.hasPrefix("ftp://") == true)
    }

    @Test("default ports follow the security mode")
    func defaultPortsFollowSecurityMode() {
        #expect(FTPLocation(host: "h", username: "u", security: .plain).port == 21)
        #expect(FTPLocation(host: "h", username: "u", security: .explicit).port == 21)
        #expect(FTPLocation(host: "h", username: "u", security: .implicit).port == 990)
    }

    // MARK: - The TLS 1.2 workaround

    /// The workaround must stay *opt-in*: applying it up front would downgrade every server that
    /// negotiates TLS 1.3 correctly. The transport arms it only after seeing exit 18.
    @Test("TLS is negotiated freely by default and pinned to 1.2 only when asked")
    func tlsCompatibilityIsOptIn() {
        let negotiated = FTPProcessArguments.list(session: session(explicitTLS), remotePath: "/")
        #expect(!negotiated.contains("--tls-max"))
        #expect(!negotiated.contains("--tlsv1.2"))

        let pinned = FTPProcessArguments.list(
            session: session(explicitTLS, tls: .forceTLS12), remotePath: "/"
        )
        #expect(pinned.contains("--tlsv1.2"))
        #expect(pinned.contains("--tls-max"))
        #expect(pinned.contains("1.2"))
    }

    @Test("the TLS workaround is not emitted for a plain-FTP session")
    func tlsWorkaroundNeedsTLS() {
        let arguments = FTPProcessArguments.list(
            session: session(plain, tls: .forceTLS12),
            remotePath: "/"
        )
        #expect(!arguments.contains("--tls-max"))
    }

    // MARK: - URLs

    @Test("a listing URL ends in a slash so the server sends LIST, not the file of that name")
    func listingURLHasTrailingSlash() {
        let arguments = FTPProcessArguments.list(session: session(plain), remotePath: "/pub/docs")
        #expect(arguments.last == "ftp://nas.local:21/pub/docs/")
    }

    @Test("a download URL has no trailing slash added")
    func downloadURLIsExact() {
        let arguments = FTPProcessArguments.download(
            session: session(plain), remotePath: "/pub/a.bin", localPath: "/tmp/a.bin",
            resume: false
        )
        #expect(arguments.last == "ftp://nas.local:21/pub/a.bin")
    }

    /// A name is percent-encoded more aggressively than `urlPathAllowed` would: `;` would otherwise
    /// be read as FTP's `;type=a` URL suffix and `#` as a fragment, either of which changes *which
    /// file* is fetched.
    @Test("awkward characters in a name are percent-encoded, slashes are not")
    func percentEncodingIsStrict() {
        #expect(FTPProcessArguments.percentEncoded("/pub/my report.txt") == "/pub/my%20report.txt")
        #expect(FTPProcessArguments.percentEncoded("/pub/a;type=a") == "/pub/a%3Btype%3Da")
        #expect(FTPProcessArguments.percentEncoded("/pub/a#b") == "/pub/a%23b")
        #expect(FTPProcessArguments.percentEncoded("/pub/a?b") == "/pub/a%3Fb")
        #expect(FTPProcessArguments.percentEncoded("/a/b/c.txt") == "/a/b/c.txt")
        #expect(FTPProcessArguments.percentEncoded("/pub/quote'name.txt") == "/pub/quote%27name.txt")
    }

    // MARK: - Transfers

    @Test("resume adds --continue-at - in both directions and is absent otherwise")
    func resumeFlag() {
        let resumedDownload = FTPProcessArguments.download(
            session: session(plain), remotePath: "/a.bin", localPath: "/tmp/a", resume: true
        )
        #expect(resumedDownload.contains("--continue-at"))
        #expect(resumedDownload.contains("-"))

        let freshDownload = FTPProcessArguments.download(
            session: session(plain), remotePath: "/a.bin", localPath: "/tmp/a", resume: false
        )
        #expect(!freshDownload.contains("--continue-at"))

        let resumedUpload = FTPProcessArguments.upload(
            session: session(plain), localPath: "/tmp/a", remotePath: "/a.bin", resume: true
        )
        #expect(resumedUpload.contains("--continue-at"))
    }

    @Test("transfers ask curl for the exact byte count they moved")
    func transfersRequestTheirByteCount() {
        let download = FTPProcessArguments.download(
            session: session(plain), remotePath: "/a.bin", localPath: "/tmp/a", resume: false
        )
        #expect(download.contains("%{size_download}"))

        let upload = FTPProcessArguments.upload(
            session: session(plain), localPath: "/tmp/a", remotePath: "/a.bin", resume: false
        )
        #expect(upload.contains("%{size_upload}"))
    }

    @Test("the certificate probe transfers nothing and asks only for the chain")
    func certificateProbeIsInert() {
        let arguments = FTPProcessArguments.certificateProbe(session: session(explicitTLS))
        #expect(arguments.contains("%{certs}"))
        #expect(arguments.contains("--insecure")) // safe: it fetches no data, only the certificate
        #expect(arguments.contains("/dev/null"))
        #expect(!arguments.contains("--pinnedpubkey"))
    }

    @Test("quote commands ride in order on one connection")
    func quoteCommandsPreserveOrder() {
        let arguments = FTPProcessArguments.quote(
            session: session(plain), commands: ["RNFR /a", "RNTO /b"]
        )
        let first = try? #require(arguments.firstIndex(of: "RNFR /a"))
        let second = try? #require(arguments.firstIndex(of: "RNTO /b"))
        #expect(first != nil && second != nil)
        if let first, let second { #expect(first < second) }
    }
}

@Suite("FTPConfigFile")
struct FTPConfigFileTests {
    @Test("a plain credential is quoted as user:password")
    func plainCredential() {
        let location = FTPLocation(host: "nas.local", username: "sa", security: .explicit)
        #expect(FTPConfigFile.credentials(for: location, password: "123") == "user = \"sa:123\"\n")
    }

    /// Probed live: an unescaped newline makes `curl` read the rest of the value as further config
    /// directives and abort. So this is an injection guard, not formatting.
    @Test("every character that could end the value or start a directive is escaped")
    func escapesInjectionCharacters() {
        let location = FTPLocation(host: "nas.local", username: "sa", security: .explicit)
        let config = FTPConfigFile.credentials(for: location, password: "a\"b\\c\nd\re\tf")
        #expect(config == "user = \"sa:a\\\"b\\\\c\\nd\\re\\tf\"\n")
        // The escaped form contains no raw newline other than the terminating one.
        #expect(config.filter { $0 == "\n" }.count == 1)
    }

    @Test("a quote in the username is escaped too")
    func escapesUsername() {
        let location = FTPLocation(host: "nas.local", username: "a\"b", security: .plain)
        let config = FTPConfigFile.credentials(for: location, password: "x")
        #expect(config == "user = \"a\\\"b:x\"\n")
    }

    @Test("anonymous ignores any stored password and sends the conventional one")
    func anonymousUsesConventionalPassword() {
        let location = FTPLocation(host: "ftp.example.org", username: "anonymous", security: .plain)
        let config = FTPConfigFile.credentials(for: location, password: "should-be-ignored")
        #expect(config == "user = \"anonymous:\(FTPConfigFile.anonymousPassword)\"\n")
        #expect(!config.contains("should-be-ignored"))
    }
}

@Suite("FTPQuoteCommand")
struct FTPQuoteCommandTests {
    @Test("builds the verbs with their raw path argument")
    func buildsVerbs() throws {
        #expect(try FTPQuoteCommand.makeDirectory("/pub/new") == "MKD /pub/new")
        #expect(try FTPQuoteCommand.removeDirectory("/pub/old") == "RMD /pub/old")
        #expect(try FTPQuoteCommand.removeFile("/pub/a.txt") == "DELE /pub/a.txt")
    }

    @Test("a path with spaces needs no quoting — FTP takes the rest of the line")
    func spacesNeedNoQuoting() throws {
        #expect(try FTPQuoteCommand.removeFile("/pub/my report.txt") == "DELE /pub/my report.txt")
    }

    @Test("rename emits RNFR then RNTO, in that order")
    func renameEmitsThePair() throws {
        #expect(try FTPQuoteCommand.rename("/a", to: "/b") == ["RNFR /a", "RNTO /b"])
    }

    /// FTP has no quoting mechanism at all, so a CR or LF in a name would terminate the command and
    /// start another one — `DELE a\r\nDELE important.txt` is two deletes. There is nothing to escape
    /// it with, so it is refused. Neither POSIX nor Windows permits these in a name, so nothing
    /// legitimate is lost.
    @Test("a path containing CR, LF or NUL is refused rather than sanitized")
    func rejectsCommandInjection() {
        #expect(throws: FTPQuoteCommand.UnsafePath.self) {
            try FTPQuoteCommand.removeFile("/pub/a\r\nDELE /pub/important.txt")
        }
        #expect(throws: FTPQuoteCommand.UnsafePath.self) {
            try FTPQuoteCommand.makeDirectory("/pub/a\nMKD /elsewhere")
        }
        #expect(throws: FTPQuoteCommand.UnsafePath.self) {
            try FTPQuoteCommand.removeDirectory("/pub/a\0b")
        }
        #expect(throws: FTPQuoteCommand.UnsafePath.self) {
            try FTPQuoteCommand.removeFile("")
        }
    }

    @Test("an injection attempt in either half of a rename is refused")
    func rejectsInjectionInRename() {
        #expect(throws: FTPQuoteCommand.UnsafePath.self) {
            try FTPQuoteCommand.rename("/a\r\nDELE /x", to: "/b")
        }
        #expect(throws: FTPQuoteCommand.UnsafePath.self) {
            try FTPQuoteCommand.rename("/a", to: "/b\r\nDELE /x")
        }
    }
}
