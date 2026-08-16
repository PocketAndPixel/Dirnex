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

**The run also found a real bug in the app, and it was found by the *user watching the screen*.** The
full suite had begun failing `S3AccountLiveIntegrationTests`' first test — 72 s and 209 s on two runs
against 1.2 s alone — and three controls pointed at parallel load (skip the new tests → green;
skip `RenameReachTests` instead → green; `-parallel-testing-enabled NO` → all green), which was a
plausible reading and the wrong one. Oleg reported dismissing **six modal alerts, one after another,
from a single test-host run**, and their titles are `RenameReachTests`' fixture table read aloud:
«Can't open "dir" — Not connected to s3://AKIAEXAMPLE@…», `pkg.zip`, `search:/Results`,
`trash:/Trash`, `icloud:/`.

`viewDidLoad` → `activateTab()` → `navigate(to:)`, and a failed listing ends at
`presentLoadFailure`, whose `runModal` fallback fires whenever the pane has **no window** — which is
every pane a headless suite builds. So the suite that has to call `loadViewIfNeeded()` (§ the rename
reach fix, one commit earlier) put an app-modal alert on screen for each non-local row and **blocked
the whole process until a human clicked OK**. The "timeout" was the live suite waiting behind them;
the run's duration was measuring reaction time.

- **Fixed by not raising it at all with no window.** This is the one alert that fires *unasked* — a
  navigation the app performs on its own — so a pane nobody can see has nobody to tell, and the
  same shape is reachable in the app during launch restoration, before `showWindow`. A pane on
  screen still gets its sheet.
- **Measured both ways**: 459 green in **16.2 s** with the guard, and the reverted version put the
  identical queue of alerts back, taking **111 s for eight tests** — all of it dismissing dialogs.
  That also retires the parallel-load theory: every earlier timing, including the three "controls",
  was reaction time.
- **The lesson is about the instrument.** Three headless controls agreed on a wrong cause, because
  each of them changes *how much runs* and none of them can see a window. The signal that settled it
  was a person looking at the screen — the same class as the menu-bar claim M20 shipped and the
  `.stringsdata` sweep that never ran. Recorded in docs/NOTES.md ▸ Testing.
