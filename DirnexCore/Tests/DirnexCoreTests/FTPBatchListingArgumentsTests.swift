import Foundation
import Testing

@testable import DirnexCore

/// The `curl` invocation behind FTP's subtree shortcut — several directories listed over **one**
/// connection (docs/HISTORY.md ▸ After M19).
///
/// Every claim here was measured against a real server on 2026-09-01 before any of it was written;
/// the measurements are at
/// ``FTPProcessArguments/listDirectories(session:requests:credentials:)``. What this suite pins is
/// that the invocation still *says* what was measured — most sharply the absence of `-Z`, which no
/// test of the answers could ever see because a parallel run produces the identical listings and
/// merely pays for a login per directory again.
@Suite("FTP batched listing: the request")
struct FTPBatchListingArgumentsTests {
    private static let location = FTPLocation(host: "ftp.example", username: "u")

    private static func session(
        security: FTPSecurity = .plain,
        trust: FTPTrust = .systemDefault,
        tls: FTPTLSCompatibility = .negotiate
    ) -> FTPSession {
        FTPSession(
            location: FTPLocation(host: "ftp.example", username: "u", security: security),
            trust: trust,
            tls: tls,
            connectTimeout: 15,
            maxTime: 30
        )
    }

    private static func invocation(
        _ paths: [String],
        session: FTPSession = session()
    ) -> FTPParallelInvocation {
        FTPProcessArguments.listDirectories(
            session: session,
            requests: paths.enumerated().map {
                FTPListingRequest(remotePath: $1, outputPath: "/tmp/out/\($0)")
            },
            credentials: "user = \"u:secret\"\n"
        )
    }

    // MARK: - The sequential invariant

    /// **The one claim the answers cannot carry.** `-Z` would open a connection per transfer, which
    /// is exactly the per-directory login this exists to avoid — and it would still return every
    /// listing correctly, so only the argv can say the run is sequential.
    @Test("the run is sequential — no -Z, and nothing that implies it")
    func theRunIsSequential() {
        let arguments = Self.invocation(["/a", "/b", "/c"]).arguments
        #expect(!arguments.contains("-Z"))
        #expect(!arguments.contains("--parallel"))
        #expect(!arguments.contains("--parallel-immediate"))
        #expect(!arguments.contains("--parallel-max"))
    }

    /// `-sS` keeps `curl`'s error text without the meter, and `--fail` is absent for the reason the
    /// segmented download's is: a refused `LIST` writes nothing either way, so the flag would be
    /// cargo.
    @Test("the meter is off, the error text is kept, and there is no --fail")
    func invocationFlags() {
        let arguments = Self.invocation(["/a"]).arguments
        #expect(arguments == ["-sS", "-K", "-"])
    }

    // MARK: - The sections

    @Test("each directory is its own section, with its own credential, output file and LIST url")
    func configurationSections() {
        let configuration = Self.invocation(["/pub", "/pub/docs"]).configuration
        let sections = configuration.components(separatedBy: "next\n")
        #expect(sections.count == 2)
        #expect(sections[0].contains("url = \"ftp://ftp.example:21/pub/\""))
        #expect(sections[0].contains("output = \"/tmp/out/0\""))
        #expect(sections[1].contains("url = \"ftp://ftp.example:21/pub/docs/\""))
        #expect(sections[1].contains("output = \"/tmp/out/1\""))
        for section in sections {
            #expect(section.contains("user = \"u:secret\""))
            #expect(section.contains("connect-timeout = 15"))
            #expect(section.contains("max-time = 30"))
        }
    }

