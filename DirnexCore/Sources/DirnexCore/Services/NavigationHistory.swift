/// A single pane/tab's back–forward navigation trail (PLAN.md §M3 "Per-panel history
/// (Alt+Down list; Cmd+[ / Cmd+] back/forward)"). Semantics match a web browser's tab
/// history: a fresh navigation truncates any forward entries and appends, while `back`
/// and `forward` only move the cursor without rewriting the trail.
///
/// A pure value type with no AppKit — the app owns the tab that stores it and the popup UI, this
/// owns the trail rules so they stay unit-testable headless (matching `Panel`, `Favorites`, and the
/// command registry). It survives a relaunch with its tab (`StoredNavigationHistory`, in
/// `NavigationHistory+Storage`).
///
/// ## A walk is not over until the folder has listed
///
/// `back`, `forward` and `jump` move ``currentIndex`` at once, because the next ⌘[ pressed before
/// the listing lands has to step on from there — three quick presses go three places back. The
/// entry the pane is actually *showing* is ``landedIndex``, which moves only when a listing lands
/// (``land(on:)``). The two differ while a walk is in flight, and the difference is what a failed
/// walk goes back to (``revert()``): before, a ⌘[ into a deleted folder raised the error and left
/// the trail pointing at the dead folder while the pane still showed the old one, so the next ⌘]
/// went nowhere. Once the trail outlives the session that is routine rather than rare.
public struct NavigationHistory: Sendable, Equatable {
    /// The most entries a trail keeps unless told otherwise.
    public static let defaultCapacity = 80

    /// How the walk in flight was started, which decides what happens if its folder is gone
    /// (``dropUnreachableTarget()``).
    public enum Walk: Sendable, Equatable {
        case back
        case forward
        /// A pick from the ⌥↓ list: the user asked for that one folder, not for "the next one".
        case jump
    }

    /// The visited directories in oldest→newest order — the trail the Alt+Down popup
    /// lists, with `currentIndex` marking where the pane sits within it.
    public private(set) var entries: [VFSPath]
    /// Index into `entries` of the directory the pane is showing or heading to: a walk moves it
    /// before the listing lands. Always valid: the trail is never empty (it seeds with the pane's
    /// initial path).
    public private(set) var currentIndex: Int
    /// Index into `entries` of the directory whose listing last landed — what the pane is showing.
    /// Equal to ``currentIndex`` except while a walk is in flight.
    public private(set) var landedIndex: Int
    /// The walk in flight, or `nil` when the trail is settled.
    public private(set) var walk: Walk?
    /// The most entries kept; older ones fall off the front (a tab visited all day never
    /// grows the trail without bound). The current position shifts to stay valid.
    public let capacity: Int

    public init(initialPath: VFSPath, capacity: Int = defaultCapacity) {
        self.init(entries: [initialPath], currentIndex: 0, capacity: capacity)
    }

    /// A trail as given. Callers keep `currentIndex` inside `entries`, which must not be empty.
    init(entries: [VFSPath], currentIndex: Int, capacity: Int) {
        self.entries = entries
        self.currentIndex = currentIndex
        landedIndex = currentIndex
        self.capacity = max(capacity, 1)
    }

    /// The directory the pane is currently showing.
    public var currentPath: VFSPath { entries[currentIndex] }

    /// Whether there is an older directory to step back to (Cmd+[).
    public var canGoBack: Bool { currentIndex > 0 }

    /// Whether there is a newer directory to step forward to (Cmd+]).
    public var canGoForward: Bool { currentIndex < entries.count - 1 }

    /// Record a fresh navigation to `path`, which has just listed. Re-entering the directory on
    /// screen (a refresh, or the initial load landing on the seeded path) is a no-op so it never
    /// bloats the trail; anything else drops the forward entries and appends `path` as the new tip
    /// — exactly how a browser forgets the forward stack once you branch off it.
    ///
    /// It branches from the entry that was **on screen**, not from a walk still in flight: a folder
    /// clicked in the listing ⌘[ had not yet replaced was clicked in *that* folder, so ⌘[ from it
    /// has to come back there. Any walk in flight is over, since this listing replaced it.
    public mutating func visit(_ path: VFSPath) {
        walk = nil
        guard path != entries[landedIndex] else {
            currentIndex = landedIndex
            return
        }
        entries.removeSubrange((landedIndex + 1)...)
        entries.append(path)
        currentIndex = entries.count - 1
        landedIndex = currentIndex
        trimToCapacity()
    }

