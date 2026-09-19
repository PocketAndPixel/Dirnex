import AppKit
import DirnexCore
import WebKit

/// Finding text in Quick View's rendered page: an HTML file, a Markdown document, and the page
/// macOS's Quick Look generator writes for a Word, Excel or PowerPoint file (2026-09-18).
///
/// The bar and its keys are the table's (`QuickViewFilterHost`), and the state machine — which match
/// is current, stepping with wraparound, the count — is the one every finding surface runs
/// (`QuickViewFindHost`). What is this surface's own is the three things only it can answer.
///
/// **What the text is.** The page is read through `QuickViewPageFindScript` in an isolated content
/// world, which was measured to work with the page's own scripts switched off — so finding neither
/// needs nor grants the JavaScript the user declined. Matching is `DirnexCore`'s
/// (``DirnexCore/TextFindMatches``) rather than WebKit's own `find`, for two reasons: the bar counts
/// ("3 of 17 matches") and `WKFindResult` reports only whether *something* was found; and an HTML or
/// Markdown file has a **source** style one keystroke away, which finds by that same rule, so the
/// two would otherwise disagree about the same file.
///
/// **A page can be more than one document.** A converted workbook of two sheets or more draws its
/// tab strip in the main page and the sheet itself in an `iframe`, and a `file://` frame is a
/// different origin — measured, `contentDocument` is `null` from the main document, so no script in
/// the page can reach it. A frame captured from `decidePolicyFor` *is* reachable through
/// `callAsyncJavaScript(in:)`, so the frames are searched beside the main document and joined into
/// one text, which ``DirnexCore/TextSegmentMap`` then cuts back apart to address a match in the
/// frame that holds it. Without this a workbook would find its sheet *names* and none of its cells.
///
/// **How a match is drawn.** The CSS Custom Highlight API paints over the text without touching it,
/// so nothing in the page is inserted, split or restyled and the highlight comes off by clearing a
/// registry entry. Every match is highlighted rather than only those near the screen, which the text
/// preview cannot afford and this can: measured, 20 000 ranges cost 38 ms end to end, where the
/// text preview's would be a storage edit apiece.
extension QuickViewWebView: QuickViewFindHost {
    var filterContentView: NSView { webView }

    var hasFilterableContent: Bool { hasPage }

    var keyboardFallback: NSView { webView }

    /// The page's text, and the frames' after it, joined the way ``findSegments`` records.
    ///
    /// A frame that cannot be read is dropped rather than counted as empty: a stale one — a sheet
    /// the tab strip has since replaced — would otherwise contribute a length to the map that no
    /// document backs, and every offset after it would address the wrong place.
    func findableText() async -> String {
        var texts: [String] = [await frameText(nil)]
        var live: [WKFrameInfo] = []
        for frame in childFrames {
            guard let text = await liveFrameText(frame) else { continue }
            live.append(frame)
            texts.append(text)
        }
        findFrames = live
        findSegments = TextSegmentMap(lengths: texts.map(\.utf16.count), separator: 1)
        return texts.joined(separator: "\n")
    }

    /// Hand each document the matches that lie in it, and say which of them is the current one.
    func showFindMatches() {
        let ranges = find.matches?.ranges ?? []
        var spans: [Int: [[Int]]] = [:]
        var current: [Int: Int] = [:]
        for (index, range) in ranges.enumerated() {
            for piece in findSegments.split(range) {
                spans[piece.index, default: []].append(
                    [piece.range.lowerBound, piece.range.upperBound]
                )
                if index == find.current { current[piece.index] = spans[piece.index]!.count - 1 }
            }
        }
        for segment in 0..<max(1, findSegments.lengths.count) {
            run(
                QuickViewPageFindScript.highlight,
                in: frame(forSegment: segment),
                arguments: [
                    "spans": spans[segment] ?? [],
                    "currentIndex": current[segment] ?? -1,
                    "styleText": Self.highlightStyle
                ]
            )
        }
    }

    func removeFindHighlights() {
        for segment in 0..<max(1, findSegments.lengths.count) {
            run(QuickViewPageFindScript.clear, in: frame(forSegment: segment))
        }
    }

