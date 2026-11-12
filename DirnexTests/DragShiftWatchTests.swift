import Foundation
import Testing

@testable import Dirnex

/// The watch that notices Shift during a drag holding a folder (`DragShiftWatch`, 2026-11-09). A drag
/// reports nothing when only a key changes, so the watch's timer is what redraws the line under the
/// row; the timer itself is exercised by `FolderZipHandoffTests`.
@MainActor
@Suite("Drag Shift watch")
struct DragShiftWatchTests {
    /// The key a watch reads.
    @MainActor
    private final class Key {
        var isDown = false
    }

    @Test("a press and a release are each noticed once")
    func noticesEachChange() {
        let key = Key()
        let watch = DragShiftWatch(keyHeld: { key.isDown }, onChange: {})
        defer { watch.stop() }
        #expect(!watch.isHeld)
        #expect(!watch.sample())
        key.isDown = true
        #expect(watch.sample())
        #expect(watch.isHeld)
        #expect(!watch.sample())
        key.isDown = false
        #expect(watch.sample())
        #expect(!watch.isHeld)
    }

    @Test("a key already down as the drag begins is not a change")
    func startsFromTheKeyAsItIs() {
        let watch = DragShiftWatch(keyHeld: { true }, onChange: {})
        defer { watch.stop() }
        #expect(watch.isHeld)
        #expect(!watch.sample())
    }
}
