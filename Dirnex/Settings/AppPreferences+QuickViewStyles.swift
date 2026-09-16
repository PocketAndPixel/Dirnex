import Foundation

/// The remembered Quick View style for each family of dual-style file — split out of `AppPreferences`
/// when JSON became the third family and the file reached SwiftLint's length ceiling (2026-09-15). The
/// preferences themselves stay there, since an extension cannot hold a stored property.
extension AppPreferences {
    /// Posted (on the main actor) when any of the remembered Quick View styles changes, so every open
    /// Quick View re-delivers its current file in the new style. `object` is the `AppPreferences` that
    /// changed. Here rather than beside the preferences for the file-length reason above.
    static let quickViewRenderStyleDidChange = Notification.Name(
        "Dirnex.quickViewRenderStyleDidChange"
    )

    /// The remembered style for a family of dual-style file.
    func quickViewRenderStyle(for kind: QuickViewDualStyleKind) -> QuickViewRenderStyle {
        switch kind {
        case .page: quickViewRenderStyle
        case .table: quickViewTableStyle
        case .json: quickViewJSONStyle
        case .xml: quickViewXMLStyle
        }
    }

    func setQuickViewRenderStyle(_ style: QuickViewRenderStyle, for kind: QuickViewDualStyleKind) {
        switch kind {
        case .page: quickViewRenderStyle = style
        case .table: quickViewTableStyle = style
        case .json: quickViewJSONStyle = style
        case .xml: quickViewXMLStyle = style
        }
    }
}
