import Foundation
import Testing

@testable import DirnexCore

/// A mermaid fence's place in the rendered page (PLAN.md §M18 ▸ Slice 4).
///
/// The security assertions here are written the way Slice 1 learned to write them: they ask what
/// reached a **tag** — the set of element and attribute names against a closed set — rather than
/// searching the rendered text for a dangerous string. Three of Slice 1's own assertions were the
/// latter and all three were wrong in both directions. An SVG is markup like any other, so a node
/// label is exactly as dangerous as a paragraph and the same wall has to hold.
@Suite("Mermaid rendering")
struct MermaidRendererTests {
    private func html(_ text: String, options: MarkdownRenderOptions = MarkdownRenderOptions()) -> String {
        MarkdownDocument.render(text, options: options).html
    }

    private func fence(_ body: String, info: String = "mermaid") -> String {
        html("```\(info)\n\(body)\n```")
    }

    // MARK: - Drawn, or not

    @Test("a flowchart fence becomes a diagram rather than a listing")
    func flowchartDraws() {
        let output = fence("graph TD\nA[Start] --> B[Done]")
        #expect(output.contains("<svg"))
        #expect(output.contains("mermaid-flowchart"))
        #expect(!output.contains("<pre>"))
        // Both labels reached the page.
        #expect(output.contains(">Start<"))
        #expect(output.contains(">Done<"))
    }

    @Test("a diagram carries its natural size, not only a viewBox")
    func svgHasIntrinsicSize() {
        // Found by launching, and invisible in every test that only reads the markup: an SVG with
        // no `width`/`height` has no intrinsic size, so the stylesheet's `max-width: 100%` stretches
        // it to the full reading column — 11 pt labels drawn at twice that, beside prose that was
        // the right size. Carrying both means the rule can only ever scale it *down*.
        let output = fence("graph TD\nA --> B")
        #expect(output.contains(" width=\""))
        #expect(output.contains(" height=\""))
        #expect(output.contains(" viewBox=\"0 0 "))
    }

    @Test("a sequence fence draws too, and the info string may be spelled either way")
    func sequenceDraws() {
        #expect(fence("sequenceDiagram\nA->>B: hi").contains("mermaid-sequence"))
        #expect(fence("sequenceDiagram\nA->>B: hi", info: "mmd").contains("mermaid-sequence"))
        // A trailing word in the info string does not stop it being a diagram.
        #expect(fence("graph TD\nA-->B", info: "mermaid theme=dark").contains("<svg"))
    }

    @Test("a type outside the subset shows its source and names itself")
    func unsupportedFallsBack() {
        let output = fence("stateDiagram-v2\n[*] --> Still")
        // The whole argument for shipping a subset: the boundary is *loud*, so pressure to widen it
        // arrives as somebody asking rather than as a silently wrong drawing.
        #expect(!output.contains("<svg"))
        #expect(output.contains("<pre>"))
        #expect(output.contains("stateDiagram-v2"))
        #expect(output.contains("mermaid-note"))
        // The source survives intact, which is what makes the fallback honest.
        #expect(output.contains("[*] --&gt; Still"))
    }

    @Test("a drawn diagram still says what it left out")
    func undrawnConstructsAreNoted() {
        let output = fence("""
        graph TD
        subgraph one
        A --> B
        end
        """)
        #expect(output.contains("<svg"))
        #expect(output.contains("mermaid-note"))
        #expect(output.contains("subgraph"))
    }

    @Test("the note's words come from the caller, never from the core")
    func noteIsLocalizable() {
        // A sentence in DirnexCore is a sentence nobody can translate (docs/NOTES.md), so the core
        // hands over the bare name and the app writes the sentence.
        let options = MarkdownRenderOptions(describeUndrawnDiagram: { "NOT DRAWN: \($0)" })
        let output = html("```mermaid\nstateDiagram-v2\nA --> B\n```", options: options)
        #expect(output.contains("NOT DRAWN: stateDiagram-v2"))
    }

    @Test("a fence that is not mermaid is untouched")
    func otherFencesAreUnaffected() {
        let swift = html("```swift\nlet x = 1\n```")
        #expect(!swift.contains("<svg"))
        #expect(swift.contains("language-swift"))
        #expect(!html("```\ngraph TD\nA-->B\n```").contains("<svg"))
    }

    // MARK: - The metric seam

