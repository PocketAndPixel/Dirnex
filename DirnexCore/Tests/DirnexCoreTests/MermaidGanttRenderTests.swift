import Foundation
import Testing

@testable import DirnexCore

/// A gantt fence on the page (PLAN.md §M39 ▸ Slice 15): drawn with class names only, every name
/// escaped, its title above it, and a fence Mermaid would refuse shown as its source.
@Suite("Mermaid gantt rendering")
struct MermaidGanttRenderTests {
    private func fence(_ body: String, options: MarkdownRenderOptions = MarkdownRenderOptions()) -> String {
        MarkdownDocument.render("```mermaid\n\(body)\n```", options: options).html
    }

    private static let sample = """
    gantt
        title Plan & <b>schedule</b>
        dateFormat YYYY-MM-DD
        excludes weekends
        section Build
        Parser :done, p, 2014-01-06, 2d
        </text><script>alert(1)</script> :active, s, after p, 3d
        Critical :crit, c, after s, 2d
        Ship :milestone, m, after c, 0d
        Freeze :vert, f, 2014-01-10, 0d
        click p href "javascript:alert(1)"
    """

    @Test("a gantt fence draws, with every state's class")
    func draws() {
        let output = fence(Self.sample)
        #expect(output.contains("mermaid-gantt"))
        #expect(!output.contains("<pre>"))
        for name in [
            "mm-gantt-done",
            "mm-gantt-active",
            "mm-gantt-crit",
            "mm-gantt-task",
            "mm-gantt-band",
            "mm-gantt-excluded",
            "mm-gantt-grid",
            "mm-gantt-tick",
            "mm-gantt-section",
            "mm-gantt-milestone-label",
            "mm-gantt-vert",
            "mm-gantt-vert-label"
        ] {
            #expect(output.contains(name), "missing \(name)")
        }
        #expect(output.contains("<polygon class=\"mm-gantt-bar mm-gantt-task\""))
        #expect(output.contains(">2014-01-07<"))
    }

    @Test("names and the title are escaped; nothing from the file reaches a tag or an attribute")
    func escaped() {
        let output = fence(Self.sample)
        #expect(!output.contains("<script>"))
        #expect(!output.contains("javascript:"))
        #expect(output.contains("&lt;/text&gt;&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(
            output.contains("<p class=\"mermaid-title\">Plan &amp; &lt;b&gt;schedule&lt;/b&gt;</p>")
        )
        #expect(!output.contains("style="))
        #expect(!output.contains("fill=\"#"))
    }

    @Test("click is named under the drawing")
    func caption() {
        #expect(fence(Self.sample).contains("“click” is not drawn in this preview."))
    }

    @Test("the title statement wins over the front matter's, which is used when there is none")
    func titles() {
        let both = fence(
            "---\ntitle: Front\n---\ngantt\n    title Statement\n    A :a, 2014-01-01, 1d"
        )
        #expect(both.contains(">Statement</p>"))
        #expect(!both.contains(">Front</p>"))
        let front = fence("---\ntitle: Front\n---\ngantt\n    A :a, 2014-01-01, 1d")
        #expect(front.contains(">Front</p>"))
    }

    @Test("the today line is drawn from the clock the options hand in")
    func todayLine() {
        let body = "gantt\n    A :a, 2014-01-01, 2014-01-11"
        #expect(!fence(body).contains("mm-gantt-today"))
        let clocked = MarkdownRenderOptions(now: Date(timeIntervalSince1970: 1_388_966_400))
        #expect(fence(body, options: clocked).contains("mm-gantt-today"))
        let off = "gantt\n    todayMarker off\n    A :a, 2014-01-01, 2014-01-11"
        #expect(!fence(off, options: clocked).contains("mm-gantt-today"))
    }

    @Test("the scale magnifies the displayed size and leaves the viewBox")
    func scaled() {
        let output = fence(
            "gantt\n    A :a, 2014-01-01, 1d",
            options: MarkdownRenderOptions(diagramScale: 2)
        )
        #expect(output.contains("width=\"1700\""))
        #expect(output.contains("viewBox=\"0 0 850 "))
    }

    @Test("a gantt Mermaid would refuse shows its source and names its type")
    func fallback() {
        let output = fence("gantt\n    A :a, not a date, 1d")
        #expect(output.contains("<pre><code class=\"language-mermaid\">"))
        #expect(output.contains("“gantt” is not drawn in this preview."))
        #expect(MermaidRenderer.unsupportedType(in: "gantt\n    A :3d") == "gantt")
        #expect(MermaidRenderer.unsupportedType(in: "gantt\n    A :a, 2014-01-01, 1d") == nil)
    }
}
