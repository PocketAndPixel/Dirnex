import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Where a click on a rendered page leads, worked out from the page it was clicked in (PLAN.md §M39 ▸
/// Slice 5). The resolution itself is `DirnexCore`'s and pinned there (`DocumentLinkTests`); what is
/// pinned here is that each kind of page hands it the right two things — the URL in the form the core
/// reads, and the document's place on its own backend — and what the surface keeps between a click
/// and the page it leads to.
@Suite("Quick View links on a page")
@MainActor
struct QuickViewLinkTests {
    private static let server = VFSBackendID("sftp://u@nas:22")

    private static func onServer(_ path: String) -> VFSPath {
        VFSPath(backend: server, path: path)
    }

    // MARK: - What each kind of page resolves against

    @Test("a generated page's links are paths on the document's own backend")
    func generatedPage() throws {
        let location = Self.onServer("/srv/docs/README.md")
        let base = DocumentLink.baseURL(for: location)
        let page = QuickViewWebView.Page.generated(
            QuickViewPreviewView.MarkdownScan(html: "", isTruncated: false),
            base: base,
            location: location
        )
        let sibling = try #require(URL(string: "other%20file.md#sec", relativeTo: base)?.absoluteURL)
        let link = try #require(page.link(for: sibling))
        #expect(link.0 == .location(Self.onServer("/srv/docs/other file.md"), fragment: "sec"))
        #expect(link.1 == location)
        let web = try #require(URL(string: "https://example.com/x"))
        #expect(page.link(for: web)?.0 == .external(web))
        let script = try #require(URL(string: "javascript:alert(1)"))
        #expect(page.link(for: script)?.0 == .refused(.scheme("javascript")))
    }

    @Test("a server's HTML file, drawn from its copy, has its links under its own location's path")
    func copyOfAServerFile() throws {
        let copy = URL(fileURLWithPath: "/var/folders/x/T/DirnexRemote/ABC/index.html")
        let location = Self.onServer("/srv/site/index.html")
        let base = DocumentLink.baseURL(for: location)
        let page = QuickViewWebView.Page.copied(copy, base: base, location: location)
        #expect(page.permittedURL == base)

        let sibling = try #require(URL(string: "about.html", relativeTo: base)?.absoluteURL)
        #expect(
            page.link(for: sibling)?.0 == .location(
                Self.onServer("/srv/site/about.html"),
                fragment: nil
            )
        )
        let itself = try #require(URL(string: "#top", relativeTo: base)?.absoluteURL)
        #expect(page.link(for: itself)?.0 == .sameDocument(fragment: "top"))
        let web = try #require(URL(string: "https://example.com/"))
        #expect(page.link(for: web)?.0 == .external(web))
    }

    @Test("a local HTML file's links are read as the file: URLs they are")
    func localFile() throws {
        let file = URL(fileURLWithPath: "/Users/tester/site/index.html")
        let page = QuickViewWebView.Page.file(file, location: .local(file.path))
        let other = try #require(URL(string: "file:///Users/tester/notes/plan.html"))
        #expect(
            page.link(for: other)?.0 == .location(
                .local("/Users/tester/notes/plan.html"),
                fragment: nil
            )
        )
    }

    @Test("a saved page's sealed links go back to the real URL, and other links go out as they are")
    func savedPage() throws {
        let page = QuickViewWebView.Page.archive(QuickViewWebView.SavedArchive(
            data: Data(),
            directory: URL(fileURLWithPath: "/Users/tester/Downloads"),
            document: try #require(URL(string: "x-dirnex-archive://o1/a/story.html")),
            origins: ["x-dirnex-archive://o1": "https://news.example"],
            location: .local("/Users/tester/Downloads/story.webarchive")
        ))
        let sealed = try #require(URL(string: "x-dirnex-archive://o1/a/next.html?p=2"))
        let original = try #require(URL(string: "https://news.example/a/next.html?p=2"))
        #expect(page.link(for: sealed)?.0 == .external(original))
        let elsewhere = try #require(URL(string: "https://elsewhere.example/"))
        #expect(page.link(for: elsewhere)?.0 == .external(elsewhere))
        let unknown = try #require(URL(string: "x-dirnex-archive://o9/x"))
        #expect(page.link(for: unknown)?.0 == .refused(.scheme("x-dirnex-archive")))
    }

    @Test("a converted document's links lead out to the web and nowhere else")
    func convertedDocument() throws {
        let bundle = URL(
            fileURLWithPath: "/var/folders/x/T/qlconvert/Preview.qlpreview",
            isDirectory: true
        )
        let page = QuickViewWebView.Page.converted(
            page: bundle.appendingPathComponent("Preview.html"),
            bundle: bundle,
            allowsJavaScript: false,
            fitWidth: nil
        )
        let web = try #require(URL(string: "https://example.com/spec"))
        #expect(page.link(for: web)?.0 == .external(web))
        #expect(page.link(for: bundle.appendingPathComponent("sheet002.htm")) == nil)
    }

    // MARK: - The navigation policy

    @Test(
        "a generated page loads under its base URL, and a click is allowed only to an anchor on it"
    )
    func generatedPolicy() async throws {
        let surface = try await QuickViewLinkSurface.built()
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let source = try tree.write("README.md", contents: "# Title\n")
        let location = Self.onServer("/srv/docs/README.md")
        surface.showMarkdown(
            QuickViewPreviewView.MarkdownScan(html: "", isTruncated: false),
            source: source,
            location: location
        )
        let base = DocumentLink.baseURL(for: location)
        #expect(surface.page?.permittedURL == base)
        #expect(surface.isPermitted(base, inFrame: false, isClick: false))
        let anchor = try #require(URL(string: base.absoluteString + "#title"))
        #expect(surface.isPermitted(anchor, inFrame: false, isClick: true))
        // The page itself without an anchor, and a sibling: followed instead, so refused here.
        #expect(!surface.isPermitted(base, inFrame: false, isClick: true))
        let sibling = try #require(URL(string: "other.md", relativeTo: base)?.absoluteURL)
        #expect(!surface.isPermitted(sibling, inFrame: false, isClick: true))
    }

    // MARK: - Between the click and the page it leads to

    @Test("a waiting heading is taken by its own document once, and dropped by any other")
    func pendingFragment() {
        let preview = QuickViewPreviewView(
            backingColor: .textBackgroundColor,
            header: .none,
            findOptions: QuickViewFindOptionsStore.scratch()
        )
        let target = Self.onServer("/srv/docs/other.md")
        let pending = QuickViewLinks.PendingFragment(location: target, fragment: "sec")

        preview.links.pendingFragment = pending
        #expect(preview.takePendingFragment(for: target) == "sec")
        #expect(preview.takePendingFragment(for: target) == nil)

        preview.links.pendingFragment = pending
        #expect(preview.takePendingFragment(for: Self.onServer("/srv/docs/README.md")) == nil)
        #expect(preview.links.pendingFragment == nil)

        preview.links.pendingFragment = pending
        preview.clear()
        #expect(preview.links.pendingFragment == nil)
    }

    @Test("a file shown by its URL alone is its own location, and a named location wins")
    func documentLocation() {
        let preview = QuickViewPreviewView(
            backingColor: .textBackgroundColor,
            header: .none,
            findOptions: QuickViewFindOptionsStore.scratch()
        )
        let copy = URL(fileURLWithPath: "/var/folders/x/T/DirnexRemote/ABC/README.md")
        #expect(preview.documentLocation(for: copy) == .local(copy.path))
        preview.links.location = Self.onServer("/srv/docs/README.md")
        #expect(preview.documentLocation(for: copy) == Self.onServer("/srv/docs/README.md"))
    }

    // MARK: - The words

    @Test("every refusal says something, and names what it names in any language")
    func refusalSentences() {
        let host = BrowserWindowController.sentence(for: .anotherHost("nas.example"))
        #expect(host.contains("nas.example"))
        let scheme = BrowserWindowController.sentence(for: .scheme("javascript"))
        #expect(scheme.contains("javascript:"))
        #expect(!BrowserWindowController.sentence(for: .localFile).isEmpty)
        #expect(!BrowserWindowController.sentence(for: .malformed).isEmpty)
    }
}

/// A web surface built the way a preview builds one, under the shipped rule list, in a window of its
/// own so a page lays out and scrolls.
@MainActor
enum QuickViewLinkSurface {
    /// Waited for rather than resumed through a continuation: the completion hands back a main-actor
    /// view, which Swift 6 refuses to send across a continuation.
    static func built() async throws -> QuickViewWebView {
        var built: QuickViewWebView?
        QuickViewWebView.withContentRules(findOptions: QuickViewFindOptionsStore.scratch()) {
            built = $0
        }
        for _ in 0..<600 where built == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return try #require(built)
    }

    private static var retained: [NSWindow] = []

    static func hosted() async throws -> (QuickViewWebView, NSWindow) {
        let surface = try await built()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        // Kept for the life of the process and never closed: closing one crashed the test host in an
        // autorelease pool pop a test later, as `TrashlessProbe.window()` records (docs/NOTES.md ▸
        // Testing), and `isReleasedWhenClosed = false` alone was not the house fix.
        retained.append(window)
        let content = try #require(window.contentView)
        content.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            surface.topAnchor.constraint(equalTo: content.topAnchor),
            surface.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        content.layoutSubtreeIfNeeded()
        return (surface, window)
    }
}
