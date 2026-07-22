# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: M0–M10 shipped · Created: 2026-07-05 · Log: [docs/HISTORY.md](docs/HISTORY.md)

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
├── docs/                       (NOTES.md gotchas · HISTORY.md M0–M10 log · RELEASING.md)
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

### Shipped: M0 → M10 (2026-07-05 → 2026-07-22)

Ten milestones, all closed. The checklists and the full per-pass progress log —
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

The undone column is scope that was decided against, not forgotten — each one is argued in
its HISTORY.md entry. The newest such call is the **Drive API backend** (2026-07-22): the
Desktop mount reaches every Drive account that is actually on this Mac, and going past it
would have bought a second, worse path to the same files at the price of an OAuth flow, a
restricted-scope verification and a paid annual security assessment. It also lines up with
§1's standing non-goal — cloud folders are folders, no proprietary APIs.

M8 also closed with one deliberate deviation from its own exit criterion: **the Trash is a
merged listing, not a location** — macOS keeps one trash per volume, so the one sidebar row
that cannot be a directory browses like a *results* pane rather than like a folder. M9 closed
with a second: **"what Finder's iCloud Drive shows" is matched approximately, on purpose** —
which app containers Finder lists is not derivable from anything public, so Dirnex's rule is
declared public scope and a folder that exists. Both are argued in HISTORY.md. The *direction* of
that approximation was reversed on 2026-07-21 (see M10): it used to also require a
non-empty folder, which hid three folders Finder shows.

### Next

#### M11 — F4 Edit, and Quick View at full size (S)

Two independent slices, neither of which needs the other: F4 binds the last free key on the
Total Commander row, and ⌃Q's preview grows two larger sizes. Both are app-side by
construction — one hands a file to another app, the other is AppKit geometry — so the core's
share of this milestone is a handful of catalog entries.

##### F4 Edit

The last unbound key on the Total Commander row. F4 has been deliberately free since M6
(`FunctionBar.slot(forFunctionKey:)` names it as the example of an unmapped key) because
Dirnex has no edit command; this gives it one **without writing a text editor**. A real
editor is encoding detection, line-ending preservation, a binary gate, undo grouping and
find/replace — a whole app, and every Mac already has one the user has already chosen. So
F4 hands the file over, exactly the way ⌥F3 hands two files to FileMerge. Same split as
M5's compare-by-content: a pure tested descriptor in the core, a thin launcher in the app,
a Settings picker between them.

- [ ] **`ExternalTextEditor` (core)** — the descriptor and the resolution order, mirroring
      `ExternalDiffTool`: BBEdit, VS Code, Sublime Text, Zed, Nova, TextMate, CotEditor,
      Xcode, TextEdit. One deliberate deviation — resolve by **bundle identifier through an
      injected probe, not by CLI executable path**. `ExternalDiffTool` looks for `bbdiff` /
      `opendiff` because a diff tool *is* invoked as a command; an editor's shim (`code`,
      `subl`) is an optional install most users never perform, so probing for it would report
      "VS Code isn't installed" to someone staring at its icon in the Dock. `OpenWithLauncher`
      already opens by bundle URL and is the model. **Automatic** = the system's own default
      handler for plain text, so a user who never opens Settings gets what double-clicking a
      `.txt` already gives them.
- [ ] **F4 opens the file under the cursor** — directly, no dialog (decided 2026-07-22; TC's
      own split). Cursor item only, marks ignored: this is "edit the thing I'm pointing at",
      and a dozen editor windows is not what a marked set means. A directory under the cursor
      is not editable, so F4 there is inert — no error, the same way ⌥F3 declines a folder.
- [ ] **⇧F4 opens the name dialog** — prefilled with the cursor's file name and selected, so
      Enter is "edit this" and typing over it is "make a new one". Existing name → open it;
      new name → create the empty file, then open it. F4 with nothing editable under the
      cursor (the `..` row, an empty directory) falls through to this dialog rather than doing
      nothing, which is where TC's Shift+F4 and plain F4 usefully converge.
- [ ] **Gate the create path on a real directory, not on `.write`** — `writeDirectory`, the
      guard `promptForNewFolder` already uses. NOTES.md's standing trap: the merged Trash
      carries `.write` so `deleteStrategy` resolves to `.permanent`, and that alone lit up New
      Folder and Paste inside a Trash tab. ⇧F4 must not become the third. Reuse New Folder's
      shape wholesale — `NSAlert` + accessory field, `/` refused with a real message, then
      `refreshCurrentDirectory(selecting:)` so the new file lands under the cursor.
