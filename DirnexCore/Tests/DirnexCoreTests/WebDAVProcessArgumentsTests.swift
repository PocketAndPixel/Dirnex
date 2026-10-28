import Foundation
import Testing

@testable import DirnexCore

/// The `curl` arguments for each WebDAV request (PLAN.md §M32 Slice 2): what is security-sensitive
/// about them, and the URL and header rules the probe measured.
@Suite("WebDAVProcessArguments")
struct WebDAVProcessArgumentsTests {
    private static let location = WebDAVLocation(host: "nas", port: 5006, username: "dirnex-test")
    private static let pin = "gkHDtxIxV+PzQoM88VA6luvmc/GSRi+UvBu3MF2a+mg="

    private func session(
        _ location: WebDAVLocation = Self.location,
        dial: DialedHost? = nil,
        trust: FTPTrust = .systemDefault,
        authentication: WebDAVAuthScheme? = .basic
    ) -> WebDAVSession {
        WebDAVSession(location: location, dial: dial, trust: trust, authentication: authentication)
    }

    private func listing(_ session: WebDAVSession, _ path: String = "/home") -> [String] {
        WebDAVProcessArguments.propfind(
            session: session,
            backendPath: path,
            depth: .one,
            isCollection: true
        )
    }

    // MARK: - Common flags

    @Test("-q is the very first argument, so ~/.curlrc is never read")
    func curlrcDisabledFirst() {
        #expect(listing(session()).first == "-q")
        #expect(WebDAVProcessArguments.certificateProbe(session: session()).first == "-q")
    }

    @Test("credentials go to stdin with the scheme spelled out, never into argv")
    func credentialsOnStdin() {
        let arguments = listing(session())
        #expect(arguments.contains("--basic"))
        #expect(!arguments.contains("--digest"))
        #expect(arguments.indices.contains { arguments[$0] == "-K" && arguments[$0 + 1] == "-" })
        #expect(!arguments.contains("-u") && !arguments.contains("--user"))
        #expect(!arguments.contains { $0.contains("dirnex-test") })
    }

    @Test("digest is asked for by name")
    func digestFlag() {
        let arguments = listing(session(authentication: .digest))
        #expect(arguments.contains("--digest"))
        #expect(!arguments.contains("--basic"))
    }

    @Test("a request without a scheme, or an account without a name, sends nothing")
    func anonymousSendsNothing() {
        for arguments in [
            listing(session(authentication: nil)),
            listing(session(WebDAVLocation(host: "nas", port: 5006, username: "")))
        ] {
            #expect(!arguments.contains("-K"))
            #expect(!arguments.contains("--basic") && !arguments.contains("--digest"))
        }
        #expect(!session(authentication: nil).sendsCredentials)
        #expect(session().sendsCredentials)
    }

    @Test("a pin travels with --insecure, and only over HTTPS")
    func pinnedTrust() throws {
        let pinned = listing(session(trust: .pinned(publicKey: Self.pin)))
        let index = try #require(pinned.firstIndex(of: "--insecure"))
        #expect(pinned[index + 1] == "--pinnedpubkey")
        #expect(pinned[index + 2] == "sha256//\(Self.pin)")

        #expect(!listing(session()).contains("--insecure"))
        let http = WebDAVLocation(host: "nas", port: 5005, username: "dirnex-test", usesTLS: false)
        let plain = listing(session(http, trust: .pinned(publicKey: Self.pin)))
        #expect(!plain.contains("--insecure") && !plain.contains("--pinnedpubkey"))
    }

    @Test("-4 and the dialed name come from the resolution, the identity stays as typed")
    func dialedHost() throws {
        let resolved = listing(session(dial: DialedHost(host: "nas.local", restrictsToIPv4: true)))
        #expect(resolved.contains("-4"))
        #expect(resolved.last == "https://nas.local:5006/home/")
        #expect(!listing(session()).contains("-4"))
        #expect(listing(session()).last == "https://nas:5006/home/")
    }

    @Test("redirects are never followed, and only a download fails on a refusal")
    func noRedirectsNoFail() {
        let listingArguments = listing(session())
        #expect(!listingArguments.contains("--location") && !listingArguments.contains("-L"))
        #expect(!listingArguments.contains("--fail"))
        #expect(listingArguments.contains("--write-out"))
    }

