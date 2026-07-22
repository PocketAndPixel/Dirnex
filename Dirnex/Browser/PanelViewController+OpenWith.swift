import AppKit
import DirnexCore

/// Handing the selection to the rest of the Mac (PLAN.md §M6 "Share sheet, 'Open With' submenu,
/// Services integration"): open it in another app, share it, or run a Service over it.
///
/// All three ask the same question first — *which of these rows are real files on this disk?* — so
/// they share `handoffTargets`. An archive member and an SFTP row have no local URL to give
/// another app, and inventing a `file://` path for one would hand Preview a path that isn't there.
/// Search results do qualify: the pane is virtual, but every row in it is a real local file, which
/// is the same line `tagTargets` draws for the same reason.
///
/// **Open With and Share are commands that pop a menu, not menu-bar submenus.** That is ⌃T's shape
/// (`showTagsMenu`), and it is deliberate: a submenu in the File menu would have to find the
/// focused pane from a static builder, whereas a registry command rides the responder chain to the
/// pane that has focus, appears in the ⌘K palette for free, and can be rebound. The right-click
/// menu still nests both as real submenus, built from the same items — the tags precedent exactly.
extension PanelViewController {
    // MARK: - Targets

    /// The rows that can be handed to another application: the marked set, else the cursor row,
    /// filtered to entries that exist on this disk.
    func handoffTargets() -> [URL] {
        selectionTargets()
            .filter { $0.path.backend == .local }
            .map(\.path.localURL)
    }

    /// Whether Open With / Share have anything to act on.
    var canHandOff: Bool {
        !handoffTargets().isEmpty
    }

    // MARK: - Open With

    /// File ▸ Open With — drop the app list over the cursor row.
    @objc func showOpenWithMenu(_ sender: Any?) {
        let targets = handoffTargets()
        guard !targets.isEmpty else { return }
        popUpOverCursorRow(openWithMenu(for: targets))
    }

    /// Validate Open With / Share. Returns `nil` for any other selector so the main switch handles
    /// it — split out like its siblings to keep `validateMenuItem` under SwiftLint's
    /// cyclomatic-complexity limit (a recurring gotcha in this file).
    ///
    /// Both are gated on the *targets*, not the pane, so they work from a results tab (virtual
    /// pane, real local hits) and go grey inside an archive or on an SFTP volume. Like ⌃T, they
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
    func openWithMenuItems(for targets: [URL]? = nil) -> [NSMenuItem] {
        let urls = targets ?? handoffTargets()
        var items: [NSMenuItem] = []
        let candidates = OpenWithLauncher.candidates(for: urls)
        if let preferred = candidates.defaultApplication {
            // Finder's wording: the app a plain double-click would have used is named as such, so
            // the item at the top reads as a confirmation rather than one more choice.
            items.append(appItem(for: preferred, urls: urls, suffix: " (default)"))
            if !candidates.others.isEmpty { items.append(.separator()) }
        }
        for application in candidates.others {
            items.append(appItem(for: application, urls: urls, suffix: ""))
        }
        if candidates.isEmpty {
            // Not an error and not an empty menu: nothing *registered* opens this, which is exactly
            // when a user reaches for Other… to pick something themselves.
            let empty = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            items.append(empty)
        }
        items.append(.separator())
        let other = NSMenuItem(
            title: "Other…",
            action: #selector(openWithOther(_:)),
            keyEquivalent: ""
        )
        other.target = self
        other.representedObject = urls
        items.append(other)
        return items
    }

    /// The same list, wrapped for the command that pops it standalone.
    private func openWithMenu(for targets: [URL]) -> NSMenu {
        let menu = NSMenu()
        for item in openWithMenuItems(for: targets) {
            menu.addItem(item)
        }
        return menu
    }

    private func appItem(for application: ApplicationRef, urls: [URL], suffix: String) -> NSMenuItem {
        let item = NSMenuItem(
            title: application.displayName + suffix,
            action: #selector(openWithApplication(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = OpenWithRequest(urls: urls, application: application)
        item.image = OpenWithLauncher.icon(for: application)
        return item
    }

    @objc private func openWithApplication(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? OpenWithRequest else { return }
        open(request.urls, with: request.application)
    }

    private func open(_ urls: [URL], with application: ApplicationRef) {
        OpenWithLauncher.open(urls, with: application) { [weak self] error in
            guard let error else { return }
            self?.presentOperationFailure(
                message: "Couldn’t open with “\(application.displayName)”.",
                detail: error.localizedDescription
            )
        }
    }

    /// Other… — pick any application by hand. The panel is rooted at /Applications and accepts only
    /// application bundles, so it can't be used to point Open With at a text file.
    @objc private func openWithOther(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL], !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let choice = panel.url else { return }
            self?.open(urls, with: OpenWithLauncher.reference(to: choice))
        }
    }

    // MARK: - Share

    /// File ▸ Share — the system share sheet over the cursor row.
    ///
    /// `NSSharingServicePicker` is shown rather than assembled: which services exist, their icons,
    /// their order, and the "More…" that opens the extension settings are all the system's to
    /// decide, and they change with what the user has installed and enabled.
    @objc func shareSelection(_ sender: Any?) {
        let targets = handoffTargets()
        guard !targets.isEmpty else { return }
        let picker = NSSharingServicePicker(items: targets)
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

/// What an Open With item carries: the files and the app to send them to. A struct in
/// `representedObject` (which takes `Any?`) keeps the item from having to encode a path in its tag.
private struct OpenWithRequest {
    let urls: [URL]
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
        if sendType == .fileURL, returnType == nil, canHandOff {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}
