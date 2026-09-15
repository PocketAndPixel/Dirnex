import Foundation

/// The remembered Quick View style for each family of dual-style file — split out of `AppPreferences`
/// when JSON became the third family and the file reached SwiftLint's length ceiling (2026-09-15). The
/// three preferences themselves stay there, since an extension cannot hold a stored property.
extension AppPreferences {
    /// The remembered style for a family of dual-style file.
    func quickViewRenderStyle(for kind: QuickViewDualStyleKind) -> QuickViewRenderStyle {
        switch kind {
        case .page: quickViewRenderStyle
        case .table: quickViewTableStyle
        case .json: quickViewJSONStyle
        }
    }

    func setQuickViewRenderStyle(_ style: QuickViewRenderStyle, for kind: QuickViewDualStyleKind) {
        switch kind {
        case .page: quickViewRenderStyle = style
        case .table: quickViewTableStyle = style
        case .json: quickViewJSONStyle = style
        }
    }
}
