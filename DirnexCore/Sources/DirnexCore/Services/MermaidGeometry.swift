import Foundation

/// The little value types a laid-out diagram is made of (PLAN.md §M18 ▸ Slice 4).
///
/// Hand-rolled rather than `CGPoint`/`CGRect` for one reason worth stating: `CGFloat` is a
/// platform-width alias, and a layout whose assertions are exact numbers should not be measured in
/// a type whose precision is decided elsewhere. Nothing here needs more than four `Double`s.
struct MermaidPoint: Equatable {
    var x: Double
    var y: Double
}

struct MermaidRect: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var center: MermaidPoint { MermaidPoint(x: midX, y: midY) }
}

/// Where a line leaving a node's centre crosses that node's outline.
///
/// An edge drawn centre-to-centre disappears under both boxes; clipping it to the outline is what
/// puts the arrowhead on the border where it belongs. Each shape has a closed-form answer along the
/// ray, so there is nothing to iterate and nothing to get within a tolerance of:
///
/// - a **rectangle** is `max(|x|/w, |y|/h) = 1`
/// - an **ellipse** is `(x/w)² + (y/h)² = 1`
/// - a **diamond** is `|x|/w + |y|/h = 1`
///
/// which are the three cases the shape vocabulary reduces to.
enum MermaidOutline {
    static func boundary(
        of frame: MermaidRect,
        shape: MermaidFlowchart.Shape,
        toward target: MermaidPoint
    ) -> MermaidPoint {
        let centre = frame.center
        let dx = target.x - centre.x
        let dy = target.y - centre.y
        guard dx != 0 || dy != 0 else { return centre }
        let halfWidth = frame.width / 2
        let halfHeight = frame.height / 2
        let scale: Double
        switch shape {
        case .circle:
            let nx = dx / halfWidth
            let ny = dy / halfHeight
            scale = 1 / (nx * nx + ny * ny).squareRoot()
        case .diamond:
            scale = 1 / (abs(dx) / halfWidth + abs(dy) / halfHeight)
        case .rectangle, .rounded, .subroutine:
            scale = 1 / max(abs(dx) / halfWidth, abs(dy) / halfHeight)
        }
        return MermaidPoint(x: centre.x + dx * scale, y: centre.y + dy * scale)
    }
}
