# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: M0–M11 shipped · M12 (localization) Passes 1–2 done, Pass 3 slices 1–7 done · M13 (FTP/FTPS) shipped · M14 (checksums + attributes) planned · Created: 2026-07-05 · Log: [docs/HISTORY.md](docs/HISTORY.md)

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

### Shipped: M0 → M11, M13 (2026-07-05 → 2026-07-25)

M0–M11 and M13 are closed; M12 (localization) is in progress — see below, which is why the
table steps from M11 to M13. The checklists and the full per-pass progress log —
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
| M13 | FTP and FTPS | 07-25 | `MLSD` (`curl` cannot send it); FTP-side `DirectorySync` by timestamp (unreliable by construction — LIST stamps are year- and zone-less); write-back for files edited in place over FTP (the shared edit-temp-watch-repack slice); an opportunistic "TLS optional" client mode (a password-downgrade vector — rejected 2026-07-26) |

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

Nine languages now; English is the source and Russian is the first translation, added
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
- **Slice 12 landed (2026-07-24): the completeness audit, and the first *behavioural* leak.** A
  full re-run of Slice 11's sweep over the app and the core, cross-checked both ways against the
  compiler-emitted `.stringsdata` (extracted-but-uncatalogued *and* catalogued-but-unused), plus a
  scan for bare literals at AppKit display sinks. The catalog itself came back clean — 726 keys, `en`
  and `ru` complete, no blanks — and the extracted-but-untranslated set was **exactly** the 21 App
  Intents keys already deferred, so Slices 1–11 held. Six leaks remained; **6 new catalog keys**
  across 8 files. Three were confirmed on screen in a Russian build before being touched.
  - **The app menu was a third English** — `About Dirnex`, `Services`, `Hide Dirnex`, `Hide Others`,
    hand-built `NSMenuItem`s in the first menu of the app, sitting between fully translated registry
    items. The `MenuSpec` fix from Pass 1 covered the menu *bar's* titles; these are the standard
    app-menu items AppKit does not build for us, so nothing inherited them.
  - **Two sites had a translated key sitting right there and did not use it**: the Quick View header
    read "14 of 21" while `%@ of %@` was already translated for the queue bar, and the File menu drew
    `Compare with FileMerge…` while `Compare with %@…` was already translated for the Synchronize
    sheet — the *exact* instance NOTES.md records as a lesson, written down after Slice 8 and never
    actually fixed. The de-duplication lesson has this second half: after de-duplicating the string,
    check that every site producing it goes through the lookup.
  - **`SpotlightQuery.summary` was a presentation decision in the core**, so it went to the path bar
    and tab chip as English `"Search results"` or a raw `SearchKind.title`, bypassing the join the
    Find-Files popup itself uses. Fixed the Slice 11 way — by *deleting* the words, not keying them:
    the core now answers `SummaryTerm` (`.name`/`.content`/`.kind`/`.tag`/`.generic`), keeping the
    tested precedence, and `LocalizedCatalog.summary(of:)`/`.plainName(of:)` pick the words. The
    display quotes became a `“%@”` format so Russian can answer `«%@»`.
  - **`NSAlert`'s Escape binding is English-only, which made this the first leak that changed
    *behaviour* rather than pixels** — see NOTES.md for the probe and the two live bugs it turned up.
    `enableEscapeToCancel(safe:)` now takes an `NSApplication.ModalResponse` instead of matching
    titles, and `EscapeToDismissTests` pins it with cases carrying no English word anywhere.
  - Keys added by script with the usual exact-match guard against the emitted `.stringsdata` and an
    additive-only check (6 added, 0 changed); the placeholder guard had to learn that `%1$lld` and
    `%lld` are the same argument, since positional specifiers are exactly how a translation reorders.
  - **Known and left alone:** an ad-hoc search with no term of its own draws "Results for Search
    results" — a stutter that reads identically in English and predates this slice. Fixing it means
    giving the generic search a self-naming identity the way Recents and the Trash have one; it is a
    wording decision, not a translation gap.
