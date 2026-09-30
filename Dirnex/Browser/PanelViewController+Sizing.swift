import AppKit
import DirnexCore

/// Total Commander's Space-on-directory in-place sizing (PLAN.md §M1 "Space-on-dir
/// in-place size"). Pressing Space on a folder marks it (the normal mark-and-advance
/// gesture) and, here, kicks off a background recursive walk; when the byte total
/// lands it replaces the folder's dash in the size column and joins any size-sort.
///
/// The heavy lifting is `DirnexCore.DirectorySizer` (headless, tested); this shell
/// only schedules it off the main thread and applies the result if the pane is still
/// showing the same directory.
///
/// **A remote folder is walked on different terms, and the difference is one measurement**
/// (PLAN.md §M21 Slice 11). Locally a directory is a `readdir`; over a connected server it is a
/// billed request at a network round trip — measured against the live S3 endpoint at 0.601–0.699 s
/// per listing, so a ten-directory prefix costs 6.2 s and a thousand-directory one costs ten
/// minutes and a thousand requests. So a remote walk is **bounded** (`DirectorySizeBudget`),
/// **abandoned** when this pane stops looking, and **visible** while it runs, where a local one is
/// none of those and correctly so — nothing is spent finishing it. All three differences come off
/// the one budget rather than off three separate tests of the backend.
extension PanelViewController {
    /// Size the directory `entry` unless it already carries a computed total. Cheap to
    /// call on a re-press: once a size exists the guard makes it a no-op, so marking a
    /// run of folders never re-walks one that was already sized.
    func computeDirectorySize(for entry: FileEntry) {
        // `panel.computedSize` reads the drawing surface, so Space on an expanded child at any depth
        // sees its own total and won't re-walk one already sized.
        guard panel.computedSize(of: entry) == nil else { return }
        // The same rule the bars are drawn under, so one pane never shows two kinds of number in one
        // size column: with git-aware sizes on, a folder sized by hand excludes what Git ignores
        // exactly as an auto-scanned one does.
        let rule = directorySizeRule
        // A folder the rule excludes has no filtered total to compute — walking it would answer
        // "Zero KB", which reads as *"measured, and empty"* about a `build/` holding gigabytes. Space
        // leaves the dash exactly as the auto-scan does (`SizeVisualization.init`); the row is marked
        // `!` and the status line says sizes exclude Git-ignored.
        guard !rule.exclude(entry.path) else { return }
        let budget = DirectorySizeBudget.forBackend(entry.path.backend)
        if budget.abandonsWhenUnwatched {
            computeBudgetedDirectorySize(for: entry, budget: budget, rule: rule)
        } else {
            computeLocalDirectorySize(for: entry, rule: rule)
        }
    }

    /// The original walk, unchanged: detached, unbounded, and deliberately outliving the gesture.
    /// A local total that lands after the user has arrowed on is still worth having — it goes into
    /// the cache and the folder shows it the next time it is on screen, for free.
    private func computeLocalDirectorySize(for entry: FileEntry, rule: DirectorySizeRule) {
        let path = entry.path
        let directory = panel.path
        let token = loadToken
        let exclude = rule.exclude
        Task {
            guard let bytes = await DirectoryLoader.size(backend, of: path, excluding: exclude)
            else { return }
            // Discard a total that resolved after the user navigated away or switched
            // tabs — both bump `loadToken`; the path check is belt-and-suspenders.
            guard token == loadToken, panel.path == directory else { return }
            applyDirectorySize(bytes, to: path)
        }
    }

