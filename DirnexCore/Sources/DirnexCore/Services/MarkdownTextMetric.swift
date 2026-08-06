import Foundation

/// How wide a string is in the font the page will draw it in (PLAN.md §M18 ▸ Slice 4).
///
/// The milestone's third probe, and the reason it existed: a flowchart node's width *is* its label's
/// width, and the core cannot measure one — it imports no AppKit. So the metric is injected, the
/// same seam the `sftp` and `curl` transports use and the same shape `resolveImageSource` already
/// has, with a fixed-advance default that makes every layout assertion in the tests exact.
///
/// ## What the probe settled
///
/// Measured 2026-08-06 against the real system font, best of 20:
///
/// - `NSString.size(withAttributes:)` costs **5.4–6.7 µs a label** and agrees exactly with
///   `NSAttributedString.size()` and `CTLineGetTypographicBounds`. A hundred-node diagram is
///   therefore ~0.7 ms of measurement against the 4.5 ms this repo's `PLAN.md` already takes to
///   render, so **per-node measurement is affordable** and no cache is warranted.
/// - `CTFontGetAdvancesForGlyphs` is ten times cheaper (0.46 µs) and was rejected: summed advances
///   are not shaping, and it measures `🐛 Bugs` at 51.7 against the real 45.5 — a 13 % overshoot on
///   exactly the labels a diagram is most likely to carry.
/// - **It is safe and exact off the main actor**, which is what decides the shape here: the render
///   runs on a detached task, and four concurrent background queues measuring 200 labels twenty
///   times produced *zero* disagreements with the main thread's answers. Hence a plain `@Sendable`
///   closure and no actor hop. It costs about 1.6× more there under contention (8.3 µs).
public struct MarkdownTextMetric: Sendable {
    /// The advance width of `text` on one line, in points.
    public var width: @Sendable (String) -> Double
    /// One line's height, which sets a node's height and a diagram's row pitch.
    public var lineHeight: Double

    public init(lineHeight: Double, width: @escaping @Sendable (String) -> Double) {
        self.lineHeight = lineHeight
        self.width = width
    }

    /// A fixed advance per character.
    ///
    /// Not a fallback that happens to be simple — it is the *test* metric, and the reason every
    /// layout assertion can be an exact number rather than a range. It is also a defensible answer
    /// on its own: a diagram measured this way is loose in places and never illegible, which is what
    /// a caller that supplies no metric should get.
    public static let fixedAdvance = MarkdownTextMetric(lineHeight: 14) { text in
        // By *character*, not by UTF-16 unit: an emoji is one advance wide, not two.
        Double(text.count) * 7
    }
}
