import Foundation

/// The change notifications ``AppPreferences`` posts, one per preference a live window has to follow.
///
/// Moved out of `AppPreferences.swift` when Show Icon Previews took it past SwiftLint's file ceiling
/// (2026-11-11). Every one of them is a constant, which an extension can hold and the stored
/// preferences cannot, so this is the seam that frees the room without parting a preference from
/// its default and the reason for it. Each property's `didSet` names the one it posts.
extension AppPreferences {
    /// Posted (on the main actor) whenever `showHidden` flips, so every open pane can apply the
    /// new value to its tabs and re-render. `object` is the `AppPreferences` that changed.
    static let showHiddenDidChange = Notification.Name("Dirnex.showHiddenDidChange")

    /// Posted (on the main actor) when `showTags` flips, so every open pane installs or removes the
    /// column live. `object` is the `AppPreferences` that changed.
    static let showTagsDidChange = Notification.Name("Dirnex.showTagsDidChange")

    /// Posted (on the main actor) when `showSyncStatus` flips, so every open pane picks the badges
    /// up or drops them live. `object` is the `AppPreferences` that changed.
    static let showSyncStatusDidChange = Notification.Name("Dirnex.showSyncStatusDidChange")

    /// Posted (on the main actor) when `showIconPreviews` flips, so every open pane redraws the icons
    /// of the rows on screen. `object` is the `AppPreferences` that changed.
    static let showIconPreviewsDidChange = Notification.Name("Dirnex.showIconPreviewsDidChange")

    /// Posted (on the main actor) when `showFunctionBar` flips, so every open window installs or
    /// collapses its bar live. `object` is the `AppPreferences` that changed.
    static let showFunctionBarDidChange = Notification.Name("Dirnex.showFunctionBarDidChange")

    /// Posted (on the main actor) when `rowDensity` changes, so every open pane re-sizes its rows
    /// and repaints. `object` is the `AppPreferences` that changed.
    static let rowDensityDidChange = Notification.Name("Dirnex.rowDensityDidChange")

    /// Posted (on the main actor) when `sizeVizDisplayMode` changes, so every open pane repaints
    /// its size-bar column. `object` is the `AppPreferences` that changed.
    static let sizeVizDisplayModeDidChange = Notification.Name("Dirnex.sizeVizDisplayModeDidChange")

    /// Posted (on the main actor) when `quickViewJavaScriptEnabled` flips, so every open Quick View
    /// reloads the page it is showing. `object` is the `AppPreferences` that changed.
    static let quickViewJavaScriptDidChange = Notification.Name(
        "Dirnex.quickViewJavaScriptDidChange"
    )

    /// Posted (on the main actor) when `remoteRefreshFloor` changes, so every open remote pane
    /// re-arms — turning polling off has to stop the pane the user is looking at, not the one they
    /// see after the next navigation.
    static let remoteRefreshFloorDidChange = Notification.Name(
        "Dirnex.remoteRefreshFloorDidChange"
    )

    /// Posted (on the main actor) when `quickViewFetchLimit` changes, so an open Quick View
    /// re-weighs the row it is showing — raising the limit has to resolve the card the user is
    /// looking at, not the one they see after the next cursor step.
    static let quickViewFetchLimitDidChange = Notification.Name(
        "Dirnex.quickViewFetchLimitDidChange"
    )

    /// Posted (on the main actor) when `showVaultsInFinder` flips, so the vaults that are unlocked
    /// right now are remounted to match. `object` is the `AppPreferences` that changed.
    static let showVaultsInFinderDidChange = Notification.Name(
        "Dirnex.showVaultsInFinderDidChange"
    )
}
