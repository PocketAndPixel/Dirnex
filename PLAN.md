# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: M0–M15 shipped (14 languages) · **M16 in flight** · Created: 2026-07-05 ·
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

### Shipped: M0 → M15 (2026-07-05 → 2026-08-02)

Every milestone through M15 is closed. The checklists and the full per-pass progress log —
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
| M15 | The tree view, and colour the user chooses | 08-02 | The **thumbnail grid, brief view and the `PaneSurface` extraction** (cut 2026-08-02 — the three are one unit, and `FileTableView` is a 25-method contract a grid satisfies none of); a memo in front of `fnmatch` (measured unnecessary — 0.46 ms per full reload for 5 rules); size bars in tree mode, withdrawn at close and re-scoped per parent directory in a follow-up (`SizeVisualization(tree:)`) |

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

### Open: M16 — Quick View: source or page (S–M)

Goal: an HTML file previews **as its source by default**, and as a real rendered page on demand,
switched with `1` / `2` the way Lister's view modes are. Opened 2026-08-06.

The complaint that opened it was "the rendered page doesn't stretch to the available area", and
reading the code found the larger half: HTML routes to `QLPreviewView`, which renders it as a
fixed-width document *card* — and the surface deliberately swallows the mouse
(`QuickViewPreviewView.hitTest`, NOTES.md), so **a page longer than the surface cannot be scrolled
at all**. Neither is fixable from our side of an out-of-process view. So the rendered mode is a
fourth in-process backend beside `PDFView`, `NSImageView` and `QuickViewTextView`, for the same
reason each of those exists: something Quick Look cannot give the user here.

App-only, with one core touch (two `CommandCatalog` entries, which are data). Nothing new reads
bytes — `TextPreview` already does that, and `TextPreview`'s own doc comment already states the
division this milestone leans on: *routing a file is a UTType question, and therefore a UI one*. The
render-style enum is therefore an app type, the twin of `RowDensity` and `SizeVizDisplayMode`.

Probed before any Swift (2026-08-06):

- **`.xhtml` is `public.xhtml`, which does not conform to `public.html`** — so `isText`'s existing
  `!type.conforms(to: .html)` exclusion never caught it and XHTML already previews as source today.
  The dual-style set is therefore named explicitly (`.html` and `.xhtml`), not derived from one
  conformance. `.mhtml` and `.webarchive` conform to neither text nor html and stay with Quick Look.
- **A local page in a plain `WKWebView` reaches the network, and the page's own error handlers say
  it didn't.** Measured against a real HTTP server on 127.0.0.1: a preview of one saved page issued
  three GETs (a stylesheet, an image, a `fetch`) while `window.probe` reported `img: 'error'` and
  `fetch: 'blocked'` — the responses fail CORS, the *requests* go out. A tracking pixel needs only
  the request, so "the page reported an error" is not evidence of anything.
- **A two-rule `WKContentRuleList` (block `.*`, then `ignore-previous-rules` for `^file://`) stops
  all of it**: zero requests reached the server on the A/B rerun, while JavaScript still ran, the
  page's local stylesheet still applied, and `data:` images — what a self-contained report inlines —
  still loaded. `blob:` URLs are collateral and are blocked; nothing a preview needs.

Hence the policy: **JavaScript on, network off**. Local JS with no network cannot exfiltrate, and it
is what makes a self-contained report render instead of showing raw LaTeX the way Quick Look does
now. A non-persistent data store, `loadFileURL(_:allowingReadAccessTo:)` scoped to the file's own
directory, and a navigation delegate that refuses everything but the initial load complete it.

#### Slice 1 — The rendered backend (S–M) — landed 2026-08-06

- [x] `QuickViewWebView` + `QuickViewPreviewView+HTML` — a `WKWebView` pinned into `content`
      alongside the other three backends, with the rule list, the ephemeral store and the scoped
      file load. Added to `hitTest`'s interactive list so it scrolls and the mouse works.
- [x] HTML routes here instead of to `QLPreviewView`. Ordered first on purpose: it is an
      improvement on its own (the page fills the surface and scrolls) and never a regression, which
      the reverse order would be — text-only would take rendered HTML away before anything gave it
      back.

