import Foundation
import Testing

@testable import DirnexCore

/// Real WebDAV answers, captured 2026-10-22 with `curl` from two servers (PLAN.md §M32): the NAS's
/// Synology WebDAV Server (`nas-*`) and macOS's own `/usr/sbin/httpd` with `mod_dav` (`apache-*`).
/// The same folder was made on both — Cyrillic, Japanese, a decomposed é, `# % ; + ? & = [ ]`, a
/// leading space, a dot file, an empty file and a subfolder — and listed with the named-property
/// PROPFIND the backend sends (`*-props`) and with an empty body (`*-allprop`).
///
/// Both servers are Apache, so these prove agreement with Apache rather than with WebDAV — the risk
/// PLAN.md §6 records for this milestone. The parser is written to RFC 4918 so that a second family
/// can be added here without changing it.
enum WebDAVFixtures {
    static func data(_ name: String, extension ext: String = "xml") throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/WebDAV")
        )
        return try Data(contentsOf: url)
    }

    static func text(_ name: String, extension ext: String = "xml") throws -> String {
        try #require(String(data: data(name, extension: ext), encoding: .utf8))
    }

    static func parse(_ name: String) throws -> WebDAVMultistatus {
        try WebDAVMultistatusParser.parse(data(name))
    }

    /// The names the fixture folder holds, as stored.
    static let folderNames: Set<[UInt8]> = Set([
        "Привет мир.txt", "cafe\u{301}.txt", "a#b%c;d+e?f&g=h[1].txt", " leading space.txt",
        ".hidden", "日本語.txt", "empty.txt", "Папка"
    ].map { Array($0.utf8) })

    /// `Thu, 22 Oct 2026 20:48:28 GMT`, the stamp every file in the NAS folder carries.
    static let nasStamp = Date(timeIntervalSince1970: 1_792_702_108)
}

@Suite("WebDAVMultistatusParser")
struct WebDAVMultistatusParserTests {
    private static let folder = "/home/dirnex-webdav-fixture"

    private func response(_ status: WebDAVMultistatus, named name: String) throws -> WebDAVResponse {
        try #require(status.responses.first { WebDAVHref.name(of: $0.path) == name })
    }

    // MARK: - Namespaces

    @Test("properties are read under lp1, which is bound to DAV: per response")
    func readsLivePropertiesByNamespace() throws {
        // What makes the fixture the test: the size, date and type are all spelled `lp1:`, so a
        // parser matching the `D:` prefix would find none of them.
        let text = try WebDAVFixtures.text("nas-folder-props")
        #expect(text.contains("<lp1:getcontentlength>"))
        #expect(!text.contains("<D:getcontentlength>"))
        #expect(text.contains("xmlns:lp1=\"DAV:\""))

        let file = try response(WebDAVFixtures.parse("nas-folder-props"), named: "Привет мир.txt")
        #expect(file.byteSize == 6)
        #expect(file.modified == WebDAVFixtures.nasStamp)
        #expect(file.created == WebDAVFixtures.nasStamp)
        #expect(file.entityTag == "\"6-65e73fc5642b9\"")
        #expect(file.contentType == "text/plain")
        #expect(!file.isCollection)
    }

    @Test("an element outside DAV: is not read, whatever its name")
    func foreignNamespaceIgnored() throws {
        let body = """
        <?xml version="1.0"?><D:multistatus xmlns:D="DAV:" xmlns:X="urn:other"><D:response>\
        <D:href>/a.txt</D:href><D:propstat><D:prop><X:getcontentlength>99</X:getcontentlength>\
        <D:getcontentlength>6</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status>\
        </D:propstat></D:response></D:multistatus>
        """
        let file = try #require(try WebDAVMultistatusParser.parse(Data(body.utf8)).responses.first)
        #expect(file.byteSize == 6)
    }

