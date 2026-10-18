import DirnexCore
import WebKit

/// ⇧↑ / ⇧↓, ⇧Page Up / ⇧Page Down and ⇧← / ⇧→ on a rendered page (2026-10-18).
///
/// By script, in the same isolated world the find uses (`QuickViewPageFindScript`), so it works with
/// the page's own scripts off and grants them nothing. Probed before this was written, on a plain page
/// with scripts off: `scrollBy` and `scrollTo` from `.defaultClient` moved it by 40, to the end and
/// back to 0.
///
/// **Why not WebKit's own `scrollLineDown:`**, which also worked on that page: a converted Excel
/// workbook draws its tab strip in a page that does not scroll at all and its sheet in an iframe that
/// does, and the probe found WebKit's commands, like a script in the main document, leaving the sheet
/// where it was. Only a script sent *into* the sheet's frame moved it — the `WKFrameInfo` the find
/// already captures (`childFrames`). So a move goes to the main document first and, when that has
/// nothing to scroll, to the frames, newest first.
extension QuickViewWebView {
    func scrollPage(_ move: QuickViewScroll) {
        let frames: [WKFrameInfo?] = [nil] + childFrames.reversed()
        let arguments = Self.scrollArguments(move)
        Task { @MainActor [weak self] in
            for frame in frames {
                guard let self else { return }
                // A frame the tab strip has since replaced throws, and is passed over like a frame
                // with nothing to scroll.
                let scrolled = try? await webView.callAsyncJavaScript(
                    Self.scrollScript,
                    arguments: arguments,
                    in: frame,
                    contentWorld: .defaultClient
                )
                if scrolled as? Bool == true { return }
            }
        }
    }

    private static func scrollArguments(_ move: QuickViewScroll) -> [String: Any] {
        let (kind, direction) = switch move {
        case .lineUp: ("line", -1)
        case .lineDown: ("line", 1)
        case .pageUp: ("page", -1)
        case .pageDown: ("page", 1)
        case .top: ("start", 0)
        case .end: ("end", 0)
        }
        return ["kind": kind, "direction": direction, "line": QuickViewScroll.lineStep]
    }

    /// Scroll this frame and answer `true`, or answer `false` when its document has nothing to scroll —
    /// which is what sends the move on to the next frame. `instant`, so a page that asks for smooth
    /// scrolling still moves a whole step per press and key repeat does not pile animations up.
    ///
    /// The page step is `QuickViewScroll.pageStep` over the frame's own height, written out here
    /// because only the frame knows that height. A test holds the two to each other.
    static let scrollScript = """
    const root = document.scrollingElement;
    if (!root || root.scrollHeight - root.clientHeight < 1) { return false; }
    const view = window.innerHeight;
    if (kind === 'start') {
      window.scrollTo({ top: 0, behavior: 'instant' });
    } else if (kind === 'end') {
      window.scrollTo({ top: root.scrollHeight, behavior: 'instant' });
    } else {
      const step = kind === 'line' ? line : Math.max(view - line, view / 2);
      window.scrollBy({ top: direction * step, behavior: 'instant' });
    }
    return true;
    """
}
