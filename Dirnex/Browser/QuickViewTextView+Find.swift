import AppKit
import DirnexCore

/// Finding text in Quick View's text preview (2026-09-17).
///
/// View ▸ Filter (⌥⌘F) shows the table's bar over the text, with no picker; its keys are the table's
/// (`QuickViewFilterHost`), ↑ and ↓ stepping from match to match. Which text matches is `DirnexCore`'s
/// (`TextFindMatches`), by the rule the table and tree filters match by, so a word found in a CSV
/// cell is found in the same file's source. The search runs off the main actor over a copy of the text
/// (4–7 ms over a 4 MB file for an ASCII query, 130–190 ms for any other, measured in a release build),
/// and each keystroke stops the one before.
///
/// Every match is highlighted in the system's find yellow with black text on it, as the table and
/// tree mark theirs, and the current one in orange. Only the matches around what is on screen carry a
/// highlight, updated as the text scrolls: a one-letter query over a 4 MB file has 100 000 matches,
/// and coloring all of them would be a storage edit per match on every keystroke.
///
/// The colors are written into the text storage, with each match's own colors kept and put back when
/// its highlight comes off (`highlightOriginals`). TextKit 2's rendering attributes, which draw over
/// the text without touching it, looked like the tool for this and are not: `NSTextView` stores them
/// and draws none of them — not after invalidating the layout, nor the rendering attributes, nor the
/// display — which only looking at the running app showed, since reading them back succeeds
/// (docs/NOTES.md ▸ AppKit). Writing to `textStorage` is safe for the lazy layout a large file depends
/// on; reading `layoutManager` is what is not.
///
/// A match off screen is brought into view by the system's scroll and then corrected on later turns
/// (`revealCurrentMatch`), since under TextKit 2 where a far match lies is an estimate until the text
/// around it is laid out.
extension QuickViewTextView: QuickViewFindHost {
    var hasFilterableContent: Bool {
        !searchableText.isEmpty
    }

    var keyboardFallback: NSView {
        textView
    }

    /// The text already on screen, held as a value beside the storage so the search never reads a
    /// mutable object off the main actor. No round trip, unlike the page and PDF surfaces.
    func findableText() async -> String {
        searchableText
    }

