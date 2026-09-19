import AppKit
import DirnexCore

/// What every Quick View surface that *finds* keeps while it is finding: the matches, which one is
/// current, and the search still in flight (2026-09-17, generalized from the text preview
/// 2026-09-18).
///
/// A class rather than a set of stored properties on each surface, because a protocol extension
/// cannot hold state and the three surfaces that find — the text preview, a rendered page and a PDF
/// — must run *one* state machine rather than three copies of it. What differs between them is
/// where the text comes from, how a match is drawn, and how it is brought into view; everything
/// else is the same and lives in `QuickViewFindHost`.
@MainActor
final class QuickViewFind {
    /// What the text in the bar found, or `nil` while none is typed.
    var matches: TextFindMatches?
    /// Which of `matches` is the current one.
    var current: Int?
    /// Bumped by every change to the text in the bar and every new file, so a search landing after
    /// either is discarded.
    var generation = 0
    /// What stops a search early once a newer one makes it pointless.
    var cancellation: CancellationFlag?
    /// The last search sent off the main actor — what a test awaits to know it has landed.
    var task: Task<Void, Never>?
    /// Set for a search the *app* is about to start because more of the surface's text has arrived
    /// — a PDF's scanned pages landing — rather than one the reader asked for by typing. Read and
    /// cleared by the next `filterChanged()`, which is called synchronously right after it is set.
    ///
    /// It decides one thing: whether the search may **scroll**. A re-run the reader did not ask for
    /// may not move the document under them, and there are three of those a second for the length
    /// of a book.
    var isRerunForMoreText = false

    /// The current match's range, if there is one and it is still in range of what was searched.
    var currentRange: Range<Int>? {
        guard let current, let matches, matches.ranges.indices.contains(current) else { return nil }
        return matches.ranges[current]
    }
}

/// A Quick View surface the filter bar *finds* in rather than narrows: the text preview, a rendered
/// page, and a PDF.
///
/// The bar, its keys and where the keyboard goes are `QuickViewFilterHost`'s. This adds the half
/// that is the same over all three — run the search off the main actor, discard one the reader has
/// moved past, pick the match to make current, step with wraparound, and say "3 of 17 matches" —
/// and leaves each surface the three things only it can answer: what its text *is*, how to draw a
/// match, and how to bring one into view.
///
/// The text is asked for asynchronously so the three can differ: the text preview already holds a
/// copy, a rendered page has to be read out of the DOM through JavaScript, and a PDF has to have
/// its pages' text extracted. Which text matches is `DirnexCore`'s in every case
/// (``DirnexCore/TextFindMatches``), by the rule the table and tree filters match by — so a word
/// found in an HTML file's *source* is found in the same file's rendered page, which is a
/// comparison the user can make in one keystroke (`1` and `2`).
@MainActor
protocol QuickViewFindHost: QuickViewFilterHost {
    /// This surface's find state.
    var find: QuickViewFind { get }
    /// The text to search, as the surface can currently see it. Called off the bar's keystroke and
    /// may be slow; a surface whose text costs a round trip reads it here.
    func findableText() async -> String
    /// Draw `find.matches`, with `find.current` drawn as the current one. Called with no stale
    /// highlight left on screen, so it never has to reason about what the previous search left.
    func showFindMatches()
    /// Take every highlight off. Called before a new search's matches are installed, because a
    /// highlight is remembered by its match's *index* and the next search renumbers them.
    func removeFindHighlights()
    /// Bring the current match into view. Nothing to do when there is none.
    func revealCurrentMatch()
    /// Where a search with no current match yet begins: the offset of the first text on screen, so
    /// typing finds what is in front of the reader rather than jumping back to the top. Asked
    /// asynchronously because a rendered page's answer is a round trip into the document.
    func findAnchorOffset() async -> Int
    /// How much of this surface's text is still being *produced*, for a surface whose text has to
    /// be read before it exists — a PDF's scanned pages, which take ~0.2–0.5 s each.
    ///
    /// `nil` for every surface whose text is simply there, which is all of them but that one. A
    /// requirement with no default rather than a defaulted extension, for the reason
    /// `returnStepsResults` is one: three surfaces, three explicit answers, and no question of
    /// which witness wins.
    ///
    /// It matters because of what the count line would otherwise say. "No matches" over a document
    /// whose pages have not been read yet is not an answer, it is a wrong one that looks exactly
    /// like a right one.
    var findReadingProgress: (read: Int, total: Int)? { get }
}

extension QuickViewFindHost {
    var filterTask: Task<Void, Never>? { find.task }