- **Slice 13 landed (2026-07-24): the deferred automation surface, and one real miss.** The two
  standing deferrals (App Intents, archive formats) cleared, plus a leak neither audit had named;
  **30 new `Localizable` keys and a new `AppShortcuts.xcstrings`** across 8 files. What each was:
  - **The App Intents strings were extracted all along** — every `LocalizedStringResource` literal
    sits in `AutomationIntents.stringsdata`, so the deferral was never "the compiler can't see
    these", it was 21 keys nobody had put in the catalog. Titles, descriptions, category names,
    parameter titles and the two `Summary(…)` lines all took ordinary catalog entries with no code
    change.
  - **The App Shortcut *phrases* need their own catalog**, `AppShortcuts.xcstrings`, and the
    stringsdata says so: the extractor writes them into an `AppShortcuts` table while everything else
    goes to `Localizable`. The file-system-synchronized group picked the new catalog up with no
    `project.pbxproj` edit, and both `.lproj`s compiled an `AppShortcuts.strings`. A phrase has to
    keep `${applicationName}` in every language.
  - **`"\(Scripting.noWindowMessage)"` extracted the key `%@`.** Interpolating a plain `String` into
    an intent's `LocalizedStringResource` yields a format with no sentence in it, so the message was
    invisible to extraction *and* to every catalog sweep — it looked wrapped. `noWindowMessage` is now
    a `LocalizedStringResource` declared once and resolved through `String(localized:)` on the
    AppleScript side, so both doors share one extracted key.
  - **The AppleScript error messages are now translated too**, reversing Slice 12's call. The `.sdef`
    *terminology* genuinely must stay English — a script breaks if `reveal` is renamed — but an error
    message is prose read by a human in Script Editor, and translating it breaks nothing. The verb
    names stay verbatim *inside* the sentences («Команде reveal нужен POSIX-путь, например reveal
    "/Users/me".»). Vocabulary and prose are different things; only the first is load-bearing.
  - **The archive format names took the registry treatment**, like the search filters before them:
    `LocalizationKey.archiveFormat(_:)` keyed by the case's raw value, `LocalizedCatalog.title(for:)`
    at the popup, the core's `displayName` left in place as English fallback *data*. New coverage test,
    with the same one-word carve-out the command titles use — "Zip" and "7-Zip" are product names.
    Confirmed live in a Russian build: `Zip · Tar-архив (gzip) · Tar-архив (bzip2) · 7-Zip · Tar (без
    сжатия)`, all fitting the popup.
  - **The one genuine miss: iCloud Drive's tab title and path-bar crumb** both read
    `ICloudLocation.mergedName` straight out of the core. The Trash had the answer next door and even
    said so in a comment — `pathSummary` is a stable English *identity*, the `title` is what's shown
    and localizes — and iCloud used the same constant for both. Invisible in Russian, where Apple
    keeps the product name; it would surface the first time a language transliterates it.
  - The extracted-vs-catalogued diff over every `.stringsdata` now comes back **clean**, with one
    deliberate survivor: `DisplayRepresentation(title: "\(name)")` in `DirnexOperationEntity` extracts
    `%@` because both arguments are already localized upstream. That is the shape the `noWindow` bug
    wore, so it is worth knowing which instances are legitimate.
- **Pass 2 is complete.** Every AppKit/SwiftUI literal and every registry-owned string is wrapped and
  Russian-filled across Slices 1–13, the automation surface included. One documented non-goal stays
  English: the stock Finder-tag *names* in the ⌃T menu, which are `DirnexCore` `systemTagName` data
  with the localization caveat already in `FinderTag`. The AppleScript `.sdef` terminology stays
  English by design — it is a scripting vocabulary, not prose. Next is Pass 3 — the additional
  languages.

**Pass 3 — the additional languages. Parked (2026-07-25), not cancelled.** Adding one is a line in
`AppLanguages.all` plus its column in the catalog; `LocalizationCoverageTests` fails until the column
is complete. It is parked behind M13 deliberately: the machinery is proven by a real language, so
the remaining languages are a translation exercise with no design risk left in them, and every
string M13 adds would have to be translated twice if the languages landed first. **That gate is now clear — M13
shipped (2026-07-25) with its 23 strings settled in English + Russian** — so Pass 3 is unblocked
whenever it is picked back up.

