import Foundation

/// A rendered Markdown document, ready for the app to wrap and style.
public struct MarkdownRender: Equatable, Sendable {
    /// An HTML **fragment** — the document's body and nothing around it. The `<html>`, the
    /// `<style>` and the appearance they carry are the app's (PLAN.md §M18 ▸ Slice 3).
    public let html: String

    /// The document's own title: its front matter's `title`, or its first heading when that is
    /// level 1; `nil` when it names none (`MarkdownTitle`). What an exported page carries in its
    /// `<title>` (PLAN.md §M39 ▸ Slice 11).
    public let title: String?

    public init(html: String, title: String? = nil) {
        self.html = html
        self.title = title
    }
}

/// The caller's say over the parts of rendering that are not the core's to decide.
///
/// Three fields, and each one is a seam a *probe* put there rather than a setting somebody wanted:
/// how a generated document reaches a sibling image (a generated page has **no** filesystem access,
/// so the app hands the bytes over — Slice 3), how wide a label is in the font the page will draw it
/// in (the core imports no AppKit — Slice 4), and what to *call* a diagram construct that was not
/// drawn (a sentence in the core is a sentence nobody can translate — docs/NOTES.md ▸ Localization).
///
/// Every default is the answer that depends on nothing, so no parser test's output turns on how the
/// app fills these in.
public struct MarkdownRenderOptions: Sendable {
    /// Maps an image's `src` as written to the one the page should load.
    ///
    /// Called from the render, which runs off the main actor — hence `@Sendable`. The app's
    /// implementation reads the file and returns a `data:` URI; anything it will not or cannot
    /// inline comes back unchanged.
    public var resolveImageSource: @Sendable (String) -> String

    /// How wide a string is in the page's font. See `MarkdownTextMetric` for what the probe
    /// measured and why this is a plain `@Sendable` closure rather than a main-actor hop.
    public var textMetric: MarkdownTextMetric

    /// The sentence naming a diagram type or construct that was not drawn, given its bare name
    /// (`stateDiagram-v2`, `subgraph`).
    ///
    /// A *closure*, not a string the core writes, and that is the whole reason it exists: the page
    /// has to say what it left out, in the user's language, and the core ships no resources. The
    /// default is the English fallback — readable, and the shape `VFSUnsupportedReason` already
    /// established for the same problem.
    public var describeUndrawnDiagram: @Sendable (String) -> String

    /// How much larger than its laid-out size a diagram is drawn.
    ///
    /// A magnification, not a second layout: it scales the `<svg>`'s displayed width and height and
    /// leaves the `viewBox` alone (`MermaidSVG.document`), so every proportion the layout measured
    /// survives it. `1` is the size the layout produced, which is what every test that pins an
    /// exact number is written against.
    public var diagramScale: Double

    /// The title a GitHub alert draws above its text, `Note` for `[!NOTE]`.
    ///
    /// A closure for `describeUndrawnDiagram`'s reason: the title is a word on the page, so it is the
    /// app's to translate. The default is GitHub's English.
    public var alertTitle: @Sendable (MarkdownAlertKind) -> String

    /// The file at `path`, written relative to the document's folder with nothing left to decode:
    /// `path` itself, or spelled as the file is when a disk that ignores case found it under
    /// another; `nil` when there is none. It decides whether `[[name]]` is a link, and where to
    /// (`MarkdownWikiLink`), and it is asked once per path per render.
    ///
    /// A closure for `resolveImageSource`'s reason: the render does no I/O, and only the app knows
    /// whether the document is on this disk or on a server it holds a listing of. The default
    /// finds nothing, so a page rendered without the app's say draws every `[[name]]` as the text it
    /// was written as.
    public var locateFile: @Sendable (String) -> String?

    /// Now, for a gantt chart: its today line, and the date its tasks fall back on where Mermaid
    /// takes today's (PLAN.md §M39 ▸ Slice 15).
    ///
    /// Handed in rather than read, so a render depends only on what it is given. The default is
    /// none: no today line, and the chart drawn from the file's dates alone.
    public var now: Date?

    /// The zone whose wall clock `now`, a `Z` offset and a Unix timestamp are read in. A gantt's own
    /// dates are wall clocks and never pass through it (`MermaidGanttTime`). UTC by default.
    public var timeZone: TimeZone

    public init(
        resolveImageSource: @escaping @Sendable (String) -> String = { $0 },
        textMetric: MarkdownTextMetric = .fixedAdvance,
        describeUndrawnDiagram: @escaping @Sendable (String) -> String = {
            "“\($0)” is not drawn in this preview."
        },
        diagramScale: Double = 1,
        alertTitle: @escaping @Sendable (MarkdownAlertKind) -> String = MarkdownRenderOptions.englishAlertTitle,
        locateFile: @escaping @Sendable (String) -> String? = { _ in nil },
        now: Date? = nil,
        timeZone: TimeZone = TimeZone(secondsFromGMT: 0) ?? .current
    ) {
        self.resolveImageSource = resolveImageSource
        self.textMetric = textMetric
        self.describeUndrawnDiagram = describeUndrawnDiagram
        self.diagramScale = diagramScale
        self.alertTitle = alertTitle
        self.locateFile = locateFile
        self.now = now
        self.timeZone = timeZone
    }

    /// GitHub's own titles, which it draws in English whatever the reader's language.
    public static func englishAlertTitle(_ kind: MarkdownAlertKind) -> String {
        switch kind {
        case .note: "Note"
        case .tip: "Tip"
        case .important: "Important"
        case .warning: "Warning"
        case .caution: "Caution"
        }
    }
}

/// Markdown, rendered as the document it describes (PLAN.md §M18).
///
/// The public face of the milestone's core half, and deliberately the only one: the block model,
/// the two parsers and the HTML writer are all internal, so the app depends on *what a `.md` looks
/// like rendered* rather than on how it was read. That is the same line `TextPreview` draws — the
/// core turns bytes into something showable, and the app decides which surface shows it.
///
/// Hand-rolled, with no third-party renderer anywhere in it, for the reasons M17 rejected the
/// equivalent shortcut for highlighting: a dependency here is a parser this project cannot test,
/// running over files a user pointed at by accident.
///
public enum MarkdownDocument {
    public static func render(
        _ text: String,
        options: MarkdownRenderOptions = MarkdownRenderOptions()
    ) -> MarkdownRender {
        let scan = MarkdownBlockParser.scan(text)
        return MarkdownRender(
            html: MarkdownHTMLRenderer.render(scan, options: options),
            title: MarkdownTitle.of(scan)
        )
    }

    /// The class a colored run inside a fence carries, or `nil` for a run the scanner made no
    /// claim about — which is emitted as bare text, since an unclaimed run is already the page's
    /// own color and a span for it would change nothing.
    ///
    /// Public because the *stylesheet* is the app's, and a stylesheet has to name these. Deriving
    /// the name on both sides is the trap docs/NOTES.md keeps finding — one rule, two spellings,
    /// and the compiler checks neither; the failure here would be a fence rendering in flat text
    /// with every automated signal green. Handing the name over instead means the app writes one
    /// rule per `SyntaxToken.Kind` and a kind added later cannot be silently uncolored.
    public static func tokenClass(for kind: SyntaxToken.Kind) -> String? {
        switch kind {
        case .keyword: "tok-keyword"
        case .string: "tok-string"
        case .comment: "tok-comment"
        case .number: "tok-number"
        case .typeOrTag: "tok-type"
        case .inserted: "tok-inserted"
        case .deleted: "tok-deleted"
        case .plain: nil
        }
    }
}
