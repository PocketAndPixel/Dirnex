import Foundation

/// A single pane/tab's back–forward navigation trail (PLAN.md §M3 "Per-panel history
/// (Alt+Down list; Cmd+[ / Cmd+] back/forward)"). Semantics match a web browser's tab
/// history: a fresh navigation truncates any forward entries and appends, while `back`
/// and `forward` only move the cursor without rewriting the trail.
///
/// A pure value type with no persistence or AppKit — the app owns the tab that stores it
/// and the popup UI, this owns the trail rules so they stay unit-testable headless
/// (matching `Panel`, `Hotlist`, and the command registry). Session-scoped: each tab
/// seeds a fresh history at its starting directory (frecency's persistent visit tracking
/// is the separate M3 item that follows).
public struct NavigationHistory: Sendable, Equatable {
    /// The visited directories in oldest→newest order — the trail the Alt+Down popup
    /// lists, with `currentIndex` marking where the pane sits within it.
    public private(set) var entries: [VFSPath]
    /// Index into `entries` of the directory currently on screen. Always valid: the trail
    /// is never empty (it seeds with the pane's initial path).
    public private(set) var currentIndex: Int
    /// The most entries kept; older ones fall off the front (a tab visited all day never
    /// grows the trail without bound). The current position shifts to stay valid.
    public let capacity: Int

    public init(initialPath: VFSPath, capacity: Int = 100) {
        entries = [initialPath]
        currentIndex = 0
        self.capacity = max(capacity, 1)
    }

    /// The directory the pane is currently showing.
    public var currentPath: VFSPath { entries[currentIndex] }

    /// Whether there is an older directory to step back to (Cmd+[).
    public var canGoBack: Bool { currentIndex > 0 }

    /// Whether there is a newer directory to step forward to (Cmd+]).
    public var canGoForward: Bool { currentIndex < entries.count - 1 }

    /// Record a fresh navigation to `path`. Re-entering the current directory (a refresh,
    /// or the initial load landing on the seeded path) is a no-op so it never bloats the
    /// trail; anything else drops the forward entries and appends `path` as the new tip —
    /// exactly how a browser forgets the forward stack once you branch off it.
    public mutating func visit(_ path: VFSPath) {
        guard path != currentPath else { return }
        if canGoForward {
            entries.removeSubrange((currentIndex + 1)...)
        }
        entries.append(path)
        currentIndex = entries.count - 1
        trimToCapacity()
    }

    /// Step back one directory, returning where to navigate — or `nil` at the oldest entry.
    public mutating func back() -> VFSPath? {
        guard canGoBack else { return nil }
        currentIndex -= 1
        return currentPath
    }

    /// Step forward one directory, returning where to navigate — or `nil` at the newest.
    public mutating func forward() -> VFSPath? {
        guard canGoForward else { return nil }
        currentIndex += 1
        return currentPath
    }

    /// Jump straight to `index` in the trail (the Alt+Down popup picking an entry),
    /// returning its path — or `nil` for an out-of-range index (leaving the trail untouched).
    public mutating func jump(to index: Int) -> VFSPath? {
        guard entries.indices.contains(index) else { return nil }
        currentIndex = index
        return currentPath
    }

    /// Drop the oldest entries once the trail exceeds `capacity`, shifting the current
    /// position back by however many were removed so it keeps pointing at the same path.
    private mutating func trimToCapacity() {
        let overflow = entries.count - capacity
        guard overflow > 0 else { return }
        entries.removeFirst(overflow)
        currentIndex -= overflow
    }
}
