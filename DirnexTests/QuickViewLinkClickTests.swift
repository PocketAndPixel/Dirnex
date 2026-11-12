import AppKit
import DirnexCore
import Testing
import WebKit

@testable import Dirnex

/// A click on a link in a real page, and the heading a link named (PLAN.md §M39 ▸ Slice 5).
///
/// The clicks are synthetic, sent with `click()` from the isolated world the find uses, so the page's
/// own scripts stay off as they ship. Probed 2026-11-12 before the slice: such a click reaches
/// `decidePolicyFor` as a link activation, resolved against the generated page's base URL, which is
/// what these read back.
@Suite("Quick View link clicks in a real page", .serialized)
@MainActor
struct QuickViewLinkClickTests {
    /// What the surface handed on, in order.
    @MainActor
    private final class Followed {
        var links: [(link: DocumentLink, location: VFSPath)] = []
    }

    private static let filler = (1...120).map { "Paragraph \($0) of the filler." }
        .joined(separator: "\n\n")

    @Test(
        "an anchor scrolls the page itself, and a link out is handed on with the document's location"
    )
    func clicks() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("README.md", contents: """
        [jump](#far) [next](other%20file.md#sec) [web](https://example.com/x)

        \(Self.filler)

        ## Far
        """)
        let location = VFSPath(backend: VFSBackendID("sftp://u@nas:22"), path: "/srv/docs/README.md")
        let (surface, _) = try await QuickViewLinkSurface.hosted()
        let followed = Followed()
        surface.onFollowLink = { followed.links.append(($0, $1)) }
        let scan = try #require(QuickViewPreviewView.MarkdownScan.read(url))
        surface.showMarkdown(scan, source: url, location: location)
        try await Self.waitForLinks(3, in: surface)

        try await Self.click("a[href='#far']", in: surface)
        try await Self.until { await Self.scrollY(of: surface) > 0 }
        // The anchor was allowed, so it was not handed on. The link below is the control: the same
        // handler hears it.
        try await Self.click("a[href^='other']", in: surface)
        try await Self.until { followed.links.count >= 1 }
        #expect(followed.links.count == 1)
        let sibling = VFSPath(backend: location.backend, path: "/srv/docs/other file.md")
        #expect(followed.links.first?.link == .location(sibling, fragment: "sec"))
        #expect(followed.links.first?.location == location)

        try await Self.click("a[href^='https']", in: surface)
        try await Self.until { followed.links.count >= 2 }
        #expect(
            followed.links.last?.link == .external(
                try #require(URL(string: "https://example.com/x"))
            )
        )
    }

    /// The case the live run caught (2026-11-13): a server's HTML file is drawn from a lone local copy,
    /// and loaded from that copy WebKit dropped every link to a sibling unasked, since none exists on
    /// this disk. Drawn under its location's base URL, the click arrives.
    @Test("a server's HTML file hands on a link to a sibling its local copy does not have")
    func copiedPage() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let copy = try tree.write("index.html", contents: """
        <!doctype html><meta charset="utf-8"><a href="about%20us.html#team">About</a>
        """)
        let location = VFSPath(
            backend: VFSBackendID("sftp://u@nas:22"),
            path: "/srv/site/index.html"
        )
        let (surface, _) = try await QuickViewLinkSurface.hosted()
        let followed = Followed()
        surface.onFollowLink = { followed.links.append(($0, $1)) }
        surface.show(copy, location: location)
        try await Self.waitForLinks(1, in: surface)

        try await Self.click("a", in: surface)
        try await Self.until { followed.links.count >= 1 }
        let sibling = VFSPath(backend: location.backend, path: "/srv/site/about us.html")
        #expect(followed.links.first?.link == .location(sibling, fragment: "team"))
        #expect(followed.links.first?.location == location)
    }

    @Test("a page a link named a heading in opens scrolled to it, and one without opens at the top")
    func scrollsToTheNamedHeading() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        // Filler after the heading too, so the page can scroll it all the way to the top.
        let url = try tree.write(
            "other.md",
            contents: "# Top\n\n\(Self.filler)\n\n## Sec\n\n\(Self.filler)\n"
        )
        let (surface, _) = try await QuickViewLinkSurface.hosted()
        let scan = try #require(QuickViewPreviewView.MarkdownScan.read(url))

        // The control: the same page with no heading named stays at the top once it has loaded.
        surface.showMarkdown(scan, source: url)
        try await Self.waitForElement("sec", in: surface)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await Self.scrollY(of: surface) == 0)

        surface.showMarkdown(scan, source: url, fragment: "sec")
        try await Self.until { await Self.scrollY(of: surface) > 0 }
        let top = try await surface.webView.callAsyncJavaScript(
            "return Math.round(document.getElementById('sec').getBoundingClientRect().top);",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        ) as? Int
        #expect(top == 0)
    }

    // MARK: - Helpers

    private static func click(_ selector: String, in surface: QuickViewWebView) async throws {
        _ = try await surface.webView.callAsyncJavaScript(
            "document.querySelector(selector).click(); return true;",
            arguments: ["selector": selector],
            in: nil,
            contentWorld: .defaultClient
        )
    }

    private static func scrollY(of surface: QuickViewWebView) async -> Double {
        let value = try? await surface.webView.callAsyncJavaScript(
            "return window.scrollY;",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
        return (value as? NSNumber)?.doubleValue ?? -1
    }

    private static func waitForLinks(_ count: Int, in surface: QuickViewWebView) async throws {
        try await until {
            let found = try? await surface.webView.callAsyncJavaScript(
                "return document.querySelectorAll('a').length;",
                arguments: [:],
                in: nil,
                contentWorld: .defaultClient
            ) as? Int
            return (found ?? 0) >= count
        }
    }

    private static func waitForElement(_ id: String, in surface: QuickViewWebView) async throws {
        try await until {
            let found = try? await surface.webView.callAsyncJavaScript(
                "return document.getElementById(id) !== null;",
                arguments: ["id": id],
                in: nil,
                contentWorld: .defaultClient
            ) as? Bool
            return found == true
        }
    }

    /// Wait for `predicate`, up to two minutes. Under the whole app suite a page here was still not
    /// drawn after 10 s, and on a busier run after 30 s, while a test of this file's with no web view
    /// at all took 44 s (seen 2026-11-13): the main actor is shared with every other suite, so the
    /// deadline only bounds a real failure. A timeout stops the test rather than letting the next
    /// step run against a page that is not there.
    private static func until(
        within: Duration = .seconds(120),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ predicate: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + within
        while await !predicate() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for the page", sourceLocation: sourceLocation)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
