import AppKit
import DirnexCore

/// Editing Finder tags from the panel (PLAN.md §M6 "Finder tags: … edit from panel"): ⌃T drops a
/// menu over the selection offering the seven stock tags and the names already in use, each item
/// toggling that tag across every target. The writing itself is the core's `FinderTagStorage`,
/// which is where all the hard-won knowledge about the format lives; this is the AppKit shell.
///
/// **Why the menu offers a colour only for a name it has never seen.** The core established, by
/// watching Finder rewrite bytes on disk, that a colour belongs to the *name*, system-wide — not to
/// the file. Finder reconciles a file's stored copy against its own name → colour database, so
/// re-colouring one file's `Work` is not a change macOS keeps. Offering per-file colour would be
/// offering an edit that silently reverts, so the menu doesn't: an existing tag toggles on and off,
/// and only "New Tag…" picks a colour, at the one moment the choice is real.
extension PanelViewController {
    // MARK: - Command (dispatched to the focused pane via the responder chain)

    /// ⌃T — drop the tag menu over the cursor row.
    @objc func showTagsMenu(_ sender: Any?) {
        guard canEditTags else { return }
        let menu = buildTagsMenu(for: tagTargets())
        // Anchored on the **model's** cursor, not `tableView.selectedRow`. The two are not the same
        // question: marks are independent of the cursor here, so ⌘A-then-⌃T leaves the table with no
        // selected row at all — `selectedRow` answers -1, and a fallback to `visibleRect` drops the
        // menu at the *bottom* of the pane (the table is flipped, so `maxY` is its lowest edge),
        // clipped and scrolling. Found live. The model always has a cursor, and `..` lives only in
        // `cursorOnParentRow`, so this is also the one source that knows about that row.
        let row = cursorOnParentRow ? 0 : row(forEntryIndex: panel.cursor)
        let anchor = tableView.rect(ofRow: row)
        // The table is flipped: `maxY` is the row's bottom on screen, so the menu drops below the
        // file it will act on rather than covering it.
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: anchor.minX + 24, y: anchor.maxY),
            in: tableView
        )
    }

    // MARK: - Targets

    /// The entries a tag edit applies to: the marked set, else the cursor row — `selectionTargets`,
    /// filtered to what can actually carry a tag.
    ///
    /// Filtered per *entry* rather than per pane, which is what lets tagging work from a search
    /// results tab: the pane is virtual, but each hit is a real local file. It also means a mixed
    /// selection tags what it can instead of refusing wholesale.
    func tagTargets() -> [FileEntry] {
        selectionTargets().filter { $0.path.backend == .local }
    }

    /// Whether the tag menu has anything to act on.
    var canEditTags: Bool {
        !tagTargets().isEmpty
    }

    // MARK: - The menu

    private func buildTagsMenu(for targets: [FileEntry]) -> NSMenu {
        let menu = NSMenu()
        for item in tagMenuItems(for: targets) {
            menu.addItem(item)
        }
        return menu
    }

    /// The tag items for the current targets — the stock tags, the names already in use, New Tag…
    /// and Remove All Tags. Handed out as items rather than a menu so ⌃T can pop them standalone
    /// while the right-click menu nests the same list as a submenu, with no second definition of
    /// what the tag menu contains.
    func tagMenuItems(for targets: [FileEntry]? = nil) -> [NSMenuItem] {
        let targets = targets ?? tagTargets()
        // Read the targets' own tags inline rather than from the render snapshot: a selection is a
        // handful of files (~10 µs each), the snapshot may not have landed yet, and it is the wrong
        // source anyway — the menu must reflect the file, not the last render.
        let current = currentTags(of: targets)
        let offered = offeredTags(including: current)
        var items = offered.map { tagItem(for: $0, current: current, targetCount: targets.count) }
        if !offered.isEmpty { items.append(.separator()) }

        let newTag = NSMenuItem(
            title: String(localized: "New Tag…", comment: "Tag menu: create a brand-new tag."),
            action: #selector(promptForNewTag(_:)),
            keyEquivalent: ""
        )
        newTag.target = self
        items.append(newTag)

        let clear = NSMenuItem(
            title: String(
                localized: "Remove All Tags",
                comment: "Tag menu: strip every tag from the targets."
            ),
            action: #selector(removeAllTags(_:)),
            keyEquivalent: ""
        )
        clear.target = self
        clear.isEnabled = !current.isEmpty
        items.append(clear)
        return items
    }

    /// One tag item: a dot in its colour, checked when **every** target carries it and mixed when
    /// only some do — so a menu over a marked set says what it will change before it changes it.
    private func tagItem(for tag: FinderTag, current: [FinderTag: Int], targetCount: Int) -> NSMenuItem {
        let item = NSMenuItem(title: tag.name, action: #selector(toggleTag(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = tag
        item.image = TagDotStyle.menuImage(for: tag.color)
        let carriers = current[tag] ?? 0
        item.state = carriers == 0 ? .off : (carriers == targetCount ? .on : .mixed)
        return item
    }

    /// How many of the targets carry each tag. Keyed by `FinderTag`, whose `==` is the system's own
    /// name-as-identity rule, so `Work` and `work` across two files count as the one tag they are.
    private func currentTags(of targets: [FileEntry]) -> [FinderTag: Int] {
        var counts: [FinderTag: Int] = [:]
        for target in targets {
            for tag in (try? FinderTagStorage.tags(at: target.path)) ?? [] {
                counts[tag, default: 0] += 1
            }
        }
        return counts
    }

    /// What the menu lists: the stock seven, plus every tag seen this session, plus whatever the
    /// targets carry. In stock order first — Finder's rainbow, since muscle memory is worth more
    /// here than alphabetical — then the custom names sorted. The same list, in the same order, that
    /// the sidebar's Tags section shows.
    ///
    /// A tag's name is spelled the way the targets spell it when they carry it; its colour comes from
    /// what that *name* is known to be, never from the targets' stored byte.
    ///
    /// The colour half used to work the other way — the files' own copy was preferred — and that is
    /// exactly the bug `FinderTagIndex` documents, twice over. A target inside iCloud Drive carries
    /// `Red\n1`, so the menu drew Red's swatch grey; worse, the item's `representedObject` *is* the
    /// tag `toggleTag` writes, so tagging an iCloud file and a local one Red together wrote `Red\n1`
    /// to the local file too — where the byte is not normalised and simply persists, leaving a
    /// permanently grey Red behind. Resolving by name fixes the swatch and what gets written.
    private func offeredTags(including current: [FinderTag: Int]) -> [FinderTag] {
        var seen = Set(FinderTag.systemTags)
        let custom = (FinderTagProvider.shared.knownTags + current.keys)
            .filter { seen.insert($0).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return FinderTagProvider.shared.resolve(
            (FinderTag.systemTags + custom).map { tag in
                current.keys.first { $0 == tag } ?? tag
            }
        )
    }

    // MARK: - Actions

    @objc private func toggleTag(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? FinderTag else { return }
        let targets = tagTargets()
        // Anything short of "every target already has it" adds — the same rule Finder's own tag
        // menu follows, and the one that makes a mixed selection converge rather than flip-flop.
        let adding = sender.state != .on
        applyTagEdit(to: targets) { path in
            if adding {
                try FinderTagStorage.add(tag, to: path)
            } else {
                try FinderTagStorage.remove(tag, from: path)
            }
        }
    }

    @objc private func removeAllTags(_ sender: Any?) {
        applyTagEdit(to: tagTargets()) { path in
            try FinderTagStorage.setTags([], at: path)
        }
    }

    @objc private func promptForNewTag(_ sender: Any?) {
        let targets = tagTargets()
        presentNewTagPrompt { [weak self] tag in
            self?.applyTagEdit(to: targets) { path in
                try FinderTagStorage.add(tag, to: path)
            }
        }
    }

    /// Run one write per target off the main thread, then bring the column back in step.
    ///
    /// Off-main because a marked set can be thousands of files and each write is a read, an encode
    /// and two `setxattr`s — small, but not something to do a thousand of on the main thread. The
    /// pane's own FSEvents watcher would eventually notice these writes; the explicit refresh is
    /// what makes the dots land *now* rather than a debounce later.
    private func applyTagEdit(
        to targets: [FileEntry],
        _ edit: @escaping @Sendable (VFSPath) throws -> Void
    ) {
        guard !targets.isEmpty else { return }
        let paths = targets.map(\.path)
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                for path in paths {
                    do {
                        try edit(path)
                    } catch {
                        // Report the first failure and stop: the rest of a selection will almost
                        // always fail the same way (a read-only volume, no permission), and a
                        // sheet per file would be unusable.
                        return "\(path.lastComponent): \(error.localizedDescription)"
                    }
                }
                return nil
            }.value
            if let failure {
                presentOperationFailure(
                    message: String(
                        localized: "Couldn’t change tags",
                        comment: "Tag-change failure alert title."
                    ),
                    detail: failure
                )
            }
            refreshTagsAfterEdit()
        }
    }

    /// Name a new tag, and pick the colour it is introduced in — the one moment the colour choice
    /// is the user's to make (see this file's header).
    private func presentNewTagPrompt(completion: @escaping (FinderTag) -> Void) {
        let alert = NSAlert()
        alert.messageText = String(localized: "New Tag", comment: "Title of the new-tag dialog.")
        alert.informativeText = String(
            localized: "Name the tag and choose the colour it will be introduced in.",
            comment: "New-tag dialog body."
        )
        alert.addButton(
            withTitle: String(localized: "Add", comment: "Button that creates the new tag.")
        )
        alert.addButton(
            withTitle: String(localized: "Cancel", comment: "Button that dismisses a dialog.")
        )
        alert.enableEscapeToCancel()

        let field = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        field.placeholderString = String(
            localized: "Tag name",
            comment: "Placeholder in the new-tag name field."
        )
        let colors = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        for color in FinderTagColor.allCases {
            colors.addItem(withTitle: LocalizedCatalog.title(for: color))
            colors.lastItem?.image = TagDotStyle.menuImage(for: color)
        }
        // The closed button draws the selected item's dot hard against its name; the open list gets
        // its gap for free from the menu's icon column. Padding the dot image would fix the button
        // and widen the list, which is already right — so the button is given an item of its own to
        // display instead, and only that copy carries the padding.
        (colors.cell as? NSPopUpButtonCell)?.usesItemFromMenu = false
        colors.target = self
        colors.action = #selector(newTagColorPicked(_:))
        showSelectedColor(on: colors)
        // An `NSAlert` accessory is laid out by frame, not by constraints — a live-found gotcha
        // from the SMB pass: constraints here leave the view zero-sized and invisible.
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        accessory.addSubview(field)
        accessory.addSubview(colors)
        alert.accessoryView = accessory

        let commit = {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let choice = colors.indexOfSelectedItem
            // Indexed through `allCases`, not `FinderTagColor(rawValue:)`: the popup was built by
            // iterating `allCases`, so that is the mapping that is actually true here. The raw
            // values happen to agree today, and would stop agreeing the moment a case is reordered.
            guard !name.isEmpty, choice >= 0, choice < FinderTagColor.allCases.count else { return }
            completion(FinderTag(name: name, color: FinderTagColor.allCases[choice]))
        }
        guard let window = view.window else {
            if alert.runModal() == .alertFirstButtonReturn { commit() }
            return
        }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            commit()
        }
        alert.window.makeFirstResponder(field)
    }

    @objc private func newTagColorPicked(_ sender: NSPopUpButton) {
        showSelectedColor(on: sender)
    }

    /// Mirror the selection onto the popup's display item — see `presentNewTagPrompt`. The item is
    /// rebuilt on every pick, since the cell shows this copy and nothing else once
    /// `usesItemFromMenu` is off.
    private func showSelectedColor(on popup: NSPopUpButton) {
        let choice = popup.indexOfSelectedItem
        guard let cell = popup.cell as? NSPopUpButtonCell,
              let selected = popup.selectedItem,
              choice >= 0, choice < FinderTagColor.allCases.count
        else { return }
        let display = NSMenuItem(title: selected.title, action: nil, keyEquivalent: "")
        display.image = paddedDot(for: FinderTagColor.allCases[choice])
        cell.menuItem = display
    }

    /// A dot with empty room after it, so the button's own drawing has a gap to butt the name up
    /// against. The dot is drawn at its natural size; only the canvas grows.
    private func paddedDot(for color: FinderTagColor, gap: CGFloat = 5) -> NSImage {
        let dot = TagDotStyle.menuImage(for: color)
        let size = NSSize(width: dot.size.width + gap, height: dot.size.height)
        return NSImage(size: size, flipped: false) { _ in
            dot.draw(in: NSRect(origin: .zero, size: dot.size))
            return true
        }
    }
}
