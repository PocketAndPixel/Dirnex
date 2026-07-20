import AppKit
import DirnexCore

/// The sidebar's Tags section (PLAN.md §M6 "Finder tags: … filter chips in search") — Finder's own
/// bottom-of-the-sidebar list of coloured tags, each one a click away from every file carrying it.
/// Split out of `SidebarViewController` so that file stays under the length limit, exactly as the
/// saved-search and server sections are; the main file's `rebuild`, `viewFor` and `rowClicked`
/// dispatch here.
///
/// **A tag row is a search, not a place.** There is no directory of tagged files to navigate to, so
/// a click runs the `SpotlightQuery` that finds them and lands the hits in a virtual results tab —
/// the same machinery a saved search uses, which is why this needed no new panel code at all.
///
/// **Why the section is gated on View ▸ Show Tags.** The preference already means "tags are part of
/// how I work" everywhere else (it installs the dots in the panes, and `PanelViewController+Tags`
/// scans only when it is on). Since the scan is what discovers custom tags, a Tags section shown
/// while the preference is off would be stuck at the stock seven forever — the toggle and the
/// section's usefulness are the same switch, so it gates both.
extension SidebarViewController {
    // MARK: - Rows

    /// The Tags section's rows — its header is `rebuild`'s to add, like every other section's — or
    /// nothing at all when the user has turned tags off, which drops the header with them.
    ///
    /// The stock seven always show: they exist on every Mac, before anything has been scanned, so
    /// the section is never empty-and-useless the way one built purely from sightings would be.
    /// Custom tags join them once `showsAllTags` is set.
    func tagRows() -> [Row] {
        guard AppPreferences.shared.showTags else {
            renderedTagNames = []
            return []
        }
        let all = FinderTagProvider.shared.knownTags
        renderedTagNames = Set(all.map(\.name))

        var rows: [Row] = (showsAllTags ? all : FinderTag.systemTags).map(Row.tag)
        // "All Tags…" only when there is something behind it. Finder can always offer it because it
        // knows every tag you own; we know the ones we have seen, so offering to reveal nothing
        // would be a row that does nothing when clicked — worse than no row.
        if !showsAllTags, all.count > FinderTag.systemTags.count {
            rows.append(.allTags)
        }
        return rows
    }

    // MARK: - Cells

    /// A tag row: its colour as a dot where the other sections put an icon, and its name.
    ///
    /// The dot is **not** a template image, unlike every other glyph in the sidebar — those are
    /// tinted to match their label, which for a tag would erase the one thing it has to say. It is
    /// the same `TagDotStyle` the name-cell dots and the ⌃T menu items draw, so a colour reads
    /// identically everywhere; a colourless custom tag gets that style's hollow ring.
    func tagCell(for tag: FinderTag) -> NSView {
        let cell = tagRowCell()
        cell.configure(
            name: tag.name,
            image: TagDotStyle.menuImage(for: tag.color, diameter: 12),
            canEject: false,
            tooltip: "Find files tagged “\(tag.name)”"
        )
        return cell
    }

    /// The "All Tags…" row — reveals the custom tags found while browsing.
    func allTagsCell() -> NSView {
        let cell = tagRowCell()
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(
            systemSymbolName: "circle.on.circle",
            accessibilityDescription: "All tags"
        )?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        cell.configure(
            name: "All Tags…",
            image: image ?? NSImage(),
            canEject: false,
            tooltip: "Show every tag found while browsing"
        )
        return cell
    }

    /// A reused item cell with the trailing affordances cleared — a tag row has neither an eject
    /// nor a delete, and a recycled cell would otherwise inherit whichever the row before it had.
    private func tagRowCell() -> SidebarCellView {
        let cell = tableView.makeView(
            withIdentifier: SidebarCellView.identifier,
            owner: self
        ) as? SidebarCellView ?? SidebarCellView()
        cell.onEject = nil
        cell.onDelete = nil
        return cell
    }

    // MARK: - Actions

    /// Expand the section to every tag we know of. One-way on purpose: the row it replaces is the
    /// only thing that would collapse it again, and someone who asked to see their tags is not
    /// looking for a way to hide them again — Finder doesn't offer one either.
    func expandAllTags() {
        showsAllTags = true
        rebuild()
    }

