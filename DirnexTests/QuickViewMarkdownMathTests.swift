import AppKit
import DirnexCore
import Testing
import WebKit

@testable import Dirnex

/// Math on the rendered page (PLAN.md §M39 ▸ Slice 8): the rules the core's classes are drawn with,
/// and the three things WebKit was seen to need, checked in a real page with scripts off.
@Suite("Quick View Markdown math", .serialized)
@MainActor
struct QuickViewMarkdownMathTests {
    /// A formula about twice as wide as the 420-point window the surface is hosted in (forty terms of
    /// some 20 points each), an `aligned` table, a fraction inline and an unknown command.
    private static let source = """
    # Math

    Inline $\\frac{1}{2}$ and an unknown $\\foo x$.

    $$
    s = \((1...40).map { "\\frac{1}{\($0)}" }.joined(separator: " + "))
    $$

    ```math
    \\begin{aligned}
    a &= b + c \\\\
    d + e &= f
    \\end{aligned}
    ```
    """

    // MARK: - The join

    @Test("every class the core emits for math has a rule, and the rules reach the page")
    func everyEmittedClassIsStyled() {
        let html = MarkdownDocument.render(Self.source).html
        let classes = QuickViewMarkdownDiagramTests.classNames(in: html)
        #expect(classes == ["math-display", "math-aligned", "math-unknown"])
        for name in classes {
            #expect(
                QuickViewMarkdownMath.rules.contains(".\(name)"),
                "no stylesheet rule names “\(name)”"
            )
        }
        #expect(QuickViewMarkdownStyle.document(body: html).contains(QuickViewMarkdownMath.rules))
    }

    @Test("an unknown command's red clears 4.5:1 on the page background, in both appearances")
    func unknownIsLegible() {
        let page = QuickViewMarkdownStyle.document(body: "<p>x</p>")
        let backgrounds = QuickViewMarkdownAlertTests.values(of: "--background", in: page)
        let reds = QuickViewMarkdownAlertTests.values(of: "--math-unknown", in: page)
        #expect(backgrounds.count == 2)
        #expect(
            reds == [
                QuickViewMarkdownMath.unknownColor.light,
                QuickViewMarkdownMath.unknownColor.dark
            ]
        )
        for (ink, paper) in zip(reds, backgrounds) {
            let ratio = QuickViewMarkdownAlertTests.contrast(ink, paper)
            #expect(ratio >= 4.5, "\(ink) on \(paper) scores \(ratio)")
        }
    }

    // MARK: - In a real page

    @Test("WebKit draws the MathML, scrolls a wide formula in its own box, and lines `aligned` up")
    func drawnInARealPage() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("math.md", contents: Self.source)
        let (surface, _) = try await QuickViewLinkSurface.hosted()
        let scan = try #require(QuickViewPreviewView.MarkdownScan.read(url))
        surface.showMarkdown(scan, source: url)
        try await Self.until { await Self.number(
            "document.querySelectorAll('math').length",
            in: surface
        ) == 4 }

        // Laid out as math: the inline half stands taller than a letter in the next formula.
        let fraction = await Self.number(
            "document.querySelector('p mfrac').getBoundingClientRect().height",
            in: surface
        )
        let letter = await Self.number(
            "document.querySelectorAll('p math')[1].querySelector('mi').getBoundingClientRect().height",
            in: surface
        )
        #expect(letter > 0)
        #expect(
            fraction > letter * 1.3,
            "the fraction is \(fraction) points tall, a letter \(letter)"
        )

        // The wide formula scrolls inside its wrapper, and the page itself does not widen.
        let wrapper = "document.querySelector('span.math-display')"
        let scrollWidth = await Self.number("\(wrapper).scrollWidth", in: surface)
        let clientWidth = await Self.number("\(wrapper).clientWidth", in: surface)
        #expect(scrollWidth > clientWidth + 100, "\(scrollWidth) against \(clientWidth)")
        let page = await Self.number("document.documentElement.scrollWidth", in: surface)
        let window = await Self.number("window.innerWidth", in: surface)
        #expect(page <= window, "the page is \(page) wide in a \(window) window")

        // `aligned`: both `=` at one x, each close to the `a` or `e` on its left.
        let equals = await Self.evaluate(
            "[...document.querySelectorAll('mtable.math-aligned mo')].filter(o => o.textContent == '=')"
                + ".map(o => o.getBoundingClientRect().left)",
            in: surface
        ) as? [NSNumber]
        let lefts = try #require(equals).map(\.doubleValue)
        #expect(lefts.count == 2)
        #expect(abs(lefts[0] - lefts[1]) < 0.5)
        let gap = await Self.number(
            "document.querySelectorAll('mtable.math-aligned mo')[0].getBoundingClientRect().left"
                + " - document.querySelector('mtable.math-aligned mi').getBoundingClientRect().right",
            in: surface
        )
        #expect(gap < 3, "`a` and its `=` are \(gap) points apart")

        // The unknown command in its red.
        let color = await Self.evaluate(
            "getComputedStyle(document.querySelector('.math-unknown')).color",
            in: surface
        ) as? String
        #expect(color == "rgb(209, 36, 47)" || color == "rgb(248, 81, 73)", "\(color ?? "none")")
    }

    // MARK: - Helpers

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
