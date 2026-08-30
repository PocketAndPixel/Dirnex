# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: **M0–M25 shipped** (14 languages) · Created: 2026-07-05 ·
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

### Shipped: M0 → M25 (2026-07-05 → 2026-08-29)

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
| M24 | Every local-only feature, on a file that is not local | 08-28 | **Content-grep and tag search on a server**, withheld at M22 for the reason that has not changed — no remote backend can answer either without reading every file; **ACLs and extended attributes remotely**, which SFTP and FTP do not carry at all; **Open in Terminal for an SFTP account**, which is an `ssh` session and a different feature; and a **folder that is not already here**, refused by every one of the seven hand-offs — a folder is an unknown number of objects in an unknown number of requests, and copying a tree out is F5's job |
| M25 | What a remote write carries, and what a remote delete costs | 08-29 | **A Trash the protocols do not have** — taken at §7 on 08-29, and the one part of the milestone that closed by not being built; **owner and group in a remote Get Info**, because `chown`/`chgrp` take a numeric id while `sftp`'s own `ls -la` prints names, so a panel built on a listing has nothing to send; **comparing by timestamp on FTP and S3**, refused by construction and always will be — `LIST` is year-less and zone-less, and an S3 `LastModified` is when the object was *written*; and ACLs and xattrs again, which is a limit rather than a gap |

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

What is still open, rather than merely imaginable, is the *undone* column above, the short list
of cells below that were too small to be a slice of M24 or M25 — which is all that is left of
[docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md)'s parity backlog — plus one item:

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

### Closed: M24 and M25 — the parity backlog (2026-08-27 → 08-29)

[docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md) used to rank what still feels unlike local at
the bottom of its own tables. It ranks nothing now, and the two milestones that closed the ranked
half of it are archived in [docs/HISTORY.md](docs/HISTORY.md): **M24** took the seven features that
refused anything not on this disk — Open With, Share, Compare By Contents, checksums, user scripts,
⌥F5 pack and Get Info — and made each of them a question about a *file* rather than about a disk,
on one shared `MaterializationPlan` that says up front what a gesture will cost. **M25** took what a
remote write quietly did *less* of: a copy now carries the mode and both timestamps as far as the
account allows and **says what it could not keep**, a duplicate inside one SFTP account is a
server-side `copy` rather than a round trip through this Mac, Get Info's fields are editable
remotely, and Synchronize compares by size or by contents on a side with no exact clock. M25's third
part closed the other way: a Trash the protocols do not have is **not** invented (§7).

What is left is the short list below — cells too small to have been a slice of either — plus the
*undone* column in the table above.

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
- **A remote attribute change cannot be undone.** M25 Slice 5a writes a mode over SFTP and a mode
  and a time over FTP, and the panel says plainly that ⌘Z will not reverse it: `restoreAttributes`
  applies through `FileAttributeIO` — local syscalls — and `RemoteAttributesController` records no
  undo at all, where the local panel hands one to the window. Closing it is a journal step that
  writes back through the backend's own `applyMetadata`, so it is a pair of small pieces rather than
  a hook that already exists.
- **Many remote write-backs do not coordinate.** A user script that rewrites forty files on a server
  produces forty independent uploads, each re-`stat`ing and uploading on its own the way F4's single
  save does — no combined bar, no Stop, no ordering. M24 Slice 2 (HISTORY.md) gave the *download*
  direction exactly that shape (`FileOperation.Kind.materialize`), so this is the mirror of a job
  that already exists rather than a new one: M24 Slice 5 handed it to M25, M25 took no slice for it,
  and it was demoted here on 2026-08-30, because one queue kind is not a milestone's worth of design.

### Open: M26 — Move to Trash, wherever the file lives (2026-08-31)

**F8 does nothing for any file inside a File Provider domain** — Dropbox, OneDrive, Box, Google
Drive and iCloud Drive alike — and reports *"Couldn't move “x” to the Trash · You don't have
permission. Dirnex may need Full Disk Access in System Settings."* Reported by a user 2026-08-30,
present since those mounts became browsable, and the sentence is the worst part: Full Disk Access is
granted, is *correct*, and toggling it does nothing, so the report reads as the app being confused
about a permission the user can see is switched on.

