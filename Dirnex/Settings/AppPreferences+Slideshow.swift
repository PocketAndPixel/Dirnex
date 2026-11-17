import DirnexCore
import Foundation

/// The slideshow interval's bookkeeping (PLAN.md §M39 ▸ Slice 16), out of `AppPreferences` for its
/// length ceiling, as the syntax theme's is: the stored property stays in the class, as stored
/// properties must.
///
/// No change notification: a running slideshow reads the interval each time it starts counting
/// down, so a new value takes effect from the next picture with nobody having to listen.
extension AppPreferences {
    /// Clamp, then write. Clamped here as well as on the way in, because Settings' field can be typed
    /// into past the stepper's range.
    func slideshowIntervalChanged(from old: Int) {
        let clamped = Slideshow.clampedInterval(slideshowInterval)
        guard clamped == slideshowInterval else {
            slideshowInterval = clamped
            return
        }
        guard slideshowInterval != old else { return }
        defaults.set(slideshowInterval, forKey: Keys.slideshowInterval)
    }

    /// The saved interval, or Preview's five seconds when there is none. `object(forKey:)` rather than
    /// `integer(forKey:)`, which answers 0 for a key never written, and the clamp would make that one
    /// second: every fresh install would race through its pictures.
    static func storedSlideshowInterval(in defaults: UserDefaults) -> Int {
        Slideshow.clampedInterval(
            (defaults.object(forKey: Keys.slideshowInterval) as? NSNumber)?.intValue
                ?? Slideshow.defaultInterval
        )
    }
}
