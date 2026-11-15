import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// A gantt chart's colors (PLAN.md §M39 ▸ Slice 15): each state's fill is a mix of one of the page's
/// colors into its background, and a task's name is drawn on it in the text color, so the mix is
/// what has to stay legible, in both appearances and in the page WebKit really draws.
@Suite("Quick View Markdown gantt charts")
@MainActor
struct QuickViewMarkdownGanttTests {
    private static let source = """
    ```mermaid
    gantt
        dateFormat YYYY-MM-DD
        section Build
        Parser :done, p, 2014-01-06, 2d
        Lexer :active, l, after p, 3d
        Plain :t, after l, 2d
        Fix :crit, f, after t, 2d
    ```
    """

    @Test("a name on every state's fill clears 4.5:1, and every outline 3:1, in both appearances")
    func fillsAreLegible() {
        let page = QuickViewMarkdownStyle.document(body: "<p>x</p>")
        func values(_ name: String) -> [String] { QuickViewMarkdownAlertTests.values(
            of: name,
            in: page
        ) }
        let backgrounds = values("--background")
        let texts = values("--text")
        #expect(backgrounds.count == 2)
        #expect(texts.count == 2)
        for fill in QuickViewMarkdownGantt.fills {
            let inks = values(fill.ink)
            #expect(inks.count == 2, "\(fill.ink) is not defined for both appearances")
            for index in inks.indices {
                let mixed = Self.mix(inks[index], fill.percent, into: backgrounds[index])
                let ratio = QuickViewMarkdownAlertTests.contrast(texts[index], mixed)
                #expect(ratio >= 4.5, "text on \(fill.selector) (\(mixed)) scores \(ratio)")
                let outline = QuickViewMarkdownAlertTests.contrast(inks[index], backgrounds[index])
                #expect(outline >= 3, "\(fill.ink) on the page scores \(outline)")
            }
        }
    }

    @Test("WebKit resolves each state's `color-mix` fill to a color of its own")
    func drawnInARealPage() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("plan.md", contents: Self.source)
        let (surface, _) = try await QuickViewLinkSurface.hosted()
        let scan = try #require(QuickViewPreviewView.MarkdownScan.read(url))
        surface.showMarkdown(scan, source: url)
        try await Self.until { await Self.evaluate(
            "document.querySelectorAll('svg.mermaid-gantt rect.mm-gantt-bar').length",
            in: surface
        ) as? Int == 4 }

        let fills = await Self.evaluate(
            "[...document.querySelectorAll('rect.mm-gantt-bar')].map(r => getComputedStyle(r).fill)",
            in: surface
        ) as? [String]
        let drawn = try #require(fills)
        let background = await Self.evaluate(
            "getComputedStyle(document.body).backgroundColor",
            in: surface
        ) as? String
        // Four states, four colors, none of them the page itself or a failed `color-mix` (black).
        #expect(Set(drawn).count == 4, "\(drawn)")
        #expect(!drawn.contains(background ?? ""))
        #expect(!drawn.contains("rgb(0, 0, 0)"))
        #expect(drawn.allSatisfy { $0.hasPrefix("rgb(") || $0.hasPrefix("color(srgb") }, "\(drawn)")

        // Shrunk to the pane, never wider than the page.
        let page = await Self.number("document.documentElement.scrollWidth", in: surface)
        let window = await Self.number("window.innerWidth", in: surface)
        #expect(page <= window, "the page is \(page) wide in a \(window) window")
    }

    // MARK: - Helpers

    /// CSS's `color-mix(in srgb, ink p%, paper)`, written out by hand: each sRGB channel weighted.
    static func mix(_ ink: String, _ percent: Int, into paper: String) -> String {
        func channels(_ hex: String) -> [Double] {
            let digits = Array(hex.dropFirst())
            return stride(from: 0, to: 6, by: 2).map {
                Double(Int(String(digits[$0..<$0 + 2]), radix: 16) ?? 0)
            }
        }
        let weight = Double(percent) / 100
        let mixed = zip(channels(ink), channels(paper)).map { ($0 * weight + $1 * (1 - weight)).rounded(
        ) }
        return "#" + mixed.map { String(format: "%02X", Int($0)) }.joined()
    }

    private static func evaluate(_ expression: String, in surface: QuickViewWebView) async -> Any? {
        try? await surface.webView.callAsyncJavaScript(
            "return \(expression);",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
    }

    private static func number(_ expression: String, in surface: QuickViewWebView) async -> Double {
        (await evaluate(expression, in: surface) as? NSNumber)?.doubleValue ?? -1
    }

    /// Wait for `predicate`, up to two minutes, for the reason `QuickViewLinkClickTests.until` gives.
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