    /// The bar set up for finding, and the scroll view reporting its moves so the highlights can follow.
    func installFinding() {
        filterBar.useForFinding()
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleTextMoved(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    // MARK: - Private

    /// The current match's color. The others take `NSColor.findHighlightColor`.
    private static var currentMatchColor: NSColor {
        .systemOrange
    }

    /// Black, as a named dynamic color. A formatted document is drawn with adaptive color mapping in
    /// Dark Mode, which turns a plain black into white — white on the find yellow, which cannot be read
    /// — and leaves named colors alone, as it leaves the yellow and the orange.
    private static let matchTextColor = NSColor(name: "QuickViewFindMatchText") { _ in .black }

    /// How far past what is on screen, in UTF-16 units, matches are highlighted, so a short scroll
    /// shows highlights already drawn.
    private static let highlightMargin = 2000

    /// Room above and below a match brought into view from nearby.
    private static let revealMargin: CGFloat = 40

    /// Draw the matches around what is on screen. Re-colouring the ones already highlighted is what
    /// moves the orange from the previous current match to the new one after a step; `highlight`
    /// reads `find.current` to decide which colour each takes.
    func showFindMatches() {
        guard find.matches != nil else {
            removeHighlights()
            return
        }
        editStorage {
            for index in highlightedMatches { highlight(index) }
        }
        updateHighlights()
    }

    /// Put every highlighted match's own colors back.
    func removeFindHighlights() {
        removeHighlights()
    }

    @objc private func visibleTextMoved(_ notification: Notification) {
        guard find.matches != nil, !isHighlightUpdateScheduled else { return }
        // Next turn, once the viewport has been laid out for where the text now is.
        isHighlightUpdateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            isHighlightUpdateScheduled = false
            updateHighlights()
        }
    }

    /// Highlight the matches around what is on screen, and take the highlight off those no longer
    /// around it.
    private func updateHighlights() {
        guard let matches = find.matches, let span = visibleSpan() else {
            removeHighlights()
            return
        }
        let wanted = matches.indices(overlapping: span)
        let leaving = TextFindMatches.indices(highlightedMatches, notIn: wanted)
        let arriving = TextFindMatches.indices(wanted, notIn: highlightedMatches)
        guard !leaving.isEmpty || !arriving.isEmpty else { return }
        editStorage {
            leaving.forEach { $0.forEach(unhighlight) }
            arriving.forEach { $0.forEach(highlight) }
        }
        highlightedMatches = wanted
    }

    private func removeHighlights() {
        guard !highlightedMatches.isEmpty else { return }
        editStorage { highlightedMatches.forEach(unhighlight) }
        highlightedMatches = 0..<0
    }

    /// Color a match — first keeping the colors it had, unless it is highlighted already and only
    /// changing between current and not.
    private func highlight(_ index: Int) {
        guard let range = matchRange(index), let storage = textView.textStorage else { return }
        let characters = nsRange(range)
        if highlightOriginals[index] == nil {
            var runs: [OriginalColors] = []
            storage.enumerateAttributes(in: characters) { attributes, run, _ in
                runs.append(OriginalColors(
                    range: run,
                    foreground: attributes[.foregroundColor],
                    background: attributes[.backgroundColor]
                ))
            }
            highlightOriginals[index] = runs
        }
        storage.addAttributes(
            [
                .backgroundColor: index == find.current ? Self.currentMatchColor : .findHighlightColor,
                .foregroundColor: Self.matchTextColor
            ],
            range: characters
        )
    }

    /// Put back the colors a match had before it was highlighted.
    private func unhighlight(_ index: Int) {
        guard let runs = highlightOriginals.removeValue(forKey: index),
              let storage = textView.textStorage
        else { return }
        for run in runs where NSMaxRange(run.range) <= storage.length {
            restore(.foregroundColor, to: run.foreground, over: run.range, in: storage)
            restore(.backgroundColor, to: run.background, over: run.range, in: storage)
        }
    }

    private func restore(
        _ key: NSAttributedString.Key,
        to value: Any?,
        over range: NSRange,
        in storage: NSTextStorage
    ) {
        if let value {
            storage.addAttribute(key, value: value, range: range)
        } else {
            storage.removeAttribute(key, range: range)
        }
    }

    /// One batch of attribute changes, laid out once.
    private func editStorage(_ changes: () -> Void) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        changes()
        storage.endEditing()
    }

    /// Bring the current match into view.
    ///
    /// Under TextKit 2 no single scroll can do it for a match far into a large file. The position of
    /// anything not yet laid out is an estimate, and the estimate moves once the text around the match
    /// is laid out: measured on a 4 MB file, the last match's frame moved by 30 000 points between two
    /// reads half a second apart, so `scrollRangeToVisible` (1 ms) and relocating the viewport by hand
    /// (0.9 s) both came to rest screens away, and laying out everything above the match first (1.8 s)
    /// missed too, the view's height lagging its layout. What converges is the system's own scroll and
    /// then a few more on later turns, each to the frame the match has by then (`settleReveal`).
    func revealCurrentMatch() {
        guard let current = find.current, let range = matchRange(current) else { return }
        revealGeneration += 1
        textView.scrollRangeToVisible(nsRange(range))
        guard textView.textLayoutManager != nil else { return }
        settleReveal(of: range, generation: revealGeneration, attemptsLeft: Self.revealAttempts)
    }