- **The other 48 `runModal` fallbacks were audited, and the question that sorts them is "who is
  waiting for the answer?"** Three kinds share one `else runModal()`: a **user** pressed something
  (the great majority — keep the fallback, a detached alert beats no answer); a **blocked worker** is
  parked on it (`ConflictDialog`, `ErrorDialog`, called from the copy thread — here `runModal` is
  *required*, since dropping it hangs the job or silently picks a resolution); and **nobody** is,
  because the app raised it on its own schedule. Only the third is the bug, and it was six sites:
  the load failure, both write-back offers (a watcher notices the editor's save), and the queue's
  failure / pack / checksum reports — plus `presentIssues`, dual-triggered by ⌘Z *and* a
  recursive-apply job. All six now share `NSAlert.beginSheetIfVisible(over:)`, so the rule lives in
  one doc comment instead of six copies of `if let window`, and they gain `sheetHost(over:)` — a
  report landing while a dialog is up attaches to that dialog rather than queueing invisibly behind
  it. Two launch-time one-shots (the displaced-script notice, the Full Disk Access wall) are
  unprompted too and were left alone on purpose: each is handed a window by construction and each is
  marked shown once presented, so dropping one would consume it in silence. 459 green in 15.0 s
  afterwards, with the screen watched.

**The preview stopped following the cursor, 2026-08-14 — reported by a user, and the rule it was
protecting was not the rule it was enforcing.** With Quick View up on a bucket root, entering
`photos/` drew the placeholder card for the file inside and never resolved it: `showActivePreview`
had `openRemotePreview` on its `unlocking` branch and *no* passive counterpart at all, so the only
row a session ever fetched was whichever one the cursor happened to be on when the mode was switched
on. The rule — "an arrow key never spends a billed request" — is real and is kept. What shipped
instead was "one file per time you turn Quick View on", which is not a rule anybody could have
discovered, and which read as the feature being broken. The fork was put to Oleg with three options
(auto-fetch with bounds / explicit-only with a working affordance / fetch once per directory) and the
first was chosen, paired with the card fix the third of them would still have needed.

- **`RemoteFetchPurpose.cursorPreview` is the whole core change, and its point is that a refusal is
  not a size.** It shares Preview's 16 MiB rather than minting a lower number that would mean nearly
  the same thing — the argument the table's own doc comment already makes for open and edit — and
  what differs is the new `RemoteFetchDecision.decline`: an automatic gesture over its threshold must
  **not confirm**, because a dialog raised because the cursor came to rest somewhere is itself a
  question nobody invited. `isAutomatic` names that rather than the one call site spelling
  `== .cursorPreview`, so a second automatic gesture inherits the answer.
- **Three bounds, and each is load-bearing on its own.** A 400 ms **settle delay** (a held arrow key
  repeats every 30–90 ms, so travelling requests nothing); the **size cap that declines**; and
  **abandonment when the cursor leaves**, which is what makes 16 MiB safe rather than merely small —
  the user pays for the seconds they were looking at the row, not for the file. Single-flight is
  structural: `RemoteFileCache` holds one pending fetch, because there is one preview and it follows
  one cursor.
- **The obvious cancellation test was worthless, and only a negative control showed it.** Every
  assertion passed with `cancelAutomaticFetch` neutered to a bare `automatic = nil`, because a fake
  backend that finishes inside the same turn is satisfied by the scheduler's identity guard and never
  reaches the transfer. A `.block` outcome that sits until `isCancelled` — plus a record of whether
  it was *told* to stop — is what pins the claim, and it fails on demand. Same shape as probe 1's
  finding one pass earlier: `throws CancellationError` is not evidence that anything was interrupted.
  The other two controls fired on exactly their own assertions (settle delay → five transfers for one
  sweep; failure memory → a retry loop, `copyCount` 2).
- **The card grew the state it always needed**, and the ⌘Y hint it used to carry was replaced: with
  small files now arriving on their own, what remains on screen is a *large* one, so the card says
  which of three things is true (over the threshold / size unreported / downloading / the attempt
  failed) and carries a **Download** button — the one control exempted from the surface's blanket
  "swallow the mouse", exempted at the *button* rather than the card so the exemption is exactly as
  large as the affordance. It routes through `RemoteFetchPrompt.fetchConfirmed`, since the card draws
  the name and the size directly above the button and `RemoteFetchPolicy`'s confirmation would be
  asking a question the click has just answered.
- **The ⌘Y panel gets the same fetch, which retires half of the cost recorded above.** That panel
  used to be empty for *every* un-fetched row; now it is empty only for one over the cap, since Quick
  Look is Apple's window and still cannot be handed our card. One transfer serves both surfaces, so
  the landing re-drives both rather than taking a callback from whichever scheduled it.
- **Verified live against the real bucket, in both directions.** The isolating run turns Quick View
  on with the cursor on a *folder* — so the mode-on fetch does nothing and only the automatic path
  can produce a preview — then arrows onto a file: the card resolved into a rendered preview. Then
  the reported case itself: into `photos/` with the preview still up, and `one.txt` drew its
  contents. The over-threshold half was reached by temporarily lowering the automatic threshold to
  **4 bytes** and rebuilding, which is what put the real card on screen (glyph, name, size, sentence,
  button) and let the button be clicked — one click, no confirmation, preview shown. 2383 core / 481
  app green, both linters clean, 4 strings in all 14 catalogs.

**The threshold became the user's, and the card learned to report, 2026-08-14 — asked for by the same
user in the same breath as the report above.** A photographer working in 40–300 MB raw files is the
case the 16 MiB cap is wrong for, and a fixed number cannot be right for both them and someone on a
tethered connection; and a preview that fetches on its own has to say what it is doing, or a slow link
is indistinguishable from the mode being broken again.

- **The limit is a preference the *core* reads as data, not a constant it owns.**
  `RemoteFetchPolicy` now takes the automatic cap rather than holding it, so the table keeps deciding
  and Settings decides the number: `AppPreferences.quickViewFetchLimit`, in Settings ▸ Panels beside
  the other Quick View row, defaulting to the 10 MiB the shipped behaviour already had. **Off** is a
  real value and is why the card needed a fourth sentence — at a limit of 0 a 21-byte file is not
  "this large", it is a mode the user turned off, and saying the former would read as arithmetic
  nobody can argue with. An open preview re-evaluates on change, so the setting is not a
  next-launch one.
- **`decline` is what makes the limit safe to raise.** Nothing about a bigger number changes the rule
  that an automatic gesture must not *ask*: over the cap the card appears and the user clicks, which
  is the same one gesture at 10 MiB and at 300.
- **Progress is a byte count the fetch already had, published rather than computed.**
  `RemoteFileCache` counts what has landed, the card polls it, and the bar is **determinate** —
  indeterminate would say "something is happening" where the honest answer is available. The readout
  is suppressed until the first byte, since "Zero KB of 42 bytes" is a claim about the transfer that
  is really a claim about the clock, and it borrows the queue bar's existing byte string rather than
  minting a second spelling of the same sentence.
- **Stop had to be *remembered*, and the first live run is what showed it.** A stopped fetch that
  merely forgot itself would be restarted by the next cursor event, or — worse, on a small file —
  leave the card claiming the file is too large. So the cancellation is recorded against the row and
  the card says "Download stopped." over a Download button; the negative control (forget instead of
  remember) fires as a retry loop, `copyCount` 2. Same asymmetry as `EditedFileRevision`: the state
  worth keeping is the one the user asked for.
- **Verified live against the real bucket, all four states.** The downloading card with its bar,
  caption and Stop; Stop clicked mid-flight → "Download stopped." with the right size on a 42-byte
  file and no restart on the next arrow key; completion → the text rendered; and, after restoring the
  400 ms settle the probe had stretched to 8 s, the reported case again — into `docs/` with the
  preview up, `notes.txt` drew its contents. 2387 core / 491 app green, both linters clean, all three
  check scripts clean, 5 strings in all 14 catalogs.

#### Slice 11 — 2026-08-14: Space-on-dir over a server

The milestone has said since it opened that "every listing is a billable request, which makes the
recursive sizer cost money over a bucket", filed under the permanent consequences. Nothing acted on
it: `computeDirectorySize` had no backend gate at all, where the *auto* scan beside it
(`areSizeBarsVisible`) has been `backend == .local` since M15. So Space on a prefix walked the whole
subtree, and it was unstoppable by construction — `DirectoryLoader.size` passes no `isCancelled`
*and* runs in a `Task.detached`, whose own doc comment says it deliberately outlives its caller's
cancellation. Right for a local walk, where finishing costs nothing and banks a total; indefensible
for one somebody is paying for.

**Probed first, and the numbers are what decided the shape.** Against the live third-party account
through the real `S3Backend` and the app's own `S3CurlTransport`:

- **One `ListObjectsV2` per directory, serial, 0.601–0.699 s each** (mean 0.621) — Slice 10 probe 5's
  0.51 s round-trip floor, once per folder. Ten directories cost **6.21 s**; extrapolated,
  1000 is **10.3 minutes and 1000 billed requests**, 10 000 is 1.7 hours.
- **Nothing was on screen while it ran.** The size column kept its dash, no spinner, no status line.
- **The cooperative-pool worry did not reproduce, and that shrank the slice.** 32 concurrent remote
  walks under `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` left a 50 ms heartbeat at a worst gap of
  **56 ms**, against **57 ms** for the no-walk control — so this is not a `BlockingWork` case, and
  the fix is about cost and cancellability rather than about where the walk runs. Worth recording as
  a negative: the natural reading of NOTES.md ▸ Swift 6 says otherwise, and acting on it would have
  been effort spent on a problem that is not there.

**The decision the cost forces, and it is not the one a download gets.** A remote *fetch* can be
confirmed against a number already on the row (`RemoteFetchPolicy`); a walk cannot, because finding
out how many folders there are **is** the walk. So a pre-confirmation could only say "this might be
expensive", which is a dialog people learn to click through. Space stays a gesture that spends —
the app's own rule since Quick View, that the key somebody pressed may spend where the cursor may
not — and the three things that make that affordable come off **one** value:

- **Bounded.** `DirectorySizeBudget` (core, +10 tests) carries a `directoryLimit`, `nil` locally and
  **1000** for anything `isRemoteConnection` — `S3Backend.pageLimit`'s number and its argument one
  level up, past anything a person points at and short of billing indefinitely. It is checked
  *before* the request, so the limit counts listings **made**: on a billed backend "refused" and
  "made and then discarded" are different numbers. Exceeding it **throws**
  `DirectorySizeBudgetExceeded` rather than returning the partial, for the reason a filtered-out row
  is dropped rather than drawn as "Zero KB" — a partial rendered as the answer is a claim about the
  folder where the truth is a claim about the question.
- **Abandoned.** `abandonsWhenUnwatched` is *derived* from the limit rather than stored beside it,
  because it is the same question — who pays for a walk nobody is waiting for — so a backend that
  gains a budget gains the cancellation with it rather than needing a second edit somebody has to
  remember. The pane keeps the task handle and cancels at the two `loadToken` bumps that mean it
  moved (`navigate`, `activateTab`); a refresh of the same directory deliberately leaves a walk
  alone, since its row is still on screen.
- **Visible.** The size column gains two states a byte count cannot express — `…` while measuring,
  `?` after a give-up — and the give-up's *sentence* goes to the status line, where prose has room.
  A give-up drawing the same dash as "never measured" is the one that matters: it invites a re-press
  that spends the whole budget again.

The local walk is deliberately **untouched** — untracked, unbounded, still outliving the gesture —
and that is pinned by a test of its own, because the easy wrong fix is to bound and cancel
everything and throw away a total that costs nothing to finish.

+10 core tests and +16 app tests (2381 core / 475 app green, both linters clean, and all three
`scripts/check_*.py` passing — the localization one is what proves the new key is extracted *and*
in the catalogs, which is the wrapped-but-untranslated case no coverage test sees). One string in
all 14 catalogs, verified in the compiled `.strings` rather than in the catalog. Four negative
controls, each failing only its own assertions: `.unbounded` in place of the budget made the
bottomless walk reach **9110 listings in 20 s** and still climbing where the fix stops at 1000;
discarding the task handle without cancelling took a cancel-at-520 to 1001; collapsing the
display states back to one dash failed exactly the two "distinguishable" assertions while the
"unmeasured still draws a dash" one stayed green; and putting the over-long Russian back in the
catalog failed the width test alone, naming `ru 713 pt` — which also proves that test reads the
built bundle rather than the source catalog.

**Verified live against the real endpoint** through the real backend and transport: a budget of 4
over a ten-directory tree gave up after **exactly 4** listings (2.43 s), the unbounded control
completed at 10 with the right total, and a cancel at 1.5 s left the count frozen at **3** through
two further seconds of grace — the requests stopped rather than being ignored.

**And verified live in the app**, against that same bucket through the running build. With the
shipped budget: Space on the ten-folder `sizerprobe` prefix drew `…` in the size column — while
`docs` and `photos` beside it kept their dashes — for the ~6 s the walk took, and the total landed
at **10 KB**, ten folders carrying one 1 KiB file each. Then, on a throwaway build with the remote
budget cut to 4 (1000 directories is a bucket nobody should create, so the give-up is unreachable
otherwise): the same prefix came back `?` while a neighbouring `docs` completed at 42 bytes in the
same listing, the status line carried its sentence whole, and hovering the `?` produced the
tooltip, wrapped over three lines. The budget and the `NSLog` came back out afterwards and both
suites were re-run against the restored source.

- **The give-up sentence did not fit the line it goes to, and it took three measurements to
  establish that — two of which were wrong.** The status label is `.byTruncatingTail` at
  `.defaultLow` compression resistance, deliberately, so a long type-to-filter string cannot shove
  the split divider across; the cost of that correct decision is that an over-long *sentence* loses
  its **tail**, which in an explanatory sentence is the explanation. The first draft measured
  **557 pt in English and 713 pt in Russian** against a pane of **542 pt**, so it clipped in
  **10 of 14 languages** and put `Stopped measuring “x” — it holds more folders than Dirnex will…`
  on screen.
  - **Getting the available width is where this went wrong twice, and the second attempt was worse
    than the first.** Subtracting an assumed sidebar from the window frame gave 532 — near enough,
    and arrived at by exactly the derivation docs/NOTES.md forbids. "Correcting" it with an `NSLog`
    of `statusLabel.frame.width` in the running app gave **409.5**, which looked authoritative and
    is meaningless: the label is sized to its own text, so that number is the *sentence* plus 3.5 pt
    of padding. Two consecutive logs give it away — `label` was always `sentence + 3.5`. The honest
    instrument is the enclosing stack's width, and better still
    `NSCell.expansionFrame(withFrame:in:)`, AppKit's own "is this truncated" asked of the real label
    in the real pane: probed that way the first draft truncates and every candidate at ~496 pt and
    below does not. **A live probe is not automatically a measurement of what you meant.**
  - The residual is the **folder name**, which is unbounded — 40 characters puts even a short
    sentence at 468 pt — so truncation here can be made unlikely and never impossible. That is what
    settled the design rather than any single width: the short note stays on the status line and the
    *reason* moves to a **tooltip** on the `?` cell, where nothing bounds it and where it outlives
    the status line's four-second expiry. Until then the glyph was permanently unexplained for
    anyone who looked away — the recorder pill's "prose belongs where its length is free" rule,
    arriving on a table cell.
  - `StatusSentenceWidthTests` pins the sentence at **400 pt against the measured 542**, the
    headroom being deliberate: budgeting to the pane itself would pass a sentence that fits the
    fixture's folder name and truncates on somebody's longer one. A sweep of all 18 sentences that
    reach the status line found none of the others over.

- **One test-design lesson, paid for twice.** The first version of the app suite installed a fixture
  model on the pane straight after `loadViewIfNeeded()`, and `viewDidLoad` → `activateTab` →
  `navigate` lists *asynchronously* — so a walk that finished in ~1 ms had its total wiped by the
  arriving listing and read as "the size never landed", while the same test over a backend slow
  enough to lose the race the other way passed. Taking the row from the pane's **own** listing
  removes the race instead of widening a timeout around it. The sibling of it: the pane lists its
  own directory on load, so a request count has to be read as a **delta** — asserting the raw count
  read 1001 against a budget of 1000 and looked exactly like an off-by-one in the sizer, which it
  was not.

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

#### Slice 12 — 2026-08-14: a transfer that says where it has got to

Reported as **"can't copy a file to S3"**, with a screenshot of the queue bar reading
`Zero KB of Zero KB · Copying DSC_0002.NEF` — and then, a minute later, "after 20-30 seconds, it was
immediately copied". The copy was never broken. Two independent defects compounded into a bar that
looked dead, and neither is visible from inside the code that owns it.

**The transfer reported nothing until it was over.** `S3Transport`'s byte-moving verbs had no
progress hook at all, and `S3Backend.copyFile`'s own doc comment said so out loud — "the whole
object transfers as one `curl` invocation, so `progress` reports once". Measured against the live
endpoint with the app's exact upload arguments: **29 MB took 99 seconds**, silent throughout. That
is the whole user-visible bug, and the sentence describing it had been sitting in the source since
the verb was written, which is this file's most repeated shape — a limitation stated in prose is a
feature request with a date on it.

**And the readout latched, which is why the *total* read zero too.** `QueueBarView` coalesces the
byte line to once a second, and it did it by **dropping** updates rather than deferring them. A job
publishes when it is enqueued — nothing scanned yet, so `Zero KB of Zero KB` is honest — and again
microseconds later carrying the real 27.7 MB; the second update lands inside the first one's second
and was thrown away. With nothing else ever publishing, no later update could correct it. A local
copy hides this completely by publishing every 8 MiB. The tell in the screenshot is that the status
line *beside* it named the file correctly, from the same snapshot — so the two disagreed about
whether anything had been measured.

**The two directions have different observables, which is why the fix is an enum and not a flag.**
A download writes a file on this machine, so its size is the byte count — exact, free, and needing
no change to the download's carefully measured flags. An upload changes nothing locally; `curl`'s
percentage meter is the only thing that knows, and `-s` silences it, so the upload verbs now pass
`-S`. `CurlProgressMeter` (core, +8 tests) parses it, pinned against **bytes captured from that
99-second run**: rows are `\r`-separated because the meter overwrites itself, the leading integer is
the overall percentage in both directions, and everything else on that stream — two header lines,
`curl`'s prose, the labelled `s3-…` write-out fields — fails to start with an integer, which is the
whole filter. What arrives mid-transfer is therefore an estimate at 1 % resolution, so every path
ends by reporting the **remainder** against the exact figure from the write-out: the bar is smooth
and the number it settles on is still the one `curl` measured.

**The bug the fix reintroduced, caught only by running it.** With everything green — 2401 core, all
the fixtures, both linters — the first live run reported **zero** sightings for a 12-second upload
while the download streamed perfectly. `FileHandle.read(upToCount:)` is not a chunked read: probed
on a child writing three lines a second apart, it returned **once, at exit, holding all three**, so
the whole meter arrived after the transfer it was describing. `availableData` delivers each write as
it lands (+0.01 s, +1.01 s, +2.02 s). It fails in the quiet direction — every byte still arrives, so
the response classifies correctly and only the progress silently never moves — which is the same
failure the slice exists to remove, one layer down.

+14 core tests, +3 app tests, +2 live (2401 core / 496 app green, both linters clean). Three
negative controls: neutering the streaming failed exactly the three progress assertions while the
"reported nothing, so report it all at the end" one stayed green; putting the dropping coalescer
back reproduced **`Zero KB of Zero KB`** verbatim in the label, which is the user's screenshot as an
assertion; and an uncapped fake part upload was rejected by the multipart test, because a part's
meter is a percentage *of that part* and a double that can exceed its slice would pass on arithmetic
the wire cannot produce. **Verified live** through the real transport against the real endpoint:
first report at 1.1 s of a 12.4-second upload and 1.2 s of a 20.4-second download.

**Left undone, and named rather than quietly skipped:** FTP and SFTP have the identical silence —
the same `ProcessWaiting` hook and the same meter are already in place for them to use, since
`FTPCurlTransport` drives the same `curl`. **Closed 2026-08-16** (below).

#### Slice 13 — 2026-08-14: the Download button the mouse could not reach

Reported as "the Download button on the Quick View is not active", with the placeholder card drawn
perfectly over a 29 MB S3 object. The button was armed, visible, un-hidden and correctly wired; what
it was not was **on top**.

Every backend the preview surface owns is pinned into one container, so the last one added is in
front — and `showPlaceholder` built the card first and called `showQuickLook(nil)` second, which
leaves an item-less `QLPreviewView` **visible** and therefore added after the card. It renders out of
process, so it draws nothing and the card looks right; it also answers `hitTest` and then *declines*
the event, which is the finding docs/NOTES.md already carries from M11 — so the surface's blanket
swallow took every press. The fix is one line: raise the card explicitly after the stand-down
(`addSubview(_:positioned: .above, relativeTo: nil)`, probed to be a pure reorder that keeps the
pinning constraints and the frame), rather than depending on the order two `ensure*` calls happen to
run in.

**Why it shipped, and why no verification pass would have caught it.** The ordering is decided by
whatever the surface shows *first*, and the failing order is the ordinary way into the mode: ⌃Q with
the cursor already on a remote file. Preview any local file first and the Quick Look view is built
early, the card lands on top, and the button works — so the bug is invisible to anyone who looked at
one file before the remote one, which is what a person checking a preview naturally does.

+3 app tests (2401 core / 499 app green, both linters clean), and the reproduction was the negative
control: against the shipped code the hit-test assertions fail with the surface itself as the hit,
the user's symptom exactly. The third test is the narrowness control — a press on the card's **body**
must still be swallowed, or "raise the card" quietly becomes "let the whole card through" and a click
beside the button moves the covered pane's cursor. Nothing else in the suite can see this class: every
other backend is the only visible thing in the container when it is asked about, so those tests pass
whatever the ordering is.

#### Slice 14 — 2026-08-15: camera RAW in the preview

Reported as "NEF images are small in the quick view", with a 29 MB frame drawn as a postage stamp in
the middle of the surface. It is not a scaling bug: the preview was showing a **different image**.
`showImage` reads the file into `Data` and calls `NSImage(data:)`, which hands ImageIO bare bytes with
no file name — and a NEF is a TIFF container, so it identifies as `public.tiff` and returns the
embedded **160×120** thumbnail as the primary image. At that thumbnail's 300 dpi it is 38 pt across,
and `scaleProportionallyDown` never upscales. Renaming the same file to `.dat` collapses *every*
route to 160×120, which is the control proving the file name is the whole mechanism.

Camera RAW now decodes through **`CIRAWFilter`** (`RAWImageDecoder`), routed by a `.rawImage`
conformance test beside the existing `isImage`; everything else keeps `NSImage(data:)` untouched. Two
measurements decided it against the ImageIO alternatives, and both inverted a recommendation made
before them:

- **`CGImageSourceCreateImageAtIndex` ignores EXIF orientation** and lays a portrait frame on its
  side. `NSImage(data:)` *does* honour it today, so the obvious "just give ImageIO the file name" fix
  would have shipped every portrait photograph sideways — ordinary JPEGs included.
- **`CGImageSourceCreateThumbnailAtIndex`, the one ImageIO spelling that does transform, diverges
  from a true demosaic** on one of five files (8.69 levels mean, with *higher* apparent detail — the
  shape of a camera's own sharpened preview). So the uniform ImageIO route would have quietly
  substituted the camera's JPEG for the RAW decode on some files.

On quality the two pipelines do not differ: measured at 1:1 over ARW/CR2/NEF/RW2/DNG, centre and
edge, they agree to **0.02–0.10** levels of 255 with identical variance-of-Laplacian — the same
demosaic — while Core Image is **3–4×** faster (99–170 ms against 370–509 ms), being GPU-backed. An
apparent 2–7 level difference seen first was the harness downscaling a 16-bit P3 image against an
8-bit `DeviceRGB` one, not the decodes.

**The bug the fix introduced, and what caught it.** `CIContext.createCGImage` returns a **lazy**
image in **0 ms** and defers the whole demosaic to whoever first draws it — the main thread, for
223–241 ms, on a preview that appears when the cursor moves. So the first version moved nothing off
the main actor; it relocated the stall. `render(_:toBitmap:)` does the work in the detached task, and
the finished bitmap also draws cheaper afterwards (7–9 ms against 18 ms). The tell was the *test
suite's own duration*: five RAW files in 0.26 s, faster than a single decode.

+5 app tests (2401 core / 500 app green, both linters clean). Three weaker assertions were tried
against the lazy version first and all three **passed** it: the dimensions (the extent is right
either way), `dataProvider.data` (it merely forces the render it was meant to detect), and a 20 ms
floor on `decode` itself, which failed by **16 µs** — a coin toss, since setting a RAW filter up
costs about that much. What separates them is the *residual* work after `decode` returns: **0.0 ms**
against 68–132 ms, a property rather than a stopwatch reading. Verified live on all five formats,
with the portrait CR2 upright and an ordinary JPEG unchanged as the narrowness control.

#### Slice 15 — 2026-08-15: the page turn that dealt the previous card

Reported the day Slice 14 landed: swiping or arrowing through RAW files "slides the current image and
only then changes it to the next one", while JPEG and PNG were fine. Not a new bug so much as a newly
*visible* one — `flip` calls `advance()` and starts its slide immediately, which assumes the next file
is on screen synchronously, and that held only while every image arrived within a frame or two.
Slice 14 turned the RAW path from an instant 160×120 thumbnail into a real demosaic, so the
assumption came due.

Instrumented in the running app, which settled both halves of it in one run:

```
   0.0 ms  flip begin
   1.0 ms  showImage begin DSC_0477-Pano.dng      ← the load starts inside advance()
   1.0 ms  flip advance returned
   1.0 ms  flip animate start                     ← the 160 ms slide starts here
 232.0 ms  showImage installed                    ← the picture arrives long after it ended
```

The first three lines are the good news: `show` really is entered synchronously inside `advance()`, so
a "still loading" flag set by the backend **is** visible to `flip` — docs/NOTES.md's warning about the
selection notification landing a runloop later does not apply on this path, which is what makes the
fix four lines rather than a redesign. `flip` now hands its slide to `whenContentReady`, which runs it
at once when nothing is loading and otherwise holds it until `contentDidLoad`. Re-measured after:
`flip SLIDE starts` lands in the *same millisecond* as the install, three flips out of three.

The state is a `FlipGate` living in `QuickViewPreviewView+Swipe` — the class was at both SwiftLint
ceilings, so this is the split-by-concept the house rule calls for rather than four more properties
on a type that had no room. A 0.5 s bound keeps a file that never decodes from leaving the surface
still; past it the old behaviour returns, which is wrong-looking rather than stuck, and it clears
every RAW measured here (slowest: a 149 MB pano at 359 ms).

+4 app tests (2401 core / 497 app green, both linters clean), asserting on the `CABasicAnimation` the
slide installs, so "has the page turned" needs no window, screenshot or wait. The negative control is
the shipped behaviour: with the wait removed, the two tests about waiting fail and the two narrowness
controls — slides at once when nothing is loading, and a flip cancelled with the surface is not
revived by a late load — keep passing, which is what says they are measuring different things.

#### Slice 16 — 2026-08-16: FTP and SFTP say where they have got to

Slice 12 fixed S3's motionless queue bar and wrote its own leftover down: the other two remote
backends had the identical silence, with the meter and the `ProcessWaiting` hook already sitting
there for them to use. Reproduced before touching anything, against a **throttled** local server
(1 MB/s — a rate is what this class of bug needs, not an input): an 8 MB FTP upload reported its
bytes **once, 8.02 seconds after it started**.

**The probes decided the shape, and one of them decided a limitation.**

- **`sftp` prints no progress meter to a spawned process, in any configuration.** Probed six ways
  over a 1 GiB transfer against a real local `sshd`: `-b -` and interactive, stdout on a pipe and on
  a PTY, and with the `progress` batch command explicitly turning it on — which answers
  `Progress meter enabled` and then prints nothing. OpenSSH draws it only for a foreground process
  group on a controlling terminal, which a spawned child is not. So an SFTP **upload** has no
  observable at all, and the honest answer is the one it already gave: report the exact count once,
  at the end. The remaining route — polling the remote size — is a fresh connection and handshake
  per tick on a transport with no session.
- **`curl` behaves over FTP exactly as it does over S3**, which is what makes three quarters of this
  free: `-S` in place of `-sS` puts the meter on stderr at ~1 Hz, the leading integer is the
  percentage, and the `%{size_upload}` write-out still lands on stdout untouched. A **download**
  needs no flag change at all — its destination is a local file that grows, so the transport reports
  exact bytes by watching it, where the meter could only offer a rounded percentage.

So: FTP gets both directions, SFTP gets its download, and the one silent verb is silent because
`sftp` is. The asymmetry is pinned by a test of its own, or the next reader files it as missing
wiring and "fixes" it by inventing a number.

`TransferProgressTally` (core, +7 tests) is the arithmetic all three backends now reconcile through
— forward-only deltas, a resume's existing bytes excluded, a truncated destination read as a fresh
transfer — and `TransferProgressWatch` (app) is the part that cannot be pure, shared by the three
transports; `S3CurlRunner`'s two private copies of both are gone. +14 core tests in all (2494 core /
535 app green, both linters clean).

**The one thing that was not simply S3's fix applied twice**: with the meter let through, it shares
stderr with `curl`'s own error text, and FTP — unlike S3 — *classifies from that text*.
`CurlProgressMeter` therefore gained a `prose` side, keeping the table out of what the classifier
reads, with the header identified **structurally** (whatever precedes the first meter row) rather
than by matching `% Total`, so the invocations that carry no meter keep every word they printed.
The live control for it came out **inert** — every failure provoked against the real server
classified identically either way — and the reason is worth recording: a transfer that fails has
usually not moved enough for its meter to print anything but zeros. The case that does bite is
arithmetic rather than luck, and is pinned headlessly: `classify` takes the *last* three-digit
4xx/5xx token, so a transfer moving at **553k** when the server refuses it reads as FTP's "file name
not allowed" and turns a missing path into a permission failure.

**Verified live** through the real backends and the app's own transports, compiled in Swift 6 mode:
FTP download **4 reports over 8.02 s**, FTP upload **5 over 6.04 s**, SFTP download **31 over
3.12 s** for 1 GiB, each summing *exactly* to what the tool reported moving; SFTP upload one report,
as documented; and a resumed FTP download reporting **only its 4 MiB remainder** onto a file that
came out byte-identical. Three live negative controls, each firing on exactly its own half: reverting
the upload's `-S` and unchunking the stderr drain both took the FTP upload from 5 reports to **1**
while leaving the download and SFTP untouched — the user's symptom, twice, from two different causes
one layer apart.

`FTPCurlTransport` hit SwiftLint's `type_body_length` on the way and was split by concept rather than
shaved: `FTPCurlTransport+Process.swift` now holds the spawn, the drains, the wait and the TLS retry.

#### Slice 17 — 2026-08-16: the write the server decides

The one item this milestone **parked rather than rejected**, taken up: Slice 10 wrote down that a
conditional `If-Match` PUT "is stronger and needs its own probe first (whether `curl` signs it under
SigV4, and whether anything but AWS honours it)". The second half of the answer had also gone stale
in the source — `S3Backend.createFile`'s doc comment said the race between its `stat` and its write
was "unavoidable and accepted" because "S3 has no create-if-absent — no `O_EXCL`, no conditional PUT
in the base API", which stopped being true when the service shipped conditional writes. A limitation
stated in prose is a feature request with a date on it, and this one had two.

