import Foundation

/// The tabs closed in one window, newest last, so ⇧⌘T can bring them back in the order a browser
/// does: the last one closed comes back first, into the pane it left and the place it had there.
///
/// Generic over the tab for the reason ``TabList`` is: the app's tab is a main-actor class full of
/// view state the core has no business knowing, and what lives here is the bookkeeping — which tab
/// comes back next, where it goes, and how many are kept.
///
/// **One list for the window, not one per pane.** ⇧⌘T undoes the last close, wherever it happened,
/// so a tab closed on the left comes back on the left even when the right pane has the focus. Held
/// for the run only: a closed tab is a live tab kept aside, never written down.
public struct ClosedTabs<Tab> {
    /// One closed tab and where it was.
    public struct Entry {
        public let tab: Tab
        /// The pane it was closed in.
        public let pane: PaneSide
        /// Where it sat in that pane's strip, which is the slot it goes back into — the slot before
        /// a tab's own index puts it back at that index (``TabList/insert(_:atSlot:)``), and a strip
        /// that has since shrunk takes it at the end.
        public let slot: Int
    }

    /// Oldest first; ``popLast()`` takes from the end.
    public private(set) var entries: [Entry] = []
    /// The most tabs kept. A closed tab holds its whole state — its trail, its marks, and until it
    /// is shown again its last listing — so the oldest goes once this many newer ones are kept.
    public let capacity: Int

    public init(capacity: Int = 20) {
        self.capacity = max(capacity, 1)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Keep `tab`, closed in `pane` at `index`. Returns the oldest tab when it had to make room, so
    /// the caller can let go of whatever that one still holds.
    @discardableResult
    public mutating func push(_ tab: Tab, from pane: PaneSide, at index: Int) -> Tab? {
        entries.append(Entry(tab: tab, pane: pane, slot: max(index, 0)))
        guard entries.count > capacity else { return nil }
        return entries.removeFirst().tab
    }

    /// The tab closed most recently, taken out of the list — `nil` when nothing is left to reopen.
    public mutating func popLast() -> Entry? {
        entries.popLast()
    }

    /// Forget every closed tab `shouldForget` names — the ones standing in a vault that has just
    /// locked, which must not be reopenable into a volume that is gone and whose names are exactly
    /// what locking was meant to put away.
    public mutating func forget(where shouldForget: (Tab) -> Bool) {
        entries.removeAll { shouldForget($0.tab) }
    }
}

extension ClosedTabs.Entry: Equatable where Tab: Equatable {}
extension ClosedTabs.Entry: Sendable where Tab: Sendable {}
extension ClosedTabs: Equatable where Tab: Equatable {}
extension ClosedTabs: Sendable where Tab: Sendable {}