    /// Step back one directory, returning where to navigate — or `nil` at the oldest entry.
    public mutating func back() -> VFSPath? {
        guard canGoBack else { return nil }
        currentIndex -= 1
        walk = .back
        return currentPath
    }

    /// Step forward one directory, returning where to navigate — or `nil` at the newest.
    public mutating func forward() -> VFSPath? {
        guard canGoForward else { return nil }
        currentIndex += 1
        walk = .forward
        return currentPath
    }

    /// Jump straight to `index` in the trail (the Alt+Down popup picking an entry),
    /// returning its path — or `nil` for an out-of-range index (leaving the trail untouched).
    public mutating func jump(to index: Int) -> VFSPath? {
        guard entries.indices.contains(index) else { return nil }
        currentIndex = index
        walk = .jump
        return currentPath
    }

    // MARK: - Ending a walk

    /// A listing that did not record a visit has landed on `path`. When it is the walk's target the
    /// walk is over and the pane is there; anything else listed in its place (the walk was overtaken
    /// by a navigation that records no visit), so the trail settles back on what was on screen.
    public mutating func land(on path: VFSPath) {
        if entries[currentIndex] == path {
            landedIndex = currentIndex
        } else {
            currentIndex = landedIndex
        }
        walk = nil
    }

    /// The walk in flight failed: the pane still shows the entry it left, so the trail goes back to
    /// it. Nothing is forgotten — a folder that could not be listed this time (no permission, a
    /// server that did not answer) may well list next time.
    public mutating func revert() {
        currentIndex = landedIndex
        walk = nil
    }

    /// The folder the walk in flight was heading for is gone: forget it, and for a ⌘[ or ⌘], step on
    /// to the next entry the same way and return it so the caller can try that one. `nil` when there
    /// is no next entry, and always for a ``Walk/jump`` — somebody picked that one folder by name, so
    /// they are told it is gone rather than taken to a neighbour they did not pick.
    ///
    /// The next entry is the one past the *gone* one, not one step from the screen: three quick ⌘[
    /// aimed three folders back, and when that third one is gone the fourth is where they were going.
    ///
    /// The entry on screen is never forgotten here, even when the walk was to it: whatever answered
    /// "gone" about the folder the pane is showing, the pane is still the place to say so.
    public mutating func dropUnreachableTarget() -> VFSPath? {
        let step = walk
        let target = currentIndex
        guard target != landedIndex else {
            revert()
            return nil
        }
        removeEntry(at: target)
        // `removeEntry` folds away the newer of two neighbours that meet, so the older one is still
        // at `target - 1` and whatever followed the gone entry is now at `target`. Going back, the
        // older one can be the folder on screen itself (`A, B, gone, B` with the last `B` showing),
        // which is no step at all, so the walk goes one further.
        var next: Int? = switch step {
        case .back: target - 1
        case .forward: target
        case .jump, nil: nil
        }
        if step == .back, next == landedIndex { next = landedIndex - 1 }
        guard let next, entries.indices.contains(next), next != landedIndex else {
            revert()
            return nil
        }
        currentIndex = next
        return currentPath
    }

    // MARK: - Trimming

    /// Take out the entry at `index`, keeping both positions on the entries they named, and fold
    /// the two neighbours it leaves side by side into one if they are the same folder — `A, B, A`
    /// with `B` gone is one visit to `A`, not two in a row that ⌘[ would step between.
    ///
    /// Never called on ``landedIndex``.
    private mutating func removeEntry(at index: Int) {
        entries.remove(at: index)
        if landedIndex > index { landedIndex -= 1 }
        if currentIndex > index { currentIndex -= 1 }
        // The two that now touch are `index - 1` and `index`.
        guard index > 0, index < entries.count, entries[index - 1] == entries[index] else { return }
        entries.remove(at: index)
        if landedIndex >= index { landedIndex -= 1 }
        if currentIndex >= index { currentIndex -= 1 }
    }

    /// Drop the oldest entries once the trail exceeds `capacity`, shifting the positions back by
    /// however many were removed so they keep pointing at the same paths. Only ever called with both
    /// positions on the newest entry, which therefore always survives.
    private mutating func trimToCapacity() {
        let overflow = entries.count - capacity
        guard overflow > 0 else { return }
        entries.removeFirst(overflow)
        currentIndex -= overflow
        landedIndex -= overflow
    }
}