- **Slice 1 landed (2026-07-26): French.** `fr` / `Français` is now a shipped language, listed in
  Settings and matched from French regional tags such as `fr-CA`. Its complete `Localizable`
  column (786 entries, including every plural variant) and both App Shortcut phrases are present in
  the built `fr.lproj`. The function bar and command-category captions received a manual UI pass so
  they use correct whole verbs and nouns. The Synchronize sheet keeps the three complete direction
  labels on their own row, sizing each segment to its localized caption so no language is cut off.
  `LocalizationCoverageTests` now checks French alongside Russian; the app bundle test confirms it
  is compiled and all registry data is translated.
- **Slice 2 landed (2026-07-26): Spanish.** `es` / `Español` is a shipped language, listed in
  Settings and matched from Spanish regional tags. Its complete `Localizable` column (786 entries,
  including every plural variant) and both App Shortcut phrases are present in the catalog, so
  `LocalizationCoverageTests` checks Spanish alongside French and Russian. A manual macOS-style pass
  kept the Spain-style platform vocabulary (`función rápida`, `ítem`, `por omisión`, `Ajustes del
  Sistema`) and aligned Finder/AppKit terms where they matter: `Conectarse a un servidor…`,
  `Ocultar otras apps`, and lowercase `papelera` in actions and prose while standalone sidebar/title
  labels remain `Papelera`. The diff-tool footer also now says it opens files in the selected app,
  not in Dirnex itself, and the palette tour title was rewritten as natural Spanish rather than a
  literal English calque.
- **Slice 3 landed (2026-07-27): German.** `de` / `Deutsch` is a shipped language, listed in
  Settings and matched from German regional tags such as `de-AT`. Its complete `Localizable` column
  (799 entries, including every plural variant) and both App Shortcut phrases are present in the
  catalog and compiled into `de.lproj`, so `LocalizationCoverageTests` now checks German alongside
  Spanish, French and Russian. A manual macOS-style pass kept product and platform terms unchanged
  where they should stay unchanged (`Dirnex`, `macOS`, `Git`, `Zip`, `7-Zip`) and corrected the
  file-manager vocabulary the automatic pass got wrong: `Papierkorb`, `Datei`, `Ordner`,
  `Laufwerke`, `Befehl`, `Kopieren`, and `Verschieben`. The same pass preserved existing casing
  rules for lowercase keyword/search terms and kept the function bar on whole German verbs.
- **Slice 4 landed (2026-07-28): Portuguese (Brazil).** `pt-BR` / `Português (Brasil)` is a
  shipped language, listed in Settings and matched from Brazilian Portuguese regional tags. Its
  complete `Localizable` column (803 entries, including every plural variant) and both App Shortcut
  phrases are present in the catalog and compiled into `pt-BR.lproj`, so
  `LocalizationCoverageTests` now checks Portuguese alongside German, Spanish, French and Russian.
  The manual macOS-style pass kept names and common technical terms unchanged (`Dirnex`, `Apple`,
  `macOS`, `Git`, `Zip`, `7-Zip`) and used natural Brazilian Portuguese for app UI (`Ajustes`,
  `Lixo`, `arquivo`, `pasta`, `etiqueta`) while preserving the same casing pattern as the existing
  languages. The function bar keeps whole Portuguese verbs.
- **Slice 5 landed (2026-07-28): Simplified Chinese.** `zh-Hans` / `简体中文` is a shipped language,
  listed in Settings and matched from Simplified Chinese regional tags such as `zh-CN` and `zh-SG`.
  Its complete `Localizable` column (803 entries, including every plural variant) and both App Shortcut
  phrases are present in the catalog and compiled into `zh-Hans.lproj`. A manual macOS-style pass
  kept product names unchanged (`Dirnex`, `Finder`, `iCloud Drive`, `Git`, `Zip`, `7-Zip`) and used
  platform wording such as `设置`, `废纸篓`, `完全磁盘访问权限`, `快速查看`, `边栏`, `宗卷`, `标签`,
  `拷贝`, `移动`, and `重新命名`. The function bar keeps whole Chinese command verbs.
