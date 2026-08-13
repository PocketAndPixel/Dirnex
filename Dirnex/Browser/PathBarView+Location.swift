import AppKit
import DirnexCore

/// How each kind of location renders in the path bar: a real directory's clickable breadcrumbs, a
/// browsed archive's mixed-backend trail, and a search snapshot's dead-end label. Split from the
/// view proper (like `+Table`/`+Chrome` around the pane) so `PathBarView` stays the editor, the
/// crumb plumbing and the branch chip, and this stays the location vocabulary.
extension PathBarView {
    /// Dispatch the location render by backend: clickable breadcrumbs for a local directory or a
    /// browsed archive (whose trail spans the archive's local ancestors, then its inner path), a
    /// non-clickable label for a search-results snapshot.
    func rebuildContents(for path: VFSPath, archiveAncestry: [VFSPath] = []) {
        if path.backend == .local {
            // A cloud provider's mount roots its own trail, so browsing Google Drive reads
            // `Google Drive › My Drive › Job` instead of burying it six crumbs deep under
            // `Macintosh HD › Users › oleg › Library › CloudStorage › GoogleDrive-someone@gmail.com`
            // (PLAN.md §M10 Phase 1). The lookup costs nothing off a cloud path — see
            // `CloudStorageMounts.mount(containing:)`.
            if let mount = CloudStorageMounts.mount(containing: path) {
                rebuildCrumbs(for: path, under: mount)
            } else if let trail = ICloudLocation.trail(for: path, fallbackName: Self.localizedName) {
                // Same judgment one level over: a folder opened from the merged iCloud listing is
                // a real local directory, but its real path runs through container machinery
                // (`com~apple~Pages/Documents`) the user never asked to see (PLAN.md §M9).
                rebuildICloudCrumbs(trail)
            } else {
                rebuildCrumbs(for: path)
            }
        } else if path.backend == .icloud {
            // The merged listing itself — the same trail as a folder inside it, with nothing below
            // the root. A crumb rather than the dead-end label the Trash gets, because unlike the
            // Trash this is one end of a chain the user walks up and down.
            rebuildICloudCrumbs([])
        } else if path.backend.isArchive {
            rebuildArchiveLabel(for: path, ancestry: archiveAncestry)
        } else if path.backend.isRemoteConnection, let rootTitle = path.backendRootTitle {
            // A connected account is re-listable, so it gets clickable breadcrumbs rooted at
            // whatever names it (`oleg@mac › Users › oleg › Dev`), like a local path — not the
            // dead-end "results" label a search snapshot gets. SFTP had this branch first and FTP
            // fell through to `rebuildVirtualLabel` for a while, drawing "Results for /" — the
            // search phrasing, on a remote server nobody searched (caught only by connecting). One
            // predicate and one title source now, so the next backend is named in
            // `backendRootTitle` and arrives here already correct.
            rebuildCrumbs(for: path, rootTitle: rootTitle)
        } else {
            rebuildVirtualLabel(for: path)
        }
    }

    /// The real directory text editing (double-click, Cmd+L) starts from, or `nil` where the
    /// location has none — a search snapshot is not a path the user can retype.
    ///
    /// The merged iCloud listing has no directory of its own but has an obvious real home: the
    /// CloudDocs container its New Folder and paste already land in (`writeDirectory`). So editing
    /// works there exactly as it does one folder deeper, rather than iCloud Drive being the one
    /// stop on the way in and out where the path goes dead.
    static func editBase(for path: VFSPath) -> VFSPath? {
        if path.backend == .local { return path }
        if path.backend == .icloud { return ICloudDrive.cloudDocs() }
        return nil
    }

