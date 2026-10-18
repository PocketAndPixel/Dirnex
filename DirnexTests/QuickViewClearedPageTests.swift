import AppKit
import Testing
import WebKit

@testable import Dirnex

/// What Quick View's web surface paints once it has been cleared (2026-10-18).
///
/// More than it sounds: a surface is put away holding that empty page, and the next rendered file
/// unhides it and *then* loads, so the empty page is on screen until the new one first paints. A bare
/// `""` paints WebKit's white canvas whatever the appearance, which in dark was a white flash ahead of
/// every Markdown page.
///
/// Read through `takeSnapshot`, which re-renders the page rather than reading the screen
/// (docs/NOTES.md ▸ Previews: web views). That is the right instrument here, since the claim is about
/// what the empty page itself paints; the on-screen half was measured live, by window capture.
@Suite("Quick View cleared page", .serialized)
@MainActor
struct QuickViewClearedPageTests {
    @Test("a cleared page paints the preview's own backing in dark, not white")
    func clearedPageIsDarkInDark() async throws {
        let color = try await Self.clearedPageColor(in: .darkAqua)
        #expect(Self.distance(color, from: .textBackgroundColor, in: .darkAqua) < 0.03, "\(color)")
    }

    /// The narrowness half: a fix that simply painted the page dark would trade the white flash in
    /// dark for a dark one in light.
    @Test("a cleared page stays white in light")
    func clearedPageIsWhiteInLight() async throws {
        let color = try await Self.clearedPageColor(in: .aqua)
        #expect(Self.distance(color, from: .textBackgroundColor, in: .aqua) < 0.03, "\(color)")
    }

    // MARK: - Helpers

    /// A surface that showed a red page and was then cleared in `appearance`: the color at its
    /// center once the red has gone.
    ///
    /// The wait is on the red going rather than on the load finishing, and the red page is there to
    /// make that possible: a web view that has never loaded anything already paints the dark canvas,
    /// so a snapshot taken before the empty page landed would pass against the broken build
    /// (docs/NOTES.md ▸ Testing — ask what the predicate would be true of in the broken build).
    private static func clearedPageColor(in appearance: NSAppearance.Name) async throws -> NSColor {
        let fixture = try await QuickViewPageFindFixtures.page(
            #"<html style="background: #ff0000"><body>red</body></html>"#
        )
        defer { fixture.cleanup() }
        let webView = fixture.surface.webView
        try #require(fixture.preview.window).appearance = NSAppearance(named: appearance)
        var color = try await centerColor(of: webView)
        for _ in 0..<300 where !isRed(color) {
            try? await Task.sleep(for: .milliseconds(10))
            color = try await centerColor(of: webView)
        }
        try #require(isRed(color), "the red page never drew, so its going would prove nothing")

        fixture.surface.clearPage()
        for _ in 0..<300 where isRed(color) || webView.isLoading {
            try? await Task.sleep(for: .milliseconds(10))
            color = try await centerColor(of: webView)
        }
        return color
    }

    /// The snapshot's center pixel, as the sRGB it is stored in.
    ///
    /// Rebuilt from the raw channels rather than converted, because `colorAt` hands back a color
    /// tagged *Generic* RGB from an image that is sRGB — measured, `usingColorSpace(.sRGB)` then
    /// turned the page's `#1E1E1E` into `#282828` and failed a page painting exactly the backing.
    private static func centerColor(of webView: WKWebView) async throws -> NSColor {
        let image = try await webView.takeSnapshot(configuration: nil)
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        try #require((cgImage.colorSpace?.name as String?) == (CGColorSpace.sRGB as String))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let pixel = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        return NSColor(
            srgbRed: pixel.redComponent,
            green: pixel.greenComponent,
            blue: pixel.blueComponent,
            alpha: 1
        )
    }

    private static func isRed(_ color: NSColor) -> Bool {
        color.redComponent > 0.8 && color.greenComponent < 0.2 && color.blueComponent < 0.2
    }

    /// The largest per-channel difference between `color` and `expected` as `appearance` resolves it.
    private static func distance(
        _ color: NSColor,
        from expected: NSColor,
        in appearance: NSAppearance.Name
    ) -> CGFloat {
        var resolved: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = expected.usingColorSpace(.sRGB)
        }
        guard let resolved else { return .infinity }
        return max(
            abs(color.redComponent - resolved.redComponent),
            abs(color.greenComponent - resolved.greenComponent),
            abs(color.blueComponent - resolved.blueComponent)
        )
    }
}
