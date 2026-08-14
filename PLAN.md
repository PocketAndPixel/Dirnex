# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: M0–M19 shipped (14 languages) · **nothing in flight** · Created: 2026-07-05 ·
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
├── docs/                       (NOTES.md gotchas · HISTORY.md M0–M19 log · RELEASING.md)
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

### Shipped: M0 → M19 (2026-07-05 → 2026-08-09)

Every milestone through M19 is closed. The checklists and the full per-pass progress log —
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
| M15 | The tree view, and color the user chooses | 08-02 | The **thumbnail grid, brief view and the `PaneSurface` extraction** (cut 2026-08-02 — the three are one unit, and `FileTableView` is a 25-method contract a grid satisfies none of); a memo in front of `fnmatch` (measured unnecessary — 0.46 ms per full reload for 5 rules); size bars in tree mode, withdrawn at close and re-scoped per parent directory in a follow-up (`SizeVisualization(tree:)`) |
| M16 | Quick View: source or page | 08-06 | Markdown and RTF as dual-style types — markdown was taken up at M18, RTF stays undone — and `.webarchive` / `.mhtml`, which need `loadData` rather than a file load; the JavaScript mark in the *pane*-size preview, which has no header to carry it |
| M17 | Syntax highlighting in Quick View | 08-06 | A **theme picker** (the colors are a fixed light/dark table, no Settings surface); the constructs a regex-free single pass cannot reach — string interpolation, JS regex literals, heredocs, Swift raw strings, JSX, and semantic coloring of any kind; **line numbers, folding and a minimap**, which are editor features Dirnex hands to the user's own editor; highlighting inside the *rendered* HTML style, which is the page's own business; a **key-vs-value** distinction in JSON, and Markdown's **setext headings** and **indented code blocks**, all three of which need a lookahead or a previous line the single pass does not keep; Ruby's `=begin` block comment; and any third-party highlighter — Highlightr (a JS engine on every cursor step) and tree-sitter (a C dependency plus a grammar per language), both rejected 2026-08-06 |
| M18 | Quick View: Markdown as a document | 08-07 | **Raw HTML passthrough** — CommonMark says to pass it and a preview that renders on *cursor movement* must not, which is also what keeps the generated page inert; **full CommonMark conformance** (the target is what the file's author sees on GitHub for an ordinary document, pinned by a corpus of real files, with an unreadable construct rendering as its literal text); **math and LaTeX, footnotes, definition lists, emoji shortcodes and wiki links**; every mermaid diagram type outside **flowchart and sequence** (a class diagram, gantt, state chart or ER diagram falls back to a code fence naming itself, as does an unsupported construct *inside* a supported type); **following a link to another file**, since turning a preview into a browser needs its own history and its own way out; **RTF**, the other type M16 left in the same sentence — `NSAttributedString`'s job, sharing nothing with a renderer; **rendering as you type** and editing of any kind (§M11's call, unchanged); and **exporting the rendered page** to HTML or PDF, which is a file operation and belongs in the operation engine with a destination and a conflict policy |
| M19 | Encryption | 08-09 | **`zipcrypt` and AES-128** (the first is broken, the second buys nothing on hardware AES — both taken at open); **encryption for any container but zip**, since libarchive's 7-Zip writer refuses it and tar has no notion of it; **a passphrase for the paths that are not F5** — preview and *nested*-archive entry failed with `passphraseRequired` rather than prompting, and the encrypted route extracts the whole archive rather than the requested members, so a member filter plus a per-archive passphrase held for the session is its own slice (the passphrase half **landed 2026-08-09**, user-reported — see §4 ▸ After M19; the member filter is still open); **encrypting in place**, or any gesture that removes the plaintext afterwards, because that delete belongs to the user with the Trash's own rules in view; and **vault paths in anything the user saved on purpose** — a named workspace or a favorite pointing inside a vault is kept, since §6's rule is about what Dirnex remembers *without being asked* (the derived-data clause itself was closed 08-09 by fixing the frecency index and session restore, not by stating the leak — see HISTORY.md §M19 ▸ Follow-up) |

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

### M20 — Every place reachable without the sidebar (S, opened 2026-08-12, all three slices landed 2026-08-12)

M8 made the sidebar "a first-class surface", and for most of what it holds it is the *only* surface.
With it collapsed — ⌃⌘S, or simply a user who wants the width for two panes — an audit of what is
still reachable reads:

| Place | With the sidebar hidden |
|---|---|
| Favorites | ⌘F and Go ▸ Favorites… |
| Volumes, cloud mounts | only by typing the path into ⌘L |
| iCloud Drive | unreachable — the row dispatches a *merge*, so there is no path to type |
| Vaults | only while the image is under the cursor (`vaultImageUnderCursor`) |
| Servers | Connect to Server… opens a **new** connection; the saved list is sidebar-only |
| Saved searches, tags, Recents, the Trash | unreachable — none is a directory, and none has a command |

Six of the nine have exactly one way in. That is the shape docs/NOTES.md records for the vault a pane
could not open — *a feature whose entire surface is one control* — and the fix is the same: give the
knowledge more than one face without giving it more than one definition.

**Not the root crumb.** The gesture this opened on was a menu hung off the path bar's "Macintosh HD",
and it is the wrong anchor for three reasons that are all in the code. `installVirtualLabel` replaces
the **whole** crumb row for the Trash, Recents, search results and the iCloud merge — the very places
you most want to leave — so the control would be absent exactly where it is needed; `rebuildCrumbs`
takes its `rootTitle` as a parameter and an archive trail spans backends, so "Macintosh HD" is not
even a reliable leading crumb on a real path; and a left-click there already navigates to `/`, with
the right-click reserved for Copy Path. It is also mouse-only, in an app whose sidebar is most often
hidden by someone working from the keyboard.

**One funnel, three faces.** The funnel is the point: `SidebarViewController.rebuild()` already
assembles every section in one place and `activate(rowAt:)` already knows the rules a menu would
otherwise re-derive — a vault *dispatches*, a tag *searches*, iCloud *merges*, a server *connects*,
and only four of the ten cases are path navigation at all. A second list would drift from it, which
is this codebase's most repeated finding.

**Slice 1 — core, landed 2026-08-12.** Purely additive; the app is untouched and did not rebuild.
8 new tests, 2056 total green, both linters clean. `SidebarPlace`, `SidebarPlaceGroup`,
`SidebarPlaceSources` and `SidebarPlaces.groups(from:)` — the ordered assembly as a pure value over
the stores' contents. Every model it names already lives in the core (`FavoriteEntry`,
`MountedVolume`, `VaultLocation`, `CloudStorageMount`, `SavedSearch`, `ServerConnection`,
`FinderTag`, `SidebarSection`), so this is §2-shaped rather than a concession, and the sections come
in `SidebarSection.allCases` order off a switch that stops compiling if a section is added and not
placed. The rule the whole slice exists to hold: **folding is not an input**, because whether a
section is collapsed is a state of the sidebar's table and not of the list — building the menu from
`SidebarViewController.rows` would have silently omitted whole sections, since `append` drops a
collapsed section's items. A test pins that every populated section survives; the negative controls
(a reversed section order, a neutered empty-header rule) fail exactly the tests that name them. Tags
arrive already withdrawn when View ▸ Show Tags is off — a preference about the feature, not something
to second-guess downstream — and "All Tags…" is deliberately absent, being a disclosure affordance of
a scrolling list rather than a destination, so the menu will list every known tag instead.

**Slice 2 — the app: Go ▸ Places, landed 2026-08-12.** 6 new app tests, 339 total green, 2056 core,
both linters and all three CI scripts clean, verified live. `rebuild()` is re-expressed over
`SidebarPlaces.groups(from:)`, rendering folding, headers, the spacer and the All Tags row on top of
it; `PlacesMenu` renders the same groups as a submenu per section; and one `activate(_ place:)` funnel
is what both a row and a menu item dispatch through. Always present whatever the sidebar is doing.

*Corrected 2026-08-12 (Slice 3):* this slice also claimed the menu made "Trash" findable through
macOS's Help ▸ Search. It does not — **Dirnex declares no Help menu**, so the search field that
indexes menu items does not exist in this app. Checked by looking at the running menu bar; the claim
had been written into the plan and `PlacesMenu`'s doc comment without it. Nothing rested on it. Adding
a Help menu is its own decision and is not taken here.

Three things the slice turned out to need beyond the plan:

- **`SidebarViewController.Row` was a second copy of the vocabulary** — it spelled out all ten
  destinations — so leaving it would have made the milestone add a *third* spelling of the list
  rather than consolidate. It is now `case place(SidebarPlace)` plus the three pieces of chrome a
  *table* adds (header, spacer, All Tags). Its accessors (`favorite`, `savedSearch`, `server`,
  `vault`, `tag`, `path`) are unchanged, so most call sites never noticed; the drag code, the cell
  builders and the context menu are the ones that moved.
- **`SidebarPlacePresentation`**, because the name and glyph were a drift surface the plan had not
  counted: "Recents", "Trash" and "iCloud Drive" are *translated literals*, and a display string that
  exists twice gets localized once. Naming lives there for both renderers; how a glyph is finally
  drawn stays with each, since a 32 pt source-list row and a menu item want different renderings.
  Transcribing the standard-place symbols turned up the value of doing it — `square.grid.3x3` for
  `square.grid.3x3.fill` was one character and would have shown up as a slightly wrong Applications
  icon in one of the two surfaces.
- **A fresh `NSMenu` per menu-bar rebuild, with one long-lived delegate.** An `NSMenu` can be the
  submenu of only one item, and `MainMenuBuilder` rebuilds the whole bar whenever a key binding or the
  language changes — so handing the same menu object to each new Go menu would attach one that still
  has a supermenu. `NSMenu.delegate` being weak is what makes the reverse arrangement the right one.

Two new strings across the 14 languages (`Places`, `Nothing Here Yet`); the section titles were
already localized, which is the payoff of `SidebarSection` carrying identity rather than text.
Verified live with the sidebar hidden: Places lists Recents, the six populated sections and the Trash
in the sidebar's own order, a volume opens the pane at `/`, the Trash opens as its own tab (the
destination that had no route at all before), and the Vaults submenu draws the shut and open padlocks
the sidebar draws for the same two vaults. Tags was toggled on to check the one section whose
contents deliberately differ — the menu lists every tag with its colored dot, where the sidebar shows
the stock seven behind "All Tags…" — and toggled back off.

**Slice 3 — the keyboard and the mouse, landed 2026-08-12.** 5 new app tests (344 total), 1 new core
test (2058), both linters and all three CI scripts clean, verified live with the sidebar hidden.
`go.places` (⌘G — ⌃G as shipped that day; see below) pops the same menu under the focused pane's
path bar, structurally the
`showFavorites` popup; and the path bar's **leading glyph slot** — which both render paths already
had, `installCrumbs(leadingSymbol:)` and `installVirtualLabel(symbolNamed:)` — is now an
always-present button onto that menu, so the mouse affordance exists in every mode including the
virtual ones the root crumb cannot reach. `PlacesMenu.shared` is the one builder all three faces fill
from, which `NSMenu.delegate` being weak already required of *something*.

The chord was free in the way that matters and was measured rather than assumed: Cocoa's
`StandardKeyBinding.dict` binds `^b`, `^d`, `^e`, `^f`, `^k`, `^n`, `^p`, `^t`, `^v` and `^y` in every
text field and **no `^g`** — so unlike the ⌃D popup beside it, this one needed no field-editor
carve-out and could mean one thing everywhere.

**The pair moved to ⌘F / ⌘G (2026-08-12).** Favorites is ⌘F and Places ⌘G; ⌃D and ⌃G are free. The
measurement above is what the ⌃-layer choice rested on and it still stands — it is simply no longer
load-bearing, because the text system claims no ⌘ letter of its own, so *neither* popup needs a
carve-out now. `validateNavigationItem`'s `showFavorites` case, which existed only to let ⌃D fall
through to `deleteForward:`, went with it; ⌃T's carve-out stays, since ⌃T still transposes. The
price of the new pair is stated rather than hidden: ⌘F/⌘G are macOS's Find / Find Next, so a user
reaching for Find gets Favorites. Nothing in Dirnex claimed them — the file search is ⌥F7 and the
app declares no Find menu — but a later search or filter feature cannot have them back.

Two things the slice turned out to need beyond the plan:

- **The Go menu carries *two* Places entries, and has to.** An `NSMenuItem` that carries a submenu
  **never fires its own key equivalent** — measured in a throwaway: `performKeyEquivalent` returns
  `false` and the action never runs, while the item still reports `isEnabled == true`, and the same
  item without a submenu fires. The menu bar is this app's only dispatch path for a command shortcut,
  so hanging ⌘G on `Places ▸` would have drawn a shortcut that is dead. `Places ▸` (browse it there)
  and `Places…  ⌘G` (drop it at the pane) are therefore two items for two gestures, which is also
  what `go.favorites` has always been. Pinned against the **built menu**, not against
  `commandItem(for:)` — a negative control showed the isolated item stays well-formed after the
  layout stops containing it.