**The probes settled the client half completely and named the half nobody can settle.** Against a
fresh ~200-line endpoint that recomputes SigV4 by hand — a wrong-secret control refused in the same
run, which is what makes a pass evidence rather than a permissive server agreeing (the `moto`
lesson, now applied four times in this milestone):

- **`curl` signs both headers and needs nothing new to do it.** They arrive in `SignedHeaders` as
  `host;if-match;x-amz-content-sha256;x-amz-date` and the signature verified every time. The same
  finding as `x-amz-copy-source` and `Content-MD5` from Slice 4: the header is ours to spell, the
  signing is not ours to write.
- **The ETag's quotes are part of the value**, and this is the finding that would have shipped as a
  bug. An unquoted digest is a different byte string and does not match, so tidying the quotes away
  turns *every* conditional write into a 412 — which reads as "somebody else changed this file". The
  app would then report a conflict that never happened, confidently, on every save. `S3ListingParser`
  has kept the quotes since Slice 10's ETag pass; what was missing was a test saying nothing between
  it and the wire may take them off.
- **A doomed conditional PUT costs a round trip rather than the file.** `curl` sends
  `Expect: 100-continue` above ~1 KiB, and a server answering the precondition there ends it before
  the body moves: a **64 MiB** upload against a stale tag reported `size_upload=0` in **0.0009 s**.
  So conditioning a *large* save-back is free, which is the case that would otherwise have been the
  argument against conditioning at all — and it is a second reason for a header this backend already
  keeps for the 403 case.
