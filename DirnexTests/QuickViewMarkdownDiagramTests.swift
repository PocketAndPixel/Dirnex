import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The app's half of a mermaid diagram (PLAN.md §M18 ▸ Slice 4): the metric, the sentence, and the
/// stylesheet.
///
/// The suite's centre of gravity is the **join** between the core and the page, because that is
/// where this feature can fail with every other signal green. The core emits class names; the app
/// writes rules for them; nothing in the compiler relates the two. A class the core starts emitting
/// and the stylesheet never hears about is an invisible shape — a diagram with a missing box, no
/// error, no log line. That is the "one rule, two spellings" trap docs/NOTES.md keeps finding, and
/// `everyEmittedClassIsStyled` is the test that closes it.
@Suite("Quick View Markdown diagrams")
@MainActor
struct QuickViewMarkdownDiagramTests {
    /// A document exercising every construct the subset draws, so the class sweep below sees the
    /// whole vocabulary rather than the handful an ordinary diagram uses.
    private static let everyConstruct = """
    ```mermaid
    graph TD
        A[Square] --> B{Diamond}
        B -->|labelled| C(Rounded)
        B -. dotted .-> D((Circle))
        C ==> E[[Subroutine]]
        D --x F
        D --o G
        E <--> A
        F --> H --> I --> J
        F ==> J
    ```

    ```mermaid
    sequenceDiagram
        participant U as User
        actor Robot
        U->>Robot: ask
        activate Robot
        Robot->>Robot: think
        Robot-->>U: answer
        deactivate Robot
        Note over U,Robot: a note
        U-xRobot: cancel
    ```
    """

    private func render(_ source: String) -> String {
        MarkdownDocument.render(
            source,
            options: MarkdownRenderOptions(
                textMetric: QuickViewMarkdownDiagram.metric,
                describeUndrawnDiagram: { QuickViewMarkdownDiagram.describeUndrawn($0) }
            )
        ).html
    }

    // MARK: - The join

    @Test("every class the core emits has a rule in the stylesheet")
    func everyEmittedClassIsStyled() {
        let rules = QuickViewMarkdownDiagram.rules
        let classes = Self.classNames(in: render(Self.everyConstruct)).subtracting(Self.hooks)
        #expect(!classes.isEmpty)
        for name in classes.sorted() {
            #expect(rules.contains(name), "no stylesheet rule mentions “\(name)”")
        }
    }

    /// Classes the emitter writes to *identify* a diagram rather than to style it — they name which
    /// dialect drew the SVG, which the tests read and a future stylesheet may.
    ///
    /// A short, closed list on purpose. Exempting a class is then a deliberate edit here, which is
    /// the whole value of the sweep above: a class arriving with no rule and no entry fails.
    private static let hooks: Set<String> = ["mermaid-flowchart", "mermaid-sequence"]

    @Test("the diagram rules reach the page the preview actually loads")
    func rulesAreInTheDocument() {
        // The rules being *written* is not the same as their being *served*: they are spliced into
        // one `<style>` block a file away, and a missing splice is an unstyled diagram.
        let page = QuickViewMarkdownStyle.document(body: render(Self.everyConstruct))
        #expect(page.contains(".mm-node"))
        #expect(page.contains("svg.mermaid"))
    }

    // MARK: - The metric

    @Test("the metric measures real text in the font the stylesheet names")
    func metricMeasuresText() {
        let metric = QuickViewMarkdownDiagram.metric
        #expect(metric.width("") == 0)
        #expect(metric.width("Start") > 0)
        // Longer text is wider, and a proportional font is not a character count: `iiii` is
        // narrower than `WWWW`, which is exactly what the fixed-advance test metric cannot say and
        // why the app supplies a real one.
        #expect(metric.width("Start Start") > metric.width("Start"))
        #expect(metric.width("iiii") < metric.width("WWWW"))
        #expect(metric.lineHeight > 0)
    }

    @Test("the metric is the same font size the stylesheet draws in")
    func metricAndStylesheetAgree() {
        // The failure this pins has no error and no log: boxes sized for one font, text drawn in
        // another, and a diagram whose labels spill out of their outlines.
        #expect(QuickViewMarkdownDiagram.rules
            .contains(
                ".mm-label { fill: currentColor; font-size: \(QuickViewMarkdownDiagram.labelSize)px; }"
            ))
    }

    @Test("measuring is safe off the main actor, which is where the render runs")
    func metricIsUsableOffTheMainActor() async {
        // The milestone's probe measured this against four concurrent queues; the claim here is the
        // narrower one a test can make — that the closure crosses the boundary and answers the same.
        let metric = QuickViewMarkdownDiagram.metric
        let expected = metric.width("Is it markdown?")
        let measured = await Task.detached { metric.width("Is it markdown?") }.value
        #expect(measured == expected)
    }

    // MARK: - The sentence

    @Test("an undrawn type is named, in the app's words rather than the core's")
    func undrawnTypeIsNamed() {
        let output = render("```mermaid\nstateDiagram-v2\n[*] --> Still\n```")
        #expect(output.contains(QuickViewMarkdownDiagram.describeUndrawn("stateDiagram-v2")))
        // And the source is still there to read, which is what makes the fallback honest.
        #expect(output.contains("<pre>"))
    }

    @Test("the sentence carries the file's own keyword")
    func sentenceCarriesTheKeyword() {
        #expect(QuickViewMarkdownDiagram.describeUndrawn("gantt").contains("gantt"))
        #expect(QuickViewMarkdownDiagram.describeUndrawn("subgraph").contains("subgraph"))
        // Not merely the keyword: a sentence, so the page says something rather than showing a word.
        #expect(QuickViewMarkdownDiagram.describeUndrawn("gantt").count > "gantt".count + 4)
    }

    // MARK: - A hand-rolled class reader

    /// Written out rather than borrowed from the emitter, for the reason Slice 1 recorded: reusing
    /// the code under test would prove the two agree, not that either is right.
    static func classNames(in html: String) -> Set<String> {
        var names: Set<String> = []
        var rest = Substring(html)
        while let start = rest.range(of: "class=\"") {
            rest = rest[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            for name in rest[..<end].split(separator: " ") { names.insert(String(name)) }
            rest = rest[end...]
        }
        return names
    }
}