- **A glyph for the locations that had no kind.** The slot only appeared for a location with a mark
  of its own (cloud, iCloud, Trash, Recents, search); a plain local path, an archive trail and a
  connected server had none. `rootSymbolName(for:)` names those: the saved-server row's own symbol by
  protocol, and the **boot volume's** for anything local — not a guess about the disk, since
  `rebuildCrumbs` titles the root crumb "Macintosh HD" for every local path, `/Volumes/…` included.
  `MountedVolume.internalSymbolName` exists so that is one string rather than two, and
  `serverSymbolName` widened from `private` for the same reason.

Swapping the slot's `NSImageView` for a borderless `NSButton` was measured before it was written —
same frame, same ink, to the pixel, in the row's real shape — so nothing moved. Verified live with the
sidebar collapsed: the glyph opens Places on a plain local path, **and from inside the Trash**, which
is the mode with no crumb row at all and the one the rejected root-crumb anchor could never have
served; ⌘G drops the same menu in the focused pane; a volume picked from it opens the pane at `/`;
and clicking the *inactive* pane's glyph opens the place in **that** pane, which is what
`showPlaces` making its pane active first is for.

Deliberately out of scope: **individual places as ⌘K palette results** (the palette is a registry of
commands, and places are live data — a different mechanism, worth its own decision); reordering or
editing places from the menu, which stays the sidebar's job; and a Finder-style "Computer" or
"Network" destination, which is not a place Dirnex has.

### After M19

M19 closed on 2026-08-09; M20 opened 2026-08-12 (above). Three things landed between M19 and M18,
which closed on 2026-08-07, and four after it.

**2026-08-11 — a vault can be shown in Finder, per vault.** Dirnex attaches `-nobrowse`, so an
unlocked vault is invisible to the rest of the Mac — right as a default, and wrong as a rule for
everyone's every vault: a vault of scanned documents is one you unlock here and then want to attach
to an email. So it is a checked item on the vault's own row (`VaultLocation.showsInFinder`), off
unless someone turned it on, rather than one switch in Settings forcing one answer onto every vault.
Toggling it on an *open* vault applies immediately — `mount -u -o browse` was measured to work
unprivileged on a mounted encrypted sparsebundle — so it needs no lock-and-unlock round trip; a
read-only volume refuses that remount cleanly (exit 66, flags untouched) and is told it will apply
next unlock, which is true either way since the stored setting is what the next attach reads. Three
findings changed the code, all in docs/NOTES.md ▸ Encryption: a bare `-o browse` **drops
`MNT_IGNORE_OWNERSHIP`**, so the whole flags word is re-stated from `statfs` and only the browse bit
changes; a browsable vault is enumerated by `mountedVolumeURLs` like any other mount, so it appeared
under **Volumes as well as Vaults** — an invariant `-nobrowse` used to hold for free, now a rule with
a test; and a new field on a persisted `Codable` value needed a hand-written `init(from:)`, because
the synthesized decoder throws on a missing key and would have emptied every existing user's Vaults
section behind a `try?`. Verified live end to end, both directions, with the mount flags as the
judge rather than a screenshot.

**2026-08-10 — a vault can be renamed.** The sidebar's vault row grew a Rename… item, and F2 on a
selected vault row does the same thing. It renames the **volume**, not the row: `volumeName` is
re-derived from the mount point on every unlock, so a Favorites-style nickname would be silently
reverted the next time the vault opened, and until then the sidebar would disagree with the pane's
own path bar. The image file is deliberately left alone — `VaultLocation.volumeName`'s doc comment
already notes it is the one thing a user may have made unrevealing on purpose. `diskutil rename`
needs the volume mounted, so a locked vault unlocks first through the existing funnel (silent when
the passphrase is in the Keychain), which is why `openVault` was split into `withUnlockedVault` plus
a navigation the rename does not want. Everything measured before it was written, and two findings
changed the code: a name already in use still renames and **remounts at `/Volumes/<name> 1`**, so the
mount point is re-read rather than rebuilt from what was typed, and the name limit is 255 UTF-8
**bytes** — 127 Cyrillic characters — so the check counts bytes and the refusal sentence never names
the number. Verified against real encrypted sparsebundles end to end (including the collision), and
the F2 routing is pinned by selector string with a negative control, since a drifted `@objc`
signature is exactly how that key would go quietly dead. docs/NOTES.md ▸ Encryption.

**2026-08-10 — a vault now survives having its image file moved.** The other half of the same
addressing problem, found while verifying the rename: a saved vault is keyed on its image's path in
*two* stores — the sidebar list and the Keychain account — so an ordinary F2 on the `.sparsebundle`
(or an F6, or a move of any folder above it) left the row pointing at nothing and the passphrase
orphaned, with the row looking completely normal until it was clicked. The hook is `UndoRecord`, the
one funnel every rename, move, multi-rename and sync already reports through; reading **both** ends
of each step and letting the disk decide is what makes undo, redo and a half-applied revert all come
out right with no direction bookkeeping. A trashed vault is deliberately *not* followed — leaving the
path alone is what lets Put Back repair the row. The trap underneath took the measurement: `hdiutil`
reports an image by the path it had when it was attached, forever, and carries no other identifier —
so following a move would have made an unlocked vault read as locked with Lock unreachable.
`MovedVaultImages` corrects that one answer where it is produced, honored only while the reported
path is missing from disk, which is why it needs no expiry. Verified live across a locked rename, an
unlocked rename and a ⌘Z: the row kept working, the Keychain item moved each time with no orphan left
at any of the three paths, and the alias stopped applying by itself once the old path existed again.

**2026-08-10 — Enter on a vault's image opens the vault.** A `.sparsebundle` *is* a directory, so
the pane's generic directory branch walked into it: an unlocked vault, its sidebar row showing an
open padlock and an eject button, read as **locked** from the pane — `bands/`, `Info.plist`, `lock`,
`token` — and the only way to the files was the sidebar (user-reported). `openCurrentEntry` now
checks for a **saved** vault ahead of that branch and hands it to the window's existing unlock
funnel, so the sidebar click, the Unlock command and Enter are one gesture. Deliberately narrower
than the command's `vaultImageUnderCursor`, which takes any image because the user named it: Enter
is pressed on everything, and attaching a stranger's `.dmg` would ask for a passphrase and file it
in the sidebar's Vaults section, none of which anyone requested. The suffix test that both now share
moved into `DiskImageArguments.Kind.isImageName`, and the store read sits behind it since Enter is
overwhelmingly pressed on ordinary folders. The decision half takes the `SavedVaults` as a
parameter, so its tests never write a fake vault into the user's own sidebar. Verified live in both
directions — unlocked jumped straight to `/Volumes/SecDocs`, and after locking, Enter unlocked
silently from the Keychain and landed in the same place.

**2026-08-09 — 26 strings that were wrapped but never translated.** The whole of Settings ▸ Panels as
M15 built it — the row-height and size-visualization pickers with their footers, the three color
wells, the file-type color rules editor — plus M18's "not drawn in this preview" and M14's
multi-selection failure detail. All correctly `String(localized:)`-wrapped and all absent from
`Localizable.xcstrings`, which compiles such a key **to itself**: the strings rendered in English
inside a fully translated build, with both suites green and a perfect English screenshot. M12's own
audit had already named the class in docs/NOTES.md and prescribed the cross-check that finds it —
diff the compiler's `.stringsdata` against the catalog — and nobody had run it, which is the actual
lesson: a check that lives in prose is not a check. It is now
`scripts/check_localization_keys.py`, run in CI immediately after the app build, with the two keys
that are legitimately absent named in its allow-list. The `allCases` pickers get a test as well
(`LocalizationEnglishKeyCoverageTests`), since the sweep only fires once a key exists and a new enum
case arrives with its catalog entry in the same commit. All 26 are translated into the 13 shipped
languages and verified in the compiled bundle; the two segmented controls — the shape docs/NOTES.md
records collapsing under a longer translation — were checked in a live Russian build rather than
argued about, and the color-rule footer's `` `*.jpg;*.png` `` keeps its backticks so the wildcards
survive SwiftUI's Markdown parser in every language.

**2026-08-08 — the tree draws indent guides.** VS Code's vertical lines, one per ancestor level,
always drawn faintly, with the ancestor line of the *focused* row drawn stronger — the focus being the
pointer while it is over the pane and the **cursor** otherwise. That last part is the whole design
difference: VS Code renders its guides `onHover` because a tree there is a mouse surface, and a
keyboard-first pane where the guides only appear under the pointer would show them to nobody. Which
line is active is the core's (`TreeProjection.activeGuide`, 13 tests): an open folder highlights the
run its own children stand beside, anything else the run of the folder it is *in*. Two measurements
decided the rest. The pane's `intercellSpacing` is **(17, 0)** — zero vertically — so a name cell's
frame is the full row height and consecutive cells tile with no gap, which is what lets each row draw
its own segment and have them join into one line with nothing coordinated between rows; no row-view
drawing, no overlay. And the colors came from a contrast table over the pane's own two row stripes
rather than from taste: the obvious pairing (`.separatorColor` at rest, `.tertiaryLabelColor` active)
puts the *active* line at 1.88–2.26:1, which is where VS Code's **inactive** guide sits — so both moved
up one, to `.tertiaryLabelColor` and `.secondaryLabelColor`. A 1 pt hairline is below what a
computer-use screenshot resolves, so the geometry and the active/inactive step are pinned by a bitmap
probe in the app suite (`TreeIndentGuideRenderingTests`) instead of by looking.

