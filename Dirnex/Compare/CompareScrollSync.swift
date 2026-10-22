import AppKit

/// Keeps the two compare panes level, row for row (PLAN.md §M31 Slice 3).
///
/// **By row, never by offset.** Both panes have the same rows, but under TextKit 2 the two documents
/// disagree about where a far row is until it has been laid out, by as much as 40 % halfway down
/// 100 000 rows (measured 2026-10-22). So when one pane scrolls, the other is asked where *its* copy
/// of the row at the top is, and is scrolled there: measured on the same documents, that lands the
/// same row at the same height in 0.2 ms, and it held for six turns afterwards. One more check a turn
/// later catches a pane whose layout moved the row after all.
@MainActor
final class CompareScrollSync {
    private let left: ComparePaneView
    private let right: ComparePaneView
    /// Set while this object scrolls a pane itself, so the scroll it causes is not followed back.
    private var isAligning = false
    private var observers: [NSObjectProtocol] = []
    /// Called after either pane has scrolled, for the views that draw what is on screen.
    var didScroll: (() -> Void)?

    init(left: ComparePaneView, right: ComparePaneView) {
        self.left = left
        self.right = right
        for pane in [left, right] {
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

    /// Scroll both panes so that `row` sits a quarter of the way down, with the rows before it above.
    func reveal(row: Int) {
        let visibleRows = Int(left.scrollView.contentSize.height / CompareTextStyle.lineHeight)
        let top = max(0, row - visibleRows / 4)
        left.textView.scroll(toRow: top, offset: 0, x: 0)
        follow(left)
        didScroll?()
    }

    private func paneScrolled(_ pane: ComparePaneView) {
        guard !isAligning else { return }
        follow(pane)
        didScroll?()
        DispatchQueue.main.async { [weak self, weak pane] in
            MainActor.assumeIsolated {
                guard let self, let pane else { return }
                self.correct(after: pane)
            }
        }
    }

    /// Bring the other pane level with `leader`.
    private func follow(_ leader: ComparePaneView) {
        let follower = leader === left ? right : left
        guard let anchor = leader.textView.rowAtTop() else { return }
        isAligning = true
        defer { isAligning = false }
        follower.textView.scroll(
            toRow: anchor.row,
            offset: anchor.offset,
            x: leader.scrollView.documentVisibleRect.minX
        )
    }

    /// Level the panes again if laying out the follower moved its row.
    private func correct(after leader: ComparePaneView) {
        let follower = leader === left ? right : left
        guard let wanted = leader.textView.rowAtTop(), let actual = follower.textView.rowAtTop(),
              wanted.row != actual.row || abs(wanted.offset - actual.offset) > 0.5 else { return }
        follow(leader)
        didScroll?()
    }
}
