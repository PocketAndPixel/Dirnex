# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: M0–M23 shipped (14 languages) · **M24–M25 planned** · Created: 2026-07-05 ·
Log: [docs/HISTORY.md](docs/HISTORY.md) · What works where:
[docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md)

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

### Shipped: M0 → M23 (2026-07-05 → 2026-08-26)

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
| M11 | F4 Edit, and Quick View at full size | 07-22 (text preview 07-27) | A built-in text editor (F4 hands the file to the user's own); write-back for archive and SFTP files — **both since shipped**, archives 2026-08-09 and SFTP with M21 Slice 10; a slideshow timer or thumbnail filmstrip in the preview |
| M12 | Localization — 14 languages | 07-29 | The stock Finder-tag *names* in the ⌃T menu (`DirnexCore` `systemTagName` data); the AppleScript `.sdef` *terminology*, since renaming a verb breaks users' scripts (its error messages did translate); a lint rule keeping bare literals out of UI files (the repeated sweeps stand in for it); the "Results for Search results" stutter, a wording decision rather than a translation gap; RTL — none in the shipped set |
| M13 | FTP and FTPS | 07-25 | `MLSD` (`curl` cannot send it); FTP-side `DirectorySync` by timestamp (unreliable by construction — LIST stamps are year- and zone-less); write-back for files edited in place over FTP — **since shipped** with M21 Slice 10, which generalized the remote edit path to every backend that accepts uploads; an opportunistic "TLS optional" client mode (a password-downgrade vector — rejected 2026-07-26) |
| M14 | Checksums and attributes | 07-30 (escalation 08-02) | Split/combine files (dropped 2026-07-29 — FAT32's ceiling, floppy/CD spanning and mail limits are all gone on macOS); multi-selection and recursive **privilege escalation** (the flat single-item path proves the mechanism; those sheets refuse a root-only change by name); escalating the *undo* of a non-owned change (still refused with `attributeRestoreNeedsAdministrator`, not escalated) |
| M15 | The tree view, and color the user chooses | 08-02 | The **thumbnail grid, brief view and the `PaneSurface` extraction** (cut 2026-08-02 — the three are one unit, and `FileTableView` is a 25-method contract a grid satisfies none of); a memo in front of `fnmatch` (measured unnecessary — 0.46 ms per full reload for 5 rules); size bars in tree mode, withdrawn at close and re-scoped per parent directory in a follow-up (`SizeVisualization(tree:)`) |
| M16 | Quick View: source or page | 08-06 | Markdown and RTF as dual-style types — markdown was taken up at M18, RTF stays undone — and `.webarchive` / `.mhtml`, which need `loadData` rather than a file load; the JavaScript mark in the *pane*-size preview, which has no header to carry it |
| M17 | Syntax highlighting in Quick View | 08-06 | A **theme picker** (the colors are a fixed light/dark table, no Settings surface); the constructs a regex-free single pass cannot reach — string interpolation, JS regex literals, heredocs, Swift raw strings, JSX, and semantic coloring of any kind; **line numbers, folding and a minimap**, which are editor features Dirnex hands to the user's own editor; highlighting inside the *rendered* HTML style, which is the page's own business; a **key-vs-value** distinction in JSON, and Markdown's **setext headings** and **indented code blocks**, all three of which need a lookahead or a previous line the single pass does not keep; Ruby's `=begin` block comment; and any third-party highlighter — Highlightr (a JS engine on every cursor step) and tree-sitter (a C dependency plus a grammar per language), both rejected 2026-08-06 |
| M18 | Quick View: Markdown as a document | 08-07 | **Raw HTML passthrough** — CommonMark says to pass it and a preview that renders on *cursor movement* must not, which is also what keeps the generated page inert; **full CommonMark conformance** (the target is what the file's author sees on GitHub for an ordinary document, pinned by a corpus of real files, with an unreadable construct rendering as its literal text); **math and LaTeX, footnotes, definition lists, emoji shortcodes and wiki links**; every mermaid diagram type outside **flowchart and sequence** (a class diagram, gantt, state chart or ER diagram falls back to a code fence naming itself, as does an unsupported construct *inside* a supported type); **following a link to another file**, since turning a preview into a browser needs its own history and its own way out; **RTF**, the other type M16 left in the same sentence — `NSAttributedString`'s job, sharing nothing with a renderer; **rendering as you type** and editing of any kind (§M11's call, unchanged); and **exporting the rendered page** to HTML or PDF, which is a file operation and belongs in the operation engine with a destination and a conflict policy |
| M19 | Encryption | 08-09 | **`zipcrypt` and AES-128** (the first is broken, the second buys nothing on hardware AES — both taken at open); **encryption for any container but zip**, since libarchive's 7-Zip writer refuses it and tar has no notion of it; **a passphrase for the paths that are not F5** — preview and *nested*-archive entry failed with `passphraseRequired` rather than prompting, and the encrypted route extracted the whole archive rather than the requested members, so a member filter plus a per-archive passphrase held for the session was its own slice (the passphrase half **landed 2026-08-09**, user-reported — see HISTORY.md ▸ After M19; the **member filter landed 2026-08-25**, closing the milestone: `ArchiveMemberFilter` skips what nobody asked for, and one member of a 600 MB archive costs 0.001 s against 1.53 s); **encrypting in place**, or any gesture that removes the plaintext afterwards, because that delete belongs to the user with the Trash's own rules in view; and **vault paths in anything the user saved on purpose** — a named workspace or a favorite pointing inside a vault is kept, since §6's rule is about what Dirnex remembers *without being asked* (the derived-data clause itself was closed 08-09 by fixing the frecency index and session restore, not by stating the leak — see HISTORY.md §M19 ▸ Follow-up) |
| M20 | Every place reachable without the sidebar | 08-12 | Individual places as ⌘K palette results (the palette is a registry of *commands*, places are live data — a different mechanism, worth its own decision); reordering or editing places from the menu, which stays the sidebar's job; a Finder-style "Computer" or "Network" destination, which is not a place Dirnex has; and a **Help menu** — Slice 2 claimed Help ▸ Search made "Trash" findable and the app declares no Help menu at all, so adding one is its own decision and was not taken |
| M21 | Amazon S3, and the mounts we already reach | 08-19 | **Atomicity of any kind** — a prefix rename or delete is N copies and N deletes, so stopping partway leaves items under both names, and no layer can make it otherwise; **a byte counter during a server-side copy**, which would cost a round trip per object (~25 min of pure latency on a 50 000-file prefix), so those jobs report items; **`copyMetadata` and `DirectorySync` by timestamp**, since S3 has no settable mtime, no permissions and no symlinks; **a File Provider mount** (Mountain Duck / `rclone mount` territory — a different product with a different lifecycle); **AES-style client-side encryption, versioning, lifecycle rules and storage-class changes**, none of which a file manager's ten verbs have a place for; and **the 200-committed multipart refusal seen from Amazon**, which AWS documents and answers `412` with the code in practice, so it stays pinned against our own SigV4-verifying endpoint |
| M22 | Find Files on a connected server | 08-16 | **Content-grep and tags remotely** — no remote backend can answer either without reading every file, so `SearchFields` withholds them rather than skipping the clause (which would return *more* results under the same name); **an exact remote timestamp**, since FTP's `LIST` stamps are year- and zone-less on the server's clock; **searching an S3 *account* pane**, whose rows are buckets — "search every bucket" is a different and much more expensive question than the one ⌥F7 asks; and GNU `find -printf`, retired at the probe rather than handled, since choosing it would have shipped the common case unverified — POSIX `find … -exec ls -ldn {} +` instead, at the cost of the date column |
| M23 | Copy, paste and drag, wherever the file is | 08-26 | Dragging a *folder* out of a server as a promise (a promise is one file; a recursive fetch behind a Finder drop has no progress surface and no way to stop it) and dragging an archive **member** out to another app, for the same reason one layer along — an encrypted archive would have to raise a passphrase sheet behind somebody else's drop, and `extractArchiveSources` reports failures with an alert rather than through a completion handler, so it would need Slice 4's always-answers contract first (taken by the user 2026-08-26, F5 copy-out being the route); `⌥⌘V` move-paste into an archive, which stays gated where it was; a *drop* into a browsed archive, where ⌘V adds by repacking and a drag does not; and the pasteboard as an automation surface — nothing here is scriptable that F5 was not. **Left for a human**, since a drag *session* cannot be synthesized: an actual drag between two panes, a Finder drag onto a connected server, and a drag from a connected server into Finder |

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

M19 closed on 2026-08-09; M20 opened and closed 2026-08-12, M22 on 08-16, M21 on 08-19 and M23 on
08-26. Thirty-two further passes landed between 2026-08-07 and 2026-08-26 without a milestone of
their own, and every one of them is shipped — so that log lives in
**[docs/HISTORY.md](docs/HISTORY.md) ▸ After M19** with the rest of the archive, together with the
two passes that closed M19's own loose ends.

What is still open, rather than merely imaginable, is the *undone* column above, the two planned
milestones below — which is where [docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md)'s parity
backlog now lives — plus one item:

- **The thumbnail grid, brief view and the `PaneSurface` extraction** — M15's cut, and one unit
  rather than three items, argued in HISTORY.md §M15. Any future grid inherits two constraints from
  it: skip `FileEntry.isDataless` rows, and move sort off the column header first.

**The top parity gap in [docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md) — "no live
refresh on a server" — closed 2026-08-26.** A pane on a connected server now re-lists itself while
it is on screen, so a file somebody else added appears without anyone pressing a key.
`RemoteRefreshPolicy` derives the gap from **what the previous refresh actually cost** rather
than from a per-backend table, holding a pane to ~5 % of its wall time — so an ordinary folder runs
at the floor
the user owns (Settings ▸ Panels, 15 s, **0 = never contact a server unasked**) while a
50 000-object prefix backs off to about one refresh every eleven minutes on its own. It polls only
while `NSWindow.occlusionState` says the pane is genuinely visible, and it re-uses the existing
passive refresh rather than growing a second one — the two wake sources differ on one thing only,
which is whether the wake is itself proof that the subtree changed. Verified against a throwaway
local `sshd`; the run is what caught the catch-up bug that no headless test could (HISTORY.md ▸
After M19, NOTES.md ▸ AppKit). It stays a **"yes, limited"** in that document rather than a plain
yes: a poll is not a notification, and nothing can make it one.

**The next one — "session restore and workspaces drop remote tabs" — closed
2026-08-27.** Quit with four bucket tabs open and they come back, as does a browsed `.zip`; a saved
workspace carries its server tabs the same way. What was missing was never the *place* — a persisted
tab has always stored the account's descriptor — but the way back to it: a `VFSBackendID` says
nothing about the auth method or an FTPS certificate the user trusted, so the tab was dropped rather
than restored dead. `PersistedTab` and `WorkspaceTab` now carry the ``ServerEndpoint`` itself, which
holds no secret (``ServerConnection``'s own argument for its JSON) and is independent of the sidebar,
so a one-off connect restores and deleting a saved row does not close anybody's tabs.

Three things decided the shape. **Registering a connection costs no round trip** — it is a credential
plus coordinates, and the network happens in the listing that follows — so the reconnect is
synchronous and needs none of the connect flow's corrections (a restored bucket's path is already
the one an earlier connect settled on). **The seam is `navigate`, not `activateTab`,** so switching
to a tab, clicking a crumb, ⌘L and back/forward are all one definition of "open this place again" —
which is also what gives a tab that came back disconnected a way out with no new UI. And the launch
activation is marked **unasked**, which decides two things and only for it: whether a server may be
contacted (Settings ▸ Panels promises a floor of 0 means never, in so many words) and whether a
failure is worth an alert (nobody is waiting for the answer, so the pane says it instead).
`TabRestorePolicy` owns which tabs come back and what each needs first — a directory, an archive
file, or a connection — with the app supplying only whether the disk agrees.

Verified against a throwaway local `sshd` plus a real `.zip`, with the **server's own log** as the
independent judge: at the default floor the restored tab reconnected at launch and its cursor came
back on a file that exists only on the server, while the archive tab's came back on one that exists
only inside the zip; at floor 0 the same launch put **0 bytes** in that log and one Go Up gesture
put a connection in it. See docs/NOTES.md ▸ Design lessons.

M19's last loose end — **a member filter for an encrypted archive** — **closed 2026-08-25**. The
encrypted route extracted the whole archive however little was asked for, so opening one member of a
600 MB archive decrypted all of it; ``ArchiveMemberFilter`` now selects what is placed and every
other entry is stepped over rather than decrypted (**1.53 s → 0.001 s**, measured through the reader
and confirmed in the running app, where the temp extraction held one 6-byte file instead of 600 MB).
Two things fell out of it rather than being built: the app's whole-archive extraction cache had
existed only to amortize the cost the filter removes, and the explicit `archive_read_data_skip` turned
out to buy nothing over libarchive's own implicit skip — the saving is in not reading the data. See
docs/NOTES.md ▸ Encryption.

### Planned: M24 and M25 — the parity backlog

[docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md) used to rank what still feels unlike local at
the bottom of its own tables. It ranks nothing now: that document is the *status*, and every cell in
it that is a gap rather than a limit points at one of the two milestones below, or at the shorter
list of cells after them. Nothing here is scheduled that the tables do not mark, and nothing they
mark as a limit is scheduled at all.

### Planned: M24 — Every local-only feature, on a file that is not local

**Seven features refuse anything that is not on this disk, and each refuses it in one line.**
`PanelViewController+OpenWith.swift:25` filters the selection to `backend == .local`;
`+Compare.swift:86` requires it of both sides; `+Checksum.swift:60`, `+UserScript.swift:25`,
`+ArchivePack.swift:28`, `+Attributes.swift:146` and `+Sync.swift:68` each say the same thing about
their own gesture. Fifty-five sites in the app read that comparison and most of them are right — Git
status, Finder tags, vaults, the terminal drawer and the cloud-download prompt are all genuinely
about *this disk*. These seven are not: nothing about them needs the file to be local, only to be
**a file**.

The bytes are already reachable, which is what makes this a milestone rather than a rewrite.
`fetchRemoteFile(_:for:)` has pulled a remote row down for ⏎, F4 and every preview since M21 Slice
10, under a size policy that decides whether to ask first (`RemoteFetchPolicy`, four purposes and a
table of thresholds); `ArchiveExtractor` has placed a member since M4, and M19's member filter made
that 0.001 s for one member of a 600 MB encrypted archive. What is missing is not a download. It is
a download of **a marked set**, with a determinate bar and a Stop — which is the operation queue's
job and not a cache's.

#### Three things to settle before any Swift

- **A gesture over N remote files has to say what it will cost before it starts.**
  `RemoteFetchPolicy` answers per file, for the one file under a cursor, because that is the only
  shape that existed. ⌥F3 is two files; a checksum run and ⌥F5 are a marked set; a user script is
  whatever the user marked. So the plan itself is the deliverable — which of the set is already
  cached, what the rest weighs, and how many billed requests it is — and the confirmation names that
  total rather than asking once per file.
- **The engine must never materialize; the gesture must.** `ByteComparator` refuses an evicted cloud
  placeholder rather than reading through it, and that rule arrives here one protocol out: the
  compare was asked for, so the *gesture* fetches and reports, and the comparator still only ever
  sees files that are already here. Anything else puts a silent multi-gigabyte download behind a
  keystroke — which is the failure `SF_DATALESS` exists to prevent, wearing a network instead of a
  file provider.
- **A `.zip` on a server is the whole file.** `ArchiveBackend.init(archiveOnDiskPath:)` needs a real
  path, so browsing one is fetch-all-then-mount and writing into one is repack-then-upload. Both are
  affordable and neither is free, and the difference from ⏎ on a small text file is exactly that the
  user should be told before it starts.

#### Slices

Core first, app untouched until (2), as usual. Each lands runnable.

1. **`MaterializationPlan` in `DirnexCore`** — given a set of `FileEntry` and what the cache already
   holds, what must be fetched, its total bytes and its request count, and whether that total is
   over the threshold a given purpose confirms at. `RemoteFetchPurpose` grows the cases these
   gestures need, so each one's threshold is a line in the existing table rather than a constant at
   a call site. Pure, tested, additive; no app rebuild.
   **Landed 2026-08-27**, and three things came out of building it that the slice did not predict.
   `MaterializationSource` has **five** cases rather than two, because the reasons a row is not yet a
   readable path cost different amounts and are paid by different people — a remote transfer is ours
   and S3 bills it, an evicted `SF_DATALESS` placeholder is a wait the file provider owns, and an
   archive member is neither. The placeholder case is the one that had to be there: its name, size
   and dates are all real, so nothing but that flag separates it from a file that is genuinely here,
   and it is exactly the row a plan built on `backend == .local` would have called present. Second,
   the decision needed a **second rule, not a second table**: `unaskedRequestLimit` (20) is derived
   from the measured 0.512–0.519 s to first byte for a *small* S3 object, because 10 000 objects of
   500 bytes is 5 MB — under every row of the size table — and about **83 minutes**, which a policy
   expressed in bytes is structurally blind to. Third, all six new purposes sit on the existing
   open/edit row deliberately: they are the same commitment ⏎ carries, and six constants a few
   megabytes apart would each mean *approximately* 64 MiB and drift on the first visit anybody paid
   to one of them. The cases exist anyway, because `threshold(for:previewLimit:)` switches
   exhaustively — which is what stops the next gesture reaching a number by inheriting one.
   Both directions are controlled: removing the request rule fails only the four tests about it and
   leaves the "few requests still start" control green, and over-correcting to always-confirm fails
   exactly the five that say a local, cached or small set must never ask.
2. **Bulk materialize as a queue job.** An N-file fetch is a `FileOperation`, which buys the
   determinate bar, Stop, per-item failure reporting and the pause/resume the queue already has —
   and stops a second copy of the transfer loop existing. `RemoteFileCache` stays the *store* and
   gains no second way to be filled.
   **Landed 2026-08-27.** `FileOperation.Kind.materialize` joins `.checksum`, `.attributes` and
   `.pack` as a kind that produces **no `outcomes`**, which is how "nothing here is undoable" is a
   property rather than a rule — `UndoJournal` has nothing to build a record from, and reversing a
   download into a temp directory is not a thing to offer. That is also why it is not expressed as a
   `.copy` into that root, which the journal would dutifully record as a transfer; it needs no
   payload either, since `destinationDirectory` already means "where this job puts things" and
   `sources` is which rows.
   The loop **keeps going past a failure** and names the row, because that is right for a checksum
   over forty objects and wrong for ⌥F3 — so the decision belongs to the gesture reading
   `report.failures`, not to the runner. Two things came out of writing it. `MaterializeRunner
   .materialize` is now the **one definition of "fetch this row"**, called by the queued loop *and*
   by `RemoteFileCache.fetch`, so the directory-per-file layout (two objects called `report.pdf` from
   different prefixes) and the leaves-nothing-behind rule have one home rather than two. And the
   cache gained one private `record` that `fetch`, `rebaseline` and the new `adopt` all go through,
   which is what makes "no second way to be filled" a property of the type instead of a rule three
   call sites keep — the runner produces `MaterializedFile` values and the window adopts them,
   because `DirnexCore` cannot see a `@MainActor` window-scoped cache at all.
   Controlled in four directions: one shared directory instead of one per file, a failed transfer
   keeping its partial, the loop stopping at the first failure, and the queue never dispatching the
   kind — each fails only the tests that name it.
3. **Open With… and the Share sheet.** The cheapest of the seven: one file, one URL, and ⏎ already
   fetches exactly that. The only new question is what a *marked set* of remote rows means for Open
   With, which is the plan from (1) with a different verb after it.
   **Landed 2026-08-27**, and the two verbs turned out not to be one gesture with one shape. **Open
   With pops its menu before anything is downloaded**: a row that is not on this disk is typed by
   its *name* rather than by a file, which is what LaunchServices types an ordinary file by anyway,
   so the app list costs nothing and a user who presses Escape has paid nothing — the transfer
   starts when they pick an application. **Share cannot do that**, because `NSSharingServicePicker`
   derives its services, their icons and their order from the *items*; there is no list to show
   before the files exist, so it fetches and then presents. Typing by name is deliberately *not* a
   fallback: it applies to a non-local row whether or not its bytes happen to be cached, so the menu
   cannot change depending on what some earlier preview downloaded, and a local row goes on reading
   the real file — which is what preserves the existing rule that a file deleted between the listing
   and the right-click offers nothing.
   **Services is the one that stays local, and it is now a limit rather than a gap.** AppKit fills
   the pasteboard **synchronously**, inside `writeSelection(to:types:)` as the menu opens, and there
   is nowhere in that call to put a download — so `canSendToServices` is a second, narrower gate,
   because asking the wider one would advertise the pane for a selection `writeSelection` then
   declines to write, leaving Services items that do nothing.
   Three things fell out of building the funnel (`PanelViewController+Materialize`), which Slices
   4–6 inherit. A **cloud placeholder is handed over as its own path** and neither confirmed nor
   fetched: those bytes are the file provider's when the receiving application reads them, exactly
   as Finder does it — hence `MaterializationPlan.excluding(_:)`, since counting them would put a
   *"download this from the server"* dialog in front of a file already on this disk. A **folder that
   is not here is not a hand-off target** at all (`pendingDirectories`, the same rows that make the
   totals a floor, read from the other side): it stands for an unknown number of objects in an
   unknown number of requests, and copying a tree out is F5's. And a **short set is a failure**
   rather than a smaller success — an application given three of the five files somebody marked has
   been told something untrue — with the server's own reason used for the wording where there is
   one, which is all `report.failures` is read for: what decides is whether every row *resolved*,
   since a row that failed while an earlier copy of it is still current costs the user nothing.
   The queue side needed one thing the other kinds did not: `MaterializeDeliveries`, because
   `FileOperationQueue.enqueue` is an actor method and the job id the two halves share exists only
   *after* the job has been accepted and could already have run — so the report and the gesture
   waiting for it pair in whichever order they arrive. A `.materialize` job is also the one kind
   that does **not** re-list the panes when it finishes: its destination is a temp root, so a
   refresh would spend a request per remote pane to redraw rows that cannot have moved.
   Controlled in seven directions, each failing only the tests that name it: refusing no folder,
   weighing placeholders, dropping the report's error, handing a short set over anyway, typing a
   non-local row as untypeable, losing a report that arrives before its gesture, and letting
   Services ask the wider question.
   **Verified live against a real `sshd`**, and the gesture that makes the whole chain drivable
   headlessly is **Share** — it fetches *before* it presents, so `run operation "file.share"` runs
   the plan, the decision, the queued job, the adoption and the delivery with no UI to click. Two
   marked SFTP rows produced **two** `Accepted publickey` sessions in the server's own log and two
   copies under `DirnexRemote`, each in its own directory under its real name with the right bytes.
   The measurement that separates a cache hit from a gesture that did nothing is the sharp one:
   deleting **one** of the two copies and repeating the gesture cost exactly **one** session and
   brought back exactly that file, leaving the other untouched — "nothing changed" would have been
   true of a dead gesture too. And `run operation "file.openWith"` over the same rows opened its
   menu (the verb does not return: the menu runs a nested event loop) having moved **zero** bytes,
   which is the asymmetry the slice was designed around, measured rather than argued.
   Two things about the instrument are worth keeping. The pane's own **background remote poll**
   makes a session *count* useless as evidence — it drifted by four over ten idle seconds — so the
   measurement has to be the delta across the gesture, or better, whether any **bytes** landed,
   which nothing but a fetch produces. And the cursor of a restored tab lands on the first row,
   which sorting puts on the *folder* — so the first run measured the refusal rather than the
   transfer, and the marked set had to be seeded (`markedPaths`) to reach the claim.
4. **Compare By Contents and checksums.** ⌥F3 fetches both sides and hands `ByteComparator` two
   local files; a checksum run fetches the marked set and hands `ChecksumEngine` real paths.
   `ChecksumScope` and the manifest's *stored* names must stay the remote names, or a manifest
   written beside a bucket's objects names temp directories.
   **Landed 2026-08-27.** The name-versus-bytes split turned out to be **one line**, because
   `ChecksumWalkedFile` had carried the two apart since M14 — a manifest-relative *name* and the
   *entry* whose bytes are read — and only the byte-reading site had ever conflated them. So
   ``MaterializedPaths`` is consulted in `ChecksumRunContext.digest` and nowhere else: the engine is
   handed a temp copy while the progress label, the failure path and the manifest's own spelling go
   on naming the object on the server. A row with no stand-in is
   ``ChecksumEntryStatus/notDownloaded`` — the answer an evicted cloud placeholder already gave,
   which is the same fact about a different provider — and it is *reported* rather than thrown, so it
   cannot be `try?`-ed out of a manifest that would then verify clean while covering less than it
   claims. A **local path stands for itself**, placeholder included, which is what keeps every
   ordinary run reaching the identical code with an empty map.
   **The manifest is written beside the objects it describes, so a bucket's checksum is an upload.**
   That is forced rather than chosen: every format spells its names relative to the checksum file's
   own location, so there is no third option where the names still resolve. It needed no new policy —
   `capabilities(for:)` asked of the **manifest's own directory** already answers per backend, so a
   writable bucket says yes, a read-only one says no, and a browsed archive refuses itself because
   `ArchiveBackend` advertises `.read` alone. And there is deliberately **no pre-flight guard on the
   manifest's backend**: the sentence a user reads should be the one the thing that declined actually
   said, which is what made `ChecksumRunContext.recordFailure` stop normalizing a `VFSError` through
   an errno — that had been flattening every backend's own refusal to `.io`, a code nobody can look
   up standing in for "the bucket is read-only".
   **Verifying is two-phase, because nothing can know what to fetch until the manifest has been
   read** — and that is what forced the walk out into ``ChecksumVerifyScope``, shared by the gesture
   that weighs the set and the run that hashes it. Two spellings of *which files does this manifest
   claim* would fail in the quiet direction: every file the gesture failed to predict comes back "not
   downloaded" while sitting right in front of the user. The walk between the phases costs listings
   and no transfers, so by the time anything is downloaded the total is exact rather than a floor. A
   **local** manifest short-circuits before phase one and is byte-identical to what M14 shipped,
   which is what keeps the common case free of a second directory walk.
   Three things fell out. A **placeholder is fetched but never weighed**, whichever gesture is
   fetching it: `CloudDownloadPrompt` already names the file and its size and carries a Stop, so a
   confirmation in front of it is one reporter too many for one transfer — and it would have to lie
   about where the bytes come from, since a plan with no `requestCount` says "from the archive".
   A **folder that is not already here is refused**, in the hand-off's own words and for its own
   reason. And M14's rule — *a file somebody pointed at downloads, a tree sweep refuses* — is
   unchanged but widened to the set the user actually **marked**, where before only a lone selected
   file qualified; a file the runner *discovers* by descending into a marked folder is in no plan and
   still meets the engine's refusal.
   Compare needed the pair itself to change shape: the `backend == .local` gate lived in
   `comparablePaths`, so it had to answer with **entries** — what the pair costs to read is now part
   of the question, and only an entry carries the size that decides.
   Controlled in nine directions, each failing only the tests that name it: reading the row's own
   path instead of the stand-in, writing the manifest locally whatever its backend, flattening the
   backend's refusal through an errno, claiming the whole walk rather than the intersection, queueing
   a create with no map, refusing no folder, asking the pane's path instead of the manifest's, never
   going two-phase, and Compare's local gate restored.
   **One control was vacuous and had to be fixed before it meant anything** — the folder refusal
   asserted only that *a* sheet appeared, which passed against a build that refused nothing, because
   the sheet it then raised was the *create* sheet. Counting the sheet's buttons is the
   language-independent discriminator (one for a refusal, three for the create sheet, whose accessory
   carries a popup).
   **Verified live against a throwaway `sshd`**, and the evidence is the files rather than a session
   count, which the pane's own background poll makes useless. `run operation "file.checksumVerify"`
   over a manifest on the server landed **three** copies under `DirnexRemote` — `files.md5` first,
   then `a.bin` and `b.bin`, each in its own directory under its real name with the right bytes —
   which is the two-phase gesture with nothing to click. The measurement that separates it from a
   cache hit is the sharp one: deleting **one** copy and repeating brought back exactly that file and
   left the other two untouched. `run operation "file.compareByContents"` over two marked SFTP rows
   fetched both and opened FileMerge on them. Creating a manifest on a server is the half that is
   **not** reachable headlessly — the gesture ends in a sheet, so the upload is covered by the core
   suite against a receiving backend rather than by a live run, which is the same asymmetry Slice 3
   recorded between Share and Open With.
   The live run is also what caught a flaw the suite could not: Compare fetched **before** asking
   whether a diff tool was installed, so a user with none would have paid for a download to be told
   so. The tool question now comes first.
5. **User scripts.** Hand the script real paths and let it run. The interesting half is a script
   that *edits* its argument: that is the `EditedFileRegistry` watch F4 already installs, so a save
   is offered back up rather than lost in a temp directory nobody will look in again.
   **Landed 2026-08-27.** The write-back half was one function because it was *two and about to be
   three*: F4-inside-an-archive and F4-on-a-server each built their own `EditedFile` behind their own
   gate, and a script would have been the third spelling, written by somebody who had not read the
   other two. `PanelViewController+WriteBack` is now the one place that answers *where does an edited
   copy of this row go back to* — `nil` meaning **not watched** rather than not writable, which is
   what keeps the nested-archive refusal F4 owns (it drops the write bits) from leaking into Open
   With and a checksum, who read the same extraction and are not about to write.
   **The fork that needed settling was not the files but the *directory*.** A script has one working
   directory for the whole run and `DIRNEX_CURRENT_DIR` claimed to be "the active panel's directory",
   which on a server, in an archive or in a results tab is a folder that does not exist — so the
   variable is now **absent** there, exactly as `DIRNEX_OTHER_DIR` already is when there is no second
   local pane, and a script branches on `[ -n "$DIRNEX_CURRENT_DIR" ]`. Naming the temp directory one
   copy happens to sit in would have been a plausible answer to *where is the user looking* that is
   not one — the same thing this repo says about a cache miss, which is "not known here" and never a
   stand-in. Where the process *starts* is a separate question with a separate answer that is always
   real (`UserScriptContext.workingDirectory`, derived rather than stored so the two cannot be given
   different answers by two callers): the panel's folder when it has one, else the folder holding the
   first file handed over — which is what a results tab had always done, now the *only* rule rather
   than a second one. A context with neither makes **no invocations**, because a `combined` script
   with nothing marked acts on a directory and there is none.
   Two smaller things fell out. `localPanelDirectory` goes through **`writeDirectory`** rather than a
   fresh `backend == .local`, which is the same question already answered once and gets the merged
   iCloud listing right for free — its own path is synthetic while the folder underneath it is
   perfectly real. And both panes' directories now go through that one property; the counterpart used
   to be asked with its own inline comparison, which is one rule in two spellings.
   Controlled in eight directions, each failing only the tests that name it and leaving Slice 3's
   suite green: always exporting the panel variable, never falling back to the first file, always
   having a working directory, the gate back to local-only, dropping the watch, watching every row
   (which also fails the narrowness control that a local run watches nothing), dropping the pairing
   guard, and reading `panel.path` instead of `writeDirectory`.
   **Verified live against a throwaway `sshd`**, and the evidence is the server's own bytes. Two
   marked SFTP rows through `run operation "userScript.ProbeRead"` reached the shell as
   `…/DirnexRemote/<uuid>/alpha.txt` and `…/beta.txt` — each in its own directory under its real
   name, holding the server's content — with `DIRNEX_CURRENT_DIR` printing **empty**, which is the
   design decision measured rather than argued. Then `ProbeEdit`, appending a line to `"$1"`, left
   **both files on the server** carrying that line: fetched, handed over, edited, noticed, uploaded,
   with nothing to click. The control is the one that separates it from "any script run uploads" —
   the read-only script ran again afterwards and the server's checksums did not move — and the
   deletion control is the sharp one, since "nothing changed" would also be true of a dead gesture:
   removing **one** copy and repeating brought back exactly that file, in a new directory, carrying
   the server's *current* bytes including the edit the earlier run had uploaded, and left the other
   untouched.
   **The one thing it does not do is coordinate.** A script that rewrites forty remote files produces
   forty independent write-backs, each re-`stat`ing and uploading on its own the way F4's single save
   does — no combined bar, no Stop, no ordering. That is the shape M24 Slice 2 gave the *download*
   direction and the upload direction has never had; it belongs with M25, which already owns what a
   remote write carries.
6. **Pack in both directions, and browsing a `.zip` on a server.** Both ends of ⌥F5 stage — build
   into temp, upload the archive — and browsing one is the mirror. This is the slice that needs the
   "the whole file is coming down" sentence, and the one where a *nested* archive stays out of
   scope for the reason it always has: its bytes are already a temp copy.
   **Landed 2026-08-27**, and the source half needed no staging directory at all — which was the
   measurement that decided the design. `bsdtar` accepts `-C` **interleaved with the names** in
   create mode (probed against libarchive 3.7.4: `-c -f out.zip -C /a alpha.txt -C /b beta.txt`
   writes both members correctly), and `ArchiveSourceItem` has split the absolute `onDiskPath` from
   the relative `archivePath` since M19 — so both writers already wanted a per-source directory and
   only their entry points did not. ``PackSource`` is that pair, `-C` is emitted **only where the
   directory changes**, and an ordinary pack's argv is byte-identical to what it always sent. No
   hardlinks, no gathering, nobody's bytes copied twice.
   **It fixes a bug nothing had reported: ⌥F5 in a *tree* has been wrong since trees shipped.** The
   pack was handed `panel.path` plus bare names, so a marked row inside an expanded folder named a
   file that is not in the pane's own directory — `bsdtar` failed, and the encrypted walk skipped
   the missing name and wrote a **smaller archive without saying so**. The same fix covers it,
   because the answer to *where are this row's bytes* is now asked of the row.
   **A folder that is not already here is refused**, in the hand-off's own words and for its reason,
   which is a *correction* to the claim `MaterializationPlan.pendingDirectories` carried from Slice
   1 — it said a pack would stage the subtree. Written before any gesture read it, and wrong by the
   time one did: all four that read it now refuse, staging a remote tree is F5's engine pointed at a
   temp directory, and nobody has built that.
   The **destination** is asked `capabilities(for:)` on its own directory rather than "is it on this
   Mac", so a writable bucket takes the archive and a read-only one is refused before a byte is
   written. `PackStaging` is the one definition of *where does the archive go* — nothing at all for
   a local destination, and build-in-temp-then-transfer for a server, swept whatever happens — and
   both pack paths use it, which is what stops the two from drifting. A refused upload comes home as
   the backend's own `VFSError` about the archive's path rather than as an `EncryptedArchiveError`:
   the write worked and the transfer did not, and those are different sentences. The upload's bytes
   are **added** to the bar's total rather than replacing it, so it grows once at the transition and
   runs on to the end — the two alternatives are a full bar parked for the length of a network
   transfer, and an aggregate that walks backwards.
   `EncryptedArchiveError.needsLocalFile` went with it, catalog entries and all: its own doc comment
   said "until then a non-local job fails fast", and *then* is now.
   **Browsing a `.zip` on a server reuses the nested-archive registry rather than growing a second
   one**, because it is the same shape — a mount whose bytes are a temp copy — and three things fall
   out of that which are exactly what is wanted: the way up goes back to the *server's* directory,
   the breadcrumb names the server (the crumb builder had to learn that, or it drew
   `Macintosh HD › private › tmp › DirnexRemote › <uuid>`), and the mount is **read-only**, since a
   write would land in the temp copy rather than in the archive on the server. Repack-then-upload is
   its own pass and is reachable now that the pack half exists.
   Controlled in ten directions, each failing only the tests that name it: the folder refusal
   dropped, the destination gate back to local-only, `canPackFromHere` back to local-only, sources
   named from the row instead of the file, one leading `-C` for the whole set, staging disabled, the
   ⏎ route removed, the crumbs rooted at the extraction again, a placeholder *directory* classified
   as one, and the remote origin walked as an enclosing archive. The narrowness controls are the
   half that matters most and all stayed green throughout: a **local** folder still packs, an
   ordinary remote **file** still opens in its own application rather than being mounted, and the
   nested and top-level crumb chains are untouched.
   **Verified live against a throwaway `sshd`**, and unlike Slices 3–5 the gesture is *not* drivable
   headlessly — ⌥F5 ends in the pack sheet, which is a nested question no AppleScript verb gets past.
   So the live half is a checked-in suite gated on the same config file `SFTPLiveIntegrationTests`
   uses (`PackLiveIntegrationTests`), driving the real `SFTPProcessTransport`, the real `bsdtar` and
   the real mount. Two objects staged off the server into **two different directories** packed into
   one archive whose members came back with the server's exact bytes, under the names the user
   marked and with no trace of where they were staged; an encrypted archive built here landed on the
   server, where **`bsdtar` — which is not ours — listed `payload.txt` in it and then demanded a
   passphrase to extract it**, so it is a real zip and really encrypted; and a `.zip` on the server
   came down whole and listed `one.txt`, `two.txt`. The independent read is the point in each case:
   the upload is checked by a *fresh* download rather than by asking the writer what it wrote, which
   is the trap Slice 10's own probe fell into one milestone ago.
   **A stronger assertion found a bug three green runs had not**, and it is worth the sentence: the
   crumb test first asserted a *suffix*, which is true of a trail carrying everything twice
   (`… › srv › backup.zip › srv › backup.zip › docs`) — the remote origin was being walked as though
   it were an enclosing archive, whose `path` is an archive-inner path where a server's is not. The
   same run showed the root crumb reading "Macintosh HD", because the fixture's backend id was a
   hand-built string `backendRootTitle` cannot parse, so the test had been measuring the fallback.
   Both are fixed and both are now pinned by an equality over the whole list.
   **The one thing it does not do is put a plain pack's upload on the queue.** A plain pack has never
   been a queue job — that is the libarchive boundary §M19 drew, and it is the *encrypting* that
   earns the queue — so a `.tar.gz` bound for a server is reported by the status line and has no bar
   and no Stop for its transfer. Encrypting the same archive puts both halves on the bar.
7. **Get Info, read-only, on a remote row.** The SFTP and FTP listings already carry mode, owner,
   group and modification date into `FileEntry`; `AttributesController` refuses to draw them. Read
   first and write in M25, because the two fail differently — a panel that shows a mode it cannot
   change is honest, and one that offers a change it cannot make is not.
   **Landed 2026-08-28, and the premise above was half wrong — which is what the slice turned out to
   be about.** Probed before any Swift: the listings carry mode and date, and **owner and group were
   read and thrown away** — `ColumnarListing.unixRow` reads columns 0 and 4–7 and skipped 2 and 3, so
   every remote `FileEntry` carried `ownerID == 0` while the answer had been arriving in the same line
   as the mode since M5. And they are **names**, not ids (`oleg     staff`), which is why they could
   never have gone into `ownerID`: `AttributesSnapshot` resolves an id through this Mac's `getpwuid`,
   so a server's `501` would have drawn the local account of whoever is reading the panel over a file
   belonging to a stranger.
   **The finding that decided the design is that two backends *invented* a mode.** S3 and FTP's
   DOS/IIS dialect both answered `0o755`/`0o644`, each under a comment explaining that `0` "would
   render every remote row as unreadable in the permissions column" — and the columns are `name`,
   `size` and `date`. There is no permissions column, and there never was: the fabrication was
   harmless for exactly as long as nothing displayed it, and this slice is the reader that would have
   drawn it as the server's own word. So `FileEntry.permissions` is now **optional**, because `0`
   cannot stand in for the absence — `chmod 000` is a legal mode — and the compiler is what stops the
   next display site inheriting a stand-in. The blast radius was one pass-through: `ArchiveSourceItem`
   takes its mode from a real `stat`, so packing never read it.
   Two things came out of it that the slice did not predict. The mode reader was **approximate** —
   `s`/`S`/`t`/`T` were all read as a plain execute bit, which is fine for a row that draws no
   permissions and wrong in a panel whose job is to state a fact, so a `rwsr-xr-x` binary would have
   been disclaimed as `rwxr-xr-x`; it is exact now, and `POSIXPermissions` already stored and rendered
   all twelve bits. And the **archive** was throwing its mode away too, using only the leading kind
   character while `bsdtar -tvf` printed the real one in the same column — with the owner arriving as
   *names* for a tar and *bare numbers* for a zip, which stores none, so even one tool's answer changes
   shape with the format.
   **A separate read-only panel rather than the four-tab one degraded**, because three of its four
   tabs would have had nothing to say: no remote listing carries an ACL, an extended attribute, an
   access time or a birth time. `RemoteAttributesController` is built on one rule — *a field with no
   answer is absent, never blank and never a stand-in* — with notes that explain the absence, so a
   short panel reads as a fact about the server rather than as a panel that failed to load. Which
   rows it will draw is a pure `fields(for:)`, and which panel a selection deserves is a pure
   `AttributesRoute`, so both are testable with nothing presented — a real window in the test host
   makes it do real pane work and destabilizes its neighbours (docs/NOTES.md ▸ Testing).
   The routing is **per row, not per pane**, which is the shape §M24 Slice 6 had already paid for in
   the pack sources: a results tab holds hits from anywhere and a tree draws several directories at
   once. That retired the `!isVirtualDirectory` gate in favour of `nameMatchesPath`, which is the
   honest form of it — the old one refused every ordinary file standing beside iCloud's app rows, and
   every hit in a results tab, for the sake of a handful of synthetic ones. A **mixed** marked set is
   now refused rather than served short: the bulk panel is an editor, and the old local-only filter
   quietly opened it over the local subset, editing fewer items than the user marked.
   Controlled in nine directions, each failing only the tests that name it: S3 and the DOS dialect
   inventing a mode again, the archive dropping its mode, `UnixRow` dropping owner and group, the
   local-only filter back in `attributesTargets`, the route ignoring the backend, the panel drawing a
   permissions row unconditionally — plus two narrowness controls that stayed green throughout (an
   ordinary mode gains no special bits, and no entry produces an empty panel).
   **Verified live against a throwaway `sshd`, with the OS as the independent judge.** The real
   parser fed the real bytes a real server printed agreed with this Mac's own `lstat` on all six
   files, including `setuid.bin` at **4755** and a sticky directory at **1777** — the two the old
   approximating reader flattened to 0755 and 0777, which is the control that makes the agreement
   evidence rather than a coincidence. Then the whole gesture in the built app, restored onto that
   server: `targets=1` on a remote row (the old filter would have made it 0), the panel opened, and
   it drew `mode=4755 owner=oleg group=wheel` — the server's own words, end to end.
   One thing about the instrument is worth keeping: `TabPersistence` reads `data(forKey:)`, so a tab
   seeded with `defaults write -string` is silently **not restored** and the pane falls back to Home.
   It cost two runs, and the tell was a false one — the server's log showed sessions that were the
   probe's own earlier `sftp` calls, which is this file's own warning that a session count is not
   evidence, met from the other side. Seed with `-data <hex>`.

**Deliberately not in scope.** Content-grep and tag search on a server, both withheld at M22 for
the reason that has not changed — no remote backend can answer either without reading every file.
ACLs and extended attributes remotely, which SFTP and FTP do not carry at all. Open in Terminal for
an SFTP account, which is an `ssh` session and a different feature. And Get Info's **write** half,
which is M25's.

### Planned: M25 — What a remote write carries, and what a remote delete costs

Three parts, and they share a subject: a remote operation that succeeds while quietly doing less
than the local one it stands in for.

**A copy that carries more than bytes.** `VFSBackend.copyMetadata` defaults to a no-op and SFTP and
FTP both take the default, so a mode and a timestamp are dropped on every transfer with nothing said.
Extended attributes and ACLs are out of scope in both directions — neither protocol carries them, and
that is a limit rather than a gap. What the protocol *does* offer is more than "wire up `chmod`", and **the five lines below were
probed 2026-08-28 against a real `sshd` (OpenSSH 10.2p1) and a real FTP server** before any Swift,
because a man page is not a server. Three of them changed the design and one is a correction this
repo owed itself; the detail is in docs/NOTES.md.

- **`get -p` / `put -p` carry more than the man page promises and less than it implies.** Measured
  in both directions: the low nine permission bits and **both** timestamps arrive exactly — it says
  "permissions and access times" and the *modification* time comes too — while **set-uid, set-gid
  and the sticky bit are silently dropped**, on a mode the server itself puts on the wire (`ls -la`
  prints `-rwsr-xr-x`). Plain `get`/`put` carries the mode only approximately: the umask applies
  and a download's local `open` forces owner-write, so `0777` lands as `0755` and `0444` as `0644`
  while `0600`, `0640`, `0700` and `0754` all survive untouched — so a probe that happens to pick
  one of the second group measures a preservation that is not there.
- **`chmod` is therefore strictly more capable than `-p`, not merely its fallback**: `chmod 4755`
  over the wire really does produce `-rwsr-xr-x`. A mode carrying special bits costs one extra
  round trip and an ordinary mode costs none. `chmod`, `chown` and `chgrp` all take **`-h`**,
  verified in both directions — with it the *link* changed and its target did not, without it the
  target changed and the link did not. `chown` to another uid is refused unprivileged (exit 1,
  `remote setstat "…": Permission denied`), which is the ordinary answer rather than a fault.
- **`copy`/`cp` exists, is genuinely server-side, and settles the correction.** OpenSSH advertises
  **`copy-data revision 1`**, and it duplicated **64 MiB in 0.08 s** — the whole session, connect
  and authentication included — with the two files SHA-256 identical. A server without it makes the
  client print its own **`Server does not support copy-data extension`**, so it degrades per
  connection exactly as M22's exec walk does, and `RelayCopy` stays the only mechanism for a pair
  of ends on *different* backends. `cp` preserves the low nine bits and drops the special ones, so
  it needs the same corrective `chmod` as `-p` — one place that finishes a copy's mode, not two.
- **A symlink's target is unreadable over `sftp` and readable over the exec channel**, as
  predicted. `ls -la` of a directory prints the kind and no ` -> target`, and `ls -la` of the link
  **follows it**, reporting the target's mode and size — the same trap this repo already records
  for classifying an item before a recursive delete. `readlink` over `ssh` returns the raw text for
  relative, absolute and dangling links alike, so this degrades per connection and an `sftp`-only
  account keeps today's refusal. `CopyEngine` passes `entry.symlinkDestination ?? ""`, so
  proceeding without a target would write `ln -s "" link`.
- **FTP is richer than "the mode alone", and that assumption was wrong.** `SITE CHMOD` carries the
  mode, and **`MFMT` writes an exact, UTC-anchored modification time** (RFC 3659) which `MDTM`
  reads back — round-tripped against the local truth on a host at `+0300`, so a timezone error
  could not have hidden. The coarse, year-less, zone-less stamp belongs to **`LIST`**, not to the
  protocol. Every `-Q` refusal is `curl` exit 21 with the reply code separating the two cases that
  need different sentences: **500** for an unimplemented verb, **550** for a file problem — already
  what `FTPTransportError.classify` reads.

**Get Info's write half, and Synchronize on a side with no exact clock.** M24 draws a remote row's
mode and dates; this makes them editable through the same verbs above, with the same per-connection
degradation. `DirectorySync` is the other consumer of the same fact: comparing by timestamp is
deliberately refused for FTP and S3 and always will be, but comparing by **size** is honest and is
simply not built — and once ⌥F3 can fetch two sides (M24 Slice 4), comparing by *contents* is
reachable too, at a price the plan from M24 Slice 1 can state up front.

**A Trash where no protocol has one.** Every remote delete is permanent and unreversible, because
`deleteStrategy` degrades to `.permanent` wherever `.trash` is absent and it is absent everywhere
remote. A confirmation dialog is what stands in for it today. Whether Dirnex should invent one — a
managed `.dirnex-trash/` prefix, a rename into it, and a sidecar naming the origin the way a trash
folder's `.DS_Store` carries `ptbL`/`ptbN` — is a **format commitment that outlives the code**, so
it is §7's open question rather than a slice, and the milestone does not start on it before it is
answered.

#### Slices

Core first, then the app, as usual. Each lands runnable, and each degrades **per connection at run
time** rather than by asking a server in advance — none of these capabilities can be queried, so
the shape is M22's: attempt the verb, read the refusal, remember it for that connection, and leave
the old behaviour standing where it cannot be established.

1. **The metadata carry, in the core.** ``RemoteMetadataPlan`` decides what one transfer must do to
   carry its source's mode and times, and — the half that matters — what it will *lose*, so a
   caller can say so instead of approximating. `SFTPBatchCommand` grows `-p` on both transfer verbs
   and the `chmod`/`chown`/`chgrp` builders (each with `-h`); `FTPQuoteCommand` grows `SITE CHMOD`
   and `MFMT`. Pure, tested, additive; no app rebuild.
   **Landed 2026-08-28.** The rule needed **two capabilities, not one flag**, because `-p` and
   `chmod` are not fallbacks for each other: `-p` is exact for the nine bits and both timestamps
   and cannot express a special bit, while `chmod` expresses all twelve and knows nothing about
   time. So an ordinary mode rides `-p` alone and costs exactly what it always did, only a mode
   carrying set-uid, set-gid or the sticky bit pays for the corrective round trip, and an account
   that has refused `chmod` keeps the nine bits and **reports the loss** rather than claiming the
   mode.
   **A `nil` mode is not a loss**, which is the distinction the whole type turns on and the one a
   sentinel would have destroyed: S3 and FTP's DOS/IIS dialect report no mode at all, so folding
   "absent" together with "dropped" would make every S3 copy claim damage it did not do — the same
   fact ``FileEntry/permissions`` became optional for one milestone earlier. The access time gets
   the same treatment for the same reason, and reading a file over `sftp` **bumps the source's own
   atime to now**, so even a carried access time is a copy of a value the act of copying has
   changed.
   Controlled in four directions, each failing only the tests that name it: the corrective `chmod`
   dropped (three failures, one per special bit), an absent mode reported as a loss, `MFMT` written
   in the local zone rather than UTC — which produced `20180607110910` against a truth of
   `…080910`, the exact three-hour error that would have reached a server silently and only for
   some users — and the over-correction of sending a `chmod` for every mode, which fails the
   narrowness control that an ordinary transfer is byte-identical to what it always sent.
   **Verified live against the same `sshd` and FTP server**, and the point is that nothing was
   hand-typed: a throwaway package built against `DirnexCore` emitted the batch lines and the
   server executed *those*, so what was measured is the builder rather than agreement between two
   things we wrote. A set-uid source came down **104755** carrying its exact mtime, the `-h` line
   left the link at `700` and its target untouched at `644`, and the generated `SITE CHMOD`/`MFMT`
   pair moved a real FTP file to `100754` and `1528358950`. The narrowness control is what makes
   that evidence: a plain `get` of the same source gives **100755** and a mtime of *now*.
2. **Wiring the carry through the transports**, so `copyFile` in both directions asks the plan what
   it needs and the app reports what a copy could not keep. This is where the per-connection latch
   lands, and where `copyMetadata` — today a no-op default the engine calls only for a directory it
   recreated by hand — stops being a no-op for SFTP and FTP.
   **Landed 2026-08-28.** Four things were measured against the real `sshd` and a real FTP server
   before any Swift, and three of them changed the shape.
   **A refused follow-up must not fail a transfer whose bytes have landed.** Under `sftp -b` a batch
   **aborts on the first failed command and exits 1**, so a `chmod` refused after a `put` reported a
   perfectly good copy as a failure; `sftp`'s `-` prefix fixes it exactly — exit 0, the bytes still
   there, and the refusal **still on stderr**, which is what keeps the loss reportable rather than
   merely swallowed. A step that succeeds prints nothing at all (measured: stderr exactly 0 bytes),
   so the ordinary transfer is untouched. The same hazard over FTP is worse: a quote command sent
   alongside the transfer is refused as `curl` **exit 21** *after* the upload, and `curl`'s
   continue-on-failure prefix avoids that only by destroying the attribution — `%{http_code}` reports
   the **last** reply, so a refused `SITE CHMOD` behind a good `MFMT` is invisible. Hence FTP's steps
   run in one invocation of their own, where reply **500** (a verb this server lacks, so latch it)
   and **550** (that file's problem, so do not) separate cleanly. `curl`'s prefix order is its own
   trap and fails silently: `*-CMD` sends the literal `-SITE …` **before** the transfer, is answered
   500, and still exits 0 — the mode never applied, on a run reporting complete success.
   **A metadata refusal must never be read as the transfer's failure**, which is the bug the split
   (`SFTPMetadataStderr`) exists for: `detect(stderr:)` scans the whole stream for `permission
   denied` and `no such file` first, so a refused `chmod` turned a completed copy into
   `.permissionDenied`. It has a family in **each** direction, both read out of `/usr/bin/sftp`
   rather than guessed — `remote setstat "…"` from `put -p`/`chmod`, and `local chmod` / `local set
   times` from `get -p`, the latter equally able to make a finished download classify as denied.
   **The capabilities describe the *destination*, not the wire.** A download lands on this machine,
   where `chmod` and `utimes` always work, so it carries everything the hint holds even on a
   connection whose server has refused to keep anything — reading the wire's limits into that
   direction would drop a time the disk was perfectly able to take and blame the protocol for it.
   That asymmetry is also what makes both directions **free**: the hint (`CopySourceHint`) comes from
   the listing `CopyEngine` already made, where asking would be a whole connection — 71 ms against a
   loopback `sshd`, a real handshake over a network.
   Controlled in five directions, each failing only the tests that name it: the corrective `chmod`
   dropped, a download reading the wire's capabilities, latching a refusal `curl` cannot attribute,
   a transport's declared capabilities defaulting to SFTP's rather than to nothing, and a refusal
   recorded as no loss at all. Two of the controls were **inert on first writing** and that is the
   finding worth keeping: `.ftp` and `.localDestination` happen to be the same set, so the download
   test discriminated nothing until the connection was latched first; and the fake *declares* its
   capabilities, so it shadows the protocol default the test was aimed at.
   **Verified live end to end**, through the real `SFTPProcessTransport` and `FTPCurlTransport`
   rather than any double: a set-uid source landed **04755** with its exact mtime, an FTP upload
   landed **0754** with an exact `MFMT` time, and a `chmod` at a path that is not there came back as
   an *answer* rather than a thrown failure. The controls are what make that evidence — with the
   corrective `chmod` removed the same server reports **0755**, and with FTP's step invocation
   removed the mode is the umask's and the time is the moment the upload ran.
   Two limits of the read-back were paid for in wrong assertions first, and both are the *listing's*
   rather than the carry's: `ls -la` drops the time of day for a file older than about six months, so
   a 2018 fixture failed by exactly its own time of day; and an FTP `LIST` stamp is zone-less on the
   server's clock, so the same assertion failed by exactly this machine's +0300.
   **What is deliberately not here is the sentence a user reads.** The loss is accumulated per
   connection (`RemoteMetadataSupport.loss`, aspects and a count) and nothing on screen consults it
   yet: where it belongs — a status line, the operation report, Get Info — is a surface decision that
   travels with Slice 5's Get Info write half rather than one to settle in the transports. A draining
   `takeLoss()` was written alongside the accumulator and deleted, because the run boundary it marked
   is the reporting caller's to define and this repo has paid before for API justified by a reader
   that does not exist.
3. **Server-side `copy`.** A duplicate inside one SFTP account stops being a download and an upload
   through this Mac, latched per connection on the client's own refusal, with `RelayCopy` unchanged
   beneath it. `RelayCopy`'s doc comment and docs/NOTES.md both said no remote protocol has a copy
   verb; this slice is where that correction lands in the code rather than only in the notes.
4. **Symlink targets over the exec channel**, degrading exactly as M22's search walk does, so a
   link is copied faithfully on an account that has one and goes on being refused on an account
   that does not.
5. **Get Info's write half**, on the verbs slices 1–2 establish, **the sentence that says what a
   copy could not keep** — Slice 2 accumulates the loss and leaves choosing its surface here — and
   **Synchronize by size** — the
   comparison that is honest on a side with no exact clock, which comparing by *contents* now
   joins, since M24 Slice 4 taught ⌥F3 to fetch both sides at a price the plan can state up front.

#### Smaller than a milestone

Each of these is one remaining cell in [docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md), too
small to be a slice of either milestone above and too real to leave unwritten:

- **An archive pane does not notice its own file changing.** `startWatching` returns early for any
  backend but `.local`, so a browsed `.zip` re-reads only when something asks it to. The decision is
  already made and tested — `ArchiveIdentity` compares device, inode, size and mtime — so this is an
  FSEvents stream on the archive file, not a rule.
- **A favorite pointing at a remote folder does not survive a launch.** A `FavoriteEntry` carries a
  `VFSPath`, whose `VFSBackendID` says nothing about the auth method — which is precisely the gap
  `PersistedTab` closed by carrying a `StoredServerEndpoint`. Same fix, one type along, and it is
  what would make the Favorites row as reconnectable as the Servers section.
- **Size bars are local-only for a cost reason that covers only half of what it gates.**
  `areSizeBarsVisible` requires `.local` because a bar needs *every* sibling's total, which remotely
  is N bounded walks where the cursor's own total is one — and that argument does not apply to an
  **archive**, whose whole table of contents is already in hand. The per-file half already works
  remotely under `DirectorySizeBudget.remote`, so what is missing is a budget for the set.
- **FTP has no server-side walk.** SFTP got one at M22 through the exec channel and S3 through a
  delimiter-less listing; FTP has neither, so its search is one `LIST` per directory. `curl` reuses
  one connection across many `ftp://` URLs, which is the shape worth measuring — and worth far less
  than it looks now that `ProcessWaiting` no longer taxes every child ~71 ms.
- **No multipart upload over SFTP or FTP.** S3 splits a large upload into parts that fail and retry
  independently; the other two send one stream, so a transfer that dies late resumes from wherever
  `put -a` or `curl -C -` can pick it up rather than from a part boundary.
- **An archive rewrite is not undoable.** Deleting a member rewrites the container, and the journal
  has nowhere to put the bytes that left. Reversing it means keeping them, which is a storage
  decision rather than a missing hook.

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
| M23's private pasteboard type becomes a *second* definition of what a transfer is — its own idea of what may land where, drifting from the one F5 already enforces | The payload carries **locations, not policy**: every read ends in the same `submitTransfer` → `FileOperation` → `CopyEngine` path F5/F6 use, under the same conflict prompter, and the admission rules it does own (no-op, recursion) are the ones that were *already* duplicated by hand in two places and got the backend wrong in both. The tell that the boundary is going is a paste or a drop growing a branch that F5 does not have — a second conflict policy, a second "can this land here" gate, a second refusal message. The gate is `acceptsUploads`, which `beginTransfer` already reads, and it must stay the one spelling. **Held through the milestone, and the pressure was real in both directions.** The gate widened once, to `receivesFiles`, and it widened *for F5 as well* rather than beside it — an S3 account pane says `.write` while a file has nowhere to go in it. Three admission rules moved **out** of the gestures into the tested `TransferAdmission` rather than being restated (recursion, volumes, and Slice 5's copy-only), each because it already had two hand-written spellings or was about to; and Slice 5 pulled the *extraction* out of F5 (`extractArchiveSources`) instead of teaching ⌘V a second way out of an archive, which is the same fork this file records for `editRoute(for:)`. The one refusal the paste path owns that F5 does not is dropping an archive member from a **move**, and it is the same rule `moveToOtherPane` enforces by returning — stated once, in the core, and read by both (HISTORY.md §M23 ▸ What the risk row asked) |
| The tree becomes a *second* pane implementation by accretion — a refresh path, a mark gesture or a sort that quietly forks from the flat one | The tree is a flat projection over the same `NSTableView` and the same index space, not a parallel surface (HISTORY.md §M15 Slice 4); anything that forks is a signal the projection is wrong, not that the tree needs its own copy. Both fork points were answered in the slice — `SizeVisualization`'s per-directory assumption (the bars were withdrawn in tree mode at M15 close, then re-scoped *per parent directory* rather than forked — `SizeVisualization(tree:)` groups each row against its own level, so the projection stays one definition of "share of this folder") and the `installSortedModel` → `reloadEverything` → `syncCursorToTable` tail. It arrived once already, as the *second index space*: six `panel.model[row]` sites that crashed on the first click below the root's last entry, now routed through `displayedIndex(ofID:)` — NOTES.md ▸ AppKit |
| M24 turns "fetch it first" into a download nobody asked for. Seven gestures gain the right to pull bytes over a network, and each one is a keystroke that used to be free | The rule is stated once and belongs to the **gesture**, never to the engine: `ByteComparator` refuses an evicted cloud placeholder rather than reading through it, and every engine reached here keeps that posture — it sees only files already on this disk, and the gesture is what fetches and what reports. The tell that the boundary is going is an *engine* learning to materialize, or a second threshold table appearing beside `RemoteFetchPolicy`'s. What makes it enforceable rather than a wish is that the size decision is already a named table keyed by `RemoteFetchPurpose`, so a new gesture is a row in it — and a purpose whose `isAutomatic` is true may never raise a dialog, which is the fork M21 Slice 10 settled and the bug a user reported when it was got wrong |
| M25 writes attributes to a server through verbs that vary per account, and reports success it did not have. `sftp`'s `-p`, `chmod`, `copy` and the `readlink` behind a symlink target are each present on some accounts and absent on others — `ForceCommand internal-sftp` alone removes the exec channel | Degrade **per connection at run time**, the shape M22's search walk already proved: the account is asked once, the answer is remembered for that connection, and what cannot be carried is *not* carried rather than approximated. The failure to design against is the quiet one — writing an empty symlink because no target could be read, or reporting a preserved mode that was silently dropped — so the milestone opens with probes against a real `sshd` rather than with a man page, and a capability that cannot be established leaves the old behaviour standing. The corollary is that this milestone owes docs/NOTES.md a **correction** rather than only an entry: "neither remote protocol has a copy verb" is written down twice, and `sftp copy` exists |

## 7. Open questions

**Open now: one, and M25 does not start on its half of it before it is answered.**

- **Whether Dirnex should invent a Trash the protocol does not have.** Every remote delete is
  permanent, because `VFSCapabilities.deleteStrategy` degrades to `.permanent` wherever `.trash` is
  absent and no remote backend has one; a confirmation dialog is what stands in for it today. The
  fork is whether that stays the answer, or whether F8 on a server renames into a managed
  `.dirnex-trash/` prefix with a sidecar naming the origin — the shape a trash folder's `.DS_Store`
  already carries as its `ptbL`/`ptbN` pair, one layer out. It buys the one safety net remote
  browsing has never had, and it costs three things worth stating before rather than after. It is a
  **format** other software will meet: a stranger's FTP client, or the account's owner on the web
  console, sees a folder of renamed junk and no explanation, so the layout outlives our code the way
  M19's cipher choice does. Its price is not uniform — a rename is one cheap verb over SFTP and FTP
  and is **N copies plus N deletes** on S3, so "delete" there would move the whole prefix twice and
  a large one is a bill rather than a safety net. And the sidecar is a second source of truth that
  can drift from the files beside it, which is the failure the `.DS_Store` origin records already
  have and survive only because Finder writes them too. The alternative — leave it permanent, keep
  the confirmation, and say plainly in the dialog that there is nothing to undo — is honest and
  costs nothing, which is why this is a question and not a slice.

M19's two were taken at open and M18's one likewise (both below); M15's two
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