- **Whether a given server honours any of it is unmeasurable from here, and that decided the
  design.** A store that ignores `If-Match` answers 200 and overwrites, indistinguishably from having
  honoured it. So the protection is built **strictly additive**: `createFile` keeps its local `stat`,
  a save-back keeps resting on `RemoteFileRevision`'s re-`stat`, and the header closes the window
  after those on the servers that can — never claiming more. `S3ConditionalWrite` is a named box
  around one `Bool` for the same reason: `conditionWasSent` is a claim about this client and never
  about the server, and the multipart path reports **`false`** rather than letting a caller believe
  a large upload was guarded.

`S3WriteCondition` (with `S3WriteConditionRefusal` and `S3WriteConditionUnsupported`),
`S3Backend+Conditional`, the two conditional verbs on `S3Transport` and `S3CurlTransport`, and two
`VFSUnsupportedReason` cases translated in all fourteen. +17 core tests (2511 core / 535 app green,
both linters clean, all three check scripts passing).

- **A 412 means opposite things depending on what was asked, so it cannot be a status map.** Against
  `.ifAbsent` it is "there is already a file here"; against `.ifMatches` it is "somebody else has
  written this since you downloaded it" — one is `alreadyExists`, the other is a sentence about a
  conflict, and nothing in the response separates them. Hence a second write funnel that has the
  condition in hand at the moment the status is read, rather than a wider `switch` inside the one
  that maps a status with no idea what produced it. A 404 joins it for one condition only: an
  unconditional PUT to a missing key *creates* it, so on an `If-Match` that status can only mean the
  object was deleted, which is a different sentence again (there is nothing to compare with).
