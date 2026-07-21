# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: M0–M7 shipped, M8 in progress, M9–M10 planned · Created: 2026-07-05 · Log: [docs/HISTORY.md](docs/HISTORY.md)

---

## 1. Product goals

**Must be true at 1.0:**

- Fully operable without a mouse. Tab switches panels, typing filters, F-keys drive
  operations, selection is independent of the cursor.
- File operations never block the UI. Everything runs through a background queue with
  progress, pause/resume, and conflict resolution.
- Feels native: Quick Look, Trash, drag-and-drop, dark mode, Finder tags, share sheet.
- Fast on ugly inputs: a 100k-entry directory opens and scrolls without jank.
- Undo works for file operations, not just text fields.

**Non-goals (for 1.0):**

- Windows/Linux ports.
- App Store distribution (sandbox is incompatible with a real file manager).
- An open binary plugin API (revisit post-1.0; automation hooks cover most needs).
- Cloud-provider integrations beyond what the filesystem already exposes
  (iCloud/Dropbox folders work as folders; no proprietary APIs).

## 2. Architecture decisions (locked unless proven wrong)

| Decision | Choice | Rationale |
|---|---|---|
| Language | Swift 6, strict concurrency | Native perf, actors fit the operation engine |
| File panes | AppKit `NSTableView` | 100k rows, total keyboard control; SwiftUI still weak here |
| Secondary UI | SwiftUI (settings, palette, dialogs, onboarding) | Velocity where perf doesn't matter |
| Core logic | `DirnexCore` — local SwiftPM package, zero AppKit imports | Testable headless; UI is a thin client |
| VFS | Protocol-based virtual filesystem from day one | Archives/SFTP become "just another backend"; retrofitting is painful |
| Watching | FSEvents (per-directory, coalesced) | Live panel refresh |
| Copy path | `copyfile()` with `COPYFILE_CLONE`, fall back to chunked copy with progress callbacks | Instant same-volume APFS copies |
| Delete | Trash via `NSWorkspace` by default; permanent delete behind a modifier | Safety first |
| Sandbox | None. Developer ID + notarization, distributed outside MAS | Needs Full Disk Access |
| Updates | Sparkle 2 | Standard for non-MAS apps |
| Min macOS | 14 (Sonoma) | Modern APIs, still covers the realistic user base |
| Persistence | JSON/plist for config; SQLite for frecency + undo journal | Boring and debuggable |

### Core abstractions

```
DirnexCore
├── VFS
│   ├── VFSBackend (protocol): list, stat, read, write, capabilities
│   ├── VFSPath: backend id + path within backend (composable: zip inside sftp)
│   ├── LocalBackend (M1) · ArchiveBackend (M4) · SFTPBackend (M5)
│   └── DirectoryModel: sorted/filtered snapshot a panel renders; FSEvents-driven
├── Operations
│   ├── Operation (copy/move/delete/rename/pack): source set → destination
│   ├── OperationQueue actor: serial-per-volume scheduling, pause/resume, ETA
│   ├── ConflictPolicy: ask / overwrite / skip / keep-both / newer-only
│   └── UndoJournal: reversible record per operation (SQLite)
└── Services
    ├── Frecency store · Favorites · History
    ├── Search (mdfind + streamed content grep)
    └── GitStatusProvider (M6)
```

**Rule:** the app target contains no file-manipulation logic. If it touches bytes,
it lives in `DirnexCore` and has tests.

## 3. Repository layout

```
Dirnex/
├── PLAN.md                     (this file: decisions + what's next)
├── docs/                       (NOTES.md gotchas · HISTORY.md M0–M7 log · RELEASING.md)
├── Dirnex.xcodeproj            (app target, thin)
├── Dirnex/                     (AppKit/SwiftUI app sources)
│   ├── Panels/                 (NSTableView pane, tabs, path bar)
│   ├── Palette/                (Cmd+K)
│   ├── Dialogs/                (conflicts, progress, multi-rename)
│   └── Settings/
├── DirnexCore/                 (SwiftPM package)
│   ├── Sources/DirnexCore/
│   └── Tests/DirnexCoreTests/
└── Tooling/                    (CI scripts, notarization, fixtures generator)
```

---

## 4. Milestones

Sizes are relative (S ≈ days, M ≈ 1–2 weeks, L ≈ 3+ weeks of focused work).
Each milestone ends in something runnable; no milestone depends on a later one.

### Shipped: M0 → M7 (2026-07-05 → 2026-07-20)

Seven milestones, all closed. The checklists and the full per-pass progress log —
46 entries of what was probed, decided, and rejected — live in
**[docs/HISTORY.md](docs/HISTORY.md)**; source comments citing `PLAN.md §M5` and the like
refer to those sections.

