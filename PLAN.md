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

### Shipped: M0 → M22 (2026-07-05 → 2026-08-19)

Every milestone is closed. The checklists and the full per-pass progress log — what was probed,
decided, and rejected — live in **[docs/HISTORY.md](docs/HISTORY.md)**; source comments citing
`PLAN.md §M5` and the like refer to those sections.

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
| M20 | Every place reachable without the sidebar | 08-12 | Individual places as ⌘K palette results (the palette is a registry of *commands*, places are live data — a different mechanism, worth its own decision); reordering or editing places from the menu, which stays the sidebar's job; a Finder-style "Computer" or "Network" destination, which is not a place Dirnex has; and a **Help menu** — Slice 2 claimed Help ▸ Search made "Trash" findable and the app declares no Help menu at all, so adding one is its own decision and was not taken |
| M21 | Amazon S3, and the mounts we already reach | 08-19 | **Atomicity of any kind** — a prefix rename or delete is N copies and N deletes, so stopping partway leaves items under both names, and no layer can make it otherwise; **a byte counter during a server-side copy**, which would cost a round trip per object (~25 min of pure latency on a 50 000-file prefix), so those jobs report items; **`copyMetadata` and `DirectorySync` by timestamp**, since S3 has no settable mtime, no permissions and no symlinks; **a File Provider mount** (Mountain Duck / `rclone mount` territory — a different product with a different lifecycle); **AES-style client-side encryption, versioning, lifecycle rules and storage-class changes**, none of which a file manager's ten verbs have a place for; **the 200-committed multipart refusal seen from Amazon**, which AWS documents and answers `412` with the code in practice, so it stays pinned against our own SigV4-verifying endpoint; and **`..` / Go Up watched by a person on a real SFTP or FTP server** — verified live on S3, and by test on the other two, which share the one predicate |
| M22 | Find Files on a connected server | 08-16 | **Content-grep and tags remotely** — no remote backend can answer either without reading every file, so `SearchFields` withholds them rather than skipping the clause (which would return *more* results under the same name); **an exact remote timestamp**, since FTP's `LIST` stamps are year- and zone-less on the server's clock; **searching an S3 *account* pane**, whose rows are buckets — "search every bucket" is a different and much more expensive question than the one ⌥F7 asks; and GNU `find -printf`, retired at the probe rather than handled, since choosing it would have shipped the common case unverified — POSIX `find … -exec ls -ldn {} +` instead, at the cost of the date column |

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

### After M19

M19 closed on 2026-08-09; M20 opened and closed 2026-08-12 (HISTORY.md). Three things landed
between M19 and M18, which closed on 2026-08-07, and five after it.

**2026-08-20 — ⎋ and ⏎ on the app's dialogs, which were dead on different alerts for different
reasons.** Reported as both keys "sometimes" doing nothing but beep. Two independent defects, each
invisible to the tests that covered the other key. **Escape** was dead on all three progress sheets
(remote download, iCloud download, search): `enableEscapeToCancel` served a lone-button alert by
installing its catcher in the `accessoryView` slot, which is a **no-op in both call orders** once the
alert has a real accessory — `accessoryView == nil` fails when the accessory is set first, and the
caller's own assignment throws the catcher away when it is set second. **Return** was dead on the SSH
host-key prompt, both FTPS certificate prompts and Full Disk Access's already-granted notice: where
the safe choice occupies the default (first-added, rightmost) slot, AppKit withholds
`defaultButtonCell` outright, so Return *and* keypad Enter fall through to the beep — measured, and
the control with `enableEscapeToCancel` removed behaves identically, so it is AppKit's doing rather
than ours. The helper now decides by what else answers Return: while another button is the default,
Escape rides the safe button (the ordinary `Delete[⏎] Cancel[⎋]` confirmation, unchanged); otherwise
the safe button keeps Return and Escape rides an `EscapeDismissingView` installed in the alert
window's own `contentView`, which is what makes the whole thing independent of call order. Note the
deliberate consequence on the four trust prompts: **⏎ now answers Cancel**, which is what putting
Cancel in the default slot always meant. `scripts/check_alert_escape.py` had reported "all 70 NSAlert
sites call `enableEscapeToCancel()`" throughout — true, and no evidence at all, since it could only
see the call and not the binding; it now also fails on a call that runs before the last `addButton`
(verified against a synthetic violation), and the binding itself is pinned by
`EscapeToDismissTests.everyShapeAnswersBothKeys`, which asserts the **pair** on every shape the app
builds and fails with 18 issues when reverted, naming both halves. Four other mechanisms were probed
and cleared before the binding was suspected — the Quick View key monitor (the parent window reports
`isKeyWindow == false` while a sheet is up, so it already bows out), `focusTable()`'s
`makeFirstResponder` on the parent, a sheet raised under an app-modal window, and sheet stacking,
which on macOS 26 **no longer queues invisibly** (docs/NOTES.md corrected).

