import Combine
import Foundation

/// The app-wide toggles the Settings window's General / Panels / Operations tabs edit
/// (PLAN.md §M3 "Settings window (SwiftUI): general, panels, operations, shortcuts"). Each is
/// backed by a `UserDefaults` key and read at its single point of use; every default preserves
/// the app's pre-Settings behavior, so an untouched install behaves exactly as before.
///
/// One shared, observable instance: the Settings UI binds to it, and the browser code reads
/// `AppPreferences.shared` when it needs a value (creating a tab, deleting to Trash, restoring
/// a session). Boring `UserDefaults` persistence, like the rest of the app's config.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private let defaults: UserDefaults

    /// General ▸ reopen the previous session's tabs at launch (default on — the existing
    /// behavior). Off starts every window fresh at Home.
    @Published var restoreSession: Bool {
        didSet { defaults.set(restoreSession, forKey: Keys.restoreSession) }
    }

    /// Panels ▸ show hidden (dot) files (default off — Finder's behavior). This is a single
    /// app-wide toggle, not a per-tab one: every pane and tab reflects it. Changing it posts
    /// `showHiddenDidChange` so the open panes re-filter live, and the Settings toggle, the
    /// header button, and ⇧⌘. all drive this one value.
    @Published var showHidden: Bool {
        didSet {
            guard showHidden != oldValue else { return }
            defaults.set(showHidden, forKey: Keys.showHidden)
            NotificationCenter.default.post(name: Self.showHiddenDidChange, object: self)
        }
    }

    /// Posted (on the main actor) whenever `showHidden` flips, so every open pane can apply the
    /// new value to its tabs and re-render. `object` is the `AppPreferences` that changed.
    static let showHiddenDidChange = Notification.Name("Dirnex.showHiddenDidChange")

    /// Flip the app-wide show-hidden state. The shared entry point for the header button, the
    /// ⇧⌘. shortcut, and the palette/menu command — all of which want the same one-line effect.
    func toggleShowHidden() {
        showHidden.toggle()
    }

    /// Panels ▸ show Finder tags as dots at the right edge of each name, where Finder puts them
    /// (PLAN.md §M6 "Finder tags: column…"). Default **on**: someone who tags files sees them
    /// without having to find a setting first, and someone who doesn't pays nothing for it — an
    /// untagged row draws no dots and gives its name the full width.
    @Published var showTags: Bool {
        didSet {
            guard showTags != oldValue else { return }
            defaults.set(showTags, forKey: Keys.showTags)
            NotificationCenter.default.post(name: Self.showTagsDidChange, object: self)
        }
    }

    /// Posted (on the main actor) when `showTags` flips, so every open pane installs or removes the
    /// column live. `object` is the `AppPreferences` that changed.
    static let showTagsDidChange = Notification.Name("Dirnex.showTagsDidChange")

    /// Flip the app-wide tags-column state — the shared entry point for the View menu item, the
    /// palette command, and the Settings toggle.
    func toggleShowTags() {
        showTags.toggle()
    }

    /// Panels ▸ show each file's cloud sync state as a badge at the right edge of its name, where
    /// Finder puts it (PLAN.md §M6 "iCloud/provider sync status"). Default **on**, and it can afford
    /// to be: a folder that isn't a cloud folder is recognised in a single read and never scanned,
    /// so someone with no provider pays one attribute read per folder visit and sees nothing.
    @Published var showSyncStatus: Bool {
        didSet {
            guard showSyncStatus != oldValue else { return }
            defaults.set(showSyncStatus, forKey: Keys.showSyncStatus)
            NotificationCenter.default.post(name: Self.showSyncStatusDidChange, object: self)
        }
    }

    /// Posted (on the main actor) when `showSyncStatus` flips, so every open pane picks the badges
    /// up or drops them live. `object` is the `AppPreferences` that changed.
    static let showSyncStatusDidChange = Notification.Name("Dirnex.showSyncStatusDidChange")

    /// Flip the app-wide sync-badge state — the shared entry point for the View menu item, the
    /// palette command, and the Settings toggle.
    func toggleShowSyncStatus() {
        showSyncStatus.toggle()
    }

    /// View ▸ show the Total-Commander-style function-key bar along the window bottom (PLAN.md
    /// §M6). Default **on**: the bar is a signature discoverability win — it puts Copy/Move/
    /// NewFolder/Delete on labelled buttons a new user can find without the manual, the exact
    /// "fix TC's adoption problem" goal — and someone who works entirely by keyboard can turn it
    /// off. App-wide, not per-window, like the tags column: every window shows or hides it
    /// together.
    @Published var showFunctionBar: Bool {
        didSet {
            guard showFunctionBar != oldValue else { return }
            defaults.set(showFunctionBar, forKey: Keys.showFunctionBar)
            NotificationCenter.default.post(name: Self.showFunctionBarDidChange, object: self)
        }
    }

    /// Posted (on the main actor) when `showFunctionBar` flips, so every open window installs or
    /// collapses its bar live. `object` is the `AppPreferences` that changed.
    static let showFunctionBarDidChange = Notification.Name("Dirnex.showFunctionBarDidChange")

    /// Flip the app-wide function-bar state — the shared entry point for the View menu item, the
    /// palette command, and the Settings toggle.
    func toggleShowFunctionBar() {
        showFunctionBar.toggle()
    }

    /// Operations ▸ ask for confirmation before moving items to the Trash (default off —
    /// Trash is recoverable, matching Finder). Permanent delete always confirms regardless.
    @Published var confirmTrash: Bool {
        didSet { defaults.set(confirmTrash, forKey: Keys.confirmTrash) }
    }

    /// Whether the Full Disk Access onboarding prompt has been shown once already (PLAN.md §M7).
    /// Not a user-facing setting — a one-shot latch so a fresh install is offered the grant at
    /// first launch, but is never nagged on every subsequent one. Set the moment the prompt is
    /// shown (or, for the on-demand menu command, whenever the user opens it). Default off, so a
    /// brand-new install prompts; the on-demand "Full Disk Access…" command re-opens it anytime.
    @Published var hasSeenFullDiskAccessOnboarding: Bool {
        didSet {
            defaults.set(
                hasSeenFullDiskAccessOnboarding,
                forKey: Keys.hasSeenFullDiskAccessOnboarding
            )
        }
    }

    /// Whether iCloud Drive has already offered the Full Disk Access grant (PLAN.md §M9). A latch of
    /// its own rather than the one above, because that one is set at first launch and would swallow
    /// this offer entirely — and the two answer different questions: "has this Mac been told what
    /// the grant is for" versus "has it been told what it costs *here*", which is the per-app
    /// document folders quietly missing from iCloud Drive. Offered once, then never again; the
    /// listing goes on working without the grant, one section short.
    @Published var hasOfferedFullDiskAccessForICloud: Bool {
        didSet {
            defaults.set(
                hasOfferedFullDiskAccessForICloud,
                forKey: Keys.hasOfferedFullDiskAccessForICloud
            )
        }
    }

    /// Whether the first-run tour has been shown once already (PLAN.md §M7 "First-run tour"). Not a
    /// user-facing setting — a one-shot latch, the twin of `hasSeenFullDiskAccessOnboarding`, so a
    /// fresh install is walked through the tour at first launch but never again. Set the moment the
    /// tour is presented (launch or on-demand); the "Welcome to Dirnex…" menu/palette command
    /// reopens it anytime. Default off, so a brand-new install sees it.
    @Published var hasSeenFirstRunTour: Bool {
        didSet { defaults.set(hasSeenFirstRunTour, forKey: Keys.hasSeenFirstRunTour) }
    }

    /// Panels ▸ move focus to a folder opened from search results (default off — stay on the
    /// results so you can keep opening hits). Opening a folder from a `.search` results tab never
    /// replaces the results in place: it lands as a new tab in the other pane (or, when there's no
    /// other pane, a new tab beside the results here). When off, that new tab opens without
    /// stealing focus/selection from the results; when on, focus follows into the opened folder.
    @Published var focusOpenedSearchDirectory: Bool {
        didSet { defaults.set(focusOpenedSearchDirectory, forKey: Keys.focusOpenedSearchDirectory) }
    }

    /// Operations ▸ which external tool "Compare By Contents" hands its two files to, as an
    /// `ExternalDiffTool.identifier`. The empty string means **automatic** — the default — and
    /// leaves the choice to `ExternalDiffTool.preferred`'s install order (Kaleidoscope, BBEdit,
    /// FileMerge). A named tool wins whenever it is still installed; uninstall it and the
    /// automatic order quietly takes over again rather than the command breaking.
    @Published var diffToolIdentifier: String {
        didSet { defaults.set(diffToolIdentifier, forKey: Keys.diffToolIdentifier) }
    }

    /// General ▸ also offer pre-release (beta) builds when checking for updates (PLAN.md §M7
    /// "Beta + stable update channels"). Default **off**: a normal install only ever sees stable
    /// releases. When on, Sparkle's `allowedChannels(for:)` — implemented on `AppUpdater` — adds
    /// the `beta` channel, so newer beta builds are offered too; a stable release still supersedes
    /// a running beta once it outranks it, rolling the tester back onto the stable line
    /// automatically. Read live on each update check via `receiveBetaUpdatesValue`, so toggling it
    /// takes effect without a relaunch.
    @Published var receiveBetaUpdates: Bool {
        didSet { defaults.set(receiveBetaUpdates, forKey: Keys.receiveBetaUpdates) }
    }

    /// A thread-safe read of the beta-updates opt-in straight from `UserDefaults`, for the one
    /// caller that runs off the main actor: Sparkle's `allowedChannels(for:)` delegate hook, which
    /// it invokes synchronously inside an update check. `UserDefaults` is itself thread-safe, so
    /// this reads the same key the `@MainActor` `receiveBetaUpdates` property writes without hopping
    /// actors, and re-reads every call so a Settings toggle is picked up on the next check.
    nonisolated static func receiveBetaUpdatesValue(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Keys.receiveBetaUpdates)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreSession = defaults.object(forKey: Keys.restoreSession) as? Bool ?? true
        showHidden = defaults.bool(forKey: Keys.showHidden)
        // Defaults on, so `object(forKey:)` rather than `bool(forKey:)` — the latter answers
        // `false` for a key that was never written, which would ship the feature turned off.
        showTags = defaults.object(forKey: Keys.showTags) as? Bool ?? true
        // Defaults on, like `showTags`, and for the same `object(forKey:)` reason.
        showSyncStatus = defaults.object(forKey: Keys.showSyncStatus) as? Bool ?? true
        // Defaults on, like `showTags`: `object(forKey:)`, not `bool(forKey:)` (which answers
        // `false` for a never-written key and would ship the bar hidden).
        showFunctionBar = defaults.object(forKey: Keys.showFunctionBar) as? Bool ?? true
        confirmTrash = defaults.bool(forKey: Keys.confirmTrash)
        // Empty (never written) = automatic, so a fresh install keeps the install-order default.
        diffToolIdentifier = defaults.string(forKey: Keys.diffToolIdentifier) ?? ""
        focusOpenedSearchDirectory = defaults.bool(forKey: Keys.focusOpenedSearchDirectory)
        // Defaults off — a fresh install rides the stable channel until the user opts in.
        receiveBetaUpdates = defaults.bool(forKey: Keys.receiveBetaUpdates)
        hasSeenFullDiskAccessOnboarding = defaults.bool(forKey: Keys.hasSeenFullDiskAccessOnboarding)
        hasOfferedFullDiskAccessForICloud = defaults.bool(
            forKey: Keys.hasOfferedFullDiskAccessForICloud
        )
        hasSeenFirstRunTour = defaults.bool(forKey: Keys.hasSeenFirstRunTour)
    }

    private enum Keys {
        static let restoreSession = "Dirnex.pref.restoreSession"
        static let showHidden = "Dirnex.pref.showHidden"
        static let showTags = "Dirnex.pref.showTags"
        static let showSyncStatus = "Dirnex.pref.showSyncStatus"
        static let showFunctionBar = "Dirnex.pref.showFunctionBar"
        static let confirmTrash = "Dirnex.pref.confirmTrash"
        static let diffToolIdentifier = "Dirnex.pref.diffToolIdentifier"
        static let focusOpenedSearchDirectory = "Dirnex.pref.focusOpenedSearchDirectory"
        static let receiveBetaUpdates = "Dirnex.pref.receiveBetaUpdates"
        static let hasSeenFullDiskAccessOnboarding = "Dirnex.pref.hasSeenFullDiskAccessOnboarding"
        static let hasOfferedFullDiskAccessForICloud = "Dirnex.pref.hasOfferedFullDiskAccessForICloud"
        static let hasSeenFirstRunTour = "Dirnex.pref.hasSeenFirstRunTour"
    }
}