- **Slice 6 landed (2026-07-28): Japanese.** `ja` / `日本語` is now a shipped language, listed in
  Settings and matched from Japanese regional tags. Its complete `Localizable` column (803 entries,
  including every plural variant) and both App Shortcut phrases are present in the catalog and
  compile into `ja.lproj`. The manual macOS-style pass kept product names unchanged (`Dirnex`,
  `Finder`, `iCloud Drive`, `Git`, `Zip`, `7-Zip`) and used platform wording such as `設定`,
  `ゴミ箱`, `フルディスクアクセス`, `クイックルック`, `サイドバー`, `ボリューム`, `タグ`,
  `コピー`, `移動`, and `名前を変更`. The function bar keeps whole Japanese command verbs.
- **Slice 7 landed (2026-07-29): Traditional Chinese.** `zh-Hant` / `繁體中文` is now a shipped
  language, listed in Settings and matched from Traditional Chinese regional tags such as `zh-TW`,
  `zh-HK`, and `zh-MO`; `zh-CN` and `zh-SG` still resolve to Simplified Chinese. Its complete
  `Localizable` column (803 entries, including every plural variant) and both App Shortcut phrases
  are present in the catalog and compile into `zh-Hant.lproj`. The manual macOS-style pass kept
  product names unchanged (`Dirnex`, `Finder`, `iCloud Drive`, `Git`, `Zip`, `7-Zip`) and used
  natural Traditional Chinese macOS wording such as `設定`, `垃圾桶`, `完整磁碟取用權限`, `側邊欄`,
  `卷宗`, `標籤`, `拷貝`, `移動`, and `重新命名`. The function bar keeps whole Chinese command verbs.

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
conventionally English and translating it breaks users' scripts. That covers the verb *names* only —
the error messages those verbs report are prose and were translated in Slice 13, keeping the verb
names verbatim inside the sentences. App Intents titles, descriptions and phrases landed there too.

### Next: M14 — Checksums and attributes (planned 2026-07-29)

Two features that have nothing to do with each other except that both are byte-touching and
both are things a Total Commander user reaches for and currently cannot: **compute and verify
checksum files**, and **see and change a file's attributes**. Core-first per §2, in five slices.

**Split/combine was considered and dropped (2026-07-29).** Every reason it exists is gone —
FAT32's 4 GB ceiling, floppy and CD spanning, mail attachment limits — and on macOS the answer
to "this file is too big" is a split archive or a link. It is also the *cheapest* of the three
to build (a chunked read/write loop, which `LocalBackend+Copy` already is), which is exactly why
it should not be built on cheapness alone: it would cost two permanent command slots and eight
languages to serve a problem nobody on this platform has. Revisit only on a real request, and if
it comes, it rides on Slice 1's digests — TC writes a `.crc` companion beside the parts and
verifies it on combine, so the checksum work is its missing half.

#### What was probed first (2026-07-29)

Both halves rest on measurements, not on recollection — §"Working rhythm". Three of the results
changed the design.

**Hash throughput**, 256 MiB of `/dev/urandom`, warm cache, `swift -O`, Apple Silicon:

| Algorithm | Throughput | Note |
|---|---|---|
| `Insecure.SHA1` | 2335 MiB/s | hardware instruction |
| `SHA256` | 2096–2310 MiB/s | hardware instruction |
| `Insecure.MD5` | 790 MiB/s | software — **3× slower than SHA-256** |
| CRC32, byte-at-a-time table | 534 MiB/s | software — **the slowest of the four** |

**The intuition that picks CRC32 or MD5 "because they're cheap" is inverted on this hardware.**
SHA-1 and SHA-256 are ARMv8 crypto instructions; MD5 and CRC32 are ordinary code. So SHA-256 is
the honest *default* — it is both the strongest and among the fastest, and the legacy three are
carried for **interop** (matching a checksum someone else published), never for speed. Chunk size
is irrelevant between 64 KiB and 4 MiB (measured within noise), so `ByteComparator`'s existing
128 KiB stands with no tuning. Computing all four in one pass costs ~247 MiB/s combined, which
makes "compute everything while the bytes are in hand" affordable and avoids ever re-reading a
file to add a second algorithm.

