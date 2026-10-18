import AppKit
import Testing
import WebKit

@testable import Dirnex

/// A new Quick View web view fades in when its first load ends (2026-10-18), which hides the frame
/// of white a brand-new content process paints before the page's own background (`fadeInOnce`).
///
/// That frame itself cannot be seen from here — it is a paint, and `takeSnapshot` re-renders rather
/// than reading the screen (docs/NOTES.md ▸ Previews: web views) — so it rests on the live window
/// capture. What is pinned is the fade's own hazards: a view that never becomes visible, and one
/// that fades on every file rather than only the first.
@Suite("Quick View web fade-in", .serialized)
@MainActor
struct QuickViewWebFadeInTests {
    @Test("a new web view starts transparent")
    func startsTransparent() async throws {
        let surface = try await Self.newSurface()
        #expect(surface.webView.alphaValue == 0)
    }

    @Test("its first page fades it in")
    func firstPageFadesIn() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let surface = try await Self.newSurface()
        surface.show(try tree.write("page.html", contents: "<p>hi</p>"))
        #expect(await Self.settledAlpha(of: surface) == 1)
    }

    /// The hazard the failure callbacks exist for: a first load that never finishes must not leave
    /// the page invisible for as long as the surface lives.
    @Test("a first page that fails to load fades it in all the same")
    func failedFirstLoadFadesIn() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let surface = try await Self.newSurface()
        surface.show(tree.root.appendingPathComponent("missing.html"))
        #expect(await Self.settledAlpha(of: surface) == 1)
    }

    /// The fade is for the first page only. Stepping from file to file, or putting the surface away
    /// and back, has to stay instant.
    @Test("later pages show at once, without fading again")
    func laterPagesDoNotFade() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let surface = try await Self.newSurface()
        surface.show(try tree.write("one.html", contents: "<p>one</p>"))
        #expect(await Self.settledAlpha(of: surface) == 1)

        surface.clearPage()
        #expect(surface.webView.alphaValue == 1)
        surface.show(try tree.write("two.html", contents: "<p>two</p>"))
        #expect(surface.webView.alphaValue == 1)
    }

    /// WebKit calls a delegate by selector, and a method on a `@MainActor` class can compile without
    /// being emitted (docs/NOTES.md ▸ the `@MainActor` delegate witness). A failure callback that
    /// never ran is the invisible page above, so they are asserted by selector string.
    @Test("the callbacks that end the fade's wait really answer")
    func answersTheCallbacks() async throws {
        let surface = try await Self.newSurface()
        for selector in [
            "webView:didFinishNavigation:",
            "webView:didFailNavigation:withError:",
            "webView:didFailProvisionalNavigation:withError:"
        ] {
            #expect(surface.responds(to: Selector(selector)), "\(selector)")
        }
    }

    // MARK: - Helpers

    /// Every fixture window, kept for the life of the process — tearing one down while AppKit is
    /// still settling it crashes a later test (docs/NOTES.md ▸ Testing).
    private static var windows: [NSWindow] = []

    /// A web surface built the way the preview builds one, pinned in a window, with nothing loaded.
    /// Polled with `Task.sleep` rather than spun: a run-loop spin never lets the rule compilation's
    /// continuation land (docs/NOTES.md ▸ Testing).
    private static func newSurface(function: String = #function) async throws -> QuickViewWebView {
        var built: QuickViewWebView?
        var answered = false
        QuickViewWebView.withContentRules(findOptions: .scratch(function: function)) {
            built = $0
            answered = true
        }
        for _ in 0..<1200 where !answered {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let surface = try #require(built)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        windows.append(window)
        let content = try #require(window.contentView)
        content.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            surface.topAnchor.constraint(equalTo: content.topAnchor),
            surface.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        content.layoutSubtreeIfNeeded()
        return surface
    }

    /// The web view's alpha once it has reached 1, or whatever it holds after a bounded wait, so a
    /// view that never fades fails on the caller's assertion rather than timing out.
    private static func settledAlpha(of surface: QuickViewWebView) async -> CGFloat {
        for _ in 0..<600 where surface.webView.alphaValue < 1 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return surface.webView.alphaValue
    }
}
