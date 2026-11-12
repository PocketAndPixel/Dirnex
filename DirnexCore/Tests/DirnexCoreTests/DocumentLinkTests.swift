import Foundation
import Testing

@testable import DirnexCore

/// The document the probe's page stood for: every name in its path means something in a URL.
private enum Fixture {
    static let document = VFSPath.local("/My Docs/café#x/READ ME.md")
    static let folder = "/My Docs/café#x"
    /// `baseURL(for: document)`'s folder, as WebKit wrote it in front of a resolved sibling.
    static let page = "x-dirnex-document:///My%20Docs/caf%C3%A9%23x/"

    static func at(_ path: String, _ fragment: String? = nil) -> DocumentLink {
        .location(.local(path), fragment: fragment)
    }

    static func resolve(_ reference: String) -> DocumentLink {
        DocumentLink.resolve(reference, from: document)
    }

    static func web(_ string: String) -> DocumentLink {
        .external(URL(string: string)!)
    }
}

@Suite("DocumentLink against WebKit")
struct DocumentLinkWebKitTests {
    @Test("the base URL is the document's own path in the scheme, each name percent-encoded")
    func baseURL() {
        let base = DocumentLink.baseURL(for: Fixture.document).absoluteString
        #expect(base == Fixture.page + "READ%20ME.md")
        #expect(
            DocumentLink.baseURL(for: .local("/a/b.md")).absoluteString == "x-dirnex-document:///a/b.md"
        )
        #expect(DocumentLink.baseURL(for: .local("/")).absoluteString == "x-dirnex-document:///")
    }

    @Test(
        "a name that means something in a URL survives the round trip through the base URL",
        arguments: [
            "q?.md", "100%.md", "%41.md", "back\\slash.md", "a;b.md", "c:d.md", "e=f&g+h.md",
            "名前.md", "...", "#.md", "sp ace.md"
        ]
    )
    func roundTrip(name: String) {
        let document = VFSPath.local("/dir/" + name)
        let base = DocumentLink.baseURL(for: document).absoluteString
        #expect(DocumentLink.resolve(base, from: document) == .sameDocument(fragment: nil))
        #expect(DocumentLink.resolve("", from: document) == .sameDocument(fragment: nil))
        #expect(
            DocumentLink.resolve(base + "#top", from: document) == .sameDocument(fragment: "top")
        )
        #expect(DocumentLink.resolve("sibling.md", from: document) == Fixture.at("/dir/sibling.md"))
    }

    struct Probed: Sendable, CustomTestStringConvertible {
        let written: String
        let webKit: String
        let expected: DocumentLink
        var testDescription: String { "'\(written)'" }

        init(_ written: String, _ webKit: String, _ expected: DocumentLink) {
            self.written = written
            self.webKit = webKit
            self.expected = expected
        }
    }

    /// Each reference as the page wrote it, the URL WebKit resolved it to against
    /// `baseURL(for: document)` (probed 2026-11-12 with `loadHTMLString` and a click on each), and
    /// where both must lead. `100%.md` and `a\b.md` are the two rows `URL(string:relativeTo:)` got
    /// wrong, by re-encoding `My%20Docs` as `My%2520Docs`.
    static let probed: [Probed] = {
        let page = Fixture.page
        let folder = Fixture.folder
        let root = "x-dirnex-document:///"
        return [
            Probed("other.md", page + "other.md", Fixture.at(folder + "/other.md")),
            Probed("./other.md", page + "other.md", Fixture.at(folder + "/other.md")),
            Probed("sub2/deep.md", page + "sub2/deep.md", Fixture.at(folder + "/sub2/deep.md")),
            Probed("../up.md", root + "My%20Docs/up.md", Fixture.at("/My Docs/up.md")),
            Probed("../../../../../../../../x.md", root + "x.md", Fixture.at("/x.md")),
            Probed("/root.md", root + "root.md", Fixture.at("/root.md")),
            Probed(
                "other.md#Sec%20One",
                page + "other.md#Sec%20One",
                Fixture.at(folder + "/other.md", "Sec One")
            ),
            Probed("#local", page + "READ%20ME.md#local", .sameDocument(fragment: "local")),
            Probed("#über", page + "READ%20ME.md#%C3%BCber", .sameDocument(fragment: "über")),
            Probed("my%20file.md", page + "my%20file.md", Fixture.at(folder + "/my file.md")),
            Probed("my file.md", page + "my%20file.md", Fixture.at(folder + "/my file.md")),
            Probed("café.md", page + "caf%C3%A9.md", Fixture.at(folder + "/café.md")),
            Probed("100%.md", page + "100%.md", Fixture.at(folder + "/100%.md")),
            Probed("a%2Fb.md", page + "a%2Fb.md", .refused(.malformed)),
            Probed(
                "other.md?plain=1#L3",
                page + "other.md?plain=1#L3",
                Fixture.at(folder + "/other.md", "L3")
            ),
            Probed("file:///etc/hosts", "file:///etc/hosts", Fixture.at("/etc/hosts")),
            Probed(
                "//host/share/x.md",
                "x-dirnex-document://host/share/x.md",
                .refused(.anotherHost("host"))
            ),
            Probed(
                "https://example.com/a b",
                "https://example.com/a%20b",
                Fixture.web("https://example.com/a%20b")
            ),
            Probed("mailto:x@y.z", "mailto:x@y.z", Fixture.web("mailto:x@y.z")),
            Probed("", page + "READ%20ME.md", .sameDocument(fragment: nil)),
            Probed(".", page, Fixture.at(folder)),
            Probed("./", page, Fixture.at(folder)),
            Probed("docs/", page + "docs/", Fixture.at(folder + "/docs")),
            Probed("a\\b.md", page + "a\\b.md", Fixture.at(folder + "/a\\b.md")),
            Probed("?q=1", page + "READ%20ME.md?q=1", .sameDocument(fragment: nil))
        ]
    }()

    @Test("a reference as written leads where its author meant", arguments: probed)
    func written(_ probe: Probed) {
        #expect(Fixture.resolve(probe.written) == probe.expected)
    }

    @Test("the URL WebKit made of a reference leads to the same place", arguments: probed)
    func resolvedByWebKit(_ probe: Probed) {
        #expect(Fixture.resolve(probe.webKit) == probe.expected)
    }
}

