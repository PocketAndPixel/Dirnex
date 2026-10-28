import AppKit

/// Keeps the compare panes level, row for row (PLAN.md §M31 Slice 3): the compare window's two, and
/// the merge window's three or four (PLAN.md §M34 Slice 3).
///
/// **By row, never by offset.** Every pane has the same rows, but under TextKit 2 two documents
/// disagree about where a far row is until it has been laid out, by as much as 40 % halfway down
/// 100 000 rows (measured 2026-10-22). So when one pane scrolls, each other one is asked where *its*
/// copy of the row at the top is, and is scrolled there: measured on the same documents, that lands
/// the same row at the same height in 0.2 ms, and it held for six turns afterwards. One more check a
/// turn later catches a pane whose layout moved the row after all.
///
/// A hidden pane is passed over, so the merge window's base follows only while it is shown, and is
/// brought level when it appears (`align()`).
@MainActor
final class CompareScrollSync {
    private let panes: [ComparePaneView]
    /// Set while this object scrolls a pane itself, so the scroll it causes is not followed back.
    private var isAligning = false
    private var observers: [NSObjectProtocol] = []
    /// Called after any pane has scrolled, for the views that draw what is on screen.
    var didScroll: (() -> Void)?

    init(panes: [ComparePaneView]) {
        self.panes = panes
        for pane in panes {
            let observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: pane.scrollView.contentView,
                queue: .main
            ) { [weak self, weak pane] _ in
                MainActor.assumeIsolated {
                    guard let self, let pane else { return }
                    self.paneScrolled(pane)
                }
            }
            observers.append(observer)
        }
    }

    /// Stop following. Called when the window closes.
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// The first pane shown, which the others are brought level with.
    private var leader: ComparePaneView? {
        panes.first { !$0.isHidden }
    }

    /// Scroll every pane so that `row` sits a quarter of the way down, with the rows before it above.
    func reveal(row: Int) {
        guard let leader else { return }
        let visibleRows = Int(leader.scrollView.contentSize.height / CompareTextStyle.lineHeight)
        let top = max(0, row - visibleRows / 4)
        leader.textView.scroll(toRow: top, offset: 0, x: 0)
        follow(leader)
        didScroll?()
    }

    /// Bring every pane level with the first one shown, as when a hidden pane appears.
    func align() {
        guard let leader else { return }
        follow(leader)
        didScroll?()
    }

    private func paneScrolled(_ pane: ComparePaneView) {
        guard !isAligning, !pane.isHidden else { return }
        follow(pane)
        didScroll?()
        DispatchQueue.main.async { [weak self, weak pane] in
            MainActor.assumeIsolated {
                guard let self, let pane else { return }
                self.correct(after: pane)
            }
        }
    }

    /// The panes shown other than `leader`.
    private func followers(of leader: ComparePaneView) -> [ComparePaneView] {
        panes.filter { $0 !== leader && !$0.isHidden }
    }

    /// Bring the other panes level with `leader`.
    private func follow(_ leader: ComparePaneView) {
        guard let anchor = leader.textView.rowAtTop() else { return }
        isAligning = true
        defer { isAligning = false }
        for follower in followers(of: leader) {
            follower.textView.scroll(
                toRow: anchor.row,
                offset: anchor.offset,
                x: leader.scrollView.documentVisibleRect.minX
            )
        }
    }

    /// Level the panes again if laying out a follower moved its row.
    private func correct(after leader: ComparePaneView) {
        guard let wanted = leader.textView.rowAtTop() else { return }
        let moved = followers(of: leader).contains { follower in
            guard let actual = follower.textView.rowAtTop() else { return false }
            return wanted.row != actual.row || abs(wanted.offset - actual.offset) > 0.5
        }
        guard moved else { return }
        follow(leader)
        didScroll?()
    }
}