**2026-08-19 — the download dialog's Download button, and the dialog on top of the card.** ⌃Q on a
14,5 MB object raised the size confirmation, and pressing **Download** closed it and did nothing:
`RemoteFetchPrompt.confirm` handed its completion `[weak self]` on an object nobody else retained —
`fetch` builds it in a local, `beginSheetModal` returns at once, and the alert retains the *closure*
— so the answer arrived at a deallocated prompt. Nothing logged, and the sibling path was fine for
the reason that hid it: `start()` launches a `Task`, which captures `self` strongly, so the same
click worked wherever no question was asked. The second half is what the fix made possible. A remote
transfer had two reporters — the placeholder card that is already standing where the preview will
be, naming the file and carrying a determinate bar and Stop, and `RemoteFetchPrompt`'s deferred
*modal* sheet, which went up over it after 1200 ms and took the keyboard off the file list to say the
same thing. The card now draws every preview download: an explicit fetch registers its counter and
its cancel flag with `RemoteFileCache` (`beginExplicitFetch`) exactly as the cursor-following one
does, `previewFetchState`/`previewFetchProgress` answer for either kind, Stop reaches either, and the
sheet stands down wherever a card is on screen — ⌘Y with Quick View off, ⏎ and F4 keep it, since
there the sheet is the only thing that can report anything. Two smaller pieces fell out: an explicit
fetch needed an `onStart` hook, because a confirmed one begins when the user answers rather than when
the caller returned, and the card was drawn before the question was asked; and `scheduleAutomaticFetch`
now stands aside for a row an explicit fetch holds, or the redraw the Download button causes issues a
second transfer of the same object (measured — the control fails at `copyCount == 2`). Pinned by
seven tests driving a real `NSAlert` sheet on a real window, each fix's negative control failing in
the reported shape: reverting the capture leaves `copyCount == 0` after a genuine click on the
dialog's own default button. docs/NOTES.md ▸ AppKit, ▸ Design lessons.

**2026-08-20 — the same fix, on the exit that actually happens.** The queue-bar half of the
2026-08-19 fix worked; the Quick View card's half was inert, and the user re-reported the identical
symptom on a preview download. Two things were wrong with it, and each is invisible on its own. The
reset was keyed on `apply(_:)`'s non-downloading branch — which covers a transfer that stopped or
failed, while the **ordinary** end of one hides the card outright (the bytes landed, so the surface
shows the file) and applies no state at all. And the claim it was tested against was about the model
rather than the screen: `startPolling` has always zeroed `doubleValue` in the same turn it unhides
the bar, so the model reads 0 throughout while the fill *layer* still carries the last download's
presentation. Sampling that layer at 10 ms in the running app against the real bucket, driving the
user's own sequence: **0.96 at the reveal, empty 11 ms later**, with the model reading `0.00` at
every sample. Emptying the bar in the stand-down funnel (`QuickViewPlaceholderCard.standDown`) plus
the state branch covers both exits; re-measured live it opens at 0.02. The test now takes the exit as
its argument, because a single-exit test passes against the half-fix — reverted to it, the `.stopped`
case is green and the show-a-file case fails at 1.0. docs/NOTES.md ▸ AppKit.

**2026-08-19 — a progress bar no longer opens on the last run's fill.** Both places a bar is hidden
between runs kept the value they were last drawn with, so the *next* run revealed the previous one's
fill before its own first number arrived: the queue bar (the window controller's idle branch hid it
without drawing anything) and Quick View's placeholder card (its bar is hidden except while
downloading). Reported by a user as a bar that "starts at 100 %, drops to zero, and only then runs",
on a copy and on ⌃Q alike. The obvious cause is the wrong one and the queue's own doc comment
predicts it — the aggregate rolls up finished jobs, and `clearFinished` is dispatched in a `Task` —
but instrumenting `update(with:)` in the running app showed every fraction correct, the new batch's
first included, with the only wrong number the one already on the bar. So the fix is to reset when
the work *ends*, while the bar is off screen: an idle snapshot now goes through `update(with:)` like
any other and empties it (`QueueBarView.reset`), which also clears the coalescer's memo — otherwise a
copy started within a second of the last one opens on the previous batch's byte count and holds it.
Measured before and after by sampling the indicator's **presentation** layer at 4 ms inside the app
(its model snaps, so a `cacheDisplay` bitmap would have cleared the code): the second copy read
`1.00` at the first sample and now reads empty from the first. Four tests, with each half reverted as
its own negative control — the queue bar's reproduces the report verbatim, `progressFraction → 1.0`
over a stale `"400 bytes of 400 bytes"` — and the three coalescing tests green throughout as the
narrowness control. `QueueBarView` crossed the 500-line ceiling doing it, so the readout and its
coalescing rule moved into `QueueBarView+Detail` beside the wording split that was already there.
docs/NOTES.md ▸ AppKit.

**2026-08-19 — a bucket row expands in a tree.** Tree mode stopped being local-only on 08-17, which
gave every bucket row in an S3 account pane a disclosure triangle — opening into nothing.
`S3AccountBackend` answers for its root and nothing deeper by design (everything below a bucket is
the `S3Backend` that shipped five slices earlier), so the tree's lazy load threw `notFound` into its
own `try?`: expanded, childless, silent, with nothing logged and both suites green. Reported from a
screenshot the day M21 closed. A bucket's contents are a **connect**, not a listing, so `→` now goes
through the funnel Enter uses — `connectS3` split into `establishS3Connection` (probe, self-correct,
register) and the navigation that had been welded to it, so the region-301 correction and the
path-style retry reach an expansion for exactly the reasons they reach Enter, rather than in a second
spelling. The rows it installs keep their own `s3://` paths, which is what makes everything below
them free: `TreeProjection` recurses into each entry's *own* path and never assumes a row descends
from the tree's root, so deeper expansion, F5, ⌃Q and F8 route to the backend that owns the bytes
with no new code, and the core needed no change at all. Two things the crossing changed underneath —
`←` climbed by `entry.path.parent`, which is no answer where the child is on another backend, so it
now walks the rows by depth; and a failed expansion names the row on the status line rather than
raising an alert on a key that comes in runs, leaving the sentence to Enter, which is the gesture
that asked for that bucket outright. What it deliberately does not buy is expansion surviving a
relaunch: a persisted expansion is anchored under the tab's root and a restored account pane has no
live connection to list its own root with. Verified live against the real AWS account through the
app's own controller, with the reverted version failing that same test in the reported shape —
expanded set holding the bucket, listings holding only the root. docs/NOTES.md ▸ Design lessons.

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
