import DirnexCore
import SwiftUI

/// The General tab's language picker, plus the relaunch that applies it.
///
/// Kept in its own file rather than inline in `GeneralSettingsView` because the relaunch notice is
/// stateful in a way the other preferences are not: every toggle there takes effect the moment it
/// flips, and this one cannot (see `LanguageSettings` for why the mechanism is `AppleLanguages` and
/// a relaunch rather than live string swapping).
struct LanguageSettingsSection: View {
    @ObservedObject var settings: LanguageSettings

    var body: some View {
        Section {
            // Each language in its own language, the way macOS lists them: a user who has landed in
            // a UI they cannot read must still be able to find the way back.
            SettingsPopUp(
                "Language",
                selection: selection,
                items: [.choice(String(localized: "Same as System"), nil), .separator]
                    + AppLanguages.all.map { .choice($0.endonym, $0.code) }
            )

            if settings.needsRelaunch {
                HStack {
                    Text(
                        "Dirnex needs to restart to switch to \(settings.resolvedLanguage.endonym)."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    SettingsButton("Relaunch") { settings.relaunch() }
                }
            }
        } footer: {
            Text("“Same as System” follows your macOS language and falls back to English.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The picker's selection as an optional language code — `nil` for "Same as System".
    ///
    /// A `LanguagePreference` binding directly would need `AppLanguage` to be the tag type, and
    /// SwiftUI compares tags by value: a `nil` tag is the one shape that expresses "no pin" without
    /// inventing a sentinel language that would then have to be filtered out of `AppLanguages.all`.
    private var selection: Binding<String?> {
        Binding(
            get: {
                switch settings.preference {
                case .system: return nil
                case let .explicit(language): return language.code
                }
            },
            set: { code in
                guard let code, let language = AppLanguages.language(for: code) else {
                    settings.preference = .system
                    return
                }
                settings.preference = .explicit(language)
            }
        )
    }
}