- **Both refusals are named reasons, not a raw errno.** The generic mapping is `.io(code: EIO)` —
  "The system reported an error (code 5)" — which is the shape this milestone already had to name
  once, for `EXDEV` on a folder rename. The control run makes that concrete: with `createFile`'s
  condition neutered, the refusal test fails showing exactly that `code: 5`.
- **The transport seam refuses rather than dropping.** A protocol requirement cannot carry a default
  parameter, so the conditional verbs are separate requirements with a default implementation that
  **throws** when handed a real condition and forwards an unconditional one. Silently writing without
  the precondition is the one outcome worse than not having the feature, and it is what a transport
  added later would otherwise do by inheritance. `S3CurlTransport` implements both, with the
  *conditional* form as the real one and the plain one forwarding to it — one argument builder, so
  a precondition cannot be lost by a caller reaching the older spelling.
- **The folder marker deliberately stays unconditional**, and it is a decision rather than an
  omission: a marker is idempotent by construction, so `.ifAbsent` there would turn the second F7 in
  the same place into an error about nothing. Pinned by a narrowness test.
- **Five negative controls, each firing on exactly its own assertions**: `createFile` dropping the
  condition (2 failures, one of them the raw errno above), the refusal reader losing its narrowness
  (a 403 then reads as a conflict), the entity tag's quotes stripped, the seam forwarding instead of
  throwing (`unconditionalCalls → 3` — the dropped precondition reaching the unguarded verb three
  times), and multipart claiming it carried a condition it cannot.
- `S3ProcessArguments.swift` was **one line** under SwiftLint's 500-line ceiling, so this feature was
  the moment to split it by concept rather than shave it: `S3ProcessArguments+Multipart.swift` now
  holds the four multipart builders, the seam `S3Backend+Multipart.swift` already uses.

**What is left, named rather than quietly skipped.** The multipart path carries no condition —
`If-Match` on `CompleteMultipartUpload` is what AWS documents and `curl` would sign it as readily,
but a completion can already fail *inside a 200*, so a refusal there has two shapes to read rather
than one, and none of it is measurable against an endpoint that is ours. The **save-back** is the
other half — `RemoteFileRevision` already carries the ETag that `.ifMatches` wants — and is Slice 18
below. Neither is verified against a real endpoint yet — the live config file this milestone's suites
are gated on is not on this Mac, so `S3AccountLiveIntegrationTests` skipped throughout.

#### Slice 18 — 2026-08-16: the save-back sends the precondition

Slice 17's other half, and it is app-only: `BrowserWindowController.writeCondition(checked:)`,
`conditionalWriter(for:)` on `CompositeBackend`, the refusal's own prompt, and three keys translated
in all fourteen (+9 app tests; 2511 core / 544 app green, both linters clean, all three check
scripts passing). F4 on a bucket object now uploads under `If-Match`, and the two sentences Slice 17
minted reach the screen.

- **The whole wiring has one decision in it, and the natural way round breaks the feature outright:
  which revision's tag travels.** The obvious reading is "the file we downloaded" — and conditioning
  on that refuses precisely the write the prompt exists to authorize. Someone told «the file on the
  server has changed — someone else has edited it» who then presses Upload has said they mean to
  replace *that* version; an `If-Match` naming the older tag answers 412 to their own decision, in a
  sentence claiming somebody changed the file. So the **check's** tag is what is sent: it pins what
  they agreed to overwrite, which is exactly the window `RemoteFileRevision` cannot cover — between
  the answer and the `PUT`. It compiles, it reads correctly at the call site, and nothing else in
  either suite can see it, which is what the named function and its negative control are for.
- **A refusal is a decision, not an error with an OK button.** A 412 here means the object moved in
  that window — nothing is broken — so it gets its own prompt naming what happened and offering
  Upload Anyway. The retry is deliberately **unconditional** rather than re-`stat`-and-re-condition:
  the second form can be refused again by a third writer, which is a loop with a round trip in it
  (the shape the FTPS trust retry had to guard against), and the user has now been told twice.
  Without the offer the only route out is saving again in the editor — and an editor asked to save a
  file it has not changed may write nothing for the watcher to notice, so "just save again" is an
  escape that is not guaranteed to exist.
- **The two refusals get two sentences**, because what uploading anyway *does* differs: a changed
  object has a newer version to destroy, a deleted one has nothing to destroy and nothing to compare
  with — "replaces their version" and "puts it back as a new file" are each false in the other's
  case.
- **`conditionalWriter(for:)` is a lookup rather than a test on the path**, and its narrowness is
  the half worth asserting: `path.backend.isS3` is `true` for a bucket nobody has connected, while
  an account root, an archive member, an SFTP path and the local disk must all answer `nil`. A
  lookup that answered for everything would send an `If-Match` down a seam that (correctly) throws
  rather than dropping it — so the failure would be a save-back that stops working over SFTP, FTP
  and the local disk alike.