Exit: a long local page fills the surface and scrolls at all three sizes; a page referencing a
remote asset makes no request (verified against a local server, not against the page's own report).
**Met** — a throwaway harness compiled against the *shipping* `QuickViewWebView.swift` reported the
web view filling its container exactly (900×500 in a 900×500 surface, against Quick Look's card), a
13 676 pt document scrolling inside a 500 pt viewport, JavaScript running, the local stylesheet
applied, a link click declined (still on `page.html`), `clearPage` emptying the document — and **zero
requests** in the server's log for the run.

The image backend moved to `QuickViewPreviewView+Image.swift` on the way: the fourth backend pushed
the class past `type_body_length`, and each in-process backend stating its own reason for existing
in its own file is where they were all heading anyway.

#### Slice 2 — The two styles, and the keys (S) — landed 2026-08-06

- [x] `QuickViewRenderStyle` (`.source` / `.rendered`), persisted app-wide in `AppPreferences`,
      defaulting to `.source`. A reading preference like `rowDensity`, not a per-tab question.
- [x] `isText` takes HTML when the style is `.source`; the web backend takes it when `.rendered`.
      RTF keeps its Quick Look rendering — it has no source anyone wants to read.
- [x] `1` / `2` in the existing Quick View key monitor, gated on the mode being on *and* the file
      offering both styles. Not menu key equivalents: a bare digit as a key equivalent is
      window-global and would swallow `1` everywhere.
- [x] Two `CommandCatalog` entries so the menu and the ⌘K palette can reach it, with the 13
      translations `LocalizationCoverageTests` requires, and the full-size header naming the two
      styles when the file offers both.

Exit: `1` and `2` flip a previewed page between source and rendering, the choice survives walking
the list and a relaunch, and a digit still types normally everywhere else. **Met**, verified live
against the real binary at both sizes: ⌃⇧Q opened on the source with the header reading
`1 Source · 2 Page`, `2` rendered the page edge to edge with its CSS and its JavaScript, two scrolls
reached filler line 51 (the gesture that did nothing at all before), `1` came back to the source, and
the choice survived a quit and relaunch into ⌃Q.

The last clause is the one that found a bug, and only live: with a preview up, ⌘L and typing
`/tmp/12` put **`/tmp/`** in the path field — the monitor ate both digits inside a text field. Esc's
carve-outs were written into `escapeBelongsToQuickView`, so the digit branch three lines away
inherited none of them; `digitBelongsToQuickView` is the fix, and it is deliberately *not* the same
predicate (a `FileTableView` is exactly where these keys must work, and is where Esc must not).

#### Slice 3 — The JavaScript switch (S) — landed 2026-08-06

Added on request after Slice 2. Scripts stay **on** by default, for the reason the milestone opened
with: the risk a previewed page carries is the network, and that is closed unconditionally by the
rule list — a script with no network cannot report what it saw. The switch exists because "run no
code from a file I have not opened" is a coherent position, and a preview that renders on every
cursor step is where somebody may want it.

- [x] `AppPreferences.quickViewJavaScriptEnabled`, Settings ▸ Panels, translated in all 14.
- [x] Applied **per navigation** in the policy delegate, not on the configuration. Probed on one live
      web view over four loads: the delegate's `preferences` re-gated scripts off and on each time,
      while assigning `webView.configuration.defaultWebpagePreferences.allowsContentJavaScript` did
      nothing at all **and read back as though it had worked**.
- [x] A change reloads open previews (`reloadPage`) rather than re-delivering them — the answer is
      given per navigation, so a page already rendered has had its.

Exit: the toggle changes an open preview live, both ways, and defaults on. **Met**, verified live —
the visible page flipped between "JavaScript RAN" and "JavaScript did NOT run" with its CSS intact
in both, and back again.

**The slice's real find, in the code Slice 1 had already shipped.** Asserting the delegate callback
in a test failed, and `class_copyMethodList` said why: on a `@MainActor` class in Swift 6 the
*completion-handler* spelling of an `@objc` optional requirement compiles, reports
`surface is WKNavigationDelegate == true`, and **is never emitted as an Objective-C method** — the
class's whole method list was its two initializers. WebKit dispatches by `respondsToSelector:`, so
the policy callback had never run and the "a link cannot navigate the preview away" rule was absent
from the shipping build. The `async` variant is the witness Swift 6 recognizes; a link click is now
declined live. Slice 1's harness had "verified" the broken version because a throwaway `swiftc`
binary compiles in the **Swift 5** language mode, where that spelling *is* the witness — the whole
trap is written up in NOTES.md.

Left deliberately undone (to be argued at close): Markdown and RTF as dual-style types, and
`.webarchive` / `.mhtml`, which need `loadData` rather than a file load.

The scope that is already written down, rather than merely imaginable, is in the *undone* column
above plus M15's cut: the **thumbnail grid, brief view and the `PaneSurface` extraction** (one unit,
argued in HISTORY.md §M15, with the two constraints any future grid inherits — skip
`FileEntry.isDataless` rows, and move sort off the column header first). The one item two separate
milestones have asked for is **edit-temp-watch-repack write-back** — M11 named it for archives and
SFTP, M13 for FTP — so it is the candidate that would close the most open ends at once.

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
| The tree becomes a *second* pane implementation by accretion — a refresh path, a mark gesture or a sort that quietly forks from the flat one | The tree is a flat projection over the same `NSTableView` and the same index space, not a parallel surface (HISTORY.md §M15 Slice 4); anything that forks is a signal the projection is wrong, not that the tree needs its own copy. Both fork points were answered in the slice — `SizeVisualization`'s per-directory assumption (the bars were withdrawn in tree mode at M15 close, then re-scoped *per parent directory* rather than forked — `SizeVisualization(tree:)` groups each row against its own level, so the projection stays one definition of "share of this folder") and the `installSortedModel` → `reloadEverything` → `syncCursorToTable` tail. It arrived once already, as the *second index space*: six `panel.model[row]` sites that crashed on the first click below the root's last entry, now routed through `displayedIndex(ofID:)` — NOTES.md ▸ AppKit |

## 7. Open questions

**Open now:** none. M15's two closed with it (below), and nothing has been opened since.

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

- **What F5/F6 do with marks spanning levels** — resolved: **TC's branch-view behaviour**, flatten
  *preserving relative paths* under the destination. Copying everything flat into one folder is the
  alternative and it silently collides the moment two folders hold an `x.jpg`.
- **F8 with an ancestor and its descendant both marked** — resolved: **dedupe to the ancestor**
  before enqueuing, since deleting the parent already takes the child. Implementing it added the half
  the settling did not say: **the dedupe belongs to F5/F6 too** — a copy fails *politely* there, with
  a conflict prompt over a file the user never chose to duplicate, which is quieter and no less wrong.

Both live in `TreeSelection` (core, 18 tests); the app keeps one `recursiveTargets()` for the
operations that recurse and the raw `selectionTargets()` for the ones that don't. See
[HISTORY.md](docs/HISTORY.md) §M15.