    /// Return steps to the next match here, and ⇧Return to the previous one — but only while there is
    /// a match to step to, so with nothing typed, or nothing found, the key falls through to handing
    /// the keyboard back rather than doing nothing at all. A dead Return in a keyboard-first app reads
    /// as a broken bar, and Tab is the only other way out of the field.
    var returnStepsResults: Bool {
        find.current != nil && find.matches?.isEmpty == false
    }

    /// Run the search the bar now describes. An empty text clears it at once; anything else is read
    /// off the main actor, and a search still running for older text is stopped.
    func filterChanged() {
        find.generation += 1
        find.cancellation?.isCancelled = true
        find.cancellation = nil
        // Captured here rather than read in the task: this runs synchronously in the turn the flag
        // was set, so there is no window for a keystroke to land between the two.
        let wasAskedFor = !find.isRerunForMoreText
        find.isRerunForMoreText = false
        let query = filterBar.query
        // Read on the main actor beside the text: the search runs off it, and a later change to the
        // options is a new search of its own rather than something this one should pick up midway.
        let options = filterBar.options
        guard !query.isEmpty, hasFilterableContent else {
            find.task = nil
            clearFindMatches()
            return
        }
        let generation = find.generation
        let cancellation = CancellationFlag()
        find.cancellation = cancellation
        find.task = Task { [weak self] in
            guard let self else { return }
            let text = await findableText()
            // Reading the text is itself a round trip on two of the three surfaces, so the query
            // can have moved on before the search has even started.
            guard generation == find.generation else { return }
            let found = await BlockingWork.run {
                TextFindMatches.find(FilterQuery(query, options: options), in: text) {
                    cancellation.isCancelled
                }
            }
            guard generation == find.generation, let found else { return }
            await applyFindMatches(found, revealing: wasAskedFor)
        }
    }

    /// Make the match `step` matches along the current one, wrapping past either end, and bring it
    /// into view.
    func stepFilterResult(by step: Int) {
        guard let matches = find.matches, !matches.isEmpty, let previous = find.current else { return }
        find.current = matches.index(previous, steppedBy: step)
        showFindMatches()
        revealCurrentMatch()
        showMatchCount()
    }

    /// No search, no highlights, the bar away, and the keyboard back if it was in the bar — for a
    /// new file, whose text the matches are not in, and which must not keep a search still running.
    func resetFind() {
        find.generation += 1
        find.cancellation?.isCancelled = true
        find.cancellation = nil
        find.task = nil
        removeFindHighlights()
        find.matches = nil
        find.current = nil
        let hadKeyboard = filterHasKeyboard
        filterBar.field.stringValue = ""
        showMatchCount()
        setFilterBarShown(false)
        if hadKeyboard { giveKeyboardBack() }
    }

    /// Take `found` as what the bar's text finds, and make current the first match from where the
    /// reader is: from the current match while text is being typed into the bar — so refining a
    /// query stays where it landed — and otherwise from the top of what is on screen.
    ///
    /// `revealing` is false only for a search the reader did not ask for (`isRerunForMoreText`).
    func applyFindMatches(_ found: TextFindMatches, revealing: Bool = true) async {
        // The anchor is only asked for when there is no current match to refine from, which is what
        // keeps a page from paying a round trip on every keystroke of a query being narrowed.
        let anchor: Int
        if let current = find.currentRange?.lowerBound {
            anchor = current
        } else {
            anchor = await findAnchorOffset()
        }
        let previous = find.currentRange
        removeFindHighlights()
        find.matches = found
        find.current = found.index(atOrAfter: anchor)
        showFindMatches()
        // A search the reader asked for always scrolls to its answer. One they did not — a PDF
        // re-searched as each scanned page lands, three times a second for the better part of a
        // minute — scrolls only when the current match has actually *moved*, which is the case
        // where a page they have been waiting on has finally answered their question. Otherwise it
        // would yank them back to the same match for the length of the book, so the document could
        // not be read while it was being read.
        if revealing || find.currentRange != previous { revealCurrentMatch() }
        showMatchCount()
    }

    /// Nothing typed: no matches, no highlights, no count — and no round trip, so clearing the bar
    /// is as immediate as it looks.
    func clearFindMatches() {
        removeFindHighlights()
        find.matches = nil
        find.current = nil
        showMatchCount()
    }

    func showMatchCount() {
        let reading = findReadingProgress
        filterBar.showMatchCount(
            current: (find.current ?? 0) + 1,
            of: find.matches?.count ?? 0,
            // A search still waiting on pages is as incomplete as one that stopped at its limit,
            // and says so the same way: "3 of 17+ matches", the count that promises more.
            isComplete: (find.matches?.isComplete ?? true) && reading == nil,
            finding: find.matches != nil,
            reading: reading
        )
    }
}
