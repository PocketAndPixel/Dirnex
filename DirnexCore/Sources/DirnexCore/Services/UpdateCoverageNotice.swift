import Foundation

/// The notice before installing an update the user's key doesn't cover (PLAN.md §M29 "Updates for
/// a key whose period has ended"): *"Your license covers versions released until 12 March 2027.
/// Dirnex 1.4.0 came out later, so it will show the license reminder. Your current version stays
/// reminder-free."*, with **Renew**, **Update Anyway** and **Not Now**.
///
/// Everyone keeps getting updates. The notice exists so that a paying customer never meets the
/// reminder after an update they didn't knowingly choose, which is PLAN.md §6's second M29 risk.
public struct UpdateCoverageNotice: Sendable, Equatable {
    /// The last release day the key covers.
    public let until: LicenseDay
    /// The update's version, as the notice names it.
    public let version: String

    /// The notice to show before installing `version`, or `nil` when the update changes nothing
    /// about the reminder.
    ///
    /// It appears only when the update would **start** the reminder: the key covers the running
    /// build and doesn't cover the update. With no key, or a key that already doesn't cover the
    /// running build, the reminder is there either way, so there is nothing to warn about. An
    /// undated update counts as covered, like an undated build.
    public static func notice(
        key: LicenseKey?,
        currentReleaseDay: LicenseDay?,
        updateVersion version: String,
        updateReleaseDay: LicenseDay?
    ) -> UpdateCoverageNotice? {
        guard let key,
              key.covers(releaseDay: currentReleaseDay),
              !key.covers(releaseDay: updateReleaseDay)
        else {
            return nil
        }
        return UpdateCoverageNotice(until: key.until, version: version)
    }
}
