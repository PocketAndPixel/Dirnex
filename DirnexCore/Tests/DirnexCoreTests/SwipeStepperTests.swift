import Testing
@testable import DirnexCore

/// The two-finger swipe that flips files under a full-size Quick View (PLAN.md §M11). These pin
/// the decisions no trackpad is needed to check — above all the two ways the gesture could run
/// away through a folder.
@Suite("SwipeStepper")
struct SwipeStepperTests {
    /// One deliberate swipe past the threshold moves exactly one row, not several.
    @Test("a swipe crossing the threshold steps one row")
    func swipeStepsOnce() {
        var stepper = SwipeStepper()
        #expect(stepper.step(deltaX: 0, deltaY: 0, phase: .began, isMomentum: false) == 0)
        var steps = 0
        for _ in 0..<8 {
            steps += stepper.step(
                deltaX: -SwipeStepper.threshold / 8,
                deltaY: 0,
                phase: .changed,
                isMomentum: false
            )
        }
        #expect(steps == 1)
    }

    /// Under natural scrolling, fingers left brings the next file on; fingers right goes back.
    @Test("direction follows the raw delta, so it inverts with natural scrolling")
    func directionFollowsDelta() {
        var forward = SwipeStepper()
        let next = forward.step(
            deltaX: -SwipeStepper.threshold,
            deltaY: 0,
            phase: .changed,
            isMomentum: false
        )
        #expect(next == 1)

        var backward = SwipeStepper()
        let previous = backward.step(
            deltaX: SwipeStepper.threshold,
            deltaY: 0,
            phase: .changed,
            isMomentum: false
        )
        #expect(previous == -1)
    }

    /// The expensive failure: a flick's coast walking the cursor through the whole directory
    /// after the fingers have already left the glass.
    @Test("momentum after the fingers lift steps nothing")
    func momentumIsIgnored() {
        var stepper = SwipeStepper()
        var steps = 0
        for _ in 0..<20 {
            steps += stepper.step(
                deltaX: -SwipeStepper.threshold,
                deltaY: 0,
                phase: .changed,
                isMomentum: true
            )
        }
        #expect(steps == 0)
    }

    /// Scrolling a long document drifts sideways; that is not a request for the next file.
    @Test("a mostly-vertical scroll steps nothing however far it goes")
    func verticalScrollIsIgnored() {
        var stepper = SwipeStepper()
        var steps = 0
        for _ in 0..<20 {
            steps += stepper.step(deltaX: -20, deltaY: -60, phase: .changed, isMomentum: false)
        }
        #expect(steps == 0)
    }

    /// A long, steady drag keeps flipping rather than stalling after the first one.
    @Test("a drag of three thresholds steps three rows")
    func longDragStepsRepeatedly() {
        var stepper = SwipeStepper()
        var steps = 0
        for _ in 0..<30 {
            steps += stepper.step(
                deltaX: -SwipeStepper.threshold / 10,
                deltaY: 0,
                phase: .changed,
                isMomentum: false
            )
        }
        #expect(steps == 3)
    }

    /// Travel banked by one swipe must not add to the next, or two half-swipes in a row produce a
    /// step neither of them asked for.
    @Test("two half-swipes in separate gestures step nothing")
    func gesturesDoNotAccumulateAcrossPhases() {
        var stepper = SwipeStepper()
        var steps = 0
        for _ in 0..<2 {
            steps += stepper.step(deltaX: 0, deltaY: 0, phase: .began, isMomentum: false)
            steps += stepper.step(
                deltaX: -SwipeStepper.threshold * 0.6,
                deltaY: 0,
                phase: .changed,
                isMomentum: false
            )
            steps += stepper.step(deltaX: 0, deltaY: 0, phase: .ended, isMomentum: false)
        }
        #expect(steps == 0)
    }
}