**Unprivileged attribute changes**, uid 501, on this Mac:

| Change | Own file | Someone else's |
|---|---|---|
| `chmod` mode bits | OK | EPERM |
| `chflags UF_IMMUTABLE` (Finder's "Locked") | OK | EPERM |
| `chflags UF_HIDDEN` | OK | EPERM |
| `chflags SF_IMMUTABLE` and the other `SF_*` | **EPERM** | EPERM |
| `chown` to another user | **EPERM** | EPERM |
| `chgrp` to a group I belong to | OK | EPERM |
| `chgrp` to a group I do not belong to | **EPERM** | EPERM |
| `utimes`, and `.creationDate` via `FileManager` | OK | EPERM |
| ACL read (`acl_get_file` → `acl_to_text`) | OK | OK |
| ACL write (`acl_set_file`) | OK | EPERM |
| `setxattr` / `removexattr` | OK | EPERM |

**So "the full version" is an ordinary in-app panel, unprivileged, for every file the user owns —
which is nearly everything a file manager touches.** Root is needed for exactly three things:
another user's files, `chown` across users, and the `SF_*` system flags. That is the finding that
decides the escalation design (Slice 5): escalation is a narrow exception, not the general path,
and building the panel around a privileged helper would have been building the whole feature
around its rarest case.

Two gotchas found in the same run, both destined for NOTES.md:

- **`chmod` fails with EPERM while `UF_IMMUTABLE` is set.** A panel that shows "Locked" and the
  mode bits together must clear the flag, apply the mode, then re-apply the flag — in that order.
  Without it, a user editing permissions on a locked file gets "Operation not permitted", which
  reads *exactly* like "you need to be root" and would send the whole design down an unnecessary
  privilege-escalation path. The failure is indistinguishable from the one case that genuinely
  needs root, which is what makes it expensive.
- **`chmod()` follows symlinks; `lchmod()` exists and does not.** Verified: `chmod` through a link
  changed the target (0600) and left the link (0755). The panel has to decide link-vs-target and
  say which it did. Recommendation: act on the link (`lchmod`/`lchflags`/`lutimes`), as Finder's
  Get Info does.

**ACLs from Swift** — the open question of whether "full" can include them. It can, mostly:

- The C API (`acl_get_file`, `acl_to_text`, `acl_from_text`, `acl_set_file`, `acl_get_entry`,
  `acl_free`) **imports and links from Swift with no module map and no bridging header**. Probed,
  not assumed — this is what makes ACLs affordable at all, and it is the opposite of §M4's
  libarchive result.
- `acl_get_file` returns `nil` with `errno == ENOENT` to mean *"this file has no ACL"*. That is a
  normal answer, not an error.
- The canonical text is `!#acl 1\nuser:<UUID>:<name>:<uid>:allow:read,write,delete`.
  `acl_to_text` resolves the name for you, and `acl_from_text` round-trips its own output.
- **But `acl_from_text` rejects the friendly form `chmod +a` accepts** (`user:oleg allow read` →
  EINVAL), because the canonical form embeds the GUID. Adding an entry for a user picked in the UI
  therefore needs `mbr_uid_to_uuid`, which is **present in libSystem** but declared in
  `membership.h`, outside the Darwin module map — so it needs a small module map or a `dlsym`
  declaration. Reading and removing need none of that; full editing is in scope (decided
  2026-07-29), so the declaration is Slice 3's.
- **Adding an ACL does not change the mode bits** (verified: still 0644 with an ACL present),
  which is precisely why a panel that shows mode alone makes a false claim about a file's
  permissions on exactly the files where it matters.
- **The rights are not one set — they depend on the item's kind**, taken from `chmod(1)` rather
  than from memory: 8 apply to everything (`delete · readattr · writeattr · readextattr ·
  writeextattr · readsecurity · writesecurity · chown`), 4 only to non-directories (`read ·
  write · append · execute`), 5 only to directories (`list · search · add_file ·
  add_subdirectory · delete_child`), and 4 inheritance flags only to directories (`file_inherit ·
  directory_inherit · limit_inherit · only_inherit`). **12 checkboxes for a file, 17 for a
  directory** — so the editor's matrix switches on kind, and a mixed multi-selection cannot
  present one matrix at all. That constraint has to shape the panel from the start, not be
  discovered when the first folder is selected.
- **Entries are ordered and evaluated in order, and the order is editable** (`chmod +a#` inserts
  at an index, `chmod -C` tests for canonical order). A deny placed after an allow means something
  different from the same pair reversed, so the editor presents a *list*, not a set, and must not
  silently reorder. **Inherited entries are their own class** with an "inherited" bit (`chmod -i`
  / `-I`) and must be shown as inherited and not casually edited in place.

**One last finding, and it kills a badge before it gets built:** `ls -l`'s trailing marker is
useless on modern macOS. `@` (extended attributes) and `+` (ACL) share one column and `@` wins, so
a file with an ACL shows `@` and never `+` — and it is moot anyway, because
**`com.apple.provenance` is present on essentially every file on this Mac** (verified across the
repo, `~`, and freshly created files; `xattr -c` does not keep it away). So "this file has
extended attributes" carries no information and must not become a row badge or a panel line — it
would light up on everything. The xattrs worth surfacing are named ones the user acts on
(`com.apple.quarantine` above all), with `com.apple.provenance` filtered out. NOTES.md already
half-knew this from the Trash work ("a trashed file's only xattr is `com.apple.provenance`"); the
general form is that it is on everything, not just trashed items.

**Checksum file formats**, captured from the real tools rather than remembered. macOS 26 ships
more than expected — `/sbin/md5sum`, `/sbin/sha1sum` and `/sbin/sha256sum` all exist (hardlinks of
one binary) alongside BSD `md5`, `shasum`, `openssl` and a Perl `/usr/bin/crc32`:

| Producer | Line |
|---|---|
| `shasum`, `md5sum` (GNU) | `<hex>␣␣<name>` |
| `shasum -b` (GNU binary) | `<hex>␣*<name>` |
| BSD `md5` | `MD5 (<name>) = <hex>` |
| `openssl dgst` | `SHA256(<name>)= <hex>` |
| `md5 -r` | `<hex>␣<name>` |
| `crc32`, `.sfv` | bare `<hex>`, and `<name>␣<hex>` with `;` comments |

**Apple's own tools cannot read each other**: `shasum -c` refuses the `openssl`/BSD form outright
("no properly formatted SHA checksum lines found"). So a tolerant parser is not gold-plating, it
is the actual user-facing advantage over the stock tools — Dirnex reads all six and writes GNU
style (now natively produced on macOS too), with `.sfv` for CRC32.

#### Slice 1 — checksum core (additive, app untouched)

- `ChecksumAlgorithm` — `crc32 · md5 · sha1 · sha256`, carrying display name, digest width and
  canonical file extension as data. SHA-256 is the default; the other three are labelled as
  interop formats and the UI must never imply MD5 or SHA-1 is a security property.
- `CRC32` — table-driven, with the published vector as its first test (`"123456789"` →
  `0xCBF43926`, already confirmed in the probe). No zlib dependency for one function. If its
  534 MiB/s ever matters, slice-by-8 or the ARMv8 `CRC32*` instructions are the escalation, but
  simple wins until measured otherwise.
- `ChecksumEngine` — `ByteComparator`'s shape exactly: chunked at 128 KiB, never a whole file in
  memory, cancellation polled between chunks, progress reported by the caller's callback, and the
  caller decides where it runs. Computes **N algorithms in one pass**.
- `ChecksumManifest` — parse and serialize. Parsing accepts all six forms above; serializing
  writes GNU style, or `.sfv` for CRC32. Round-trip tests per form, plus the awkward real cases:
  names with spaces, a BOM, CRLF, `;` comments, a missing trailing newline, and a mixed-algorithm
  file (refused, with the reason named).
- `ChecksumVerification` — pure: manifest × directory listing → per-entry `ok / mismatch /
  missing / unreadable / extra`. "Extra" matters — a manifest that omits a file is a different
  answer from one that fails it.

#### Slice 2 — checksum app

- Two commands, `file.checksumCreate` and `file.checksumVerify`. `Command.id` is a translation key
  and renaming one orphans its translations, so these names are final.
- **Verify is the primary half.** Most people never author a checksum file; they download one next
  to an ISO and want to know whether the bytes survived. The results surface is a per-entry
  pass/fail list, and the nearest existing shape is the Synchronize Directories diff table.
- Runs on `FileOperationQueue`, which means extending `FileOperation.Kind` beyond `.copy`/`.move`
  for the first time — plus its `QueueSnapshot` status strings and their translations. A 50 GB
  file is ~25 s of SHA-256 and ~100 s of CRC32, so progress and cancel are not optional; a modal
  sheet over that is the thing §1 forbids.
- **The dataless gate is mandatory.** NOTES.md: reading one byte of an evicted iCloud or streaming
  Drive file materializes it and blocks. `FileEntry.isDataless` already arrives on the `stat` the
  listing performs, so a "checksum this folder" that would silently download the user's cloud
  drive is preventable for free — and must say what it is about to do rather than start.
- **Remote backends have no server-side hashing.** Neither `sftp` nor `curl` can hash on the
  server, so a checksum over SFTP/FTP is a full download. Genuinely useful (M13 shipped with no
  way to confirm an upload arrived intact) but it has to be stated, not discovered.

#### Slice 3 — attributes core (additive, app untouched)

- `FileEntry` gains `ownerID`, `groupID` and `flags`. **This is free at the syscall level** — the
  listing already `stat`s and already reads `st_flags` for `isHidden` and `isDataless`; the values
  are in hand and thrown away. Five construction sites across the backends, and the compiler finds
  all of them.
- `FileAttributes` — the value type the panel edits: mode bits, BSD flags, owner/group, the three
  timestamps. Pure, `Equatable`, and diffable against what was read, so the applier changes only
  what the user actually touched.
- `AttributeChangePlan` — the *ordered* syscall sequence for a diff, which is where the immutable
  gotcha is encoded once and tested: unlock → apply → relock. Tests pin the ordering directly,
  because the bug it prevents is invisible in any dialog screenshot.
- `AccessControlList` — the full editable model (decided 2026-07-29): an **ordered list** of
  entries, each carrying subject (user or group, with its GUID), allow/deny, the kind-appropriate
  rights set, and whether it is inherited. Read via `acl_to_text` (which resolves names for
  free), written via `acl_from_text` on the canonical form, with `mbr_uid_to_uuid` declared for
  the subject picker. Order is preserved exactly — never silently canonicalized — and inherited
  entries are marked as such. The parse/serialize pair is the testable core; a captured real ACL
  from a real file is the fixture, per §"Working rhythm".
- The **rights set is a function of item kind** (12 for a file, 17 for a directory), so it is
  modelled as such rather than as one flat option set — the compiler then prevents offering
  `add_subdirectory` on a file.
- `AttributePrivilege` — pure, from the probed matrix: given an entry's owner and the requested
  diff, does this need root? It is what greys the panel and decides whether Slice 5 is reachable
  at all, and it is a table, so it is a test.

#### Slice 4 — attributes app

- A Get Info-style panel. Dirnex currently cannot answer "what are this file's permissions?" at
  all, so the *visibility* is most of the value — `FileEntry.permissions` has been read on every
  listing since M1 and displayed nowhere.
- Multi-selection applies a diff, not a value, so a mixed field stays mixed unless touched.
- **The ACL editor is a list, not a checkbox grid**: entries in evaluation order, add / remove /
  reorder, allow-vs-deny per entry, inherited entries visibly distinct and not casually edited,
  and the rights matrix switching between the 12-right file form and the 17-right directory form.
  A mixed file+directory selection cannot show one matrix, so it offers the 8 common rights or
  nothing — decided up front rather than found later.
- The subject picker resolves a user or group to its GUID through `mbr_uid_to_uuid`. macOS spells
  ACL subjects by GUID, so the picker is the only place a name is turned into an identity, and
  it is worth one place.
- Extended attributes are listed with `com.apple.provenance` filtered out (it is on everything);
  `com.apple.quarantine` is the one worth acting on, and removing it is the case a user actually
  has — NOTES.md already records that `xattr -dr` is the form that exits 0.
- Recursive apply is a queued, cancellable operation and lands **after** the flat case. It is the
  one shape here that can wreck a tree, and undo needs the prior mode/flags/ACL journaled per path.
- Undo: a new `UndoActionLabel` case (the enum is closed, so this is a compile error until it is
  added — as designed in M12 Slice 10) plus its translation key.
- Lives in `PanelViewController+Attributes.swift`; the controller is at the lint ceiling. The ACL
  editor is its own controller from the start — on the M12 Slice 8 evidence that a panel this
  dense arrives at all three SwiftLint ceilings at once, and on the §"Lint ceilings" rule that a
  type at the ceiling splits by *concept*.

#### Slice 5 — the narrow privileged case

Only for what the matrix says needs root: another user's file, `chown` across users, `SF_*`.
Three options were weighed:

1. **`SMAppService` privileged daemon + XPC** — Apple's modern answer, and the wrong one *here*:
   it requires a Team-ID-signed bundle, so per NOTES.md's App Intents lesson every local build
   would be unable to run it and every local verification would be blind. A high price for the
   rarest case in the feature.
2. **`osascript` → `do shell script … with administrator privileges`** — the standard system
   authorization dialog, runs as root, stays in the app, needs no entitlement and works under
   ad-hoc signing. Not sandbox-legal, which §2 already settled by not sandboxing.
3. **Terminal handoff** — a pre-filled command line the user runs themselves.

**Decided 2026-07-29 (Oleg): (2) as the in-app path, with (3) always present beside it as a
read-only "or run it yourself" field.** (3) is nearly free, is the honest escape hatch for a user
who would rather not hand an app their admin password, and is the safest half to build first —
so it ships first and (2) is layered on. Note that `ExternalTerminal.invocation` opens a terminal
*at a directory* via `open -a` and types nothing, so delivering a pre-filled command line is new
machinery (Terminal.app's AppleScript `do script`); the existing launcher does not cover it.

Two constraints on (2) that follow from the probe rather than from taste. The escalation is
offered **only** where `AttributePrivilege` says root is actually required — never as a blanket
"try again as admin", because the matrix shows that is the rare case and a panel that reaches for
authentication by default trains the user to approve it. And the immutable-flag gotcha must be
fixed *before* this slice, not worked around by it: an EPERM from a locked file is
indistinguishable from an EPERM that needs root, so shipping (2) first would paper over the bug
with a password prompt the user never needed.

**Both (2) and (3) build a shell command out of file paths, which is an injection surface, not a
formatting concern** — the same lesson as FTP's `-Q` and the Google `doc_id`. The command is
composed in the core through the existing `ShellQuoting`, tested against names with quotes,
spaces, newlines and leading dashes, and never interpolated at the call site.

#### Exit criteria

- A checksum file written by Dirnex verifies with `shasum -c`, and files written by `shasum`,
  `md5`, `openssl` and an `.sfv` tool all verify in Dirnex — the interop claim tested in both
  directions, against the real tools.
- Verifying a folder containing an evicted iCloud file does not download it without saying so.
- The attributes panel round-trips against the OS as the independent judge: set it in Dirnex,
  read it back with `ls -le@` and `stat -f`, and set it with `chmod`/`chflags` and see the panel
  agree.
- Changing permissions on a **locked** file works, in one gesture, with no root prompt.
- A file carrying an ACL never displays its mode bits without saying an ACL is present.
- An ACL authored in Dirnex reads back correctly under `ls -le` **in the order Dirnex showed**,
  and an ACL authored with `chmod +a` / `+a#` displays in Dirnex in the same order — the OS as
  the independent judge in both directions, entry order included, since order is meaning here.
- The root-only cases are reachable two ways and neither is the default: the authenticate path
  and the copyable command produce the same result on the same file.

**Localization:** M12's rhythm is to fill Russian in the same slice rather than accumulate
English-only surface, and M14 assumes that — each slice ships its own catalog keys.
`LocalizationCoverageTests` fails on an untranslated command, so this is enforced, not intended.

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
