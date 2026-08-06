import Foundation

/// A laid-out diagram, written as SVG (PLAN.md §M18 ▸ Slice 4).
///
/// **Class names and `currentColor`, never a literal colour.** The same division the rest of the
/// milestone keeps: the core says what a thing is, the app's stylesheet says what colour it takes,
/// and a diagram therefore follows light and dark exactly the way the prose around it does — for
/// free, live, with no reload (`QuickViewMarkdownStyle`). A single `#333` written here would be the
/// one element on the page that stays dark when the user's Mac crosses sunset.
///
/// Every string that reaches the output is escaped, without exception, because the labels are the
/// file's own bytes and this is the same wall `MarkdownHTML` describes — an SVG is markup, and a
/// node called `</text><script>` is a node somebody can write.
enum MermaidSVG {
    /// The number, in a form an SVG attribute accepts and a test can predict.
    ///
    /// Rounded to two places rather than printed with `\(Double)`: the layout divides by counts, so
    /// a coordinate is routinely `123.33333333333333`, and neither the file size nor anything else
    /// gains from the last twelve digits. `-0` is normalized away — it renders identically and
    /// reads as a bug.
    static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded(), abs(rounded) < 1e15 {
            return String(Int(rounded == 0 ? 0 : rounded))
        }
        return String(format: "%.2f", rounded)
    }

    /// The `<svg>` wrapper, carrying its natural size **as well as** its `viewBox`.
    ///
    /// Both, and the pair is the point. An SVG with only a `viewBox` has no intrinsic size, so
    /// `max-width: 100%` in the stylesheet stretches it to the full reading column — which is what
    /// the first live run showed: a three-node flowchart blown up until its 11 pt labels drew at
    /// twice that, on a page whose prose was the size it should have been. With `width` and
    /// `height` present the diagram draws at the size it was laid out for and the `max-width` rule
    /// only ever scales it *down*, on a window too narrow to hold it.
    ///
    /// `scale` multiplies the *displayed* size and leaves the `viewBox` — hence the whole drawing —
    /// alone, so it is a uniform magnification rather than a second layout: labels, strokes and
    /// gaps all grow by the same factor and their proportions cannot drift from the ones the layout
    /// was measured in. Doing it here rather than by enlarging the label font is what keeps that
    /// true; the paddings and layer gaps are constants, so a bigger font alone would grow the text
    /// inside boxes that stayed the size they were.
    static func document(
        width: Double,
        height: Double,
        body: String,
        classes: String,
        scale: Double = 1
    ) -> String {
        """
        <svg class="\(classes)" width="\(number(width * scale))" \
        height="\(number(height * scale))" \
        viewBox="0 0 \(number(width)) \(number(height))" \
        xmlns="http://www.w3.org/2000/svg" role="img">\(body)</svg>
        """
    }

    static func text(_ value: String, at point: MermaidPoint, classes: String) -> String {
        """
        <text class="\(classes)" x="\(number(point.x))" y="\(number(point.y))" \
        text-anchor="middle" dominant-baseline="central">\(MarkdownHTML.escaped(value))</text>
        """
    }

    static func line(_ points: [MermaidPoint], classes: String) -> String {
        let path = points
            .map { "\(number($0.x)),\(number($0.y))" }
            .joined(separator: " ")
        return "<polyline class=\"\(classes)\" points=\"\(path)\" fill=\"none\"/>"
    }

    /// An arrowhead, as a filled triangle pointing along `direction`.
    ///
    /// Drawn as an explicit polygon rather than through a `<marker>`, and that is a decision rather
    /// than an omission: a marker inherits the *line's* colour through `context-stroke`, which is
    /// not supported everywhere, and otherwise needs a colour written into the marker — the one
    /// thing this emitter must never do. A polygon carrying `currentColor` is coloured by the same
    /// CSS rule as everything else.
    static func tip(
        _ tip: MermaidFlowchart.Tip,
        at point: MermaidPoint,
        from origin: MermaidPoint,
        classes: String
    ) -> String {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard tip != .none, length > 0.001 else { return "" }
        let ux = dx / length
        let uy = dy / length
        switch tip {
        case .arrow:
            let size = 8.0
            let backX = point.x - ux * size
            let backY = point.y - uy * size
            let half = size * 0.42
            let points = [
                MermaidPoint(x: point.x, y: point.y),
                MermaidPoint(x: backX - uy * half, y: backY + ux * half),
                MermaidPoint(x: backX + uy * half, y: backY - ux * half)
            ]
            let path = points.map { "\(number($0.x)),\(number($0.y))" }.joined(separator: " ")
            return "<polygon class=\"\(classes)-arrow\" points=\"\(path)\"/>"
        case .circle:
            let radius = 4.0
            let centre = MermaidPoint(x: point.x - ux * radius, y: point.y - uy * radius)
            return """
            <circle class="\(classes)-circle" cx="\(number(centre.x))" cy="\(number(centre.y))" \
            r="\(number(radius))"/>
            """
        case .cross:
            let size = 5.0
            let centre = MermaidPoint(x: point.x - ux * size, y: point.y - uy * size)
            return [
                segment(centre, dx: size, dy: size, classes: "\(classes)-cross"),
                segment(centre, dx: size, dy: -size, classes: "\(classes)-cross")
            ].joined()
        case .none:
            return ""
        }
    }

    private static func segment(
        _ centre: MermaidPoint,
        dx: Double,
        dy: Double,
        classes: String
    ) -> String {
        """
        <line class="\(classes)" x1="\(number(centre.x - dx))" y1="\(number(centre.y - dy))" \
        x2="\(number(centre.x + dx))" y2="\(number(centre.y + dy))"/>
        """
    }

    static func rect(_ frame: MermaidRect, classes: String, radius: Double = 0) -> String {
        let corner = radius > 0 ? " rx=\"\(number(radius))\"" : ""
        return """
        <rect class="\(classes)" x="\(number(frame.x))" y="\(number(frame.y))" \
        width="\(number(frame.width))" height="\(number(frame.height))"\(corner)/>
        """
    }
}
