import Foundation

/// What the user did with an update Sparkle offered them, in the terms the indicator cares about.
/// A stand-in for Sparkle's `SPUUserUpdateChoice` so this policy stays in `DirnexCore` (data, not
/// AppKit or Sparkle) — the app maps one enum onto the other in a single `switch`.
public enum UpdateChoice: Sendable, Equatable, CaseIterable {
    /// The user accepted; the app is about to relaunch into the new build.
    case install
    /// The user closed the dialog without deciding. Sparkle will offer this same version again.
    case dismiss
    /// The user skipped this version; Sparkle won't raise it again on its own.
    case skip
}

/// Whether a newer Dirnex is waiting, and how the titlebar indicator should read
/// (PLAN.md §M7 "Sparkle 2 updates"). Sparkle's own dialog is a one-shot: dismiss it and the
/// only trace an update exists is gone until the next scheduled check. This is the ambient half —
/// the state a persistent titlebar button tracks so a postponed update stays visible.
///
/// A value type in `DirnexCore` rather than flags on the app's `SPUUpdaterDelegate`, for the same
/// reason as `UpdateChannels`: the transitions are the part that can be wrong (dismiss must *keep*
/// the indicator, skip must clear it), so they are unit-tested and the delegate is a one-line
/// assignment per callback.
public struct UpdateAvailability: Sendable, Equatable {
    /// The version Sparkle found, when it named one. `nil` while nothing is pending, and also for a
    /// pending update whose appcast item carried a blank version string.
    public private(set) var pendingVersion: String?

    /// Whether an update is waiting. Not `pendingVersion != nil`: an update with an unusable version
    /// string still deserves the indicator, it just gets the version-less tooltip.
    public private(set) var isAvailable: Bool

    /// Nothing pending — the state at launch, and after a check that found no newer build.
    public static let none = UpdateAvailability(pendingVersion: nil, isAvailable: false)

    /// An update is waiting. A blank or whitespace-only version is normalised to `nil` so the
    /// tooltip falls back rather than rendering "Dirnex  is available".
    public static func available(version: String?) -> UpdateAvailability {
        let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
        return UpdateAvailability(pendingVersion: normalized, isAvailable: true)
    }

    /// The state after the user answered Sparkle's dialog.
    ///
    /// `dismiss` is the case the indicator exists for: the user closed the window without deciding,
    /// the update is still there, and Sparkle will not mention it again until its next scheduled
    /// check — so the button keeps standing. `skip` is an explicit "not this version", and `install`
    /// means the app is on its way to relaunching as that version; neither should leave a badge
    /// behind, so both reset.
    public func afterUserChoice(_ choice: UpdateChoice) -> UpdateAvailability {
        switch choice {
        case .dismiss: self
        case .install, .skip: .none
        }
    }

    // The indicator's *tooltip* lives in the app (`BrowserWindowController+Updates`), not here.
    // This type owns the state — is something pending, and which version — and the words that
    // render it are the app's, the same split `SyncBadgeStyle` and `GitStatusStyle` already draw
    // ("the core picks the state; this picks the pixels and the words"). Composed here it was a
    // bare literal reached through a variable: permanently on screen in the titlebar, and English
    // in a fully translated UI (PLAN.md §M12 Slice 11).
}