**2026-08-07 — the Git status gutter became a badge.** M6's "status column (M/A/?/ignored)" was a
contextual 20 pt column installed beside Name for the length of a stay in a repository; it is now
`GitBadgeView`, at the trailing edge of the name cell outside the tag dots and the cloud badge —
the order is dots, cloud, Git. Same information (Git's own letter, in the same colors), and the
letters still line up in a vertical run, because the badge is right-aligned inside a fixed-width
column and centered in a slot sized to the widest code. What it gives back is **37 pt of Name** — the
column's 20 plus the 17 pt intercell spacing `NSTableView` charges per column — to put a letter about
20 pt from where it lands now. That is the third time a "column" in the plan turned out to mean a
badge in the name cell: tags and sync status made the same move at M6. Two things came with it: a
per-status **tooltip** (the gutter could only name itself in its header, and `!` or `U` is nobody's
vocabulary), and the fix for a latent `..` bug the third badge made worth looking for — the parent
row's cell comes out of the same reuse pool as the real name cells and was clearing none of them.
The one thing left alone deliberately: `GitStatusStyle`'s **colors** are unchanged, so `.systemGreen`
still sits near 2.22:1 on a light background (docs/NOTES.md's palette table). That is a pre-existing
call about the whole `.system*` palette, not this change's to make quietly.

The scope that is already written down, rather than merely imaginable, is in the *undone* column above
plus M15's cut: the **thumbnail grid, brief view and the `PaneSurface` extraction** (one unit, argued
in HISTORY.md §M15, with the two constraints any future grid inherits — skip `FileEntry.isDataless`
rows, and move sort off the column header first). The item two separate milestones had asked for —
**edit-temp-watch-repack write-back**, M11 for archives and SFTP, M13 for FTP — **landed for archives
on 2026-08-09** and is still open for the two remote backends, which is where the rest of its value
is: `ArchiveMemberEditRegistry` and `EditedFileRevision` are backend-agnostic (watch a temp copy,
notice a save, offer to put it back), so SFTP and FTP need an upload in place of the repack rather
than a second mechanism.

M19's own loose end — **a per-archive passphrase held for the session** — **closed on 2026-08-09**,
reported by a user who could not open a file inside an archive they had just packed. Preview, opening
a member, and nested-archive entry all failed with `passphraseRequired`, and each swallowed it, so
the keys read as broken rather than locked. `ArchivePassphraseStore` (one per window, memory only)
now holds what the user typed and `withArchivePassphrase` is the single ask-once-retry-on-typo funnel
all four gestures share, F5 included — so an archive unlocked by any of them is not asked about again.
The *passive* half is the part with a rule behind it: a preview follows the cursor, so those paths
read the store and stay quiet when it is empty, and only the gesture the user actually made may raise
a sheet. Two things the same pass settled: Enter on a plain file member had never opened anything in
*any* archive (it extracts to temp and launches the default app now, read-only, since nothing writes
an edit back), and an encrypted archive's whole-archive extraction is reused for its later members
rather than re-decrypted per arrow key. **A member filter is still open** — one member of a 600 MB
encrypted archive still decrypts all of it, once.

The same day, **editing a member in place** landed on top of it, and needed one thing nobody had
noticed was missing: every archive *write* went through `bsdtar`, which cannot be given a
passphrase — so F8 delete and F5/paste add inside an encrypted archive had never worked. They failed
safely (the rewrite throws before the original is touched), which is why it read as unimplemented
rather than broken. `ArchiveRewriteFormat` now picks the libarchive route off one header read and
re-states what the extracted tree cannot say — that the archive was encrypted, and whether its names
were hidden. On top of that, an opened member is watched (`ArchiveMemberEditRegistry`) and a save
offers to repack it; the read-only `chmod` that stood in for this for one day is gone, and F4 works
inside a writable archive. A **nested** archive stays read-only, since its bytes are themselves a
temp copy. (Its other loose end, §6's derived-data clause,
closed on 08-09 too — measuring the three leaks it named found none of them real and found a fourth
that was ours, so it was fixed rather than documented: HISTORY.md §M19 ▸ Follow-up.)

### M21 — Amazon S3, and the mounts we already reach (M, opened 2026-08-12)

Asked as one question — "can we add Dropbox, OneDrive and Amazon?" — and it is three, with three
different answers. Worth writing down in that shape, because two of the three are settled before any
code is written.

**Dropbox, OneDrive and Box are already supported and always have been.** `CloudStorageMounts` was
written provider-agnostic on purpose (§M10 Phase 1), so every File Provider client macOS hosts
appears in the Cloud section through the ordinary `LocalBackend`, with its own `.Trash` picked up by
`SidebarLocations.trashDirectories`. There is no backend to write. What was actually wrong is the
*naming*, and only for one form: OneDrive mounts a SharePoint document library as
`OneDrive-SharedLibraries-<tenant>`, where the first hyphen falls **inside the provider's name** — so
the split answered the account `SharedLibraries-Contoso`, and the row drew either a bare "OneDrive"
(wrong: it is not the user's own drive, and it collides with `OneDrive-Personal`, which produced two
identically-labelled rows) or an internal English token in a sidebar that ships in fourteen
languages. Landed 2026-08-12: a known provider id now wins over the hyphen, longest first, with
`OneDrive-SharedLibraries` → "SharePoint" beside Google's existing entry. Brand names, so the table
is the right home and not the string catalog.

The half that is **not** done is verification, and it needs the clients installed: whether the sync
badges light up (the ubiquity keys were measured for Drive's streaming mode only — Dropbox
online-only and OneDrive Files On-Demand should be the same File Provider mechanism, but that is a
prediction, not a measurement), and whether each client's `.Trash` has the shape `Places` assumes.

**Amazon Drive is not a thing to support.** It shut down 2023-12-31, and WorkDocs was EOL'd in 2025;
there is no File Provider mount to find. So "Amazon" means **S3**, which is a real backend and the
rest of this milestone.

#### S3 fits the house pattern, and fights the filesystem

Probed 2026-08-12 before any Swift, and the first probe is what makes the milestone affordable:
**stock `/usr/bin/curl` 8.7.1 signs SigV4 natively** (`--aws-sigv4 aws:amz:<region>:s3`). Verified
with a control — a fake key against real AWS returns `InvalidAccessKeyId`, meaning the signature was
computed and looked up, against an unsigned control returning nothing. So S3 needs **no SDK and no
dependency**, exactly like `bsdtar` and the FTP backend, and §2's "no proprietary APIs" line holds:
this is a wire protocol reached with a stock tool, not a vendor SDK. One spelling covers Cloudflare
R2, Backblaze B2, Wasabi and MinIO, which is most of the value — so S3-compatible endpoints are in
scope from day one (a custom endpoint plus a path-style flag is nearly free now and awkward to
retrofit).

What the probes settled, all against real buckets:

- **The classifier is inverted from FTP's.** NOTES.md ▸ curl says "the exit code is the
  classification" for FTP, where every failure has its own code. S3 speaks HTTP, so `curl` **exits 0**
  for a missing key, a denied bucket, a bad signature and a wrong region alike (404/403/403/301, all
  exit 0). The HTTP status plus the `<Code>` element is the answer; the exit code is demoted to "did
  this reach a server".
- **A wrong region answers 301 and names the endpoint that would have worked.** So the connect form
  can *correct* a mistyped region instead of reporting a failure — from outside, a wrong region is
  otherwise indistinguishable from a missing bucket.
- **A continuation token must be percent-encoded going back**, or AWS rejects the page with
  `InvalidArgument`. Measured A/B on the same token in one run. It fails *intermittently*: base64 that
  happens to carry no `+`, `/` or `=` round-trips raw perfectly, so a bucket small enough never to
  paginate hides it entirely.
- **Keys and common prefixes come back whole at every depth** (`tiles/1/C/`, not `C/`), so a parser
  that renders them verbatim draws the full path in every row.
- **A zero-byte object whose key *is* the prefix is how a flat store holds an empty folder**, and it
  arrives as an ordinary row in that folder's own listing — rendering as a duplicate of the folder,
  inside itself.

Slice 1 landed 2026-08-12, core-only and additive (`S3Location`, `S3Key`, `S3ListingParser`,
`S3ResponseError`; 52 tests, app untouched). The listing fixtures are real AWS bytes from the public
`sentinel-s2-l1c` bucket rather than written from the documentation, for the reason NOTES.md gives
about corpora: a hand-written fixture proves the parser agrees with whoever wrote it, and both facts
above are invisible that way.

Slice 2 landed 2026-08-13 and is the **read half**, still core-only and additive
(`S3ProcessArguments` with `S3ConfigFile` and `S3WriteOut`, `S3Transport`, `S3Backend`, and
`ConnectionScopedBackend`; +90 tests, app untouched). A bucket now lists, stats and downloads
against an injected transport fed the bytes `1000genomes` and `nasa-nex` actually sent. Five things
were probed first and four of them changed the code that was about to be written:

- **The credential rides on stdin and the signature is provably computed** — `-K -` carrying
  `user = "<id>:<secret>"` beside `--aws-sigv4`, verified with the control that makes it evidence: a
  fake key delivered that way comes back `InvalidAccessKeyId` (the key was looked up, so a
  well-formed signature reached AWS) where the *unsigned* same request answers `NoSuchBucket`.
- **`curl` sorts the query string itself when signing**, so the URL builder must not. Measured by
  signing a deliberately out-of-order query, capturing the `Authorization` header, and recomputing
  SigV4 by hand both ways — the sorted canonical query reproduces `curl`'s signature byte-for-byte
  and the as-written order does not. Unmeasured, this fails as `SignatureDoesNotMatch` for one user
  with one prefix.
- **`x-amz-bucket-region` is on the 301**, which retires the plan's "parse the `<Endpoint>`
  element": AWS's endpoint element is bucket-prefixed *and* spelled in the legacy dash form
  (`nasa-nex.s3-us-west-2.amazonaws.com`), which is not a shape this project ever builds. The header
  is now the primary source and the element the fallback, for S3-compatible servers that send no
  header.
- **A stat is one request, and the exact match is the whole rule.** Listing with `prefix=` the key
  itself separates all three outcomes at once — a `Contents` row of exactly that key is a file, a
  `CommonPrefixes` of `key/` is a folder, neither is not-found. What makes it sharp is that
  `prefix=README` came back with four `README.*` siblings and no `README`, so a first-row reading
  reports a *sibling's* size and date under the name that was asked about.
- **Resume works and answers 206**, byte-identical to a whole download (a 257 098-byte object
  resumed from a 100 000-byte partial moved exactly 157 098). Two corollaries: success is the 2xx
  range and not `== 200`, or every correct resume reads as a failure; and resuming onto an
  already-*complete* file answers **416**, so the remote size is checked first rather than left to
  `curl -C -` to discover.

The write half is deliberately not in it. `capabilities` says `.read`, so M5's degradation grays the
rest out, and the upload payload-signing question below is still the thing that needs credentials to
settle rather than a mock (the `moto` lesson).

Slice 3 landed 2026-08-13 and is the **app half** — a bucket is now reachable: `S3CurlTransport`,
the connect sheet's fourth protocol (`ConnectServerS3Fields`), `PanelViewController+ConnectS3`,
routing and capabilities on `CompositeBackend`, the saved-server endpoint, the path bar's crumbs and
the sidebar's glyph. Verified live against a local S3-shaped endpoint: connect, list, walk into a
folder, F5 a file out (byte-exact), reconnect from the saved sidebar row, and F5 *into* the pane
refused up front. Four things are worth carrying out of it:

- **A refused download used to land in the destination file.** `--output` writes whatever the server
  sends, and a refusal is still a response — measured against real AWS with a bad key, the
  destination came away holding a 354-byte `<Error>` document under the object's own name. The
  transfer arguments now carry `--fail`, which writes nothing and still reports the status through
  the write-out; `--remove-on-error`, the flag that pairs with it by reflex, is deliberately absent,
  because it deletes exactly the partial that resume exists to continue from.
- **The exit code is demoted literally**, which is what the inverted classifier means in code: the
  transport reads the status out of the labelled write-out and treats a nonzero exit as a failure
  only when there is *no* status. `--fail`'s exit 22 on a refused transfer is then absorbed for
  free — the response arrived, it just said no.
- **Five app sites spelled `isSFTP || isFTP` where they meant "a connected remote"**, which is the
  trap NOTES.md records from the day FTP arrived beside SFTP. They now read `isRemoteConnection`,
  with `acceptsUploads` as the deliberately narrower twin S3 is absent from — one line to edit when
  the write half lands, instead of five to find.
- **A folder has no date, and formatting the sentinel drew `01.01.1, 02:02`.** An S3 folder is a
  common prefix rather than an object, so there is nothing to render; `FileEntry.unknownDate` names
  what four backends were already spelling `.distantPast`, and the Date column draws the same dash
  the Size column already uses. Invisible to every fixture — each carries a real date — and obvious
  in the first second of looking at the app.

Slice 4 landed 2026-08-13 and is the **write half**: `createDirectory`, `createFile`, `moveItem`,
`removeItem`, and `copyFile`'s two new directions (`S3DeleteBatch`, `S3Backend+Write`; +36 tests,
`capabilities` now `[.read, .write]` and `acceptsUploads` gains S3). Everything was probed first
against a local endpoint that **verifies SigV4 by hand** — a real signature check rather than a
mock, which is the `moto` lesson applied: a wrong secret is refused there, so a pass is evidence.

- **The payload-signing question is settled, and on the merits rather than by preference.** It was
  never really "which does AWS accept" — measured on one 512 MiB upload, `-T` peaks at **5.3 MB**
  resident and `--data-binary @` at **1.08 GB**, twice the file. A file manager cannot hold every
  uploaded file twice in RAM to buy a payload digest, so `-T` is the only viable shape and
  `UNSIGNED-PAYLOAD` — what S3 documents for a stream over HTTPS — comes with it. The request is
  still fully signed; the bytes are TLS's to protect.
- **Three spellings of "write nothing" and only one is safe.** `-T /dev/null` sends
  `Transfer-Encoding: chunked` with `UNSIGNED-PAYLOAD` (which S3 rejects — a chunked upload needs
  its own streaming signature) and reports 5 bytes uploaded for an empty file, which is the chunk
  framing; a bare `-X PUT` sends no `Content-Length` at all. `--data-binary ""` states its own
  emptiness. And **`-T` against a URL ending in `/` appends the local file's basename** — measured,
  `trailing/tiny.txt` — so an upload URL must never end in a slash, while a folder marker's must.
- **`curl` signs `x-amz-copy-source` and `Content-MD5` and produces neither.** Both appear in
  `SignedHeaders`, which is what makes the rename primitive and the batch delete reachable at all;
  the copy source's *encoding* and the digest's *value* are ours. A wrong digest signs perfectly and
  only the server catches it, so the probe was made to enforce `BadDigest` before that was believed.
- **A folder move needed no new job type, which is the whole reason it is affordable.**
  `moveItem` answers `EXDEV` for a prefix and `CopyEngine.perform` already falls back to a recursive
  copy-then-delete on exactly that signal — on the operation queue, with progress, cancellation,
  conflict policy and a per-item failure report. The same signal `RemoteTransportBackend` sends for
  a cross-*backend* move, used here for a cross-*shape* one.
- **A batch delete's body is the outcome, not its status.** A 200 can carry per-key `<Error>` rows,
  so a status-only reader reports a folder as deleted with the files a bucket policy protects still
  in it. Batched at 1000, one request per thousand keys instead of one per key on a verb where every
  request is billed.

Verified live end-to-end by a harness compiled in Swift 6 mode against the **real** core and the
app's own `S3CurlTransport` source: create a folder, upload, round-trip the bytes, rename (including
a name carrying a space, `+` and `#` through both sides of the copy-source header), defer a prefix
move with `EXDEV`, delete one object, sweep a nested prefix in one batch, and a wrong-secret control
that had to be refused.

Slice 5 landed 2026-08-13 and is **multipart upload**, which closes the last thing that could make
an ordinary F5 fail on size alone: S3 refuses a single `PUT` above 5 GiB, so before this a large
file was rejected at the end of however long it took to offer the whole thing. `S3MultipartPlan`,
`S3MultipartDocument`, `S3PartSlice` and `S3Backend+Multipart` (+38 tests), with the four verbs on
`S3ProcessArguments`, `S3Transport` and `S3CurlTransport`. Everything below was measured against a
local endpoint that verifies SigV4 by hand, before any Swift.

