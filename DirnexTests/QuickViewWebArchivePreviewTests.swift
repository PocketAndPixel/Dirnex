import AppKit
import DirnexCore
import Testing
import WebKit

@testable import Dirnex

/// The core's saved page, named apart from the legacy `WebKit.WebArchive` this file also sees, and
/// through an alias because `#require` cannot expand a module-qualified initializer.
private typealias CoreWebArchive = DirnexCore.WebArchive

/// Quick View's saved-page backend (PLAN.md §M39): which files it takes, what its read hands WebKit,
/// that the shipped rule list lets a sealed archive draw from itself, and what its frames and links
/// may navigate to.
///
/// What is not here is the network claim itself, for the reason `QuickViewHTMLPreviewTests` gives:
/// "nothing reached the network" is a measurement against a real server's access log, made for this
/// slice and recorded in PLAN.md. What is pinned is everything around it an edit could get wrong.
@Suite("Quick View web archive preview")
@MainActor
struct QuickViewWebArchivePreviewTests {
    private static let sealed = WebArchiveSeal.scheme + "://"

    // MARK: - Routing

    @Test("webarchive, mhtml and mht are saved pages, in any case")
    func recognizesSavedPages() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["x.webarchive", "page.mhtml", "page.mht", "PAGE.MHT", "Page.WebArchive"] {
            let url = try tree.write(name, contents: "x")
            #expect(QuickViewPreviewView.isWebArchive(url), "\(name) should be a saved page")
        }
        #expect(QuickViewPreviewView.isMHTML(try tree.write("a.mht", contents: "x")))
        #expect(!QuickViewPreviewView.isMHTML(try tree.write("b.webarchive", contents: "x")))
    }

    @Test("a page, a document or a text file is not a saved page")
    func leavesOtherFilesAlone() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["page.html", "README.md", "notes.txt", "letter.rtf", "archive.zip"] {
            let url = try tree.write(name, contents: "x")
            #expect(!QuickViewPreviewView.isWebArchive(url), "\(name) should not be a saved page")
        }
    }

    // MARK: - The read

    @Test(
        "a webarchive is read sealed: every URL in the scheme, and the page's own URL kept for anchors"
    )
    func readSealsAWebArchive() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("story.webarchive")
        try Self.archive().propertyListData().write(to: url)

        let page = try #require(QuickViewPreviewView.SavedPage.read(url))
        let archive = try #require(CoreWebArchive(propertyList: page.archive))
        #expect(archive.allURLs.allSatisfy { $0.hasPrefix(Self.sealed) })
        #expect(page.document == URL(string: Self.sealed + "o1/a/story.html"))
        let html = String(data: archive.mainResource.data, encoding: .utf8) ?? ""
        #expect(html.contains(#"src="x-dirnex-archive://o1/red.png""#))
        #expect(!html.contains("https://news.example"))
    }

    @Test("an MHTML file is converted, then sealed")
    func readConvertsMHTML() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("story.mhtml", contents: """
        Content-Type: multipart/related; boundary="b"

        --b
        Content-Type: text/html
        Content-Location: https://news.example/a/story.html

        <h1>Saved</h1><img src="https://news.example/red.png">
        --b
        Content-Type: image/png
        Content-Transfer-Encoding: base64
        Content-Location: https://news.example/red.png

        iVBORw0KGgo=
        --b--
        """)
        let page = try #require(QuickViewPreviewView.SavedPage.read(url))
        let archive = try #require(CoreWebArchive(propertyList: page.archive))
        #expect(archive.subresources.map(\.url) == [Self.sealed + "o1/red.png"])
        #expect(page.document == URL(string: Self.sealed + "o1/a/story.html"))
    }

    @Test("a file that is not the saved page its name says, or is over the limit, is not read")
    func readRefuses() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        #expect(
            QuickViewPreviewView.SavedPage.read(
                try tree.write("x.webarchive", contents: "not a plist")
            ) == nil
        )
        #expect(
            QuickViewPreviewView.SavedPage.read(try tree.write("x.mhtml", contents: "no headers")) == nil
        )
        // Sparse, so the test writes a few bytes and the file still measures past the limit.
        let large = tree.root.appendingPathComponent("large.webarchive")
        try Self.archive().propertyListData().write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(QuickViewPreviewView.webArchiveByteLimit) + 1)
        try handle.close()
        #expect(QuickViewPreviewView.SavedPage.read(large) == nil)
    }

    // MARK: - Drawn under the shipped rules

    /// The rule list is compiled once per process and is a precondition of the surface, so this is
    /// the check that its third rule exists and admits the scheme: a sealed image the archive holds
    /// is drawn, which the first two rules alone would block. The image the archive lacks is the
    /// control, and is not drawn.
    @Test("a sealed archive draws its own image under the shipped rule list")
    func drawsFromTheArchive() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("story.webarchive")
        try Self.archive().propertyListData().write(to: url)
        let preview = try await Self.loaded(url)
        let surface = try #require(preview.webSurface)
        #expect(surface.isHidden == false)
        #expect(surface.page?.archiveDocument == URL(string: Self.sealed + "o1/a/story.html"))

        let state = try await Self.pageState(in: surface)
        #expect(state["heading"] as? String == "Saved")
        #expect(state["image"] as? Int == 4)
        #expect(state["missing"] as? Int == 0)
        #expect((state["location"] as? String)?.hasPrefix(Self.sealed) == true)
    }

    // MARK: - Navigation

    @Test("a saved page's frames load from the archive, and nothing is followed by a click")
    func archiveNavigation() async throws {
        let surface = try await Self.surface()
        let document = try #require(URL(string: Self.sealed + "o1/a/story.html"))
        let directory = URL(fileURLWithPath: "/tmp/dirnex-archive-test", isDirectory: true)
        surface.showArchive(
            Data(),
            document: document,
            source: directory.appendingPathComponent("s.webarchive")
        )
        let frame = try #require(URL(string: Self.sealed + "cid/frame-1@mhtml.blink"))

        #expect(surface.isPermitted(frame, inFrame: true, isClick: false))
        #expect(!surface.isPermitted(frame, inFrame: true, isClick: true))
        #expect(
            !surface.isPermitted(URL(fileURLWithPath: "/etc/hosts"), inFrame: true, isClick: false)
        )
        #expect(
            !surface.isPermitted(
                try #require(URL(string: "https://elsewhere.example/")),
                inFrame: true,
                isClick: false
            )
        )
        // The main frame: the load itself, and the page's own anchors.
        #expect(surface.isPermitted(directory, inFrame: false, isClick: false))
        #expect(
            surface.isPermitted(
                try #require(URL(string: document.absoluteString + "#part")),
                inFrame: false,
                isClick: true
            )
        )
        #expect(!surface.isPermitted(document, inFrame: false, isClick: true))
        #expect(
            !surface.isPermitted(
                try #require(URL(string: Self.sealed + "o1/other.html")),
                inFrame: false,
                isClick: true
            )
        )
    }

    @Test("a plain page's frames are still refused the sealed scheme")
    func plainPageRefusesTheScheme() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let surface = try await Self.surface()
        surface.show(try tree.write("page.html", contents: "<p>hi</p>"))
        let frame = try #require(URL(string: Self.sealed + "o1/x.html"))
        #expect(!surface.isPermitted(frame, inFrame: true, isClick: false))
    }

    // MARK: - Helpers

    /// A saved page from `https://news.example`: a heading, a 4 × 4 PNG it holds, and one it lacks.
    private static func archive() throws -> CoreWebArchive {
        let html = #"<h1 id="h">Saved</h1><img id="i" src="https://news.example/red.png">"#
            + #"<img id="m" src="https://news.example/missing.png">"#
        return CoreWebArchive(
            mainResource: .init(
                url: "https://news.example/a/story.html",
                mimeType: "text/html",
                textEncodingName: "UTF-8",
                data: Data(html.utf8)
            ),
            subresources: [
                .init(url: "https://news.example/red.png", mimeType: "image/png", data: try png())
            ]
        )
    }

    private static func png() throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// A preview showing `url`, once its web surface is up. The window keeps it laid out.
    private static func loaded(_ url: URL) async throws -> QuickViewPreviewView {
        let preview = QuickViewPreviewView(
            backingColor: .textBackgroundColor,
            header: .none,
            findOptions: QuickViewFindOptionsStore.scratch()
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let content = try #require(window.contentView)
        content.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.topAnchor.constraint(equalTo: content.topAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        preview.show(url, style: .rendered)
        for _ in 0..<600 {
            if preview.webSurface?.isHidden == false { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        content.layoutSubtreeIfNeeded()
        return preview
    }

    /// A web surface built the way the preview builds one, under the shipped rule list.
    ///
    /// Waited for rather than resumed through a continuation: the completion hands back a main-actor
    /// view, which Swift 6 refuses to send across a continuation.
    private static func surface() async throws -> QuickViewWebView {
        var built: QuickViewWebView?
        QuickViewWebView.withContentRules(findOptions: QuickViewFindOptionsStore.scratch()) { built = $0 }
        for _ in 0..<600 where built == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return try #require(built)
    }

    /// What the page drew, read in the isolated world the find uses, once it has drawn.
    private static func pageState(in surface: QuickViewWebView) async throws -> [String: Any] {
        let script = """
        const h = document.getElementById('h'), i = document.getElementById('i'), m = document.getElementById('m');
        if (!h || !i.complete) { return null; }
        return { heading: h.textContent, image: i.naturalWidth, missing: m.naturalWidth, location: location.href };
        """
        for _ in 0..<400 {
            if let state = try? await surface.webView.callAsyncJavaScript(
                script, arguments: [:], in: nil, contentWorld: .defaultClient
            ) as? [String: Any] {
                return state
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the saved page never drew")
        return [:]
    }
}
