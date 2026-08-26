import DirnexCore
import SwiftUI

/// Panels ▸ how often a pane on a connected server re-lists it by itself
/// (docs/LOCATION-SUPPORT.md ▸ "No live refresh on a server").
///
/// Its own file for the reason `QuickViewFetchLimitSection` has one: the Panels tab is a list of
/// one-line toggles and pickers, and this is a *number the user types*, with a range, a unit and a
/// zero that means something.
///
/// **A typed field rather than a menu of intervals**, and it is the same argument as the fetch
/// limit's: the right value is a fact about the user's own account — somebody sharing a bucket with
/// a build server wants fifteen seconds, somebody on a metered link wants none of it — and a preset
/// list would make them pick the nearest value that is wrong.
///
/// **Only the floor is here, and that is the design rather than a simplification.** How often a
/// pane *actually* re-lists is derived from what the previous refresh cost
/// (``RemoteRefreshPolicy``), so a folder that turns out to be expensive backs off on its own and
/// there is no second number for the user to keep consistent with this one.
struct RemoteRefreshSection: View {
    @ObservedObject var preferences: AppPreferences

    /// The band, in the seconds the field edits. Read from the policy rather than restated, so the
    /// control cannot offer a value the clamp will silently take back.
    private var secondsRange: ClosedRange<Int> {
        let range = RemoteRefreshPolicy.floorRange
        return Int(range.lowerBound)...Int(range.upperBound)
    }

    var body: some View {
        Section {
            HStack {
                // The unit rides *inside* the label rather than sitting as its own `Text` after the
                // field: a caption split across two views is a sentence whose word order a
                // translation cannot change (docs/NOTES.md ▸ Localization).
                Text("Check servers for changes every (seconds)")
                Spacer(minLength: 12)
                TextField("", value: $preferences.remoteRefreshFloorSeconds, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                Stepper(
                    "",
                    value: $preferences.remoteRefreshFloorSeconds,
                    in: secondsRange,
                    step: 5
                )
                .labelsHidden()
            }
        } footer: {
            Text(
                """
                No server can tell Dirnex that somebody else added a file, so a pane showing one \
                asks again on a timer — but only while you can actually see it, and never oftener \
                than this. A folder that turns out to be slow or expensive to list is then asked \
                less often still, so a huge one costs about as little as a small one. Set it to 0 \
                to never contact a server unasked. Files on this Mac are never affected: they are \
                watched exactly, and for free.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