**It is not a permission the app lacks, and the probe that says so is the whole finding.** At the
instant `FileManager.trashItem` throws — `NSCocoaErrorDomain` **513**, with **no underlying POSIX
errno**, so nothing beneath it refused anything — the same process was asked what it could actually
do with that file:

```
[trashItem]             NSCocoaErrorDomain 513   under=nil
[read ~/.Trash]         OK  3 entries
[open O_RDONLY]         OK
[rename in place]       OK
[rename into ~/.Trash]  OK
[stat]                  OK
```

It can perform the very move `trashItem` claims it may not. So `FileManager` is declining on its
own, and no grant the user can reach changes it: `tccutil reset FileProviderDomain com.dirnex.Dirnex`
removed every per-provider row and nothing changed, macOS never prompts, and no TCC service is
consulted during the call at all.

**What decides it is how the app was launched, which is why it survived every pass.** Same binary,
same Developer ID signature, back to back: launched from a shell it trashes fine (**2/2**), launched
by LaunchServices — the Dock, Finder, `open` — it fails (**2/2**). A shell-launched app inherits the
launching process as its TCC *responsible* process, so a developer running from a terminal borrows
that process's Full Disk Access and sees a working feature. Every automated signal is clean, both
suites and both linters are green, the pane lists the folder perfectly, and only pressing F8 from a
normally launched app shows it. The same trap wasted the first two diagnoses of this bug (▸
docs/NOTES.md), which is the reason it is written down here rather than only in the fix.

**`NSWorkspace.recycle` is *not* the answer, and the run that said it was is the lesson.** It was
measured succeeding in the failing context on all five domains — and that measurement was
contaminated by the diagnostic probe sitting a few lines above it, which had renamed each item out
to `~/.Trash` and straight back before `recycle` was asked. Implemented for real, with no probe in
front of it, `recycle` fails with the byte-identical `NSCocoaErrorDomain` 513 — it wraps the same
`trashItem` refusal. Re-adding the bounce as a control flips it back to succeeding, 1/1 each way.
The probe had **detached the item from its provider**, so what was being measured was a trash of an
ordinary file. This is docs/NOTES.md's own rule about a probe's actions being part of the experiment,
met for the third time in one investigation.

**What is established, and what is not.** Established: the refusal is exact and reproducible; it
covers every File Provider domain and nothing else; it follows the TCC *responsible* process, not
the app's own grants; and the process is not missing any file permission — at the instant of the
throw the same process can `open` the item, `rename` it in place, `rename` it into `~/.Trash`, and
read `~/.Trash`. **Full Disk Access is effective in both cases and is not the gate** — the failing
LaunchServices-launched process read the system TCC database and `~/Library/Mail`, both FDA-only,
in the same call that was refused. Three candidate mechanisms have been measured and eliminated:
the per-provider `kTCCServiceFileProviderDomain` grants (resetting them changes nothing, and macOS
never prompts), Full Disk Access (above), and `kTCCServiceSystemPolicyAppData`'s odd `auth_value 5`
(shared with the process that *succeeds*). Not established: which policy actually denies, and
therefore whether any grant the user can reach would fix it.

So the milestone was **open on its design**, not on its implementation. Put to the user on
2026-08-31, the fork below was resolved as **route by domain, one performer** — the first option,
with `trashItem` kept wherever `trashItem` works, so the regression it costs falls only on the items
that were already broken:

- **Perform the move ourselves.** A plain `rename` into the right trash is measured working from the
  failing process, so this cannot be refused. It costs Finder parity: the collision-safe naming and,
  more seriously, the `ptbL`/`ptbN` **Put Back** record, which this package can read (`DSStoreReader`)
  and cannot write. Trading "delete does not work at all" for "delete works, Put Back does not" is a
  real improvement and a real regression, and which one is a person's call.
- **Ask Finder**, whose own delete succeeds on these files. That is an Apple event, so it needs the
  Automation grant and Finder running, and it makes the most ordinary gesture in the app depend on
  another process.
- **Keep looking for the grant**, which is the only route that ends with the platform doing this
  properly — and the three cheapest candidates are already eliminated.

