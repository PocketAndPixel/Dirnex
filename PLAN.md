# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: M0–M11 shipped · M12 (localization) in progress · Created: 2026-07-05 · Log: [docs/HISTORY.md](docs/HISTORY.md)

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
├── docs/                       (NOTES.md gotchas · HISTORY.md M0–M11 log · RELEASING.md)
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

### Shipped: M0 → M11 (2026-07-05 → 2026-07-22)

Eleven milestones, all closed. The checklists and the full per-pass progress log —
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
| M11 | F4 Edit, and Quick View at full size | 07-22 | A built-in text editor (F4 hands the file to the user's own); write-back for archive and SFTP files (edit-temp-watch-repack is its own slice); a slideshow timer or thumbnail filmstrip in the preview |

The undone column is scope that was decided against, not forgotten — each one is argued in
its HISTORY.md entry. The newest such call is the **built-in text editor** (2026-07-22): a
real one is encoding detection, line-ending preservation, a binary gate, undo grouping and
find/replace — a whole app, and every Mac already has one the user has already chosen, so F4
hands the file over the way ⌥F3 hands two files to FileMerge. Revisit only if leaving the app
proves to break the keyboard-first flow, which is a claim to test by living with the handoff
first. The call before it was the **Drive API backend** (2026-07-22): the Desktop mount reaches
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

### In progress: M12 — Localization (started 2026-07-22)

Eight languages eventually; English is the source and Russian is the first translation, added
alongside the machinery so the machinery is proven by a real language rather than by a
pseudolanguage. No RTL in the planned set — CJK is, so input-method behaviour in the inline rename
field and the palette needs a live check when those land.

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

**Pass 2 — the extraction sweep (in progress).** ~500–700 remaining AppKit and SwiftUI literals
wrapped file by file so Xcode extracts them, then Russian filled in. Mechanical; the lever that makes
it verifiable is Xcode's **pseudolanguages** — accented catches literals that were never wrapped,
double-length catches truncation in the function bar and column headers before a translator is
involved. Worth a lint rule keeping bare literals out of UI files afterwards.

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
- **Deferred as its own slice: the undo/redo action *labels*.** The "Undo Move" / "Redo Clear
  Selection" menu titles compose `"Undo \(label)"` from a label that is *data*, not an app literal:
  the file-op names ("Move", "Copy", "Rename", "Move to Trash", "New Folder") originate in
  `DirnexCore`'s `UndoJournal`, and the selection/navigation names ("Mark", "Select All", "Invert
  Selection", "Back", …) are passed *into* the core from the panes. Localizing this properly means
  giving those labels the registry treatment (a symbolic key per label, joined in the app) and
  localizing the `"Undo %@"` / `"Redo %@"` frames — a core-touching change. Doing only the app half
  would leave the menu mixing a Russian frame with English labels, which is worse than uniform
  English, so the whole concern waits for one slice.
- **Remaining:** the rest of the `Dirnex/Browser/` controllers — multi-rename, the user-script and
  workspace organizers, sync, and the assorted status/tooltip strings; then the undo-label slice
  above.

**Pass 3 — the remaining six languages.** Adding one is a line in `AppLanguages.all` plus its
column in the catalog; `LocalizationCoverageTests` fails until the column is complete.

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
conventionally English and translating it breaks users' scripts. App Intents phrases are localizable
but are their own pass.

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