- **`conditionWasSent` is deliberately shown nowhere.** A file over the multipart threshold reports
  `false`, and the prompt the user agreed to never claimed the write was guarded — it rests on the
  re-`stat`, which works at every size and on every server. Saying "this large save was not
  protected" would announce the absence of a protection nothing had promised, which is the
  strictly-additive rule read from the other end.
- **Three negative controls, each firing on its own assertions**: the condition flattened to
  `.unconditional` (both tag tests fail, both "writes unconditionally" tests keep passing), the
  refusal reader widened to answer for every error (the narrowness test fails on all four of its
  errors, plus the `.gone` half of its neighbour), and the writer lookup made to ignore the path
  (the narrowness test fails on all four backends while "needs a connection" passes).

Unverified against a real endpoint, and named rather than skipped: the live config file this
milestone's suites are gated on is still not on this Mac. What that leaves unmeasured is one step —
whether a real provider's 412 arrives in the shape `S3WriteCondition.refusal(for:)` reads — since
everything before it (the header travelling, signed, with its quotes intact) was measured in Slice
17 against an endpoint that recomputes SigV4 by hand.

### M22 — Find Files on a connected server (M, opened 2026-08-16)

⌥F7 has been Spotlight since M4, so it answers for this Mac and for nothing else: connect a bucket
or a server and the one gesture for "where is that file" stops existing. The ask is to make it work
on S3, FTP/FTPS and SFTP.

**Most of the feature is already there, and it is the half that looks hardest.** A results tab's
*container* path is synthetic while every entry in it carries its real `VFSPath`
(`PanelViewController+Results`), and `CompositeBackend` routes per entry — so F5, ⌘Y, the path bar
and Quick View reach an `s3://` hit exactly as they reach a local one, with no work. What is
Spotlight-bound is two links of the chain: `FileQuery.metadataPredicate()` (the type was
called `SpotlightQuery` until this milestone) and
`SpotlightSearchRunner`. One consequence worth having early: a remote search needs **no per-hit
`stat`**. That call exists because `mdfind` hands back bare strings; a walk gets whole `FileEntry`s
out of the listing it has already paid for.

#### The query and the index are two things wearing one name

`FileQuery` describes what the user wants *and* renders it into `kMDItem…`. The milestone
splits those: the same value gains a pure `matches(_ entry:)`, so one query drives both routes and
there is one definition of what "Images larger than 1 MB" means. The route is picked by the scope's
backend — `.local` keeps Spotlight, anything re-listable and not on this disk takes a walk.

**Which fields a backend can answer is one named thing, not a check per site**
(`SearchFields.answerable(by:)`). The dialog hides what is not in the set; the matcher applies only
what is in it. That is what makes the hazard catchable: a saved search made locally carries
`contentContains`, and a matcher that quietly skips a clause it cannot answer returns **more**
results under the same name — the quiet direction, and the reason this is a capability set rather
than four `if` statements.

Content and tags are gone remotely, as asked. Two more needed deciding and are *kept*:

- **Kind stays, and changes meaning.** Remotely it can only be derived from the **name**
  (`UTType(filenameExtension:)`), not from content — but it asks the identical conformance question
  against the identical `SearchKind.contentType`, so the two routes share one definition and diverge
  only in what they look at. "Every image under this prefix" is most of what anyone wants from a
  bucket, and it costs no request.
- **Modified and Size stay, and never match a row that cannot answer.** An S3 folder is a common
  prefix with **no date at all** (`FileEntry.unknownDate`), and a directory's size is not measured
  on any of the three. So a size or date filter is a question about *files*: a row with no such
  attribute does not match, rather than matching vacuously. It diverges from Spotlight, which does
  answer for folders, and that is stated rather than discovered.

#### Three backends, three different costs

- **S3 is nearly free and needs no walk.** `ListObjectsV2` with **no delimiter** returns every key
  at every depth — the enumeration `S3Backend.removeItem` already uses for a recursive delete — so a
  whole-bucket name search is one request per **1000 keys**, not one per directory. A backend that
  can answer a subtree in fewer requests than a walk would take says so through one optional seam
  (`subtreeListing(at:)`, defaulting to `nil`); everything else walks.
- **FTP/FTPS is a client walk**, one round trip per directory, and its cost model is already
  measured and written down: `DirectorySizeBudget` — 0.62 s per listing, a 1000-directory remote
  ceiling, `abandonsWhenUnwatched`. Search reuses that type rather than minting a second policy.
  Note FTP's stamps are year-less, zone-less and on the server's clock (`hasCoarseModificationTimes`)
  — fine for a "past week" filter, which is all this asks of them.
- **SFTP goes server-side**, decided at open: `ssh <host> find <path> …` answers the whole tree in
  one round trip where the walk pays one per directory. It is the one part of this milestone that
  needs a probe before any Swift, and it has two failure modes that must degrade rather than
  surface — an account restricted to the `sftp` subsystem (no exec channel at all) and a server
  whose `find` is not GNU's. The walk is the fallback, so the feature never depends on the probe's
  answer, only its speed does.
  - **The probe retired the second failure mode rather than handling it** (2026-08-16, taken by the
    user on a recommendation). `find -printf` is GNU-only, and there is no Linux host and no GNU
    coreutils on this Mac, so choosing it would have shipped the *common* case unverified while the
    only server available exercised the fallback. `find <root> -exec ls -ldn {} +` is POSIX on both
    halves, prints the `ls -l` row `ColumnarListing.unixRow` already reads for `sftp` and FTP, and
    was measured end to end here. What it costs is the date column — year-less, zone-less, on the
    server's clock — which is the compromise this milestone had already accepted for FTP.

A **search over an S3 account pane is refused**: its rows are buckets, and "search every bucket" is
a different and much more expensive question than the one ⌥F7 asks. Scope must be a bucket or a
folder in one.

Something the walk gets for free and Spotlight does not: an **archive** is re-listable out of a
cached `bsdtar -tvf` on this disk, so "find in this zip" is the same code with an unbounded budget.
In scope for the capability table from Slice 1; wired last.

**The walk is breadth-first, unlike `DirectorySizer`'s stack**, and it matters at exactly the moment
it is bounded: a depth-first search that runs out of budget returns a deep sliver of one branch,
where breadth-first returns everything near the top — which is where a person's file usually is. It
also returns its partial hits instead of throwing, which is the opposite of what the sizer does with
a partial total, and for a stated reason: a partial *total* is a claim about the folder, while
partial *hits* really do match and the truncation is a fact about the question. That is what
`SpotlightSearchRunner`'s existing 5000-row cap already reports.

**Verification is the constraint.** There is no live FTP, FTPS, SFTP or S3 account available for
this milestone, so "probe the real thing" cannot be satisfied the way M21's was. The honest
substitute is the instrument M13 and M21 already used and NOTES already documents — `pyftpdlib` with
two self-signed certificates for FTP/FTPS, a SigV4-verifying local endpoint for S3, and this Mac's
own Remote Login for SFTP (which needs the user to switch it on). Anything that cannot be measured
that way is stated as unmeasured rather than assumed.

Slices, core first: **(1)** `SearchFields`, `SearchPredicate`, `SubtreeSearch` — pure, tested, app
untouched. **(2)** the app routes ⌥F7 by backend and the dialog hides the fields the scope cannot
answer. **(3)** S3's flat enumeration behind `subtreeListing`. **(4)** SFTP's server-side `find`,
after its probe, with the walk as fallback. **(5)** archives, and saved searches carrying a remote
scope.

**Slice 1 landed 2026-08-16**, core-only and additive: `SearchFields` (what a place can answer, plus
`SearchRoute`), `SearchPredicate` (the query compiled to a per-entry test), `SubtreeSearch` (the
breadth-first bounded walk), and one optional seam on `VFSBackend` — `subtreeListing(at:isCancelled:)`,
defaulting to `nil`, so a backend whose keyspace is flat can answer a whole subtree in one call. +29
core tests (2427 core / 508 app green, both linters clean); the only edit to existing code is three
`private` computed properties on `FileQuery` widened to internal, since Swift's `private` does
not cross files.

Two negative controls, both of which fired and one of which measured the design rather than merely
guarding it:

- **Depth-first instead of breadth-first** failed exactly the two order-dependent tests and left the
  other eleven green — which is what says they measure different things. It also put a number on the
  argument: over the same fixture with a 2-directory budget, the depth-first version dived into
  `/root/b` and returned **one** hit where breadth-first returned two, having covered the shallow
  tree. That is the "deep sliver of one branch" claim, reproduced.