    /// Render a location inside a cloud provider's mount, with the trail rooted at the mount under
    /// the provider's name — `Google Drive › My Drive › Job`.
    ///
    /// Still fully clickable, unlike the merged iCloud Drive's dead-end label: every crumb here is a
    /// real directory, so the breadcrumb affordance tells the truth. The trail simply *starts*
    /// lower. Walking above the mount is what the pane's Go Up does, not something the path bar has
    /// to keep a crumb for — the machinery under `~/Library/CloudStorage` is not a place the user
    /// asked to see, the same judgment the merged iCloud listing makes about its containers.
    func rebuildCrumbs(for path: VFSPath, under mount: CloudStorageMount) {
        let trail = path.ancestorsFromRoot.filter { $0.isSelfOrDescendant(of: mount.path) }
        installCrumbs(
            trail.map { ancestor in
                Crumb(
                    title: ancestor == mount.path ? mount.name : ancestor.lastComponent,
                    target: ancestor
                )
            },
            // The mount's own glyph, so browsing a cloud location is marked as one at a glance —
            // the same `cloud` symbol its sidebar row carries.
            leadingSymbol: mount.symbolName
        )
    }

    /// What the OS calls a directory — "Pages" for an app library's `Documents` folder, which is
    /// the name Finder shows for it.
    ///
    /// The non-hermetic half of the library-name lookup, which is why it lives here and is handed
    /// to the core rather than called by it: it only answers for a real iCloud item, so no test can
    /// synthesize it. Asked only when `bird`'s cached plist could not be read, which on a build
    /// without Full Disk Access is exactly when the container itself is still listable.
    static func localizedName(of directory: VFSPath) -> String? {
        try? URL(fileURLWithPath: directory.path)
            .resourceValues(forKeys: [.localizedNameKey]).localizedName
    }

    /// Render a location inside iCloud Drive, rooted at the merged listing — `iCloud Drive ›
    /// Pages › Drafts`.
    ///
    /// Every crumb navigates, including the root one: it targets the synthetic `.icloud` location,
    /// which the pane re-gathers rather than lists (`PanelViewController+PathBar`), the same thing
    /// walking up out of one of these folders does. That is what makes the merge a place in a chain
    /// instead of somewhere you can only arrive from the sidebar.
    func rebuildICloudCrumbs(_ trail: [ICloudLocation.Step]) {
        // The crumb's *target* is the core's stable synthetic path; its *title* is the displayed
        // name, so it localizes rather than borrowing `mergedName`, which is an identity.
        let root = Crumb(
            title: String(
                localized: "iCloud Drive",
                comment: "Apple's iCloud Drive: the sidebar row, the tab title, and the path bar's root crumb."
            ),
            target: ICloudLocation.mergedPath
        )
        installCrumbs(
            [root] + trail.map { Crumb(title: $0.title, target: $0.directory) },
            leadingSymbol: "icloud"
        )
    }