    // MARK: - The right-click menu

    /// Populate `menu` for a tag row — find the files carrying it, and, for a custom tag, delete it.
    ///
    /// **Deleting lives here and not in the ⌃T menu**, which is the other place tags are edited. That
    /// menu acts on the selected *files*: every item there answers "which tags does this file wear?",
    /// and "Remove All Tags" strips the selection, not the tag. The tag *list* is what the sidebar
    /// shows, so the tag list is what the sidebar edits — the same split Finder draws.
    func buildTagMenu(_ menu: NSMenu, for tag: FinderTag) {
        menu.addItem(tagMenuItem("Find Tagged Files", #selector(findTaggedFilesItem(_:)), tag))
        // No Delete for the stock seven: `FinderTag.isSystem` covers why it could not do anything.
        // They are a constant, not a sighting, so the row would be back on the next rebuild.
        guard !tag.isSystem else { return }
        menu.addItem(.separator())
        menu.addItem(tagMenuItem("Delete Tag", #selector(deleteTagItem(_:)), tag))
    }

    /// One management item, carrying the tag itself. The saved-search menu carries a *name* so a
    /// store change under an open menu can't act on the wrong (index-shifted) search; a `FinderTag`
    /// already **is** its name — identity is the name, case-insensitively — so passing the value is
    /// that same protection, not a shortcut around it.
    private func tagMenuItem(_ title: String, _ action: Selector, _ tag: FinderTag) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = tag
        return item
    }

    @objc private func findTaggedFilesItem(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? FinderTag else { return }
        delegate?.sidebar(self, didActivateTag: tag)
    }

    @objc private func deleteTagItem(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? FinderTag, !tag.isSystem else { return }
        Task { await deleteTag(tag) }
    }

    // MARK: - Deleting a tag

    /// Delete a custom tag: strip it off every file carrying it, then forget the name.
    ///
    /// **Deletion has to be a search**, because a tag is not stored anywhere we could edit. It
    /// exists precisely because files carry it — `FinderTagProvider.known` accumulates tags by
    /// sighting, for want of any API for "the user's tags" — so the only way to make one stop
    /// existing is to take it off all of them. macOS does keep a list, in Finder's synced
    /// preferences, but that is Finder's business and not a contract; Spotlight is what we can ask.
    ///
    /// **So it is only ever as complete as the index.** A carrier on an unindexed volume keeps its
    /// tag, and browsing to it later brings the name back into the sidebar with no explanation.
    /// That hole is real, and it is the one Finder's own tag deletion has; closing it would mean
    /// walking every mounted filesystem on the off chance, which is not a trade worth making here.
    private func deleteTag(_ tag: FinderTag) async {
        let carriers = await SpotlightSearchRunner.paths(SpotlightQuery(tags: [tag.name]))
        // Nothing to rewrite, so nothing to confirm — the only effect is a name leaving a list, and
        // a sheet asking permission for that is asking about nothing. This is the *common* case, not
        // an edge: the tag list never forgets within a session (`FinderTagProvider.record`), so a
        // tag whose last file was just untagged sits in the menu carried by nothing at all, which is
        // exactly the state someone reaches for Delete Tag to tidy away.
        guard !carriers.isEmpty else {
            FinderTagProvider.shared.forget(tag)
            rebuild()
            return
        }
        guard await confirmDeleteTag(tag, carriers: carriers.count) else { return }

        let outcome = await strip(tag, from: carriers)
        guard outcome.failed == 0 else {
            // Forget nothing: a file still wearing the tag means the tag still exists, and dropping
            // it from the sidebar would be the list telling a lie that the next scan of that folder
            // would silently correct — the row reappearing on its own. The dots on the files that
            // *did* let go are fixed by their directory watcher; an xattr write is an FSEvent like
            // any other, which is why this doesn't have to reach into the panes itself.
            presentTagDeleteFailure(tag, outcome: outcome, carriers: carriers.count)
            return
        }
        FinderTagProvider.shared.forget(tag)
        rebuild()
    }

    /// Strip `tag` from every carrier off the main thread, and **keep going past a failure** —
    /// unlike the panel's `applyTagEdit`, which stops at the first one.
    ///
    /// The opposite rule, for the opposite situation. There, the targets are one selection in one
    /// folder: a failure on the first is almost certainly the same read-only volume the other 200
    /// will hit, so stopping is kind and a sheet per file would be unusable. Here the carriers are
    /// scattered across the disk and share nothing — one locked file says nothing about the rest —
    /// so stopping would abandon the deletion partway for the sake of the one file that was never
    /// going to work, and leave the tag alive on files that would have let it go.
    private func strip(_ tag: FinderTag, from carriers: [String]) async -> TagStripOutcome {
        await Task.detached(priority: .userInitiated) {
            var outcome = TagStripOutcome()
            for path in carriers {
                do {
                    try FinderTagStorage.remove(tag, from: .local(path))
                } catch {
                    outcome.failed += 1
                    outcome.firstError = outcome.firstError ?? VFSErrorText.sentence(for: error)
                }
            }
            return outcome
        }.value
    }

    /// Confirm before rewriting files, naming how many — so that deleting a tag can't quietly turn
    /// out to have been an edit of two hundred files the user never pictured.
    ///
    /// The count is why the search runs *before* this sheet rather than after it: a confirmation
    /// that can't say what it is about to do isn't much of a confirmation. One tag clause through
    /// `mdfind` answers in milliseconds, which is what makes that ordering affordable — no spinner,
    /// no progress, just a sheet that knows the number.
    private func confirmDeleteTag(_ tag: FinderTag, carriers: Int) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the tag “\(tag.name)”?"
        alert.informativeText = """
        It will be removed from \(carriers == 1 ? "1 file" : "\(carriers) files"), \
        everywhere Spotlight has indexed. The files themselves aren’t deleted.
        """
        alert.addButton(withTitle: "Delete Tag")
        alert.addButton(withTitle: "Cancel")

        return await runTagAlert(alert) == .alertFirstButtonReturn
    }

    /// Some files kept the tag. Say so with the count, rather than leaving the row in the sidebar
    /// looking like the delete simply did nothing.
    private func presentTagDeleteFailure(_ tag: FinderTag, outcome: TagStripOutcome, carriers: Int) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t fully delete “\(tag.name)”"
        let removed = carriers - outcome.failed
        alert.informativeText = """
        Removed from \(removed) of \(carriers) files. \(outcome.firstError ?? "")
        The tag stays in the sidebar because files still carry it.
        """
        Task { _ = await runTagAlert(alert) }
    }

    /// Sheet on the window, app-modal when there is none — `ErrorDialog.runAlert`'s shape, for the
    /// same reason it has one.
    private func runTagAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = view.window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Live updates

    func observeTagChanges() {
        // The preference: the section appears and disappears with the dots in the panes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showTagsPreferenceChanged),
            name: AppPreferences.showTagsDidChange,
            object: nil
        )
        // A scan: a tag used somewhere we had not looked yet joins the list without a relaunch.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(knownTagsMayHaveChanged),
            name: FinderTagProvider.didChangeNotification,
            object: nil
        )
    }

    @objc private func showTagsPreferenceChanged() {
        rebuild()
    }

    /// Rebuild only when the scan actually turned up a tag we had not rendered.
    ///
    /// This fires for **every** directory scan — which is every directory change, in either pane, on
    /// every tab — and the overwhelming majority discover nothing new. Rebuilding the whole sidebar
    /// each time would drop the user's selection on it for no reason at all; the same "is this a
    /// real change?" gate the server-activity observer applies.
    @objc private func knownTagsMayHaveChanged() {
        guard AppPreferences.shared.showTags,
              FinderTagProvider.shared.knownTagNames != renderedTagNames else { return }
        rebuild()
    }
}

// MARK: - Strip outcome

/// What one pass of `strip(_:from:)` did: how many files refused to give the tag up, and what the
/// first of them said. Counted rather than collected — the point is to tell the user the deletion
/// was partial, and a list of two hundred paths tells them that no better than the number does.
///
/// Declared at file scope, not nested in the controller, so it is plainly `Sendable`: it is returned
/// out of a detached task, and a type nested in a `@MainActor` class is a worse place to have to
/// reason about that from.
private struct TagStripOutcome: Sendable {
    var failed = 0
    var firstError: String?
}