- **A part must be a file on disk, and the natural fix for that is a trap.** `-T` is the only
  affordable upload shape (5.3 MB resident against `--data-binary`'s 1.08 GB on 512 MiB), and it
  needs something it can `fstat` for a `Content-Length` — a part piped to `-T -` goes out
  `Transfer-Encoding: chunked`, which S3 rejects for an `UNSIGNED-PAYLOAD` upload. Adding
  `-H "Content-Length: N"` does **not** fix it: `curl` then sends *both* headers, a contradictory
  pair that a permissive endpoint reads happily and a real one refuses. So each part is cut to a
  temp slice, which costs one part of temp space and roughly 1 % of a real upload's wall time.
- **Two zero-copy routes were measured working and both were declined**, which is worth recording
  because each looks like the obvious answer. Moving the credential to `-K /dev/fd/3` frees stdin
  for `--data-binary @-` and signs a *real* payload digest — but `Foundation.Process` exposes only
  three descriptors, so fd 3 means raw `posix_spawn`, and feeding a body while draining two pipes
  turns a settled transport into a three-way pump. An APFS `clonefile` plus a truncate, `-C` and a
  suppressed `Content-Range` sends the exact range with nothing copied — and is APFS-only, needs a
  writable spot on the *source* volume, and so needs the slice path as its fallback anyway.
- **The threshold is policy at 64 MiB, well below the 5 GiB the service forces**, because multipart
  buys two things a single `PUT` cannot: a retry unit smaller than the file, and a progress counter
  that moves. The whole object is one `curl` invocation on the single-`PUT` path, so a 4 GiB upload
  showed nothing moving for its entire duration.
- **An abandoned upload is a bill.** S3 stores the parts of an unfinished upload and charges for
  them, invisibly to an ordinary listing, so every failing exit aborts — and the abort deliberately
  swallows its own failure, since the error the caller is carrying is the one worth reporting.
- **A completion can fail inside a 200**, the same shape `DeleteObjects` was *measured* to have, so
  the body is read as well as the status. Reading only the status would report a successful upload
  of an object that does not exist.

Verified live by the same harness against that endpoint, with the server's own log as the judge
rather than the client's opinion: a 70 MiB file went out as 4 × 16 MiB + 1 × 6 MiB, every part with
an exact `Content-Length` and **no chunked framing anywhere**, reassembled byte-identical, stat'ed
at its full size; a small file still took one `PUT`; a refused part ran `create → part → part →
abort` and never completed; and a wrong-secret control was refused with `SignatureDoesNotMatch`.

Slice 6 landed 2026-08-13 and is the **app pass** — the write half driven through the real UI rather
than through a harness, and the two gaps that only that could show. The probe endpoint grew a
server-side copy and a `DeleteObjects` batch (both verifying `Content-MD5` and the signature by
hand), the app was driven against it by computer-use, and every request was read back out of the
server's log: F7 sent `PUT /probe/from-app/` with `Content-Length: 0` and the empty string's real
SHA-256 — no chunked framing; F5 sent the file as `UNSIGNED-PAYLOAD` with an exact length; F2 on a
name carrying a space came through as `x-amz-copy-source: /probe/hello.txt` → `renamed%20by%20app.txt`
followed by the delete; F8 on a folder swept three keys in **one** batch. So the wire shape Slices 4
and 5 were designed to produce is what the app actually produces. The two things it found were both
in the app and neither is S3-specific in its cause:

- **A remote pane had no `..` row, a dead Backspace and a grayed Go Up** — `parentRowCount`,
  `goToParent()` and the Go menu's validator each spelled the rule `backend == .local`, so this had
  been true for SFTP since M5 and FTP since M13 as well. It is the "one rule, several spellings"
  trap in its worst form, because a *missing* row shows nothing: the pane is an ordinary listing, and
  both remote parsers correctly strip the server's own `..`, so there was no accidental row either.
  Walking into an **empty** bucket folder is what removes every alternative at once — no rows, no
  Backspace, no menu item, the crumb the only way out. One `canGoToParent` now answers it for all
  three surfaces, deliberately still excluding a results snapshot, whose synthetic parent is not
  somewhere to go — and a fourth site fell out of naming it, the `cursorOnParentRow` seed, which had
  been parking an empty results pane's cursor on a row that pane does not draw. Re-verified live: the
  same empty folder now carries `..`, Backspace walks up onto the row it came from, and Go Up is
  enabled.
- **A bucket root had no name.** `VFSPath.displayName` named an archive, an SFTP account and an FTP
  account and stopped there, so the tab chip read `/` directly above a crumb reading
  `probe — 127.0.0.1` — the contradiction that property's doc comment exists to prevent — and F7
  offered «Create a folder in "/"», which `creationDirectoryName` had been saying at an SFTP or FTP
  root all along. The root title now has one definition (`backendRootTitle`) that both the chip and
  the crumb read, since they need it at *different depths* and that is exactly how the two drifted.

The `..` widening is verified live on S3 and by test on SFTP and FTP — they share the one predicate,
but nobody connected to a real server to watch it.

Slice 7 landed 2026-08-13 and is the **bucket picker**: the connect sheet can now fill in the one
field nothing else could supply. `S3Account`, `S3BucketListParser`, `S3BucketEnumeration` and
`S3ProcessArguments.listBuckets` in the core (+17 tests); `S3CurlRunner`, `S3BucketLister` and
`ConnectServerS3BucketPicker` in the app (+9). It is the deferral below answered in the shape that
survives its own objection — an **assist, never a root**. The field stays a field, so a key scoped to
one bucket loses nothing it had; only a key allowed to ask gains anything.

- **The signature needed nothing new, and that was worth measuring rather than assuming.** Probed
  against the endpoint that recomputes SigV4 by hand: `curl --aws-sigv4` signs a service-level
  `GET /` — no bucket in the path *or* the host — with canonical URI `/`, an empty canonical query
  and the real digest of the empty body, and it verified; a wrong secret against the same URL was
  refused, which is the control that makes the pass evidence. So account-level access is a URL with
  the bucket left out, which is exactly what `S3Account` is and why an `S3Location` with an ignored
  `bucket` will not do: under virtual-host addressing the bucket lives in the *host*, where `GET /`
  is S3's legacy `ListObjects` — a well-formed listing of the wrong thing, handed to a parser looking
  for buckets.
- **Both refusals are 403 and only the `<Code>` separates them**, which is the inverted classifier
  arriving at one more site and this time deciding *who is told they have a problem*. `AccessDenied`
  is the ordinary answer for a properly scoped key and must not read as a fault; `SignatureDoesNotMatch`
  and `InvalidAccessKeyId` are worth reporting, because Connect is about to fail the same way. Both
  were driven live, and the server's own log is what makes the claim sharp: the *denied* request's
  signature **verified** — the credentials were fine and the policy said no — while the other
  genuinely mismatched, and the app told them apart.
- **These fixtures are from the API reference, not captured, and the suite says so.** There is no
  public account to list and this Mac holds no AWS credentials, so unlike the object-listing suite —
  real bytes off real buckets — a green run here proves the parser reads the documented shape and
  tolerates its variations, not that it agrees with what AWS sends. Everything it does leans one way
  (require only `<Name>`; read *both* continuation spellings, since the reference gives this response
  `ContinuationToken` where every other paginated response says `NextContinuationToken`).
- **Two AppKit bugs that only launching could find, and both fail in the quiet direction**: the
  button drew perfectly and was unclickable because the form pins every control it is handed to
  364 pt, so the row overflowed its grid cell (`NSView` does not clip; hit testing does respect
  bounds); and then it was clickable only on its *rim*, because a stopped `NSProgressIndicator` is
  still hit-tested. Both are in docs/NOTES.md ▸ AppKit.
- **One wrong sentence found by using it**: the first click on a freshly opened sheet reported "The
  access key or secret wasn't accepted" for a form that had sent nothing. An empty form now has its
  own string, because a refusal is a claim about a server that has not been asked.

Slice 8 landed 2026-08-13 and is the **first pass against a real third-party endpoint** — a paid
S3-compatible account (`s3.lax.sharktech.net`), where every earlier slice had been verified against a
local SigV4-verifying probe endpoint and anonymous reads of public AWS buckets. The whole write half
was re-run through the real `S3Backend` and the app's own `S3CurlTransport`, compiled in Swift 6
mode: listing, F7, upload, byte-exact download, F2 through a name carrying a space, `+` and `#`, the
empty-file `PUT`, the `EXDEV` folder-move deferral, multipart (70 MiB → 4 × 16 MiB + 6 MiB, five
progress reports, byte-identical round trip), server-side copy, single delete, a one-batch prefix
sweep, and a wrong-secret control that was refused. Slice 7's bucket parser was scored against real
`ListAllMyBuckets` bytes for the first time — its API-reference fixtures turned out faithful,
including the empty-account shape a brand-new account actually returns.

It found one real bug, and the shape of it is the milestone's own lesson arriving one layer lower.
`S3ListingParser` trimmed whitespace off every XML value it read, so a key whose *edges* are
whitespace was misnamed by one character — and everything that then addressed it by that name
missed: F5 and F2 answered `notFound` for a row visible in the pane, F8 **reported success having
deleted nothing**, and a common prefix of `" folder/"` entered *empty*. `stat` kept working
throughout and is what hid it, since the trim applied to both sides of its comparison. It is
unreachable against AWS by construction — AWS honors `encoding-type=url`, so the space arrives as
`%20` and there is nothing to trim. The echo protects the decode; nothing protected the trim. Fixed
by trimming per field (never a `<Key>` or `<Prefix>`, always a size, date, boolean or token), with
the same one-line shape corrected in `S3DeleteBatch`'s response parser and deliberately left alone in
`S3BucketListParser`, where a bucket name cannot carry whitespace. +6 tests in a suite of their own,
whose fixtures are this endpoint's bytes precisely because AWS cannot produce them; the negative
control fails 10 assertions with the fix backed out. Re-verified live: the row now draws its space,
downloads, renames, and deletes for real, and the folder opens with its file in it.

Three endpoint facts came out of it that are worth having before the next S3-compatible server
(docs/NOTES.md ▸ curl ▸ S3): the region is **not validated** there and no `x-amz-bucket-region`
header is sent, so the wrong-region 301 path cannot be exercised at all; a raw continuation token
fails as **`SignatureDoesNotMatch`** rather than AWS's `InvalidArgument`, which would have sent a
user to retype a credential that was never wrong; and a **single-label wildcard certificate** forces
path-style addressing, failing at curl exit 60 before any S3 conversation — settleable from the
certificate in one `openssl s_client` run rather than by trying both modes.

The **UI pass against the same endpoint** followed, driven by computer-use, with the server's own
listing as the judge rather than the pane's. Connect through the sheet, the bucket picker filling its
field from the live account, the bucket root listing with folders drawing `—` for size *and* date,
Enter into a folder, Backspace back out over a real `..` row, F5 out, F7, F2 and F8 — and the server
afterwards held exactly what the pane claimed. Two things it confirmed that only the real UI could:
F7's sheet reads «Create a folder in "dirnex-test — s3.lax.sharktech.net"» rather than the `/` that
Slice 6 fixed, and the whitespace fix survives the whole stack — the trailing-space object drew with
its space, and F5 landed it on the local disk as `edge ` with the byte intact.

The region field was **emptied** in the same pass. It had been prefilled `us-east-1`, which states a
fact about the user's server that the app does not know: measured, this endpoint verifies the
signature while ignoring the credential scope's region entirely. The field now starts blank behind
its placeholder and resolves to `us-east-1` when read — in one funnel both readers share, since the
bucket picker's own guard rejects an empty region and would otherwise refuse to ask on a form whose
Connect button works. It cannot simply be dropped: SigV4 always names a region, and for the Amazon
service the region *derives the host*, where empty would address `s3..amazonaws.com`. Defaulting is
safe there because a bucket elsewhere answers 301 and the connect flow already re-aims at the region
the service names. Verified live with the field left blank end to end — the picker listed the account
and the connect succeeded.

**The UI pass found one wrong sentence, and it is now fixed.** Connecting to this endpoint with the
default virtual-host addressing fails, correctly, at curl exit 60 — and the sheet reported "The
endpoint's TLS certificate couldn't be verified. A server with a self-signed certificate has to be
reached over http:// for now." Every clause of that was wrong here: the certificate is a valid
GoDaddy-issued `*.lax.sharktech.net`, nothing is self-signed, and the actual remedy is the
**path-style checkbox two rows above** — a wildcard is one label deep (RFC 6125), so it cannot cover
`<bucket>.s3.lax…`. The app was diagnosing an addressing problem as a trust problem and pointing the
user at **plaintext HTTP** as the cure, on the default path for any S3-compatible provider whose
certificate is not wildcard-deep — i.e. the first thing such a user meets.

`s3CertificateDetail(location:)` now splits the one exit code by what the *request* asked for, since
that is what decides which failure it is. Under virtual-host addressing the name being verified is
`<bucket>.<host>` rather than the endpoint that was typed, so the message names that host and the
path-style checkbox; under path-style the verified name *is* the endpoint, so a failure really is
about trust and the original sentence stands. It is keyed on the addressing mode rather than on the
service picker deliberately: AWS reaches the identical state, because `*.s3.<region>.amazonaws.com`
is also one label deep and so a bucket whose own name contains dots cannot be addressed virtual-host
over TLS either — path-style is the same answer there. The checkbox is named by interpolating its
own title rather than by spelling it out, so the sentence names the control the user is looking at in
all fourteen languages instead of becoming the second copy of a display string that gets localized
once. +4 tests; the new key is translated in all fourteen and verified in the compiled `.strings`
rather than in the catalog.

Verified live on the endpoint that produced it, both directions in one run: the failing connect now
reads «The endpoint's TLS certificate couldn't be verified for "dirnex-test.s3.lax.sharktech.net".
The bucket is part of the host name until "Path-style addressing" is turned on, and most certificates
don't cover that», and ticking that box and pressing Connect again succeeds — which is what makes the
new sentence *advice* rather than merely better wording.

**What S3 will not be able to do, and it is better to state it than to discover it.** S3 is not a
filesystem: rename is copy-then-delete (O(size), and N copies for a "folder"), `createDirectory` has
no operation behind it beyond writing a marker, there is no settable mtime, no permissions and no
symlinks — so `copyMetadata` is a no-op and `DirectorySync` by timestamp is as unreliable as it is
over FTP. Every listing is a billable request, which makes the recursive sizer cost money over a
bucket. `RemoteTransportBackend`'s four write verbs were shaped for FTP and SFTP, where they are
genuine filesystem operations; S3 fits the *transport* shape, so it conforms to
`ConnectionScopedBackend` (the guard all three need) and answers the four verbs itself — which is
what Slice 4 is. Two consequences survive that and are permanent: nothing about a folder rename or a
folder delete is **atomic**, and a byte counter cannot advance during a server-side copy without
paying a round trip per object for it (~25 min of pure latency on a 50 000-file prefix), so those
copies report items rather than bytes.

Slice 9 opened 2026-08-13 and is **bucket management** — the deferral below, answered. Core-only and
additive so far (`S3BucketName`, `S3AccountBackend` with its own `S3AccountTransport`, the account
descriptor and `bucketLocation`, three argument builders, two `VFSUnsupportedReason` cases
translated in all fourteen; +30 tests, app code untouched). An account is a **second root, never the
only one** — the pane lists buckets as rows, so F7 creates one and F8 deletes one through the
machinery that already exists, and the objection below survives intact: a key that cannot call
`ListAllMyBuckets` keeps exactly what it had.

Everything was probed before any Swift — a local endpoint that recomputes SigV4 by hand for the
request shape, then the real third-party account for the semantics, with every probe bucket cleaned
up afterwards. Two findings changed the code that was about to be written:

- **Creating a bucket that already exists answers 200, silently.** No `409`, no code, nothing
  changed — so relying on the service means F7 on a taken name reports success and does nothing.
  AWS *does* refuse (`BucketAlreadyOwnedByYou`), which is exactly why the check has to be ours: a
  local stat first is the only behaviour that is correct on both. The `moto` lesson from Slice 4
  arriving from the other side — this time the *real* server was the one being permissive.
- **Every broken naming rule comes back as one indistinguishable `400 InvalidBucketName`.** Five
  different mistakes — uppercase, two characters, an underscore, an IP-shaped name, 64 characters —
  one sentence, "The specified bucket is not valid", with nothing a user can act on. So
  `S3BucketName` is not a round-trip optimisation: refusing locally is the only way anyone learns it
  was the capital letter. A **dotted** name is legal and was accepted in the same run, and is the
  one that strands a user later, since a wildcard certificate is one label deep — a warning about
  addressing, never a naming refusal.

Three more that shaped the verbs: a successful `DeleteBucket` is **204**, so a classifier keyed on
`== 200` fails every correct delete (the resumed download's 206, on another verb); `409
BucketNotEmpty` needs its own sentence because the shared 409 mapping is `alreadyExists`, which
answers a *delete* with "this already exists"; and `HeadBucket` sends **no** `x-amz-bucket-region` on
this endpoint, so entering a bucket keeps the account's region — correct there precisely because that
server does not validate regions. The trailing slash `S3Location.bucketURL` already produces is safe
on both write verbs (probed both ways), so the account arguments reuse the one definition of how a
bucket is addressed rather than growing a second.

The app pass landed the same day and is four **backend crossings** — the connect sheet's
empty-bucket path, the saved-account sidebar row, entering a bucket as a *connect* (so the region
correction applies), and **Backspace out of a bucket root**, which is a crossing rather than a path
walk since a bucket root's path is `/` and has no parent to find. It probes once before navigating,
so a key that cannot list buckets gets a sentence where it is standing rather than a pane it has
landed in that can only show an error. `PanelViewController+S3Account` holds all three gestures;
`ServerEndpoint.s3Account` and `S3AccountCurlTransport` are what the sidebar and the composite need.

- **A blank bucket field is an answer, not an omission**, and giving it a meaning is safe precisely
  because it had none: `S3BucketName.minimumLength` is 3, so nothing that used to connect now
  connects somewhere else. The cost is a typo landing in the account pane instead of an error, which
  is one keystroke from recovery — the bucket meant is a row there. The placeholder carries the hint,
  because a blank field that *does* something and says nothing is a feature nobody finds; it is the
  only always-on surface for it, since the picker button beside it explains itself only once clicked.
- **A case of its own rather than an optional bucket on `.s3`.** They are different *places* — two
  backend ids, two requests, and a saved server has to come back as the one it was saved as — where
  an optional field would make every existing reader ask a question that has only ever had one
  answer. `S3Account` is disjoint from `S3Location` at both keys that matter (the `s3a://` scheme and
  the Keychain account), so neither can ever be read as the other.
- **`readAccount` had to start carrying the addressing mode**, and this is the slice's own instance
  of the finding it keeps re-deriving: the account built for Slice 7's picker was built *without*
  one, correctly, because a service request names no bucket. The moment an account became a place,
  every bucket reached from it — plus `CreateBucket` and `DeleteBucket` — spelled one into a URL, and
  two builders of the same value disagreeing is how this project loses an afternoon.
- **Entering a bucket routes through `connectS3`** rather than re-implementing it, so the 301 region
  correction, the Keychain filing and the certificate sentences apply to a row the same way they
  apply to the sheet. The one thing that genuinely differs is the TLS message: an account request is
  `GET https://<endpoint>/` with no bucket in the host, so the path-style advice a bucket's failure
  gives would name a checkbox that could not have caused it.
- **F7 there names a bucket, not a folder.** Left generic it would have prefilled "untitled folder",
  which breaks two naming rules by construction — a default that can only earn a refusal about a rule
  the user never chose to break — and the folder-shaped slash check would have preempted
  `S3BucketName`'s sentence, which is the one that says *which* rule broke.

Verified live against the real third-party account (path-style, which its single-label wildcard
certificate requires): connect with no bucket → the account pane lists its bucket; Enter → the bucket
lists, with a `..` row; Go Up → back to the account with the cursor on the bucket it left; and F7's
create + F8's delete of a scratch bucket, confirmed gone from the account afterwards by an
independent `ListAllMyBuckets`. Two negative controls make that mean something: with the endpoint
stopped all four fail, and with `leavesBucketForItsAccount` neutered the walk-up fails **while its
neighbours pass** — landing the cursor on a folder *inside* the bucket, which is exactly the bug the
branch exists to prevent. `S3AccountLiveIntegrationTests` is that run, kept and gated on a config
file. What no automated signal covers is the *drawn* surfaces — the sheet's placeholder, the sidebar
row, the account crumb, the New Bucket dialog — which want one look by hand.

**Follow-up, 2026-08-13 — a virtual-host TLS failure now corrects itself.** Reported by a user
connecting with the bucket field blank and pressing Enter on a bucket: exit 60, and a sentence naming
a checkbox that was not on screen. Slice 9's own reasoning above says why the connect could not have
caught it — a service request has no bucket in the host, so the wildcard covers it and the probe
validates nothing about how a *bucket* will be addressed. The fix is the second self-correction in
`connectS3`, on the same argument the region one makes: path-style still verifies the certificate,
against the host the user typed, so there is no weaker outcome to accept and nothing to ask about.
It also *measures* what the sentence could only guess — exit 60 cannot separate a wildcard that is
one label too shallow from a genuinely self-signed endpoint, and the retry answers which it was,
fixing the case the shipped message had backwards (it advised a self-signed endpoint to tick a
checkbox that cannot help it). `savedServerName` carries the answer back into the saved record, which
for a bucket entered from an account pane is the **account's** — the live account is left alone
because its addressing rides in its descriptor and its descriptor is its backend id. +10 tests, both
directions of the negative control run. Details in docs/NOTES.md ▸ curl for S3.

The deferral this answers, kept for its reasoning: **account-level browsing** (`ListAllMyBuckets`) as
a second root — a key scoped to one bucket is the ordinary way these are issued, so an account-rooted
design fails at the root for exactly the users whose credentials are set up properly. Slice 7 is why
the distinction was worth keeping: the same call makes an excellent **assist** — a picker beside a
field that is still typed — precisely because a key that cannot make it costs the user nothing. Slice
9 is the third position that argument allows and the one that was missed for two slices: an
*optional* root is neither the root nor a mere assist, and it inherits the assist's whole safety
argument. Worth carrying past S3: when a capability is rejected for what it does at the *root*, ask
what it does as an *option* before filing it away. **Multipart upload**
was the other one and closed with Slice 5 above. The **upload payload-signing question**
closed with Slice 4 and did not need credentials in the end: it looked like "which does AWS accept"
and was really a memory measurement, since `--data-binary @` holds twice the file and `-T` holds
nothing, so `UNSIGNED-PAYLOAD` arrives as a consequence rather than as a choice. Worth keeping the
shape of that mistake — a local `moto` mock had answered the *acceptance* form of it wrongly in the
confident direction (silently storing an empty object for the signed form while a trace showed the
bytes had gone out fine), and the question it was asked was the wrong one anyway.

#### Slice 10 — opened 2026-08-14: reading and editing a remote file in place

Quick View (⌘Y / ⌃Q / F3), F4 Edit with write-back, and ⏎ to open — for **every** remote backend,
not for S3 alone.

**The core half landed 2026-08-14, additive and app-untouched** (`RemoteFileRevision` with
`RemoteRevisionEvidence`, `RemoteFetchPolicy`, and one predicate on `VFSBackendID`; +24 tests, 2351
core tests green, both linters clean). It is deliberately the part none of the five probes below can
change — every one of them is about the transport or the app, so the value types were affordable
first and the probes still gate the app pass rather than being skipped.

- **`isSuperseded(by:)` and "how much is that answer worth" are two questions**, and folding them
  into one confidence number would have made the second unanswerable. A *difference* found here is
  always real evidence of a write; *no* difference is only as strong as the fields compared, so
  `evidence(comparedWith:)` names the blind spot instead — `.entityTag`, `.sizeAndTimestamp`,
  `.sizeAndApproximateTimestamp`, `.sizeOnly` — and the app words each rather than showing a
  percentage nobody can act on. `.sizeOnly` outranks the approximate case on purpose: with no date
  at all there is nothing to be approximate *about*, and the FTP sentence there would name a
  weakness that is not the one in play.
- **The FTP caveat rides on the value, not on the call site.** `VFSBackendID.hasApproximateTimestamps`
  is the one spelling — a `LIST` stamp is year-less, zone-less and on the server's clock, which is
  fine to display and sort by and is not something to decide "nobody has touched this since" on —
  and `RemoteFileRevision(_ entry:)` reads it off the entry's own path, so a caller wording a
  conflict dialog cannot forget to ask. Named beside `isRemoteConnection` and `acceptsUploads`
  because this milestone has now re-derived the one-rule-several-spellings finding four times.
- **The ETag field ships with no producer, and it earns its place by changing the *rule*.** A
  matching tag short-circuits the comparison outright rather than joining the disjunction — a
  matching size and time is an absence of evidence where a matching tag is proof — and the two
  cannot be collapsed after the fact. Nothing supplies one yet (`S3ListingParser` reads a listing's
  `<ETag>` past without keeping it, and `FileEntry` has no field to carry it); the negative control
  is what makes the field testable today, since without the tags the same-size same-second rewrite
  is invisible to every other assertion in the suite.
- **`RemoteFetchPolicy` is a table because the numbers are expected to move.** Preview at 16 MiB
  asks first — the least committed gesture, the most expensive to get wrong, and every renderer
  behind it holds the whole file — while open and edit sit at 64 MiB, reusing `S3MultipartPlan`'s
  existing statement of where a transfer stops feeling instant rather than minting a second number
  that means the same thing. Edit is deliberately *not* lower than open: the file F4 was pressed on
  is one the user intends to change, so the dialog would stand in front of the work rather than in
  front of a look. The row that is not a number is the least arguable — an unknown (or negative,
  i.e. unparsed) size confirms, because not knowing how much is about to be pulled is exactly when
  to ask.
- Four negative controls were run and each failed only its own assertions: dropping the entity-tag
  short-circuit, passing `FileEntry.unknownDate` through as a date, flattening
  `hasApproximateTimestamps` to `false`, and clamping a negative size to zero.

**The five probes ran 2026-08-14** against the real third-party account, plus a deliberately slow
local HTTP server for the one that is about our own process plumbing rather than about S3. Two of
them change the app pass, one holds, one is unanswerable on this endpoint, and one found a bug older
than this milestone.

- **1 — Cancel mid-GET: Stop does not stop, and the plan's worry was the wrong way round.** Measured
  through the real `S3Backend` and the app's own `S3CurlTransport`: Stop pressed at 1.00 s,
  `copyFile` returned at **16.98 s** — the full time the server needed — with the server's own log
  reading `SERVED all 4194304 bytes` rather than a client disconnect, the destination holding the
  **complete** file, and `CancellationError` thrown after all of it. The plan feared a half-download
  cached as a preview; that cannot happen. What happens instead is that the whole cost is paid and
  the result thrown away. **It is remote-generic and pre-existing**: `isCancelled` is honoured at
  the file boundary in `S3Backend`, `FTPBackend` and `SFTPBackend` alike, and no transport calls
  `process.terminate()` except from its own timeout backstop — so Stop has never abandoned a
  single-file remote transfer, since M5. A preview or edit fetch therefore cannot bound its cost
  with `isCancelled`, which is the one thing the slice was going to lean on.
- **2 — A Glacier object is unanswerable here, and that is the finding.** Every non-`STANDARD`
  storage class is refused outright: `REDUCED_REDUNDANCY`, `STANDARD_IA`, `ONEZONE_IA`,
  `INTELLIGENT_TIERING`, `GLACIER`, `DEEP_ARCHIVE` and `GLACIER_IR` all come back **400
  `InvalidStorageClass`**, and only `STANDARD` is accepted. There is no archived-object state to
  reach, so `403 InvalidObjectState` cannot be exercised without an AWS account — any message we
  write for it ships unmeasured, and should say so rather than being listed as verified.
- **3 — Read-after-write holds on this endpoint.** Six writes, six immediate reads: the GET returned
  the bytes just written every time, and — the half that actually matters — the **listing** reported
  the new size immediately, which is what `stat` reads and therefore what the conflict check rests
  on. The endpoint that has already inverted two of this milestone's rules does not invert this one.
- **4 — The edge-whitespace key survives download and save-back.** Four names (`trailing `,
  ` leading`, `mid dle`, `plus+hash#and space`) × six assertions, all green — and the design of the
  probe is the lesson. The first version re-typed the name it had just uploaded, which is blind to
  Slice 8's bug **by construction**: the trim was invisible precisely because both sides of a
  hand-built comparison carried it. Rewritten to address the object through the path the *listing*
  produced, the way the app does, the negative control fires immediately — reintroducing the `<Key>`
  trim kills the download with `notFound` on `/probe10/edge/trailing`, Slice 8's symptom exactly.
  Two earlier controls were **inert** and worth recording so they are not tried again: handing the
  key over raw dies at the first verb rather than creating a sibling, and percent-encoding the
  separator changes nothing at all, because this endpoint normalizes `%2F` back to `/`.
- **5 — Time to first byte is 0.51 s, and the inherited 400 ms sheet delay is below the floor.**
  Five runs, 0.512–0.519 s, decomposing as DNS 0.003 + connect 0.17 + TLS 0.34 + ~0.17 s of server
  turnaround. Every request is a fresh `curl` — HTTP keeps no session, which is why the transport
  re-signs each time — so **half a second is the floor for any remote fetch on this endpoint**, not
  the cost of a large one. `CloudDownloadPrompt`'s 400 ms was tuned against iCloud materialization,
  where the wait is either ~0 or long; against a network round trip it means the sheet appears on
  *every* preview and is dismissed ~115 ms later. The threshold has to clear a round trip.

**The cancellation bug probe 1 found is fixed, 2026-08-14, across all three remote backends** —
taken deliberately wide rather than S3-only, because the slice is remote-generic by design and
because two spellings of one rule is the trap this milestone has now re-derived five times. The
seven byte-moving verbs of `S3Transport`, `FTPTransport` and `SFTPTransport` take an `isCancelled`;
the metadata verbs deliberately do not; and `ProcessWaiting.wait` is the one home of the poll that
replaces the single bounded `DispatchGroup.wait` all three transports had. +7 core tests
(`RemoteTransferCancellationTests`, one suite for all three rather than one test each, for the same
reason the fix is wide).

- **Re-measured on the server that found it: 16.98 s → 1.11 s** against a Stop pressed at 1.00 s,
  matching the 100 ms poll, with the server logging no `SERVED all` — the client really did go away.
- **The obvious assertion is worthless here, and the negative control is what showed it.** With one
  backend reverted, every `#expect(throws: CancellationError.self)` still passed: the *post*-transfer
  boundary check throws whether or not anything stopped, which **is** the shipped bug. Each test
  therefore rests on a record of whether the transfer verb was asked, and reverting FTP alone fails
  exactly its two tests and no others.
- **It makes a partial file possible for the first time, which is the hazard the plan expected to
  find already present.** A cancelled download now leaves 278 528 bytes of a 4 MiB object where it
  used to leave all of them. That is correct for F5 — it is the partial `-C -` resumes from — and it
  is precisely why the slice's cache must **drop** what a cancelled fetch left rather than keep it: a
  truncated file renders as a damaged document, not as an error. Probe 1's stated worry, arriving one
  fix later than expected.
- SFTP needed one thing the other two did not: only its interactive (password) path was ever
  time-bounded, so the key-auth path waits on `.distantFuture` and cancellation is the *only* thing
  that can interrupt it.

**The app pass landed 2026-08-14**, and both decisions the probes settled are in it: the deferred
sheet sits at **1200 ms**, which clears probe 5's 0.51 s floor with room for an endpoint twice as far
away, and `RemoteFileCache` removes a cancelled fetch's partial rather than keeping it. ⌘Y / ⌃Q, ⏎
and F4 all work on SFTP, FTP and S3 alike; a save is offered back up with the server re-`stat`ed
first. +25 app tests (2358 core, 444 app, both linters clean), three headless negative controls and
one live one, and 19 strings in all 14 catalogs.

- **Nothing is spent on cursor movement, and that is *structural* rather than a rule somebody keeps.**
  The passive path (`cachedRemoteFileURL` → `RemoteFileCache.cachedURL(for:)`) does not take a
  backend at all, and its freshness check reads the revision off the `FileEntry` the pane is already
  drawing — so it costs nothing, where the archive cache's equivalent affords a `stat` because an
  archive's `stat` is a syscall and a remote one is half a second and a bill. `showActivePreview`
  therefore has an `openRemotePreview` on its `unlocking` branch and *no* counterpart on the other,
  which is the difference from `+ArchivePreview` worth noticing when reading the two side by side.
- **The write-back's `stat` happens before the sheet, not after the user agrees** — so the sentence
  being agreed to is the true one, and the four `RemoteRevisionEvidence` cases become four different
  sentences instead of a confidence number. Six distinct bodies, asserted as six distinct strings:
  matching a phrase would pass on the sentence saying the opposite.
- **A successful upload re-baselines the recorded revision, and this is not optional.** Leaving the
  pre-upload one makes our *own* write read back as "someone else has edited it" on the next save —
  the one sentence in this feature that must never be wrong. It costs one extra request, and a
  failed re-read drops the entry rather than keeping a stale revision, since "cannot tell" is true
  where a stale one is confidently false.
- **F4's key and its menu validator had *already* drifted, before this slice touched them.** The key
  routed an archive member to its extracted copy (§M4) while `validateEditItem` still answered
  `backend == .local`, so Edit was gray inside an archive — and a disabled `NSMenuItem` swallows its
  own key equivalent, so F4 was dead there. Adding the remote branch beside it would have made that
  two misses instead of one. One `editRoute(for:)` now answers for both, verified live: **Edit with
  TextEdit / F4 enabled on a member of a `pkg.zip`**.
- **The negative controls each fired on exactly their own assertions.** Dropping the revision stamp
  failed the two staleness tests and left every request count at zero; never serving a cached copy
  failed reuse and re-baselining and left staleness untouched; keeping the partial failed only the
  cancelled-fetch assertion. And reintroducing Slice 8's `<Key>` trim killed the **live**
  whitespace-key test with `notFound` on `/dirnex-live-probe/slice10/trailing` — Slice 8's symptom
  verbatim, on a test that addresses the object through the path the listing produced rather than
  re-typing the one it uploaded.
- The placeholder card was rendered to a bitmap and looked at (it cannot be judged any other way),
  at 420 pt and at 300 pt: glyph, name, size and a hint naming ⌘Y and ⏎, wrapping inside its bound
  rather than overrunning it. `BlockingWork` became `public` — the transports block on a subprocess,
  so a fetch started from an AppKit controller is exactly the shape that type argues about, and a
  second spelling in the app would be the one place the reasoning is not written down.

**Live in the app, 2026-08-14 — and ⌘Y previewed nothing.** The slice had been verified by tests
(headless, live-integration and one bitmap) and never by pressing its keys, so this run did that
against the saved S3 account: ⌃Q drew the placeholder card on cursor movement and fetched when
switched on, ⏎ opened the object in TextEdit under its real name, F4 edited it, and the save came
back up with the re-baseline holding — a second save read "still has the size and modification date
it had", not "someone else has edited it". **⌘Y was the one that failed**, and it is this milestone's
most-repeated finding once more: `quickViewSourceURL` grew a remote branch at the app pass while
`quickLookURL(for:)` — the *other* resolver of the same question, the one the `QLPreviewPanel` data
source reads — kept its archive-only copy. So ⌘Y spent the download (the key does ask for one) and
then showed **“No items selected”** for a row the Quick View surface beside it was drawing
perfectly. The placeholder card names ⌘Y in its own hint, so the app was telling the user to press
the key that showed nothing.

- **The fix is a name and a deferral, not a third branch**: `previewsCursorFileOnly` (archive *or*
  remote — one file, the one under the cursor, once its bytes are here) and a resolver that hands
  everything non-local to `quickViewSourceURL` instead of resolving a second time. +4 app tests; the
  control neutered the predicate back to `isArchive` and failed on exactly the four remote backends
  while both local tests stayed green.
- **What isolated it was a *cached* row.** Pressing ⌘Y on an object whose bytes were already on
  disk still said "No items selected", which removes the fetch from the question entirely and points
  at the data source. Worth reaching for whenever a surface that depends on a transfer looks broken.
- **The empty panel on an un-fetched row is deliberate and is the cost.** Quick Look is Apple's
  window and cannot be handed our placeholder card, and `refreshQuickLookIfVisible` runs on every
  cursor step — so fetching there would be the arrow-key spend the whole slice is built to avoid.
  Re-verified after the fix: arrowing onto an un-fetched row leaves the panel empty and downloads
  nothing. Said out loud in that function's doc comment, since "add the remote counterpart here" is
  the natural-looking edit that would undo the rule.

**The ETag field has a producer, 2026-08-14.** It shipped at the core pass with none — named above as
changing `isSuperseded(by:)`'s *rule* rather than its inputs — and S3 sends `<ETag>` on every
`ListObjectsV2` row, which is the same response a row is already built from, so the strongest
comparison available costs no request. `FileEntry.entityTag` carries it (defaulted, so every other
producer is untouched), `S3ListingParser` keeps it **with its quotes** through both the listing path
and the `entry(forKey:in:at:)` path `stat` uses, and `RemoteFileRevision(_ entry:)` reads it. +6 core
tests, 2364 core / 452 app green, both linters clean.

- **Two producers means two controls, and each fired on its own half**: dropping the parser's `ETag`
  case failed the five parser-side assertions while the revision tests (which build entries by hand)
  stayed green, and making the revision ignore `entry.entityTag` failed exactly the two revision
  tests while the parser's stayed green.
- **The live suite caught the change itself, in the informative direction.** Its untouched-object
  test asserted `.sizeAndTimestamp` — the honest answer while nothing supplied a tag — and now reads
  `.entityTag` against the real third-party endpoint, which is the measurement that says that
  endpoint really does send them. It now also pins that the tag is non-`nil` and that both readings
  carry the *same* one, so the evidence case cannot pass by both sides being empty.
- **The visible half is a sentence that had never been reachable.** `.entityTag`'s body — "The file
  on the server is byte-for-byte the one you downloaded" — was dead code with a full set of
  translations. Live now on every save: the F4 → edit → ⌘S sheet draws it, and a second save after
  an upload draws it again rather than reporting our own write as somebody else's.
- The tag is opaque and compared only against another reading of the *same* object — an AWS tag is
  an MD5 for a single-part upload and a digest-of-digests with `-<parts>` for a multipart one — so
  the parser keeps it verbatim and nothing reads into it. An empty `<ETag>` is `nil` rather than
  `""`, or two tag-less objects would compare equal and be read as proof neither had changed.

**Rename's two spellings, 2026-08-14 — the fifth instance, and the first that was wrong in both
directions at once.** Found while verifying this slice live: with the cursor on an S3 object,
File ▸ Rename… and Multi-Rename were **gray while F2 itself worked**. `S3Backend` advertised
`[.read, .write]` with `moveItem` implemented since the write half shipped — a miss, not a decision,
since FTP and SFTP have carried `.rename` since they shipped and the live bucket already held an
object renamed through the UI — so it is `[.read, .write, .rename]` now. But the capability was only
the half that was *visible*: `beginRename` and `beginMultiRename` guarded on `backend.capabilities`,
the composite's backend-wide set, which is always the **local** backend's, while `validateMenuItem`
asked `capabilities(for: panel.path)`. Both compile everywhere and they are different questions.
One predicate — `canRenameHere`, carrying `!isVirtualDirectory` as its second half — is what the two
flows and the two menu items now all read. +4 tests (`RenameReachTests`, plus a live one), 2364 core
/ 456 app green, both linters clean.

- **The other direction was the merged iCloud listing, and nothing had reported it**: the item was
  *enabled* over a flow that returned in silence, because those rows are ordinary local files (so the
  capability says yes) inside a listing with no directory of its own. Graying it is the honest answer
  — half those rows are an app's `Documents` folder wearing the app's name, which is not what
  renaming them would do. Fixed by the same predicate, in the same edit.
- **Three negative controls, each failing only its own assertions**: withdrawing `.rename` from
  `S3Backend` (the capability tests, plus the connected-bucket rows), reverting the two flows to
  `backend.capabilities` (only the key's refusals, and only where the two sets differ), and dropping
  `!isVirtualDirectory` from the predicate (only the iCloud row, in all three tests).
- **A fourth control is deliberately absent and the reason is recorded in the suite**: a reverted
  `beginMultiRename` presents an app-modal window from the test host, which **wedges** the run
  instead of failing it. The F2 half is drivable and needs `loadViewIfNeeded()` to mean anything —
  measured, without it the whole suite passes against a reverted flow, because an unloaded pane's
  table has no columns and the flow returns one guard later.
- **Verified live against the saved account**: the item is enabled on an object, and renaming through
  it re-lists with the new name, the same 42 bytes, a fresh `LastModified`, and the old key gone.
- **The folder caveat is measured rather than inferred, and it is unchanged by any of this.** F2 on a
  prefix draws «Can't rename "docs" — The system reported an error (code 18)»: `moveItem` answers
  `EXDEV` for a prefix, which is the request `CopyEngine` runs as a recursive copy-then-delete, and
  inline rename calls the primitive directly. Nothing is written (the folder is untouched
  afterwards), and it was reachable by key before this change; what is new is that the menu item now
  reaches it too. Worth a decision of its own — either a named `VFSUnsupportedReason` in place of the
  raw errno, or routing a prefix rename onto the operation queue. **Taken 2026-08-14, the second
  way** (below).

**A folder rename runs as a job, 2026-08-14 — the caveat above, answered.** F2 and ⇧F2 on an S3
prefix now do the thing rather than name the reason they cannot: `EXDEV` is handed to the queue,
which already knows how to finish it. `FileOperation.renamedTo` with its
`init(renaming:to:in:)`, one line in `CopyEngine`, `PanelViewController+RenameQueue` and one
`submit(_:)` both transfer paths share; +7 core tests, +4 app tests, 2371 core / 460 app green,
both linters clean, 4 strings in all 14 catalogs.

- **Nothing new moves bytes, which is the whole reason it was affordable.** `moveItem` has answered
  `EXDEV` for a prefix since Slice 4, and `CopyEngine.perform` has turned that into a recursive
  copy-then-delete for longer than S3 has existed here — with a determinate bar, Stop, the conflict
  policy, per-item failures and an undo record from the outcomes. What was missing was a job that
  lands its **one** source under a *different* name, which is four lines of value type.
- **A field on a `.move`, not a `Kind` of its own.** A rename that reaches the queue *is* a move; a
  `.rename` kind would fork every `switch` over `Kind` — four label sites in the app, the undo
  journal's label map, `CopyEngine`'s own `kind == .move` tests — to change a caption on a job whose
  behavior is identical. Only `init(renaming:to:in:)` sets the field, so "several sources under one
  new name" is unrepresentable rather than merely undocumented, and the queue bar's "Move" is
  preceded by a confirmation that says what is really about to happen.
- **The confirmation is not politeness.** A prefix rename is N billed copies and N deletes with no
  atomicity available at any layer (§ the permanent consequences above), so the sheet says so —
  including that stopping partway leaves some items under each name, which is the one outcome a user
  cannot infer from a progress bar. F2 on a local folder is untouched: a local rename never crosses
  a volume, so it never reaches this.
- **The undo half was a guard resting on an invariant this change retires**, and it is the milestone's
  own lesson arriving in the core rather than the app. `UndoJournal.crossVolumeRestore` required
  `from.lastComponent == to.lastComponent`, with the reason written out — "a rename never crosses
  volumes, so it never gets here" — so ⌘Z on a queued rename would have refused **exactly** the
  operation it was reached for, `EXDEV` on a restore that had nothing wrong with it. It now builds
  the same rename operation, which for a same-name move is `entry.name`: one path, no branch, and no
  invariant left for the next backend to break. The tell to grep for is a comment explaining why two
  things *cannot* collide (docs/NOTES.md ▸ Design lessons).
- **⇧F2 came with it rather than after it.** Multi-rename swallowed the same `EXDEV` into "Couldn't
  rename 3 items — The other items were renamed", so fixing F2 alone would have been this milestone's
  most-repeated finding once more. Both flows now classify through one `RenameDeferral` and enqueue
  through one funnel; the batch's *other* failures are reported from the confirmation's completion,
  since a second sheet raised on a window that already has one is queued invisibly.
- **What the app tests can and cannot reach, said out loud in the suite.** The classification and the
  operation are pinned headlessly — including that the job takes the **row's own** directory, which
  in a tree is not the pane's, the second-index-space trap inline rename already hit for real. The
  flow itself is not driven: it ends in a confirmation, and on a window-less pane that is
  `NSAlert.runModal()`, which **wedges** a run rather than failing it (`RenameReachTests` measured
  that cost for ⇧F2's modal window). The keystroke is verified live instead.
- **Two negative controls, each failing only its own assertions**: reverting `CopyEngine` to
  `entry.name` failed the four rename tests while the ordinary-move and `landingName` ones stayed
  green, and restoring `crossVolumeRestore`'s name guard failed exactly the undo test — with the
  reoccupied-name test still passing, which is what says the guard that was removed was the right
  one.
- `UndoJournal.swift` reached SwiftLint's 500-line ceiling on the way, and was split by concept
  rather than shaved: `UndoJournal+Revert.swift` now holds everything that touches bytes, leaving the
  stacks and the record builders behind. (`swiftformat --lint` had also been failing on
  `S3AccountLiveIntegrationTests.swift` since the previous commit; fixed in passing.)

**Verified live against the real third-party bucket**, with the server's own listing as the judge
rather than the pane's. A `renameprobe/` prefix holding `alpha.txt` and `sub/beta.txt`: F2 → the
sheet reads «Rename "renameprobe" to "renamed-probe"?» → the queue bar shows *Moving renameprobe* →
the pane re-lists under the new name, and an independent `ListObjectsV2` holds
`renamed-probe/alpha.txt` and `renamed-probe/sub/beta.txt` with `renameprobe/` gone and the bytes
intact. Then three more, because each is a branch the tests cannot drive: **⌘Z** put the whole
subtree back under `renameprobe/` (the widened `crossVolumeRestore`, live); **Cancel** wrote nothing
at all — no `should-not-happen` key anywhere in the bucket; and **⇧F2** raised the identical sheet
through the batch path and landed `batchprobe/` with both files. Probe data removed afterwards.

**One thing the run found that is *not* about this feature, and is worth its own decision.** With the
four new app tests in, `S3AccountLiveIntegrationTests`' first test times out in the **full** parallel
run — 72 s and 209 s on two runs — while passing in 1.2 s on its own, and passing beside
`RemoteFileEditLiveIntegrationTests`. Three controls place it: skipping the four new tests → 455
green in 27 s; keeping them and skipping `RenameReachTests` instead → 456 green in 18 s; and
`-parallel-testing-enabled NO` → **all 459 green**. So it is the live suite's tolerance for parallel
load, not the change: a fourth `@MainActor` pane-building suite is enough to starve a connect that
blocks on `curl`, and the failure surfaces in the shared `connectedPane` helper, which reads as the
feature being broken (docs/NOTES.md ▸ Testing already records that shape for the same suite). What it
needs is a decision about how the live suites run, not another `.serialized`.

All three stop at one predicate today. `quickViewSourceURL` resolves a local path or an already
extracted archive member and answers `nil` for anything else, so an S3 row previews nothing; F4 says
«Only files on this Mac can be edited — copy it out first (F5)»; and ⏎ falls off the end of
`activate`'s chain and does nothing whatsoever, with no message at all. The workaround is the round
trip F4's own sentence describes, and automating it is what every other client in this space sells.

**The shape is settled by what those clients do, and it is the FTP shape.** Cyberduck's Edit
downloads to a temp directory, opens the preferred editor and uploads the revision on save — one
funnel for S3, SFTP and WebDAV alike — and its space-bar Quick Look is that same fetch without the
editor. Transmit is the same, down to uploading while its own window is hidden behind the editor's.
The other family mounts the bucket (Mountain Duck, ExpanDrive, `rclone mount`) and is not ours to
build: that is a File Provider extension, a different product with a different lifecycle. Nobody
streams — an editor and a Quick Look plugin both want a real file, so every client pre-downloads.
Dirnex already owns that machinery for archive members (§M4's extract → watch → offer → write back);
this slice points it at a second kind of elsewhere.

Three decisions taken before any code, each with the alternative it beat:

- **Remote-generic, gated on `isRemoteConnection`.** SFTP and FTP arrive with S3: all three answer
  `copyFile` in both directions and all three carry `acceptsUploads`. Writing it against `isS3`
  would be the fourth instance of the finding this milestone keeps re-deriving — one question,
  several spellings, and the compiler checks none of them.
- **The cursor never downloads.** Quick View follows the cursor, so a preview that fetches on an
  arrow key spends a billed request and someone's bandwidth because the cursor passed over a row.
  Same fork as Quick View's JavaScript switch and Enter-vs-Unlock, and settled the same way: "is
  this safe" and "should this happen unasked" are different questions. `updateQuickView(unlocking:)`
  already carries exactly this distinction for encrypted archives, so it is a branch and not a new
  mechanism — `prepareRemotePreview` reads the cache and never fetches, `openRemotePreview` is the
  key somebody pressed and may. Cursor movement draws a placeholder naming the file and its size.
- **A save re-stats before it writes.** S3 has no locking and a save is a whole-object PUT, so the
  ordinary hazard is silently overwriting an edit someone else made in the meantime. Record size and
  mtime at download, re-`stat` before uploading, and on a difference say so and let the user choose.
  One extra request per save on every S3-compatible endpoint, where a conditional `If-Match` PUT is
  stronger and needs its own probe first (whether `curl` signs it under SigV4, and whether anything
  but AWS honours it) — parked, not rejected. Note the check is **weaker on FTP**, whose `LIST`
  stamp is year-less, zone-less and on the server's clock (NOTES.md ▸ curl): say that plainly rather
  than implying a guarantee the protocol cannot give.

**Probes first, and these are the ones that can change the code that gets written:**

1. **Cancel mid-GET.** `copyFile` takes `isCancelled`; measure that Stop on the download sheet
   really kills `curl` and leaves **nothing** in the cache — a half-downloaded object cached as a
   preview is the quiet direction, since it renders as a truncated file rather than as an error.
2. **A Glacier object.** PUT with `x-amz-storage-class: GLACIER`, then GET: expect `403
   InvalidObjectState`. Backup buckets are exactly where a file manager gets pointed, and the
   preview has to say "this object is archived and must be restored first" rather than the generic
   refusal. Cheap, and only measurable against a real endpoint.
3. **Read-after-write on the third-party endpoint.** The conflict check assumes a `stat` sees a
   write that has already landed. AWS has been read-after-write consistent since 2020; the endpoint
   from Slice 8 has promised nothing, and it is the one that has already inverted two rules.
4. **The edge-whitespace key, again.** Slice 8's trailing-space object broke every verb that builds
   a URL from a name while `stat` kept agreeing with the listing. Download-and-upload is two more
   such verbs, so the same object goes through this path before it ships.
5. **Time to first byte for a small object**, to check the 400 ms sheet delay inherited from
   `CloudDownloadPrompt` is still the right threshold — it was tuned against iCloud
   materialization, not against a network round trip.

**Core first (additive, app untouched).** `RemoteFileRevision` — size + mtime + an optional ETag,
built from a `FileEntry`, with `isSuperseded(by:)`; deliberately *not* `EditedFileRevision`, which
answers the opposite question for a local temp copy and must keep ignoring the inode. Plus the pure
rule for when an explicit fetch is big enough to confirm first, as a table rather than a constant
buried at a call site. No `VFSBackend` change: the revision comes from `stat`, which every remote
backend already answers, so the protocol surface stays where it is.

**Then the app.** A window-scoped `RemoteFileCache` beside `archivePreviewCache`, keyed by `VFSPath`
(which carries the backend id, so two accounts cannot collide) and **stamped with the revision** —
the `ArchiveIdentity` lesson's second instance: a cache keyed by a path outlives the object that
path named, and here it would hand over the previous object's bytes under the new object's name.
Each download lands in its own directory under the same temp root, keeping the file's real name,
because the editor shows that name and the edit watcher watches the *directory*. Then
`PanelViewController+RemotePreview` (the passive/explicit pair, mirroring `+ArchivePreview` line for
line), the remote branch in `quickViewSourceURL`, a placeholder card for the preview surfaces, the
F4 branch replacing the refusal, and write-back on the window rather than the pane — an edit
outlives whatever the panes are showing, which is why `+ArchiveWriteBack` already lives there.
`ArchiveMemberEditRegistry` generalizes to carry a destination (an archive member or a remote path)
so there is **one** save-detection mechanism with two endings; the remote ending differs in one way
worth writing down, that it keeps watching after a successful upload and re-baselines the revision,
because the editor still holds that same copy and a second save must offer again.

**Two things the compiler will not check**, both named here so they are not rediscovered. The
transfer is a blocking subprocess wait, so it belongs on `BlockingWork` and not in a
`Task.detached` — the cooperative-pool finding, which `ArchivePreviewCache` predates and should
follow later. And F4's refusal sentence and its **menu validator** are two copies of one predicate
(the size-bar lesson): change one and the key works while the item stays gray, which no headless
test drives.

**Tests, with the negative controls that make them evidence.** Core: the revision table and the
confirm rule. App: the cache drops a stale entry and keeps a fresh one (neuter the stamp — the first
must fail while the second passes, or the "fix" is really "re-download every time"); the registry
routes both destinations; F4 validates enabled for a remote file. The claim that matters most is
testable directly — a fake transport that **counts requests** while the cursor walks five rows must
stay at zero, and neutering the passive/explicit split must break exactly that count. Live, in
`S3AccountLiveIntegrationTests` (`.serialized`, gated on its config file): download → edit → save
back → verify the bytes with an independent GET, plus the conflict path, driven by mutating the
object between the download and the save.

**Deliberately out of scope.** Range requests for a partial preview (a truncated image or PDF
renders as damage, and a head-of-file text preview is a second rendering path for one case);
local version history of the kind Cyberduck keeps in its editor preferences; and any form of mount.
The ⏎ gesture is *in* scope and uses the same funnel with the same watch, because leaving it
silently dead beside a working F4 is stranger than either.

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
| M19: a forgotten passphrase is **unrecoverable**, and it is the only feature in Dirnex whose failure is silent, total and permanent — no undo journal, no Trash, no support call | The confirmation wording matters more than any code here, so it is a milestone deliverable rather than a detail: the create sheet says plainly that a lost passphrase means lost data, and both the pack sheet and the vault sheet require the passphrase **twice** before a byte is written (`passphrasesDoNotMatch` is a named error, not an assertion). Dirnex never deletes the originals after encrypting them — it creates and populates, and the user removes, because "encrypt these files" naively implemented is create → copy → delete, and that delete puts **plaintext in the Trash**. Spotlight's index, Quick View's caches and the thumbnail store are the same family of leak and are a stated Slice 2 decision rather than silence. **Held, and the derived-data clause was closed by fixing rather than by stating (2026-08-09).** The wording shipped in both sheets as a `static let` whose doc comment names this row as its reason (`VaultCreateAccessory.passphraseNote`, `PackAccessory.encryptionNote`), `passphrasesDoNotMatch` is a named case in both error enums checked before a byte is written, and nothing is ever deleted after encrypting. The three leaks this row *named* were then measured and **none of them is real**: a disk-image volume is not Spotlight-indexed at all (controls: the boot volume is, and an unencrypted image is not either, so it is the image and not the encryption), and a real `QLThumbnailGenerator` request cached nothing anywhere. What was real was Dirnex's own — the frecency index records every local directory and `PersistedTab` carries the cursor's and marks' file names, both surviving the lock — so `VaultPrivacy` (core) and `VaultMounts` (app) now keep vault paths out of **implicit** memory, while an explicitly saved workspace or favorite keeps working. Verified live with a control token that had to appear. HISTORY.md §M19 ▸ Follow-up |
| M19: linking libarchive is an exception to §2, and exceptions spread | It is confined by construction, not by discipline: `CArchiveShim` declares only the ~30 symbols the encrypted path calls, so reaching for anything else is a visible edit to a header whose doc comment argues the whole exception. The tell that the boundary is going is a `bsdtar` call site being replaced with a libarchive one for a reason *other* than a passphrase — performance, or progress, or tidiness. Those are real benefits (all three measured) and none of them is this exception's justification. **Held through the milestone**: the header carries 38 prototypes and no constants, every `bsdtar` call site that existed still exists, and the one new *queued* path (`PackJob` / `PackRunner`) is encryption-only by its own doc comment — the queue is where encrypting happens, not where packing moved to. The place to watch next is that boundary from the other side: an unencrypted `.none` job is legal and runs through the same writer, kept so the two cannot drift, and it would be the cheapest way for "ordinary packing" to arrive on this path without anyone deciding to move it |
| Full Disk Access friction kills onboarding | Dedicated flow in M7; app degrades gracefully (browse home dir) before grant |
| Scope creep before the feel is right | M1 exit criteria are the gate; nothing from M3+ starts until M1 feels great |
| A system-CLI quirk changes under us (M13's TLS-1.2 pin for FTPS is a workaround for `curl` 8.7.1, not a property of the protocol) | The flag lives in a pure, tested `FTPProcessArguments` with the reason in its doc comment, so it is one place to re-measure — and a listing that comes back empty is the *symptom*, so an FTPS smoke test asserts non-empty rather than merely "no error" |
| M17's highlighter grows into a parser by accretion — one heredoc, one regex literal, one interpolation at a time, each individually reasonable | The scanner's boundary is written into the milestone as a list of *decisions*, and each one carries a comment at the place in the grammar where it would have been handled. The tell that the boundary is being crossed is a grammar gaining a **state stack**: a single pass with one lookahead is the whole design, and anything needing to remember where it has been is a parser, which is a compiler's job and not a preview's. The affordable escape hatch is that highlighting only ever *adds* foreground color to a document that already renders correctly — so a construct the scanner gets wrong is a wrong color, never a wrong character, and the honest fix for a hard one is to stop coloring it. **Held through the milestone, and the escape hatch was used**: `prefix` and `postfix` came out of the Swift keyword set rather than gaining a rule, because both are contextual and `prefix` is one of the language's most common method names (HISTORY.md §M17 ▸ Slice 1). No grammar gained a state stack; the closest anything came is one `Bool` inside `SyntaxMarkupScanner.scanAttributes`, which is a lookbehind of one token and is argued at the site |
| M18's Markdown renderer chases CommonMark, and its mermaid subset chases mermaid — both indefinitely, one individually reasonable case at a time. The renderer has it worse than M17's scanner, because a wrong answer here is a wrong *document* rather than a wrong color | Two different mitigations, because the two halves fail differently. For **markdown**, the target is named as a corpus rather than as a spec — this repo's own files, plus whatever real `.md` the next bug report arrives with — and the escape hatch is that an unreadable construct falls back to its literal text, so the worst outcome is a paragraph that looks like its source. For **mermaid** the boundary is a *list of diagram types*, and crossing it is loud by construction: an unsupported type renders its fence with a note naming it, so the pressure to add one shows up as a user asking rather than as a silently wrong drawing. The tell that the mermaid half is going wrong is the layout gaining knobs — mermaid has a config surface of its own, and reproducing it is how a subset becomes a port. **Held through the milestone, and both escape hatches were used**: the markdown half is pinned by a corpus suite over this repo's own `PLAN.md`, `README.md`, `NOTES.md` and `HISTORY.md` rather than against the spec's test cases, and the mermaid half reports by name — not only an unsupported diagram *type* but an unsupported construct inside a supported one (`subgraph`, `loop`, `alt`, `style`), which is more than the milestone asked for and in the same direction. The one thing that did arrive is the knob the risk names: a `diagramScale` and a shared `labelSize` (HISTORY.md §M18 Slice 4), both of them constants the *app* sets once rather than a config surface read out of the diagram's own source, which is the line worth keeping |
| The tree becomes a *second* pane implementation by accretion — a refresh path, a mark gesture or a sort that quietly forks from the flat one | The tree is a flat projection over the same `NSTableView` and the same index space, not a parallel surface (HISTORY.md §M15 Slice 4); anything that forks is a signal the projection is wrong, not that the tree needs its own copy. Both fork points were answered in the slice — `SizeVisualization`'s per-directory assumption (the bars were withdrawn in tree mode at M15 close, then re-scoped *per parent directory* rather than forked — `SizeVisualization(tree:)` groups each row against its own level, so the projection stays one definition of "share of this folder") and the `installSortedModel` → `reloadEverything` → `syncCursorToTable` tail. It arrived once already, as the *second index space*: six `panel.model[row]` sites that crashed on the first click below the root's last entry, now routed through `displayedIndex(ofID:)` — NOTES.md ▸ AppKit |

## 7. Open questions

**Open now:** none. M19's two were taken at open and M18's one likewise (both below); M15's two
closed with it, and M17's one closed at open and was then
**re-taken twice** (2026-08-06, every time by the user):

- **How much of a syntax theme the user owns** — resolved in favor of **a small fixed set of
  semantic kinds, no Settings surface at all**. That half never moved. What moved, twice, is where
  the colors come from. The question closed on *system dynamic colors*, on the ground that each
  resolves per appearance for free — and Slice 3 measured them and found `.systemGreen` at
  **2.22:1** on a white text background, with teal, cyan, mint, orange and yellow all between 1.5
  and 2.4. The system palette is tuned for fills, not for text on white, so the premise held in
  dark mode and collapsed in light. Re-taken as authored light values with the system color in
  dark; then re-taken again, the same day and on sight of the result, as **VS Code's Dark Modern
  and Light Modern on both halves** — the `dark_plus` / `light_plus` token colors. The reason is
  not aesthetic preference but *whose* theme: a preview is read next to the editor the file will be
  opened in, and matching that editor is worth more than any hue chosen in isolation. It cost
  nothing to check — every published value clears the same ≥ 4.5:1 floor `SyntaxThemeTests` already
  pinned, in both appearances, because `.textBackgroundColor` resolves to exactly `#1E1E1E` in
  dark, which *is* VS Code's editor background. Everything the original answer was *for* survives
  both moves: one `NSColor` per kind, resolving itself, no picker, no persistence. Reopening the
  *owned-theme* half still means the M15 palette machinery (persistence, a Settings section, a
  derived-foreground rule), which is why it stays written down.
- Kind count is the one detail the answer no longer pins: it opened at "six and no more" and is
  **eight**, `.inserted` and `.deleted` having been added with the diff scanner (HISTORY.md §M17
  ▸ Slice 2). That is two more entries in the same dictionary, not a Settings surface.

Opened with M18 (2026-08-06) and **closed at open, by the user**:

- **Where mermaid diagrams come from** — resolved in favor of **a hand-rolled SVG renderer in the
  core, over a named subset (flowchart and sequence)**, against the alternative of vendoring
  `mermaid.min.js` and running it in the preview. The fork is real because the two answers cost
  opposite things: bundling buys every diagram type mermaid supports, at ~3 MB of third-party
  JavaScript, a JS engine running on every cursor step, and output §2 cannot test — which is
  Highlightr's and tree-sitter's rejection at M17 arriving in a different shape. Hand-rolling buys a
  pure, tested renderer with no dependency and no script in the page at all, at the price of a
  subset that will visibly diverge from what the user's editor draws. The security half turned out
  *not* to be the deciding argument in either direction: escaping the file's raw HTML (M18, above)
  already means no script from the `.md` reaches the page, so a bundled mermaid would have been
  running our code over the file's data rather than the file's code — a materially different posture
  from M16's toggle, and one that would have needed saying out loud in the JavaScript policy.
  Reopening it means taking on a vendored asset with its own update cadence, which is why the
  reasoning stays written down.

Opened with M19 (2026-08-09) and **closed at open, by the user** — both are format commitments that
outlive the code, which is why they are written down rather than left in the implementation:

- **Which cipher an encrypted archive uses** — resolved: **AES-256 and nothing else.** `zipcrypt` is
  the only choice every Windows and macOS unzip can read and it has a published known-plaintext
  break, so offering it under a checkbox saying "Encrypt" would be the app lying; AES-128 is sound
  and buys nothing on hardware AES. The price is paid by the recipient rather than by us and is
  therefore stated in the sheet: nothing Apple ships opens an AES-256 zip (measured — `unzip`,
  `ditto` and Archive Utility all refuse it), so Keka, 7-Zip or WinRAR is required at the other end.
  Reopening it means deciding that reach is worth a broken cipher, which is the whole argument in
  one sentence.
- **What a vault is made of** — resolved: an encrypted APFS **sparsebundle**. It is growable, so the
  user is never asked to predict how much they will ever store (23 MB for a declared 10 GB), and
  unlocked it is an ordinary mounted volume `LocalBackend` already browses, so the milestone added
  no backend. What it costs is that a vault is a *directory* and therefore awkward to send — which
  is the archive half's job, and the reason the milestone has two halves.

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

Opened with M15 (2026-08-02) and **closed** in it the same day, as recommended — both about what a
*marked set spanning directories* means for an operation:

- **What F5/F6 do with marks spanning levels** — resolved: **TC's branch-view behavior**, flatten
  *preserving relative paths* under the destination. Copying everything flat into one folder is the
  alternative and it silently collides the moment two folders hold an `x.jpg`.
- **F8 with an ancestor and its descendant both marked** — resolved: **dedupe to the ancestor**
  before enqueuing, since deleting the parent already takes the child. Implementing it added the half
  the settling did not say: **the dedupe belongs to F5/F6 too** — a copy fails *politely* there, with
  a conflict prompt over a file the user never chose to duplicate, which is quieter and no less wrong.

Both live in `TreeSelection` (core, 18 tests); the app keeps one `recursiveTargets()` for the
operations that recurse and the raw `selectionTargets()` for the ones that don't. See
[HISTORY.md](docs/HISTORY.md) §M15.