- **Dropping the unanswerable-clause refusal** compiled a tags-only query into a predicate with
  *every field nil* — one that matches every row it is shown. So the hazard the type exists to
  prevent is not theoretical: without it, a saved search re-run on a server lists the entire subtree
  under the name of a search that means something much narrower.

**Slice 2 landed 2026-08-16** — the app: ⌥F7 routes by the scope's backend, and the dialog hides
what the scope cannot answer. `SubtreeSearchRunner` (the walk off the main thread, with a
latest-value `SearchControl` rather than a progress callback, because a coalescer that drops what it
withholds latches — docs/NOTES.md), `SearchProgressSheet` (late by 400 ms, live counts, Stop),
`PanelViewController+SearchWalk` (the three completions, two surfaces: an alert for a limit the user
ran into, the status line for a stop they chose), and `SearchFilterOptions` split out of a
`SearchController` that had gone past `type_body_length`. `canFindFiles` gates both the key and the
menu item, so an **S3 account pane** offers no search rather than quietly searching this Mac's home
folder. 11 new strings, translated into all 13 languages — two of them reworded to labelled counts
(`Folders searched: %lld · Found: %lld`) so nothing needs plural agreement on two numbers in
fourteen languages for a line that is on screen for seconds. +9 app tests (2429 core / 517 app
green, both linters and all three scripts clean).

`SubtreeSearch` gained a fourth completion in the same pass, and it is a correction to Slice 1 rather
than an addition: a stopped walk **returns its hits** instead of throwing `CancellationError`. Stop
here means "that's enough, show me what you have" — a person is standing at the button — where a
cancelled *size* walk has nothing honest to report. The flat shortcut cannot return partway through,
so it says the same thing by throwing, which `find` converts, and the two routes are
indistinguishable to the caller.

**Verified live against an archive**, which is the one walking backend reachable with no server: a
zip four levels deep, searched from its root (4 hits at every depth) and from `docs/` (3, the root's
own hit correctly excluded), with "All of “pkg.zip”" from inside `docs/` finding all 4 again. The
dialog drew **Name / Kind / Size / Modified / Search in** and no Content or Tags row.

That run found the one thing nothing else could have: **F5 on a hit failed inside the queue** —
"This location doesn't support copying files". `copyToOtherPane` asked the *pane* whether it was an
archive, and a results tab's container is the synthetic `search:` path, so the extraction route never
ran and the byte copy reached `ArchiveBackend`, which has no `copyFile`. The question has to be asked
of the **rows** (`extractionArchivePath(for:)`), which is this project's most-repeated finding
arriving through a new door: a second source of entries reached a site that decides by backend. F6 is
gated the same way, in the flow *and* in its validator. Re-verified live: `report-top.txt` extracted
out of the archive and landed in the destination pane. Fixed rather than deferred because the slice
is what made it reachable; four tests pin it, including the narrowness control that an ordinary local
results tab still takes the copy path.

**Slice 3 landed 2026-08-16** — S3 answers a whole subtree in one enumeration.
`S3Backend.subtreeListing` (`S3Backend+Subtree.swift`) fills the Slice 1 seam with a
delimiter-less `ListObjectsV2`, and `S3SubtreeListing` turns those flat keys into the rows a walk
would have produced. Two things in that conversion are decisions rather than plumbing, and both are
what the tests are really about:

- **Folders are synthesized, because with no delimiter the server sends none.** The pages carry
  `docs/`, `docs/report.pdf` and `docs/sub/notes.txt` and not one `<CommonPrefixes>` — the same
  measured fact the recursive delete already rests on — so rendering only the objects would mean a
  search for `docs` finds nothing called `docs`, and a Kind filter of *Folders* returns an empty
  result over a bucket full of them. An empty result reads as "there is none", which is the quiet
  direction. Every component on the way down to a key therefore names a folder, emitted once; a
  trailing-slash marker names one too, which is the only trace an **empty** folder leaves in a flat
  store.
- **Rows come out shallowest-first.** S3 returns keys lexicographically, so truncating that order
  keeps a deep branch under `a/` ahead of everything under `z/` — the "deep sliver" this milestone
  argued against when it chose breadth-first for the walk. Ordering by depth is what makes the two
  routes agree at the moment the 5000-row cap bites, rather than differing on a property of the
  *store* that nobody chose.

The app's `CompositeBackend` had to **forward** the seam, and that is the finding worth keeping: the
protocol's default is `nil` — "no shortcut, walk instead" — so a composite that never mentions it
compiles, returns the same rows, and quietly bills one request per folder. There is no symptom on
screen. Two other one-rule-two-spellings cleanups came with it: the pagination loop and its two
guards now live once (`S3Backend+Pages.swift`) rather than in three copies whose comments said "the
same reason `listDirectory` does", and `S3ListingParser`'s row builder is shared, so the flat route
cannot render an object differently from the listing route.

+15 core, +2 app (2444 core / 519 app green, both linters and all three scripts clean). Three
negative controls, each firing on a different set: dropping folder synthesis failed 9 tests and left
the file-only ones green; returning arrival order instead of depth order failed exactly the 4
order-dependent ones; and removing the composite's forward failed the routing test while its
narrowness control (a local path still reports `nil`) kept passing.

**Verified live against a local endpoint**, since there is still no account to probe: a Python
`ListObjectsV2` server on `127.0.0.1`, plus a throwaway SwiftPM harness compiling the app's *real*
`S3CurlTransport` against the real core, so every byte came off a socket through real `curl`. Six
searches, six single-request enumerations, with the server's own log as the witness — and re-run
with the page size forced to **two keys** it produced byte-identical output across four pages, which
is the cross-page folder dedupe and the continuation-token round trip measured rather than argued.
Then the app itself, connected to that endpoint: the Find Files dialog drew Name / Kind / Size /
Modified and no Content or Tags row, ⌥F7 for `o` returned six hits spanning three depths —
`notes.txt` three levels down, and the folders `docs` and `photos` that exist in that bucket only as
prefixes — and the log shows the search spending **delimiter-less pages only**, with no per-folder
listing of the four folders a walk would have had to visit.

**Slice 4 landed 2026-08-16** — SFTP borrows the server's own `find` over an SSH exec channel.
`SSHFindCommand` builds the one remote command, `SSHFindListingParser` reads it back, and
`SFTPBackend+Subtree` fills the Slice 1 seam with them; `SFTPTransport` gains `runCommand`, whose
default answers `nil` so every existing transport and test double inherits "no shortcut, walk". The
seam's return type changed from `[FileEntry]?` to `VFSSubtreeListing`, carrying `isComplete` —
S3 pages until the bucket is exhausted and is always complete, while this command's output is capped
on the server, and a shortcut that could not report being cut off would answer "here is everything"
about a slice of a tree.

**The probe came first and decided four things, none of them guessable.** Measured against a real
`sshd` (Remote Login is off on this Mac, so the instrument is a non-root `sshd` on port 2222, with a
second on 2223 carrying `ForceCommand internal-sftp`):

- **The saving is the connection, not the walk.** Over 501 directories on *loopback*, where there is
  no latency to blame: one exec **98 ms**, against **34.3 s** as separate `sftp` connections
  (68.5 ms each) — the shipped walk opens a full TCP connect, SSH handshake and authentication per
  directory. On any real network the gap only widens, since a handshake is several round trips.
- **Neither the exit status nor the stream tells you whether the command ran**, which inverts the
  natural design. An `sftp`-only account answers an exec request with prose on **stdout**, exit 1,
  empty stderr; `find` answers exit 1 **with correct rows** when one subdirectory is unreadable. So
  the transport classifies nothing, and the *parser* decides — `find` echoes the operand it was
  given, so the root's own row is the sentinel, and its absence is what means "walk instead". An
  empty folder still prints that row, which is precisely the case the two answers must be told apart
  on.
- **An exec channel runs the user's login shell and sources their rc**, so a `find` shell *function*
  shadows the binary — probed, one printed `SHADOWED` where the real `find` would have listed.
  `/usr/bin/env` bypasses it. Only the words the shell resolves need that; the `ls` inside `-exec` is
  spawned by `find` itself and is out of reach.
- **A remote path reaches a shell, so quoting is a security boundary rather than formatting.** POSIX
  single-quoting held against a crafted `…/tree'; touch CANARY; echo '` (no canary; `find` reported
  the whole string as one missing path), and a directory genuinely named ``it's $a `b` ;x.txt`` came
  back byte-for-byte.

