import Foundation

/// TeX math as MathML, for the math a Markdown document writes (PLAN.md §M39 ▸ Slice 8).
///
/// WebKit draws MathML with scripts off, so a formula is markup like any other on the generated
/// page and the page stays inert (PLAN.md §6). Nothing is borrowed: MathJax and KaTeX are scripts,
/// and a converter this project cannot test is the dependency M17 rejected for highlighting.
///
/// ## The subset
///
/// What a README or a paper's notes write: letters, numbers and operators; `^`, `_` and primes;
/// `\frac`, `\sqrt`, `\binom` and `\over`; Greek and the symbol commands (`TeXMathSymbols`); large
/// operators with their limits under and over in display, beside them inline; the named functions;
/// `\left…\right`, `\middle` and the `\big` family; the font commands (`TeXMathFont`) and `\text`;
/// the accents; spacing; `\not`; the size and style switches; and the matrix, `cases`, `aligned`,
/// `gathered` and `array` environments. **A command outside it is drawn as its own text**, in
/// the class `math-unknown`, and whatever follows it is read as usual, as MathJax draws an
/// undefined command on GitHub. Only a structure that does not close fails the whole formula: a
/// brace, a `\left` or a `\begin` left open or closed twice, or a command missing its argument.
/// The caller then draws the formula as the text it was written as (`MarkdownMath`).
///
/// ## What WebKit needed (probed 2026-11-14 in a real `WKWebView`)
///
/// - A delimiter written plainly, `(`, stretches to the height of its row unless it says
///   `stretchy="false"`. TeX's does not, so only `\left`, `\big` and an environment's stretch.
/// - `columnalign` works on an `<mtd>` and is ignored on an `<mtable>`, so each cell carries its own.
///   A cell is padded 0.4 em each side by WebKit's own stylesheet, which spreads `aligned` apart;
///   its table is class `math-aligned` for the app's stylesheet to take that away.
/// - `<mo>&#x2061;</mo>` after `sin` adds no space, so `\log n` drew `logn`. A thin `<mspace>`
///   follows a function name instead, unless an opening delimiter does.
/// - An accent's `<mo>` brings its operator spacing into the `<mover>`, which drew `\vec{v}` with
///   a gap each side; accents are unspaced. `\vec`'s `→` is drawn at 0.6 em, which is TeX's small
///   arrow, where U+20D7 floats high above the letter.
/// - A prime as a superscript is drawn tiny and high, since WebKit does not swap in the font's
///   prime variant. `′` drawn after its base is right, and `f'^2` puts the `2` on `f′`.
/// - `<math display="block">` will not scroll a formula wider than the page, so a display formula is
///   wrapped in an element of class `math-display` that the app's stylesheet lets scroll.
/// - `movablelimits` works, so `\sum_{i=1}^n` is one `<munderover>` that WebKit draws beside the
///   sum inline and under and over it in display.
enum TeXMath {
    /// MathML for `tex`: a `<math>` element, with `display="block"` for display math. `nil` when
    /// the formula's structure does not close.
    static func mathML(_ tex: String, display: Bool) -> String? {
        var parser = TeXMathParser(tex)
        guard let node = try? parser.formula() else { return nil }
        let body = TeXMathWriter.markup(node)
        return display ? "<math display=\"block\">\(body)</math>" : "<math>\(body)</math>"
    }
}

/// One piece of a formula, as MathML draws it.
indirect enum TeXMathNode: Equatable {
    /// `<mi>`. `upright` writes `mathvariant="normal"`, which a one-letter identifier needs to be
    /// drawn roman.
    case identifier(String, upright: Bool)
    case number(String)
    case symbol(TeXMathOperator)
    /// `<mtext>`. `unknown` marks a command outside the subset, drawn as its own text.
    case text(String, unknown: Bool)
    case space(String)
    case row([TeXMathNode])
    /// `<mfrac>`; `rule: false` is `\binom`'s, with no bar.
    case fraction(TeXMathNode, TeXMathNode, rule: Bool)
    case squareRoot(TeXMathNode)
    case root(TeXMathNode, index: TeXMathNode)
    /// Sub- and superscripts. `limits` puts them under and over (`<munderover>`) rather than
    /// beside (`<msubsup>`).
    case scripts(TeXMathNode, sub: TeXMathNode?, sup: TeXMathNode?, limits: Bool)
    case over(TeXMathNode, TeXMathNode, accent: Bool)
    case under(TeXMathNode, TeXMathNode, accent: Bool)
    case style(TeXMathNode, TeXMathStyle)
    case table(TeXMathTable)
    case phantom(TeXMathNode)
    case boxed(TeXMathNode)
}

/// An `<mo>` and the attributes TeX's meaning needs on it.
struct TeXMathOperator: Equatable {
    var glyph: String
    /// `false` for a delimiter TeX does not stretch, `true` for one it does, `nil` to leave it to
    /// MathML's operator dictionary.
    var stretchy: Bool?
    /// `form="prefix"`: a binary operator TeX reads as a sign.
    var prefix = false
    /// `movablelimits`, for `\lim` (which the dictionary does not know) and `\sum\limits`.
    var movableLimits: Bool?
    /// The height `\big` and its kin draw a delimiter at.
    var size: String?
    /// `false` writes `lspace="0" rspace="0"`, for a function's name, whose spacing `row` decides,
    /// and for an accent, whose spacing would otherwise widen the letter under it.
    var spaced: Bool
    /// `mathsize`, which draws `\vec`'s arrow at the size of TeX's.
    var scale: String?

