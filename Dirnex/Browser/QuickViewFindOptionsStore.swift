import AppKit
import DirnexCore

/// Case Sensitive and Whole Word, remembered across Quick View's five surfaces and across launches
/// (2026-09-18).
///
/// One object rather than a value on each bar, because the five bars are built eagerly and live as
/// long as the preview does: a value read at construction would carry over to a surface that had
/// never been built and not to one that had, so whether the option followed you from a text preview
/// to a CSV would depend on which files you had opened first. That is the shape this codebase keeps
/// recording — a rule whose answer depends on invisible state — and it is worse than not persisting
/// at all, because it looks like it works.
///
/// So every bar reads *this* and writes through it, and ``didChange`` is what puts the other four in
/// step: each rebuilds its menu and re-runs its search, which is not waste — a table still holding a
/// filtered CSV has to be right about it before it is shown again. An idle bar's re-run costs a
/// cleared match set, since every `filterChanged` guards on an empty query.
///
/// **The domain is a required argument, with no `.standard` default anywhere below ``standard``.**
/// The app test target's `UserDefaults.standard` *is* the developer's own `com.dirnex.Dirnex`
/// (docs/NOTES.md ▸ Testing), and this store is read as well as written: a test asserting that the
/// options start off would otherwise be asserting something about whoever ran it, and would fail on
/// the machine of anyone who had turned Case Sensitive on in the real app.
@MainActor
final class QuickViewFindOptionsStore {
    /// The app's own, on `UserDefaults.standard`. Handed to every preview, so two Quick Views open at
    /// once share one answer rather than agreeing only until the next launch.
    static let standard = QuickViewFindOptionsStore(defaults: .standard)

    /// Posted (on the main actor) when the options change. `object` is the store that changed, so a
    /// bar on a test's scratch store never hears the app's.
    static let didChange = Notification.Name("Dirnex.quickViewFindOptionsDidChange")

    /// Stored under its names rather than the option set's raw bits (``DirnexCore/FilterQuery/Options/storedNames``).
    private static let key = "Dirnex.quickView.findOptions"

    private let defaults: UserDefaults

    /// How the text is read. Off unless the user turned one on, which is what shipped before the bar
    /// offered a choice.
    private(set) var options: FilterQuery.Options

    init(defaults: UserDefaults) {
        self.defaults = defaults
        // `stringArray(forKey:)` is the tolerant read by construction: it answers `nil`, never a
        // partial value, for anything that is not an array of strings (measured 2026-09-18), so a
        // hand-edited or newer-build value falls back to the default instead of half-applying.
        options = FilterQuery.Options(storedNames: defaults.stringArray(forKey: Self.key) ?? [])
    }

    /// The one way the options change. A no-op when nothing moved, so a bar that rebuilds its menu
    /// from the store cannot loop through the notification.
    func apply(_ newValue: FilterQuery.Options) {
        guard newValue != options else { return }
        options = newValue
        if newValue.isEmpty {
            // Removed rather than written empty, so an install where nobody has touched the toggles
            // keeps the key out of its domain — what the strip's dragged height already does.
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(newValue.storedNames, forKey: Self.key)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