    /// The trailing slash is what makes `curl` send `LIST` rather than fetch a *file* of that name,
    /// and it is the single rule both listing paths share — hence one `listingURL`, since two
    /// spellings would be one edit away from silently fetching a file.
    @Test("a listing url always ends in a slash, added exactly once")
    func listingURLAlwaysEndsInASlash() {
        let configuration = Self.invocation(["/pub", "/pub/", "/"]).configuration
        #expect(configuration.contains("url = \"ftp://ftp.example:21/pub/\""))
        #expect(!configuration.contains("url = \"ftp://ftp.example:21/pub//\""))
        #expect(configuration.contains("url = \"ftp://ftp.example:21/\""))
    }

    /// The batch encodes exactly as the single listing does, which is what lets a directory whose
    /// name carries a space, a `;` or a `#` be walked at all — a `;` would otherwise be read as
    /// FTP's `;type=a` suffix and change which file is fetched.
    @Test("a directory name is percent-encoded the same way the single listing encodes it")
    func namesArePercentEncoded() {
        let configuration = Self.invocation(["/with space", "/semi;colon", "/hash#tag"]).configuration
        #expect(configuration.contains("url = \"ftp://ftp.example:21/with%20space/\""))
        #expect(configuration.contains("url = \"ftp://ftp.example:21/semi%3Bcolon/\""))
        #expect(configuration.contains("url = \"ftp://ftp.example:21/hash%23tag/\""))
        let single = FTPProcessArguments.list(
            session: Self.session(), remotePath: "/with space"
        )
        #expect(single.contains("ftp://ftp.example:21/with%20space/"))
    }

    // MARK: - Security

    /// `curl` reads one option set per transfer, so a section that lost either flag would be a
    /// downgrade nobody asked for — on a path the user is not watching, since this runs behind a
    /// search or a folder size rather than behind a click.
    @Test("every section carries the TLS requirement and the certificate pin")
    func everySectionCarriesItsSecurity() {
        let configuration = Self.invocation(
            ["/a", "/b", "/c"],
            session: Self.session(
                security: .explicit,
                trust: .pinned(publicKey: "AAAABBBB="),
                tls: .forceTLS12
            )
        ).configuration
        let sections = configuration.components(separatedBy: "next\n")
        #expect(sections.count == 3)
        for section in sections {
            #expect(section.contains("ssl-reqd"))
            #expect(section.contains("insecure"))
            #expect(section.contains("pinnedpubkey = \"sha256//AAAABBBB=\""))
            #expect(section.contains("tlsv1.2"))
            #expect(section.contains("tls-max = 1.2"))
        }
    }

    /// The invariant `FTPTrust` exists to make unbreakable: `--insecure` never travels without a
    /// pin. Asserted here too because a batch writes it N times, so a mistake would be N downgrades.
    @Test("no section is insecure without a pin")
    func insecureNeverTravelsAlone() {
        let configuration = Self.invocation(
            ["/a", "/b"],
            session: Self.session(security: .explicit)
        ).configuration
        #expect(!configuration.contains("insecure"))
        #expect(configuration.contains("ssl-reqd"))
    }

    @Test("no password reaches argv")
    func noPasswordInArguments() {
        let invocation = Self.invocation(["/a", "/b"])
        #expect(!invocation.arguments.contains { $0.contains("secret") })
        #expect(invocation.configuration.contains("secret"))
    }

    @Test("an empty request list is an empty configuration, not a malformed one")
    func emptyRequestList() {
        let invocation = Self.invocation([])
        #expect(invocation.configuration.isEmpty)
        #expect(!invocation.configuration.contains("next"))
    }

    /// `max-time` is **per transfer** — probed with five 0.4 s transfers under a 1 s budget each:
    /// 2.056 s total, exit 0, all five landed. So the section budget is the ordinary metadata one
    /// however many sections there are, and it is only the *process* backstop that has to be their
    /// sum.
    @Test("every section carries the same per-transfer budget, however many there are")
    func everySectionCarriesTheOrdinaryBudget() {
        let configuration = Self.invocation((0..<20).map { "/d\($0)" }).configuration
        #expect(configuration.components(separatedBy: "max-time = 30").count == 21)
    }
}
