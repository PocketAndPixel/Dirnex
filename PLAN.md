# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: M0–M9 shipped, M10 Phase 1 in progress · Created: 2026-07-05 · Log: [docs/HISTORY.md](docs/HISTORY.md)

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
├── docs/                       (NOTES.md gotchas · HISTORY.md M0–M9 log · RELEASING.md)
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

### Shipped: M0 → M9 (2026-07-05 → 2026-07-21)

Nine milestones, all closed. The checklists and the full per-pass progress log —
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

The undone column is scope that was decided against, not forgotten — each one is argued in
its HISTORY.md entry. The newest such call is the **built-in compare view** (2026-07-20):
external diff tools stay the handoff until they prove a persistent disappointment rather
than an occasional one.

M8 also closed with one deliberate deviation from its own exit criterion: **the Trash is a
merged listing, not a location** — macOS keeps one trash per volume, so the one sidebar row
that cannot be a directory browses like a *results* pane rather than like a folder. M9 closed
with a second: **"what Finder's iCloud Drive shows" is matched approximately, on purpose** —
which app containers Finder lists is not derivable from anything public, so Dirnex's rule is
public scope and a non-empty folder. Both are argued in HISTORY.md.

### Next

#### M10 — Google Drive and Docs (L)

Reaching the user's Google Docs. Phased along the two depths that actually exist, cheap first
(decided 2026-07-21): browse the local File Provider mount, then a real Drive API backend for accounts
that aren't synced to this Mac.

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
        - **The app name has a second source.** The cached plist `ICloudDrive.appLibraries()` reads
          is refused without Full Disk Access *while the container itself still lists* — observed
          live, where the crumb came out as `com.apple.Pages`. So the OS's own
          `URLResourceValues.localizedName` is injected as a fallback: non-hermetic, hence in the
          app, hence a closure the core is handed rather than one it calls (§2).
      - **The section refreshes live when an account is connected or signed out.** A File Provider
        mount is not a volume and posts no `NSWorkspace` notification, so this is an FSEvents watcher
        on `~/Library/CloudStorage` — the parent, never the mounts, which would wake on every synced
        file.
- [ ] **Open `.gdoc` / `.gsheet` / `.gslides` stubs** — a Google-native doc on the mount is a tiny
      JSON file, not bytes. Parse it (pure, core-tested) and open it in the browser instead of handing
      the stub to a text viewer, the way M4 hands off to external tools. Real (non-native) Drive files
      are dataless File-Provider items — the same download-on-open story as M9's iCloud, so that
      machinery is shared, not rebuilt.

      **Unblocked and re-specified 2026-07-21**, once the mount held real content. This bullet used to
      say the stub "holds a `docs.google.com` URL" — **it does not**, and building against that would
      have failed at the first file. The real bytes are
      `{"":"WARNING! …","doc_id":"…","resource_key":"","email":"…"}`, so the URL has to be
      *constructed* from `doc_id` and the extension. Exactly the failure mode §2's probe-first rule
      exists to catch; NOTES.md carries the format.

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

Open for M10 (Google Drive), still undecided:

- **Google OAuth scope for the Phase-2 backend** — the fork is `drive`/`drive.readonly` (restricted:
  browse the *whole* Drive, but Google requires restricted-scope verification **plus a paid annual
  CASA third-party security assessment** before a distributed build may use it) versus `drive.file`
  (unrestricted, no assessment, but limited to files the app itself created or the user explicitly
  picked — which cannot list a pre-existing Drive and so is useless for a file manager). This is a
  money-and-verification commitment, not a code choice, so it is decided before Phase 2 code starts.
  Phase 1 (the Desktop-mount browse) needs none of this and is unblocked. Recorded here because
  choosing `drive.file` to dodge the assessment would quietly gut the feature.