**The design is one path, not a fallback.** `NSWorkspace` and any Apple event are AppKit, and
`LocalBackend.trashItem` is headless core, so whichever route wins takes the seam the project already
uses for `bsdtar` and `sftp`: the core keeps the decision (the already-in-a-trash refusal, the
Trash-less-volume refusal ``trashFailure`` reads, the landing path a `Restoration` needs) and an
injected performer does the byte-touching. Keeping a second route alive as a fallback is rejected at
open: two paths differing only by which one macOS happens to refuse is exactly the shape this
codebase keeps paying for.

- **Slice 1 — core.** ``TrashPerformer``, a one-method seam returning where the item landed; the
  `alreadyInTrash` guard and ``trashFailure`` stay where they are; tests drive a fake.
  **Landed 2026-08-31**, and it is the half that holds whichever way the fork above goes: every
  candidate performer plugs in here, and the suite already pins that both refusals the backend owns
  survive the seam (negative control: neutering it fails 4 of the 5 tests, and correctly leaves the
  already-in-a-trash one green, since that never reaches a performer either way).
- **Slice 2 — the performer that works. Landed 2026-08-31.** ``ProviderAwareTrashPerformer``:
  `FileManager.trashItem` for an ordinary item, and the rename macOS would have made for one inside a
  domain. It is **core, not app** — nothing in the answer is AppKit, so §2 puts it with the bytes it
  touches, and it is `LocalBackend`'s default rather than something the app injects, so the fix
  reaches every caller without one of them having to remember. `WorkspaceTrashPerformer` was written,
  live-tested and **removed** before this: it is not a fix, and leaving it would have been a second
  route that fails exactly where the first one does.
  - **Every part of it was measured against the five live domains before any Swift was written**, and
    two of the measurements overturned the design the slice opened on. The destination is **not**
    `~/.Trash`: renaming an evicted placeholder out of its domain **materializes it** — a 4 MB iCloud
    file took 1.15 s and arrived with blocks — where the rename into the provider's own trash took
    **0.001 s and left it dataless**, exactly as `trashItem` does. On a 14 GB placeholder that is the
    download-nobody-asked-for the M24 risk row names, arriving inside a delete. And the destination
    cannot be tabulated per provider (docs/NOTES.md is emphatic that a real delete is the only thing
    that answers), so it is **asked of Foundation and then verified with a `stat`** — the pair agrees
    with `trashItem`'s own destination on all five domains plus both controls, where the lookup alone
    disagrees on two and names a `.Trash` for Box and OneDrive that does not exist.
  - **`renamex_np` with `RENAME_EXCL`, never `rename`**, which replaces its destination silently and
    would destroy the copy the user had already thrown away. The collision name reproduces
    `trashItem`'s own measured format, because a Trash holding items Dirnex named one way and Finder
    another is a surface the user reads.
  - **Verified live with a control, which is the only instrument this bug has**: the same script,
    LaunchServices-launched, across all five domains — **5 of 5 deleted** with the fix and **0 of 5**
    with `LocalBackend`'s default reverted, the files landing in exactly the trashes the table
    predicts. What ⌘Z does is unaffected either way: `DeletePass.Restoration` rides the landing path,
    not Finder's record.
  - What it costs is **Finder's `ptbL`/`ptbN` Put Back for a provider item only** — this package can
    read those records and cannot write them. An ordinary delete is byte-for-byte what it always was.
    Slice 4 takes that cost back for Dirnex's own deletes, from the origin the delete already knew.
