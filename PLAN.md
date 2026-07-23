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
- **Slice 7 landed (2026-07-23): the Multi-Rename tool.** The whole ⇧F2 sheet — the name/extension
  mask fields and their hint placeholders, search & replace, the regex toggle, the case popup, the
  counter row, the token legend, the two preview column headers, the footer status and the confirm
  button — plus the batch failure alert: 26 new catalog keys across 2 files
  (`MultiRenameController`, `PanelViewController+MultiRename`), all Russian-filled; `Cancel` and
  `Rename` reused. Three recurring traps, fixed at the source: **hand-rolled plurals** became catalog
  plurals through `String(localized:)` interpolation — the conflict count (`count == 1 ? "conflict"
  : "conflicts"` → `%lld name conflicts`) and the confirm button (`renaming == 1 ? "Item" : "Items"`
  → `Rename %lld Items`), each Russian one/few/many; the **name/count split** in the failure alert
  (single case names the file `Couldn’t rename “%@”`, many case counts `Couldn’t rename %lld items`,
  only the count branch carrying the plural); and the **`+`-concatenation trap** in the token legend
  (`"a " + "b"` → one `\`-continued `"""` literal). Two deliberate non-translations: the **mask
  tokens** (`[N] [E] [C] [Y] [M] [D] [h] [n] [s]`) stay literal because they are the syntax the user
  types into the fields — the same convention as the SFTP/SMB acronyms — so only the words *around*
  them in the legend translate; and the status line `%lld of %lld will be renamed` stays a **plain
  two-argument string, not a plural**, because Russian expresses it with the impersonal neuter
  «Будет переименовано N из M», invariant across every count (the same reasoning that kept Slice 3's
  three-argument failure line out of a plural). Keys taken from the compiler-emitted `.stringsdata`,
  added by script with an **exact-match guard** — a mistyped curly quote aborts rather than creating a
  phantom entry — verified additive-only (26 added, 0 changed), the multi-space legend key checked
  verbatim against the emitted key. Verified live in Russian: the whole sheet (Маска имени ·
  Расширение · Найти · Заменить на · Регулярное выражение · Регистр: Исходный регистр · Счётчик:
  Начало/Шаг/Цифры · the token legend · Текущее имя/Новое имя), with every label fitting the fixed
  640 pt sheet, and both count strings live — the status «Будет переименовано 3 из 3» and the button
  plural «Переименовать 3 объекта» (correct *few* form for 3). The failure alerts were checked
  through the compiled `ru.lproj` (`.strings` + `.stringsdict`) rather than live, being awkward to
  provoke.
- **Slice 8 landed (2026-07-23): scripts, workspaces, and directory sync.** The whole
  script/workspace/sync surface — the scripts organizer sheet (name/run-mode/function-key/keywords/
  command fields, the argv-env help text), the **Scripts ▸** submenu and script-run failures, the
  displaced-function-key notice; the workspace organizer, the Workspaces popup, and the save/replace
  prompts; the Synchronize Directories sheet (direction/comparison controls, the diff table's action
  glyphs and per-row override menu, the status/error lines) and its menu action and delete
  confirmation: 74 new catalog keys across 9 files, all Russian-filled; `Cancel`, `Done`, `Name`,
  `OK`, `Replace`, `Scripts` reused. The recurring traps, all fixed at the source: the
  **`+`-concatenation trap** in two multi-sentence bodies (the scripts help text and the
  displaced-keys footer → single `\`-continued `"""` literals); **verb/noun-splicing** in the
  displaced-keys line, kept as *one* positional-arg frame (`• %@ — %@ now runs %@.`) so Russian
  reorders it, with the key label and the claimant (`a macOS shortcut` / `a Dirnex command` / a
  command title) translating as independent object noun phrases; the **name/count split** in the
  script-run and displaced-keys titles (single names the file, many counts — separate keys, only the
  count branch a plural); and three **catalog plurals** (`%lld conflicts skipped`, `%lld scripts no
  longer run…`, `Synchronizing will move %lld items to the Trash.`, Russian one/few/many). Two
  plain-string decisions matching earlier slices: the sync status `%lld to copy, %lld to delete`
  stays a two-count string (neither verb inflects), and the script exit line is `Exited with status
  %d.` — the exit code is an `Int32`, so the emitted specifier is `%d`, not `%lld` (taken verbatim
  from the `.stringsdata`, not assumed). Technical tokens stay literal, as ever: the `$@` / `$1` /
  `$DIRNEX_*` shell variables in the scripts help. One structural cost: localization pushed
  `UserScriptsOrganizerController` past **all three** SwiftLint ceilings at once — the
  view-construction methods moved to the same-file `private extension` (type-body), and the table
  data-source moved to a companion `UserScriptsOrganizerController+Table.swift` (file-length),
  widening `scripts`/`loadDetail` to internal (docs/NOTES.md file-splitting). Keys taken from the
  compiler-emitted `.stringsdata`, added by script with an exact-match guard, verified additive-only
  (74 added, 0 changed). **The live Russian run caught one fit bug, as every slice has:** the sync
  controls row overflowed — measured (`NSLog`, not eyeballed) at **1163 pt demanded in a 680 pt row**,
  which collapsed the direction segmented control to an unreadable «…». Fixed two ways: the hint's
  horizontal compression resistance was lowered so it (not the controls) yields — a language-agnostic
  structural fix — and the Russian direction labels were shortened to single words («Слева
  направо»→«Направо», «В обе стороны»→«Обе», «Справа налево»→«Налево»), bringing the controls to
  657 pt; re-measured to confirm. The scripts organizer and the Save-Workspace prompt were verified
  clean live; the run/notice failure alerts were checked through the compiled `ru.lproj`, being
  awkward to provoke.
- **Slice 9 landed (2026-07-23): the remaining Browser controllers.** The last bare status/tooltip
  strings across `Dirnex/Browser/` — the Find Files sheet (`SearchController`: field labels, the
  kind/size/date/scope popups, placeholders, Find/Cancel), the Save Search and Replace dialogs, the
  New Tag dialog and its colour popup, the tag menu (New Tag… / Remove All Tags) and tag-change
  failure, the Favorites ⌃D menu (No Pinned Folders / Add·Remove Current Folder / missing-favorite
  alert), the terminal-launch failure, the iCloud download sheet, the inline-rename validation and
  failure alerts, the search-results truncation alert, and the window-controller tooltips (Toggle
  Sidebar, hidden-files toggle, update indicator): **68 new catalog keys across 15 files**, all
  Russian-filled; ~19 keys reused (Cancel/OK/Save/Remove/Replace, the pre-existing `Replace “%@”?`,
  `Recents`, `Trash`, `Results for %@`, and several more). **Three `DirnexCore` data enums got the
  registry treatment** (like `SidebarSection`): `SearchKind`/`SearchAge`/`FinderTagColor` `.title`
  reach the popups through a variable, so `LocalizationKey.searchKind/searchAge/tagColor` key them
  (the last by a switch-derived stable token, not its `Int` raw value, so the catalog reads as colour
  names), `LocalizedCatalog.title(for:)` joins them, and `LocalizationCoverageTests` now fails on an
  untranslated kind/age/colour (18 symbolic keys). Recurring traps fixed at the source: the
  **`+`-concatenation trap** in the iCloud download body (`"a " + "b"` → one literal), and the New Tag
  dialog's `colour` popup built its titles from `color.title` (a variable) — the exact reason the
  registry treatment exists. **Two things only the live Russian run caught, both after a *second*,
  wider scan:** the first pattern-based sweep missed every **multi-line `NSMenuItem(title:` / menu
  constructor** (the Favorites and tag menu items sat bare), and the **Recents virtual tab leaked
  English** — its tab title read "Recents" and its path bar "Результаты для Recents", because a
  `.search`-backend listing borrows the "Results for %@" phrasing. Fixed by giving Recents the Trash's
  self-naming treatment: `pathSummary` stays a stable English identity (`ResultsPresentation
  .recentsIdentity`, never displayed), the tab title localizes, and `rebuildVirtualLabel` matches on
  the identity to draw "Недавние" with the sidebar's `clock` glyph — the same lesson as the Trash,
  that a *place you visit* must name itself rather than read as a search someone ran. The stock tag
  *names* in the ⌃T menu (Red/Orange/…) stay English on purpose — they are `FinderTag.systemTagName`
  data, a separate core concern, not the colour titles. Keys taken from the compiler-emitted
  `.stringsdata`, added by script with an exact-match guard, verified additive-only (68 added, 0
  changed). Verified live in Russian: the whole Find Files sheet with all four popups, the Favorites
  and tag menus, the New Tag dialog and its eight colour names (Без цвета · Серый · … · Оранжевый),
  and the Recents self-naming; the awkward-to-provoke alerts were checked through the compiled
  `ru.lproj`.
- **Slice 10 landed (2026-07-23): the undo/redo action labels — the last piece of Pass 2.** The
  "Undo Move" / "Redo Clear Selection" menu titles composed `"Undo \(label)"` from a `label` that is
  *data*, not an app literal: the file-op names ("Copy", "Move", "New Folder", "Rename", "Move to
  Trash") originate in `DirnexCore`'s `UndoJournal`, and the selection-gesture names ("Mark", "Select
  All", "Invert Selection", "Select Files", "Unselect Files", "Clear Selection", "Select Range") are
  authored in the app and passed *into* the core on a `SelectionChange`. The fix was **the registry
  treatment, made honest by a type change**: a new `DirnexCore` enum `UndoActionLabel` names the whole
  finite vocabulary (English `title` = fallback data, stable `rawValue` = the key), and `UndoRecord
  .label` / `SelectionChange.label` / `UndoEntry.label` went from `String` to it — so a mistyped label
  is now a compile error, not a silently-untranslated magic string, and one coverage test
  (`UndoActionLabel.allCases`, 12 symbolic keys) proves every label is translated. `LocalizationKey
  .undoActionLabel` keys it, `LocalizedCatalog.title(for:)` joins it, and the two `"Undo %@"` /
  `"Redo %@"` menu frames plus the two `"Undo %@ finished with issues"` alert frames and the idle
  "Undo"/"Redo" collapse became `String(localized:)` literals (six English-text keys; Russian splices
  the accusative noun that follows «Отменить/Повторить» — "Отменить копирование", "Отменить выделение").
  18 new catalog keys across 12 core+app files, all Russian-filled. Two things worth recording. **The
  label is persisted** (a file-op record survives relaunch, `UndoController`), so the clean-token
  `rawValue` changes the journal's on-disk form — which decodes-or-resets exactly as `UndoController`
  already documents ("fails to decode and starts empty — a one-time reset, never a crash"), verified,
  not assumed. And the four **frame keys are English-text keys, not covered by the coverage test**
  (which only checks symbolic registry keys), so their exact spelling was confirmed against the
  compiler-emitted `.stringsdata` (`Undo %@`, `Redo %@ finished with issues`, … — byte-identical, no
  `%1$@` positional drift that would have silently fallen back to English) and against the compiled
  `ru.lproj`. Keys added by script, verified additive-only (18 added, 0 changed). Verified live in
  Russian: Space-mark → **Правка ▸ «Отменить выделение»** with **«Повторить»** collapsed, then Cmd+Z →
  **«Отменить»** collapsed with **«Повторить выделение»** — all four states (active/idle × undo/redo)
  rendering the composed frame + translated label. The file-op labels share the identical display path
  (the same join, the same frame), so proving the selection path proves them without mutating the
  filesystem; their translations were checked through the compiled `ru.lproj`.
- **Slice 11 landed (2026-07-23): the strings that reach the screen through a *return value*.** An
  audit after Slice 10 — a full sweep of the app *and* the core for bare prose, cross-checked against
  the compiler-emitted `.stringsdata` — found Pass 2's sweeps had all shared one blind spot, and it
  cost seven surfaces. Every earlier scan looked for the **assignment** (`messageText =`, `title:`,
  `String(localized:`); these seven compose their text in a computed property or a function that
  *returns* `String`, with the assignment a file away. It is the `statusText()` lesson from Slice 9
  generalized: that one was fixed as an instance, not as a class. **50 new catalog keys across 20
  files**, all Russian-filled.
  - **The 30 `VFSError.unsupported` sentences were the bulk of it**, and the fix is structural rather
    than a wrapping pass: `PanelViewController+Errors` ended its switch with `case let
    .unsupported(message): return message`, so every one of them — 17 authored in `DirnexCore`, 13 in
    the app — went to the screen in English, under a translated alert title, at the exact moment
    something had failed. The payload changed from a free-form `String` to a new
    `VFSUnsupportedReason` enum (the `UndoActionLabel` move from Slice 10, applied to an error):
    English `sentence` = fallback data, stable `key` = the translation key, and — because six of the
    sentences take arguments — a `%@` `englishFormat` plus its `arguments`, spliced *after* the
    lookup so a translation can reorder them positionally. `LocalizationKey.vfsUnsupported` keys it,
    `LocalizedCatalog.sentence(for:)` joins it, and one coverage test over
    `VFSUnsupportedReason.allCases` (27 symbolic keys) proves every sentence is translated **and**
    that no translation dropped a placeholder — a lost `%@` swallows the file name the sentence was
    naming. `CaseIterable` can't be synthesized with associated values, so `allCases` is spelled out
    with placeholder arguments; the key doesn't depend on them.
  - **Three surfaces moved their *words* out of the core rather than getting keys**, because the core
    owned a presentation decision it had no business owning: `UpdateAvailability.tooltip` (the
    permanently visible titlebar indicator) → `BrowserWindowController.tooltip(for:)`;
    `GitBranch.displayName`'s `"detached HEAD"` → `GitBranchChipView`; and
    `SFTPTransportError.classify`'s empty-stderr fallback, which now returns `.failure("")` — the
    payload is the *server's* words, and the app supplies a localized stand-in when there are none,
    exactly as it already owned the wording for `.notFound` / `.permissionDenied`. This is the
    `SyncBadgeStyle` / `GitStatusStyle` split ("the core picks the state; this picks the pixels and
    the words") applied where it had been skipped. Three core tests asserting the tooltip's English
    moved to the app as `UpdateIndicatorTooltipTests`; the *state* they rested on was already covered
    in `UpdateAvailabilityTests`, so nothing was lost.
  - **The remaining four were ordinary wrapping** of return-value producers: the cloud sync badge's
    tooltip and VoiceOver label (`SyncBadgeStyle.label(for:)`, 7 strings, on every cloud row),
    `SMBMountError.errorDescription` (5), `CloudDownloadPrompt`'s `verdict`/`describe` (4), and
    `SFTPProcessTransport`'s two failures. Each literal sits *at* its `String(localized:)` call
    rather than being switched into one, or it extracts nothing.
  - Verified live in Russian, three of the seven end to end: a deliberately corrupt `.zip` produced
    «Не удалось прочитать архив «broken.zip».» (the whole chain — core enum → key → catalog → join →
    `VFSErrorText` — with the argument spliced), a detached-HEAD repo drew «отсоединённый HEAD» in the
    Git chip, and an evicted iCloud file's badge read «Не загружено — хранится в облаке». The four
    awkward-to-provoke ones (SMB, iCloud download, SFTP, the update indicator) were checked through
    the compiled `ru.lproj`, as earlier slices did. One probe was wrong before it was right, and is
    worth recording: `plutil -extract` reads a dotted key as a **keypath**, so it reported all 27
    `vfs.unsupported.*` keys MISSING from a bundle that had every one of them.
  - Keys added by script with the usual exact-match guard against the emitted `.stringsdata` and an
    additive-only check (50 added, 0 changed), and `Couldn’t mount the share (error %d).` was taken
    verbatim from it — the errno is an `Int32`, so the specifier is `%d`, not `%lld`.
- **Pass 2 is complete.** Every AppKit/SwiftUI literal and every registry-owned string is wrapped and
  Russian-filled across Slices 1–11. One documented non-goal stays English: the stock Finder-tag
  *names* in the ⌃T menu, which are `DirnexCore` `systemTagName` data with the localization caveat
  already in `FinderTag`. Two deferrals stand, both re-confirmed by Slice 11's audit: the App Intents
  strings (21 keys, their own pass) and the archive format names. The AppleScript error *messages*
  join the `.sdef` terminology in staying English, on the same reasoning. Next is Pass 3 — the
  remaining six languages.

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
