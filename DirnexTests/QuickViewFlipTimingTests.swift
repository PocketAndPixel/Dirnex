import AppKit
import Testing

@testable import Dirnex

/// When the page turn moves, relative to when the file it is turning to arrives.
///
/// The flip was written assuming `advance()` puts the next file on screen synchronously, which held
/// while every image arrived within a frame or two. A camera RAW does not: measured in the running
/// app, `showImage` is entered in the same millisecond as `flip` and the picture lands **149–231 ms**
/// later, against a 160 ms slide — so the whole animation ran carrying the *previous* photograph,
/// which then swapped in place once the decode finished. Reported 2026-08-15, in exactly those terms:
/// "it slides the current image and only then changes it to the next one".
///
/// The animation itself is what these assert on: `flip` ends in `animateContent`, which installs a
/// `CABasicAnimation` under a known key, so "has the slide started" is a question the layer answers
/// without a window, a screenshot, or a wait.
@Suite("Quick View flip timing")
@MainActor
struct QuickViewFlipTimingTests {
    /// A surface with a real frame, so the entry offset is a real distance rather than zero.
    private func surface() -> QuickViewPreviewView {
        let view = QuickViewPreviewView(backingColor: .black, header: .none)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func isSliding(_ view: QuickViewPreviewView) -> Bool {
        view.content.layer?.animation(forKey: QuickViewPreviewView.swipeAnimation) != nil
    }

    @Test("a flip whose file is already on screen slides at once")
    func slidesImmediatelyWhenNothingIsLoading() {
        let view = surface()
        var advanced = false
        view.flip(steps: 1) { advanced = true }
        #expect(advanced, "the cursor must move whether or not the slide waits")
        #expect(isSliding(view), "nothing was loading, so the page turn had no reason to wait")
    }

    /// The regression itself. A backend that is still decoding must hold the movement back — the
    /// slide is what says "next file", so running it over the previous one is the bug.
    @Test("a flip whose file is still decoding waits for it")
    func waitsWhileContentIsLoading() {
        let view = surface()
        view.flipGate.isLoading = true
        var advanced = false
        view.flip(steps: 1) { advanced = true }
        #expect(advanced, "the cursor still moves immediately — only the animation waits")
        #expect(!isSliding(view), "the slide ran while the file it is dealing was still decoding")

        view.contentDidLoad()
        #expect(isSliding(view), "the file arrived, so the page turn should have been released")
    }

    /// A held arrow key deals faster than a RAW decodes, so the flip a newer one supersedes must
    /// never land: it would slide a file the cursor has already left.
    @Test("a superseded flip is dropped rather than run late")
    func supersededFlipIsDropped() {
        let view = surface()
        view.flipGate.isLoading = true
        var first = 0, second = 0
        view.flip(steps: 1) { first += 1 }
        view.flipGate.isLoading = true
        view.flip(steps: 1) { second += 1 }
        #expect(first == 1 && second == 1, "each flip advances the cursor exactly once")
        #expect(!isSliding(view))

        view.contentDidLoad()
        #expect(isSliding(view), "the surviving flip should slide when its file lands")
    }

    /// Tearing the surface down has to drop a waiting flip too, or it lands on a preview that has
    /// moved on — the same reason `resetSwipe` is called there, one step earlier.
    @Test("putting the surface away drops a waiting flip")
    func teardownDropsAWaitingFlip() {
        let view = surface()
        view.flipGate.isLoading = true
        view.flip(steps: 1) {}
        view.clear()
        #expect(!isSliding(view))

        view.contentDidLoad()
        #expect(
            !isSliding(view),
            "a flip cancelled with the surface must not be revived by a late load"
        )
    }
}