- **Slice 3 — the sentence. Landed 2026-08-31**, re-taken rather than executed as written, and the
  re-take moved it off "over a refusal nobody has yet seen in the wild": **it is reachable today, in
  one keystroke.** A Google Drive mount root is `dr-x------` — measured on both live Drive accounts,
  where creating a file answers `EACCES` — so every refusal it hands back arrives as
  `EACCES` → `.permissionDenied` → the sentence that cost a user an evening, on the *new* route.
  The 513 refusal is indeed gone (a provider item no longer goes near `trashItem`); what replaced it
  reaches the same wrong words by a different door.
  - **The fix is the M21 split arriving on a path that is on this Mac.** `VFSErrorText` already asks
    `path.backend.isRemoteConnection`, because "Dirnex may need Full Disk Access" is a claim about
    *where* the failure happened. A `CloudStorage` mount is an ordinary local path with an ordinary
    local backend, so that test cannot see it — and Full Disk Access does not gate that tree, so the
    advice names a switch that is already on and could not help if it were off.
    ``CloudStorageMounts/isInsideCloudStorage(_:home:)`` is the predicate: pure, no I/O, free to ask
    on an error path, and living beside the root and the not-TCC-gated fact it rests on.
  - **The narrowness is the whole design, and the two provider roots are opposites for this
    question.** `~/Library/Mobile Documents` **is** TCC-gated, so Full Disk Access is exactly right
    for an iCloud path — which is why the branch names `CloudStorage` alone rather than reusing
    ``TrashLanding/providerRoots``, whose two entries are twins for the trash route. One pair of
    roots, two questions, and only a name keeps them from being merged.
  - **Both controls run, and they fail on disjoint tests**, which is what makes the seven green ones
    evidence: disabling the branch fails the two fix tests with the reporter's own sentence verbatim
    and leaves all five narrowness tests green; widening it to both provider roots — the "stop saying
    it inside a provider domain" version this slice was originally written as — fails *only* the
    iCloud test, taking the correct advice away with the wrong one. The assertions are
    language-independent (which sentences match, not what they say), since the app test target
    inherits the developer's own `AppleLanguages` pin; the English wording is checked behind a guard.
  - The new sentence is translated into all fourteen languages in the same pass, so it cannot join
    the class docs/NOTES.md documents where a wrapped-but-uncatalogued key compiles to itself.
    Note `scripts/check_localization_keys.py` **already failed on five strings from the pack work**
    (`Pack…`, `Packing…`, `Pack %@`, `Packing %@`, `Couldn't create the archive "%@"`), absent from
    the catalog on HEAD and untouched by this slice — a separate gap, in separate files, and it took
    its own pass: the five landed in all fourteen languages immediately afterwards, and the script
    now reads **970 extracted keys, all present in the catalogs**.
- **Verified end to end in the app, 2026-08-31**, which is the half Slice 2's script could not
  reach: the same five domains driven through the *shipped* F8 — `reveal` then
  `run operation "file.trash"` over the AppleScript verbs — against a LaunchServices-launched build,
  since a shell-launched one borrows the terminal's grant and passes either way. **6 of 6 deleted**
  with the fix, each landing in exactly the trash the table above predicts, including the two that
  are not the obvious answer (Drive streaming → `<mount>/.Trash`, iCloud →
  `~/Library/Mobile Documents/.Trash`). With `LocalBackend`'s default reverted to
  `FileManagerTrashPerformer`, **1 of 6** — and *which* one is the whole value of the run:
  **mirror-mode Google Drive still deleted in both directions**, because `~/My Drive` is an ordinary
  local file outside every domain, so it takes `trashItem` either way and keeps Finder's Put Back.
  A control that failed there too would have been measuring a broken app or a bad path rather than
  the routing; passing in both directions is what makes the other five a measurement of exactly the
  provider branch and nothing wider. No confirmation sheet stands in the way — `confirmTrash`
  defaults off — so the whole gesture is drivable headlessly, which is what makes this repeatable
  rather than a one-off screenshot.