    init(
        _ glyph: String,
        stretchy: Bool? = nil,
        movableLimits: Bool? = nil,
        size: String? = nil,
        spaced: Bool = true,
        scale: String? = nil
    ) {
        self.glyph = glyph
        self.stretchy = stretchy
        self.movableLimits = movableLimits
        self.size = size
        self.spaced = spaced
        self.scale = scale
    }
}

/// `<mstyle>`'s attributes: `\displaystyle` and its kin, and the size switches.
struct TeXMathStyle: Equatable {
    var displayStyle: Bool?
    var scriptLevel: Int?
    var size: String?
}

/// An environment's rows, and how each column aligns.
struct TeXMathTable: Equatable {
    var rows: [[TeXMathNode]]
    /// One per column, repeating from the start when a row is longer: `aligned` is
    /// `["right", "left"]`. `"center"` writes nothing, which is MathML's own default.
    var alignments: [String]
    /// `aligned` and its kin, whose cells sit close together (`math-aligned`).
    var isAligned = false
}

/// Nodes to markup. Every character of text goes through `MarkdownHTML.escaped`, as on the rest of
/// the page.
enum TeXMathWriter {
    static func markup(_ node: TeXMathNode) -> String {
        switch node {
        case let .identifier(text, upright):
            element("mi", text: text, attributes: upright ? " mathvariant=\"normal\"" : "")
        case let .number(text): element("mn", text: text)
        case let .symbol(symbol): markup(symbol)
        case let .text(text, unknown):
            element("mtext", text: text, attributes: unknown ? " class=\"math-unknown\"" : "")
        case let .space(width): "<mspace width=\"\(width)\"></mspace>"
        case let .row(children): "<mrow>" + children.map(markup).joined() + "</mrow>"
        case let .fraction(numerator, denominator, rule):
            "<mfrac\(rule ? "" : " linethickness=\"0\"")>"
                + markup(numerator) + markup(denominator) + "</mfrac>"
        case let .squareRoot(body): "<msqrt>" + markup(body) + "</msqrt>"
        case let .root(body, index): "<mroot>" + markup(body) + markup(index) + "</mroot>"
        case let .scripts(base, sub, sup, limits): scripts(base, sub: sub, sup: sup, limits: limits)
        default: compound(node)
        }
    }

    private static func compound(_ node: TeXMathNode) -> String {
        switch node {
        case let .over(base, top, accent):
            "<mover\(accent ? " accent=\"true\"" : "")>" + markup(base) + markup(top) + "</mover>"
        case let .under(base, bottom, accent):
            "<munder\(accent ? " accentunder=\"true\"" : "")>"
                + markup(base) + markup(bottom) + "</munder>"
        case let .style(body, style): "<mstyle\(attributes(style))>" + markup(body) + "</mstyle>"
        case let .table(table): markup(table)
        case let .phantom(body): "<mphantom>" + markup(body) + "</mphantom>"
        case let .boxed(body): "<menclose notation=\"box\">" + markup(body) + "</menclose>"
        default: ""
        }
    }

    private static func markup(_ symbol: TeXMathOperator) -> String {
        var attributes = ""
        if let stretchy = symbol.stretchy { attributes += " stretchy=\"\(stretchy)\"" }
        if symbol.prefix { attributes += " form=\"prefix\"" }
        if let movable = symbol.movableLimits { attributes += " movablelimits=\"\(movable)\"" }
        if let size = symbol.size { attributes += " minsize=\"\(size)\" maxsize=\"\(size)\"" }
        if !symbol.spaced { attributes += " lspace=\"0\" rspace=\"0\"" }
        if let scale = symbol.scale { attributes += " mathsize=\"\(scale)\"" }
        return element("mo", text: symbol.glyph, attributes: attributes)
    }

    private static func scripts(
        _ base: TeXMathNode,
        sub: TeXMathNode?,
        sup: TeXMathNode?,
        limits: Bool
    ) -> String {
        let parts = [base, sub, sup].compactMap(\.self).map(markup).joined()
        let tag = switch (sub != nil, sup != nil, limits) {
        case (true, true, false): "msubsup"
        case (true, false, false): "msub"
        case (false, _, false): "msup"
        case (true, true, true): "munderover"
        case (true, false, true): "munder"
        case (false, _, true): "mover"
        }
        return "<\(tag)>\(parts)</\(tag)>"
    }

    private static func markup(_ table: TeXMathTable) -> String {
        let rows = table.rows.map { cells in
            let cells = cells.enumerated().map { column, cell in
                let alignment = table.alignments.isEmpty
                    ? "center" : table.alignments[column % table.alignments.count]
                let attribute = alignment == "center" ? "" : " columnalign=\"\(alignment)\""
                return "<mtd\(attribute)>" + markup(cell) + "</mtd>"
            }
            return "<mtr>" + cells.joined() + "</mtr>"
        }
        let attributes = table.isAligned ? " class=\"math-aligned\"" : ""
        return "<mtable\(attributes)>" + rows.joined() + "</mtable>"
    }

    private static func attributes(_ style: TeXMathStyle) -> String {
        var attributes = ""
        if let display = style.displayStyle { attributes += " displaystyle=\"\(display)\"" }
        if let level = style.scriptLevel { attributes += " scriptlevel=\"\(level)\"" }
        if let size = style.size { attributes += " mathsize=\"\(size)\"" }
        return attributes
    }

    private static func element(_ tag: String, text: String, attributes: String = "") -> String {
        "<\(tag)\(attributes)>" + MarkdownHTML.escaped(text) + "</\(tag)>"
    }
}