- [ ] **Local files only** — `.local` backend filter, the same one Open With, Quick Look and
      Compare all apply. An archive member or an SFTP file would edit an extracted temp copy
      whose saves go nowhere (already noted at `PanelViewController+NestedArchive`), and a
      silent no-op that looks like it worked is the expensive kind of wrong.
- [ ] **Route through `CloudDownload`, never `String(contentsOf:)`** — an evicted iCloud or
      streaming-Drive file is `SF_DATALESS`, and touching one byte blocks while it materializes
      (measured 1.1 s for 200 KB). The listing already carries `isDataless`; F4 reads it and
      shows the existing download prompt instead of beachballing.
- [ ] **Absorb the fallout of binding F4** — it joins `FunctionBar.defaultSlots` as "Edit" and
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

##### Quick View at full size

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

- [ ] **`QuickViewPreviewView` — extract before extending.** The overlay and its two backends
      (the `NSBox` backing, the lazy `QLPreviewView(.compact)`, the lazy `PDFView`, the
      content-type routing between them) come out of `PanelViewController+QuickView` into a
      standalone view. The pane keeps one pinned over its scroll view; each new mode hosts an
      identical one at a different anchor. A pure refactor with no behaviour change, and the
      thing that keeps this slice from being three copies of one preview.
- [ ] **A mode, not a Bool** — `isQuickViewOn` becomes
      `QuickViewMode { off, pane, fullWindow, fullScreen }` on the window controller, which
      already owns the state because the mode spans both panes. `isQuickViewEnabled` stays as
      `mode != .off`, so `fileTableCancel`'s progressive Esc and `validateMenuItem` need no
      rethink.
- [ ] **Re-assert table focus after every show.** The new risk the pane version never had: in
      the full modes the preview sits over the *focused* table, so a backend that takes first
      responder turns ↑/↓ into document scrolling and the cursor stops moving — the mode's whole
      point, lost silently. `focusedPanel.focusTable()` after each show, and a subclass refusing
      first responder if that isn't enough. Verify live; first-responder questions are exactly
      what a screenshot cannot answer.
- [ ] **⌃⇧Q full window, ⌃⌥Q full screen — flat toggles.** Each key turns its own mode off and
      switches from any other; Esc closes straight out to the file list from any of the three.
      Deliberately *not* an escalation ladder where repeat presses of ⌃⇧Q climb — that is a key
      that never turns off what it turned on.
- [ ] **Full window anchors on `panesSplitViewController.view`** — both panes and the divider,
      and nothing else. The sidebar, the drawer and the function bar stay usable, which is what
      separates this mode from the next one rather than making it a smaller version of it.
- [ ] **Full screen anchors on the window's `contentView` and enters the native space** —
      black backing instead of `textBackgroundColor`, no chrome. The fiddly part is state sync,
      not rendering: `toggleFullScreen(nil)` needs a *did we enter it* flag or closing the
      preview evicts a user who was already full-screen, and `willEnterFullScreen` /
      `willExitFullScreen` observers or leaving by ⌃⌘F or the green button leaves the mode
      claiming something untrue.
- [ ] **A name-and-position header, in both full modes.** In pane mode the list sits beside the
      preview; in the full modes it does not, and arrowing through files you cannot see is
      flying blind. Pinned in full window (a working surface), fading in and back out on mouse
      movement in full screen (a viewing one).
- [ ] **← / → step the cursor while a full mode is up.** Both keycodes fall straight through
      `FileTableView.handleTypingKey` today, so they are free — and nobody flips through a
      vacation folder with ↑/↓.
- [ ] **Two catalog commands** — `view.quickViewFullWindow` (⌃⇧Q) and `view.quickViewFullScreen`
      (⌃⌥Q), with menu items beside Quick View Panel, `CommandBinding` selectors and
      `validateMenuItem` checkmarks. `KeyBindings().conflicts(for:)` is what proves both are
      free, and the catalog test is the only test this slice can carry — the rest is AppKit and
      is verified by driving the built app.

Exit: ⌃⇧Q reads a PDF across both panes with the sidebar still in place; ⌃⌥Q fills the display
with a photo and nothing else; arrows walk the file list underneath in both, and Esc returns to
it. Explicitly **not** in scope: a slideshow timer or a thumbnail filmstrip — that is an image
viewer, and the point here is that the *file list* remains the navigation.

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
