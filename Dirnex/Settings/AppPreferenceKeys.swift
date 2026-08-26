import Foundation

extension AppPreferences {
    /// The `UserDefaults` key for every preference above.
    ///
    /// Its own file since the remote-refresh floor took `AppPreferences` past SwiftLint's ceiling,
    /// and a good seam regardless: these are the app's **on-disk vocabulary**, which outlives any
    /// property that reads them — a key renamed here silently discards what a user already set, so
    /// it is worth being a list somebody can read in one screen. `internal` rather than `private`
    /// only because Swift's `private` does not cross files (docs/NOTES.md ▸ Lint ceilings).
    enum Keys {
        static let restoreSession = "Dirnex.pref.restoreSession"
        static let showHidden = "Dirnex.pref.showHidden"
        static let showTags = "Dirnex.pref.showTags"
        static let showSyncStatus = "Dirnex.pref.showSyncStatus"
        static let showFunctionBar = "Dirnex.pref.showFunctionBar"
        static let rowDensity = "Dirnex.pref.rowDensity"
        static let sizeVizDisplayMode = "Dirnex.pref.sizeVizDisplayMode"
        static let quickViewRenderStyle = "Dirnex.pref.quickViewRenderStyle"
        static let quickViewJavaScriptEnabled = "Dirnex.pref.quickViewJavaScriptEnabled"
        static let quickViewFetchLimit = "Dirnex.pref.quickViewFetchLimit"
        static let remoteRefreshFloor = "Dirnex.pref.remoteRefreshFloor"
        static let accentColorHex = "Dirnex.pref.accentColorHex"
        static let cursorColorHex = "Dirnex.pref.cursorColorHex"
        static let markColorHex = "Dirnex.pref.markColorHex"
        static let confirmTrash = "Dirnex.pref.confirmTrash"
        static let diffToolIdentifier = "Dirnex.pref.diffToolIdentifier"
        static let textEditorIdentifier = "Dirnex.pref.textEditorIdentifier"
        static let focusOpenedSearchDirectory = "Dirnex.pref.focusOpenedSearchDirectory"
        static let receiveBetaUpdates = "Dirnex.pref.receiveBetaUpdates"
        static let hasSeenFullDiskAccessOnboarding = "Dirnex.pref.hasSeenFullDiskAccessOnboarding"
        static let hasOfferedFullDiskAccessForICloud = "Dirnex.pref.hasOfferedFullDiskAccessForICloud"
        static let hasReadICloudAppLibraries = "Dirnex.pref.hasReadICloudAppLibraries"
        static let hasSeenFirstRunTour = "Dirnex.pref.hasSeenFirstRunTour"
    }
}