    @Test("a default namespace with no prefix reads the same as a prefixed one")
    func defaultNamespace() throws {
        let body = """
        <?xml version="1.0"?><multistatus xmlns="DAV:"><response><href>/d/</href><propstat><prop>\
        <resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat>\
        </response></multistatus>
        """
        let folder = try #require(try WebDAVMultistatusParser.parse(Data(body.utf8)).responses.first)
        #expect(folder.path == "/d")
        #expect(folder.isCollection)
    }

    // MARK: - Propstat status

    @Test("a collection's 404 propstat leaves its size unknown")
    func collectionHasNoSize() throws {
        let text = try WebDAVFixtures.text("nas-folder-props")
        #expect(text.contains("<g0:getcontentlength/>"))
        let folder = try response(
            WebDAVFixtures.parse("nas-folder-props"),
            named: "dirnex-webdav-fixture"
        )
        #expect(folder.isCollection)
        #expect(folder.byteSize == nil)
        #expect(folder.contentType == "httpd/unix-directory")
    }

    @Test("a value inside a non-2xx propstat is ignored, and the same value in a 200 one is read")
    func propstatStatusGatesValues() throws {
        // Derived from the real fixture: the collection's empty 404 property is given a value. The
        // control flips that propstat to 200, which proves it is the status doing the work rather
        // than the value's shape.
        let text = try WebDAVFixtures.text("nas-folder-noslash-depth0-props")
        let withValue = text.replacingOccurrences(
            of: "<g0:getcontentlength/>", with: "<g0:getcontentlength>999</g0:getcontentlength>"
        )
        #expect(withValue != text)
        let refused = try #require(
            try WebDAVMultistatusParser.parse(Data(withValue.utf8)).responses.first
        )
        #expect(refused.byteSize == nil)