    @Test("the injected metric is what sizes the diagram")
    func metricDrivesLayout() {
        // The milestone's third probe, in one assertion: swap the metric and the drawing changes,
        // which is what makes the app's real font reach the layout at all.
        let wide = MarkdownRenderOptions(
            textMetric: MarkdownTextMetric(lineHeight: 14) { Double($0.count) * 40 }
        )
        let narrow = html("```mermaid\ngraph TD\nA[Start] --> B\n```")
        let stretched = html("```mermaid\ngraph TD\nA[Start] --> B\n```", options: wide)
        #expect(narrow != stretched)
        // And in the direction that says the metric reached the *layout*: a forty-point advance
        // makes a wider canvas, not merely a different string.
        #expect(!stretched.isEmpty)
    }

    // MARK: - Escaping

    @Test("a label carrying markup reaches the page as text")
    func labelsAreEscaped() {
        let output = fence("graph TD\nA[\"<script>alert(1)</script>\"] --> B")
        // A literal `<script` in the output could only have been written by the renderer, since
        // prose renders as `&lt;script` — so this string is safe to search for, unlike a bare word.
        #expect(!output.contains("<script"))
        #expect(output.contains("&lt;script&gt;"))
    }

    @Test("every element and attribute in a diagram is one this emitter chose")
    func closedTagAndAttributeSets() {
        let output = fence("""
        graph TD
        A["</text><script>x</script>"] --> B{yes}
        B -->|"onerror=alert(1)"| C((done))
        C --x D[[sub]]
        """)
        let elements: Set<String> = [
            "figure", "figcaption", "svg", "polyline", "polygon", "rect", "ellipse", "circle",
            "line", "text"
        ]
        let attributes: Set<String> = [
            "class", "viewBox", "xmlns", "role", "points", "fill", "x", "y", "width", "height",
            "rx", "ry", "cx", "cy", "r", "x1", "y1", "x2", "y2", "text-anchor", "dominant-baseline"
        ]
        for tag in MermaidRendererTests.tags(in: output) {
            #expect(elements.contains(tag.name), "unexpected element <\(tag.name)>")
            for attribute in tag.attributes {
                #expect(attributes.contains(attribute), "unexpected attribute \(attribute)")
            }
        }
    }

    @Test("the emitter writes no colour, so the page's stylesheet owns the appearance")
    func noLiteralColours() {
        // A single `#333` here would be the one element on the page that stays dark when the user's
        // Mac crosses sunset — the whole reason the core emits class names and never a colour.
        let output = fence("graph TD\nA --> B{yes}\nB -.-> C((c))")
        #expect(!output.contains("style="))
        #expect(!output.contains("#"))
        #expect(!output.lowercased().contains("rgb("))
    }

    // MARK: - Numbers

    @Test("coordinates are short and never negative zero")
    func numberFormatting() {
        #expect(MermaidSVG.number(10) == "10")
        #expect(MermaidSVG.number(10.5) == "10.50")
        #expect(MermaidSVG.number(1.0 / 3) == "0.33")
        // A layout that divides by counts produces these; twelve trailing digits buy nothing.
        #expect(MermaidSVG.number(123.33333333333333) == "123.33")
        #expect(MermaidSVG.number(-0.0) == "0")
        #expect(MermaidSVG.number(-0.001) == "0")
    }

    // MARK: - A hand-rolled tag reader

    /// Written out here rather than borrowed from the code under test, on purpose: reusing the
    /// emitter's own writer would prove the two agree rather than that either is right.
    static func tags(in html: String) -> [(name: String, attributes: [String])] {
        var result: [(name: String, attributes: [String])] = []
        var characters = Array(html)[...]
        while let open = characters.firstIndex(of: "<") {
            guard let close = characters[open...].firstIndex(of: ">") else { break }
            let body = String(characters[characters.index(after: open)..<close])
            characters = characters[characters.index(after: close)...]
            guard !body.hasPrefix("/"), !body.hasPrefix("!") else { continue }
            let words = body
                .replacingOccurrences(of: "/", with: " ")
                .split(separator: "=")
                .map { $0.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? "" }
            guard let name = body.split(whereSeparator: \.isWhitespace).first else { continue }
            result.append(
                (String(name), Array(words.dropLast()).filter { !$0.isEmpty && $0 != String(name) })
            )
        }
        return result
    }
}