    // MARK: - PROPFIND

    @Test("a listing is Depth 1 on the folder's URL with its slash, the named properties inline")
    func propfindListing() throws {
        let arguments = listing(session())
        let method = try #require(arguments.firstIndex(of: "-X"))
        #expect(arguments[method + 1] == "PROPFIND")
        #expect(arguments.contains("Depth: 1"))
        #expect(arguments.contains(#"Content-Type: application/xml; charset="utf-8""#))
        let body = try #require(arguments.firstIndex(of: "--data-binary").map { arguments[$0 + 1] })
        for property in [
            "resourcetype", "getcontentlength", "getlastmodified", "creationdate", "getetag",
            "getcontenttype"
        ] {
            #expect(body.contains("<D:\(property)/>"))
        }
        #expect(!body.contains("allprop"))
        #expect(!body.hasPrefix("@"), "a leading @ would make curl read a file")
    }

    @Test("a stat is Depth 0 and names the path without a slash")
    func propfindStat() {
        let arguments = WebDAVProcessArguments.propfind(
            session: session(),
            backendPath: "/home/photo.jpg",
            depth: .zero,
            isCollection: false
        )
        #expect(arguments.contains("Depth: 0"))
        #expect(arguments.last == "https://nas:5006/home/photo.jpg")
    }

    @Test("the root path is prefixed and every unsafe byte of a name encoded")
    func rootAndEncoding() {
        let rooted = WebDAVLocation(
            host: "cloud.example.com",
            username: "me@example.com",
            rootPath: "/remote.php/dav/files/me@example.com"
        )
        let arguments = WebDAVProcessArguments.propfind(
            session: session(rooted),
            backendPath: "/a#b%c;d+e?f&g=h[1].txt",
            depth: .zero,
            isCollection: false
        )
        #expect(arguments.last == "https://cloud.example.com/remote.php/dav/files/me%40example.com/"
            + "a%23b%25c%3Bd%2Be%3Ff%26g%3Dh%5B1%5D.txt")
        #expect(listing(session(rooted), "/").last
            == "https://cloud.example.com/remote.php/dav/files/me%40example.com/")
    }

    // MARK: - Download

    @Test("a download fails on a refusal, keeps a partial, and resumes only when asked")
    func download() throws {
        let fresh = WebDAVProcessArguments.download(
            session: session(),
            backendPath: "/home/DSCF8566.JPG",
            localPath: "/tmp/x.jpg",
            resume: false
        )
        #expect(fresh.contains("--fail"))
        #expect(!fresh.contains("--remove-on-error"))
        #expect(!fresh.contains("--continue-at"))
        let output = try #require(fresh.firstIndex(of: "--output"))
        #expect(fresh[output + 1] == "/tmp/x.jpg")
        #expect(fresh.last == "https://nas:5006/home/DSCF8566.JPG")

        let resumed = WebDAVProcessArguments.download(
            session: session(),
            backendPath: "/home/DSCF8566.JPG",
            localPath: "/tmp/x.jpg",
            resume: true
        )
        let resume = try #require(resumed.firstIndex(of: "--continue-at"))
        #expect(resumed[resume + 1] == "-")
    }

    // MARK: - Certificate probe and config

    @Test("the certificate probe trusts nothing it keeps and sends no credential")
    func certificateProbe() {
        let arguments = WebDAVProcessArguments.certificateProbe(
            session: session(dial: DialedHost(host: "nas.local", restrictsToIPv4: true))
        )
        #expect(arguments.contains("--insecure"))
        #expect(!arguments.contains("--pinnedpubkey"))
        #expect(!arguments.contains("-K"))
        #expect(arguments.contains("%{certs}"))
        #expect(arguments.contains("-4"))
        #expect(arguments.last == "https://nas.local:5006/")
    }

    @Test("a password that would end the value or start a directive is escaped")
    func configEscaping() {
        let config = WebDAVConfigFile.credentials(
            username: "dirnex-test",
            password: "a\"b\nurl = x:y"
        )
        #expect(config == "user = \"dirnex-test:a\\\"b\\nurl = x:y\"\n")
        #expect(config.split(separator: "\n").count == 1)
    }
}
