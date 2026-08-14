import DirnexCore
import SwiftUI

/// Panels ▸ how large a file Quick View may pull down from a server on its own (PLAN.md §M21
/// Slice 10).
///
/// Its own file for the reason `PaletteSettingsSection` and `FileColorRulesSection` are: the Panels
/// tab is a list of one-line toggles and this is the only row that is a *number the user types*, with
/// a range, a unit and a zero that means something.
///
/// **A typed field rather than a menu of sizes**, which is the whole point of the setting: the right
/// value is a fact about the user's own files — 300 MB photographs are the case that asked for this —
/// and a preset list would make them pick the nearest size that is wrong. The stepper is there for
/// nudging; the field is there because somebody knows their number.
struct QuickViewFetchLimitSection: View {
    @ObservedObject var preferences: AppPreferences

    /// The band, in the megabytes the field edits. Read from the policy rather than restated, so the
    /// control cannot offer a value the clamp will silently take back.
    private var megabyteRange: ClosedRange<Int> {
        let range = RemoteFetchPolicy.previewLimitRange
        return Int(range.lowerBound / 1_000_000)...Int(range.upperBound / 1_000_000)
    }

    var body: some View {
        Section {
            HStack {
                // The unit rides *inside* the label rather than sitting as its own `Text` after the
                // field: a caption split across two views is a sentence whose word order a
                // translation cannot change (docs/NOTES.md ▸ Localization).
                Text("Download previews from servers up to (MB)")
                Spacer(minLength: 12)
                TextField("", value: $preferences.quickViewFetchLimitMegabytes, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                Stepper(
                    "",
                    value: $preferences.quickViewFetchLimitMegabytes,
                    in: megabyteRange,
                    step: 10
                )
                .labelsHidden()
            }
        } footer: {
            Text(
                """
                How much Quick View may download by itself as the cursor moves over a file on a \
                server. Anything larger still previews — the card names the file and its size and \
                waits for you to press Download, or ⌘Y. Set it to 0 to download nothing unasked. \
                Files on this Mac are never affected.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
