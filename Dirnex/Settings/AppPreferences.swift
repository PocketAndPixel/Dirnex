import Combine
import DirnexCore
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

    /// `internal` rather than `private` only because Swift's `private` does not cross files and
    /// `AppPreferences+Palette` writes through it (docs/NOTES.md ▸ Lint ceilings and file splitting).
    let defaults: UserDefaults

    /// General ▸ reopen the previous session's tabs at launch (default on — the existing
    /// behavior). Off starts every window fresh at Home.
    @Published var restoreSession: Bool {
        didSet { defaults.set(restoreSession, forKey: Keys.restoreSession) }
    }

    /// View ▸ show hidden (dot) files (default off — Finder's behavior). This is a single
    /// app-wide toggle, not a per-tab one: every pane and tab reflects it. Changing it posts
    /// `showHiddenDidChange` so the open panes re-filter live, and the View menu item, the
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

    /// View ▸ show Finder tags as dots at the right edge of each name, where Finder puts them
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

    /// View ▸ show each file's cloud sync state as a badge at the right edge of its name, where
    /// Finder puts it (PLAN.md §M6 "iCloud/provider sync status"). Default **on**, and it can afford
    /// to be: a folder that isn't a cloud folder is recognized in a single read and never scanned,
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

    /// View ▸ show the Total-Commander-style function-key bar along the window bottom (PLAN.md
    /// §M6). Default **on**: the bar is a signature discoverability win — it puts Copy/Move/
    /// NewFolder/Delete on labeled buttons a new user can find without the manual, the exact
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

    /// Panels ▸ how tall each file row is drawn, and how big the icon in it (PLAN.md §M15). A
    /// single app-wide value like `showHidden`, not a per-tab one: it is a reading preference, not
    /// a question you ask of one directory. Changing it posts `rowDensityDidChange` so every open
    /// pane re-renders live. Defaults to `.regular`, which is the 22 pt row the app hardcoded
    /// before this setting existed — an untouched install is unchanged.
    @Published var rowDensity: RowDensity {
        didSet {
            guard rowDensity != oldValue else { return }
            defaults.set(rowDensity.rawValue, forKey: Keys.rowDensity)
            NotificationCenter.default.post(name: Self.rowDensityDidChange, object: self)
        }
    }

    /// Posted (on the main actor) when `rowDensity` changes, so every open pane re-sizes its rows
    /// and repaints. `object` is the `AppPreferences` that changed.
    static let rowDensityDidChange = Notification.Name("Dirnex.rowDensityDidChange")

    /// Panels ▸ what the size-visualization column draws: the bar, the folder-share percentage, or
    /// both (PLAN.md §M15). A single app-wide value like `rowDensity`, not a per-tab one — it is a
    /// reading preference, not a question about one directory. Changing it posts
    /// `sizeVizDisplayModeDidChange` so every open pane showing bars repaints live. Defaults to
    /// `.bar`, the quiet chart on its own.
    @Published var sizeVizDisplayMode: SizeVizDisplayMode {
        didSet {
            guard sizeVizDisplayMode != oldValue else { return }
            defaults.set(sizeVizDisplayMode.rawValue, forKey: Keys.sizeVizDisplayMode)
            NotificationCenter.default.post(name: Self.sizeVizDisplayModeDidChange, object: self)
        }
    }

    /// Posted (on the main actor) when `sizeVizDisplayMode` changes, so every open pane repaints
    /// its size-bar column. `object` is the `AppPreferences` that changed.
    static let sizeVizDisplayModeDidChange = Notification.Name("Dirnex.sizeVizDisplayModeDidChange")

    /// How Quick View draws a file that can be shown two ways — its source, or the page it
    /// describes (PLAN.md §M16). Only HTML offers both today; every other file ignores it.
    ///
    /// App-wide like `rowDensity`, not per tab: it is a reading preference, not a question you ask
    /// of one directory — and a per-file choice would reset on every cursor step, which is the
    /// annoyance the two keys exist to remove. Changing it posts `quickViewRenderStyleDidChange` so
    /// every open preview re-renders the file it is already showing.
    @Published var quickViewRenderStyle: QuickViewRenderStyle {
        didSet {
            guard quickViewRenderStyle != oldValue else { return }
            defaults.set(quickViewRenderStyle.rawValue, forKey: Keys.quickViewRenderStyle)
            NotificationCenter.default.post(name: Self.quickViewRenderStyleDidChange, object: self)
        }
    }

    /// Posted (on the main actor) when `quickViewRenderStyle` changes, so every open Quick View
    /// re-delivers its current file in the new style. `object` is the `AppPreferences` that changed.
    static let quickViewRenderStyleDidChange = Notification.Name(
        "Dirnex.quickViewRenderStyleDidChange"
    )

    /// Panels ▸ whether a rendered HTML preview may run the page's own JavaScript (PLAN.md §M16).
    ///
    /// **Off** by default: a preview renders on every cursor step, so the file's code would run
    /// because the cursor passed over it, not because anybody opened it — and "run no code from a
    /// file I have not opened" is the answer that needs no argument. What the switch buys when it
    /// is on is a self-contained report rendering as itself instead of showing raw LaTeX, which is
    /// worth having and is one toggle away.
    ///
    /// The measured half is what makes turning it on defensible rather than reckless: the risk a
    /// previewed page carries is the *network*, and that is closed unconditionally by a content
    /// rule list nothing here can turn off (`QuickViewWebView`) — a script with no network cannot
    /// report what it saw. Changing it posts `quickViewJavaScriptDidChange` so an open preview
    /// re-renders under the new answer, and the full-size header says which answer is in force.
    @Published var quickViewJavaScriptEnabled: Bool {
        didSet {
            guard quickViewJavaScriptEnabled != oldValue else { return }
            defaults.set(quickViewJavaScriptEnabled, forKey: Keys.quickViewJavaScriptEnabled)
            NotificationCenter.default.post(name: Self.quickViewJavaScriptDidChange, object: self)
        }
    }

    /// Posted (on the main actor) when `quickViewJavaScriptEnabled` flips, so every open Quick View
    /// reloads the page it is showing. `object` is the `AppPreferences` that changed.
    static let quickViewJavaScriptDidChange = Notification.Name(
        "Dirnex.quickViewJavaScriptDidChange"
    )

    /// Panels ▸ how large a file Quick View may pull down from a server on its own, in **bytes**
    /// (PLAN.md §M21 Slice 10).
    ///
    /// The one number in `RemoteFetchPolicy`'s table the user owns, and the only one whose right
    /// value is a fact about *them* rather than about the gesture: somebody whose photographs run to
    /// 300 MB is asking a reasonable thing of a preview, and somebody on a metered link is right to
    /// want none of it. Below it the preview follows the cursor by itself; above it the placeholder
    /// card appears with the file's size and a Download button, and ⌘Y confirms before spending.
    /// **Zero is a setting** — never fetch unasked — and is exactly what Quick View did before this
    /// existed.
    ///
    /// Stored in bytes and edited in decimal megabytes, so what the field says is what the file list
    /// beside it says. Clamped on the way in *and* on the way out (`RemoteFetchPolicy` computes every
    /// threshold through its own clamp), because a defaults domain is hand-editable by design.
    @Published var quickViewFetchLimit: Int64 {
        didSet {
            let clamped = RemoteFetchPolicy.clampedPreviewLimit(quickViewFetchLimit)
            guard clamped == quickViewFetchLimit else {
                quickViewFetchLimit = clamped
                return
            }
            guard quickViewFetchLimit != oldValue else { return }
            defaults.set(quickViewFetchLimit, forKey: Keys.quickViewFetchLimit)
            NotificationCenter.default.post(name: Self.quickViewFetchLimitDidChange, object: self)
        }
    }

    /// Panels ▸ how long a pane on a connected server waits before re-listing it on its own
    /// (docs/LOCATION-SUPPORT.md ▸ "No live refresh on a server"), in seconds.
    ///
    /// **Zero is a setting** — never talk to my server unless I ask — and is exactly what every
    /// remote pane did before this existed. It is the honest answer on a metered link or a bill
    /// somebody watches, which is why the band starts there rather than at some small number.
    ///
    /// The floor is all the user owns: how often a pane *actually* re-lists is derived from what the
    /// previous refresh cost (``RemoteRefreshPolicy``), so a folder that turns out to be expensive
    /// backs off on its own and there is no second number to keep consistent with this one. Clamped
    /// on the way in *and* on the way out, because a defaults domain is hand-editable by design.
    @Published var remoteRefreshFloor: TimeInterval {
        didSet {
            let clamped = RemoteRefreshPolicy.clampedFloor(remoteRefreshFloor)
            guard clamped == remoteRefreshFloor else {
                remoteRefreshFloor = clamped
                return
            }
            guard remoteRefreshFloor != oldValue else { return }
            defaults.set(remoteRefreshFloor, forKey: Keys.remoteRefreshFloor)
            NotificationCenter.default.post(name: Self.remoteRefreshFloorDidChange, object: self)
        }
    }

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

    /// Panels ▸ the three colors the user owns (PLAN.md §M15 Slice 2), each as `#RRGGBB` or the
    /// empty string for **Follow System** — the default, so an untouched install renders exactly as
    /// it did before this setting existed and the default path stays AppKit's own drawing.
    ///
    /// Stored as hex strings rather than as archived `NSColor`s so the defaults domain stays
    /// readable and hand-editable (PLAN.md §2, "boring and debuggable"), and so the change guard is
    /// an exact string comparison rather than `NSColor`'s color-space-sensitive equality. What each
    /// one paints, and what "the system's own" resolves to, is `PanelPalette`'s.
    @Published var accentColorHex: String {
        didSet { paletteValueChanged(accentColorHex, oldValue, key: Keys.accentColorHex) }
    }

    @Published var cursorColorHex: String {
        didSet { paletteValueChanged(cursorColorHex, oldValue, key: Keys.cursorColorHex) }
    }

    @Published var markColorHex: String {
        didSet { paletteValueChanged(markColorHex, oldValue, key: Keys.markColorHex) }
    }

    /// Set while `resetPalette` writes all three, so the run posts one notification instead of up to
    /// three — each of which would drive a full re-render of every open pane. Stays in the class
    /// while the rest of the palette lives in `AppPreferences+Palette`, as stored properties must.
    var isResettingPalette = false

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

    /// Whether Dirnex has ever actually read the iCloud app containers (docs/NOTES.md ▸ iCloud
    /// Drive). Not a user-facing setting — the second half of the offer above, and the thing that
    /// tells "the user declined" apart from "it worked and has since broken".
    ///
    /// Set from a scan that came back with libraries, which is the only positive proof of the
    /// access available; spent by the rescue offer, so one loss buys one ask and declining it is
    /// respected. A grant that returns sets it again and re-arms the rescue for the next loss.
    /// `ICloudAccessOffer.decide` owns the rule.
    @Published var hasReadICloudAppLibraries: Bool {
        didSet {
            defaults.set(hasReadICloudAppLibraries, forKey: Keys.hasReadICloudAppLibraries)
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

    /// Operations ▸ which editor F4 "Edit" hands the cursor file to, as an
    /// `ExternalTextEditor.identifier`. The empty string means **automatic** — the default — which
    /// resolves to the system's own handler for plain text, so a user who never opens Settings gets
    /// what double-clicking a `.txt` already gives them. A named editor wins whenever it is still
    /// installed; uninstall it and automatic quietly takes over again rather than F4 breaking.
    @Published var textEditorIdentifier: String {
        didSet { defaults.set(textEditorIdentifier, forKey: Keys.textEditorIdentifier) }
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

    /// General ▸ let an unlocked vault's volume appear to the rest of the Mac: Finder's sidebar, the
    /// desktop, every other app's Open panel (PLAN.md §M19).
    ///
    /// **On** by default, and one app-wide answer rather than a flag on each vault. It was per-vault
    /// and off until 2026-09-02, on the argument that the two questions have different answers for
    /// the same person — a vault of scanned documents is one you want to attach a file from in Mail,
    /// while another should stay where you put it. What that cost was a setting living in one
    /// sidebar row's context menu, which is nowhere anybody looks, for the thing most people want
    /// most of the time. The default flip is the deliberate part of it: a vault is now published to
    /// the whole Mac while it is unlocked unless this is turned off, so *locking it* is what makes
    /// it private again rather than the attach flag.
    ///
    /// `-nobrowse` is still the whole mechanism
    /// (``DiskImageArguments/attach(atPath:showingInFinder:)``); this decides whether it goes on the
    /// command line. Changing it posts `showVaultsInFinderDidChange`, which `VaultVisibility` turns
    /// into a live remount of every vault that is open right now — a setting that only took effect
    /// at the next unlock would look like it did nothing at all.
    @Published var showVaultsInFinder: Bool {
        didSet {
            guard showVaultsInFinder != oldValue else { return }
            defaults.set(showVaultsInFinder, forKey: Keys.showVaultsInFinder)
            NotificationCenter.default.post(name: Self.showVaultsInFinderDidChange, object: self)
        }
    }

    /// Posted (on the main actor) when `showVaultsInFinder` flips, so the vaults that are unlocked
    /// right now are remounted to match. `object` is the `AppPreferences` that changed.
    static let showVaultsInFinderDidChange = Notification.Name(
        "Dirnex.showVaultsInFinderDidChange"
    )

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
        // Stored as the raw string and read back tolerantly: a value written by a newer build
        // (or a hand-edited defaults domain) falls back to the shipped default rather than
        // trapping, the same way `PersistedTab` reads its sort key.
        rowDensity = RowDensity(rawValue: defaults.string(forKey: Keys.rowDensity) ?? "") ?? .regular
        // Empty (never written) = the bar alone, and so is anything an older/newer build can't parse.
        sizeVizDisplayMode = SizeVizDisplayMode(
            rawValue: defaults.string(forKey: Keys.sizeVizDisplayMode) ?? ""
        ) ?? .bar
        // Defaults off (see the property), which is what `bool(forKey:)` already answers for a
        // never-written key.
        quickViewJavaScriptEnabled = defaults.bool(forKey: Keys.quickViewJavaScriptEnabled)
        // `object(forKey:)`, not `integer(forKey:)`: a missing key reads as **0** there, which is a
        // legitimate value here ("never fetch unasked") — so the cheap spelling would hand every
        // fresh install the one setting that turns the feature off, and read as it never working.
        quickViewFetchLimit = RemoteFetchPolicy.clampedPreviewLimit(
            (defaults.object(forKey: Keys.quickViewFetchLimit) as? NSNumber)?.int64Value
                ?? RemoteFetchPolicy.defaultPreviewLimit
        )
        // `object(forKey:)` for the same reason as the line above: a missing key reads as **0**
        // through `double(forKey:)`, and 0 is the one setting here that turns polling off — so the
        // cheap spelling would ship every fresh install with the feature disabled and no way to tell
        // that from a deliberate choice.
        remoteRefreshFloor = RemoteRefreshPolicy.clampedFloor(
            (defaults.object(forKey: Keys.remoteRefreshFloor) as? NSNumber)?.doubleValue
                ?? RemoteRefreshPolicy.defaultFloor
        )
        // Empty (never written) = the source, the shipped default, and so is anything an
        // older/newer build can't parse.
        quickViewRenderStyle = QuickViewRenderStyle(
            rawValue: defaults.string(forKey: Keys.quickViewRenderStyle) ?? ""
        ) ?? .default
        // Empty (never written) = Follow System, and so is anything `PanelPalette` can't parse.
        accentColorHex = defaults.string(forKey: Keys.accentColorHex) ?? ""
        cursorColorHex = defaults.string(forKey: Keys.cursorColorHex) ?? ""
        markColorHex = defaults.string(forKey: Keys.markColorHex) ?? ""
        confirmTrash = defaults.bool(forKey: Keys.confirmTrash)
        // Empty (never written) = automatic, so a fresh install keeps the install-order default.
        diffToolIdentifier = defaults.string(forKey: Keys.diffToolIdentifier) ?? ""
        // Empty (never written) = automatic, i.e. the system's own plain-text handler.
        textEditorIdentifier = defaults.string(forKey: Keys.textEditorIdentifier) ?? ""
        focusOpenedSearchDirectory = defaults.bool(forKey: Keys.focusOpenedSearchDirectory)
        // Defaults off — a fresh install rides the stable channel until the user opts in.
        receiveBetaUpdates = defaults.bool(forKey: Keys.receiveBetaUpdates)
        // Defaults on, like `showTags`: `object(forKey:)`, not `bool(forKey:)`, which answers
        // `false` for a never-written key and would ship every vault hidden while the property
        // above documents the opposite.
        showVaultsInFinder = defaults.object(forKey: Keys.showVaultsInFinder) as? Bool ?? true
        hasSeenFullDiskAccessOnboarding = defaults.bool(forKey: Keys.hasSeenFullDiskAccessOnboarding)
        hasOfferedFullDiskAccessForICloud = defaults.bool(
            forKey: Keys.hasOfferedFullDiskAccessForICloud
        )
        hasReadICloudAppLibraries = defaults.bool(forKey: Keys.hasReadICloudAppLibraries)
        hasSeenFirstRunTour = defaults.bool(forKey: Keys.hasSeenFirstRunTour)
    }
}
