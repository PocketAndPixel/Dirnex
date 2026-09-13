import DirnexCore
import Foundation

/// Live refresh for a pane on the **Photos library**, woken by the library rather than by a clock
/// (PLAN.md §M28 Slice 4).
///
/// It rides the remote poll's machinery everywhere but the one place the two differ, *when*: it is
/// armed and stood down by the same funnel (`updateRemoteRefreshSchedule`), keeps the same "is
/// anybody looking" gate, runs the same passive refresh, and spaces rounds by what the last one cost.
/// Only the sleep is replaced — by waiting for `PhotosLibraryChangeMonitor` to count a change this
/// pane has not refreshed for yet.
extension PanelViewController {
    /// Wait for a change, let its burst settle, re-list — until the task is cancelled or the pane
    /// stops qualifying.
    ///
    /// **The subscription is taken before the generation is read**, so a change landing between the
    /// two wakes the loop rather than slipping past it; the extra wake that ordering can cost is
    /// answered by comparing generations again.
    ///
    /// **A pane remembers the generation it last refreshed at, per path**, in the same measurement
    /// that carries the cost — which is what makes a covered pane catch up when it is uncovered: the
    /// loop that stood down is gone, and the one that re-arms finds the library a generation or
    /// more ahead and refreshes at once. A pane that has only just arrived records the current
    /// generation as its starting point, because arriving *was* a listing.
    func runLibraryChangeLoop(for path: VFSPath) async {
        let monitor = PhotosLibraryChangeMonitor.shared
        var changes = monitor.changes().makeAsyncIterator()
        monitor.startIfPermitted()

        var seen: Int
        if let last = remoteRefreshLastPoll, last.path == path, let generation = last.libraryGeneration {
            seen = generation
        } else {
            seen = monitor.generation
            remoteRefreshLastPoll = RemoteRefreshMeasurement(
                path: path, duration: 0, finished: Date(), libraryGeneration: seen
            )
        }

        while !Task.isCancelled {
            guard monitor.generation != seen else {
                guard await changes.next() != nil else { return }
                continue
            }
            let last = remoteRefreshLastPoll.flatMap { $0.path == path ? $0 : nil }
            let delay = RemoteRefreshPolicy.delayAfterLibraryChange(
                afterRefreshTaking: last?.duration,
                finishedSecondsAgo: last.map { Date().timeIntervalSince($0.finished) }
            )
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, panel.path == path, isRemoteRefreshWanted else { return }
            // Read before the refresh rather than after it: a change that lands while this round is
            // listing belongs to the next round, and reading afterwards would count it as seen.
            seen = monitor.generation
            guard await refreshUnasked(path, wake: .libraryChange, libraryGeneration: seen) else {
                return
            }
        }
    }
}