| | Milestone | Landed | Left deliberately undone |
|---|---|---|---|
| M0 | Scaffolding | 07-05 | — |
| M1 | Read-only dual-pane browser | 07-06 | — |
| M2 | Operation engine | 07-07 | Side-by-side text diff in the conflict dialog |
| M3 | Discoverability layer | 07-08 | SQLite stores (JSON is fine); per-workspace palette entries |
| M4 | VFS payoff | 07-12 | libarchive C-module gate (`bsdtar` instead); search tag chip + content-grep fallback |
| M5 | Network and sync | 07-14 | — |
| M6 | Mac-native power features | 07-19 | — |
| M7 | Release readiness | 07-19 | — |

The undone column is scope that was decided against, not forgotten — each one is argued in
its HISTORY.md entry. The newest such call is the **built-in compare view** (2026-07-20):
external diff tools stay the handoff until they prove a persistent disappointment rather
than an occasional one.

### Next

#### M8 — The sidebar as a first-class surface (M)

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

#### M9 — iCloud Drive, for real (M)

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

- [ ] **Dataless placeholder awareness** — an evicted file is a real on-disk stub `.<name>.icloud`
      that `readdir` sees; the M8 backend lists it under that literal name with the stub's tiny size,
      not the real name/size. Read the ubiquitous resource keys
      (`.isUbiquitousItemKey`, `.ubiquitousItemDownloadingStatusKey`, `.ubiquitousItemIsDownloadingKey`)
      to present the true name, size, and a download-state affordance. Probe how the keys read for a
      genuinely evicted item first — the M8 machine had none (everything downloaded), which is exactly
      why the stub-listing quirk never showed there.
- [ ] **Download on open** — opening or previewing an evicted item fires
      `FileManager.startDownloadingUbiquitousItem(at:)` and waits on the status key rather than handing
      a byte-less stub to the viewer. Pure progress state machine in the core (evicted → downloading →
      ready), the syscall and the wait in the app.
- [ ] **The merged app-container view** — the piece that makes the row match Finder. Union the sibling
      `~/Library/Mobile Documents/<container>/Documents` folders into the iCloud listing. Needs Full
      Disk Access (those `Documents/` are TCC-gated — probed) wired into the **M7 FDA flow**, and it
      cuts against §2's "a pane shows one real directory": decide the VFS shape — a `CompositeBackend`-
      style union keyed off a synthetic path (the NOTES.md lesson for browsing a second backend), or a
      virtual merged listing. Degrade to the M8 loose-files-only view when FDA is ungranted, never a
      dead row.
- [ ] **App-name / icon resolution** — Finder labels `com~apple~Pages` as "Pages" with the app's
      icon; a raw container id is not a name a user recognises. Probe where macOS keeps that mapping
      (LaunchServices, or the container's own `.com.apple.mobile_container_manager` metadata / a
      `.<app>.plist`) before wiring — do not guess the format.

Exit: the iCloud row shows what Finder's shows — loose files *and* the per-app document folders; an
evicted file downloads on open instead of opening empty; and a machine without FDA degrades to the
loose-files view M8 already ships, rather than an error.

#### M10 — Google Drive and Docs (L)

Reaching the user's Google Docs. Phased along the two depths that actually exist, cheap first
(decided 2026-07-21): browse the local File Provider mount, then a real Drive API backend for accounts
that aren't synced to this Mac.

**Phase 1 — the Desktop mount (no API, no OAuth).**

- [ ] **Browse the Google Drive for Desktop mount** — when the app is installed, Drive streams to
      `~/Library/CloudStorage/GoogleDrive-<email>/`, a real path readable **without** FDA (probed
      2026-07-21: the `CloudStorage` dir exists and lists free; the mount itself is absent here only
      because Google's app isn't installed). Surface it like the iCloud row: a sidebar row present when
      a `GoogleDrive-*` mount exists, browsed by the existing `LocalBackend` — no new backend.
- [ ] **Open `.gdoc` / `.gsheet` / `.gslides` stubs** — a Google-native doc on the mount is a tiny
      JSON file holding a `docs.google.com` URL, not bytes. Parse it (pure, core-tested) and open the
      URL in the browser instead of handing the stub to a text viewer, the way M4 hands off to external
      tools. Real (non-native) Drive files are dataless File-Provider items — the same download-on-open
      story as M9's iCloud, so that machinery is shared, not rebuilt.

**Phase 2 — a real Drive backend (for accounts not synced to this Mac).**

- [ ] **A `GoogleDriveBackend` VFS backend** — OAuth2 (loopback/PKCE installed-app flow, refresh token
      in the Keychain) + Drive API v3, mirroring the **M5 SFTP backend**: the non-hermetic HTTP
      transport in the app, the pure JSON parsing in the core behind an injected transport tested
      against a fake. `files.list` browses; `files.get?alt=media` downloads a binary file. Fits the
      Servers section's connect-an-account flow.