    /// On a later turn, scroll to where the match now is if it is not on screen, and look again after;
    /// the highlights are brought up to date each time. Stops once the match is on screen, after
    /// `revealAttempts`, or when a newer reveal has started.
    private func settleReveal(of range: Range<Int>, generation: Int, attemptsLeft: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.revealSettleDelay)
            guard let self, generation == revealGeneration,
                  let layoutManager = textView.textLayoutManager,
                  let textRange = textRange(range),
                  let frame = frame(of: textRange, in: layoutManager)
            else { return }
            // The highlights follow the scroll a turn behind it, and the last correction may have
            // been read against a viewport that had not caught up yet.
            updateHighlights()
            guard attemptsLeft > 0, !scrollView.documentVisibleRect.contains(frame) else { return }
            textView.scrollToVisible(frame.insetBy(dx: 0, dy: -Self.revealMargin))
            settleReveal(of: range, generation: generation, attemptsLeft: attemptsLeft - 1)
        }
    }

    /// How many times a reveal looks again, and how long it waits each time.
    private static let revealAttempts = 8
    private static let revealSettleDelay = Duration.milliseconds(30)

    /// Where a laid-out range is drawn, in the text view's coordinates.
    private func frame(of textRange: NSTextRange, in layoutManager: NSTextLayoutManager) -> CGRect? {
        var frame: CGRect?
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
            frame = frame.map { $0.union(segment) } ?? segment
            return true
        }
        let origin = textView.textContainerOrigin
        return frame?.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// The UTF-16 offsets of what is on screen, widened by `highlightMargin`, or `nil` before the text
    /// has been laid out.
    private func visibleSpan() -> Range<Int>? {
        let length = textView.textStorage?.length ?? 0
        guard length > 0, let visible = laidOutCharacters() else { return nil }
        let start = max(0, visible.lowerBound - Self.highlightMargin)
        return start..<min(length, max(start, visible.upperBound + Self.highlightMargin))
    }

    /// The characters laid out for the screen: TextKit 2's viewport, which reaches a little past what
    /// is visible, or under TextKit 1 the characters in the visible rectangle.
    private func laidOutCharacters() -> Range<Int>? {
        if let layoutManager = textView.textLayoutManager {
            guard let storage = textView.textContentStorage,
                  let viewport = layoutManager.textViewportLayoutController.viewportRange
            else { return nil }
            let start = storage.offset(from: storage.documentRange.location, to: viewport.location)
            let end = storage.offset(from: storage.documentRange.location, to: viewport.endLocation)
            return start..<max(start, end)
        }
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return nil
        }
        let origin = textView.textContainerOrigin
        let rect = scrollView.documentVisibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        return characters.location..<NSMaxRange(characters)
    }

    /// The offset of the first text on screen: where a search that has no current match yet begins.
    func findAnchorOffset() async -> Int {
        guard let layoutManager = textView.textLayoutManager, let storage = textView.textContentStorage else {
            return laidOutCharacters()?.lowerBound ?? 0
        }
        let top = scrollView.documentVisibleRect.minY - textView.textContainerOrigin.y
        guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, top))) else {
            return 0
        }
        return storage.offset(
            from: storage.documentRange.location,
            to: fragment.rangeInElement.location
        )
    }

    /// A match's range, or `nil` for one the text on screen does not reach — a mismatched pair must fail
    /// as a missing highlight rather than raise on a range past the end.
    private func matchRange(_ index: Int) -> Range<Int>? {
        guard let matches = find.matches, matches.ranges.indices.contains(index) else { return nil }
        let range = matches.ranges[index]
        return range.upperBound <= (textView.textStorage?.length ?? 0) ? range : nil
    }

    private func textRange(_ range: Range<Int>) -> NSTextRange? {
        guard let storage = textView.textContentStorage,
              let start = storage.location(
                  storage.documentRange.location,
                  offsetBy: range.lowerBound
              ),
              let end = storage.location(start, offsetBy: range.count)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    private func nsRange(_ range: Range<Int>) -> NSRange {
        NSRange(location: range.lowerBound, length: range.count)
    }
}

extension QuickViewTextView {
    /// The colors one stretch of a match had before it was highlighted — a match can span several
    /// syntax colors, so it is kept run by run.
    struct OriginalColors {
        let range: NSRange
        let foreground: Any?
        let background: Any?
    }
}
