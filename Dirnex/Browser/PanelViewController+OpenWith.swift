import AppKit
import DirnexCore

/// Handing the selection to the rest of the Mac (PLAN.md §M6 "Share sheet, 'Open With' submenu,
/// Services integration"): open it in another app, share it, or run a Service over it.
///
/// All three used to ask the same question first — *which of these rows are real files on this
/// disk?* — and refuse everything else, because an archive member and an SFTP row have no local URL
/// to give another app. M24 Slice 3 splits that in two: nothing about Open With or Share needs a row
/// to be **local**, only to be a **file**, so those two now bring the bytes down first
/// (`PanelViewController+Materialize`) and hand over the copy. Search results qualified all along —
/// the pane is virtual, but every row in it is a real local file, the same line `tagTargets` draws.
///
/// **Services is the one that stays local, and it is a limit rather than a gap.** AppKit asks a
/// responder to fill a pasteboard *synchronously*, from `writeSelection(to:types:)`, and there is
/// nowhere in that call to put a download — blocking the main thread on one is the failure every
/// other part of this milestone exists to prevent. So `handoffTargets` survives as the local-only
/// subset, and Services is now the only thing that reads it: user scripts joined the fetching side
/// at Slice 5.
///
/// **The Open With menu appears before anything is downloaded.** A row that is not on this disk is
/// typed by its *name* (`OpenWithLauncher.candidates(for:)`), so the app list costs nothing and a
/// user who presses Escape has paid nothing; the transfer starts when they pick an application. The
/// share sheet cannot do that — `NSSharingServicePicker`'s services and their icons are derived
/// from the items themselves — so Share fetches first and then presents.
///
/// **Open With and Share are commands that pop a menu, not menu-bar submenus.** That is ⌃T's shape
/// (`showTagsMenu`), and it is deliberate: a submenu in the File menu would have to find the
/// focused pane from a static builder, whereas a registry command rides the responder chain to the
/// pane that has focus, appears in the ⌘K palette for free, and can be rebound. The right-click
/// menu still nests both as real submenus, built from the same items — the tags precedent exactly.
extension PanelViewController {
    // MARK: - Targets

    /// The rows a hand-off acts on — Open With, Share and a user script: the marked set, else the
    /// cursor row, with anything nothing could turn into a file dropped.
    ///
    /// What that drops is a **folder that is not on this disk** — a remote directory, or a directory
    /// member of an archive. Neither stands for one transfer or one extraction: a folder on a server
    /// is an unknown number of objects in an unknown number of requests, which is exactly why
    /// `MaterializationPlan` names them rather than weighing them. Copying a tree out is F5's job
    /// and it already does it. A local folder is untouched and still hands over, as it always has —
    /// "Open With ▸ Terminal" on a directory is an ordinary thing to want.
    func handoffEntries() -> [FileEntry] {
        let rows = selectionTargets()
        let refused = Set(materializationPlan(for: rows).pendingDirectories.map(\.path))
        return refused.isEmpty ? rows : rows.filter { !refused.contains($0.path) }
    }

    /// The subset that is **already** a file on this disk, as URLs — what a caller that cannot wait
    /// for a download is left with. Services is the whole of that (see the type comment).
    func handoffTargets() -> [URL] {
        selectionTargets()
            .filter { $0.path.backend == .local }
            .map(\.path.localURL)
    }

    /// Whether Open With / Share have anything to act on.
    var canHandOff: Bool {
        !handoffEntries().isEmpty
    }

    /// Whether this pane has anything to offer a **Service**, which is a narrower question with a
    /// different answer — and asking the wider one here would advertise the pane to the Services
    /// menu for a selection `writeSelection` then declines to write, leaving items that do nothing.
    var canSendToServices: Bool {
        !handoffTargets().isEmpty
    }

    // MARK: - Open With

    /// File ▸ Open With — drop the app list over the cursor row.
    @objc func showOpenWithMenu(_ sender: Any?) {
        let targets = handoffEntries()
        guard !targets.isEmpty else { return }
        popUpOverCursorRow(openWithMenu(for: targets))
    }