Rows come out **shallowest-first**, as S3's do and for the same reason: `find` walks depth-first, so
its own order would put a whole deep branch ahead of a file at the top when the result cap bites.

+27 core (2471) and +2 app (523) tests, both linters and all three scripts clean. **Seven negative
controls, and the seventh is the one worth recording**: dropping depth ordering, the root sentinel,
the path anchor, `env`, `ssh`'s `-p`, and the truncated-beats-budgetExceeded tie each failed exactly
the tests naming them — while *claiming a capped run was complete* failed **nothing**, because the
row cap was unreachable at 50 000 rows. That is a rule nobody had watched fail; `subtreeRowLimit`
became settable so a test can reach it, and the control then fired on one test alone.

**Verified live, twice, with the server's own log as the witness.** The real app connected to the
exec-capable account, ⌥F7 over a four-level tree returned 5 hits spanning three depths and the log
shows **one** `Starting session: command`. The same search against the `sftp`-only account returned
**the identical 5 hits** and the log shows **six** `forced-command 'internal-sftp'` sessions — one
refused exec attempt, then five directory listings. The degrade is invisible to the user, which is
what it was designed to be.

Two things the slice deliberately did **not** ship, both recorded because they are the next thing
someone will reach for:

- **A memo of accounts that refused exec.** Written, then removed on the measurement: it cannot fire
  for the case it exists for (the refusal *looks* like an answer from the transport's side, so only
  the core could feed it), and it would save exactly one handshake in front of a walk about to spend
  one per directory.
- **Batching the walk itself.** The same benchmark measured **one** `sftp` session carrying all 501
  `ls` commands at **239 ms** — 140× faster than the shipped walk, on every account including
  locked-down ones, with no exec channel needed. It is a change to `SFTPTransport.listDirectory`,
  which every browse and every file operation goes through, so it is a milestone of its own rather
  than a passenger in a search slice.

**Slice 5 landed 2026-08-16** — saved searches, and the archive half, which turned out to be
mostly *undoing this milestone's own opening premise*.

Archives needed no wiring at all: Slice 2 keyed the route on `isArchive` rather than enumerating
backends, so the walk, the unbounded budget and the dialog's hidden rows all arrived with it and
were verified live that day. What was left was the **saved search**, and one whole class of bug
underneath it.

**A saved search is the only place where the scope, not the pane, says where a search runs** — it
carries an absolute path from whenever it was saved and deliberately does not follow the pane. It
inherited Spotlight by default, and `FileQuery.mdfindArguments` takes `scope.path` and drops the
backend, so what a saved bucket or archive search actually ran was decided by how deep its scope
was. Measured, not guessed, by reverting `runSavedSearch` in the built app and clicking the same
row: a scope at a **backend root** — every archive root, every bucket root, every server home —
spells `path` as `"/"`, so **"Zip reports", a search saved inside a four-file zip, came back with
1275 hits** from `/System`, `/Library` and the crash logs, in a tab wearing the name the user gave
it. One level down (`/2026`, `/docs`) it answers zero. Both are the quiet direction and the first
is worse: an empty pane at least looks like an answer about nothing. `SearchRoute.forSavedSearch`
is the fix, `mdfind -onlyin /` reproducing 1275 at a shell is the corroboration, and the restored
build gives the 4 archive hits back.

**The bigger finding is that this milestone's opening premise is false, and it was false in four
places.** §M22 opened saying a hit is reached "exactly as a local one is, with no work", because a
results tab's container is synthetic while every entry carries its real `VFSPath`. True of the
*paths*; false of the four properties that resolve them, each of which asked `panel.path.backend`
— which in a results tab says `search:`. So ⌃Q drew nothing on an archive or server hit,
⌘Y reported **“No items selected”**, ⏎ inside a zip did nothing at all, and F4 said the file could
not be edited — all four about rows the browse route handles perfectly. Slice 2 met this shape at
F5 and fixed that one site; Slices 3 and 4 then made remote hits real, which is what made the rest
reachable. `previewableArchiveMember`, `remoteFileUnderCursor`, `previewsCursorFileOnly` and
`isWritableArchiveMember` now ask the row.

One more thing the slice made reachable and closed in the core: **a walk's root must be listable.**
A stored scope can since have been renamed, deleted, or be on a server nobody reconnected to, and
skipping the root the way an unreadable *subdirectory* is skipped returns zero hits and `complete`
— indistinguishable from "nothing matched". The root now throws; below it nothing changed.

+6 core (2475) and +8 app (531) tests, both linters and all three scripts clean; one new string in
all 14 languages. Six negative controls, each firing on exactly the tests naming it with every
narrowness control still green — and a seventh run in the built app, which is the only instrument
that could see the saved-search bug at all.

**The FTP/FTPS verification pass landed 2026-08-16**, and it is the one backend of the four the
milestone was asked for that no slice had ever exercised live. FTP takes the generic walk through
`isRemoteConnection`, so it needed no code of its own and nothing could be said about it beyond
"it compiles". The instrument is the one this milestone named at open: `pyftpdlib` on
`127.0.0.1:2121` plain and `:2122` explicit FTPS with a self-signed certificate, logging every
command it is asked to run, plus a throwaway SwiftPM harness compiling the app's **real**
`FTPCurlTransport` against the real core so every byte came off a socket through real `curl`.

**Nothing in the FTP half was wrong.** Over a 12-directory tree four levels deep: 7 hits at five
depths, and the server's own log shows the LISTs arriving root → all four depth-1 → all four
depth-2 → depth-3 → depth-4, which is the breadth-first claim measured at the wire rather than
argued. Scope narrowing (4 hits from `/docs`), a directory named `odd 'name` walked and its hit
returned, kind decided from the name, a size filter excluding folders, `contentContains` and
`tags` **refused** rather than skipped, `budgetExceeded` / `truncated` / `stopped` each reported
with the hits already found, and a scope that is not there throwing rather than answering "complete,
nothing found". FTPS behaved identically once its key was pinned.

**What the pass found is bigger than FTP, and it is in `Foundation`.** Every listing was paying a
flat ≈71 ms in **`Process.waitUntilExit()`, which is a poll and not a wait** — `/usr/bin/true` costs
the same as a full FTP listing, and a child dead for 300 ms still costs 71.3 ms (8 runs, 70.1–72.5;
the tightness is the tell). On loopback that was **84 %** of the per-listing cost. It hid for the
life of the app because its *relative* size is inversely proportional to how fast the child is: on
`git status` it is a quarter and reads as git being slow, and only something spending one invocation
**per directory** makes it the whole cost. The fix is one primitive in `ProcessWaiting` — the funnel
whose own doc comment already argued "one home rather than three copies" — applied to all **14**
spawn sites, since a half-applied rule is this project's most repeated failure. The whole-tree FTP
search went **1.04 s → 0.09 s** with byte-identical hits, and the same 0.09 s was then measured in
the built app against the server's log.

Two things worth keeping beyond the fix. It is **not** what "one `curl` per directory" costs, which
is the natural first reading: the identical argv from Python's `subprocess` is 6.7 ms against
Swift's `Process` at 68 ms, and that control is what isolates the wait from the spawn, the flags and
the network. And it mostly retires the optimisation it makes look attractive — `curl` does reuse one
connection across many `ftp://` URLs (11 LISTs on 1 connect, the FTP twin of Slice 4's `sftp -b`
note), but that is **15×** against the shipped path and only **1.4×** against the fixed one.

+4 app tests (2475 core / 535 app green, both linters and all three scripts clean). The timing
property is pinned without a stopwatch reading anyone has to trust, because what it asserts is the
absence of a *timer*: reaping a process dead for 300 ms, bounded well under the poll interval, which
no faster machine can drift past. The negative control fails that one test at 63 ms and leaves its
three narrowness controls green.

**Verified live in the built app**, with the new symbols confirmed present in `Dirnex.debug.dylib`
first: plain FTP 7 hits and FTPS 7 hits (12 breadth-first LISTs each, 0.091 s and 0.154 s, the
difference being TLS per connection), the Find Files dialog drawing **Name / Kind / Size / Modified**
on the FTP scope and **Content contains / Tags** as well on a local one *in the same session*, and
the trust dialog's fingerprint matching `openssl`'s byte for byte. The three other routes the
14-site change touched were checked in the same run and all behave: Spotlight (⌥F7 locally),
the git badge (`M` on a modified folder, plus the branch chip), and `bsdtar` archive browsing and
searching (3 hits at three depths inside a zip).

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
