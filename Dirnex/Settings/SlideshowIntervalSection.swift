import DirnexCore
import SwiftUI

/// Panels ▸ how long a Quick View slideshow shows each image (PLAN.md §M39 ▸ Slice 16).
///
/// Its own file for the reason `QuickViewFetchLimitSection` has one: a number the user types, with a
/// range and a unit, among a list of one-line toggles. The same shape as that row, a field for
/// somebody who knows their number and a stepper for nudging, so the two read as one family.
struct SlideshowIntervalSection: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Section {
            HStack {
                // The unit inside the label, for the word order a translation needs (docs/NOTES.md
                // ▸ Localization), as the fetch limit's "(MB)" is.
                Text("Show each slideshow picture for (seconds)")
                Spacer(minLength: 12)
                TextField("", value: $preferences.slideshowInterval, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                Stepper("", value: $preferences.slideshowInterval, in: Slideshow.intervalRange)
                    .labelsHidden()
            }
        } footer: {
            Text(
                """
                View ▸ Slideshow (⇧⌘S) steps through the pictures in the active pane, looping until \
                you stop it. The time starts once a picture is on screen, so a large photo or one \
                downloading from a server still gets all of it.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