    /// The SF Symbol that names a *kind* of location in the path bar — `trash`, `icloud`, `cloud`,
    /// `magnifyingglass`. Always the same symbol the sidebar row that opens the location carries, so
    /// the place you clicked and the place you landed wear one mark.
    ///
    /// Shared by the non-clickable virtual label and the clickable cloud-mount trail, which is why
    /// it takes its tint rather than reading `isActive`: the label owns the whole row and follows the
    /// pane's active state, while the trail's glyph sits beside secondary-colored crumbs and matches
    /// those instead.
    ///
    /// It is a **button onto Places** (PLAN.md §M20 Slice 3), and it is in every location the bar can
    /// render — which is what makes it the mouse face of the place list. The root crumb could not be:
    /// `installVirtualLabel` replaces the whole crumb row for the Trash, Recents and search results,
    /// so a control hung there would be missing from exactly the locations you most want to leave.
    /// Swapping the `NSImageView` this used to be for a borderless button was measured to move
    /// nothing — same frame, same ink, to the pixel, in the row's real shape.
    func makePlacesButton(
        named symbolName: String,
        describedAs description: String,
        tint: NSColor
    ) -> NSButton {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        symbol?.isTemplate = true
        let glyph = NSButton(image: symbol ?? NSImage(), target: self, action: #selector(showPlaces))
        glyph.isBordered = false
        glyph.bezelStyle = .inline
        glyph.setButtonType(.momentaryChange)
        glyph.imagePosition = .imageOnly
        glyph.contentTintColor = tint
        glyph.toolTip = Self.placesTitle
        // A glyph-only control is silent to VoiceOver, and what it *does* is open the place list —
        // the location it also marks is spoken by the crumbs and the label beside it.
        glyph.setAccessibilityLabel(Self.placesTitle)
        // The glyph is the one thing in the row that must never be squeezed — it is what names the
        // kind of location, and a symbol compressed to nothing is worse than no symbol at all.
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        return glyph
    }

    /// The tooltip and accessibility label, drawn from the same catalog entry the Go ▸ Places
    /// submenu titles itself with — a display string that exists twice gets localized once
    /// (docs/NOTES.md). The `comment:` is repeated verbatim rather than hoisted because
    /// `String(localized:comment:)` takes a `StaticString`, and two sites keying one string with
    /// different comments hand the translator whichever `xcstringstool` kept.
    static var placesTitle: String {
        String(
            localized: "Places",
            comment: "Every sidebar destination: the Go-menu submenu, and the path bar's glyph."
        )
    }

    /// The glyph for a location whose trail is rooted in a filesystem rather than in a *place* —
    /// a plain local path, a browsed archive (whose crumbs start at the archive's local ancestors),
    /// and a connected server.
    ///
    /// The two remote answers are the saved-server row's own symbols, asked for by protocol, so a
    /// server browsed and a server listed wear one mark. Local takes the **boot volume's** glyph,
    /// which is not a guess about the disk the directory sits on: `rebuildCrumbs` titles the root
    /// crumb "Macintosh HD" for every local path, `/Volumes/…` included, so the glyph marks the
    /// trail's own root and matches the crumb beside it.
    static func rootSymbolName(for path: VFSPath) -> String {
        if path.backend.isSFTP { return SidebarPlacePresentation.serverSymbolName(for: .sftp) }
        if path.backend.isFTP { return SidebarPlacePresentation.serverSymbolName(for: .ftp) }
        // An account and a bucket are one service, so they wear one glyph — the same one their
        // sidebar rows carry, which is what `ServerKind` collapsing the two is for.
        if path.backend.isS3 || path.backend.isS3Account {
            return SidebarPlacePresentation.serverSymbolName(for: .s3)
        }
        return MountedVolume.internalSymbolName
    }

    /// Render a virtual location (Spotlight results, Recents, the merged Trash) as a single,
    /// non-clickable label — there is no ancestor chain to walk into, so the breadcrumb affordance
    /// would only mislead.
    ///
    /// The Trash names itself instead of borrowing the results phrasing: "Results for Trash" reads
    /// as a search someone ran, which is neither what it is nor how it behaves (it re-lists after a
    /// delete, where a search snapshot doesn't). Each carries the SF Symbol of the sidebar row that
    /// opens it — `trash` and `magnifyingglass` — rather than an emoji, which is a different type
    /// vocabulary that neither tints with the pane's active state nor matches the sidebar.
    ///
    /// iCloud Drive is the merged listing that is *not* here: you walk into and out of its rows, so
    /// it gets a crumb trail (`rebuildICloudCrumbs`) rather than a dead end.
    func rebuildVirtualLabel(for path: VFSPath) {
        if path.backend == .trash {
            installVirtualLabel(
                String(localized: "Trash", comment: "Path-bar label for the merged Trash listing."),
                symbolNamed: "trash"
            )
        } else if path.lastComponent == PanelViewController.ResultsPresentation.recentsIdentity {
            // Recents self-names for the same reason the Trash does: it is a place you visited, not a
            // search someone ran, so "Results for Recents" would misdescribe it. It matches on the
            // stable English `pathSummary` identity and carries the `clock` glyph its sidebar row uses.
            installVirtualLabel(
                String(localized: "Recents", comment: "Path-bar label for the Recents listing."),
                symbolNamed: "clock"
            )
        } else {
            installVirtualLabel(
                String(
                    localized: "Results for \(path.lastComponent)",
                    comment: "Path-bar label for a search-results snapshot; %@ is the query."
                ),
                symbolNamed: "magnifyingglass"
            )
        }
    }

    /// Render a browsed archive as a full, clickable breadcrumb trail — styled exactly like a
    /// local path (`Macintosh HD › Users › oleg › Downloads › pkg.zip › folder`). The trail
    /// carries the archive's real on-disk ancestors, then crosses into the archive at its own
    /// filename, then walks the inner tree. Every crumb navigates: a local ancestor exits the
    /// archive to that folder, the archive-name crumb re-enters its root, an inner crumb jumps
    /// within it — the same affordance the local path bar gives.
    func rebuildArchiveLabel(for path: VFSPath, ancestry: [VFSPath] = []) {
        installCrumbs(
            Self.archiveCrumbs(for: path, ancestry: ancestry),
            // The archive's own local ancestors are what the trail is rooted at — the crumb row
            // opens on "Macintosh HD" here exactly as a plain local path does — so the leading
            // glyph is the local one rather than an archive glyph, which would name the *last*
            // crumbs instead of the first.
            leadingSymbol: Self.rootSymbolName(for: .local("/"))
        )
    }

    /// The crumb chain for a browsed archive, outermost local folder → current inner directory.
    ///
    /// For a nested archive (§M4), `ancestry` carries the enclosing members outermost-first. The
    /// backends the chain crosses are `ancestry[i].backend` for each outer frame plus `path.backend`
    /// for the current (innermost) one; member `ancestry[i].path`'s last component is the next
    /// inner-archive file, so it doubles as frame `i+1`'s archive-name crumb, and that crumb's
    /// target is frame `i+1`'s root — every target is a directly navigable location.
    ///
    /// `static` and pure (no view state) so it's unit-testable without instantiating the view.
    static func archiveCrumbs(for path: VFSPath, ancestry: [VFSPath]) -> [Crumb] {
        // The outermost archive's real on-disk path — the local file the whole chain roots at.
        guard let outerOnDisk = ancestry.first?.backend.archivePath ?? path.backend.archivePath else {
            let name = (path.backend.archivePath as NSString?)?.lastPathComponent ?? "Archive"
            return [Crumb(title: name, target: path)]
        }

        // 1. The archive file's containing folders, so the trail reads as a full path before it
        //    crosses into the archive. Drop the file itself — it becomes the first archive crumb.
        var crumbs = VFSPath.local(outerOnDisk).ancestorsFromRoot.dropLast().map { ancestor in
            Crumb(title: ancestor.isRoot ? "Macintosh HD" : ancestor.lastComponent, target: ancestor)
        }

        // 2. Each archive in the chain, outermost → current.
        let backends = ancestry.map(\.backend) + [path.backend]
        for (index, backend) in backends.enumerated() {
            // The archive-name crumb — its own filename, navigating to this archive's root.
            let name = index == 0
                ? (outerOnDisk as NSString).lastPathComponent
                : (ancestry[index - 1].path as NSString).lastPathComponent
            crumbs.append(Crumb(title: name, target: VFSPath(backend: backend, path: "/")))

            // The inner directories browsed within this archive: down to (but not including) the
            // nested-archive file for an outer frame, the full browsed location for the current one.
            let isCurrentFrame = index == ancestry.count
            let innerPath = isCurrentFrame ? path.path : ancestry[index].path
            var components = innerPath.split(separator: "/", omittingEmptySubsequences: true).map(
                String.init
            )
            if !isCurrentFrame { components.removeLast() } // the nested-archive file, next frame's crumb
            var cumulative = ""
            for component in components {
                cumulative += "/" + component
                crumbs.append(
                    Crumb(title: component, target: VFSPath(backend: backend, path: cumulative))
                )
            }
        }
        return crumbs
    }
}
