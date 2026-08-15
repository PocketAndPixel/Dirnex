import DirnexCore
import Foundation

/// The fixed menus behind the Find Files dialog's Kind, Size and Modified popups — each a list of
/// (title, value) pairs whose first entry is the no-filter option.
///
/// Split out of `SearchController` when M22 gave that class per-scope layout to do and pushed it
/// past SwiftLint's `type_body_length`, along the seam the house rule names: by concept rather than
/// by shaving lines. These are the dialog's *vocabulary* — the sizes worth offering, the windows
/// worth calling recent — and they are the same whatever the pane is showing, where everything left
/// in the controller now varies with the place being searched.
///
/// Each is resolved once at first use rather than rebuilt per dialog, and the titles come from
/// `LocalizedCatalog` for the two enums the core owns, so the popup and the results tab's own label
/// cannot drift apart.
enum SearchFilterOptions {
    static let kinds: [(title: String, kind: SearchKind?)] =
        [
            (
                String(
                    localized: "Any kind",
                    comment: "Find Files: the Kind popup's no-filter option."
                ),
                nil
            )
        ]
        + SearchKind.allCases.map { (LocalizedCatalog.title(for: $0), $0) }

    static let sizes: [(title: String, bytes: Int64?)] = [
        (
            String(localized: "Any size", comment: "Find Files: the Size popup's no-filter option."),
            nil
        ),
        (
            String(
                localized: "Larger than 1 MB",
                comment: "Find Files: a minimum-size filter option."
            ),
            1_048_576
        ),
        (
            String(
                localized: "Larger than 10 MB",
                comment: "Find Files: a minimum-size filter option."
            ),
            10_485_760
        ),
        (
            String(
                localized: "Larger than 100 MB",
                comment: "Find Files: a minimum-size filter option."
            ),
            104_857_600
        ),
        (
            String(
                localized: "Larger than 1 GB",
                comment: "Find Files: a minimum-size filter option."
            ),
            1_073_741_824
        )
    ]

    static let ages: [(title: String, age: SearchAge?)] =
        [
            (
                String(
                    localized: "Any date",
                    comment: "Find Files: the Modified popup's no-filter option."
                ),
                nil
            )
        ]
        + SearchAge.allCases.map { (LocalizedCatalog.title(for: $0), $0) }
}
