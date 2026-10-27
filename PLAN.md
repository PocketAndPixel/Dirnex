# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: **M0–M32 shipped** (14 languages; M29's licensing is on in betas, off in stable until the
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

### Shipped: M0 → M32 (2026-07-05 → 2026-10-24)

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
| M31 | A compare window of our own | 10-22 | **Editing, copying a block across and saving**, a later milestone's decision; **a three-way merge**; **a file over 64 MiB** in the window, refused by name and left to the external tools; **a binary comparison**. **Seen only through a probe**: a Mac with no external diff tool. **Not run live**: an external tool from the conflict dialog, FTP and S3 pairs, and Escape |
| M32 | WebDAV | 10-24 | **Depth infinity**; **locks of our own**; **NTLM, Negotiate and OAuth**; **setting a time on Apache**, which has no way to take one (Nextcloud's `X-OC-Mtime` is used where it is answered); **Apache's offset PUT** as a segmented upload; **quota**; **CalDAV, CardDAV, versioning and WebDAV ACLs**; **a Trash**, which the protocol does not have, so a NAS's `#recycle` softens the delete sheet instead. **All run live 2026-10-24**, on the NAS and a throwaway Apache, which found and fixed three bugs: ⌥F5 with a server folder in the set, Put Back into a folder deleted since, and dragging a marked set out (HISTORY.md §M32) |

### Next: M33 and M34 (planned 2026-10-25)

M33 and M34 take the two items in M31's *undone* column that are product decisions rather than
limits: copying a change across and saving it, and a three-way merge. M33 comes first, because
M34's result pane, its undo and its save are M33's.

The app's share of selling Dirnex (the private companion repo `dirnex-home`, milestones C1–C15) was
two milestones, **M29** (a license, and the reminder it removes) and **M30** (Report a Bug), both
shipped and archived in [docs/HISTORY.md](docs/HISTORY.md). Neither changed what Dirnex *is*: it
stays open source, fully usable without paying, and it never asks a server whether a license is
real. Before the store opens (the private repo's C12), the licensing switch goes on for stable, and
two small changes are proposed: Help ▸ Release Notes opening the website's changelog, and a "Lost
your key?" link in Settings ▸ License.

### M33 — Copy a change across, and save (M)

**Planned 2026-10-25.** Dirnex's compare window shows two files and changes neither. Total
Commander's compare tool, the one M31 named, copies a block from one side to the other and saves
the result, and that is what editing a comparison is mostly for: making one file agree with the
other where it should. This milestone adds that and stops short of typing. M11's call stands: a
built-in text editor is encoding detection, line-ending preservation, undo grouping and find and
replace, a whole app, and every Mac already has the editor its user chose. So the window edits
*lines*, through a model in the core, and an edit by hand goes to the user's own editor, which the
window watches and compares again when it saves.

Read before deciding (2026-10-25):

- **A pane's text is not the file's text** (`ComparisonPaneText`). A gap is an empty line; U+2028,
  U+2029, U+0085, a vertical tab and a form feed show as stand-ins; a line over 10 000 UTF-16 units
  is cut at `…`; and every row ends in `\n`, whatever the file's line ended in. An editable pane
  would have to map every keystroke, every marked-text composition and every `NSTextFinder` replace
  back through all four, a keystroke landing in a gap included.
- **The window already holds what a save needs.** `ComparedText` keeps the encoding and the
  byte-order mark, and `TextLine` keeps each line's own ending, so the bytes can be written back
  without a guess.
- **Every place a side comes from already has a way back.** A local file is a path. A server file
  or an archive member reaches the window as a temporary copy (`CompareFile.path` beside `origin`),
  and F4's write-back already puts such a copy back, re-`stat`ing the server and conditioning the
  upload on what the check read (`WriteBackJob`, §M21 Slice 10).
- **Comparing again after every change is cheap enough.** M31 measured 0.03 s for a 20 000-line
  file with 200 edits and 0.43 s for the dense 100 000-line pair, in release.
- **⌥⌘← and ⌥⌘→ are free.** No catalog command is bound to either, and the window's own change
  keys, ⌥⌘↑ and ⌥⌘↓, sit beside them (`CompareWindowController+Keys`).
- **An archive rewrite is already undone by exchanging two files** (`ArchiveUndoStore.exchange`,
  with `ArchiveUndoWitness` checked at ⌘Z): the self-inverse step NOTES.md ▸ Undo and redo
  recommends for any whole-object replacement. A saved file is one.

Decided before Slice 1:

- **The panes stay `isEditable = false`.** An edit is a line operation on the core model, never a
  keystroke in a text view. Hand edits go to the user's editor (Slice 5).
- **Two verbs: Copy to Right (⌥⌘→) and Copy to Left (⌥⌘←).** Each acts on the current change, then
  moves to the next one. Copying a side whose block is empty is how a block is deleted, so there is
  no third verb. Buttons beside the change arrows carry the same two.
- **Copied lines take the line ending most common in the file they land in**, and a copied line
  that had none, being its file's last, gains one unless it lands last too. Otherwise a CRLF block
  lands in an LF file unannounced, the one change nobody expects from "copy".
- **A copy acts on what the comparison shows.** Under an ignore option, lines shown as the same are
  not copied, and the banner goes on naming what still differs.
- **Undo belongs to the window.** Every edit replaces some lines with others, and its inverse is an
  edit of the same shape, so ⌘Z and ⇧⌘Z come free.
- **A side is saved as it was read, apart from the lines that changed**: the same encoding, the
  same byte-order mark, and every unchanged line with its own ending. A character the encoding
  cannot hold is refused by name, with its line, never substituted. A side whose unedited bytes do
  not come back identical from the model opens read-only, and the banner says why.
- **⌘S saves every edited side.** The title bar shows unsaved changes, and closing the window asks
  Save, Don't Save or Cancel.
- **A local save is checked, kept and journaled.** Before writing, the file's size and modification
  date are compared with what was read, and if either moved the window asks rather than writes. The
  old bytes go to the undo store, and ⌘Z in a pane exchanges them back:
  `ArchiveUndoStore.exchange`'s step, widened from archives to any file, with the same witness.
- **A server file or an archive member is saved into its temporary copy and handed to the
  write-back F4 uses**, re-`stat`, prompt and precondition included. There is no second upload path
  (§6's M23 row), and the save is not journaled, as no remote write-back is.
- **The window opened from the conflict dialog stays read-only.** Its right-hand file is the source
  of a copy that is waiting on that dialog.

#### Slices

1. **The editable side** (core, additive). `ComparedDocument`: owned lines, the encoding and the
   byte-order mark; `LineEdit` and its inverse; copying a change either way with the destination's
   line ending; encoding back to bytes, with `unencodable(line:character:)`. Tests: edits and their
   inverses as properties over random texts, every line-ending case, the round trip over M31's
   checked-in corpus, and once over every version of every text file in this repository's history
   (a throwaway harness, recorded in the slice note).
2. **Copying across** (app). The two keys and buttons; comparing again after each copy, with the
   current change kept; the window's undo manager under Edit ▸ Undo; the title bar's edited state;
   Swap Sides carrying unsaved edits with their side; the conflict dialog's window read-only (moved
   up from Slice 4).
3. **Saving a local file** (core, then app). First a probe of what a save must keep, against
   TextEdit's and BBEdit's own saves: mode, owner, Finder tags, other extended attributes, an ACL,
   the creation date, a symlink (saved through to its target) and a file with a second hard link.
   Then the writer, the witness check, the journal step, ⌘S, and the close prompt (moved from
   Slice 2, which had no Save for it to offer).
4. **Saving anywhere else** (app). Server and archive sides through the write-back; the Synchronize
   row the window came from compared again after a save.
5. **Edit in the user's editor** (app). Edit Left and Edit Right open that side the way F4 does, so
   a server side's save is offered back exactly as F4's is. The window watches the file as
   `EditedFileRegistry` does and compares again when it changes. With unsaved edits on that side, it
   asks to save them first.
6. **Live, and the record.** A local pair, a zip member, and the throwaway SFTP and WebDAV servers;
   the 14 languages; the compare window's rows in
   [docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md).

**Done when:**
- every version of every text file in this repository's history either comes back byte-identical
  from an unedited side or opens read-only with the reason named;
- after any sequence of copies the window shows what a fresh comparison of the two texts shows, and
  ⌘Z walks every copy back;
- a local save keeps what Slice 3's probe says it must, is undone by ⌘Z in a pane, and is never
  written over a file that changed since it was read;
- a server file and an archive member save through the existing write-back, byte-exact, and a server
  file changed in the meantime gets the write-back's own prompt;
- a save in the user's editor shows in the window without reopening it.

Expected to be left undone, each for its own reason: **typing in a pane** and **find and replace**,
M11's call; **copying every change at once**, which is F5; **a save that changes the encoding or the
line endings**, since a save keeps both; and **editing in the conflict dialog's window**.

#### Progress

**2026-10-25: Slice 1 landed** (core only; the app is untouched).

- **Core:**
  - `ComparedDocument` holds a side's lines, encoding and byte-order mark. `read` and `decode` write
    the unedited lines back once, and `isSavable` says whether that gave the file's own bytes. It
    also has `commonLineEnding`, `isEdited` (by bytes, against the file as read), `apply(_:)`, which
    returns the inverse edit, and `encoded()`, which throws `unencodable(line:character:)`.
  - `LineEdit` replaces some lines with others. `LineEdit.copying(_:to:left:right:)` builds the copy
    of one change, with the destination's line ending.
  - `TextComparison` compares two documents as they stand.
  - `LineTerminator.text` and `TextPreview.byteOrderMark(for:)` are now the only spelling of a line
    ending and of a mark.
- **Tests:** 18 in two new suites.
  - `ComparedDocumentTests` pins each line-ending rule, both refusals, each encoding's round trip
    and the not-savable cases.
  - `ComparedDocumentPropertyTests` applies up to 8 random edits to each of 1 000 random documents,
    then walks every one back by its inverse and forward again by theirs. It draws 2 000 random
    pairs under four option sets and copies changes in random order and direction until the pair
    agrees. Every pair agrees within as many copies as the first comparison had changed lines, and
    undo restores both sides: 4 545 copies, 81 of them giving the line before a break of its own.
  - The same suite takes M31's 35 corpus files and their seeded edits in UTF-8, UTF-8 with a mark,
    UTF-16LE and UTF-16BE. Each comes back byte for byte, and copying every change of a file into
    its edit gives the file back (205 copies).
- **Measured** (throwaway harnesses, not checked in):
  - **This repository's whole history:** 7 480 blob versions. 7 449 are text, and every one is
    savable and comes back byte for byte; the other 31 are binary.
  - **The development Mac:** 835 018 files under `~/Dev`, `/usr/share`, `/etc` and three
    frameworks. 555 676 decode as text, in 25 encodings: 5 124 UTF-8 with a mark, 596 UTF-16LE and
    280 legacy files in 23 encodings among them. Every one comes back byte for byte.
  - **Two hand-made files do not**, and are not savable. One has a second UTF-8 mark, which
    Foundation drops when decoding; the other is UTF-16 with an odd last byte, dropped too
    (docs/NOTES.md ▸ Text fields and text views).
  - **The check costs little at open**, in release: 0.35 → 0.48 s for 58 MiB of UTF-8, +0.08 s for
    15 MiB of UTF-16 and +0.3 s for 7.7 MB of Windows-1251.
- **Decided in the slice:**
  - **Outside UTF-8, the writer encodes one line at a time**, so a refused character is found on
    its own line. The check at open covers an encoding whose state would run across lines. The
    character named is the last of the shortest prefix the encoding refuses, so a flag or a
    decomposed letter is named whole.
  - **`commonLineEnding` comes from the file as read and stays.** A tie goes to the ending met
    first. A file with no line break takes the source's, and two such files get LF.
  - **A copy that lands after a last line with no break gives that line one**, so the edit starts a
    line early. Only an option that overlooks line endings can leave a change there; without the
    break the two lines would join. `apply` traps on any edit that leaves a line without a break
    ahead of another.
  - **An undo, or a change copied back by hand, leaves a side unedited**, because `isEdited`
    compares bytes with the file as read rather than counting edits.
- **Negative controls:**
  - Without the line-break step, its unit test and the copy property both trap in `apply`.
  - With copied lines keeping their own ending, the CRLF-into-LF test fails. It is the only test
    that does, since the property draws both sides from one ending under the default options.
  - With a copied last line always gaining a break, three unit tests, the corpus copy and the
    default-option property fail.
  - Writing no mark fails five round trips and the not-savable test's controls.
- **Found on the way:** M31's decoder takes 6 s to open a 7.7 MB Windows-1251 file, in
  `NSString.stringEncoding(for:)`. The compare window has paid that since M31, and this slice adds
  0.3 s to it.

**2026-10-25: Slice 2 landed** (the window; nothing is saved yet, which is Slice 3).

- **Core:** `ComparedDocument.text(ofFirstLines:)` and `SyntaxLanguage.contentsLineLimit`, so the
  opener names a file's language from its first 500 lines without joining the whole file.
- **App:**
  - `CompareSource` holds a `ComparedDocument` and an `id`, and the opener reads one, so a file
    that would not come back byte for byte is known when the window opens.
  - `+Copy` adds Copy to Right (⌥⌘→) and Copy to Left (⌥⌘←), and two arrows right after the change
    arrows. A copy is the core's `LineEdit`. The pair is then compared again, and the change below
    the copied lines becomes the current one, or the last change when none is below.
  - The window has its own `UndoManager`, handed to AppKit by `windowWillReturnUndoManager`. Edit ▸
    Undo names the copy ("Undo Copy to Right"), and an undo makes the change it brought back the
    current one.
  - A side that differs from its file says "— Edited" in its header, and the close button carries
    the edited dot. Both read `isEdited`, which is computed with the comparison, off the main thread.
  - Swap Sides takes each file's copies with it. An undo finds its file by `id`, on whichever side
    the file is.
  - A side that is not savable takes no copy: its arrow is grayed and the banner says why. The
    conflict dialog's window shows no arrows and ignores both keys.
- **Tests:** 11 in `CompareCopyTests` and one in the core. The existing compare suites now build
  their sides from documents.
- **Probed before writing it:**
  - **Edit ▸ Undo needs nothing from the window but an undo manager.** In a throwaway app, `undo:`
    with a read-only text view first walked past it to `NSWindow`. The window asked its delegate's
    `windowWillReturnUndoManager`, enabled the item and titled it "Undo Copy to Right", and ⌘Z
    through `NSMenu.performKeyEquivalent` ran the handler.
  - **A momentary `NSSegmentedControl` keeps no selection set from code**, so the button test
    presses the segment through its accessibility element (docs/NOTES.md ▸ Windows).
- **Decided in the slice:**
  - **The close prompt moved to Slice 3**, since Save has nothing to do until a save exists. In this
    slice, closing an edited window drops copies that nothing could have kept.
  - **The conflict dialog's window became read-only here rather than in Slice 4.** The arrows
    arrive in this slice, and that window's right-hand file is a copy waiting on the dialog.
  - **A copy waits for a comparison of the sides as they stand.** `sidesRevision` counts every
    copy, undo and swap. A copy is refused with a beep until a comparison of that revision has
    landed, because a change's ranges name lines of the comparison it came from.
  - **After a copy or a redo, the next change is current. After an undo, the restored one is.**
- **Negative controls:**
  - With an undo landing as a copy does, the window's undo test fails. At first only the unit test
    failed: the window test copied the last change, where "the last one left" and "the one restored"
    are the same change. The test now copies a middle one.
  - Without the revision guard, the stale-comparison test fails.
  - With an undo finding its file by side rather than by `id`, the Swap Sides test fails.
  - Without `windowWillReturnUndoManager`, two tests fail.
- **Seen live** in the Debug build, on a three-change pair opened with ⌥F3. The saved tabs were
  cleared first, since a WebDAV tab would have asked the Keychain. A temporary probe (since removed)
  logged both files' text, the current change, the edited marks, and the Edit menu's Undo and Redo
  titles after each step:
  - ⌥⌘→ and ⌥⌘← arrived as key events (keyCodes 124 and 123, with ⌥⌘) and copied each way. The
    arrow button copied too.
  - The Edit menu said "Undo Copy to Right". Choosing it made the restored change the current one,
    and Redo then said "Redo Copy to Right". ⇧⌘Z and ⌘Z did the same by key.
  - Undoing every copy cleared the "— Edited" mark and the close button's dot, and a copy put both
    back.
  - ⌘U took the left file's copy and its mark to the right, and ⌘Z then restored that file there.
  - **The keys needed Dirnex in front** (full-screen control). Driven from the background, the
    window is not key, so its key monitor is not installed (docs/LIVE-VERIFICATION.md).
  - The defaults domain was put back afterwards and compared unchanged.
- **Seen, and left as it was:** after Swap Sides no change is current, so both arrows stay grayed
  until ⌥⌘↓. That is M31's swap, which compares again rather than mirroring the comparison.

**2026-10-25: Slice 3 landed** (core, then app). A server file or an archive member is not saved
yet, which is Slice 4.

- **Probed first** (docs/NOTES.md ▸ Keeping a file's previous bytes): what TextEdit, vim,
  `FileManager.replaceItemAt` and a write in place keep. The fixture had mode 0640, a group the
  folder does not have, two Finder tags, a private extended attribute, an ACL entry and a 2020
  creation date, and the cases were a plain file, a symlink, a second hard link and an ACL denying
  delete.
  - All four kept the mode, group, ACL and creation date. vim dropped the tags and the private
    attribute.
  - TextEdit and `replaceItemAt` gave the hard-linked file a new inode, so the other name kept the
    old bytes. Neither could save the file whose ACL denies delete: TextEdit's save never returned
    and left a temporary file beside it.
  - Only the write in place kept everything in every case. BBEdit is not on this Mac, so vim stood
    in. A file owned by another user could not be made here; a write in place keeps its owner by
    construction.
- **Core:**
  - `InPlaceFileWrite` replaces a file's bytes through `open(O_TRUNC)`. Its writer is the one seam
    a test can fail partway.
  - `ComparedFileSave` encodes first, so an unencodable character is refused before anything is
    touched. It then checks the file against the `Target` taken when it was read, captures the old
    bytes into the undo store and writes in place. A write that fails is undone by writing the old
    bytes back with their modification time.
  - `UndoStep.restoreSavedFile` is the archive step with the same store, witness and both refusals.
    It writes back in place too (`ArchiveUndoStore.exchangeInPlace`), labelled `.saveFile` ("Undo
    Save", translated in all 14 languages, since the coverage test reads every label).
  - `ComparedDocument.markSaved` makes the saved lines what `isEdited` compares with.
- **App:**
  - ⌘S saves every edited side and beeps when there is nothing to save. It is a key the window
    takes, like ⌥⌘→, since the main menu has no Save item.
  - A file changed since it was read asks "Save Anyway" or Cancel. A character the encoding cannot
    hold is reported with its line and the encoding's name.
  - Closing an edited window asks Save, Don't Save (⌘D) or Cancel. So does quitting, through
    `applicationShouldTerminate`.
  - ⌘W closes the window, through the same question. Since M31 it had done nothing there: the
    menu's ⌘W is the browser's Close Tab, which is disabled in the compare window.
  - The undo record goes to the browser window the comparison came from, or the front one if that
    has closed. `CompareSaving` carries the store and the journal, with no default, as
    `ArchiveWriter`'s request does.
  - `CompareOpener.openWindow`'s `allowsCopies` became `saving: CompareSaving?`: a window with
    nowhere to save takes no copies, which is the conflict dialog's.
- **Tests:** 18 in the core, in `ComparedFileSaveTests` and `SavedFileUndoTests`, and 15 in the
  app, in `CompareSaveTests` and `CompareCloseTests`. Full runs: 4 537 core and 1 940 app tests,
  without the live server suites, which this slice does not touch.
- **Decided in the slice:**
  - **A save writes in place**, the only way that kept everything. It gives up atomicity, so the old
    bytes are read first and put back if the write fails. Measured on a 3 MB APFS disk image: a
    17 MB save failed with `ENOSPC`, and the file came back byte for byte with its witness
    unchanged.
  - **⌘Z writes in place as well.** The plan named `ArchiveUndoStore.exchange`'s rename, which would
    break the hard link the save kept and fail on the ACL. The undo puts back the modification time
    the file had before the save, as an archive's undo does, so the witness stays exact.
  - **The witness is taken just before the read**, so a write during the read makes the save ask.
    A symlink is resolved when saving, and the undo record names its target.
  - **A server or archive side still takes copies and is not saved**, as in Slice 2. ⌘S and both
    prompts pass over it until Slice 4.
  - **The compare window is no longer deferred.** Probed: a deferred window takes no sheet until it
    has been shown, so a test's window raised none (docs/NOTES.md ▸ Testing).
  - The window's new sentences wait for Slice 6's translations, as Slice 2's do.
- **Negative controls:**
  - `replaceItemAt` in place of the write fails the hard-link, symlink, deny-delete and disk-full
    tests.
  - Without the put-back, the disk-full test fails. Without the witness check, both changed-file
    tests fail.
  - An undo by rename fails the hard-link and deny-delete undo tests.
  - With a saved file's snapshot left out of `archiveSnapshotPaths`, three tests fail. Launch's
    prune would otherwise delete the copy.
  - In the app, a save without `markSaved`, without the journal call, without the ⌘S key or the ⌘W
    key, or a close that never asks, each fails its test.
- **Seen live** in the Debug build, on a pair whose right file carried tags, a private attribute, an
  ACL, the `admin` group, a 2020 creation date and a second hard link. Computer-use pressed the keys;
  a temporary probe (since removed) logged the window, and a sampler logged the file whenever it
  changed:
  - ⌥⌘→ then ⌘S wrote the line into the same inode. Both names showed it, every attribute stayed,
    and the "— Edited" mark cleared.
  - In the pane, Edit ▸ Undo said "Undo Save". It put the old bytes and the 2024 modification time
    back, and ⇧⌘Z put the saved ones back, all in that inode.
  - Closing with an edit asked; ⌘D answered Don't Save and left the file alone, and Return answered
    Save and wrote it.
  - With the file changed behind the window, ⌘S asked. Cancel kept the other write; Save Anyway
    replaced it, and its undo copy held the other write.
  - Quit asked the same question. Cancel kept the app running, and Don't Save quit it.
  - In a second run, ⌘W closed an unedited window at once and left the browser's tab alone. With an
    edit it asked; Cancel kept the window, and ⌘D closed it with the file untouched.
  - The defaults domain was restored and compared unchanged, and the run's three undo copies were
    deleted.

**2026-10-25: Slice 4 landed** (app only). **Not yet run live**; the tests drive the window with a
stand-in write-back.

- **App:**
  - A server file or an archive member is saved into the copy the window read, then handed to F4's
    write-back: the re-`stat`, the question only when the check found something, the precondition
    and the queued upload, or the archive's question and its rewrite.
    `BrowserWindowController.writeBack(_:askingOver:)` runs the batch's two endings at once rather
    than gathering, puts their sheets on the compare window, and answers whether the copy landed.
  - **A side counts as saved only once it lands.** Keep Editing, a failed upload or a declined
    rewrite leaves it edited, so the close prompt still asks and the next ⌘S carries it again. The
    copy's witness moves with the window's own write, so that save does not ask whether the copy
    changed.
  - Where each copy goes back to is `editDestination(for:)`'s answer when ⌥F3 is pressed, as for F4.
    A side with nowhere to go (a member of a nested archive or a self-extractor, an iCloud Photos
    original) is read-only: its arrow is grayed and the banner says Dirnex can't save it back where
    it came from. It took copies until now, which close dropped without asking.
  - The window keeps no undo for these. An upload has none, and an archive's rewrite journals its
    own, as it does for F4.
  - **The Synchronize row is compared again.** A landed save posts `CompareWindowController.fileSaved`
    with the file's origin. The Synchronize window re-`stat`s the row showing it and answers the row
    under the comparison on screen (`SyncDirectoriesController+Saves`). The row leaves the list once
    its two files agree. A row whose status did not move keeps its action and tick, and every other
    row keeps them too. A notification rather than a handler passed down, so a compare window
    opened before the sheet counts as well.
  - `EditedFileRegistry.acknowledgeWrite(to:)`: F4 may have the same copy open, and its watch would
    offer the window's write a second time.
- **Fixed on the way:**
  - Cancel at an encrypted archive's passphrase prompt called nothing back, so the archive
    write-back waited forever and that window's later write-backs queued behind it.
    `withArchivePassphrase` now has `onCancel`.
  - The upload anyway after a refused precondition ran detached, where no caller could hear of it.
    It is awaited now, and the next batch's sheet waits behind it.
- **Found and not fixed:** the write-back's check reads the revision the cache holds for the
  *path*, not for the copy being written back. If a preview downloads a newer version of the file
  while an edit is open, F4's or the window's, the check compares the server with that newer
  revision, finds nothing, and uploads the older copy over it without a question. It has been so
  since M21 Slice 10, and the compare window makes it easier to reach.
- **Tests:** 15 in three new suites. `CompareWriteBackTests` covers what the window hands over, when,
  over which window, and what it does with the answer, plus the read-only side and the
  announcement. `SyncCompareAgainTests` covers the row leaving, the other rows keeping their ticks,
  and the four ways an answer lands in the list. `EditedFileRegistryTests` covers the acknowledged
  write. Full runs: 4 537 core and 1 955 app tests, without the live server suites; the backends and
  the runner are untouched.
- **Negative controls:**
  - Without the witness moving with the window's write, the not-landed test fails.
  - A side saved whatever the write-back answered fails that test and the announcement test.
  - Without the read-only reason, the nowhere-to-save test fails. Without the observer, the
    Synchronize row test fails.
  - Without the status-kept branch, its row test fails. Without the acknowledgement, the watch test
    fails: its first control was a `return` above the line, which Swift ran anyway
    (docs/NOTES.md ▸ Negative controls).
- **Left for Slice 6:** the compare window's cells in [docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md),
  the new sentences' translations, and the live runs over SFTP, WebDAV and a zip.

**2026-10-25: the write-back check reads the copy's revision** (app only). Closes Slice 4's
*found and not fixed*. **Not yet run live.**

- **App:**
  - `RemoteFileCache` keeps a revision **per copy**, by the copy's URL. Before this it kept one per
    path, and `fetched[path]` still names the path's newest copy, which is what previews and opens
    are handed. A copy keeps its record after the path stops handing it out, because the edit open
    on it outlives the listing that superseded it.
  - The check reads `revision(ofCopy:)` for the copy being saved, through
    `BrowserWindowController.recordedRevision(of:in:)`. A copy with no record answers `nil`, never
    another copy's revision, and the check then asks with the "no record" sentence.
  - An upload re-baselines only its own copy. A failed re-`stat` or an unclaimed item forgets only
    that copy's record (`forget(copy:)`), where it used to drop the whole path.
  - **Chosen over** answering "no record" whenever the copy is not the path's newest. That also
    closes the hole, but the user would read "can't tell" where "someone else has edited it" is
    known. It would also lose the newer copy's record once the older one uploaded.
  - `Entry` and `cached(for:)` are gone: the copy's URL was all their callers used, and without
    them no path-keyed revision is left to reach for.
- **Tests:** 5 new. `WriteBackBatchTests` has two: the older copy's save is checked against its own
  download (and the newer copy's save stays quiet), and after one copy uploads, the other copy's save
  is checked against its own revision. `RemoteFileCacheTests` has three, on two copies of one path:
  each keeps its own revision, a re-baseline moves only its copy, and forgetting one leaves the
  other. Full runs: 4 537 core and 1 960 app tests, without the live server suites. The S3 edit
  suite now reads the per-copy accessor and still needs a real account to run.
- **Negative controls:**
  - The check reading the path's newest copy, as before, fails both batch tests. The concern comes
    back `nil`, which is the silent overwrite.
  - One record per path (a record dropped with its path, or replaced by the next copy) fails both
    batch tests and two cache tests.
  - A path-wide `forget` fails the forget test.
- **Left for Slice 6's live runs over SFTP and WebDAV:** F4 a file, change it on the server, let a
  preview bring the new version down, then save the old copy and see it ask. Once with F4's editor
  and once with the compare window's ⌘S.

**2026-10-25: Slice 5 landed** (app only). Run live on a local pair the same night; the server and
archive runs are Slice 6's.

- **Probed first** (a throwaway package over `DirnexCore`, not checked in):
  - **A file-path FSEvents stream with file events fires for every way an editor saves.** Counted
    `DirectoryWatcher(filePath:)` callbacks: a write in place gave 1, and a rename over the file, a
    delete and create, `replaceItemAt` from the item replacement directory, `NSDocument.writeSafely`
    (TextEdit's save) and vim's `:wq` gave 2 each. A sibling written five times gave 0. The
    `/var/folders` spelling of a temporary copy fired, and so did a symlink's own path for a write
    to its target.
  - `NSDocument.writeSafely` to a symlink's own URL failed ("doesn't exist"), and to the resolved
    URL it worked, so a document-based editor saves the target. The stream is given the resolved
    path.
  - `UndoManager.removeAllActions(withTarget:)` took one target's actions off both stacks and left
    another's, with their titles and order.
- **Decided with Oleg before writing it:** every savable side is watched from the moment the window
  opens, not only after Edit; the pencils sit in the pane headers, with F4; a side with unsaved
  copies asks Save and Edit or Cancel, with no Discard; and a change under unsaved copies asks Read
  Again or Keep Copied Changes rather than keeping them in silence.
- **App:**
  - `+Watch` watches each side a save can write. A change is a file that no longer matches the
    witness its side was read or last saved at, so the window's own save is not one. A look that
    comes during a save, or during a read of the same file, waits until it ends.
  - The file is read again off the main thread and replaces its side. The pair is compared again
    with the other file's top line kept, and the first change at or below that line is current, so
    the copy keys go on working.
  - **The file's copies leave Edit ▸ Undo**, since their ranges name the old lines, and the other
    file's stay. Each file registers its copies under its own `CompareUndoTarget`.
  - **Each copy is its own undo group now** (`groupsByEvent = false`), found by the undo test. In
    the test host two copies made with no event between them shared one open group, and removing
    one file's action left the group holding the other's under the first one's name. In the app each
    key press closes its group, but a step holding both files' copies is one a read again cannot
    take apart.
  - A side holding unsaved copies asks first. Read Again drops them. Keep Copied Changes leaves
    them, and ⌘S then asks Save Anyway, as for any file changed since it was read. A state the user
    kept, or one that could not be read as text, is not asked about again; a later change is.
  - A file that can no longer be read as text gets "Couldn’t compare these files" with the opener's
    reason, and the window goes on showing it as read.
  - A local file's change posts `fileSaved`, so a Synchronize row showing it compares again. A
    server copy's does not, since the server is unchanged until the copy's write-back lands.
  - `+Edit` adds Edit Left and Edit Right: a pencil at the end of each pane's name, and F4 for the
    pane holding the keyboard. The editor is handed what F4 would hand it: a local file itself, or
    for a server file or an archive member the copy the window read, registered with the browser
    window's `EditedFileRegistry`, so its save is offered back exactly as F4's is. A side with
    nowhere to save has its pencil grayed. The conflict dialog's window shows none and beeps at F4.
    No editor, or a launch that fails, gets F4's own alert, on the compare window.
  - `CompareSaving` gained `openInEditor` and `watchCopy`, stand-ins in tests, so a test window
    opens no editor.
  - `buildContent` moved to `+Layout` when the controller passed the type-body ceiling.
- **Tests:** 20 in two new suites: `CompareEditTests` (9) and `CompareWatchTests` (11), over real
  FSEvents streams on the rig's files. Full runs: 4 537 core and 1 980 app tests, without the live
  server suites, which this slice does not touch.
- **Negative controls:**
  - With no watch, 10 of the 11 watch tests fail (all but the pure change-picking one).
  - Without the witness comparison, the window's own save is read back, and the own-save and undo
    tests fail. Without the passed-over check, the kept state is asked about again.
  - With every copy registered under the controller, as before, the undo test and Read Again's
    fail. Grouping by event fails the undo test.
  - Reading again without asking fails Keep and Read Again. Editing without saving first fails both
    save-first tests.
  - Without the copy watch, the server test fails; without the notice, the Synchronize test;
    without F4, both F4 tests; without stopping at close, the close test.
- **Seen live** (2026-10-26) in the Debug build on a local pair, with TextEdit as the editor. The
  saved tabs were set aside so no WebDAV tab asked the Keychain. Computer-use drove it, in the
  background and then with Dirnex in front for the window's keys, and a temporary probe (since
  removed) logged every look at a file, question and save:
  - Both pencils sat at the end of their name rows, enabled, titled "Edit Right in TextEdit (F4)".
    The right pencil handed TextEdit `right.txt` itself and watched no copy. TextEdit merely opening
    the file fired the stream, and the witness answered "unchanged".
  - TextEdit's save (a new inode) fired twice. The first read the file again and showed the added
    line, 3 changes and no edited mark. The second answered "unchanged".
  - The pencil on an edited side asked Save and Edit. The save landed and was journaled, its own
    stream event answered "unchanged", and TextEdit was handed the file.
  - With a copy unsaved, TextEdit's save asked Read Again or Keep Copied Changes, and the save's
    second event waited behind the question. Keep left the copy, and that event, looked at
    afterwards, was passed over. ⌘S then asked Save Anyway, and Cancel left TextEdit's save on disk.
    A later TextEdit save asked again, and Read Again showed it, unedited, with the right file's
    copies gone from undo.
  - F4 followed the keyboard: in the right pane it asked about `right.txt`, and Cancel opened
    nothing. In the left pane it handed TextEdit `left.txt`.
  - After ⌥⌘←, ⌥⌘→ and ⌘S, an outside write to the right file was read in silence, and Edit ▸ Undo
    said "Undo Copy to Left". Choosing it put the left file's line back, with nothing left to undo.
  - ⌘W asked about the unsaved left file, and Don't Save closed the window.
  - The defaults domain was restored and compared unchanged, and the run's three undo copies were
    deleted.
- **Found live, and fixed in the entry below: an editor that already has the file open does not see
  the window's save.** After Save and Edit, TextEdit, which had `right.txt` open from the first Edit, went on
  showing the old text, even after Dirnex and then TextEdit were activated again. Its next save
  refused with "The file has been changed by another application" (Save Anyway, Revert, Save As),
  so nothing was lost in silence, but Save and Edit's promise, that the editor opens the file with
  the copies in it, does not hold there. The window's save writes in place without
  `NSFileCoordinator`. The same in-place write made through a coordinator refreshed TextEdit's
  window at once. ⌘Z's write-back of a saved file (`exchangeInPlace`) is the same kind of write.
- **Left for Slice 6:** the live runs over SFTP, WebDAV and a zip member, among them an editor's
  save through Edit Right; this slice's sentences in the 14 languages; and the compare window's
  cells in [docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md).

**2026-10-26: the window's saves are coordinated** (core, then a live check). Closes Slice 5's
finding above.

- **Probed first** (docs/NOTES.md ▸ Keeping a file's previous bytes), with a test-process presenter
  and with TextEdit, the three ways of writing:
  - **Uncoordinated**, as before: a presenter heard nothing. TextEdit kept a stale document, and
    kept an unsaved edit over the new bytes until its next autosave asked about it.
  - **Coordinated with no options**: TextEdit refreshed an unedited document at once, but
    **discarded an unsaved edit**, from the window and from Undo.
  - **Coordinated for merging**: TextEdit saved its unsaved edit into the file first, then showed
    the new bytes. An unedited document refreshed.
  - A presenter's write while it let go was already in the file when the accessor ran. And
    `cancel()` from another thread ended a coordination stuck on a presenter that never let go.
- **Core:**
  - `CoordinatedFileWrite.run` runs a block inside a merging coordinated write, and gives up after
    10 s, answering `nil` without running it.
  - `ComparedFileSave` runs its witness check, its read of the old bytes, the undo copy and the
    write inside that block, so an editor's unsaved edit, saved by the coordination, is found by the
    check and refused as changed since read. Saving anyway writes over it, and the undo copy holds
    it.
  - ⌘Z of a save (`restoreSavedFile`) runs its witness check and the in-place exchange inside one
    coordinated write too. An archive's swap is unchanged.
  - `VFSUnsupportedReason.fileHeldByAnotherApp(name:)` for a write no app let go of in time,
    translated in all 14 languages, since the coverage test reads every reason.
- **Tests:** 6 in `CoordinatedFileWriteTests`, with a file presenter standing in for the editor:
  the save and ⌘Z are heard, an unsaved edit is saved first and kept, saving anyway leaves it in the
  undo copy, ⌘Z refuses over it, and an editor that never lets go fails the save by name after its
  patience. 10 of 10 runs green alone. Full runs: 4 543 core tests, and 1 980 app tests green in
  two consecutive runs, without the live server suites.
- **Negative controls:**
  - With no coordination, all six fail. Coordinated without merging, the three unsaved-edit tests
    fail and the other three pass, as TextEdit predicted.
  - With the save's check before the coordination, the two save-side unsaved-edit tests fail. With
    the undo's check before it, the undo one fails.
  - With no watchdog, the stuck-editor test was still running when killed at 90 s.
- **Seen live** in the Debug build, with TextEdit holding `right.txt` open and unedited from Edit
  Right:
  - A copy, then the pencil's Save and Edit: TextEdit showed the copied line without being touched,
    the case that had stayed stale.
  - Edit ▸ Undo Save in the browser window: TextEdit went back to the old line, and the compare
    window read the file in.
  - Typing in TextEdit and switching to Dirnex: TextEdit autosaved the line on losing focus, so the
    window read it in silently. The unsaved-edit case is the core tests' and the probe's to show.
  - The defaults domain was restored and compared unchanged, and the run's undo copy was deleted.
- **Found on the way: five tests' first waits had outgrown 30 s.** The first full run of the night
  took 56 s and the next five 81–87 s, on the same code, and the committed tree failed the same five
  tests the same way (three in `CompareWatchTests`, the two archive-encoding member opens, and in
  some runs `RemotePreviewFetchTests` and `RemoteFetchPromptTests`). Each sat in the main-actor stall
  at a full run's start, at 22–27 s even in the green run. They now get 60 s and passed at 40–56 s
  (docs/NOTES.md ▸ Testing).

**2026-10-26: Slice 6 landed** (the catalog and the record; no code changed).

- **Translations:** `scripts/check_localization_keys.py` named 26 strings from Slices 2–5 missing from
  the catalog. They are now there in all 13 languages, with the comments the compiler extracted, and
  the script reports all 1 191 keys present. Every new string sits in an alert, the wrapping banner,
  a tooltip, or the pane's name label, which truncates in the middle and so keeps "— Edited" at its
  end. No fixed-width control holds one.
- **[docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md):** a row for copying, saving and editing in
  the compare window, with footnote vvv on where each location's save lands.
- **Seen live** in the Debug build against the throwaway servers. The panes were seeded with a
  local folder, an SFTP tab with a key, a public WebDAV tab and a zip's folder, so nothing asked the
  Keychain. Background computer-use drove it. ⌘S needs Dirnex in front, so each save went through
  the close prompt's Save, which runs the same save:
  - **SFTP:** copying `bravo` into a CRLF file landed on the server as `bravo\r\n`, with every other
    byte as it was.
  - **WebDAV:** Save and Edit uploaded first (one PUT). The byte-order mark stayed, and the editor
    was handed the copy. A write to that copy, standing in for the editor's save, was uploaded by F4's
    write-back, and the window read it in, unedited.
  - **Zip member:** the archive's own question, then one repack. The member held the copied line and
    the sibling's bytes were untouched. Edit ▸ Undo Change Archive put the archive back byte for
    byte.
  - **The stale copy, closed by the write-back fix above:** the window was open on a copy, the
    server changed, and Quick View brought the newer version down as a second copy. The window's
    save asked "someone else has edited it". Keep Editing left the server alone, and the close prompt
    asked again. Upload All then wrote the window's lines. F4's own path asked the same, for an
    edit saved 7 s after the newer copy had landed.
  - **In Russian:** the copy and edit buttons, "— Изменено", the close prompt and Save and Edit's
    question, all drawn whole.
  - The defaults domain was restored and compared unchanged. The run's undo copy was deleted,
    `known_hosts` was put back, and the servers were stopped.
- **Found on the way (neither is M33's):**
  - **Every archive rewrite renamed the archive's members.** `ArchiveMutation.repackAllArguments`
    packed `-C <dir> .`, so `inner.txt` came back as `./inner.txt`, beside a new `./` entry. Dirnex
    and `unzip -l` read it as before, but `unzip -p pair.zip inner.txt` no longer found the file, and
    neither did Python's `zipfile.getinfo("inner.txt")`. It held for F8, paste, rename and F4's
    save-back alike, from M4 on. Fixed in the entry below.
  - **A write-back question about one file offers Upload All**, the batch's button
    (`BrowserWindowController+WriteBackBatch`), under a title naming the one file. Fixed in M34
    Slice 4.

**2026-10-26: archive rewrites keep their members' names** (core, then app). Closes Slice 6's first
finding above.

- **Probed first** (docs/NOTES.md ▸ bsdtar), against bsdtar 3.5.3:
  - `-s '|^\./||S' -s '|^\.$||S'` on the same `-C dir .` gave bare names in zip, jar, 7z, tar and
    every compressed tar, dropped the root entry, left a symlink's `./` target alone, and rewrote a
    hard link's target with its member. An emptied tree packed into an archive with no entries.
  - Passing the tree's names instead fails on two of them: `@at.zip` is read as an archive to copy
    from, and `-dash.txt` as an option.
  - 160 archives on this Mac: 157 bare, one `./` throughout (Sparkle's release tarball), none mixed.
    Two zips in `~/Downloads` carry the `./` root entry this repack left, likely earlier Dirnex
    rewrites. They keep it, since a rewrite keeps whatever form it finds.
- **Core:** `ArchiveNameForm` (`.bare`, `.dotSlash`) is a third property of `ArchiveRewriteFormat`,
  read off the same header inspection as encryption and name privacy. It is `.dotSlash` only when
  every name is spelled that way. `repackAllArguments` takes it and adds the two substitutions for
  `.bare`. The encrypted route already wrote bare names, and still does whatever the form.
- **Tests:** 5 new in the core (the `./` argv and four inference cases, beside the bare argv's
  updated test) and a new app suite, `ArchiveRewriteNamesTests`, of 5 tests over 18 cases, against
  archives `bsdtar` itself packs and reads back: bare names in
  10 suffixes, the `./` form in zip, tar.gz and 7z, a hard link's target in two tars, `@` and `-`
  names added, and an emptied archive. Four existing suites had pinned `./` as expected:
  `ArchiveUndoReachTests`, `ArchiveMultiAddTests`, `ArchiveWriterEncryptedTests`, and
  `ArchiveRenameTests`, whose helper stripped `./` before comparing and so could not see it. They now
  assert the names as stored. Full runs: 4 548 core and 1 985 app tests, without the live server
  suites, which this change does not touch.
- **Negative controls:**
  - With `.bare` given no substitutions, the old argv, every bare-name test failed across all
    formats, and so did the four corrected suites. The `./` test still passed.
  - With the form always inferred `.bare`, only the `./` test failed, in all three formats.
- **Seen live** in the Debug build: a zip member saved back from the compare window left `pair.zip`
  holding `inner.txt` and `sibling.txt` and nothing else. `unzip -p pair.zip inner.txt` printed the
  copied line, and `zipfile` found the member. Edit ▸ Undo put the original back byte for byte. The
  defaults domain was restored and compared unchanged, and the undo copy was deleted.
- **Found: `.tar.zst` needs an external `zstd`.** Apple's bsdtar runs one to read and write, and
  with the system `PATH` both fail, so the new suite left `.tar.zst` out. Fixed in the entry below.

**2026-10-26: a `.tar.zst` opens from the Dock** (core, then app). Closes the finding above.

- **Measured first**, in the Debug build launched with a Dock's environment (`PATH` read back as
  `/usr/bin:/bin:/usr/sbin:/sbin`): Enter on a `.tar.zst` answered *Can't open “sample.tar.zst”*,
  *Couldn't read the archive “sample.tar.zst”.*, the generic `archiveUnreadable`. Quick View on the
  row showed an icon, as for any file it cannot preview, and F5 or F8 inside could not be reached. A
  `.tar.gz` beside it opened, and so did the `.tar.zst` once the same build was relaunched with
  `/opt/homebrew/bin` on `PATH`.
- **Probed** (docs/NOTES.md ▸ bsdtar), against libarchive 3.7.4:
  - The system libarchive has no zstd (`archive_libzstd_version()` is NULL, both zstd filters answer
    *Using external zstd program*), and neither have Compression.framework or AppleArchive. So the
    in-process option was out. The in-process reader needs `zstd` too, through Dirnex's own `PATH`,
    and every rewrite starts with its inspection.
  - An absolute-path `archive_read_support_filter_program_signature` registered before
    `filter_all` wins the bid. A second one covers `pzstd`'s leading skippable frame.
  - **libarchive's external-program filters deadlock when two run at once**: children inherit each
    other's pipes. Four threads, and also two, completed 0 of 100 reads. One reader at a time
    completed 100 of 100. This was already true of a build launched from a shell.
- **Oleg chose the known-locations route** over the login shell's `PATH` and over refusing only.
- **Core:** `ZstdTool` searches the inherited `PATH`, then `ToolSearchPath`'s directories, then
  MacPorts' `/opt/local/bin`, and recognizes a Zstandard stream by its first four bytes.
  `BsdtarEnvironment` is `ChildProcessLocale`'s environment with `zstd`'s directory appended to
  `PATH`, so no argv changed. The reader registers the two program filters, and an
  `ArchiveReadHandle` reading a Zstandard file holds one external-program turn from open to free.
  `extract` frees its outer handle before unwrapping a hidden-names archive, since the turn is not
  re-entrant. New refusal `archiveNeedsZstd`: *Opening “x” needs the zstd tool, which Dirnex couldn't
  find on this Mac. You can install it with Homebrew (brew install zstd).*, in all 13 languages.
- **App:** all four `bsdtar` runners take `BsdtarEnvironment`. The mounter and the extractor say
  `archiveNeedsZstd` where they would have said unreadable, and the writer says it before anything
  runs.
- **Tests:** 19 in the core over two committed fixtures that `bsdtar` and `pzstd` wrote. A stand-in
  `zstd` that records its runs shows the reader used the path it was given, and eight concurrent
  reads must finish within 30 s. A new app suite, `ZstdArchiveTests`, has 5 tests over 7 cases: list,
  extract and rewrite under the test host's launchd `PATH`, and the three refusals.
  `ArchiveRewriteNamesTests` has `tar.zst` back in its suffixes. The CI image carries zstd 1.5.7.
  Full runs: 4 567 core and 1 990 app tests, without the live server suites, which this change does
  not touch.
- **Negative controls:**
  - With the reader's filters registered after `filter_all`, the three tests that read through the
    stand-in failed. The first try at this control hung instead, which is how the deadlock above
    was found.
  - Without the turn, the concurrency test failed at its deadline.
  - With the four runners back on `ChildProcessLocale`, exactly the five `zstd`-found cases failed as
    `archiveUnreadable`, the rewrite suite's `tar.zst` among them. That also shows the test host's
    `PATH` has no `zstd`.
  - With `ZstdTool.refusal` never refusing, the three refusal tests failed. The rewrite's error was
    then `EncryptedArchiveError.archiveUnreadable`, *This archive couldn't be read. It may be damaged
    or incomplete.*
- **Seen live** in the Debug build, launched again with a Dock's environment: Enter on the
  `.tar.zst` listed `alpha.txt` and `beta.txt`. Quick View showed `alpha`, and F5 copied
  `alpha.txt` out byte for byte. F8 on `beta.txt` rewrote the archive as a Zstandard stream holding
  `alpha.txt` alone, under its bare name, and Edit ▸ Undo Change Archive put it back byte for byte.
  - With a temporary probe that made the search find nothing, Enter showed the new sentence in
    English and in Russian, each in full. The probe was then removed and the app rebuilt.
  - The defaults domain was restored and compared unchanged, and the run's undo copy was deleted.

### M34 — A three-way merge (M)

**Planned 2026-10-25.** A file manager has no common ancestor to merge from, except in two places
where Dirnex already holds three versions of one file. The first is its own. F4 on a server file
downloads a copy, and when the user saves, the write-back can find that the server's copy changed
in the meantime. The prompt then offers Upload Anyway or Cancel, so one of the two edits is lost.
The second is git's: a file in a conflicted merge, which `GitStatus.conflicted` already badges U.
This milestone merges the three in a window built on M33's, and saves only once every conflict has
an answer.

Probed 2026-10-25 with git 2.54, on small triples and in a scratch repository:

- **`git merge-file -p --diff3 --diff-algorithm=minimal ours base theirs` is the oracle**, as
  `git diff --minimal` was M31's. Its regions are what the engine has to reproduce:
  - the same change on both sides merges cleanly;
  - changes that touch, with no unchanged line of the base between them, conflict, and so do two
    insertions at the same place and a deletion against an edit;
  - one unchanged line between two changes is enough for both to merge.
- **git's default style is not the one to match.** It joins two conflicts that are three or fewer
  lines apart (four apart stay two), and it moves lines both sides share out of a conflict.
  `--diff3` does neither, and `--zdiff3` does only the second.
- **The exit status is the conflict count, capped at 127**: 200 conflicts answered 127. The oracle
  counts markers rather than reading the status.
- **A conflicted file's three versions read without writing the index.**
  `git --no-optional-locks show :1:<path>`, `:2:` and `:3:` left `.git/index`'s modification time as
  it was, and `git ls-files -u` lists which stages exist. A file both sides added (`AA`) has no
  stage 1.
- **Real merges are too few to be a corpus**: 10 of this repository's 799 commits. git does not care
  whether a triple came from a merge, so the corpus is triples of versions of one file from the
  history.

Decided before Slice 1:

- **The regions are `--diff3`'s, and a conflict's shared first and last lines move out of it as
  `--zdiff3` moves them**, so Take Both does not repeat them. Each half is checked against its own
  git style.
- **No ignore options in a merge.** Under `-w` a whitespace edit on one side reads as no edit, and
  the merge would drop it without a word.
- **Two entry points**: the server write-back's prompt and a conflicted row. Not Synchronize, which
  keeps no record of the last sync and so has no base; not three files picked by hand, whose base
  would be a guess; and not an archive member.
- **A server file's base is kept when F4 downloads it**: an APFS clone of the copy, outside the
  directory the edit watch watches. The uploaded bytes replace it after every upload, and it goes
  when the watch ends. An edit opened before this milestone has no base and keeps today's prompt.
- **Merge… joins the prompt only when it can work**: a base is there and all three versions are
  text. The server's current version comes down through the download funnel, and the upload's
  precondition is read off that download's revision, the rule `writeCondition` already states. The
  merged result is written into the copy the user's editor has open, then uploaded.
- **git stays read-only.** The stages come through `GitCommand` with `--no-optional-locks`. Save
  writes the working-tree file, and `git add` stays the user's, so the U badge stays until they
  stage it. `AA` merges against an empty base, and a deletion on either side (`DU`, `UD`, `DD`) is
  refused by name, since there is no one file to write.
- **Three panes level by row: Yours, Result, Theirs**, with the base shown on request. Each conflict
  takes Yours, Theirs, or Both in either order, and a region only one side changed is applied from
  the start. A hand edit is Take Both, save, then the user's editor: once saved, the result is an
  ordinary file.
- **Save is refused while a conflict is open.** Conflict markers are never written, to a server or
  to a working tree.

#### Slices

1. **The merge engine** (core, additive). `ThreeWayMerge`: two `LineDiff`s against the base, the
   regions, and the trimming. Properties that need no git: merging a text with itself gives it
   back, a side equal to the base yields the other side, and every change only one side made is in
   the result. Then the oracle over the corpus, with and without M31's sliding, keeping whichever
   agrees more. Triples where two minimal alignments tie are counted and named in the slice note.
2. **What the merge window shows** (core). Rows level across the three versions and the result, a
   resolution per conflict as M33's line edits, and the pane text generalized from two sides to N.
3. **The window** (app). Three panes, `CompareScrollSync` over N of them, the band and overview for
   conflicts, "Conflict 2 of 5", the take keys, Show Base, and Save held back while a conflict is
   open.
4. **The server entry** (app). Keeping and refreshing the base, Merge… in the prompt, fetching the
   server's version, writing the result into the editor's copy, and the conditioned upload.
5. **The git entry** (core, then app). The stage reads in `GitCommand`, their parse in the core
   against a fake, Resolve Conflict… on a U row, `AA`, and the refusals.
6. **Live, and the record.** F4 a file on the throwaway SFTP and WebDAV servers, change it on the
   server, save, merge and upload; a real conflict in a scratch repository; the 14 languages.

**Done when:**
- every corpus triple gives git's text where git merges cleanly and git's regions where it does not,
  apart from the ties Slice 1 names;
- a server file changed under an F4 edit is merged and uploaded with both edits in it, over SFTP and
  WebDAV, and a third write during the merge is caught by the precondition rather than overwritten;
- a `UU` and an `AA` file resolve and save, a `DU` is refused by name, and no git command Dirnex
  runs writes to the repository;
- nothing is saved while a conflict is open.

Expected to be left undone, each for its own reason: **Synchronize as an entry point**, until a sync
keeps a record of the last one; **three files picked by hand**; **an archive member** changed behind
an edit; **being git's merge tool**, which needs a command-line entry point Dirnex does not have;
**conflict markers** in any form; a merge that ignores whitespace; and a binary file.

#### Progress

**2026-10-26: Slice 1 landed** (core only; the app is untouched).

- **Core:**
  - `ThreeWayMerge` holds regions that tile the base, yours and theirs in order, each `unchanged`,
    `yours`, `theirs`, `same` or `conflict`, with `conflictCount`, `isClean`, and `mergedLines`,
    which is `nil` while a conflict is open. `same` is one change made on both sides, or the lines
    a conflict's two sides share at its edges.
  - `ThreeWayMerge+Walk` is git's walk, `xdl_do_merge` and `xdl_append_merge`, with their
    arithmetic kept as it is. A conflict's shared first and last lines then move out into `same`
    regions with no base lines, and its base range stays whole.
  - `ChangeSliding.Placement`: `readable` is M31's scoring, and `lowest` is git's with its indent
    heuristic off. `LineDiff.compare` takes it internally; the compare window is unchanged.
- **Tests:** 15 in three suites.
  - `ThreeWayMergeTests` (10) pins the probed cases: touching, one line apart, two insertions at
    one place, a deletion against an edit, joined and bridged changes, both kinds of trimming,
    bytes over characters, and line endings.
  - `ThreeWayMergePropertyTests` (3) runs without git. A text merged with itself, a side left as
    the base and the same edit on both sides each come back, over 2 000 random texts. The regions
    tile and each kind says what its lines show, over 3 000 triples. Every change only one side
    made is in the result, whichever way the conflicts are taken, over 1 000 triples of unique
    lines.
  - `ThreeWayMergeGitTests` (2) asks `git merge-file` about 678 triples, eight at a time: the
    corpus files edited twice, and 600 short random texts. Given git's own comparisons, every
    merge is git's to the byte in both styles. Given its own, every one is too but 28, and each of
    those is a tie: the same counts, aligned another way.
  - Full run: 4 582 core tests. The app suite was not run, since the app is untouched.
- **Measured** (a throwaway harness, not checked in): 9 114 triples from this repository's history,
  7 578 text versions of 2 001 paths, each version taken as the base between its neighbours and as
  the base of the next two.
  - Given git's comparisons, all 9 114 came back byte for byte in `--diff3` and `--zdiff3`. 5 406
    merged clean and 3 708 had conflicts, 18 714 of them; 3 287 moved shared lines out of one.
  - Given its own, `lowest` agreed with git on 9 001. The other **113 are ties**, across 63 files:
    11 in `Localizable.xcstrings`, and 5 each in `PathBarView.swift` and
    `PanelViewController+ArchivePack.swift`. None disagreed for any other reason.
  - M31's `readable` placement agreed on 8 982, with 132 ties, and no sliding at all on 7 979.
  - In release, the default (cost-limited) merge of the largest triple, three versions of
    `Localizable.xcstrings` at 25 380 / 30 594 / 30 594 lines with 272 conflicts, took 0.077 s.
    `docs/HISTORY.md` at 21 000 lines took 0.038 s.
- **Decided in the slice:**
  - **`lowest` over M31's sliding**, since it agrees with git more often. `git merge-file` runs with
    git's indent heuristic off (docs/NOTES.md ▸ git).
  - **A conflict whose two sides are the same lines merges as `same`.** It comes from how the two
    comparisons aligned one edit, such as each side's deleting a different one of two equal lines.
    git's `--zdiff3` keeps it, with nothing on either side of the markers, and there is nothing to
    choose. Seen in 5 history triples. The git suite renders those the way git does, so every
    other byte is still compared.
- **Negative controls:**
  - Without the join, the unit tests failed and the run then trapped.
  - With touching changes taken as one-sided, the property and git suites failed. The touching
    unit test still passed: the join alone makes that case a conflict, as it does in git.
  - With the same change taken as a conflict, both git tests failed; the unit and property tests
    passed, since the trimming then empties it and the rule above merges it.
  - With no trimming, the own-comparisons git test and the tiling property failed. With identical
    sides left a conflict, the tiling property failed.
- **Found on the way:**
  - **`git diff -U0` places blocks differently from `merge-file`**: at zero context it trims the
    files' common tail first. The first history run read 25 such triples as merge bugs. The oracle
    reads `-U1` hunk bodies now (docs/NOTES.md ▸ git).
  - **Many `Process` runs with pipes from several threads failed with `EBADF`**, so the oracle
    writes git's output to a file (docs/NOTES.md ▸ Fixtures and shared state).
- **Left for Slice 2:** Take Both can put a side's last line, one with no line break, ahead of the
  other's. git adds a break there. Closed in Slice 2.

**2026-10-26: Slice 2 landed** (core only; the app is untouched).

- **Core:**
  - `TextMerge` holds the three documents, the merge, the result, a choice for each conflict, and
    rows level across all four. The result starts as yours' document with every region merged
    and nothing where a conflict is. So it keeps yours' encoding, byte-order mark and line endings,
    and `result.isEdited` says whether a save would change yours' file.
  - `Choice` is yours, theirs, or both in either order. `apply(_:)` makes one choice, or opens a
    conflict again, as a `LineEdit` on the result, and returns the step that undoes it. Also
    `isResolved`, `openConflictCount`, and `conflict(after:)`, `conflict(before:)` and
    `conflict(containing:)`, which pass over chosen conflicts on request.
  - `MergeRow` is a line or a gap in each of four columns, yours, result, theirs and base, with the
    region it belongs to. `MergeRowLayout` lays each region out once. A region one side changed
    pairs that side's lines with the base's, as the compare window pairs them, and a conflict pairs
    yours with theirs and puts the base from its first row down. Only the result column follows
    the choices.
  - `ComparisonPaneText(lines:rows:)` builds a pane for any column on shared rows. Its `side` is
    now `nil` for such a pane; the app's two panes read it as before.
- **Tests:** 11 in three suites.
  - `TextMergeTests` (9) pins the layouts, the pairing, each choice's result and rows, undo, the
    break taking both adds, the result as yours' document, moving between conflicts, and the panes.
  - `TextMergePropertyTests` (1) makes up to 8 random choices on each of 2 000 random triples. After
    every step, each column shows each of its lines once and in order, each result line sits on the
    row of the line it came from, and the result is what the regions and choices call for, built
    without `TextMerge`. Undoing every step gives back the merge as it opened.
  - `TextMergeGitTests` (1) takes every conflict one way over Slice 1's 678 triples, from git's own
    comparisons, and compares the encoded result with `git merge-file --zdiff3` and `--ours`,
    `--theirs` or `--union`: 1 990 results, byte for byte. 44 unions are passed over, where the two
    rules for a break differ (below).
  - Full run: 4 593 core tests. The app was compiled into a separate DerivedData folder, since
    `ComparisonPaneText.side` became optional; the app suite was not run.
- **Measured** in release, on Slice 1's largest triple (`Localizable.xcstrings`, 33 582 rows, 272
  conflicts): opening took 0.121 s, a choice 0.001 s, and the four panes' text 0.137 s.
- **Decided in the slice:**
  - **An open conflict has no lines in the result**, and its rows show gaps there. `isResolved` is
    what holds Save back, so no marker is ever written.
  - **Lines are taken as their side has them, endings included**, as git takes them, so a clean
    region from a CRLF theirs brings CRLF lines. M33's copy rule is the window's, not the merge's.
  - **Taking both gives the first side's last line a break only when it has none and the second
    side has lines**, and the break is yours' common ending. git's `--union` adds one even with
    nothing after it, and makes it CRLF from the lines around the conflict (docs/NOTES.md ▸ git).
  - **Both sides taken: the second side's lines go on the rows after the first's last**, adding rows
    below the conflict when they run out.
- **Negative controls:**
  - With no break when taking both, or with a region's result count left stale, the run trapped in
    `ComparedDocument.apply`'s precondition rather than writing a joined or misplaced line.
  - With a reopened conflict holding yours' lines, or a step returning itself instead of its
    inverse, the undo test and the property failed.
  - With both sides' lines starting on the conflict's first row, the choices test and the property
    failed.
- **Not in the model:** the words that differ inside a row's lines, which the compare window marks.
  Nothing in Slice 3's list needs them.

**2026-10-26: Slice 3 landed** (app only). Nothing opens the window yet; that is Slices 4 and 5.

- **Decided with Oleg before writing it:** the take keys point the way the lines go, ⌥⌘→ Take Yours
  and ⌥⌘← Take Theirs, as ⌥⌘→ copies to the right in the compare window, and ⇧ takes both sides with
  the arrow's side first. Show Base adds the base as a fourth pane at the left edge.
- **App:**
  - `MergeWindowController` takes a `MergeInput` (the three versions, the file Save writes and where
    the result goes) and a `MergeSaving` (the undo store and the journal). It merges off the main
    thread, and prepares each state off it too (`MergePrepared`): each column's text, every row's
    color, the syntax colors and the marks.
  - Yours, Result and Theirs, with Show Base (⌥⌘B, a checkbox) putting Base at the left edge, a band
    between each two panes and the overview strip. A change one side made is blue in that side, the
    result and the base; an open conflict is orange in every column, the result's empty rows
    included; a chosen one is green.
  - "Conflict 2 of 5", ⌥⌘↓ and ⌥⌘↑ and the arrows, and a click in the overview makes the conflict
    under it current. The four takes are keys and one segmented control. After a take the next open
    conflict is current, going round to the start; after an undo, the conflict it changed. Edit ▸
    Undo names the take ("Undo Take Both, Theirs First").
  - Save (⌘S and a button) is disabled while a conflict is open. ⌘S then beeps and goes to the first
    open one, and the banner says how many are open. The save is the compare window's
    `ComparedFileSave`: checked against the file as read, kept in the undo store and journaled, and
    written in place inside a coordinated write. A conflicted working-tree file is replaced whole,
    markers and all.
  - Closing with choices not saved asks Save, Cancel or Don't Save once every conflict has one, and
    Cancel (the default) or Don't Save while one is open. Quitting asks the same, after the compare
    window's question.
  - Shared with the compare window: `ComparePaneView`, whose `side` is `nil` for a merge pane, which
    has no Edit button; `CompareScrollSync`, now over any number of panes, passing hidden ones over
    and bringing one level when it appears; and the save alerts. `CompareColors` gains three row
    colors and two marks, and an open conflict wins a point of the overview.
  - The three counted sentences have English plurals in the catalog. The 13 other languages wait for
    Slice 6, as M33's did.
- **Fixed on the way:** in a comparison shorter than its pane, the compare window's band marked
  nothing below row 0, and the overview outlined a sliver at its top. `visibleRows()` read the missing
  fragment below the last line as "only row 0 is visible" (docs/NOTES.md ▸ Text fields and text
  views). It has been so since M31, and was found here because every fixture was short.
- **Tests:** 25 in three new suites, `MergeWindowTests` (9), `MergeTakeTests` (8) and
  `MergeSaveTests` (8), and one in `CompareWindowTests`. Full runs: 4 593 core and 2 016 app tests,
  without the live server suites; the core is untouched.
- **Negative controls:**
  - A save not held back fails the open-conflict save test. An undo landing as a take does fails the
    undo test. A sync following one pane fails the level test. The base never placed fails the Show
    Base and level tests. The unchanged side marked fails the fills test. No English plural fails
    the counter test. No going round fails its unit test. The visible-rows fallback off fails the
    new compare test.
  - Cancel and Don't Save swapped first passed: the test read the close count before the task that
    asked had acted on Cancel (docs/NOTES.md ▸ Runs and assertions that prove nothing). Awaited now,
    it fails.
- **Seen live** in the Debug build, through a temporary probe (since removed) that opened the window
  on three versions of a Swift file at launch. The saved tabs were set aside, and computer-use drove
  it from the background:
  - Dark appearance: rows level across the panes, with syntax colors. Yours' doc comment was blue in
    Yours and Result, theirs' farewell blue in Theirs and Result, and both conflicts orange with the
    result's rows empty.
  - The first look showed no marks in the bands, which is the fix above. After it, each band marked
    every region, the current conflict solid.
  - Take Yours put the line in the result and turned the conflict green in every pane and band; the
    counter said "Conflict 2 of 2" and the banner "1 conflict is still open". Show Base put the base
    at the left edge, four equal panes, level. Take Both, Theirs First put theirs' line, then yours'
    two on a row added below, and enabled Save. Edit ▸ Undo said "Undo Take Both, Theirs First".
  - Save wrote exactly the chosen merge. Undo then opened the conflict again, and the close button
    asked "Close the merge of “Greeter.swift” without saving?" with Cancel the default. Don't Save
    closed the window, and the file kept what Save had written.
  - The defaults domain was restored and compared unchanged.
  - **Not seen live:** the keys, which the tests drive through `handleKey` (the monitor is the
    compare window's, seen live in M33 Slice 2), and the light appearance.

**2026-10-27: Slice 4 landed** (core, then app). A server file changed under an F4 edit can be
merged instead of overwritten.

- **Decided with Oleg before writing it:** Merge… is the prompt's first button, so Return takes it,
  and Keep Editing stays last and takes ⎋. The merge window counts a server file saved once the result
  is in the editor's copy. The upload is then that copy's ordinary write-back, with its own check,
  question and report.
- **Core:** `EditBaseStore` duplicates a file into a folder of its own under its root, an APFS clone
  where it can, keeping the modification time, and removes only what it made.
- **App:**
  - **The base** (`RemoteFileCache+Bases`). For each copy the cache keeps the copy's own revision
    when it last held the server's bytes, and a base. The base is taken when an edit's watch starts
    on a copy nothing has written since its download: F4, ⏎, a user script, the compare window's
    Edit. It lives in `DirnexRemote/Bases`, which the launch purge clears and no watch watches. An
    archive member keeps none.
  - **Every upload sends a duplicate taken as it is queued**, and once that lands it is the copy's
    base, so the base is what the server holds to the byte whatever the editor wrote meanwhile. A
    record forgotten after an upload of unknown outcome takes its base with it. A refused
    precondition no longer forgets the record, since the server wrote nothing.
  - **Merge… is offered** for a save of one file when the check found the server's copy changed, a
    base is kept, the server's size is within the window's 64 MiB, and the base and the copy read as
    text. It is offered again after a refused precondition on one changed file. Nothing is fetched to
    decide.
  - **Merge…** reads the file's size afresh and brings the server's version down through the
    download funnel, unweighed, since the window's limit is the edit row's threshold. A held copy
    something has written is passed over. The window reads a duplicate of the download. One merge
    window per copy: one with choices not saved comes forward instead, and one already saved closes.
  - **The window's save** writes the result into the editor's copy, coordinated so TextEdit
    refreshes. The first save then makes the server's version the copy's base and its revision what
    the next save is checked against, and every save carries the copy up through
    `writeBack(_:askingOver:)`. A server unchanged since uploads, its precondition read off that
    revision; a write since asks again, Merge… included. The window will not close while the upload
    may still ask. `MergeSaving` gains `carry` and `closed`, and a window closed without a save
    removes the server's version kept for it.
- **Fixed on the way:** a write-back question about one file said Upload All (M33 Slice 6's finding).
  It says Upload, a catalog key already translated with this meaning and unused since the batch.
- **[docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md):** a row for the merge, with footnote www on
  what limits it over SFTP and FTP.
- **Tests:** 4 in the core (`EditBaseStoreTests`) and 17 in three app suites:
  `RemoteWriteBackBaseTests` (6), `RemoteWriteBackMergeOfferTests` (8) and `MergeServerSaveTests`
  (3). Full runs: 4 597 core and 2 033 app tests. One run before the last two tests were added had
  the live server suites up, and they ran, the save-back batch and WebDAV ones included.
- **Negative controls**, each failing its own test: a base kept from a written copy; an upload's
  duplicate not made the base; a forgotten record keeping its base; a merge making the copy its
  path's newest; Merge… offered with nothing changed; a written held copy read as the server's
  version; the carry run before the window counts the save; the window closing while it carries. The
  store discarding outside its root failed the core test.
- **Seen live** in the Debug build against the throwaway SFTP server, on a seeded key tab, driven by
  background computer-use. A shell write to the copy stood in for TextEdit's save.
  - F4 kept the base beside the copy, byte for byte. A server edit and a copy edit raised the prompt
    with Merge… first and Upload second. The window showed theirs' change merged and the two touching
    edits as one conflict. Take Yours and Save put both edits on the server, the copy matched, and the
    one base left was the uploaded bytes.
  - A third write while a second merge was open: Save wrote the copy, the check found the server
    changed and asked over the merge window, and Merge… closed the saved window and opened one with
    the third write. Its save landed all three. TextEdit showed the final text, unedited.
  - The defaults domain was restored and compared unchanged, and the servers were stopped.
- **Found on the way:** a same-size server edit in the minute of Dirnex's own upload was overwritten
  by the next save with no question. An SFTP `stat` is a minute-resolution `ls -la` row with no entity
  tag (docs/NOTES.md ▸ sftp). It is M21's check, not the merge's. Not fixed. (Taken up the same day,
  below.)
- **Left for Slice 6:** WebDAV, whose precondition is an entity tag; the refused precondition's
  Merge… live, which needs a write between the check and the PUT; and the 14 languages. A batch's
  prompt offers no Merge…, by design.

**2026-10-27: the content check, core** (app untouched). Closes Slice 4's *Found on the way* in the
core. Over SFTP and FTP a write-back's re-`stat` is a size and a time, and when both agree the save
now compares the server's bytes with the copy's base, which is the server's bytes at the revision
the copy is checked against.

- **Probed first**, against the throwaway servers (docs/NOTES.md ▸ sftp):
  - `sftp`'s `ls -la` rows for "Goodbye" and "See you", three seconds apart, were byte-identical.
  - `get -a -p` onto an empty file of the same size sets that file to the server's second and sends
    no bytes. A second is still a window.
  - Exec `cksum` reads the content of any size in one round trip (85 ms at 10 MB), but not on an
    `internal-sftp` or non-admin NAS account.
  - `ls -la` plus a 10 MB `get` in one `sftp` session took 125 ms against 75 ms for `ls -la` alone,
    so a download costs its bytes.
  - FTP's `MLSD` and `MDTM` give the second; `LIST` alone missed a rewrite two seconds later.
- **Decided with Oleg:** the bytes, not a finer clock, since a match with the base is proof that the
  upload loses nothing. Bounded by the Settings ▸ Panels limit, and run for each file of a batch.
  Not taken: exec `cksum` for files over the limit, and folding the `stat` and the download into one
  session.
- **Core:**
  - `RemoteFileRevision.matchesOnlyBySizeAndTime(_:)`: not superseded, with no entity tag on both
    sides. That is the verdict only the bytes can settle.
  - `RemoteFetchPurpose.writeBackCheck`, the table's second automatic row. It takes the Settings limit,
    declines past it without asking, and ignores the session's preview allowance.
  - `WriteBackContentCheck` brings the server's file down through `MaterializeRunner` into a scratch
    folder, compares it with the base through `ByteComparator`, and removes it. Its verdict is
    `notAsked`, `noBase`, `overLimit`, `same`, `different` or `unreadable`. Only `different` is a
    change, so a fetch that fails leaves the save where the `stat` put it.
- **Tests:** 10 in `WriteBackContentCheckTests`, over a fake server that lists every file at one
  minute; 3 in `RemoteFileRevisionTests`; 2 in `RemoteFetchPolicyTests`. The automatic-purpose test
  and two refusal helpers now name both automatic rows.
- **Negative controls**, each failing only its own tests: the comparison ignored (the same-minute
  rewrite passed), the download left in the scratch folder, the limit not applied, tags on both sides
  ignored, the row reading the preview allowance, and the row not automatic.
- **Next, the app:** `checkWriteBacks` runs the check per file after its `stat`, a `different` verdict
  raises the changed question with Merge…, then a live run on the throwaway SFTP server and footnote
  www.

**2026-10-27: the content check, app.** Every save of an F4 edit over SFTP or FTP now has the server's
bytes compared with the copy's base when the size and time agree, and a difference asks.

- **App:**
  - `readServer(at:recorded:bases:check:)` `stat`s each destination and runs the check against that
    copy's own base, one file after another as the `stat`s always ran. It is `nonisolated static`,
    so the wiring is testable with no window. The check downloads into `DirnexRemote/Checks`, within
    `AppPreferences.quickViewFetchLimit`.
  - `checkedWriteBacks(_:recorded:readings:sizes:mergeBase:)` turns readings into the prompt's items,
    pure and `static` for the same reason. `writeBackConcern` and `mergeBase` take `contentChanged`,
    so a `different` verdict gets the changed sentence and Merge…, as a size that moved does.
  - Merge… fetches the server's version as before. Its carry goes through the same check against the
    version merged, so a stale copy would cost a second question rather than an edit.
- **[docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md):** footnotes www and mm say what the bytes
  now catch, and what is still open: a file past the limit, a copy with no base, and a write between
  the check and the unconditional upload.
- **Tests:** 5 in `RemoteWriteBackContentTests` over a fake server listing every file at one minute,
  and 2 live in `RemoteWriteBackContentLiveTests`. Over SFTP the server's own file and over FTP an
  `MFMT` stamps both versions to one second, so the server's listing cannot tell them apart and the
  bytes can. Full runs: 4 612 core and 2 040 app tests, 2 014 of them executed with the throwaway
  servers up, the new live suites included.
- **Negative controls**, each failing its own tests: the reader skipping the bytes (5 tests, both live
  ones included), the items dropping the finding (2), the concern ignoring it (4), and the Merge…
  offer ignoring it (1).
- **Seen live** in the Debug build against the throwaway SFTP server, on a seeded key tab, driven by
  background computer-use, with shell writes to the copy standing in for TextEdit's saves:
  - The first save went up with nothing asked, the base became the bytes it sent, and `Checks` was
    left empty.
  - The server's "Goodbye" became "See you", the same 24 bytes, stamped back to the upload's own
    second. The next save asked "The file on the server has changed since you downloaded it —
    someone else has edited it" with Merge… first, and the server kept its edit.
  - Merge… showed "See you" as Theirs. The two touching edits were one conflict. Take Both, Theirs
    First and Save put both on the server, the copy matched, and the one base left was the uploaded
    bytes. A third save went up with nothing asked.
  - The defaults domain was restored and compared unchanged, the servers were stopped, and
    `known_hosts` was put back (docs/LIVE-VERIFICATION.md, on `ssh-keyscan`'s comment lines).
  - **Not seen live in the app:** FTP (its live test drives the real transport), a batch, and a file
    past the limit.

**2026-10-27: Slice 5 landed** (core, then app). A file git has badged U opens in the merge window
on the versions git holds of it.

- **Decided with Oleg before writing it:**
  - Each version is read as a checkout would write it (`cat-file --filters`), so a file under
    `eol=crlf` or a `working-tree-encoding` keeps its form when saved.
  - Resolve Conflict… is a registry command: in the File menu after Compare By Contents, in ⌘K, by
    `run operation`, and first in the right-click menu over a conflicted file, as Put Back leads in
    a `#recycle`.
  - Each pane says what its version is in the operation in progress, since in a rebase git's ours is
    the branch being rebased onto and theirs the user's own commit.
- **Probed first** on git 2.54, in scratch repositories (docs/NOTES.md ▸ git):
  - `ls-files --unmerged --format` gives each stage's mode, object and size in one run (git 2.38 or
    later), and a path given to it is a pattern: `a[1].txt` also listed `a1.txt`, and `:colon.txt`
    listed nothing. `--literal-pathspecs` fixes both.
  - Under `eol=crlf` the stored blob is LF and the working-tree file CRLF; `cat-file --filters`
    gives the CRLF.
  - Which stages exist names the conflict. A deletion on both sides is resolved by `ort` itself, so
    stage 1, 2 or 3 alone comes from a rename to two names. A link both sides changed is a file at
    stage 1 and links at 2 and 3.
  - The git directory names the operation, a worktree's included (`rev-parse --absolute-git-dir`).
  - With a clean file's time made stale, a plain `git status` rewrote the index, and the three reads
    changed nothing in `.git`.
- **Core:**
  - `GitCommand` gains `unmergedStages`, `stageContents` and `gitDirectory`, each a read.
  - `GitStage` parses the listing. `GitConflictStages.choose` takes both sides, with the base when
    there is one, or refuses by name: `deletedByUs`, `deletedByThem`, `deletedByBoth`, `addedByUs`,
    `addedByThem`, `notAFile`, `notConflicted`.
  - `GitOperation.inProgress` reads the markers, a rebase first, since one stopped on a merge commit
    writes `MERGE_HEAD` too.
  - `GitConflictReader`, behind `GitTransport`: the listing decides before a byte is read, a version
    over the window's 64 MiB refuses the read, and git's own words come back when it fails. With no
    git directory to read, the versions still read and no operation is named.
- **App:**
  - `GitProcessTransport` runs the `git` the status provider runs, draining both pipes.
  - `conflictTarget`: one file, not a folder, whose own badge is U. A folder's U is a roll-up.
  - Resolve Conflict… takes the working-tree file's witness, reads off the main thread, and opens
    the merge window, or brings forward one already open on the file. Save is the window's own, with
    the undo store and this pane's journal as the compare window's, so ⌘Z puts the conflicted file
    back.
  - The refusals do not say which side deleted the file, for the rebase's reason above.
  - The command's title and keywords are in all 14 languages, which the coverage test asks of every
    command. The other new sentences are English and wait for Slice 6.
- **Decided in the slice:**
  - **A name only one side has is refused**, as the plan refuses a deletion: there is no second
    version to merge it with. The plan named DU, UD and DD only.
  - **What git holds decides, not the badge**, which a snapshot drew earlier: a file staged since is
    refused as no longer conflicted.
- **[docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md):** a row, with footnote xxx.
- **Tests:** 28 in the core, in `GitConflictTests` (11), `GitConflictReaderTests` (8) over a
  scripted git, and `GitConflictReaderLiveTests` (9) over real git in scratch repositories: each
  kind of conflict, `eol=crlf`, a rebase and a cherry-pick, a name with pattern characters and one
  starting with a colon, and nothing in `.git` changed by the reads where a plain `git status` does
  change it. 9 in the app, in `ResolveConflictTests` (7) and `ResolveConflictReachTests` (2),
  through the shipped transport: the save writes the working-tree file and git still lists `UU`, and
  the right-click menu leads with the command. Full runs: 4 640 core and 2 049 app tests, without
  the live server suites, whose code this slice does not touch.
- **Negative controls**, each failing its own tests:
  - In the core: no `--literal-pathspecs` (the colon name and the argv test), the raw blob for
    `--filters` (the CRLF test), the two deletions swapped, no filter by path, no size check, a
    merge marker asked before a rebase's, a link's mode taken as a file's, and the request's
    spelling of a name in `--path` rather than git's.
  - In the app: a folder taken as the target, the menu entry not offered, a rebase worded as a
    merge, and the transport ignoring git's exit status. With the save's witness dropped, the save
    test hung on the changed-since-read sheet instead of failing, and was stopped by hand.
  - Two controls passed at first, and the tests were fixed. Without `--literal-pathspecs` the live
    test still passed, since the reader keeps only its own path's records; the colon name fails it.
    The `--path` test compared `String`s, which are equal across normalizations (docs/NOTES.md ▸
    Runs and assertions that prove nothing).
  - `--no-optional-locks` changes nothing measurable for these three commands and is kept as
    `status` keeps it.
- **Found on the way:** two full app runs each failed one timing test elsewhere, a 100 ms deadline
  in the WebDAV bin check and a compare window's file watch, while the new fixture built
  repositories with `waitUntilExit` on the main actor. Moved off it, the new suites took 0.6 s
  instead of 5.4 s and the full run passed (docs/NOTES.md ▸ External CLI tools). The link is likely,
  not proven.
- **Seen live** in the Debug build on two scratch repositories, one stopped in a merge with a `UU`,
  an `AA` and a `DU` file and one stopped in a rebase. The first look had the screen locked, so it
  read only window sizes; the rest was driven by background computer-use, with full-screen control
  for the right-click menu.
  - File ▸ Resolve Conflict… on `Greeter.swift` opened "Merge of “Greeter.swift”": Yours "HEAD, the
    branch you’re on", Theirs "The branch being merged in", yours' doc comment and theirs' farewell
    already merged in blue, the two greetings one orange conflict, and Save held back.
  - Take Theirs and Save wrote the merged file with no marker in it, and git still listed `UU
    Greeter.swift`. The save left the index as it was: its time was the second of a plain `git
    status` run by hand before the launch. Every read after that left both `.git` directories
    exactly as they were, and the rebase repository's as it was built.
  - On `gone.txt` (`DU`): "Couldn’t resolve the conflict in “gone.txt”" and the deletion sentence.
    On `added.txt` (`AA`): Base "None: both sides added the file", empty, with one conflict. On the
    rebase: Yours "HEAD, the branch being rebased onto" with upstream's line, and Theirs "The commit
    being replayed" with the user's own.
  - A right-click on the conflicted file led with Resolve Conflict… and a separator; on `keep.txt`
    the menu began at Open.
  - A saved window and one with no choice closed without asking.
  - The defaults domain was restored and compared unchanged.
- **Fixed after the live look:** the Result pane's subtitle named the file's full path, and a
  working tree's path cut it mid-sentence ("…tage it with git add"), shorter still with the base
  shown. It says "Saved to the working tree; git add marks it resolved" now, since the window's
  title names the file, and it fits in four panes (seen live).
- **Left for Slice 6:** the 13 languages for the new sentences, and the server entry's WebDAV run.

### Still open

Everything through M32 is shipped, and the record of it — the milestone checklists, the sixty
dated passes that landed outside a milestone of their own, and the reasoning behind every decision —
is in **[docs/HISTORY.md](docs/HISTORY.md)**. What is still open, rather than merely imaginable, is
the *undone* column in the table above, plus the list below. Everything that came off this list came
off in the eight days to **2026-09-01** (HISTORY.md ▸ the follow-on log): both of M25's own
leftovers — *"A remote attribute change cannot be undone"* and *"Many remote write-backs do not
coordinate"* — and the last parity cell, *"No multipart upload over SFTP or FTP"*, which closed by
being **half built and half proved impossible**. SFTP splits a large upload into parts that go at
once and are joined by the server (measured 3.6× through the shipped path, 16.92 s → 4.73 s on
32 MiB over a 2 MB/s-per-connection link); FTP cannot, and that is now a measurement rather than an
assumption — it has no way to write at an offset into a file that does not already exist at full
length, and no way to make one without sending the file twice. The refusal moved to
[docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md)'s *"cannot be closed from here"* list with the
numbers behind it. What remains here is M15's own cut, and one gap a bug report opened on
**2026-09-04**.

- **The thumbnail grid, brief view and the `PaneSurface` extraction** — M15's cut, and one unit
  rather than three items, argued in HISTORY.md §M15. Any future grid inherits two constraints from
  it: skip `FileEntry.isDataless` rows, and move sort off the column header first.

- **Dirnex's own SMB share picker.** With the Share field blank the app hands the mount to NetFS's
  own UI (`kNAUIOptionAllowUI`), which is macOS's share picker — the only way today to browse a
  server's shares. It costs two things the user sees. A failed pick raises **two** dialogs,
  NetAuthAgent's generic *"There was a problem connecting to the server"* and Dirnex's after it; and
  NetFS never reports back *which* share was picked, so the second one cannot name the folder that
  failed. That is what makes it worth a slice rather than a nicety: a share the account may not use
  and a share that is not there come back as **one** status (ENOENT), so only the *listing* tells
  them apart — and the server names a refused share to the very account it refuses. The listing is
  reachable in-process, measured 2026-09-04 against a real NAS: `EnumerateShares` on the SMB plugin's
  `NetFSMountInterface_V1` (`<NetFS/NetFSPlugin.h>`), credentials in memory, no subprocess and
  nothing in `argv` (docs/NOTES.md ▸ SMB). One enumeration therefore buys all three — the picker, the
  exact refusal (*"“dirnex-test” doesn't have permission to use “Photos”"* rather than a sentence
  that has to hedge), and the duplicate dialog going away. The hedging wording shipped 2026-09-04 as
  the half that needed no new machinery.

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
| App test host | The host is the app, so its `UserDefaults.standard` is the user's own `com.dirnex.Dirnex`: it installs no app delegate, and a store a test writes takes a scratch domain. CI exports the domain before and after the run and fails on any change by content (`scripts/check_defaults_unchanged.py`) |

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
| M33 grows the compare window into the text editor M11 refused, one reasonable step at a time: copy a block, then fix one character, then type. And a save can write bytes nobody chose: an encoding, a byte-order mark or line endings the file did not have | M31's row named a Save command appearing *before the decision* as its tell, and M33 is that decision, taken for line operations only. The panes stay `isEditable = false` and an edit is a `LineEdit` on the core model, so the tell is now a keystroke reaching a pane's text storage, or find and replace appearing. Hand edits go to the user's own editor, which the window watches. Against the quiet error: an unedited side must encode back byte-identical over the repository's history, a side that does not opens read-only with the reason named, and a character the encoding cannot hold is refused rather than substituted |
| M34's merge is wrong in the quiet direction: a region read as changed on one side when both sides changed it drops an edit, and nothing on screen shows what went missing. A stale base does the same | git is the oracle in two styles, `--diff3` for the regions and `--zdiff3` for the trimming, and the properties that need no git (a text merged with itself comes back, a side equal to the base yields the other, every one-sided change survives) run over random texts. No ignore option reaches a merge, the uploaded bytes replace the base after every upload, and Save is refused while a conflict is open. The tell is a merge offered without a real base, such as the server's copy standing in for one, or an ignore option reaching `ThreeWayMerge` |

## 7. Open questions

**None open.** M25's was the last, and it closed on 2026-08-29. Every question this plan asked since
M0, and how each one closed, is in [docs/HISTORY.md](docs/HISTORY.md) ▸ **The questions the plan
asked**.
