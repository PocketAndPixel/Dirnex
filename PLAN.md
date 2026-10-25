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
   Swap Sides carrying unsaved edits with their side; the close prompt.
3. **Saving a local file** (core, then app). First a probe of what a save must keep, against
   TextEdit's and BBEdit's own saves: mode, owner, Finder tags, other extended attributes, an ACL,
   the creation date, a symlink (saved through to its target) and a file with a second hard link.
   Then the writer, the witness check, the journal step and ⌘S.
4. **Saving anywhere else** (app). Server and archive sides through the write-back; the conflict
   dialog's window read-only; the Synchronize row the window came from compared again after a save.
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