    /// Scroll the current match into the middle of the document holding it — and, when that is a
    /// frame, bring the frame itself into view in the page first, or the scroll would land inside a
    /// sheet nobody can see.
    func revealCurrentMatch() {
        guard let range = find.currentRange,
              let piece = findSegments.split(range).first
        else { return }
        let target = frame(forSegment: piece.index)
        if piece.index > 0 {
            run(Self.revealFrameScript, in: nil, arguments: ["frameIndex": piece.index - 1])
        }
        run(
            QuickViewPageFindScript.reveal,
            in: target,
            arguments: ["start": piece.range.lowerBound, "end": piece.range.upperBound]
        )
    }

    /// Nothing here has to be read before it exists: a rendered page's text is in the document the
    /// moment it has loaded.
    var findReadingProgress: (read: Int, total: Int)? { nil }

    /// Where a search with no current match begins: the first text on screen in the main document.
    /// A frame's own scroll position is deliberately not consulted — the reader's place is where the
    /// *page* is, and a search that began inside a sheet the page has scrolled past would look as
    /// though it had skipped the top.
    func findAnchorOffset() async -> Int {
        let value = try? await webView.callAsyncJavaScript(
            QuickViewPageFindScript.visibleOffset,
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
        return (value as? Int) ?? 0
    }

    /// The bar set up for finding. Called once, when the surface is built.
    func installFinding() {
        filterBar.useForFinding()
    }

    /// A page was replaced — a new file, a different style, or the page cleared. The matches were in
    /// the old one, and the new one carries no highlight to take off.
    func resetFindForNewPage() {
        findFrames = []
        childFrames = []
        findSegments = TextSegmentMap(lengths: [])
        resetFind()
    }

    /// The same page loaded again — a changed JavaScript preference, which rebuilds the DOM and with
    /// it throws away every highlight. Draw them again rather than making the user retype.
    func redrawFindAfterReload() {
        guard find.matches != nil else { return }
        showFindMatches()
        revealCurrentMatch()
    }

    // MARK: - Private

    /// The find yellow the table and tree mark their matches in, and the current match's orange,
    /// with black text on both. Written as literals rather than taken from `NSColor`: the page is
    /// drawn by WebKit in its own colour space, and a dynamic colour resolved here would freeze at
    /// whichever appearance was current when the search ran.
    private static let highlightStyle = """
    ::highlight(\(QuickViewPageFindScript.allName)) { background-color: #FFE24D; color: #000; }
    ::highlight(\(QuickViewPageFindScript.currentName)) { background-color: #FF9F0A; color: #000; }
    """

    /// Bring the `frameIndex`-th `iframe` into view in the main document.
    private static let revealFrameScript = """
    const frames = document.querySelectorAll('iframe');
    const frame = frames[frameIndex];
    if (!frame) { return false; }
    frame.scrollIntoView({ block: 'center', inline: 'nearest' });
    return true;
    """

    /// Segment 0 is the main document; the rest are the frames, in the order `findableText` read
    /// them.
    private func frame(forSegment segment: Int) -> WKFrameInfo? {
        guard segment > 0, findFrames.indices.contains(segment - 1) else { return nil }
        return findFrames[segment - 1]
    }

    private func frameText(_ frame: WKFrameInfo?) async -> String {
        let value = try? await webView.callAsyncJavaScript(
            QuickViewPageFindScript.text,
            arguments: [:],
            in: frame,
            contentWorld: .defaultClient
        )
        return (value as? String) ?? ""
    }

    /// A child frame's text, or `nil` when the frame has gone — which is a refusal rather than an
    /// empty document, and the two must not be confused (see `findableText`).
    private func liveFrameText(_ frame: WKFrameInfo) async -> String? {
        let value = try? await webView.callAsyncJavaScript(
            QuickViewPageFindScript.text,
            arguments: [:],
            in: frame,
            contentWorld: .defaultClient
        )
        return value as? String
    }

    /// Fire a script and forget it: every one of these draws or scrolls, so there is nothing to read
    /// back and nothing a failure could usefully do but leave the page as it was.
    private func run(_ script: String, in frame: WKFrameInfo?, arguments: [String: Any] = [:]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await webView.callAsyncJavaScript(
                script,
                arguments: arguments,
                in: frame,
                contentWorld: .defaultClient
            )
        }
    }
}
