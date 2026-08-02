# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: M0–M14 shipped (14 languages) · **M15 in flight** · Created: 2026-07-05 ·
Log: [docs/HISTORY.md](docs/HISTORY.md)

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
│   ├── LocalBackend (M1) · ArchiveBackend (M4) · SFTPBackend (M5) · FTPBackend (M13)
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
├── docs/                       (NOTES.md gotchas · HISTORY.md M0–M14 log · RELEASING.md)
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

### Shipped: M0 → M14 (2026-07-05 → 2026-08-02)

Every milestone through M14 is closed. The checklists and the full per-pass progress log —
what was probed, decided, and rejected — live in
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
| M8 | The sidebar as a first-class surface | 07-21 | Dragging a *remote* (SFTP) folder into the sidebar — stays menu-only; Recents ordered by modification date, not the true last-used stamp |
| M9 | iCloud Drive, for real | 07-21 | Per-item download percentage (macOS exposes none through the URL resource keys); Put Back inside the iCloud trash — the origin is an opaque provider reference with no path in it |
| M10 | Google Drive and Docs | 07-22 | A real Drive API backend (OAuth + Drive v3, native Docs export/import) — dropped 2026-07-22; sync status in Drive's *mirror* mode, which macOS exposes to no one but Finder |
| M11 | F4 Edit, and Quick View at full size | 07-22 (text preview 07-27) | A built-in text editor (F4 hands the file to the user's own); write-back for archive and SFTP files (edit-temp-watch-repack is its own slice); a slideshow timer or thumbnail filmstrip in the preview |
| M12 | Localization — 14 languages | 07-29 | The stock Finder-tag *names* in the ⌃T menu (`DirnexCore` `systemTagName` data); the AppleScript `.sdef` *terminology*, since renaming a verb breaks users' scripts (its error messages did translate); a lint rule keeping bare literals out of UI files (the repeated sweeps stand in for it); the "Results for Search results" stutter, a wording decision rather than a translation gap; RTL — none in the shipped set |
| M13 | FTP and FTPS | 07-25 | `MLSD` (`curl` cannot send it); FTP-side `DirectorySync` by timestamp (unreliable by construction — LIST stamps are year- and zone-less); write-back for files edited in place over FTP (the shared edit-temp-watch-repack slice); an opportunistic "TLS optional" client mode (a password-downgrade vector — rejected 2026-07-26) |
| M14 | Checksums and attributes | 07-30 (escalation 08-02) | Split/combine files (dropped 2026-07-29 — FAT32's ceiling, floppy/CD spanning and mail limits are all gone on macOS); multi-selection and recursive **privilege escalation** (the flat single-item path proves the mechanism; those sheets refuse a root-only change by name); escalating the *undo* of a non-owned change (still refused with `attributeRestoreNeedsAdministrator`, not escalated) |

The undone column is scope that was decided against, not forgotten — each one is argued in
its HISTORY.md entry. The largest such call is the **built-in text editor** (2026-07-22): a
real one is encoding detection, line-ending preservation, a binary gate, undo grouping and
find/replace — a whole app, and every Mac already has one the user has already chosen, so F4
hands the file over the way ⌥F3 hands two files to FileMerge. Revisit only if leaving the app
proves to break the keyboard-first flow, which is a claim to test by living with the handoff
first. The other big one is the **Drive API backend** (2026-07-22): the Desktop mount reaches
every Drive account that is actually on this Mac, and going past it would have bought a second,
worse path to the same files at the price of an OAuth flow, a restricted-scope verification and
a paid annual security assessment. It also lines up with §1's standing non-goal — cloud folders
are folders, no proprietary APIs.

M8 also closed with one deliberate deviation from its own exit criterion: **the Trash is a
merged listing, not a location** — macOS keeps one trash per volume, so the one sidebar row
that cannot be a directory browses like a *results* pane rather than like a folder. M9 closed
with a second: **"what Finder's iCloud Drive shows" is matched approximately, on purpose** —
which app containers Finder lists is not derivable from anything public, so Dirnex's rule is
declared public scope and a folder that exists. Both are argued in HISTORY.md. The *direction* of
that approximation was reversed on 2026-07-21 (see M10): it used to also require a
non-empty folder, which hid three folders Finder shows.

### In flight: M15 — The tree view, and colour the user chooses (M)

Goal: the file list gets a second *shape* and a palette the user owns. Everything through M14
decided what a pane shows; this decides how it looks and how deep it reaches. Opened 2026-08-02.

Four slices, each shippable on its own and ordered so the cheap visible wins land first. Slices 1–3
touch only the app; Slice 4 opens core-first (§2: a slice starts with purely additive, tested
`DirnexCore` files and lands in a second pass that wires the app).

#### Slice 1 — Row density, and view mode as tab state (S) — **landed 2026-08-02**

- [x] `AppPreferences.rowDensity` — compact / regular / roomy, app-wide like every other View
      toggle, with a change notification so open panes re-render live. `tableView.rowHeight` is a
      hardcoded 22 today. Settings ▸ Panels carries a segmented picker; `PanelViewController+Density`
      is the observer, shaped as the twin of `+Hidden` so there is one pattern for "an app-wide View
      preference a pane must follow".
- [x] `FileCellView`'s icon constraints follow it. They are hardcoded 16 pt `widthAnchor` /
      `heightAnchor` constants, and cells are recycled across a density change, so the cell is
      rebuilt rather than mutated. **Probed, and the answer inverted the plan:** `reloadData` empties
      `NSTableView`'s reuse pool outright — measured on a real 300-row table, every row after one is
      a fresh build even at an unchanged density — so a density change already hands out correctly
      sized cells and there is nothing to rebuild. That is undocumented and fails in the quiet
      direction, so the cell owns the invariant instead: `FileCellView.density` is re-applied on
      every render and moves the two stored constraints, which is provably correct whether the pool
      is purged or not.
- [x] `PanelTab.viewMode` (`.list` / `.tree`), persisted in `PersistedTab` beside `columns` — per
      *tab*, so one pane can be a tree while the other is a list. Note the precedent it must not
      copy: `isSizeVisualizationEnabled` is per-tab and **not** persisted, which is fine for a mode
      you switch on to answer a question; a tab restored into the wrong *shape* reads as data loss.
      Stored as the raw string, not the enum: a `Codable` enum throws on an unknown case and the
      throw takes the whole `PersistedTab` with it, so a shape written by a newer build would drop
      the tab out of the session rather than merely be ignored.

Exit: density changes live in both panes and survives relaunch; `viewMode` round-trips through
persistence with `.tree` still rendering as `.list` (nothing reads it yet). **Met** — verified live
against the real binary with a temporary `NSLog` of the measured row rects and icon frames (never
off a screenshot, NOTES.md ▸ Live verification): both panes moved together to 28/20 and 18/14 with
`cursorRow` preserved across every change, the density came back after a relaunch, and a
hand-written `viewMode: "tree"` was restored into the tab and re-persisted while the other pane
stayed `.list`.

Geometry, measured rather than picked: the floor is the **text**, whose intrinsic height at the
system font is exactly 16.00 pt (bold included — a marked row draws bold). So the three steps are
18/14, 22/16 and 28/20, with `.regular` reproducing the shipped pane byte-for-byte.

#### Slice 2 — A palette the user owns (S–M) — **landed 2026-08-02**

Three colours, each defaulting to **Follow System**, so an untouched install renders exactly as it
does today and the default path stays AppKit's own drawing:

- [x] **Accent** — overrides `.controlAccentColor` at the path bar, the tab chips and the update
      indicator. Framed in Settings as an override, because macOS already ships this control
      (System Settings ▸ Appearance ▸ Accent) and `.controlAccentColor` already follows it.
- [x] **Cursor** — the row background. The sharp one: AppKit draws the emphasized selection, so a
      custom colour needs an `NSTableRowView` subclass that draws its own. **Probed, and the answer
      simplified the plan:** when the delegate declines to supply a row view, `NSTableView` makes a
      plain `NSTableRowView` — in every one of its five styles — so a subclass that hands the call
      to `super` is byte-for-byte the shipped drawing, and `PanelRowView` is installed
      *unconditionally* rather than only when a colour is set. Switching classes as the preference
      changes would leave a reuse pool of the other kind to reason about; deferring leaves nothing
      to get wrong.
- [x] **Mark** — today's hardcoded `.systemRed` in `FileCellView`. Unlike the selection blue this
      one was always Dirnex's decision rather than the system's, which is what makes it the most
      worthwhile of the three.
- [x] Two sites currently assume the system blue and must take a **derived** foreground instead:
      `FileCellView.applyStyle`'s `.alternateSelectedControlTextColor`, and `SizeBarView`'s
      `isEmphasized` branch, whose own comment names it as the only fill that survives the blue.
      Derive by luminance — never let the user pick the foreground, or the first custom colour
      makes the cursor row unreadable. **The rule is "white unless it drops below 3:1", not
      "whichever contrasts more"**, and the measurement is what settled it: `.controlAccentColor`
      is L=0.2114, where white scores 4.02:1 and black 5.23:1 — so maximum contrast picks *black*,
      while macOS and Dirnex's own tab chip draw white. See NOTES.md ▸ AppKit.
- [x] Keep the emphasized/unemphasized split. NOTES.md ▸ AppKit: grey-versus-blue is AppKit saying
      the focus moved, and it is the signal the *rows themselves* carry (the path bar and tab chips
      say it separately, via `updateActiveAppearance`). Flatten the two and both panes' cursors look
      identical, which reads as permanently unfocused. Measured, the unemphasized selection is a
      *pure grey* in both appearances (`#DCDCDC` / `#464646`, zero saturation) and in dark mode is
      **darker** than the emphasized fill rather than fainter — so there is nothing to derive, and
      only the emphasized half is drawn here.

Deliberately not themable: Finder tag dots (they have to match Finder's own colours), git status
colours, sync badges. Those are information, not decoration. All of this is presentation and lives
in the **app**, not the core (NOTES.md ▸ Localization: a presentation decision in the core is a
string that can never be translated — the general form is that the core picks the state and the app
picks the pixels), tested in `DirnexTests` the way `SyncBadgeTests` already is. Colours persist as
hex in `UserDefaults`, per §2's "boring and debuggable".

Exit: a non-default cursor colour renders legibly in both appearances, the inactive pane still reads
as inactive, and Follow System restores byte-identical rendering. **Met** — verified live against
the real binary with a deliberately pale cursor (`#FFD60A`): the name, size, date, the ncdu bar, its
track and its percentage all flipped to black on it, a marked row under the cursor stayed bold and
legible, the inactive pane kept AppKit's grey, and Settings ▸ Use System Colours restored the blue
cursor, the blue crumb, the white-on-blue chip and the titlebar indicator live, without a relaunch.
Legibility in the *other* appearance is a claim no single screenshot can make, so it is pinned by
construction instead: the derivation is a luminance test over the user's own sRGB colour, measured
identical under `.aqua` and `.darkAqua` and asserted in `PanelPaletteTests`.

`PathBarView` hit SwiftLint's 500-line ceiling in this slice and was split by *concept* rather than
shaved (CLAUDE.md ▸ file splitting): `PathBarView+Editing` takes the Cmd+L text field, its
completion cache and the `NSTextFieldDelegate` conformance, leaving the crumb row behind.

#### Slice 3 — Colour rules by file type (M)

Total Commander's signature: an ordered list of glob → colour rules, first match wins. Order is
meaning, so the list is never silently canonicalized — the same rule an ACL's entry order follows.

- [ ] Core: `FileColorRule` + `FileColorRules.firstMatch(for:)`, pure and tested, over the same
      `Glob` that `+`/`-` pattern select already uses. The colour rides as user *data* (hex), not as
      a decision the core authored — the `FinderTag` split, where the core carries the colour and
      the app maps it to pixels.
- [ ] Precedence, made explicit rather than reusing the existing slot: `FileCellView.accentColor`
      currently *outranks* the mark (a marked modified file still shows its orange git `M`), and a
      type colour has to rank **below** it — a marked file must stay unmistakably marked. Resolution
      becomes git status → mark → type rule → label colour.
- [ ] Settings editor: add / remove / reorder with a live preview row, stored beside the user
      scripts.

Exit: `*.jpg` draws teal in both panes and survives relaunch; a marked `.jpg` still reads as marked;
a modified `.jpg` inside a repository still shows its git letter.

#### Slice 4 — The tree (M–L, core-first)

An inline-expanding file list: folders open in place and show their children indented, files
included.

- [ ] Core, additive: `TreeProjection` — a pure flattening of a set of expanded directories into one
      indexed row list of `(entry, depth)`, sorted **within each level** and hidden-filtered like the
      flat model. Tested for expand/collapse, a folder that vanishes while expanded, a filter that
      empties a level, and sort applying per level rather than globally.
- [ ] The shape is the **sidebar's**, deliberately: an `NSTableView` over a flat projection, not an
      `NSOutlineView` (HISTORY.md §M8 — "every row is a leaf, so folding is a build-time filter, not
      a view feature — and the drag code keeps one flat index space to map through"). That is the
      whole reason this slice is affordable: columns, the git gutter, the size bar, marks (already
      keyed by `VFSPath`), inline rename, drag/drop and the Quick View overlay all keep working
      against one index space, unchanged.
- [ ] Expansion state per tab (`Set<VFSPath>` in `PanelTab`, persisted), listed lazily on expand
      under the existing `loadToken` stale-guard.
- [ ] **One** `DirectoryWatcher` over the whole expanded set, not one per folder: `FSEventStreamCreate`
      takes an array of paths (NOTES.md, the merged-listing lesson), and the stream is rebuilt only
      when the *set* changes — rebuilding per event tears down the thing that delivered it.
- [ ] Keys reuse the sidebar's vocabulary rather than inventing a second one
      (`SidebarViewController+Keyboard`): **→** expands a closed folder or steps into an open one,
      **←** collapses an open folder or steps out to its parent. Space still marks, ⏎ still opens.
- [ ] Two things the flat model owns that a tree breaks, both answered *in* the slice:
      `SizeVisualization(model:)` projects one directory's siblings, so the bars are either scoped
      per level or withdrawn in tree mode; and every tree refresh path keeps the
      `installSortedModel` → `reloadEverything` → `syncCursorToTable(scroll: false)` tail, each half
      of which NOTES.md records as a bug found live.

Exit: two folders expanded in one pane, files marked across all three levels and copied with F5; the
tree survives an FSEvents change in a collapsed sibling; relaunch restores the expansion.

#### Two decisions to settle before Slice 4 opens

Both are operation semantics, not view work, which is why they cannot be deferred into it:

1. **What F5/F6 do with marks spanning levels.** Recommendation: TC's branch-view behaviour —
   flatten *preserving relative paths* under the destination. Copying everything flat into one
   folder is the alternative and it silently collides the moment two folders hold an `x.jpg`.
2. **F8 with an ancestor and its descendant both marked.** Recommendation: dedupe to the ancestor
   before enqueuing. Deleting the parent already takes the child, so passing both makes the second
   operation fail on a path that no longer exists.

#### Deliberately not in scope: the thumbnail grid, brief view, and the surface extraction

Cut 2026-08-02. The three are one unit, and the reason is worth writing down because it is not
obvious from the outside: `FileTableView` is not a view but a **contract** — 25 `FileTableViewInput`
methods, plus drag-out, drop, inline rename, the context menu's row mapping, and the cursor⇄selection
mirror (`syncCursorToTable` / `reconcileCursorFromTable`) that assumes *row == entry*. A grid
satisfies none of it, so a second surface must first extract that contract into a shared `PaneSurface`
protocol — otherwise there are two definitions of what an arrow does, which NOTES.md already records
as a mistake in a smaller form. Brief view was only ever justified as a free rider on the grid
thumbnails would have paid for; with thumbnails out it carries the whole extraction alone, to show
names in columns. So M15 needs no second surface at all, and stays four additive slices on the table
that already exists.

Two things to keep, for whenever the grid is revisited: a thumbnail sweep must skip
`FileEntry.isDataless` rows (a grid over an iCloud or Drive folder would otherwise download the
user's cloud drive by scrolling — NOTES.md measured 1.1 s to materialize 200 KB) and fall back to
type icons on every remote backend, where a thumbnail is a network transfer. And the column header
is currently the only sort UI, so a grid has to move sort to the View menu first.

## 5. Cross-cutting: testing strategy

| Layer | Approach |
|---|---|
| DirnexCore | Unit tests against generated fixtures; every operation tested for: success, cancel mid-flight, permission denied, disk full, source mutated during op |
| VFS backends | One shared conformance test suite run against every backend (Local, Archive, SFTP-against-docker, FTP/FTPS against an injected fake transport fed real captured bytes) |
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
| A system-CLI quirk changes under us (M13's TLS-1.2 pin for FTPS is a workaround for `curl` 8.7.1, not a property of the protocol) | The flag lives in a pure, tested `FTPProcessArguments` with the reason in its doc comment, so it is one place to re-measure — and a listing that comes back empty is the *symptom*, so an FTPS smoke test asserts non-empty rather than merely "no error" |
| M15's tree becomes a *second* pane implementation by accretion — a refresh path, a mark gesture or a sort that quietly forks from the flat one | The tree is a flat projection over the same `NSTableView` and the same index space, not a parallel surface (§M15 Slice 4); anything that forks is a signal the projection is wrong, not that the tree needs its own copy. The known fork points are named in the slice — `SizeVisualization`'s per-directory assumption and the `installSortedModel` → `reloadEverything` → `syncCursorToTable` tail |

## 7. Open questions

**Open now:** M15 carries two, both about what a *marked set spanning directories* means for an
operation — F5/F6's destination layout and F8's ancestor/descendant overlap. They are written where
the work is, under §M15 "Two decisions to settle before Slice 4 opens", with a recommendation each;
they are listed here so the section stays the index of what is actually undecided.

All four opened before M1 are closed — the first three by shipping and living in the result,
which was the stated way to decide them. Recorded because reopening one is a real design
change, not a free choice:

- **Space key** — TC's select+dir-size won over macOS's Quick Look. ⌘Y and a palette action
  carry Quick Look. Validated by use across M1–M8.
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

Opened and closed during M10:

- **Google OAuth scope for a Drive API backend** — resolved 2026-07-22 by **not needing one.** The
  fork was `drive`/`drive.readonly` (restricted: browse the *whole* Drive, but Google requires
  restricted-scope verification **plus a paid annual CASA third-party security assessment** before a
  distributed build may use it) versus `drive.file` (unrestricted, no assessment, but limited to files
  the app itself created or the user explicitly picked — which cannot list a pre-existing Drive and so
  is useless for a file manager). Dropping the API backend drops the question with it: the Desktop
  mount browses through `LocalBackend` with no OAuth, no scope and no assessment. Reopening it means
  taking on the whole verification commitment, which is why it stays written down.

Opened during M13 planning (2026-07-25) and **closed** in it (both by the user, 2026-07-25; the
security posture revisited and re-confirmed 2026-07-26):

- **How much of FTP's insecurity is Dirnex's to editorialize about?** — resolved: **default the
  connect form to FTPS and make plain FTP the deliberate switch**, with no per-connect nagging. It
  costs nothing when the server supports FTPS and states the tradeoff exactly once, where it is
  actionable; the failure mode to avoid — a warning firing on every connect to a decade-old NAS — is
  avoided. The corollary was settled 2026-07-26: **no opportunistic "TLS optional" client mode.** The
  three explicit modes reach every server, and `--ssl`'s silent fall-back to cleartext is a
  password-downgrade vector, so `FTPProcessArguments` requires the upgrade (`--ssl-reqd`). A mismatch
  is surfaced as a clear, actionable error (`tlsNotAvailable` / `tlsRequired`), never guessed around.
- **Whether `curl`'s progress output is good enough for the queue, or transfers need chunking.** —
  resolved: **one exact byte count per file**, via `-w '%{size_download}'` / `'%{size_upload}'`, which
  matches what `SFTPProcessTransport` ships and hands the queue its delta directly. `curl`'s live meter
  was measured at ~1 Hz rounded to `k`/`M` — good for a bar, not for accounting — so an intra-file
  determinate bar is deferred as a thing worth doing for both remote backends together or not at all.
