# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: **M0–M36 shipped**, **M37–M40 planned** (14 languages; M29's licensing is on in betas, off in stable until the
store opens; M30's Report a Bug is in every release built while `DIRNEX_BUG_REPORT_URL` is set) ·
Created: 2026-07-05 ·
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
  (iCloud/Dropbox folders work as folders; no proprietary APIs). **One exception, taken
  2026-09-13: iCloud Photos through Apple's PhotoKit (§M28)**, because the Photos library exposes no
  browsable filesystem at all — without the API there is nothing to show.

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

### Shipped: M0 → M36 (2026-07-05 → 2026-11-08)

Every milestone is closed. The checklists and the full per-pass progress log — what was probed,
decided, and rejected — live in **[docs/HISTORY.md](docs/HISTORY.md)**; source comments citing
`PLAN.md §M5` and the like refer to those sections.

| | Milestone | Landed | Left deliberately undone |
|---|---|---|---|
| M0 | Scaffolding | 07-05 | — |
| M1 | Read-only dual-pane browser | 07-06 | — |
| M2 | Operation engine | 07-07 | Side-by-side text diff in the conflict dialog — **since shipped** 2026-10-22 with M31 Slice 4, as Compare Contents… for two local files whose bytes are here |
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
| M13 | FTP and FTPS | 07-25 | `MLSD` (`curl` cannot send it) — **wrong, and since shipped** 2026-10-19: `curl -X MLSD` works, and it now times every row of a server that answers it, with a per-server time zone for those that do not; FTP-side `DirectorySync` by timestamp (unreliable by construction — LIST stamps are year- and zone-less); write-back for files edited in place over FTP — **since shipped** with M21 Slice 10, which generalized the remote edit path to every backend that accepts uploads; an opportunistic "TLS optional" client mode (a password-downgrade vector — rejected 2026-07-26) |
| M14 | Checksums and attributes | 07-30 (escalation 08-02) | Split/combine files (dropped 2026-07-29 — FAT32's ceiling, floppy/CD spanning and mail limits are all gone on macOS); multi-selection and recursive **privilege escalation** (the flat single-item path proves the mechanism; those sheets refuse a root-only change by name); escalating the *undo* of a non-owned change (still refused with `attributeRestoreNeedsAdministrator`, not escalated) |
| M15 | The tree view, and color the user chooses | 08-02 | The **thumbnail grid, brief view and the `PaneSurface` extraction** (cut 2026-08-02 — the three are one unit, and `FileTableView` is a 25-method contract a grid satisfies none of); a memo in front of `fnmatch` (measured unnecessary — 0.46 ms per full reload for 5 rules); size bars in tree mode, withdrawn at close and re-scoped per parent directory in a follow-up (`SizeVisualization(tree:)`) |
| M16 | Quick View: source or page | 08-06 | Markdown and RTF as dual-style types — markdown was taken up at M18, RTF stays undone — and `.webarchive` / `.mhtml`, which need `loadData` rather than a file load; the JavaScript mark in the *pane*-size preview, which had no header to carry it — **since shipped** 2026-10-14, when ⌃Q took the full-window header |
| M17 | Syntax highlighting in Quick View | 08-06 | A **theme picker** (the colors are a fixed light/dark table, no Settings surface); the constructs a regex-free single pass cannot reach — string interpolation, JS regex literals, heredocs, Swift raw strings, JSX, and semantic coloring of any kind; **line numbers, folding and a minimap**, which are editor features Dirnex hands to the user's own editor; highlighting inside the *rendered* HTML style, which is the page's own business; a **key-vs-value** distinction in JSON, and Markdown's **setext headings** and **indented code blocks**, all three of which need a lookahead or a previous line the single pass does not keep; Ruby's `=begin` block comment; and any third-party highlighter — Highlightr (a JS engine on every cursor step) and tree-sitter (a C dependency plus a grammar per language), both rejected 2026-08-06 |
| M18 | Quick View: Markdown as a document | 08-07 | **Raw HTML passthrough** — CommonMark says to pass it and a preview that renders on *cursor movement* must not, which is also what keeps the generated page inert; **full CommonMark conformance** (the target is what the file's author sees on GitHub for an ordinary document, pinned by a corpus of real files, with an unreadable construct rendering as its literal text); **math and LaTeX, footnotes, definition lists, emoji shortcodes and wiki links**; every mermaid diagram type outside **flowchart and sequence** (a class diagram, gantt, state chart or ER diagram falls back to a code fence naming itself, as does an unsupported construct *inside* a supported type); **following a link to another file**, since turning a preview into a browser needs its own history and its own way out; **RTF**, the other type M16 left in the same sentence — `NSAttributedString`'s job, sharing nothing with a renderer; **rendering as you type** and editing of any kind (§M11's call, unchanged); and **exporting the rendered page** to HTML or PDF, which is a file operation and belongs in the operation engine with a destination and a conflict policy |
| M19 | Encryption | 08-09 | **`zipcrypt` and AES-128** (the first is broken, the second buys nothing on hardware AES — both taken at open); **encryption for any container but zip**, since libarchive's 7-Zip writer refuses it and tar has no notion of it; **a passphrase for the paths that are not F5** — preview and *nested*-archive entry failed with `passphraseRequired` rather than prompting, and the encrypted route extracted the whole archive rather than the requested members, so a member filter plus a per-archive passphrase held for the session was its own slice (the passphrase half **landed 2026-08-09**, user-reported — see HISTORY.md ▸ After M19; the **member filter landed 2026-08-25**, closing the milestone: `ArchiveMemberFilter` skips what nobody asked for, and one member of a 600 MB archive costs 0.001 s against 1.53 s); **encrypting in place**, or any gesture that removes the plaintext afterwards, because that delete belongs to the user with the Trash's own rules in view; and **vault paths in anything the user saved on purpose** — a named workspace or a favorite pointing inside a vault is kept, since §6's rule is about what Dirnex remembers *without being asked* (the derived-data clause itself was closed 08-09 by fixing the frecency index and session restore, not by stating the leak — see HISTORY.md §M19 ▸ Follow-up) |
| M20 | Every place reachable without the sidebar | 08-12 | Individual places as ⌘K palette results (the palette is a registry of *commands*, places are live data — a different mechanism, worth its own decision); reordering or editing places from the menu, which stays the sidebar's job; a Finder-style "Computer" or "Network" destination, which is not a place Dirnex has; and a **Help menu** — Slice 2 claimed Help ▸ Search made "Trash" findable and the app declares no Help menu at all, so adding one is its own decision and was not taken |
| M21 | Amazon S3, and the mounts we already reach | 08-19 | **Atomicity of any kind** — a prefix rename or delete is N copies and N deletes, so stopping partway leaves items under both names, and no layer can make it otherwise; **a byte counter during a server-side copy**, which would cost a round trip per object (~25 min of pure latency on a 50 000-file prefix), so those jobs report items; **`copyMetadata` and `DirectorySync` by timestamp**, since S3 has no settable mtime, no permissions and no symlinks; **a File Provider mount** (Mountain Duck / `rclone mount` territory — a different product with a different lifecycle); **AES-style client-side encryption, versioning, lifecycle rules and storage-class changes**, none of which a file manager's ten verbs have a place for; and **the 200-committed multipart refusal seen from Amazon**, which AWS documents and answers `412` with the code in practice, so it stays pinned against our own SigV4-verifying endpoint |
| M22 | Find Files on a connected server | 08-16 | **Content-grep and tags remotely** — no remote backend can answer either without reading every file, so `SearchFields` withholds them rather than skipping the clause (which would return *more* results under the same name); **an exact remote timestamp**, since FTP's `LIST` stamps are year- and zone-less on the server's clock — **since shipped** over FTP for servers that answer `MLSD` (2026-10-19); **searching an S3 *account* pane**, whose rows are buckets — "search every bucket" is a different and much more expensive question than the one ⌥F7 asks; and GNU `find -printf`, retired at the probe rather than handled, since choosing it would have shipped the common case unverified — POSIX `find … -exec ls -ldn {} +` instead, at the cost of the date column |
| M23 | Copy, paste and drag, wherever the file is | 08-26 | Dragging a *folder* out of a server as a promise (a promise is one file; a recursive fetch behind a Finder drop has no progress surface and no way to stop it) and dragging an archive **member** out to another app, for the same reason one layer along — an encrypted archive would have to raise a passphrase sheet behind somebody else's drop, and `extractArchiveSources` reports failures with an alert rather than through a completion handler, so it would need Slice 4's always-answers contract first (taken by the user 2026-08-26, F5 copy-out being the route); `⌥⌘V` move-paste into an archive, which stays gated where it was; a *drop* into a browsed archive, where ⌘V adds by repacking and a drag does not; and the pasteboard as an automation surface — nothing here is scriptable that F5 was not. **Left for a human**, since a drag *session* cannot be synthesized: an actual drag between two panes and a Finder drag onto a connected server. A drag from a server into Finder **ran live 2026-10-24**, where a marked set dropped nothing until it was fixed (HISTORY.md §M32) |
| M24 | Every local-only feature, on a file that is not local | 08-28 | **Content-grep and tag search on a server**, withheld at M22 for the reason that has not changed — no remote backend can answer either without reading every file; **ACLs and extended attributes remotely**, which SFTP and FTP do not carry at all; **Open in Terminal for an SFTP account**, which is an `ssh` session and a different feature; and a **folder that is not already here**, refused by every one of the seven hand-offs — a folder is an unknown number of objects in an unknown number of requests, and copying a tree out is F5's job |
| M25 | What a remote write carries, and what a remote delete costs | 08-29 | **A Trash the protocols do not have** — taken at §7 on 08-29, and the one part of the milestone that closed by not being built; **owner and group in a remote Get Info**, because `chown`/`chgrp` take a numeric id while `sftp`'s own `ls -la` prints names, so a panel built on a listing has nothing to send; **comparing by timestamp on FTP and S3**, refused by construction and always will be — `LIST` is year-less and zone-less, and an S3 `LastModified` is when the object was *written*; and ACLs and xattrs again, which is a limit rather than a gap |
| M26 | Move to Trash, wherever the file lives | 08-31 | **The remote backends**, which have no Trash at all and are already degraded to a confirmed permanent delete (§M5, and M25 §7's decision not to invent one); **chasing the refusal further into TCC and `fileproviderd`**, which is not observable from here past the three candidates already eliminated — the fix does not depend on knowing which policy denies; and **Put Back for an item *Finder* deleted out of a provider domain**, or for anything trashed before the store shipped, both of which keep the honest answer the restore flow already gives by name. A **third** origin source landed 2026-09-20 — a network share's own `#recycle`, where the bin mirrors the original path so there is no record to be missing (HISTORY.md ▸ the follow-on log) |
| M27 | Legacy code-page archive names | 09-09 | **Inferring** the code page — no reader can, and a wrong guess is a plausible name for the wrong file, so it is a chooser over a preview and never a detector; **preserving an un-representable name byte-for-byte**, the rejected streaming rewrite, which keeps bytes nobody can read and still cannot extract that row *out* of the archive; and **persisting the declaration** across sessions, since it is a guess the user made about one archive and a wrong one silently outliving the session is worse than being asked again |
| M28 | iCloud Photos, as folders of originals | 09-13 | **Import, delete and album edits**, each a write Photos mediates with its own confirmation; **smart albums** — one a person made is returned by no PhotoKit fetch, and the system ones are views over the library rather than places; **shared albums, the Shared Library and hidden photos**, left out as Photos' own Library view leaves them out; **a per-asset time zone**, which PhotoKit does not expose, so months are cut in the Mac's; **⌘L inside the library**, which has no real directory to start from; and **Photos' lowercase `.mov`** for a Live Photo's movie, since a row's name is part of its path. **Exercised later that evening**: the download of an original that is only in iCloud, on clips recorded for it — the bar sat at zero and Stop was ignored until the request carried a progress handler (HISTORY.md §M28); after that fix a 219 MB copy arrived byte-identical and Stop on a 276 MB one stored nothing |
| M29 | A license, and the reminder it removes | 10-01 | **Revoking a refunded key inside the app** (the server marks it; an in-app list waits until refunds are actually abused); **trials that stop working, and activation limits**; **any copy protection beyond the signature**, since the source is open and the reminder is a request, not a lock; and **the Keychain** for the key, which is signed rather than secret. **Seen only in tests or a Debug build**: the Renew reminder on a release build, the prominent Renew… in Settings ▸ License, a pasted production key, and the 13:00 rule |
| M30 | Report a Bug, and a Help menu to hold it | 10-07 | **Anything the user didn't type or tick** in a report: no logs, no screenshots, no file names or paths, one crash report at most; **the website** naming Help ▸ Report a Bug…, until a stable release has it (the private repo's C8). **Seen only in tests**: Email Instead's draft, since this Mac's Mail has no account |
| M31 | A compare window of our own | 10-22 | **Editing, copying a block across and saving**, a later milestone's decision — **since shipped** as M33, for whole lines; **a three-way merge** — **since shipped** as M34; **a file over 64 MiB** in the window, refused by name and left to the external tools; **a binary comparison**. **Seen only through a probe**: a Mac with no external diff tool. **Not run live**: an external tool from the conflict dialog, FTP and S3 pairs, and Escape |
| M32 | WebDAV | 10-24 | **Depth infinity**; **locks of our own**; **NTLM, Negotiate and OAuth**; **setting a time on Apache**, which has no way to take one (Nextcloud's `X-OC-Mtime` is used where it is answered); **Apache's offset PUT** as a segmented upload; **quota**; **CalDAV, CardDAV, versioning and WebDAV ACLs**; **a Trash**, which the protocol does not have, so a NAS's `#recycle` softens the delete sheet instead. **All run live 2026-10-24**, on the NAS and a throwaway Apache, which found and fixed three bugs: ⌥F5 with a server folder in the set, Put Back into a folder deleted since, and dragging a marked set out (HISTORY.md §M32) |
| M33 | Copy a change across, and save | 10-26 | **Typing in a pane** and **find and replace**, M11's call; **copying every change at once**, which is F5; **a save that changes the encoding or the line endings**, since a save keeps both; **editing in the conflict dialog's window**, whose right-hand file waits on that dialog. **Not run live**: FTP and S3 sides, a Synchronize row compared again after a save, a side with nowhere to save, and an editor's unsaved edit met by a save |
| M34 | A three-way merge | 10-27 | **Synchronize as an entry point**, until a sync keeps a record of the last one; **three files picked by hand**, whose base would be a guess; **an archive member** changed behind an edit; **being git's merge tool**, which needs a command-line entry point; **conflict markers** in any form; **a merge that ignores whitespace**; **a binary file**. **Not run live**: FTP in the app, a batch's question, a file past the content check's limit, the take keys and the light appearance. Over SFTP and FTP a write between the check and the upload goes unseen, since that upload carries no condition |
| M35 | An SMB server's shares, as a pane | 11-05 | **Anything that writes to the list**: creating, renaming or deleting a share, or copying onto it; **a comment column**; **a way up from a share Finder mounted**, which keeps `..` → `/Volumes`. **Not run live**: the plain permission sentence, since no share is listed to `dirnex-test` and refused; ⌘Return into the other pane; a saved sidebar row; `..` from a share typed into the sheet while its server is not connected; and marks inside a share after a relaunch |
| M36 | Drag and paste, where M23 stopped | 11-08 | **A folder for Teams, Chrome and the rest of Chromium**, which refuse a promise — **since shipped** the same day as a zip of the folder for every app but Finder, after Gmail answered "Attachment failed" for a folder (HISTORY.md, after §M36); **a folder inside an archive**, which probe P1 answers for too, leaving the extraction of a subtree behind the promise; **a folder dragged with files** losing its promise once the pointer has been over another app, the board's rewrite to file URLs being one way. **Not run live**: Edit ▸ Move Items Here being enabled, F5 from a server into an archive, an archive member into a Chromium app, and a server folder crossing another app on its way to Finder |

### Next

**Planned 2026-11-07: M36–M40.** These five milestones take up what earlier milestones left undone by
choice rather than for a hard limit, in the order Oleg set: drag and paste, compare and merge, remote,
Quick View, and everything else. Each item names the milestone that left it and the reason given
then, because that reason is what the design has to answer. Nothing left here has been probed yet. Each
milestone opens with its probes, and its slices are written then (CLAUDE.md ▸ How to work here). An
item whose reason still holds after the probe goes back to the *undone* column with what the probe
found.

M36 (drag and paste, where M23 stopped) closed 2026-11-08, and is archived in
[docs/HISTORY.md](docs/HISTORY.md).

#### M37 — Compare and merge, past M31 and M34 (M–L)

- **A file over 64 MiB in the compare window** (M31), refused by name today and left to the
  external tools.
- **A binary comparison** (M31). `ByteComparator` answers "differ", and the window refuses the pair
  by name.
- **Synchronize as a way into a merge** (M34). A merge needs a real base, and Synchronize keeps no
  record of the last sync, so this item starts by giving it one.
- **Being git's merge tool** (M34). `git mergetool` hands the tool its files and waits for it to
  exit, so this needs a command-line entry point Dirnex does not have.
- **An archive member changed behind an edit** (M34). No base is kept for a member's edit.
- **A merge that ignores whitespace** (M34). It was left because it would drop a whitespace edit
  without a word, and M34's risk row names an ignore option reaching `ThreeWayMerge` as its tell. So
  this one is a decision before it is a slice. It is built only in a form where a whitespace-only
  change on either side still survives or is shown, and otherwise goes back to the *undone* column.

Inherited from M31's and M34's risk rows (§6): lines compare as bytes, git stays the oracle for
regions, and a merge is offered only over a base that really was the file's.

**Opened 2026-11-08.** Probed on this Mac (64 GB) with git 2.54, through throwaway release harnesses
over the real core:

- **The text path grows in a straight line, and the window is not what limits it.** Log-shaped text
  with 500 edits, both sides read, compared once, each pane built once:

  | One side | Read and decode, each | Compare | Pane text, each | Footprint |
  |---|---|---|---|---|
  | 64 MiB (651 543 lines) | 0.5 s | 1.0 s | 2.9 s | 0.5 GiB |
  | 256 MiB | 2.1 s | 4.3 s | 11.4 s | 2.0 GiB |
  | 512 MiB | 4.2 s | 8.8 s | 23.5 s | 4.1 GiB |
  | 1 GiB (10.4 million lines) | 8.4 s | 18.3 s | 47 s | 8.3 GiB |

  TextKit 2 stays lazy at 256 MiB: setting the text took 0.02 s, the first draw 0.01 s and a jump
  anywhere 3 ms, at about 0.75 GiB per pane for ASCII text. So memory is the limit, about 13 times
  one side's bytes for a pair, and the slowest step is the pane text, where `columns(of:)` walking
  `Character`s is the first suspect.
- **Two hazards that a higher limit makes worse.** A dense pair (256 MiB, 868 724 changes) took 33 s
  to compare rather than 4.3 s, with nothing on screen and no way to stop it. And a Windows-1251 file
  takes **65 s per side at 64 MiB**, in `NSString.stringEncoding(for:)`, which is already true at
  today's limit.
- **A comparison at the same offset is nearly free.** Two 1 GiB files with 2 000 patches: 0.37 s from
  the page cache, and `cmp -l` agrees on the 15 938 differing bytes. Sixteen bytes inserted 4 KiB in
  make 1 069 480 528 bytes differ (99.6 %), in 4.2 million stretches, so the stretches need a bound.
- **What `git mergetool` hands a tool.** Four paths, relative, with the command's working directory
  at the top of the worktree even when `git mergetool` ran in a subfolder. The three versions are
  temporary files beside the file (`a_LOCAL_74127.txt`), removed afterwards, and `$MERGED` holds the
  conflict markers. `$BASE` is 0 bytes for add/add. Under `trustExitCode`, exit 0 stages the file, and
  exit 1 prints "merge of added.txt failed" and leaves it `AA`.
- **git's whitespace options drop whitespace edits, as M34 feared.** With `-Xignore-space-change` or
  `-Xignore-all-space`: ours re-indents and theirs edits the same line, and the result is theirs
  alone (`  B!`, the re-indent gone); the mirror image gives the same; and both re-indenting
  differently takes theirs, with no conflict. Each of the three stops as a conflict without the
  option.

Decided before Slice 1 (2026-11-08, Oleg, on the probes above):

- **A byte view at the same offset, of any size.** Hex rows side by side, with no alignment. It takes
  a binary pair and a text pair too large for the text window, instead of refusing them, and says
  plainly when nearly every byte differs from some point on, which is what an insertion looks like.
  **Aligning across insertions goes back to the *undone* column**: it needs gaps in the rows, a size
  limit, and has no oracle.
- **The text window's limit becomes a share of this Mac's memory**: a side of up to 1/32 of it, and
  never under today's 64 MiB, so a pair costs at most about 40 % of memory. The merge window keeps
  64 MiB: it holds three or four panes, and M34's reads stay as they are.
- **A sync keeps a base only when asked, per folder pair.** A checkbox in the Synchronize window, off
  by default, in keeping with §6's rule about what Dirnex remembers without being asked. It keeps
  each text file of up to 64 MiB that the sync left equal on both sides, an APFS clone where the
  volumes allow, under a total budget with the oldest dropped first, and never a vault path.
- **git reaches Dirnex through the app's own binary and a private socket.**
  `Dirnex.app/Contents/MacOS/Dirnex --git-merge "$LOCAL" "$BASE" "$REMOTE" "$MERGED"` runs as a plain
  command before any AppKit starts, launches the copy it belongs to if that copy is not up, and exits
  when the merge window closes: 0 for saved, 1 for anything else. No new build target and no
  Automation prompt, and it works from any terminal or IDE. M34's window and refusals are reused, and
  Save writes `$MERGED` alone. git stays the one that stages it.
- **Whitespace never reaches `ThreeWayMerge`.** The regions stay byte-exact. A conflict that whitespace
  explains is labelled, and gains one more take: this side's text with the other side's indentation.
  Save still waits for an answer to every conflict, so a whitespace edit is either kept or was chosen
  against.

#### Slices

1. **The byte comparison** (core, additive). The differing stretches of two local files at the same
   offset, bounded, cancellable and reporting as it goes; the rows a window shows; pages read on
   demand. `cmp -l` is the oracle.
2. **The byte window** (app). One table of hex rows for both sides, a page loaded off the main thread,
   next and previous difference, an overview strip, and the opening routes: ⌥F3, the Synchronize row
   and the conflict dialog, in place of the two refusals.
3. **Larger text** (core, then app). The column count's fast path, encoding detection bounded on a
   large file, the limit as a share of memory, "Comparing…" in the window and a Stop that really
   stops, and the byte view past the limit.
4. **An archive member's edit** (app, on M34's base). A base kept for a member, the member read again
   at save when the archive moved, and Merge… in the archive's question.
5. **Whitespace in a merge** (core, then the merge window). What whitespace explains in a conflict, the
   extra take, and git as the check that the regions did not move.
6. **git's merge tool** (core, then app). The request and the socket's protocol against a fake, the
   binary's command-line entry, a merge window whose end answers the command, and a way to set it up.
7. **The sync's record** (core). The kept versions, the budget, and which side changed since.
8. **Merge from Synchronize** (app). The checkbox, keeping after a sync, "changed on both sides", and
   Merge… on such a row.
9. **Live, and the record.** Every entry point on a real pair, 14 languages, and M37 closed.

**Done when:**
- a binary pair and a pair past the text limit open and show every difference, checked against
  `cmp -l`, with the window up before the scan ends;
- a 256 MiB text pair opens without a beachball on this Mac, and a dense one can be stopped;
- a member changed behind its edit merges and repacks with both edits in it;
- `git mergetool` resolves `UU` and `AA` files through the window and reports a closed window as a
  failure, and nothing but `$MERGED` is written;
- a file changed on both sides of a remembered sync merges over the base that sync kept, and a pair
  with no record offers no merge;
- no ignore option reaches `ThreeWayMerge`, and nothing is saved while a conflict is open.

#### Progress

**2026-11-08: Slice 1 landed** (core only; the app is untouched).

- **Core:**
  - `BinaryDifferenceList` holds the stretches, with an exact count of differing bytes. Two differing
    bytes join when fewer than a row's width of equal bytes lie between them. Past 100 000 stretches
    the gap doubles and the list is joined up again, so a pathological pair loses resolution and no
    difference.
  - `BinaryComparison` is the scan, the bytes only one side has, stepping between changes, and the
    dense stretch an insertion leaves. Like `ByteComparator`, it refuses an evicted placeholder.
  - `BinaryFilePair` holds both files open and reads a page at any offset, from any thread.
  - `BinaryHexLayout`, `BinaryHexRow`, `BinaryPage` and `BinaryPageCache` are what the window draws.
  - `ByteComparator.requireRegularFiles` and `requireDownloaded` went from private to internal, so
    the two comparisons share those rules.
- **Tests:** 67 in six suites. `BinaryComparisonCmpTests` asks `/usr/bin/cmp -l` about 40 random
  pairs at the sizes where an off-by-one would show, an inserted run, a chunk boundary and this Mac's
  own programs. The rest pin what joins and what stays apart, every promise of the list at every
  bound, the refusals, reports and Stop, the hex text column by column, and pages past a file's end.
  Full run: 4 871 core tests. The app suite was not run, since the app is untouched.
- **Measured** in release, on 1 GiB pairs:

  | Pair | Time | Stretches | Differing bytes |
  |---|---|---|---|
  | 2 000 patches | 0.44 s | 2 000 | 15 929, as `cmp -l` counts |
  | Sixteen bytes inserted 4 KiB in | 1.79 s | 1, named as dense from 4096 to the end | 1 069 543 201 |
  | One byte in every 19 differing | 0.57 s | 1, the gap doubled once | 56 513 536 |
  | A file against itself | 0.09 s | 0 | 0 |

- **Negative controls:** 14 faults put in the source, one at a time. Eleven failed at once. Three
  passed, and each was a gap in the tests, now closed: a stretch touching the bytes only one side
  has, a scan ending exactly on a report's boundary, and a file that shrank to exactly a chunk's
  edge.
- **Found on the way, for Slice 6:** `VFSPath.local` with a relative path gives a path from the root
  (`data/a.bin` became `/data/a.bin`), and `git mergetool` passes relative paths. The command-line
  entry has to resolve them against its own working directory first.

**2026-11-08: Slice 2 landed** (the byte window, and the routes to it).

- **App (`Dirnex/Compare/`):**
  - `BinaryCompareWindowController`, with `+Table`, `+Changes`, `+Layout` and `+Banner`. The window
    knows its rows from the two sizes, so it is up before the scan ends, and closing it stops the
    scan.
  - `BinaryHexTable`, `BinaryHexCell` and `BinaryCompareStyle`: one table holds both sides, so they
    are level by construction, with each cell drawn in one pass.
  - `BinaryRowSource` reads a page off the main thread when a row needs one: one read at a time, and
    only of a page still on screen.
  - `ModalLevelKeeper` is the text window's rule for opening over a modal window, moved so both
    windows share it. `CompareToolbar` can show only its arrows and counter.
  - **Routes:** `CompareOpener` sends a binary, undecodable or too-large pair to the byte view, which
    covers ⌥F3, the Synchronize row and the conflict dialog. A file that cannot be opened is still an
    alert. Twelve new strings, in all 14 languages.
- **Core:** `BinaryFilePair` keeps each file's size from `fstat` at open, and `BinaryComparison.scan`
  takes an open pair, so the rows and the scan see the same two files. `percentScanned`, whose first
  version overflowed `Int64` near 2^62, and `changeRows`.
- **Tests:** 6 more in the core and 36 in the app. Full runs: 4 877 core tests, and the app suite
  green twice in a row without the live server suites, whose code this slice does not touch.
- **Decided in the slice:**
  - **An ordinary table, not a custom view.** It brings the row keys, scrolling and accessibility with
    it, and it is exact for any file up to about 16 TiB once it is kept out of Auto Layout.
  - **"No differences" waits for the scan to end.** Before that the counter is blank, since it would
    be a claim about bytes nobody has compared.
  - **Left out:** a Go to Offset, copying bytes, Swap Sides, a file that changes while it is shown,
    and a Stop short of closing the window.
- **Negative controls:** 10 faults, one at a time, each failed its own test: the intrinsic height left
  in, no refill on scroll, a close that keeps scanning, "No differences" said early, the next
  difference missing one on the current row, a jump after the user moved, reading every wanted page,
  the tail marked as a change, the header's height left out of a jump, and a page queued again while
  it was being read.
- **Found by a full run:** that last one, a real double read that passed alone and failed once in a
  full suite, depending on when a redraw landed. Its test now holds the read open and asks during it.
  The waits in these suites went from 10 s to 60 s, after a full run's other suites held the main
  actor long enough to expire them.
- **Run live** on the Debug build, driven from the background: the patched program pair (5 changes, 6
  bytes, as patched), a 70 MiB text pair (24 bytes, as `cmp -l` counts) and a sparse 20 GiB pair, whose
  window was up at "Compared 51 %" and landed on the last row. The row keys, the arrows, the close
  button and the screen reader's tree were each tried there. Two bugs only that run could find:
  - **An accessibility read crashed the app** on the 20 GiB pair, and the first two fixes left a real
    client with no table at all (docs/NOTES.md ▸ A table of billions of rows).
  - **A change opened with one row above it, not three**, since the column header floats over the
    clip view.
  - An earlier window-less probe had also passed a table Auto Layout then cut at 10^10 points, the
    case the 1 TiB test now resizes for.
- **Not run live:** the keys the window takes with its monitor (⌥⌘↓, ⌥⌘↑, ⌘W, Escape), which a
  background run cannot send and tests pin through `handleKey`; the Synchronize row and the conflict
  dialog, which go through the same `CompareOpener` call; the light appearance; and any translation.

**2026-11-08: Slice 3 landed** (larger text).

- **Probed first, in release, on 256 MiB pairs:**
  - `columns(of:)` was 11.2 s of a pane's 11.7 s. On the dense pair, 27 s of the 32 s was row alignment,
    not the search.
  - Encoding detection on a sample is only as good as the sample. Over 235 legacy-encoded files of 2 to
    8 MiB in 25 encodings, the file's start agreed with the whole-file answer on 185, and 256 KiB of
    lines holding a non-ASCII byte on 233. The two left are KOI8-R, which the detector gets wrong on the
    whole file as well.
  - **Everything on the main thread was cheap but one thing:** replacing a pane's text that already held
    1.9 million attribute runs ran for over four minutes in `NSMutableRLEArray`, a bug the shipped app
    has at any size with enough marked words, on every re-compare. Emptying the storage first takes
    0.02 s (docs/NOTES.md ▸ Text fields and text views).
- **Core:** the column count's ASCII path. Detection past 4 MiB, which is all Quick View reads, shown a
  sample and the whole file decoded by its answer. `ComparedText.windowByteLimit` and
  `ComparedText.precheck`, which reads a few KiB so a binary of gigabytes is not read whole under the
  larger limit. `ComparisonStop` and a `check` through `LineDiff`, `MyersDiff`, `RowAlignment`,
  `TextComparison` and the pane text. `ComparedDocument.read` can be stopped between its steps, and
  `isEdited` answers at once for lines nothing touched.
- **App:**
  - **A side past 64 MiB opens the window first**, on stand-ins with the files' names, and reads with it
    on screen. A smaller pair is read first, as it always was, so nothing flashes for a small file that
    turns out to be undecodable.
  - **"Comparing…", a spinner and Stop in the toolbar** once a comparison runs past 200 ms, and ⌘. for
    Stop. Stop, a newer comparison and closing the window each stop the work.
  - **Stop empties the panes** and offers Compare Again. By then a swap or a copy may have changed what
    the old panes were a comparison of, so they are not left up.
  - The panes' attributed text, fills and kinds are built off the main thread. Three new strings, in all
    14 languages. A Synchronize row and the conflict dialog take the same route.
- **Measured** on the Release build, on this 64 GB Mac:

  | | Before | After |
  |---|---|---|
  | Pane text, 256 MiB | 11.7 s | 0.7 s |
  | `isEdited`, 256 MiB | 0.6 s | 0 |
  | Read a 64 MiB Windows-1251 file | 65 s | 2.9 s |
  | Stop reaching the work, dense 256 MiB, 8 moments | no way to stop | at most 0.38 s |
  | Re-compare of a dense pane, main thread | over 4 minutes | at most 0.35 s |

- **Tests:** 38 more in the core and 27 more in the app. Full runs: 4 915 core tests, and 2 289 app tests,
  green in two runs of three without the live server suites, whose code this slice does not touch. The
  third failed only `PanesDividerDetentTests`' queued-mouse test, which passed alone three times and in
  the next full run.
- **Negative controls:** 30 faults, one at a time, each failed its own test. Three passed at first, and
  each was a gap, now closed: the loop over a block's alike pairs, the walk over the rows, and Comparing
  shown at once.
- **Found by the live run:** the copy arrows and pencils looked enabled while the files were still being
  read, and the toolbar sat 2 pt higher with Stop in it, moving the panes 4 pt when it left. Both fixed,
  pinned, and seen fixed.
- **Run live** on a Release build driven from the background: a 256 MiB pair (window up in under half a
  second, Comparing… and Stop on screen, 144 changes, worst main-thread answer 106 ms over 371 samples), a dense pair
  (Stop, 0.3 % CPU after it, Compare Again, then 954 300 changes), Ignore Case on the dense pair, a
  64 MiB Windows-1251 pair (Russian as written, its one change found), and a 3 GiB pair past the limit,
  in the byte view with its 4 differing bytes. The sampler's control read 979 ms for a 1 s `SIGSTOP`.
- **Decided in the slice:**
  - **Stop empties rather than keeping the last comparison**, as above. A Show Bytes beside Compare Again
    was left out.
  - **The sides are read one after the other.** Reading them at once would save about 2 s at 256 MiB.
- **Not run live:** ⌘. and Escape during a comparison, which a background run cannot send and a test pins
  through `handleKey`; a pair from a Synchronize row or the conflict dialog; a side near this Mac's
  2 GiB limit; and any translation.

**2026-11-08: Slice 4 landed** (core, then app). A member changed inside its archive under an edit can be
merged instead of overwritten.

- **Found first:** a save back never looked at the archive. The rewrite extracts the archive as it is now
  and replaces the member with the copy, so another member's change survived and a change to the same
  member was replaced without a word, however long ago the copy was extracted.
- **Decided with Oleg before writing it:** a set with changed members is asked as the server batch is:
  Save Back, **Skip Changed Files** where some members are clean, Keep Editing. The members it skips
  stay watched, so each one's next save asks on its own, Merge… included.
- **Core:** `ArchiveMemberBase` is a member's bytes and the archive's `ArchiveIdentity` read just before
  their extraction. `ArchiveMemberCheck` answers `unmoved`, `noBase`, `same`, `different` (with the
  member's size) or `unreadable` for each member of one archive. An archive with the stamped identity
  is one `stat` and no read; the moved members are extracted in **one** call through an injected
  extractor and compared through `ByteComparator`, and the extraction is removed. No size bound, since
  the rewrite that follows extracts every member anyway. `keep` reads one member again into an
  `EditBaseStore`, stamped first, for a merge.
- **App:**
  - **The base** (`ArchivePreviewCache+Bases`). The cache stamps each extraction with the archive's
    identity from before it and the copy's revision as it landed. When an edit's watch starts on a copy
    nothing has written since, the cache keeps a clone of it in `DirnexExtract/Bases`, which the launch
    purge clears and no watch watches. `PanelHost.watchEdit` is now the one call F4, ⏎, a user script
    and the compare window's Edit make, keeping a server file's base or a member's.
  - **The question** checks each member first, with the passphrase this window was given and no prompt.
    One changed member is named before the usual body, with Merge… first where its three versions are
    text within 64 MiB; one that could not be read says so; a set names how many and the first three.
    With nothing found, the question is the one it was.
  - **Merge…** reads the archive's version again through the pane's passphrase funnel, and opens M34's
    window on it, the copy and the base. Its save writes the result into the editor's copy, makes the
    archive's version the copy's base, and carries the copy back through the archive's own question and
    rewrite. A landed rewrite drops the bases of the copies it took in.
  - Eight new strings, in all 14 languages. "Skip Changed Files" is one shared title now.
- **[LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md):** the merge row's archive cell, with footnote zzz.
- **Tests:** 9 in the core (`ArchiveMemberCheckTests`, over a fake extractor) and 17 in the app:
  `ArchiveMemberBaseTests` (4), `ArchiveMemberCheckLiveTests` (4, real zips through `ArchiveExtractor`,
  one of them the milestone's sentence end to end: extract, edit, another writer's change, the check,
  the offer, the archive's version kept, the merge, its adoption and the rewrite, with both edits in the
  archive after) and `ArchiveWriteBackQuestionTests` (9). Full runs: 4 924 core and 2 305 app tests,
  without the live server suites, whose code this slice does not touch; the new suites again once the
  last test was added.
- **Negative controls:** 7 faults in the core and 12 in the app, one at a time. In the core, each failed
  its own test; one first try changed nothing a test could see (a missing member already fails the byte
  comparison) and was replaced by one that did. In the app, 11 failed their own tests. **One passed:** the
  cache reading the archive's identity after the extraction instead of before. Only a write during a
  `bsdtar` run tells the two apart, and no test can make one; the core's `keep` pins the same order with
  a fake extractor that does write.
- **Run live** on the Debug build, driven from the background, with shell writes to the copies standing
  in for TextEdit's saves and a repack under the same name for another app:
  - F4 kept the base beside the copy, byte for byte. With line 2 changed on both sides and line 5 in the
    archive, the question named the change with Merge… first. The window showed the base as extracted,
    theirs' line 5 merged and one conflict; Take Both and Save wrote the copy and left the archive's
    version as the only base; the plain question followed and Save Back put **both edits** in the archive,
    the other members untouched and no base left.
  - Two members saved together after another app changed only `keep.txt`: the plain question about two
    files. After it changed `other.txt`: "1 of them has changed inside the archive…" with Skip Changed
    Files, which wrote back `notes.txt` alone and kept the other app's `other.txt`. The skipped copy's
    next save asked on its own with Merge…, merged clean, and went back with both edits.
  - The defaults domain was restored and compared unchanged.
- **Not run live:** an encrypted archive (the check reads with the window's passphrase or not at all), a
  member taken out of the archive, the compare window's save, ⏎ and a user script as the edit's start,
  a tar or 7z archive, the light appearance, and any translation. The check's cost on a large compressed
  archive was not measured; the rewrite after it reads the whole archive anyway.
- **Left open:** a change to the same member between the check and the rewrite is replaced, as M34 left
  the upload's window over SFTP and FTP. And a merge window saved again after its rewrite landed asks the
  plain question, since a landed rewrite drops the copy's base.

#### M38 — Remote: what M8, M22, M24, M25 and M32 left (M–L)

- **Owner and group in a remote Get Info** (M25). `chown` and `chgrp` take a numeric id, while
  `sftp`'s `ls -la` prints names, so a panel built on a listing has nothing to send. A remote
  `chgrp` also clears set-uid and set-gid without a word, so a change needs the ordering rule
  `AttributeChangePlan` already encodes locally.
- **Open in Terminal for an SFTP account** (M24). A local shell cannot `cd` to a server, so this is
  an `ssh` session to the account's own host. A key account is the easy half; a password account
  needs its secret kept out of `argv`.
- **Searching an S3 account pane** (M22). Its rows are buckets, and "search every bucket" is a far
  more expensive question than the one ⌥F7 asks, so it needs a bound the user sees before it starts.
- **Dragging a remote folder into the sidebar** (M8). A remote folder cannot ride `.fileURL`, and M8
  named a private `VFSPath` pasteboard type as the way. M23's `app.dirnex.locations` payload is that
  type, and a pin on an account already carries where to reconnect (LOCATION-SUPPORT.md
  <sup>ii</sup>).
- **A faster Find Files walk in Photos** (LOCATION-SUPPORT.md <sup>nnn</sup>). One PhotoKit fetch
  could answer every capture date in the library at once, but names cost about 1.1 ms an asset, so a
  search walks month by month today.
- **WebDAV locks of our own** (M32). Left because the entity tag already guards the write, so the
  first question is what a lock would add that the tag does not.
- **WebDAV sign-in by NTLM, Negotiate and OAuth** (M32), left with no reason recorded. The
  transport is `curl`, which has flags for NTLM and Negotiate, so the first probe is whether this
  Mac's `curl` was built with both. OAuth needs a sign-in flow and somewhere to keep the token first.
- **WebDAV quota** (M32). Left because the NAS does not report it, so the first question is which
  servers do. The Nextcloud container M32 used is the place to measure.

Inherited from M25's risk row (§6): a capability is learned per connection when it is first needed,
and what cannot be carried is reported rather than approximated. And from M32's: nothing branches on
a namespace prefix or the `Server` header, and a capability is used only where the server's own
answer shows it.

#### M39 — Quick View (L)

- **RTF** (M16, M18), with a source and a page view. It is `NSAttributedString`'s job and shares
  nothing with the Markdown renderer.
- **`.webarchive` and `.mhtml`** (M16), which need `loadData` rather than a file load.
- **Markdown: math, footnotes, definition lists, emoji shortcodes and wiki links** (M18). A wiki
  link names another file, so it depends on following a link, the item below.
- **More mermaid diagram types** (M18). Only flowchart and sequence draw today. A class diagram,
  gantt, state chart or ER diagram falls back to a code fence naming itself.
- **Following a link to another file** (M18). A preview that follows links is a browser, and needs
  its own history and its own way back.
- **Exporting the rendered page** to HTML or PDF (M18). That is a file operation, so it goes through
  the operation engine with a destination and a conflict policy.
- **Syntax highlighting** (M17): a theme picker, since the colors are a fixed light and dark table;
  JSON keys colored apart from values; setext headings and indented code blocks in a Markdown file's
  source; and Ruby's `=begin` block comment. The JSON and Markdown items need a lookahead or a
  previous line that the single pass does not keep.
- **A slideshow timer or a thumbnail filmstrip** (M11). Left because that is an image viewer, and the
  point of full-size Quick View is that the file list stays the navigation.

Inherited from M17's and M18's risk rows (§6): the highlighter stays one pass with no state stack, and
only ever adds color. Markdown is judged against a corpus of real files rather than the spec, an
unreadable construct falls back to its own text, and the generated page stays inert. Mermaid gains
diagram types, never a config surface read from the diagram's source.

#### M40 — Everything else (M)

- **Places as ⌘K results** (M20). The palette is a registry of commands and places are live data, so
  this is a second mechanism and its own decision.
- **Per-workspace palette entries** (M3). Workspaces are reached through the Workspaces… popup
  today.
- **Privilege escalation for a multi-selection, and recursively** (M14). The single-item path proved
  the mechanism, and those sheets refuse a root-only change by name.
- **Escalating the undo of a non-owned change** (M14), refused today with
  `attributeRestoreNeedsAdministrator`.
- **Recents ordered by when each item was last used** (M8). Modification date stands in today,
  because `mdfind` returns paths in no useful order and a statted `FileEntry` carries no last-used
  date.
- **Find Files: the tag chip, and a content-grep fallback for volumes Spotlight does not index**
  (M4).
- **Localization** (M12): the stock Finder tag names in the ⌃T menu, which are
  `FinderTag.systemTagName` data in the core and stay English; a lint rule keeping bare literals out
  of UI files, which the sweeps stand in for; and the "Results for Search results" stutter, a wording
  decision rather than a translation gap.
- **Revoking a refunded key inside the app** (M29). The server marks a refunded key, and M29 set the
  in-app list to wait until refunds are actually abused. Dirnex never asks a server whether a license
  is real, so the list ships in the app.
- **SMB** (M35): a comment column on a server's share list, from the `NetCommentStr` that
  `EnumerateShares` already returns; and a way up from a share Finder mounted, which keeps `..` →
  `/Volumes`.

The app's share of selling Dirnex (the private companion repo `dirnex-home`, milestones C1–C15) was
two milestones, **M29** (a license, and the reminder it removes) and **M30** (Report a Bug), both
shipped and archived in [docs/HISTORY.md](docs/HISTORY.md). Neither changed what Dirnex *is*: it
stays open source, fully usable without paying, and it never asks a server whether a license is
real. Before the store opens (the private repo's C12), the licensing switch goes on for stable, and
two small changes are proposed: Help ▸ Release Notes opening the website's changelog, and a "Lost
your key?" link in Settings ▸ License.

### Still open

Everything through M36 is shipped, and the record of it — the milestone checklists, the dated
passes that landed outside a milestone of their own, and the reasoning behind every decision — is in
**[docs/HISTORY.md](docs/HISTORY.md)**, which also tells how everything else on this list came off
it (HISTORY.md ▸ the follow-on log). What is still open, rather than merely imaginable, is M37–M40
under *Next*, which take up the items in the table's *undone* column that were left by choice, plus
the list below. The column itself stays as each milestone's record.

- **The thumbnail grid, brief view and the `PaneSurface` extraction** — M15's cut, and one unit
  rather than three items, argued in HISTORY.md §M15. Any future grid inherits two constraints from
  it: skip `FileEntry.isDataless` rows, and move sort off the column header first.

## 5. Cross-cutting: testing strategy

What each pass *found* lives in [docs/HISTORY.md](docs/HISTORY.md) ▸ *the follow-on log*; the six
dated notes that used to sit here moved there on 2026-09-10, the way §4's did on 2026-08-23. The
plan keeps the strategy, which is a rule that outlives any one pass.

| Layer | Approach |
|---|---|
| DirnexCore | Unit tests against generated fixtures; every operation tested for: success, cancel mid-flight, permission denied, disk full, source mutated during op |
| VFS backends | One shared conformance test suite run against every backend (Local, Archive, SFTP-against-docker, FTP/FTPS against an injected fake transport fed real captured bytes) |
| Undo journal | Property tests: op + undo == original tree (compare via content hash) |
| Panels/keyboard | XCUITest smoke for the keyboard core; snapshot tests for panel rendering states |
| Performance | XCTest metrics gated in CI: 100k-dir list < 150 ms, filter keystroke < 16 ms, memory ceiling on huge dirs |
| App test host | The host is the app, so its `UserDefaults.standard` is the user's own `app.dirnex.Dirnex`: it installs no app delegate, and a store a test writes takes a scratch domain. CI exports the domain before and after the run and fails on any change by content (`scripts/check_defaults_unchanged.py`) |

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
| M29's reminder turns goodwill into irritation. A sheet Escape cannot close, at every launch, is the most hostile thing Dirnex will ever do, in an app whose reviews are written by keyboard users | The mitigations: 30 quiet days; a sentence that asks rather than scolds; one sheet per launch or per day, never stacked over onboarding; and every rule a named constant in `LicenseReminderPolicy`, so changing the cadence is a one-line, tested change rather than a redesign. The tell is feedback about the sheet outnumbering feedback about the app |
| M29: a paying customer meets the reminder after an update they didn't choose | The notice before any uncovered install, and no silent background install of one. Slice 5's probe chose the hook, an app test pins that a background check cannot get past it, and Slice 6 watched it hold on a beta all night |
| M31's compare window grows into an editor one small step at a time: selectable text, then editable text, then something has to save it. And a diff can be wrong in the quiet direction, showing two different files as the same | Editing is a later milestone's decision, stated in M31's first bullet. The tell is a text view becoming editable, or a Save command appearing, before that decision is taken. Against the quiet error there are three defenses: lines compare as bytes, every corpus pair has to match git's minimal counts, and a pair with no visible change says what differs. **Held (closed 2026-10-22).** Both panes are `isEditable = false`, and nothing in the window saves. All three defenses shipped and were seen working: the history run found no disagreement with git, and live, an encoding-only, a byte-order-mark-only and a line-ending-only pair each said what differed |
| M32's WebDAV backend is fitted to one server. The NAS and the throwaway `httpd` are both Apache `mod_dav`, so every fixture, every live run and every probe agree with Apache, and a parser can pass all of them while reading Apache's spelling rather than the protocol | The parser matches elements by namespace URI and reads only what RFC 4918 promises, so `lp1:` and `D:` are one case rather than two. The fixtures are captured bytes, and the corpus gets a second implementation family (Nextcloud's sabre/dav, in a container) before the milestone closes. The tell is a branch keyed on a prefix, on the `Server` header or on a slash at the end of an href. A capability only Apache has, such as the offset PUT, stays unused until a second server answers it the same way. **Held (closed 2026-10-24).** Nextcloud 34's sabre/dav ran every probe and the whole live suite: its `d:` prefix, with `oc:` and `nc:` beside it, parsed unchanged, and no branch keys on a prefix, a header or a slash. What differed was behaviour, each now a claim in the endpoint's config or a rule with its fixture: names stored composed, a lock that guards only the file, a strong tag shared by every write in one second, `creationdate` at the epoch, a 404 for a PUT into a missing folder, and `X-OC-Mtime` honoured, which is the one capability Dirnex now uses there and asks of every server, believing only an answer that says so. The offset PUT stays unused |
| M33 grows the compare window into the text editor M11 refused, one reasonable step at a time: copy a block, then fix one character, then type. And a save can write bytes nobody chose: an encoding, a byte-order mark or line endings the file did not have | M31's row named a Save command appearing *before the decision* as its tell, and M33 is that decision, taken for line operations only. The panes stay `isEditable = false` and an edit is a `LineEdit` on the core model, so the tell is now a keystroke reaching a pane's text storage, or find and replace appearing. Hand edits go to the user's own editor, which the window watches. Against the quiet error: an unedited side must encode back byte-identical over the repository's history, a side that does not opens read-only with the reason named, and a character the encoding cannot hold is refused rather than substituted. **Held (closed 2026-10-26).** The panes are still `isEditable = false`, every edit is a `LineEdit` on `ComparedDocument`, and no find or replace arrived; a hand edit goes to the user's editor, which the window watches. An unedited side came back byte-identical for all 7 449 text versions in this repository's history and all 555 676 text files measured on the development Mac. The two hand-made files that did not come back open read-only, with the reason in the banner. A character the encoding cannot hold is refused with its line, and copied lines take the line ending of the file they land in |
| M34's merge is wrong in the quiet direction: a region read as changed on one side when both sides changed it drops an edit, and nothing on screen shows what went missing. A stale base does the same | git is the oracle in two styles, `--diff3` for the regions and `--zdiff3` for the trimming, and the properties that need no git (a text merged with itself comes back, a side equal to the base yields the other, every one-sided change survives) run over random texts. No ignore option reaches a merge, the uploaded bytes replace the base after every upload, and Save is refused while a conflict is open. The tell is a merge offered without a real base, such as the server's copy standing in for one, or an ignore option reaching `ThreeWayMerge`. **Held (closed 2026-10-27).** git agreed in both styles on every corpus triple apart from 113 named ties, and the three properties ran over random texts. No ignore option reaches `ThreeWayMerge`. Merge… is offered only with a base that was the server's own bytes: taken when the edit's watch starts on a copy nothing has written, replaced by each upload's sent duplicate, forgotten with a record whose upload outcome is unknown, and never the server's copy standing in. Save is refused while a conflict is open, and no marker is written. The quiet failure the row names turned up once, in the check rather than the merge: over SFTP a same-size write in the minute of the last upload went unseen and was overwritten, and the save now compares the server's bytes with the base |

## 7. Open questions

**None open.** M25's was the last, and it closed on 2026-08-29. Every question this plan asked since
M0, and how each one closed, is in [docs/HISTORY.md](docs/HISTORY.md) ▸ **The questions the plan
asked**.
