import Foundation
import Testing

@testable import DirnexCore

@Suite("NavigationHistory")
struct NavigationHistoryTests {
    private func path(_ raw: String) -> VFSPath { .local(raw) }

    @Test("a fresh history holds only the initial path, with nowhere to go")
    func startsAtInitial() {
        let history = NavigationHistory(initialPath: path("/Users/me"))
        #expect(history.entries == [path("/Users/me")])
        #expect(history.currentPath == path("/Users/me"))
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test("visiting a new path appends it and enables going back")
    func visitAppends() {
        var history = NavigationHistory(initialPath: path("/a"))
        history.visit(path("/a/b"))
        #expect(history.entries == [path("/a"), path("/a/b")])
        #expect(history.currentPath == path("/a/b"))
        #expect(history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test("re-visiting the current path is a no-op (a refresh doesn't grow the trail)")
    func visitSameIsNoOp() {
        var history = NavigationHistory(initialPath: path("/a"))
        history.visit(path("/a"))
        #expect(history.entries == [path("/a")])
        #expect(history.currentIndex == 0)
    }

    @Test("back and forward walk the trail without rewriting it")
    func backAndForward() {
        var history = NavigationHistory(initialPath: path("/a"))
        history.visit(path("/b"))
        history.visit(path("/c"))

        let wentBack = history.back()
        #expect(wentBack == path("/b"))
        #expect(history.canGoBack)
        #expect(history.canGoForward)

        let wentForward = history.forward()
        #expect(wentForward == path("/c"))
        #expect(!history.canGoForward)
        // The trail is unchanged by the walk.
        #expect(history.entries == [path("/a"), path("/b"), path("/c")])
    }

    @Test("back at the oldest entry and forward at the newest return nil")
    func edgesReturnNil() {
        var history = NavigationHistory(initialPath: path("/a"))
        #expect(history.back() == nil)
        #expect(history.forward() == nil)

        history.visit(path("/b"))
        let toOldest = history.back()
        #expect(toOldest == path("/a"))
        #expect(history.back() == nil) // already oldest
    }

    @Test("visiting after going back truncates the forward entries")
    func visitTruncatesForward() {
        var history = NavigationHistory(initialPath: path("/a"))
        history.visit(path("/b"))
        history.visit(path("/c"))
        _ = history.back() // now at /b, /c is ahead

        history.visit(path("/d"))
        #expect(history.entries == [path("/a"), path("/b"), path("/d")])
        #expect(history.currentPath == path("/d"))
        #expect(!history.canGoForward)
    }

    @Test("jump moves straight to an entry; out-of-range is ignored")
    func jumpToIndex() {
        var history = NavigationHistory(initialPath: path("/a"))
        history.visit(path("/b"))
        history.visit(path("/c"))

        let jumped = history.jump(to: 0)
        #expect(jumped == path("/a"))
        #expect(history.currentIndex == 0)
        #expect(history.canGoForward)

        let outOfRange = history.jump(to: 9)
        #expect(outOfRange == nil)
        #expect(history.currentIndex == 0) // unchanged
    }

    @Test("the trail is bounded, dropping the oldest while keeping the current position")
    func boundedByCapacity() {
        var history = NavigationHistory(initialPath: path("/p0"), capacity: 3)
        history.visit(path("/p1"))
        history.visit(path("/p2"))
        history.visit(path("/p3")) // overflows: /p0 falls off the front

        #expect(history.entries == [path("/p1"), path("/p2"), path("/p3")])
        #expect(history.currentPath == path("/p3"))
        #expect(history.currentIndex == 2)

        // Back still walks the retained trail correctly after trimming.
        #expect(history.back() == path("/p2"))
    }

    @Test("capacity is clamped to at least one entry")
    func capacityFloor() {
        var history = NavigationHistory(initialPath: path("/a"), capacity: 0)
        history.visit(path("/b"))
        #expect(history.entries == [path("/b")])
        #expect(history.currentPath == path("/b"))
        #expect(!history.canGoBack)
    }
}
