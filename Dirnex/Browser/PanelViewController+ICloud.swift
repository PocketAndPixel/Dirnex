import AppKit
import DirnexCore

/// iCloud Drive as Finder assembles it, shown in a virtual listing (PLAN.md §M9 "the merged
/// app-container view").
///
/// Finder's "iCloud Drive" is a *synthesized* surface, not a directory: it merges the loose files in
/// `com~apple~CloudDocs` with every iCloud-enabled app's own public `Documents` folder — and those
/// live as **siblings** of CloudDocs under `~/Library/Mobile Documents`, not inside it (probed
/// 2026-07-21). M8's row browsed the container alone, which is half of it; this is the whole.
///
/// The shape is the M8 Trash's, one level over: `ICloudDrive.appLibraries` says which containers
/// qualify, each contributes one row wearing the app's name over the real `Documents` path, and the
/// union installs as an `.icloud` listing. Three things differ from the Trash, all because iCloud
/// Drive is a place people *put* things rather than a bin they empty:
///
/// - **It navigates in place**, like clicking a Favorite, rather than opening a tab beside the
///   current one. The Trash and Recents are results a user visits once; iCloud Drive is browsed
///   repeatedly, and a tab per click stacks up.
/// - **The root is writable**, through `writeDirectory`: New Folder, paste and drop land in the
///   CloudDocs container underneath. A merged listing has no directory of its own, but this one has
///   an obvious real home, and refusing a drag onto iCloud Drive would be a worse lie than the
///   merge.
/// - **Missing Full Disk Access degrades instead of asking.** `~/Library/Mobile Documents` is
///   TCC-gated (only the CloudDocs leaf is carved out), so without the grant the app libraries are
///   simply not there and the row shows the loose files M8 already shipped. The Trash asks because
///   without the grant it can show *nothing*, and an empty Trash is a lie; a short iCloud Drive is
///   not.
extension PanelViewController {
    /// Whether the active tab is showing the merged iCloud Drive.
    var isICloudListing: Bool {
        panel.path.backend == .icloud
    }

    /// The real directory this pane's create / paste / drop operations land in: the current
    /// directory for an ordinary folder, `nil` where there is none — search results, the Trash, a
    /// browsed archive — and the CloudDocs container for the merged iCloud listing, which is the one
    /// virtual location with a real home underneath it.
    var writeDirectory: VFSPath? {
        if isICloudListing { return SidebarLocations.iCloudDrive() }
        return isVirtualDirectory ? nil : panel.path
    }

    /// Show iCloud Drive in this pane — the sidebar's iCloud row, and walking up out of one of the
    /// folders the listing stands in front of, which is what `selecting` is for: the cursor lands on
    /// the row just left, exactly as walking up out of any folder does.
    func showICloudDrive(selecting target: VFSPath? = nil) {
        gatherICloudDrive { [weak self] entries, sources in
            guard let self else { return }
            // Recorded *before* the install, so the watcher `installResults` starts is the merged
            // one — a file added to iCloud Drive elsewhere then shows up without re-clicking.
            mergedSources = sources
            installResults(entries, as: iCloudPresentation())
            if let target, let index = panel.model.index(ofID: target) {
                panel.moveCursor(to: index)
                reloadEverything()
            }
        }
    }

    /// Re-gather the merge into the tab already showing it, after something in it changed. Called by
    /// `refreshCurrentDirectory`, the one funnel every mutation refreshes through — a merged listing
    /// has no FSEvents watcher of its own, so a New Folder or a paste into the root would otherwise
    /// leave the pane drawing the rows it had.
    func reloadICloudDrive(selecting target: VFSPath? = nil) {
        gatherICloudDrive { [weak self] entries, sources in
            guard let self, isICloudListing else { return }
            // An app library that appeared or emptied out changes what there is to watch; an
            // unchanged set leaves the running stream alone.
            watchMergedListing(sources: sources)
            // The same install-then-render tail the real-directory refresh ends with:
            // `installSortedModel` only swaps the model, and without `reloadEverything` the pane
            // goes on drawing what it had (docs/NOTES.md).
            _ = reconcileCursorFromTable()
            installSortedModel(resultsModel(entries, as: iCloudPresentation()))
            if let target, let index = panel.model.index(ofID: target) {
                panel.moveCursor(to: index)
            }
            reloadEverything()
        }
    }

    func iCloudPresentation() -> ResultsPresentation {
        ResultsPresentation(
            backend: .icloud,
            // The synthetic path the presentation builds from these two is `ICloudLocation
            // .mergedPath`, which is what the path bar's root crumb targets — they have to be the
            // same location or clicking the crumb would install a *second* iCloud tab identity.
            // Stable English identity, never displayed, exactly as the Trash's `pathSummary` is.
            pathSummary: ICloudLocation.mergedName,
            sort: panel.model.sort,
            query: nil,
            scope: nil,
            // The *tab title* is what's shown, so it localizes — the core's `mergedName` is the
            // identity above and carries no words for the screen.
            title: String(
                localized: "iCloud Drive",
                comment: "Apple's iCloud Drive: the sidebar row, the tab title, and the path bar's root crumb."
            ),
            // The pane's own setting, not the results default: this is a place being browsed, and
            // its dotfiles are ordinary dotfiles — a forced-on `.DS_Store` would be the first row of
            // the user's iCloud Drive.
            showsHidden: panel.model.showHidden
        )
    }

