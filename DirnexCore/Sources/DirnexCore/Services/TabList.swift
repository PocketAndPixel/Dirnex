import Foundation

/// A pane's tabs in order and which one is showing: the arithmetic behind reordering them, and
/// behind moving one to the other pane.
///
/// Generic over the tab because the app's tab is a main-actor class full of view state the core has
/// no business knowing. What lives here is the *positions*: where a dropped tab lands, which tab is
/// showing after a move, and which takes over when one leaves.
///
/// **There are two ways to name a position, and mixing them was a bug.** A *slot* is a gap between
/// tabs, 0 before the first and `count` after the last; it is what a drop names, because the pointer
/// is between two chips rather than on one. An *index* is where a tab sits. A tab moved to a slot on
/// its right ends up one index short of that slot, because it leaves a gap behind it on the way. The
/// first tab strip read a slot as an index, so a tab dragged to the right landed one place past the
/// pointer, and a short nudge right jumped it over its neighbour. ``TabSlot`` is where a slot comes
/// from.
public struct TabList<Tab> {
    public private(set) var tabs: [Tab]
    public private(set) var activeIndex: Int

    /// `activeIndex` is clamped into the list, so a stale index cannot point past the end.
    public init(tabs: [Tab], activeIndex: Int) {
        self.tabs = tabs
        self.activeIndex = min(max(activeIndex, 0), max(tabs.count - 1, 0))
    }

    // MARK: - Reordering

    /// Move the tab at `source` into `slot`, keeping the same tab showing. `false`, with nothing
    /// changed, when `source` is not a tab, `slot` is not a gap in this list, or the move would leave
    /// the tab where it is.
    @discardableResult
    public mutating func move(from source: Int, toSlot slot: Int) -> Bool {
        guard tabs.indices.contains(source), (0...tabs.count).contains(slot),
              !TabSlot.isNoOpMove(from: source, toSlot: slot) else { return false }
        let destination = slot > source ? slot - 1 : slot
        tabs.insert(tabs.remove(at: source), at: destination)
        activeIndex = Self.index(activeIndex, afterMovingFrom: source, to: destination)
        return true
    }

    /// Whether the showing tab can move `offset` places along the strip. Not past either end: a tab
    /// that wrapped round to the far end would read as the tab vanishing.
    public func canMoveActive(by offset: Int) -> Bool {
        offset != 0 && tabs.indices.contains(activeIndex + offset)
    }

    /// Move the showing tab `offset` places along the strip, −1 to the left and +1 to the right.
    /// `false`, with nothing changed, where ``canMoveActive(by:)`` is.
    @discardableResult
    public mutating func moveActive(by offset: Int) -> Bool {
        guard canMoveActive(by: offset) else { return false }
        let destination = activeIndex + offset
        tabs.insert(tabs.remove(at: activeIndex), at: destination)
        activeIndex = destination
        return true
    }

    // MARK: - Leaving and arriving

    /// Whether a tab can leave this list at all. A pane always shows a tab, so its last one stays.
    public var canRemove: Bool {
        tabs.count > 1
    }

    /// Take the tab at `index` out, to close it or to hand it to the other pane. `nil`, with nothing
    /// changed, for the last tab or an index that is not a tab.
    ///
    /// When the showing tab leaves, the neighbour that slides into its place takes over, or the new
    /// last tab when it was the last. That is the rule Close Tab has always followed.
    public mutating func remove(at index: Int) -> Tab? {
        guard canRemove, tabs.indices.contains(index) else { return nil }
        let tab = tabs.remove(at: index)
        if index < activeIndex || activeIndex >= tabs.count {
            activeIndex -= 1
        }
        return tab
    }

    /// Put `tab` into `slot` and show it. A tab arrives from the other pane because somebody moved
    /// it, and they are still looking at it. A slot past either end is taken as that end.
    public mutating func insert(_ tab: Tab, atSlot slot: Int) {
        let index = min(max(slot, 0), tabs.count)
        tabs.insert(tab, at: index)
        activeIndex = index
    }

    /// Where the tab that was at `index` sits after the tab at `source` moved to `destination`.
    private static func index(_ index: Int, afterMovingFrom source: Int, to destination: Int) -> Int {
        if index == source { return destination }
        if source < index, destination >= index { return index - 1 }
        if source > index, destination <= index { return index + 1 }
        return index
    }
}

extension TabList: Equatable where Tab: Equatable {}
extension TabList: Sendable where Tab: Sendable {}

/// The gaps between a strip's tabs, which a drop names (see ``TabList``): 0 before the first tab and
/// `count` after the last. Apart from `TabList` because it needs no tabs, only where their chips are.
public enum TabSlot {
    /// The slot a drop at `x` names, given each chip's horizontal midpoint in strip order: the gap
    /// before the first chip whose middle is still right of the pointer, or the end. A pointer exactly
    /// on a midpoint counts as that chip's right half.
    public static func slot(forDropAt x: Double, chipMidpoints: [Double]) -> Int {
        chipMidpoints.firstIndex { x < $0 } ?? chipMidpoints.count
    }

    /// Whether moving the tab at `source` to `slot` leaves it where it is. Both gaps beside a tab
    /// do: the one before it and the one after it.
    public static func isNoOpMove(from source: Int, toSlot slot: Int) -> Bool {
        slot == source || slot == source + 1
    }
}
