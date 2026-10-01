import Foundation

/// Which kind of update check is asking. A stand-in for Sparkle's `SPUUpdateCheck`, so the rule
/// below stays in the core; the app maps one onto the other in a single `switch`.
public enum UpdateCheckKind: Sendable, Equatable, CaseIterable {
    /// Check for Updates…, the palette command, or the titlebar indicator. The user is there.
    case userInitiated
    /// Sparkle's own scheduled check. It can show its dialog uninvited, or download the update and
    /// install it when Dirnex quits.
    case background
    /// Dirnex's own probe (`checkForUpdateInformation`). It installs nothing and shows nothing; it
    /// only lights the titlebar indicator.
    case probe
}

/// Whether Sparkle may go on with an update the key doesn't cover (PLAN.md §M29 "Updates for a key
/// whose period has ended").
///
/// The app asks this from Sparkle's `updater(_:shouldProceedWithUpdate:updateCheck:)`, which every
/// check passes through before it shows or downloads anything. With a notice due
/// (``UpdateCoverageNotice``):
///
/// - a **background** check is held back silently, so Sparkle never installs such a version on its
///   own;
/// - a **user-initiated** check is held back too, and the notice is shown once the check has ended;
/// - the **probe** goes on, because it installs nothing, and the indicator should still say an
///   update exists.
///
/// **Update Anyway** allows that one build for the rest of the run. Every check then goes on with
/// it, including a background one, since the user has already said yes to it. It isn't saved: after
/// a relaunch the notice is shown again, and it is still true.
public struct UpdateCoverageGate: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        /// Let Sparkle go on as it would without a license.
        case proceed
        /// Stop this check, and show nothing.
        case holdBack
        /// Stop this check, and show the notice once it has ended.
        case notify(UpdateCoverageNotice)
    }

    /// The builds (`CFBundleVersion`, the appcast's `sparkle:version`) the user chose **Update
    /// Anyway** for. A build number rather than the version shown, because it names exactly one
    /// release.
    public private(set) var allowedBuilds: Set<String> = []

    public init() {}

    /// What to do with the update `build`, for which `notice` is the notice due (`nil` when the key
    /// covers it, or when there's no key).
    public func decision(
        notice: UpdateCoverageNotice?,
        build: String,
        check: UpdateCheckKind
    ) -> Decision {
        guard let notice, !allowedBuilds.contains(build) else { return .proceed }
        return switch check {
        case .probe: .proceed
        case .background: .holdBack
        case .userInitiated: .notify(notice)
        }
    }

    /// The user chose **Update Anyway** for `build`.
    public mutating func allow(build: String) {
        allowedBuilds.insert(build)
    }
}