@Suite("DocumentLink")
struct DocumentLinkTests {
    private let folder = Fixture.folder

    private func at(_ path: String, _ fragment: String? = nil) -> DocumentLink {
        Fixture.at(path, fragment)
    }

    private func resolve(_ reference: String) -> DocumentLink {
        Fixture.resolve(reference)
    }

    // MARK: - Other spellings of the same place

    @Test("the document by any spelling is the document, not a step to it")
    func sameDocumentSpellings() {
        #expect(resolve("READ%20ME.md") == .sameDocument(fragment: nil))
        #expect(resolve("READ ME.md#top") == .sameDocument(fragment: "top"))
        #expect(resolve("../café%23x/READ%20ME.md") == .sameDocument(fragment: nil))
        #expect(resolve("/My%20Docs/caf%C3%A9%23x/READ%20ME.md") == .sameDocument(fragment: nil))
        #expect(
            resolve("file:///My%20Docs/caf%C3%A9%23x/READ%20ME.md#a") == .sameDocument(fragment: "a")
        )
    }

    @Test("dot segments fold after decoding, and in a URL that arrives already absolute")
    func dotSegments() {
        // WHATWG folds an encoded `..`, so the decoded names are what is folded.
        #expect(resolve("%2E%2E/x.md") == at("/My Docs/x.md"))
        #expect(resolve("sub/%2e/x.md") == at(folder + "/sub/x.md"))
        #expect(resolve("file:///a/./b/../c.md") == at("/a/c.md"))
        #expect(resolve("x-dirnex-document:///a/b/../../../c.md") == at("/c.md"))
        #expect(resolve("..") == at("/My Docs"))
        #expect(resolve("/") == at("/"))
    }

    @Test("the fragment is decoded, and an empty one is none")
    func fragments() {
        #expect(resolve("#") == .sameDocument(fragment: nil))
        #expect(resolve("other.md#") == at(folder + "/other.md"))
        #expect(resolve("#%C3%BCber") == .sameDocument(fragment: "über"))
        #expect(resolve("#a%zz") == .sameDocument(fragment: "a%zz"))
        #expect(resolve("#user-content-install") == .sameDocument(fragment: "user-content-install"))
    }

    @Test("leading and trailing controls and spaces go, and so does every tab and line break")
    func whitespace() {
        #expect(resolve("  other.md\n") == at(folder + "/other.md"))
        #expect(resolve("\tother.md") == at(folder + "/other.md"))
        #expect(resolve("oth\ner.md") == at(folder + "/other.md"))
        #expect(resolve("   ") == .sameDocument(fragment: nil))
        // An inner space is part of the name.
        #expect(resolve(" my file.md ") == at(folder + "/my file.md"))
    }

    @Test("a colon makes a scheme only before any slash, and only after ASCII letters")
    func colons() {
        #expect(resolve("a:b.md") == .refused(.scheme("a")))
        #expect(resolve("./a:b.md") == at(folder + "/a:b.md"))
        #expect(resolve("sub/a:b.md") == at(folder + "/sub/a:b.md"))
        #expect(resolve("café:x.md") == at(folder + "/café:x.md"))
        #expect(resolve("1a:b.md") == at(folder + "/1a:b.md"))
    }

    // MARK: - Backends

    @Test("a link in a server's document is a place on that server")
    func serverDocument() {
        let server = VFSBackendID("sftp://u@nas:22")
        let document = VFSPath(backend: server, path: "/home/u/docs/README.md")
        let notes = VFSPath(backend: server, path: "/home/u/notes/a.md")
        #expect(
            DocumentLink.resolve("../notes/a.md#b", from: document) == .location(
                notes,
                fragment: "b"
            )
        )
        let srv = VFSPath(backend: server, path: "/srv/x.md")
        #expect(DocumentLink.resolve("/srv/x.md", from: document) == .location(srv, fragment: nil))
        #expect(DocumentLink.resolve("#top", from: document) == .sameDocument(fragment: "top"))
        // A `file:` URL names some computer's own disk, which is not this server.
        #expect(DocumentLink.resolve("file:///etc/hosts", from: document) == .refused(.localFile))
    }

    @Test("a link in an archive's member stays in the archive, and stops at its root")
    func archiveDocument() {
        let archive = VFSBackendID.archive(forArchiveAt: "/Users/me/pkg.zip")
        let document = VFSPath(backend: archive, path: "/pkg/README.md")
        let license = VFSPath(backend: archive, path: "/LICENSE")
        #expect(
            DocumentLink.resolve("../LICENSE", from: document) == .location(license, fragment: nil)
        )
        // Past the root clamps, as RFC 3986 and WebKit both do: WebKit has clamped before the app
        // sees the click, so the target is the archive's own `/outside.md`, likely not there.
        let outside = VFSPath(backend: archive, path: "/outside.md")
        #expect(
            DocumentLink.resolve("../../../outside.md", from: document)
                == .location(outside, fragment: nil)
        )
        #expect(
            DocumentLink.resolve("file:///Users/me/x.md", from: document) == .refused(.localFile)
        )
    }

    // MARK: - Other computers, other apps, nowhere

    @Test("a host names another computer, except localhost in a file: URL")
    func hosts() {
        #expect(resolve("file://localhost/etc/x") == at("/etc/x"))
        #expect(resolve("file://LOCALHOST/etc/x") == at("/etc/x"))
        #expect(resolve("file://server/share/x") == .refused(.anotherHost("server")))
        #expect(resolve("//nas.local/x.md") == .refused(.anotherHost("nas.local")))
    }

    @Test("an empty authority roots the path, and any other names a computer")
    func authorities() {
        #expect(resolve("//") == at("/"))
        #expect(resolve("///x.md") == at("/x.md"))
        #expect(resolve("file://localhost") == at("/"))
        #expect(resolve("//user@nas:2222/x") == .refused(.anotherHost("nas")))
        #expect(resolve("//[::1]:22/x") == .refused(.anotherHost("[::1]")))
        #expect(resolve("//n%41s/x") == .refused(.anotherHost("nAs")))
        // The document scheme never carries a host, so even `localhost` there is somewhere else.
        #expect(resolve("x-dirnex-document://localhost/x") == .refused(.anotherHost("localhost")))
    }

    @Test("the web and mail go to another app, whatever the scheme's case")
    func external() {
        #expect(resolve("https://example.com/x#y") == Fixture.web("https://example.com/x#y"))
        #expect(resolve("http://example.com") == Fixture.web("http://example.com"))
        #expect(resolve("HTTPS://EXAMPLE.com/X") == Fixture.web("HTTPS://EXAMPLE.com/X"))
        #expect(resolve("mailto:a@b.c?subject=hi") == Fixture.web("mailto:a@b.c?subject=hi"))
    }

    @Test("a web link's invalid characters are encoded and its valid escapes kept")
    func webEncoding() {
        // `URL(string:)` alone gives `My%2520Docs/a%20b`: one space re-encodes every `%` in it.
        #expect(
            resolve("https://e.com/My%20Docs/a b") == Fixture.web("https://e.com/My%20Docs/a%20b")
        )
        #expect(resolve("https://e.com/café?q=ü") == Fixture.web("https://e.com/caf%C3%A9?q=%C3%BC"))
        #expect(resolve("https://e.com/100%") == Fixture.web("https://e.com/100%25"))
        #expect(resolve("https://e.com/a#b#c") == Fixture.web("https://e.com/a#b%23c"))
        #expect(resolve("https://e.com/{x}") == Fixture.web("https://e.com/%7Bx%7D"))
    }

    @Test(
        "every other scheme is refused by name, however it is spelled",
        arguments: [
            ("javascript:alert(1)", "javascript"),
            ("JavaScript:alert(1)", "javascript"),
            ("java\tscript:alert(1)", "javascript"),
            ("java\nscript:alert(1)", "javascript"),
            ("  javascript:alert(1)", "javascript"),
            ("data:text/html,hi", "data"),
            ("ftp://h/x", "ftp"),
            ("sftp://h/x", "sftp"),
            ("tel:+15550100", "tel"),
            ("about:blank", "about"),
            ("shortcuts://run-shortcut?name=x", "shortcuts"),
            ("C:/x.md", "c"),
            ("x-dirnex-archive://o1/a.html", "x-dirnex-archive"),
        ]
    )
    func refusedSchemes(reference: String, scheme: String) {
        #expect(resolve(reference) == .refused(.scheme(scheme)))
    }

    @Test("what names no place is malformed")
    func malformed() {
        #expect(resolve("a%2Fb.md") == .refused(.malformed))
        #expect(resolve("%00.md") == .refused(.malformed))
        #expect(resolve("file:etc/x") == .refused(.malformed))
        #expect(resolve("http:x") == .refused(.malformed))
        #expect(resolve("https:///path") == .refused(.malformed))
    }
}
