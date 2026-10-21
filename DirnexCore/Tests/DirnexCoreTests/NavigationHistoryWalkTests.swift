import Foundation
import Testing

@testable import DirnexCore

/// A walk along the trail between the press and the listing that ends it: what ⌘[ steps on from,
/// what a failure goes back to, and what happens to a folder that is gone.
@Suite("NavigationHistory walks")
struct NavigationHistoryWalkTests {
    private func path(_ raw: String) -> VFSPath { .local(raw) }

    // MARK: - Walks in flight

    /// A trail through `names`, on the newest one or landed on the one at `index`.
    private func trail(_ names: [String], landedOn index: Int? = nil) -> NavigationHistory {
        var history = NavigationHistory(initialPath: path(names[0]))
        for name in names.dropFirst() {
            history.visit(path(name))
        }
        if let index {
            _ = history.jump(to: index)
            history.land(on: path(names[index]))
        }
        return history
    }

    @Test("a walk moves the position at once and the landed entry only when it lists")
    func walkLandsOnlyWhenListed() {
        var history = trail(["/a", "/b", "/c"])
        _ = history.back()
        #expect(history.currentIndex == 1)
        #expect(history.landedIndex == 2)
        #expect(history.walk == .back)

        history.land(on: path("/b"))
        #expect(history.landedIndex == 1)
        #expect(history.walk == nil)
    }

    @Test("quick presses step on from the walk in flight, not from the screen")
    func quickPressesAccumulate() {
        var history = trail(["/a", "/b", "/c", "/d"])
        _ = history.back()
        _ = history.back()
        let third = history.back()
        #expect(third == path("/a"))
        #expect(history.landedIndex == 3)
    }

    @Test("a walk overtaken by a listing of somewhere else settles back on the screen")
    func overtakenWalkSettlesBack() {
        var history = trail(["/a", "/b", "/c"])
        _ = history.back()
        history.land(on: path("/elsewhere"))
        #expect(history.currentIndex == 2)
        #expect(history.landedIndex == 2)
        #expect(history.walk == nil)
    }

    /// The bug the landed entry exists for: a failed ⌘[ used to leave the trail on the folder that
    /// failed while the pane still showed the one it left.
    @Test("a failed walk goes back to the entry on screen and forgets nothing")
    func failedWalkReverts() {
        var history = trail(["/a", "/b", "/c"])
        _ = history.back()
        history.revert()
        #expect(history.currentPath == path("/c"))
        #expect(history.entries == [path("/a"), path("/b"), path("/c")])
        #expect(history.canGoBack)
        #expect(!history.canGoForward)
        #expect(history.walk == nil)
    }

    @Test("a fresh visit during a walk branches from the folder on screen")
    func visitDuringWalkBranchesFromScreen() {
        var history = trail(["/a", "/b", "/c"])
        _ = history.back() // heading for /b, still showing /c
        history.visit(path("/c/child")) // clicked in /c's listing
        #expect(history.entries == [path("/a"), path("/b"), path("/c"), path("/c/child")])
        #expect(history.back() == path("/c"))
    }

    @Test("re-listing the folder on screen during a walk ends the walk there")
    func revisitDuringWalkSettles() {
        var history = trail(["/a", "/b", "/c"])
        _ = history.back()
        history.visit(path("/c"))
        #expect(history.currentIndex == 2)
        #expect(history.entries.count == 3)
        #expect(history.walk == nil)
    }

    // MARK: - A folder that is gone

    @Test("⌘[ into a gone folder forgets it and offers the one before")
    func backSkipsGoneFolder() {
        var history = trail(["/a", "/b", "/gone", "/c"])
        #expect(history.back() == path("/gone"))
        let next = history.dropUnreachableTarget()
        #expect(next == path("/b"))
        #expect(history.entries == [path("/a"), path("/b"), path("/c")])
        #expect(history.landedIndex == 2)
        #expect(history.walk == .back)
    }

    @Test("several quick ⌘[ that end on a gone folder carry on past it, not from the screen")
    func quickPressesSkipFromTheTarget() {
        var history = trail(["/a", "/gone", "/c", "/d", "/e"])
        _ = history.back()
        _ = history.back()
        #expect(history.back() == path("/gone"))
        #expect(history.dropUnreachableTarget() == path("/a"))
        #expect(history.landedIndex == 3) // still /e, one place lower
    }

    @Test("⌘] into a gone folder forgets it and offers the one after")
    func forwardSkipsGoneFolder() {
        var history = trail(["/a", "/gone", "/b"], landedOn: 0)
        #expect(history.forward() == path("/gone"))
        #expect(history.dropUnreachableTarget() == path("/b"))
        #expect(history.entries == [path("/a"), path("/b")])
    }

    @Test("a gone oldest folder leaves the walk on the screen with nowhere further back")
    func goneOldestStops() {
        var history = trail(["/gone", "/a"])
        _ = history.back()
        #expect(history.dropUnreachableTarget() == nil)
        #expect(history.entries == [path("/a")])
        #expect(history.currentPath == path("/a"))
        #expect(!history.canGoBack)
        #expect(history.walk == nil)
    }

    @Test("a gone folder picked from the list is forgotten and not replaced by a neighbour")
    func goneJumpStops() {
        var history = trail(["/a", "/gone", "/b", "/c"])
        _ = history.jump(to: 1)
        #expect(history.dropUnreachableTarget() == nil)
        #expect(history.entries == [path("/a"), path("/b"), path("/c")])
        #expect(history.currentPath == path("/c"))
    }

    @Test("the same folder either side of a gone one folds into one visit")
    func neighboursFold() {
        var history = trail(["/a", "/gone", "/a"])
        _ = history.back()
        #expect(history.dropUnreachableTarget() == nil)
        #expect(history.entries == [path("/a")])
        #expect(history.currentIndex == 0)
        #expect(history.landedIndex == 0)
    }

    @Test("a fold onto the folder on screen walks one further back")
    func foldOntoScreenGoesFurther() {
        var history = trail(["/a", "/b", "/gone", "/b"])
        _ = history.back()
        #expect(history.dropUnreachableTarget() == path("/a"))
        #expect(history.entries == [path("/a"), path("/b")])
        #expect(history.landedIndex == 1)
    }

    @Test("a fold going forward skips the duplicate")
    func forwardFoldSkipsDuplicate() {
        var history = trail(["/a", "/gone", "/a", "/b"], landedOn: 0)
        _ = history.forward()
        #expect(history.dropUnreachableTarget() == path("/b"))
        #expect(history.entries == [path("/a"), path("/b")])
    }

    @Test("the folder on screen is never forgotten, even when it is what came back gone")
    func screenIsNeverDropped() {
        var history = trail(["/a", "/b"])
        _ = history.jump(to: 1)
        #expect(history.dropUnreachableTarget() == nil)
        #expect(history.entries == [path("/a"), path("/b")])
    }

    @Test("only a missing place or a file in its stead counts as gone")
    func goneErrors() {
        let place = path("/a")
        #expect(VFSError.notFound(place).meansPlaceIsGone)
        #expect(VFSError.notADirectory(place).meansPlaceIsGone)
        #expect(!VFSError.permissionDenied(place).meansPlaceIsGone)
        #expect(!VFSError.io(path: place, code: EIO).meansPlaceIsGone)
    }
}
