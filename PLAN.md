# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: M0–M7 shipped, M8 planned · Created: 2026-07-05 · Log: [docs/HISTORY.md](docs/HISTORY.md)

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
    ├── Frecency store · Hotlist · History
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
**Favorites** section nobody can touch, while the *actual* user-owned pin list — `Hotlist`,
with add/remove/rename/reorder already tested in core — hides behind Ctrl+D and a modal
organizer. Two competing concepts, and the personalizable one is invisible. M8 collapses
them into one, then earns the sections that follow.

- [x] **Merge the hotlist into the sidebar's Favorites section** — the pin list *becomes* the
      section, seeded on first run from `SidebarLocations.favorites()`. That is Finder's own model:
      user-owned, seeded with the standard folders, any of them removable. Retires the modal
      organizer; keeps the Ctrl+D menu's bare 1–9 jumps, which are the keyboard half of the feature
- [x] **Drag to reorder** — `Hotlist.move(from:to:)` is already core-tested, and
      `HotlistOrganizerController` already demonstrates the `NSTableView` reorder pattern to lift.
      Favorites only: Volumes is a mount-table snapshot re-sorted on every mount event, so a user
      order has nowhere to live
- [x] **Drag folders in from a pane** — panes already write `.fileURL` to the pasteboard, so
      pane → sidebar is a `registerForDraggedTypes` plus ~~`Hotlist.add`~~ **`Hotlist.insert(_:at:)`**
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
- [ ] **iCloud Drive row** — `~/Library/Mobile Documents/com~apple~CloudDocs`, a real directory
      (probed, present). Probe how dataless `.icloud` placeholder stubs list before wiring: size
      and download-on-access is the part that surprises
- [ ] **Trash row** — cheaper-looking than it is. `~/.Trash` reads back `Operation not permitted`
      without Full Disk Access (probed), so it needs a graceful un-granted state tied to the M7 FDA
      flow. Trash is also per-volume (`/Volumes/X/.Trashes/$uid`), so a single row is a lie on a
      multi-drive setup; "Put Back" has no public API; and delete-inside-Trash must invert the
      default move-to-Trash semantics or it is a no-op loop
- [ ] **Recents row** — Finder's is a saved search, and saved searches already render into virtual
      result panels, so this reuses machinery instead of adding some

Exit: a folder dragged from a pane lands in the sidebar, is dragged into position, survives a
relaunch, and is reachable from the keyboard; iCloud Drive and Trash browse like any other location.

Progress (2026-07-20, M8 pass 1 — the merge's ordering rules): the pure, tested half of the
Favorites merge landed, the same core-first opener every M4/M5/M6 slice used. **Box stays `[ ]`** —
no store flag, no sidebar section, no app wiring yet; this is only the model. One new core file
plus two additive functions, so the app is untouched and needed no rebuild (its suite was run
anyway, since the core it links changed).

- **`Services/HotlistSeeding.swift`** — `Hotlist.prepend(_:)`, the seed-vs-pins ordering rule, and
  `HotlistEntry(place:)`. `prepend` does **not** reimplement de-duplication: `init(entries:)`
  already collapses duplicate paths keeping the *first* occurrence, so prepending and
  re-initializing yields the decided semantic (seed wins, at the seeded position, under the seeded
  name) out of the rule that already existed. It returns whether the list actually changed, so the
  app can skip a needless write. `HotlistEntry(place:)` exists because the generic
  `HotlistEntry(path:)` derives its label from the path's last component — which for `/Users/oleg`
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

- **`HotlistStore`** — gained `didChangeNotification` (posted on save, matching `SavedSearchStore`)
  and `seedStandardPlacesIfNeeded()`, called from `applicationDidFinishLaunching` before any window
  builds a sidebar. The seeded flag is set **even when the merge changes nothing**, so the migration
  is genuinely once: a fresh install whose `~` has no Desktop yet must not quietly re-seed on some
  later launch.
- **`SidebarViewController`** — `Row.place(FavoritePlace)` became `Row.favorite(HotlistEntry)`;
  `rebuild()` reads `HotlistStore`. The Favorites header is now rendered **even when the section is
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
was actually in it): the migration ran against a hotlist that already held one pin, `Dev`, and
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

- **`Hotlist.insert(_:at:)`** (core, tested) — the drop half, where `move` is the reorder half.
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
  coordinates while `Hotlist.move` takes a destination in the resulting list. Both directions were
  driven live for exactly this reason — an upward move is unaffected by the adjustment and would
  have passed either way.
- Room for all this came from *removing* code: the saved-search and server cell rendering moved into
  the companion files that already own those sections, taking the main file from 494 to 453.

Live verification: `Dev` dragged from last position to second and back, landing exactly where the
insertion line showed each time; `~/Public` dragged in from a pane and pinned; a **file** dragged
over the sidebar drew no insertion line and pinned nothing. The store finished byte-identical to
how it started. ⌃D still lists the same rows with 1–9 intact and no gap where "Organize Hotlist…"
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

- **Seeding an existing hotlist** — resolved 2026-07-20: **standard places lead, existing pins
  follow.** The sidebar therefore looks unchanged on the launch after the merge, which matters more
  than the one thing it costs: a path pinned under a custom label ("Dl" for Downloads) is reclaimed
  as the standard row and loses that label. The alternatives were pins-first (nothing the user chose
  moves, but the sidebar's top rows change on update) and seeding fresh installs only (honest about
  ownership, but Home/Desktop/Documents visibly vanish on update). Still needs a one-shot "seeded"
  flag in `HotlistStore`, so it is a real migration and not a first-run branch.