        let accepted = withValue.replacingOccurrences(
            of: "HTTP/1.1 404 Not Found",
            with: "HTTP/1.1 200 OK"
        )
        let read = try #require(
            try WebDAVMultistatusParser.parse(Data(accepted.utf8)).responses.first
        )
        #expect(read.byteSize == 999)
        // The 200 propstat's own values survive the merge.
        #expect(read.entityTag == "\"e0-65e73fc5abb3f\"")
    }

    // MARK: - Collections

    @Test("the account root's shared folders are folders without a trailing slash")
    func rootFoldersHaveNoSlash() throws {
        let text = try WebDAVFixtures.text("nas-root-props")
        #expect(text.contains("<D:href>/home</D:href>"))
        let root = try WebDAVFixtures.parse("nas-root-props")
        #expect(root.responses.map(\.path) == ["/", "/media", "/share", "/home"])
        #expect(root.responses.allSatisfy { $0.isCollection })
    }

    @Test("every name in the folder is read, byte for byte")
    func readsEveryName() throws {
        let parsed = try WebDAVFixtures.parse("nas-folder-props")
        #expect(parsed.unreadableHrefCount == 0)
        let names = parsed.responses.dropFirst().compactMap { WebDAVHref.name(of: $0.path) }
        #expect(Set(names.map { Array($0.utf8) }) == WebDAVFixtures.folderNames)
        #expect(try response(parsed, named: "Папка").isCollection)
        #expect(try response(parsed, named: "empty.txt").byteSize == 0)
    }

    @Test("an empty-bodied PROPFIND reads the same rows as the named one")
    func allpropMatchesNamedProperties() throws {
        let named = try WebDAVFixtures.parse("nas-folder-props")
        let all = try WebDAVFixtures.parse("nas-folder-allprop")
        #expect(all.responses.map(\.path) == named.responses.map(\.path))
        #expect(all.responses.map(\.byteSize) == named.responses.map(\.byteSize))
        #expect(all.responses.map(\.isCollection) == named.responses.map(\.isCollection))
    }

    @Test("macOS's Apache lists the same names in another order, with weak tags")
    func apacheAgrees() throws {
        let apache = try WebDAVFixtures.parse("apache-folder-props")
        let nas = try WebDAVFixtures.parse("nas-folder-props")
        let apacheNames = apache.responses.dropFirst().compactMap { WebDAVHref.name(of: $0.path) }
        #expect(Set(apacheNames.map { Array($0.utf8) }) == WebDAVFixtures.folderNames)
        // Order is not a contract.
        let nasNames = nas.responses.dropFirst().compactMap { WebDAVHref.name(of: $0.path) }
        #expect(apacheNames != nasNames)
        // A file read in the second it was written carries a weak tag, kept verbatim.
        let hidden = try response(apache, named: ".hidden")
        #expect(hidden.entityTag == "W/\"6-65e73feb83900\"")
        // No content type for a collection here, where the NAS sends one.
        #expect(try response(apache, named: "dirnex-webdav-fixture").contentType == nil)
    }

    // MARK: - Hrefs that are not the resource

    @Test("a locked file's lock-token href does not replace its own")
    func lockTokenHrefIgnored() throws {
        let text = try WebDAVFixtures.text("nas-folder-allprop-active-lock")
        #expect(text.contains("<D:href>opaquelocktoken:"))
        let parsed = try WebDAVFixtures.parse("nas-folder-allprop-active-lock")
        // The token comes after the file's own href, and a row of properties takes its first, so
        // this fixture alone does not need the rule that an href counts only under `<response>`.
        // The outcome row in the next test does.
        #expect(parsed.unreadableHrefCount == 0)
        #expect(parsed.responses.map(\.path) == [
            "/home/dirnex-webdav-lockfx", "/home/dirnex-webdav-lockfx/locked.txt",
            "/home/dirnex-webdav-lockfx/free.txt"
        ])
        let locked = try response(parsed, named: "locked.txt")
        #expect(locked.byteSize == 6)
        #expect(locked.entityTag == "W/\"6-65e740d66aa14\"")
    }

    @Test("unreadable hrefs are counted, and the readable rows beside them kept")
    func unreadableHrefsCounted() throws {
        let rows = ["/d/", "/d/a%2Fb", "/d/%ff", "relative.txt", "/d/ok.txt"].map { href in
            "<D:response><D:href>\(href)</D:href><D:propstat><D:prop><D:resourcetype/></D:prop>" +
                "<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
        }
        let body = "<?xml version=\"1.0\"?><D:multistatus xmlns:D=\"DAV:\">\(rows.joined())</D:multistatus>"
        let parsed = try WebDAVMultistatusParser.parse(Data(body.utf8))
        #expect(parsed.unreadableHrefCount == 3)
        #expect(parsed.responses.map(\.path) == ["/d", "/d/ok.txt"])
    }

    // MARK: - Outcomes

    @Test("a 424 body names the locked member with its own status")
    func failedDependencyBody() throws {
        let parsed = try WebDAVFixtures.parse("nas-delete-locked-member-424")
        let member = try #require(parsed.responses.first)
        #expect(parsed.responses.count == 1)
        #expect(member.status == 423)
        #expect(WebDAVHref.samePath(member.path, "/home/dirnex-webdav-fixture/Папка/inside.txt"))
    }

    @Test("an href inside an outcome's <error> is not another member")
    func errorElementHrefIgnored() throws {
        // RFC 4918 §16's `lock-token-submitted` names the root of the lock in an href of its own.
        // An outcome takes every href it lists (the next test), so only the element's position
        // keeps this one from being reported as a second locked member. Apache sends HTML for a
        // 423; this is the RFC's shape, which other servers send.
        let body = """
        <?xml version="1.0"?><D:multistatus xmlns:D="DAV:"><D:response><D:href>/d/a.txt</D:href>\
        <D:status>HTTP/1.1 423 Locked</D:status><D:error><D:lock-token-submitted>\
        <D:href>/d</D:href></D:lock-token-submitted></D:error></D:response></D:multistatus>
        """
        let parsed = try WebDAVMultistatusParser.parse(Data(body.utf8))
        #expect(parsed.responses == [WebDAVResponse(path: "/d/a.txt", status: 423)])
    }

    @Test("one status may cover several hrefs (RFC 4918 §14.24)")
    func statusCoversSeveralHrefs() throws {
        let body = """
        <?xml version="1.0"?><D:multistatus xmlns:D="DAV:"><D:response><D:href>/a</D:href>\
        <D:href>/b</D:href><D:status>HTTP/1.1 423 Locked</D:status></D:response></D:multistatus>
        """
        let parsed = try WebDAVMultistatusParser.parse(Data(body.utf8))
        #expect(parsed.responses == [
            WebDAVResponse(path: "/a", status: 423), WebDAVResponse(path: "/b", status: 423)
        ])
    }

    @Test("a body that is not a multistatus is refused", arguments: [
        "nas-put-locked-423", "nas-depth-infinity-403"
    ])
    func htmlRefused(_ name: String) throws {
        let data = try WebDAVFixtures.data(name, extension: "html")
        #expect(throws: WebDAVParseError.notAMultistatus) { try WebDAVMultistatusParser.parse(data) }
    }

    @Test("an empty body, or XML of another kind, is refused")
    func otherBodiesRefused() {
        #expect(throws: WebDAVParseError.notAMultistatus) { try WebDAVMultistatusParser.parse(Data()) }
        let s3 = Data("<?xml version=\"1.0\"?><Error><Code>NoSuchKey</Code></Error>".utf8)
        #expect(throws: WebDAVParseError.notAMultistatus) { try WebDAVMultistatusParser.parse(s3) }
        // `multistatus` outside the DAV: namespace is not one.
        let foreign = Data("<?xml version=\"1.0\"?><multistatus/>".utf8)
        #expect(throws: WebDAVParseError.notAMultistatus) { try WebDAVMultistatusParser.parse(
            foreign
        ) }
    }

    // MARK: - Small readers

    @Test("status lines", arguments: [
        ("HTTP/1.1 200 OK", 200), ("HTTP/1.1 423 Locked", 423), ("HTTP/1.1 409 (status)", 409),
        ("HTTP/2 404", 404), ("  HTTP/1.1 207 Multi-Status ", 207)
    ])
    func statusLines(_ line: String, _ code: Int) {
        #expect(WebDAVMultistatusParser.statusCode(fromLine: line) == code)
    }

    @Test(
        "lines that are not status lines",
        arguments: ["", "200 OK", "HTTP/1.1", "HTTP/1.1 OK", "HTTP/1.1 2000"]
    )
    func notStatusLines(_ line: String) {
        #expect(WebDAVMultistatusParser.statusCode(fromLine: line) == nil)
    }

    @Test("the three HTTP date forms RFC 9110 obliges, and RFC 3339")
    func dates() {
        let dates = WebDAVDate()
        let stamp = WebDAVFixtures.nasStamp
        #expect(dates.httpDate("Thu, 22 Oct 2026 20:48:28 GMT") == stamp)
        #expect(dates.httpDate("Thursday, 22-Oct-26 20:48:28 GMT") == stamp)
        #expect(dates.httpDate("Thu Oct 22 20:48:28 2026") == stamp)
        #expect(dates.creationDate("2026-10-22T20:48:28Z") == stamp)
        #expect(dates.creationDate("2026-10-22T20:48:28.000Z") == stamp)
        #expect(dates.creationDate("2026-10-22T22:48:28+02:00") == stamp)
        // Each accepts the other's shape, since a server that sends the wrong one still means a date.
        #expect(dates.httpDate("2026-10-22T20:48:28Z") == stamp)
        #expect(dates.creationDate("Thu, 22 Oct 2026 20:48:28 GMT") == stamp)
        #expect(dates.httpDate("yesterday") == nil)
    }
}