- **Slice 4 — Put Back for a provider delete. Planned**, and it is the one regression this milestone
  knowingly introduced: `trashItem` writes Finder's `ptbL`/`ptbN` pair and the rename that replaces
  it cannot, so an item Dirnex trashed out of a domain lands correctly and then has no way home.
  ⌘Z is *not* the gap — `DeletePass.Restoration` rides the landing path and undo works — but the
  journal is a session-scoped stack, where Put Back is the gesture for an item sitting in the Trash
  a week later.
  - **The data already exists at the moment of the delete, which is what makes this a store and a
    read rather than a measurement.** `DeletePass.run` already builds
    `Restoration(original:trashed:)` — origin and landing — for *every* trashed item, because ⌘Z
    needed it; and `TrashPutBack.origins(inDSStore:ofTrashAt:)` already hands the app a
    `[String: TrashOrigin]` keyed by the filename **as it appears in that trash**, which the restore
    flow matches a listing into. So the slice is a durable record in that same shape and a merge at
    the one call site that reads it. Nothing in `TrashPerformer` changes.
  - **Finder's record wins wherever it exists, and the store is only ever consulted for what it does
    not cover.** An ordinary local delete still goes through `trashItem`, which writes the pair — so
    the common case must keep answering from the `.DS_Store` and not from us, or Dirnex's Put Back
    and Finder's own could send the same file to two different folders. That is the merge rule and
    it is the whole correctness argument: a second source of truth for a question already answered
    is the shape this codebase keeps paying for, so this one answers only where the first is silent.
  - **Key on the full landing path, not the filename.** `origins` is keyed per trash directory
    because a `.DS_Store` only ever describes its own; the merged Trash spans `~/.Trash`, every
    volume's, iCloud's and every provider mount's at once, and two of them can hold the same name.
  - **It must respect ``VaultPrivacy``, which is the reason this is not simply "record every
    delete".** A record pairs a file's name with the folder it came from and outlives both — exactly
    the *implicit* memory M19 §6 keeps vault paths out of, and a file deleted from inside a mounted
    vault would otherwise leave its name and its origin in a plain store outside the vault. The
    frecency index and session restore already have this rule; a third store needs it before it
    ships, not after.
  - **Records go stale and that is tolerable; unbounded growth is not.** Finder's own outlive their
    files by weeks (measured — the probe machine's `~/.Trash` still listed records for files long
    gone), so `origins` is deliberately a *superset* the caller matches into, and ours may be too.
    What it may not be is permanent: drop an entry whose landing path no longer exists, on the read
    that is already enumerating those trashes anyway.
  - **The bonus worth naming is iCloud, which M9 left undone for a reason this route sidesteps.**
    Put Back inside `~/Library/Mobile Documents/.Trash` has never worked for anybody: that trash
    keeps no `.DS_Store` at all, and the origin rides on the item as
    `com.apple.clouddocs.private.trash-parent-bookmark`, an opaque provider reference with no path
    in it. A record Dirnex wrote itself needs none of that — so this closes M9's gap for **Dirnex's
    own** deletes, without touching the reason it is still open for Finder's.
  - **What it still cannot do, and must not claim**: an item **Finder** deleted out of a provider
    domain — on Box that does not land on this Mac at all, it goes to Box's server-side trash — and
    anything trashed before the store shipped. Both keep today's honest answer, which the restore
    flow already gives by name rather than by guessing at a folder.
  - The controls the slice owes: without the store a provider item still reports that its origin is
    unknown (today's behaviour, so the fix must be what changes it); with the store allowed to
    *override* a `.DS_Store` record, an ordinary local item restores to the wrong folder — which is
    the narrowness half, and the one that keeps the merge rule from quietly inverting.

Left deliberately undone: **the remote backends**, which have no Trash at all and are already
degraded to a confirmed permanent delete (§M5, and M25 §7's decision not to invent one); **any
workaround inside F8 while this is open**, since ⇧F8's confirmed permanent delete already works — it uses
`removeItem` and consults no Trash, so it is unaffected; and **chasing the refusal further into TCC
and `fileproviderd`**, which is not observable from here past the three candidates already
eliminated, and which the two implementable routes above do not depend on.

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
| M24 turns "fetch it first" into a download nobody asked for. Seven gestures gain the right to pull bytes over a network, and each one is a keystroke that used to be free | The rule is stated once and belongs to the **gesture**, never to the engine: `ByteComparator` refuses an evicted cloud placeholder rather than reading through it, and every engine reached here keeps that posture — it sees only files already on this disk, and the gesture is what fetches and what reports. The tell that the boundary is going is an *engine* learning to materialize, or a second threshold table appearing beside `RemoteFetchPolicy`'s. What makes it enforceable rather than a wish is that the size decision is already a named table keyed by `RemoteFetchPurpose`, so a new gesture is a row in it — and a purpose whose `isAutomatic` is true may never raise a dialog, which is the fork M21 Slice 10 settled and the bug a user reported when it was got wrong. **Held (closed 2026-08-28).** No engine learned to materialize: `ByteComparator` still refuses an evicted placeholder, every fetch runs through the one `MaterializationPlan` the gesture builds, and `RemoteFetchPurpose` grew **rows** — `handOff`, `compare`, `syncContents`, `checksum`, `userScript`, `pack` — rather than the second threshold table the row names as the tell. The unbounded case is refused rather than weighed: a folder that is not already here is turned away by name in each hand-off, because it stands for an unknown number of requests |
| M25 writes attributes to a server through verbs that vary per account, and reports success it did not have. `sftp`'s `-p`, `chmod`, `copy` and the `readlink` behind a symlink target are each present on some accounts and absent on others — `ForceCommand internal-sftp` alone removes the exec channel | Degrade **per connection at run time**, the shape M22's search walk already proved: the account is asked once, the answer is remembered for that connection, and what cannot be carried is *not* carried rather than approximated. The failure to design against is the quiet one — writing an empty symlink because no target could be read, or reporting a preserved mode that was silently dropped — so the milestone opens with probes against a real `sshd` rather than with a man page, and a capability that cannot be established leaves the old behaviour standing. The corollary is that this milestone owes docs/NOTES.md a **correction** rather than only an entry: "neither remote protocol has a copy verb" is written down twice, and `sftp copy` exists. **Held (closed 2026-08-29).** Every capability is latched per connection and none is asked in advance; a refusal is *reported* rather than approximated (`RemoteMetadataPlan` names what a transfer will lose, and the status line says it), and the quiet failure the row names was found to be worse than described — `CopyEngine.swift:283` now refuses a symlink whose target could not be read, because `ln -s ""` is a dangling link over SFTP and an **`NSInvalidArgumentException` that terminates the process** on a download. The correction was made: NOTES.md records `copy-data revision 1`, measured at 64 MiB in 0.08 s |

## 7. Open questions

**None open.** M25's was the last, and it closed on 2026-08-29.

Opened with M25 (2026-08-27) and **closed by the user (2026-08-29)**:

- **Whether Dirnex should invent a Trash the protocol does not have** — resolved: **no.** A remote
  delete stays permanent, the confirmation is what stands in for the Trash, and the alert says in as
  many words that there is nothing to undo. The alternative was a managed `.dirnex-trash/` prefix, a
  rename into it, and a sidecar naming the origin the way a trash folder's `.DS_Store` carries its
  `ptbL`/`ptbN` pair — the one safety net remote browsing has never had, at three prices.
  **The one that decided it is that the price is not uniform**: a rename is one cheap verb over SFTP
  and FTP and is **N copies plus N deletes** on S3, so a delete on a bucket would stop being N
  deletes and become a billed movement of every byte under the prefix. Offering it only where it is
  cheap is the worse half of that fork rather than the escape from it — a Trash that exists on some
  backends and not others is a promise the user cannot carry from one pane to the next, and the pane
  looks identical either way. The other two prices stand and are why this was a question rather than
  a slice: it is a **format** other software meets — a stranger's FTP client, or the account's owner
  on the web console, sees a folder of renamed junk and no explanation, so the layout outlives our
  code the way M19's cipher choice does — and the sidecar is a second source of truth that can drift
  from the files beside it, which the `.DS_Store` origin records survive only because Finder writes
  them too.
  - What the answer costs is **nothing to build**, which is what makes it the honest answer rather
    than merely the cheap one: `deleteStrategy` already degrades to `.permanent` wherever `.trash`
    is absent, so F8 on a server already raises `confirmPermanentDelete`'s critical alert reading
    *Delete “x” permanently?* over *This can’t be undone.*, and `runDelete` already journals
    nothing on that branch. The decision is to keep saying the true thing rather than to build a
    safety net that is true on two backends of three.
  - **Reopening is not symmetric with having taken it**, which is the reason to write it down:
    staying permanent stays reopenable, while the format, once anyone's files are sitting in it,
    cannot be withdrawn from accounts Dirnex does not own. docs/LOCATION-SUPPORT.md therefore
    carries this as a **limit** rather than a gap — the `F8 → Trash` row is `n/a` in every remote
    column, and footnote `p` names the decision.

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