- [ ] **Native Docs export / import** — a Google Doc has no byte download; `files.export` converts on
      the way out (Docs→docx/pdf/odt, Sheets→xlsx/csv, Slides→pptx) and an import converts on the way
      in. Decide the default export format and whether to offer a picker.
- [ ] **The scope / verification decision (gates Phase 2 shipping)** — browsing a whole Drive needs the
      *restricted* `drive` (or `drive.readonly`) scope. Google grants it to file-manager-type UIs, but
      only behind restricted-scope verification **plus a paid annual CASA security assessment**; the
      narrow `drive.file` scope skips verification yet can't list pre-existing files, which is useless
      for a manager. Decided **before** Phase 2 starts, not during — it is a cost/distribution
      commitment, not a code choice. See Open questions.

Exit (Phase 1): a Google Drive row browses the Desktop mount and a Google Doc opens in the browser.
Exit (Phase 2): a Drive account connects from the Servers add-flow and its files browse, download, and
export without the Desktop app installed.

## 5. Cross-cutting: testing strategy

| Layer | Approach |
|---|---|
| DirnexCore | Unit tests against generated fixtures; every operation tested for: success, cancel mid-flight, permission denied, disk full, source mutated during op |
| VFS backends | One shared conformance test suite run against every backend (Local, Archive, SFTP-against-docker) |
| Undo journal | Property tests: op + undo == original tree (compare via content hash) |
| Panels/keyboard | XCUITest smoke for the keyboard core; snapshot tests for panel rendering states |
| Performance | XCTest metrics gated in CI: 100k-dir list < 150 ms, filter keystroke < 16 ms, memory ceiling on huge dirs |

## 6. Risks

| Risk | Mitigation |
|---|---|
| SwiftUI temptation for panels degrades perf later | Decision locked in §2; perf budgets in CI make regressions loud |
| Undo journal correctness (the scariest feature) | Property tests from M2 day one; non-reversible ops explicitly marked in UI, never silently dropped |
| FSEvents refresh fighting the cursor/selection | DirectoryModel diffs snapshots and reapplies cursor by identity, not row index; test with high-churn fixture |
| Archive writes corrupting user data | Always rewrite to temp + atomic swap; never in-place |
| Full Disk Access friction kills onboarding | Dedicated flow in M7; app degrades gracefully (browse home dir) before grant |
| Scope creep before the feel is right | M1 exit criteria are the gate; nothing from M3+ starts until M1 feels great |

## 7. Open questions

All four opened before M1 are closed — the first three by shipping and living in the result,
which was the stated way to decide them. Recorded because reopening one is a real design
change, not a free choice:

- **Space key** — TC's select+dir-size won over macOS's Quick Look. ⌘Y and a palette action
  carry Quick Look. Validated by use across M1–M7.
- **Quick view panel shortcut** — ⌃Q. ⌘Q is untouchable and ⌘⇧Q was free but less TC-like.
- **Tabs UI** — compact TC-style, auto-hiding at a single tab.
- **Name/brand check for "Dirnex"** — resolved 2026-07-19: the name is free, cleared by the
  user, no conflicting prior marks. The `NOTICE` / `TRADEMARKS.md` carve-out stands as written.

Opened and closed during M8:

- **Seeding an existing favorites** — resolved 2026-07-20: **standard places lead, existing pins
  follow.** The sidebar therefore looks unchanged on the launch after the merge, which matters more
  than the one thing it costs: a path pinned under a custom label ("Dl" for Downloads) is reclaimed
  as the standard row and loses that label. The alternatives were pins-first (nothing the user chose
  moves, but the sidebar's top rows change on update) and seeding fresh installs only (honest about
  ownership, but Home/Desktop/Documents visibly vanish on update). Still needs a one-shot "seeded"
  flag in `FavoritesStore`, so it is a real migration and not a first-run branch.

Open for M10 (Google Drive), still undecided:

- **Google OAuth scope for the Phase-2 backend** — the fork is `drive`/`drive.readonly` (restricted:
  browse the *whole* Drive, but Google requires restricted-scope verification **plus a paid annual
  CASA third-party security assessment** before a distributed build may use it) versus `drive.file`
  (unrestricted, no assessment, but limited to files the app itself created or the user explicitly
  picked — which cannot list a pre-existing Drive and so is useless for a file manager). This is a
  money-and-verification commitment, not a code choice, so it is decided before Phase 2 code starts.
  Phase 1 (the Desktop-mount browse) needs none of this and is unblocked. Recorded here because
  choosing `drive.file` to dodge the assessment would quietly gut the feature.
