import AppKit

/// Notices Shift going down or up during a drag holding a folder, so the line under the row can say
/// what the key will do (2026-11-09).
///
/// **Polled, because a drag says nothing when only a key changes.** Measured 2026-11-09 with a
/// throwaway drag source: two Shift presses with the pointer at rest brought no
/// `draggingSession(_:movedTo:)` call at all, and a local `.flagsChanged` monitor that saw both presses
/// outside the drag saw nothing during it. `NSEvent.modifierFlags` did change, read by a timer in the
/// `.common` modes the drag's loop runs in.
///
/// **It only redraws the line.** Shift counts as the pointer enters an app (`RemoteDragHandoff`),
/// because Teams and Chrome drop what they read then: a press over an app the pointer is already in
/// was read and ignored in each of Oleg's six logged drops. So a change noticed here tells the user to
/// move out and back in, and changes nothing about the board.
@MainActor
final class DragShiftWatch {
    /// Twenty milliseconds: well under what a person notices, and nothing to the main thread.
    static let interval: TimeInterval = 0.02

    /// Whether the key was down when last looked at.
    private(set) var isHeld: Bool

    private let keyHeld: @MainActor () -> Bool
    private let onChange: @MainActor () -> Void
    private var timer: Timer?

    /// `onChange` is called from the timer when the key changes, so a still pointer is noticed too.
    init(keyHeld: @escaping @MainActor () -> Bool, onChange: @escaping @MainActor () -> Void) {
        self.keyHeld = keyHeld
        self.onChange = onChange
        isHeld = keyHeld()
        // `.common` takes in the event-tracking mode a drag runs the loop in, where a timer in the
        // default mode alone would never fire.
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] timer in
            // Gone with the drag that owned it, ended or not.
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                if self.sample() { self.onChange() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Look at the key once. Returns whether it changed since last looked at.
    @discardableResult
    func sample() -> Bool {
        let held = keyHeld()
        guard held != isHeld else { return false }
        isHeld = held
        return true
    }
}
