import Foundation

/// What ⇧↑ / ⇧↓, ⇧Page Up / ⇧Page Down and ⇧← / ⇧→ do to a Quick View preview (2026-10-18): scroll
/// the document on screen while the file list keeps the focus, so the cursor can go on walking files
/// between one look and the next.
///
/// One rule for every backend that scrolls — text, a PDF, a CSV table, a JSON or XML tree, a zoomed
/// image and a rendered page — so the keys go the same distance whichever file is up. Distances are
/// in the *document's* units, the way AppKit's own line scroll and WebKit's arrow key measure them: a
/// step is the same stretch of the document at any zoom, and so covers more of the screen when the
/// document is drawn larger.
public enum QuickViewScroll: Sendable, Equatable, CaseIterable {
    case lineUp
    case lineDown
    case pageUp
    case pageDown
    /// The top of the document.
    case top
    /// The end of the document.
    case end

    /// How far a move goes.
    public enum Travel: Sendable, Equatable {
        /// By this distance, positive toward the end and negative toward the start.
        case by(Double)
        case toStart
        case toEnd
    }

    /// One line step. WebKit's own for an arrow key (measured on a rendered page: 40 CSS px), and a
    /// little over two lines of the text preview (measured live: three presses, seven lines), so
    /// holding the key reads down a file at key-repeat speed.
    public static let lineStep: Double = 40

    /// How far a page step goes over a view `visibleHeight` tall: the visible height less one line
    /// step, so the line read last is still on screen after the jump, but never less than half of it,
    /// so a surface only a few lines tall still pages rather than crawling.
    public static func pageStep(visibleHeight: Double) -> Double {
        max(visibleHeight - lineStep, visibleHeight / 2)
    }

    /// How far this move goes over a view `visibleHeight` tall.
    public func travel(visibleHeight: Double) -> Travel {
        switch self {
        case .lineUp: .by(-Self.lineStep)
        case .lineDown: .by(Self.lineStep)
        case .pageUp: .by(-Self.pageStep(visibleHeight: visibleHeight))
        case .pageDown: .by(Self.pageStep(visibleHeight: visibleHeight))
        case .top: .toStart
        case .end: .toEnd
        }
    }
}