    /// Validate Open With / Share. Returns `nil` for any other selector so the main switch handles
    /// it — split out like its siblings to keep `validateMenuItem` under SwiftLint's
    /// cyclomatic-complexity limit (a recurring gotcha in this file).
    ///
    /// Both are gated on the *targets*, not the pane, so they work from a results tab (virtual
    /// pane, real local hits) and go gray inside an archive or on an SFTP volume. Like ⌃T, they
    /// must reach a field editor rather than being stolen to open a popup mid-rename.
    func validateHandoffItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(showOpenWithMenu(_:)), #selector(shareSelection(_:)):
            return canHandOff && !(view.window?.firstResponder is NSText)
        case #selector(editCursorFile(_:)), #selector(editNewFile(_:)):
            // F4/⇧F4 are handoffs too — to a text editor rather than to a chosen app — and they
            // ride this helper rather than the main switch, which sits at SwiftLint's
            // cyclomatic-complexity ceiling. The answer itself lives in `+Edit`.
            return validateEditItem(menuItem)
        default:
            return nil
        }
    }

    /// The Open With items for the current targets. Handed out as **items** rather than a menu, so
    /// the command can pop them standalone while the right-click menu nests the same list as a
    /// submenu — one definition of what Open With contains, and the shape `tagMenuItems` already
    /// uses. (An `NSMenuItem` belongs to one menu at a time, so a menu can't be shared this way.)
    func openWithMenuItems(for targets: [FileEntry]? = nil) -> [NSMenuItem] {
        let rows = targets ?? handoffEntries()
        var items: [NSMenuItem] = []
        let candidates = OpenWithLauncher.candidates(for: rows)
        if let preferred = candidates.defaultApplication {
            // Finder's wording: the app a plain double-click would have used is named as such, so
            // the item at the top reads as a confirmation rather than one more choice.
            items.append(appItem(for: preferred, rows: rows, isDefault: true))
            if !candidates.others.isEmpty { items.append(.separator()) }
        }
        for application in candidates.others {
            items.append(appItem(for: application, rows: rows))
        }
        if candidates.isEmpty {
            // Not an error and not an empty menu: nothing *registered* opens this, which is exactly
            // when a user reaches for Other… to pick something themselves.
            let empty = NSMenuItem(
                title: String(
                    localized: "No Applications",
                    comment: "Open With menu, disabled item: nothing is registered to open this file."
                ),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            items.append(empty)
        }
        items.append(.separator())
        let other = NSMenuItem(
            title: String(
                localized: "Other…",
                comment: "Open With menu item: pick an application by hand."
            ),
            action: #selector(openWithOther(_:)),
            keyEquivalent: ""
        )
        other.target = self
        other.representedObject = rows
        items.append(other)
        return items
    }

    /// The same list, wrapped for the command that pops it standalone.
    private func openWithMenu(for targets: [FileEntry]) -> NSMenu {
        let menu = NSMenu()
        for item in openWithMenuItems(for: targets) {
            menu.addItem(item)
        }
        return menu
    }

    private func appItem(
        for application: ApplicationRef,
        rows: [FileEntry],
        isDefault: Bool = false
    ) -> NSMenuItem {
        // Compose the whole title through the catalog rather than appending a " (default)" suffix:
        // `displayName + suffix` resolves to a plain `String` and never localizes (docs/NOTES.md),
        // and Russian parenthesizes differently anyway.
        let title = isDefault
            ? String(
                localized: "\(application.displayName) (default)",
                comment: "Open With menu item for the app a double-click would use; %@ is the app name."
            )
            : application.displayName
        let item = NSMenuItem(
            title: title,
            action: #selector(openWithApplication(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = OpenWithRequest(rows: rows, application: application)
        item.image = OpenWithLauncher.icon(for: application)
        return item
    }

    @objc private func openWithApplication(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? OpenWithRequest else { return }
        open(request.rows, with: request.application)
    }

    /// Bring the rows down to real files, then launch.
    ///
    /// The download happens **here**, after the app was chosen, rather than before the menu was
    /// built — so escaping out of the list costs nothing at all. One failure sentence covers both
    /// halves deliberately: the user asked for these files in this application, and "the transfer
    /// failed" and "the launch failed" are the same disappointment from their side.
    private func open(_ rows: [FileEntry], with application: ApplicationRef) {
        let failureMessage = {
            String(
                localized: "Couldn’t open with “\(application.displayName)”.",
                comment: "Open With failure; %@ is the app name."
            )
        }
        materialize(rows, for: .handOff, failureMessage: failureMessage) { [weak self] urls in
            OpenWithLauncher.open(urls, with: application) { error in
                guard let error else { return }
                self?.presentOperationFailure(
                    message: failureMessage(),
                    detail: error.localizedDescription
                )
            }
        }
    }

    /// Other… — pick any application by hand. The panel is rooted at /Applications and accepts only
    /// application bundles, so it can't be used to point Open With at a text file.
    @objc private func openWithOther(_ sender: NSMenuItem) {
        guard let rows = sender.representedObject as? [FileEntry], !rows.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = String(
            localized: "Choose an Application",
            comment: "Open panel title for picking an app in Open With ▸ Other…"
        )
        panel.prompt = String(
            localized: "Open",
            comment: "Open panel button for picking an app in Open With ▸ Other…"
        )
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let choice = panel.url else { return }
            self?.open(rows, with: OpenWithLauncher.reference(to: choice))
        }
    }

    // MARK: - Share

    /// File ▸ Share — the system share sheet over the cursor row.
    ///
    /// `NSSharingServicePicker` is shown rather than assembled: which services exist, their icons,
    /// their order, and the "More…" that opens the extension settings are all the system's to
    /// decide, and they change with what the user has installed and enabled.
    @objc func shareSelection(_ sender: Any?) {
        let targets = handoffEntries()
        guard !targets.isEmpty else { return }
        // Fetch first, unlike Open With — and it is the picker's own shape that decides it, not a
        // preference: which services appear, their icons and their order are derived by AppKit from
        // the *items*, so there is no list to show before the files exist.
        materialize(targets, for: .handOff) {
            String(
                localized: "Couldn’t share these items",
                comment: """
                Alert title when files can't be downloaded or extracted for the share sheet.
                """
            )
        } then: { [weak self] urls in
            self?.presentShareSheet(for: urls)
        }
    }

    /// Drop the system picker under the cursor row.
    ///
    /// Separate from the gesture because the two are no longer in the same turn: a remote selection
    /// puts a transfer between them, so this runs when the bytes have landed rather than when the
    /// key was pressed.
    private func presentShareSheet(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        let row = cursorOnParentRow ? 0 : row(forEntryIndex: panel.cursor)
        // Same anchoring as the tags menu, and for the same reason: the model's cursor, not
        // `tableView.selectedRow`, which is -1 whenever marks were made without moving the cursor.
        picker.show(relativeTo: tableView.rect(ofRow: row), of: tableView, preferredEdge: .maxY)
    }

    /// The system's own "Share…" item, for nesting in the right-click menu. AppKit fills its
    /// submenu when it opens.
    func shareMenuItem(for targets: [URL]) -> NSMenuItem {
        NSSharingServicePicker(items: targets).standardShareMenuItem
    }

    // MARK: - Shared plumbing

    /// Drop `menu` under the cursor row, where the tags menu appears.
    private func popUpOverCursorRow(_ menu: NSMenu) {
        let row = cursorOnParentRow ? 0 : row(forEntryIndex: panel.cursor)
        let anchor = tableView.rect(ofRow: row)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: anchor.minX + 24, y: anchor.maxY),
            in: tableView
        )
    }
}