    // MARK: - Gathering

    /// Build the merged listing off the main thread: the CloudDocs container's own children, plus
    /// one row per qualifying app library.
    ///
    /// A container that can't be stat'ed contributes nothing rather than a row pointing at nothing —
    /// `appLibraries` already proved the folder exists and has content, so this only drops one that
    /// vanished between the scan and the stat.
    /// The directories are handed back alongside the entries because a pane showing the merge has to
    /// *watch* them — it has no directory of its own to watch.
    private func gatherICloudDrive(then present: @escaping ([FileEntry], [VFSPath]) -> Void) {
        let backend = backend
        let container = SidebarLocations.iCloudDrive()
        Task {
            let gathered = await Task.detached(priority: .userInitiated) { () -> ICloudGather in
                let loose = container.flatMap { try? backend.listDirectory(at: $0) } ?? []
                let scan = ICloudDrive.appLibraries()
                let rows = scan.libraries.compactMap { library -> FileEntry? in
                    guard let entry = try? backend.stat(at: library.documents) else { return nil }
                    return ICloudDrive.libraryRow(for: library, stat: entry)
                }
                return ICloudGather(
                    entries: ICloudDrive.merge(looseFiles: loose, libraryRows: rows),
                    libraries: scan.libraries,
                    // What this pass actually read: the loose-files container (when it exists) and
                    // every library folder that contributed a row.
                    sources: [container].compactMap { $0 } + rows.map(\.path),
                    isRestricted: scan.isRestricted
                )
            }.value

            // The icons are decoded on the main actor, from the cache the scan just named, so the
            // rows can render an app's own icon rather than a generic folder.
            ICloudLibraryIcons.shared.record(gathered.libraries)
            present(gathered.entries, gathered.sources)
            // Offered after the listing is on screen, and only once ever: the pane has just shown
            // the loose files, so this explains what is *missing* rather than standing in for it.
            if gathered.isRestricted {
                FullDiskAccessOnboarding.presentForICloud(over: view.window)
            }
        }
    }

    /// What one gather produced. The libraries ride along with the entries because the row an
    /// `ICloudAppLibrary` becomes keeps only its name and path — the icon lookup needs the rest.
    private struct ICloudGather: Sendable {
        let entries: [FileEntry]
        let libraries: [ICloudAppLibrary]
        /// The real directories behind the listing, for the pane to watch.
        let sources: [VFSPath]
        /// Whether a container's `Documents` refused to be read — the difference between "this Mac
        /// has no app libraries" and "I was not allowed to look", which must not render alike.
        let isRestricted: Bool
    }

    /// The app icon for a merged row, or `nil` for a loose file (and everywhere but this listing).
    func iCloudLibraryIcon(for entry: FileEntry) -> NSImage? {
        guard isICloudListing else { return nil }
        return ICloudLibraryIcons.shared.icon(for: entry.path)
    }
}

/// The cached app icons behind the merged listing's rows, keyed by the `Documents` path each app
/// library shows up as (PLAN.md §M9 "app-name / icon resolution").
///
/// Probed rather than guessed, and the obvious guess is wrong: `NSWorkspace.icon(forFile:)` on one
/// of these folders returns the **generic folder icon**, byte-identical to `~/Documents`', so it
/// looks like it works. The real icons are PNGs `bird` caches beside the container metadata, which
/// is also why they resolve for apps that are iOS-only and not installed on this Mac.
///
/// A library with no cached icon at all is a real outcome, not a defensive one — Curve caches none
/// here — and it simply falls back to the folder icon the rest of the pane draws.
@MainActor
final class ICloudLibraryIcons {
    static let shared = ICloudLibraryIcons()

    /// The name column's icon size in points; the cache names its PNGs in pixels, so the pick goes
    /// through `bestIconName(from:pointSize:scale:)` rather than by string.
    private static let pointSize: Double = 16

    private var icons: [VFSPath: NSImage] = [:]

    /// Load (and keep) the icon for each library in a fresh scan. Replaces the map wholesale so an
    /// app that stopped qualifying stops being drawn; the decode is a handful of small PNGs, once
    /// per visit to the row.
    func record(_ libraries: [ICloudAppLibrary]) {
        var icons: [VFSPath: NSImage] = [:]
        for library in libraries {
            guard let name = ICloudContainers.bestIconName(
                from: library.iconNames,
                pointSize: Self.pointSize,
                scale: Double(NSScreen.main?.backingScaleFactor ?? 2)
            ) else { continue }
            let file = ICloudContainers.metadataDirectory()
                .appending(library.bundleID)
                .appending(name + ".png")
            guard let image = NSImage(contentsOfFile: file.path) else { continue }
            image.size = NSSize(width: Self.pointSize, height: Self.pointSize)
            icons[library.documents] = image
        }
        self.icons = icons
    }

    func icon(for path: VFSPath) -> NSImage? {
        icons[path]
    }
}
