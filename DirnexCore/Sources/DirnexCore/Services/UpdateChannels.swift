import Foundation

/// The Sparkle update-channel policy (PLAN.md §M7 "Beta + stable update channels"). Dirnex serves
/// **one** appcast that carries both a stable and a beta item: the beta item is tagged
/// `<sparkle:channel>beta</sparkle:channel>`, the stable item is untagged. Untagged is Sparkle's
/// default channel, which every install always sees; the beta channel is opt-in.
///
/// This namespace holds the single runtime decision that logic — rather than the release pipeline —
/// needs: which extra channels an install is allowed to look in, given the user's opt-in. Kept in
/// `DirnexCore` (data, not AppKit) so it is unit-tested and the app's `SPUUpdaterDelegate` is a
/// one-line call, not a place a bug can hide. A caseless enum used as a namespace, exactly like
/// `FunctionBar`.
public enum UpdateChannels {
    /// The Sparkle channel identifier for opt-in pre-release builds. The single source of truth for
    /// the literal the app opts into here and the release pipeline stamps onto each beta appcast
    /// item — the two must be the same token or a beta build would be published to a channel no
    /// updater ever asks for. A test pins the value so the pair can't drift silently.
    public static let beta = "beta"

    /// The set of non-default channels the updater is allowed to find updates in, given the user's
    /// opt-in. Off (the default) → `[]`, which Sparkle reads as "only the default channel", so an
    /// install is offered untagged stable items alone. On → `["beta"]`, so beta items become
    /// eligible too — and because Sparkle still ranks every candidate by `CFBundleVersion` (the
    /// GitHub run number here, so globally monotonic across both channels), a newer stable release
    /// outranks a running beta and the tester rolls onto it automatically. That automatic
    /// beta→stable graduation is the whole reason for one appcast over two separate feeds.
    public static func allowed(receiveBetaUpdates: Bool) -> Set<String> {
        receiveBetaUpdates ? [beta] : []
    }
}