/// What an Open With item carries: the **rows** and the app to send them to.
///
/// Rows rather than URLs since M24 Slice 3, because at the moment this item is built half of them
/// may have no file on this disk — the menu is drawn from names and the bytes are fetched once the
/// user has picked. A struct in `representedObject` (which takes `Any?`) keeps the item from having
/// to encode anything in its tag.
private struct OpenWithRequest {
    let rows: [FileEntry]
    let application: ApplicationRef
}

/// Makes the pane's selection available to **Services**, so a Service that takes files ("New Mail
/// Message With Attachment", "Encode Selected Video Files", anything a user has built in
/// Automator) sees what the pane has marked.
///
/// This is the whole of Services integration on our side: the Services menu itself is populated by
/// AppKit from the responder chain, and the only thing it needs from a responder is an answer to
/// "can you produce file URLs?" and then the URLs. `AppDelegate` registers `.fileURL` as a send
/// type, which is what lets the menu be built before anything is asked.
///
/// **Local rows only**, and that is the one place M24 Slice 3 deliberately changed nothing: the
/// pasteboard is filled *synchronously*, inside the call AppKit makes as the menu opens, and there
/// is nowhere in it to put a download. `canSendToServices` is the narrower gate that keeps the menu
/// from advertising a selection this cannot write.
///
/// `@preconcurrency` for the same reason as the Quick Look panel's conformance: `NSServicesMenuRequestor`
/// carries no main-actor annotation in the SDK, but AppKit only ever asks a responder for its
/// selection on the main thread — it is driven by the menu opening.
extension PanelViewController: @preconcurrency NSServicesMenuRequestor {
    func writeSelection(
        to pasteboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard types.contains(.fileURL) else { return false }
        let targets = handoffTargets()
        guard !targets.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(targets.map { $0 as NSURL })
    }

    /// Offer this pane to a Service only when it is asking for files we have and wants nothing
    /// back — Dirnex sends a selection to a Service, it does not take a result from one (a Service
    /// that returns text has nothing to give a file pane).
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if sendType == .fileURL, returnType == nil, canSendToServices {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}