    /// The remote walk: bounded, cancellable, and drawn as running.
    ///
    /// Re-pressing Space on a folder already being walked is a no-op rather than a second walk —
    /// the guard the local path gets from `computedSize` does not cover the in-flight window, which
    /// over a network is seconds long rather than instant, and every duplicate is a duplicate bill.
    private func computeBudgetedDirectorySize(
        for entry: FileEntry,
        budget: DirectorySizeBudget,
        rule: DirectorySizeRule
    ) {
        let path = entry.path
        guard directorySizeWalks[path] == nil else { return }
        let directory = panel.path
        let token = loadToken
        // A re-press after a give-up is a deliberate retry, so the marker is dropped here rather
        // than kept forever — the user is allowed to spend the budget again on purpose.
        directorySizesGaveUp.remove(path)
        let walk = DirectoryLoader.budgetedSize(
            backend, of: path, budget: budget, excluding: rule.exclude
        )
        directorySizeWalks[path] = walk
        redrawSizedRow(at: path) // draw the in-flight marker in place of the dash

        Task {
            let outcome = await walk.value
            directorySizeWalks[path] = nil
            guard token == loadToken, panel.path == directory else { return }
            switch outcome {
            case let .total(bytes):
                applyDirectorySize(bytes, to: path)
            case .gaveUp:
                directorySizesGaveUp.insert(path)
                // The column can only carry a glyph, so the words go to the two places that have
                // room: a short note on the status line now, and the full reason in the row's
                // tooltip for as long as the marker is there (`FileFormatting.sizeToolTip`).
                //
                // **The split is forced by a measurement, not by taste.** The status label
                // tail-truncates at the pane's width — **542 pt**, probed in the running app — and
                // the first draft of this sentence measured 557 pt in English and 713 in Russian,
                // so it lost the half that says *why* in 10 of 14 languages.
                //
                // The residual is the **folder name**, which is unbounded: a 40-character one puts
                // even this short sentence at 468 pt, and a longer one past the pane whatever the
                // sentence says. So truncation here can be made unlikely and never impossible,
                // which is exactly why the reason lives in the tooltip instead of on this line.
                //
                // One literal across several source lines: the `\` continuations keep it a single
                // string, so it is extracted as one key rather than silently going verbatim
                // (docs/NOTES.md ▸ Localization).
                showTransientStatus(String(
                    localized: """
                    Stopped measuring “\(path.lastComponent)” — too many folders.
                    """,
                    comment: """
                    Status line shown when a recursive folder size over a server gave up at its \
                    budget. The argument is the folder's name. Keep it short: this line \
                    tail-truncates at the pane's width, so a longer sentence loses its own \
                    ending. The fuller explanation is a separate tooltip string.
                    """
                ))
                redrawSizedRow(at: path)
            case .unavailable:
                // Cancelled, or unreadable. Both mean "no total" and neither is worth a sentence:
                // a cancel is the user's own doing, and the row simply goes back to its dash.
                redrawSizedRow(at: path)
            }
        }
    }

    /// Bank a total and re-render. A size can reorder the list (when sorting by size), so this
    /// re-renders — but as a background refresh that never scrolls, so the number appears without
    /// yanking the user's reading position.
    private func applyDirectorySize(_ bytes: Int64, to path: VFSPath) {
        if deferRefreshIfRenaming() { return }
        reconcileCursorFromTable()
        panel.setDirectorySize(path, bytes: bytes)
        renderRefresh()
    }

    /// Abandon every walk this pane is paying for, because it has stopped looking — a navigation,
    /// a tab switch, or the pane going away.
    ///
    /// Only the budgeted walks are here to cancel; a local one is not tracked at all, which is what
    /// makes "unwatched" mean the same thing in both places rather than being a rule somebody has
    /// to keep. Called from the two `loadToken` bumps that mean *the pane moved* — a refresh of the
    /// same directory deliberately leaves an in-flight walk alone, since its row is still on screen.
    func cancelUnwatchedDirectorySizeWalks() {
        for walk in directorySizeWalks.values { walk.cancel() }
        directorySizeWalks.removeAll()
        // The give-up markers describe rows this pane is no longer showing. Left behind they would
        // re-appear on a folder of the same name somewhere else, which is a claim about the wrong
        // directory.
        directorySizesGaveUp.removeAll()
    }

    /// How the size column should draw `entry` right now — the two states a byte count cannot
    /// express.
    ///
    /// Both are remote-only in practice, because only a **bounded** walk is refused. Two things
    /// reach the give-up set and they mean the same thing to the reader: Space on one folder whose
    /// own walk ran past `DirectorySizeBudget.remote`, and a row size-visualization mode never got
    /// to because the whole set's allowance ran out first (`DirectorySizeProvider.gaveUpKey`).
    func directorySizeState(for entry: FileEntry) -> DirectorySizeDisplayState {
        if directorySizeWalks[entry.path] != nil { return .measuring }
        if directorySizesGaveUp.contains(entry.path) { return .gaveUp }
        return .idle
    }

    /// Repaint one row addressed by path rather than by index, since a walk lands long after the
    /// row number that started it may have meant anything. A row that is no longer displayed is
    /// simply not found, and nothing is drawn.
    private func redrawSizedRow(at path: VFSPath) {
        guard let index = panel.displayedIndex(ofID: path) else { return }
        redrawRow(row(forEntryIndex: index))
    }
}

/// What the size column draws for a directory beyond a byte count or a dash.
///
/// A third and fourth state rather than more `Int64?` sentinels: "being measured" and "gave up"
/// are facts about the *question*, not about the folder's bytes, and `computedSize` must keep
/// answering only the latter — the size bars and the size sort both read it as a number or nothing.
enum DirectorySizeDisplayState {
    case idle
    case measuring
    case gaveUp
}
