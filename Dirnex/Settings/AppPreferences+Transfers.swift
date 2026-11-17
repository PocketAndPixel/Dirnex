import Foundation

/// Operations ▸ whether F5 and F6 ask first and then show their progress in a dialog (PLAN.md §M41).
///
/// Asked for by users coming from Total Commander, and **on by default** for a reason that is about
/// the off switch rather than the feature: the "Don't ask again" box that turns it off lives on the
/// confirmation itself, so the dialog has to show to offer it. Settings ▸ Operations turns it back
/// on. Off, F5 and F6 go straight to the queue bar, as they always have.
///
/// Computed straight over `defaults` rather than stored and `@Published` like its neighbours: the
/// class file sits at SwiftLint's file-length ceiling, and a setting that only F5 and F6 read, each
/// time they run, gains nothing from a cached copy. `objectWillChange` keeps the Settings toggle
/// bound to it in step.
extension AppPreferences {
    var confirmTransfers: Bool {
        get { defaults.object(forKey: Keys.confirmTransfers) as? Bool ?? true }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.confirmTransfers)
        }
    }
}
