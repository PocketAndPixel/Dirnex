# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: **M0–M38 shipped**, **M39 open**, **M40 planned** (14 languages; M29's licensing is on in betas, off in stable until the
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

### Shipped: M0 → M38 (2026-07-05 → 2026-11-11)

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
| M8 | The sidebar as a first-class surface | 07-21 | Dragging a *remote* (SFTP) folder into the sidebar — stays menu-only, **since shipped** 2026-11-10 with M38 Slice 4, for SFTP, FTP, WebDAV and S3; Recents ordered by modification date, not the true last-used stamp |
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
| M22 | Find Files on a connected server | 08-16 | **Content-grep and tags remotely** — no remote backend can answer either without reading every file, so `SearchFields` withholds them rather than skipping the clause (which would return *more* results under the same name); **an exact remote timestamp**, since FTP's `LIST` stamps are year- and zone-less on the server's clock — **since shipped** over FTP for servers that answer `MLSD` (2026-10-19); **searching an S3 *account* pane**, whose rows are buckets — "search every bucket" is a different and much more expensive question than the one ⌥F7 asks — **since shipped** 2026-11-10 with M38 Slice 5, each bucket up to a bound stated before the search; and GNU `find -printf`, retired at the probe rather than handled, since choosing it would have shipped the common case unverified — POSIX `find … -exec ls -ldn {} +` instead, at the cost of the date column |
| M23 | Copy, paste and drag, wherever the file is | 08-26 | Dragging a *folder* out of a server as a promise (a promise is one file; a recursive fetch behind a Finder drop has no progress surface and no way to stop it) and dragging an archive **member** out to another app, for the same reason one layer along — an encrypted archive would have to raise a passphrase sheet behind somebody else's drop, and `extractArchiveSources` reports failures with an alert rather than through a completion handler, so it would need Slice 4's always-answers contract first (taken by the user 2026-08-26, F5 copy-out being the route); `⌥⌘V` move-paste into an archive, which stays gated where it was; a *drop* into a browsed archive, where ⌘V adds by repacking and a drag does not; and the pasteboard as an automation surface — nothing here is scriptable that F5 was not. **Left for a human**, since a drag *session* cannot be synthesized: an actual drag between two panes and a Finder drag onto a connected server. A drag from a server into Finder **ran live 2026-10-24**, where a marked set dropped nothing until it was fixed (HISTORY.md §M32) |
| M24 | Every local-only feature, on a file that is not local | 08-28 | **Content-grep and tag search on a server**, withheld at M22 for the reason that has not changed — no remote backend can answer either without reading every file; **ACLs and extended attributes remotely**, which SFTP and FTP do not carry at all; **Open in Terminal for an SFTP account**, which is an `ssh` session and a different feature — **since shipped** 2026-11-10 with M38 Slice 3; and a **folder that is not already here**, refused by every one of the seven hand-offs — a folder is an unknown number of objects in an unknown number of requests, and copying a tree out is F5's job |
| M25 | What a remote write carries, and what a remote delete costs | 08-29 | **A Trash the protocols do not have** — taken at §7 on 08-29, and the one part of the milestone that closed by not being built; **owner and group in a remote Get Info**, because `chown`/`chgrp` take a numeric id while `sftp`'s own `ls -la` prints names, so a panel built on a listing has nothing to send — **since shipped** 2026-11-10 with M38 Slices 1–2, by name over the exec channel; **comparing by timestamp on FTP and S3**, refused by construction and always will be — `LIST` is year-less and zone-less, and an S3 `LastModified` is when the object was *written*; and ACLs and xattrs again, which is a limit rather than a gap |
| M26 | Move to Trash, wherever the file lives | 08-31 | **The remote backends**, which have no Trash at all and are already degraded to a confirmed permanent delete (§M5, and M25 §7's decision not to invent one); **chasing the refusal further into TCC and `fileproviderd`**, which is not observable from here past the three candidates already eliminated — the fix does not depend on knowing which policy denies; and **Put Back for an item *Finder* deleted out of a provider domain**, or for anything trashed before the store shipped, both of which keep the honest answer the restore flow already gives by name. A **third** origin source landed 2026-09-20 — a network share's own `#recycle`, where the bin mirrors the original path so there is no record to be missing (HISTORY.md ▸ the follow-on log) |
| M27 | Legacy code-page archive names | 09-09 | **Inferring** the code page — no reader can, and a wrong guess is a plausible name for the wrong file, so it is a chooser over a preview and never a detector; **preserving an un-representable name byte-for-byte**, the rejected streaming rewrite, which keeps bytes nobody can read and still cannot extract that row *out* of the archive; and **persisting the declaration** across sessions, since it is a guess the user made about one archive and a wrong one silently outliving the session is worse than being asked again |
| M28 | iCloud Photos, as folders of originals | 09-13 | **Import, delete and album edits**, each a write Photos mediates with its own confirmation; **smart albums** — one a person made is returned by no PhotoKit fetch, and the system ones are views over the library rather than places; **shared albums, the Shared Library and hidden photos**, left out as Photos' own Library view leaves them out; **a per-asset time zone**, which PhotoKit does not expose, so months are cut in the Mac's; **⌘L inside the library**, which has no real directory to start from; and **Photos' lowercase `.mov`** for a Live Photo's movie, since a row's name is part of its path. **Exercised later that evening**: the download of an original that is only in iCloud, on clips recorded for it — the bar sat at zero and Stop was ignored until the request carried a progress handler (HISTORY.md §M28); after that fix a 219 MB copy arrived byte-identical and Stop on a 276 MB one stored nothing |
| M29 | A license, and the reminder it removes | 10-01 | **Revoking a refunded key inside the app** (the server marks it; an in-app list waits until refunds are actually abused); **trials that stop working, and activation limits**; **any copy protection beyond the signature**, since the source is open and the reminder is a request, not a lock; and **the Keychain** for the key, which is signed rather than secret. **Seen only in tests or a Debug build**: the Renew reminder on a release build, the prominent Renew… in Settings ▸ License, a pasted production key, and the 13:00 rule |
| M30 | Report a Bug, and a Help menu to hold it | 10-07 | **Anything the user didn't type or tick** in a report: no logs, no screenshots, no file names or paths, one crash report at most; **the website** naming Help ▸ Report a Bug…, until a stable release has it (the private repo's C8). **Seen only in tests**: Email Instead's draft, since this Mac's Mail has no account |
| M31 | A compare window of our own | 10-22 | **Editing, copying a block across and saving**, a later milestone's decision — **since shipped** as M33, for whole lines; **a three-way merge** — **since shipped** as M34; **a file over 64 MiB** in the window, refused by name and left to the external tools; **a binary comparison**. **Seen only through a probe**: a Mac with no external diff tool. **Not run live**: an external tool from the conflict dialog, FTP and S3 pairs, and Escape |
| M32 | WebDAV | 10-24 | **Depth infinity**; **locks of our own**, which M38's probe found add nothing worth holding one; **NTLM, Negotiate and OAuth**, NTLM and Negotiate **since shipped** 2026-11-10 with M38 Slice 6; **setting a time on Apache**, which has no way to take one (Nextcloud's `X-OC-Mtime` is used where it is answered); **Apache's offset PUT** as a segmented upload; **quota**, **since shipped** 2026-11-10 with M38 Slice 7 where the server reports one; **CalDAV, CardDAV, versioning and WebDAV ACLs**; **a Trash**, which the protocol does not have, so a NAS's `#recycle` softens the delete sheet instead. **All run live 2026-10-24**, on the NAS and a throwaway Apache, which found and fixed three bugs: ⌥F5 with a server folder in the set, Put Back into a folder deleted since, and dragging a marked set out (HISTORY.md §M32) |
| M33 | Copy a change across, and save | 10-26 | **Typing in a pane** and **find and replace**, M11's call; **copying every change at once**, which is F5; **a save that changes the encoding or the line endings**, since a save keeps both; **editing in the conflict dialog's window**, whose right-hand file waits on that dialog. **Not run live**: FTP and S3 sides, a Synchronize row compared again after a save, a side with nowhere to save, and an editor's unsaved edit met by a save |
| M34 | A three-way merge | 10-27 | **Synchronize as an entry point**, until a sync keeps a record of the last one; **three files picked by hand**, whose base would be a guess; **an archive member** changed behind an edit; **being git's merge tool**, which needs a command-line entry point; **conflict markers** in any form; **a merge that ignores whitespace**; **a binary file**. **Not run live**: FTP in the app, a batch's question, a file past the content check's limit, the take keys and the light appearance. Over SFTP and FTP a write between the check and the upload goes unseen, since that upload carries no condition |
| M35 | An SMB server's shares, as a pane | 11-05 | **Anything that writes to the list**: creating, renaming or deleting a share, or copying onto it; **a comment column**; **a way up from a share Finder mounted**, which keeps `..` → `/Volumes`. **Not run live**: the plain permission sentence, since no share is listed to `dirnex-test` and refused; ⌘Return into the other pane; a saved sidebar row; `..` from a share typed into the sheet while its server is not connected; and marks inside a share after a relaunch |
| M36 | Drag and paste, where M23 stopped | 11-08 | **A folder for Teams, Chrome and the rest of Chromium**, which refuse a promise — **since shipped** the same day as a zip of the folder for every app but Finder, after Gmail answered "Attachment failed" for a folder, and **since 2026-11-09 as the folder itself, with the zip for an app the pointer enters with ⇧ held**, after VLC was handed a zip of a whole season (HISTORY.md, after §M36); **a folder inside an archive**, which probe P1 answers for too, leaving the extraction of a subtree behind the promise; **a folder dragged with files** losing its promise once the pointer has been over another app, the board's rewrite to file URLs being one way. **Not run live**: Edit ▸ Move Items Here being enabled, F5 from a server into an archive, an archive member into a Chromium app, and a server folder crossing another app on its way to Finder |
| M37 | Compare and merge, past M31 and M34 | 11-09 | **Aligning a byte comparison across insertions**, which needs gaps in the rows and a size limit, and has no oracle; **whitespace in a merge's regions**, labelled and offered as a take instead, so no edit goes missing in silence; **a sync's record with a side on a server**, **since shipped** 2026-11-11 with M38 Slices 8–9, keeping only what each sync copied; Go to Offset, copying bytes and Swap Sides in the byte view |
| M38 | Remote: what M8, M22, M24, M25 and M32 left | 11-11 | **WebDAV locks of our own**, since a lock around the save cannot see a write made before it, and one held from the download on would lock everyone else out while an editor is open; **OAuth for WebDAV**, which needs a sign-in flow and a token store; **a faster Find Files walk in Photos**, which saves about 1 ms a month while a name costs 2.0 ms an asset; **a quota over SFTP**, which the protocol does not carry. **Not run live**: real AWS, IIS, a Windows domain and a hosted Nextcloud; root over GNU coreutils; a password pin reconnecting through the Keychain itself; and the NAS for Open in Terminal, whose accounts may not run a command |

### Next

**Planned 2026-11-07: M36–M40.** These five milestones take up what earlier milestones left undone by
choice rather than for a hard limit, in the order Oleg set: drag and paste, compare and merge, remote,
Quick View, and everything else. Each item names the milestone that left it and the reason given
then, because that reason is what the design has to answer. Nothing left here has been probed yet. Each
milestone opens with its probes, and its slices are written then (CLAUDE.md ▸ How to work here). An
item whose reason still holds after the probe goes back to the *undone* column with what the probe
found.

M36 (drag and paste, where M23 stopped) closed 2026-11-08, M37 (compare and merge, past M31 and M34)
2026-11-09 and M38 (remote: what M8, M22, M24, M25 and M32 left) 2026-11-11, and all three are archived in
[docs/HISTORY.md](docs/HISTORY.md).

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

**Opened 2026-11-12.** Probed on macOS 26.7.1 with the system WebKit, Chrome headless and a throwaway
`http.server` whose access log was the network instrument:

- **WebKit renders a `.webarchive` from its own subresources and asks the network for nothing it holds.**
  A real archive written by `createWebArchiveData` loaded by `load(_:mimeType:"application/x-webarchive"…)`
  and by `loadFileURL` alike (so M16's "needs `loadData`" was only half right), CSS and image applied,
  and the server saw no request. The page's `location` is the archive's own `http://` URL, and
  `decidePolicyFor` sees one main-frame navigation, to the base URL passed in.
- **The shipped rule list blanks an archive.** Block `.*` then re-admit `^file://` blocks the archive's
  *own* subresources, since their URLs are the originals: heading unstyled, image 0×0.
- **An archive asks the network for what it lacks.** With no rules and scripts on, a missing image, a
  `fetch` and a `new Image()` pixel each reached the server. A `fetch` of a URL the archive holds did
  not.
- **Re-admitting each archived URL looked like the answer and is not.** Block `.*`, re-admit
  `^file://`, then each archived URL exactly, for the `document`, `image`, `style-sheet`, `script`,
  `font`, `media` and `svg-document` types: with scripts on the archive rendered whole, the missing
  image and both script requests were blocked, and nothing reached the server (compiling cost 1.2 ms
  for 3 URLs, 15 ms for 1 000; one non-ASCII character fails the whole list). **But an allowed URL is
  a request WebKit may make.** A subframe whose archived name did not match the one WebKit generates
  (`<!--frame1-->`) was fetched from the server, and its image after it. WebKit's own archives carry
  the right names and stayed silent, frames included; a crafted file controls both the names and the
  HTML.
- **So an archive is sealed instead: every archived origin moves to a scheme of ours.**
  `http://127.0.0.1:8765/…` became `x-dirnex-archive://o1/…`, in each resource's URL and in the bytes
  of every text resource, paths untouched so relative references still resolve. Under one constant
  rule (re-admit `^x-dirnex-archive:`) WebKit's archive drew its script, web font, CSS background,
  SVG and subframe from itself, with zero requests. With the frame's name deliberately wrong the
  frame came up empty, still with zero requests: a miss has no network path, not even DNS, which an
  `http://o1.dirnex.invalid` host (which also worked) would have had. A reference the rewrite misses
  keeps its real origin, which the rules block, so every miss fails closed.
- **WebKit has no MHTML.** A Chrome `Page.captureSnapshot` file loaded as `multipart/related` or
  `message/rfc822` drew its raw headers as text, and `loadFileURL` failed ("Frame load interrupted").
  Converted to a webarchive and sealed, it rendered whole with zero requests: windows-1252 text by its
  own `<meta>` (a main resource with no encoding name honours it), an image at a path with spaces and
  `é`, and the iframe. Chrome writes CRLF, every reference as an absolute URL, quoted-printable HTML
  and CSS, base64 images, an iframe as `src="cid:frame-…@mhtml.blink"`, a frame's `<style>` as a
  `text/css` part whose `Content-Location` is itself a `cid:`, and no scripts. **A frame finds
  resources only in its own archive**, not its parent's: the frame drew unstyled until the parts it
  names were copied into its subframe archive.
- **Quick Look has a webarchive generator and none for MHTML** (`qlmanage -m`); `-p -o` wrote no
  bundle for either. Both UTIs exist: `com.apple.webarchive`, `org.ietf.mhtml`.
- **WebKit's MathML is good enough to be the target.** With scripts off it drew a fraction, nested
  roots, sub- and superscripts, `∑` with limits, an integral, a matrix and double-struck letters. A
  plain `(` stretches unless it says `stretchy="false"`.
- **PDF**: `createPDF` gives one 800 × 10 420 pt page of a long page in 73 ms. A headless
  `printOperation` (`runModal(for:)` on an unshown window, `jobDisposition = .save`) gives 17 A4 pages
  in 781 ms, text selectable. The dark appearance leaks into the PDF, so an export renders light.
- **The corpus.** 1 440 distinct `.md` files of Oleg's own and 5 411 in dependencies on this Mac. A
  relative link to another file: **35 %** of his own (25 % to another `.md`). GitHub alerts
  (`> [!NOTE]`), which Dirnex draws as a blockquote with `[!NOTE]` in it: **5.7 %**. Everything else
  M39 names is under 0.5 %: definition lists 7 files, emoji shortcodes 3, math 2, footnotes 1, wiki
  links 0 (the hits were `[[String]]` in prose). Every mermaid fence is `graph`, `flowchart` or
  `sequenceDiagram`, which already draw; one `stateDiagram-v2` sits in a dependency.

Decided before Slice 1 (2026-11-12, Oleg, on the probes above):

- **A link to a local file moves the pane**: its cursor lands on the target, entering the target's
  folder when it is elsewhere, the preview follows the cursor, and the pane's own Back is the way
  back. So the file list stays the navigation (M11's reason) and the preview gains no history. A
  `#fragment` scrolls once the target renders. A web link opens in the user's browser, since a
  click is a deliberate act where a cursor step is not.
- **Mermaid: all four types**, state, class and ER on the flowchart's layered layout, gantt on a time
  axis of its own.
- **A slideshow timer, no filmstrip.** In the two full sizes a key starts a timer that steps the pane's
  cursor through the folder's images. The filmstrip goes back to *undone*: it is a second file list,
  which is M15's grid under *Still open*.
- **Export lands like F5**: a sheet with the name and the other pane's folder, both editable, then a
  queued copy from a temp file, with F5's conflict policy, undo and remote targets. HTML is one
  self-contained file, images inlined. PDF is paginated through the print path, in the light palette.
- **Web archives** are sealed in the core and loaded under one constant rule: a `.webarchive` is read,
  an `.mhtml` is converted to one, and either has every origin moved to `x-dirnex-archive:` before
  WebKit sees it. Both are one style, the page, with the user's JavaScript switch.
- **RTF** gains its source as a fifth dual-style family, opening on the page and remembered apart, so
  today's rendering stays the default. `.rtfd` and `.odt` keep one style: neither is text.
- **GitHub alerts join M39**, on the corpus. Not asked; drop them if unwanted.
- **Themes: VS Code (today's), Xcode and GitHub**, each a light and dark pair held to 4.5:1 on the
  system text background, for the source view and rendered fences alike. Asked at Slice 10
  (2026-11-14): all three, picked in Settings ▸ Panels over a code sample.

#### Slices

1. **Web archives in the core** (additive). The webarchive plist read and written, subframes
   included; an MHTML parse (MIME headers, the boundary, quoted-printable and base64, charsets) into a
   webarchive, frames named as WebKit names them and given the parts they reference; and the seal.
   Tested against the Chrome and WebKit files the probe wrote. **Landed 2026-11-12**: `WebArchive`,
   `MIMEEntity`, `MHTMLArchive` and `WebArchiveSeal`, 47 tests over five captures in
   `Fixtures/WebArchive` (the `types` capture taken again without its `@font-face`, which had copied a
   system font into it). The core's own sealed output, written by a scratch package and loaded under
   the one rule with scripts on, drew all five whole with zero requests in the server's log, frames
   included and the archived responses dropped. Sealing costs 0.1–0.7 ms. A WebKit archive names its
   frames in creation order, not document order: the `<object>` before the iframe is `<!--frame2-->`.
2. **Web archives in the app.** Routing for both UTIs and `.mht`, a page case under the sealed-scheme
   rule, find, LOCATION-SUPPORT.md, and a live run against a server log. **Landed 2026-11-12**:
   `QuickViewPreviewView+WebArchive` reads, converts and seals off the main actor (a 65 MB webarchive
   in 19 ms, an 88 MB MHTML in 232 ms, release build), up to 64 MB; the shipped rule list gained one
   rule, re-admitting the sealed scheme; and the web view's `.archive` page lets its frames load in
   the scheme but never follow a click, and takes its `#anchor`s against the archive's own document.
   The navigation delegate moved to `QuickViewWebView+Navigation.swift` to stay under the length
   ceiling. 8 app tests, one of which drew a sealed image under the shipped rules and failed with the
   third rule removed. **Run live** in `app.dirnex.Dirnex.live`, full window, scripts on: WebKit's
   own archive (script, CSS background, SVG, iframe), Chrome's MHTML with its frame, and a crafted
   archive carrying the probe's leak (a misnamed frame at the server's real URL, a missing image, a
   `fetch`, a pixel) all drew as designed, the crafted frame empty, and the server logged **no
   request** across the three. Find and zoom come with the web surface, which picks the visible
   backend. Not run live: a server or a zip as the location, which reach the same code through the
   local copy.
3. **RTF source and page.** `QuickViewDualStyleKind.richText`, a small control-word scanner, the
   header, 14 languages. **Landed 2026-11-12**: `SyntaxRTFScanner` colors a control word as a keyword
   and its parameter as a number, `\'hh`, `\\`, `\{`, `\}`, `\~`, `\-` and `\_` as the characters they
   are, a backslash before a line break (Cocoa's paragraph mark) as a keyword, braces as tags, and a
   `{\*…}` group, which the spec lets a reader skip whole, as one comment: most of a Word file and none
   of its text. One saved depth while such a group is skipped is all it remembers; `\bin` and a
   picture's hex are left as text and say why. The family opens on the document and remembers apart
   (`Dirnex.pref.quickViewRichTextStyle`), and the header calls it **Document** rather than Page, whose
   Chinese is a *web* page. The corpus: 1 779 distinct RTF files on this Mac, all Cocoa's but 16 of
   Word's and 1 of Aspose's, none with `\bin`; all of them scanned in 90 ms in a release build, the
   largest (1.37 MB) in 6.4 ms. 16 core tests and 5 app tests, and the two older RTF tests now ask for
   the document. **Run live** in `app.dirnex.Dirnex.live`, full window: TextEdit-shaped, Word and
   1.37 MB files in both styles, `1` on RTF leaving Markdown on its page and `2` on Markdown leaving
   RTF on its source, and an RTFD drawn as its document with no style offered. Seven RTF files here,
   six of them Software Update's Portuguese and Hindi legal texts, carry raw UTF-8 under
   `\ansicpg1252`: the document reads them as code page 1252 ("estÃ¡"), as the spec says to, and the
   source shows what the bytes say ("está").
4. **Following a link, core.** An `href` resolved against the document's location on its own backend:
   percent-decoding, the fragment split off, a target outside the backend refused by name. **Landed
   2026-11-12**: `DocumentLink.resolve(_:from:)` answers `.sameDocument(fragment:)`, `.location(VFSPath,
   fragment:)` on the document's own backend, `.external(URL)` for `http`, `https` and `mailto`, or
   `.refused` with a fact and no sentence (the app words it): another host, a `file:` URL from a
   document not on this disk, any other scheme by name (`javascript`, `ftp`, `shortcuts`, a drive
   letter), or a name that decodes to hold `/` or NUL. **Probed first**, because WebKit hands
   `decidePolicyFor` only the URL it resolved, never the `href`: a generated page loaded under
   `DocumentLink.baseURL(for:)`, the document's own path in `x-dirnex-document:///`, delivered every
   synthetic click there with the backend path as its path, `#anchor` against the document (and it
   scrolled), `""` as the document and `.` as its folder, names with a space, `é` and `#` round-tripped,
   and `//host/x` with `host` as the host. So the resolver reads the `href` as written and WebKit's URL
   alike, and 25 probed pairs pin both to one answer. **One departure from the line above**: `..` past
   the root stops at the root rather than being refused, as RFC 3986 and WebKit both do, since WebKit
   clamps before the app sees the click. RFC 3986's steps are written out rather than asked of
   `URL(string:relativeTo:)`, which re-encodes every `%` in a string once it meets one invalid
   character (`My%20Docs/100%.md` read back as a folder named `My%20Docs`). 17 tests, 87 cases. **For
   Slice 5**: the generated page moves to that base URL (today's `file://` folder resolves `""`, `.` and
   `#anchor` all to the folder); the preview needs the document's `VFSPath`, which it does not hold
   today; and an HTML file from a server is loaded from its local copy, so its links come back as
   `file:` URLs there and this resolver refuses them, which Slice 5 either maps or leaves to local HTML.
5. **Following a link, app.** The click moves the pane, the fragment scrolls after the render, a web
   link opens in the browser; at all three sizes and on a server. **Landed 2026-11-13**: a Markdown
   page loads under `DocumentLink.baseURL(for:)` of the file's own location, which the window now hands
   every surface with the file (`PanelViewController.quickViewSourceLocation`). A click the navigation
   policy refuses is resolved and handed to the window (`QuickViewWebView+Links`,
   `BrowserWindowController+QuickViewLinks`), which moves the **active** pane at every size: a target the
   listing shows takes a cursor step with no request, anything else is `stat`ed and then entered with the
   cursor on it (`PanelViewController+LinkTarget`), and from a results listing it opens in a new tab so
   the results stay. A heading waits on the surface (`QuickViewLinks.pendingFragment`), survives a
   server file's download card, and is scrolled to after the load. `http`, `https` and `mailto` go to
   `NSWorkspace`; a refusal is an alert naming its reason, in 14 languages, and so is a file that is not
   there ("There's no “nope.md” in “docs”."). HTML files follow links too: a local one resolves its
   `file:` URLs; **a server's or an archive's is now drawn from its bytes under its location's base URL**
   (`Page.copied`), because the live run found every link on one dead. On a `file:` page WebKit asks the
   delegate only about a file that exists inside the read access, and the copy sits alone in a temp
   folder (docs/NOTES.md ▸ Previews: web views). That made Slice 4's copy-relative helper unneeded, and it
   went. A saved page's sealed links go back to their real URL (`WebArchiveSeal.originalURL(for:origins:)`,
   the seal's table kept beside the page), and a converted office document follows web links only. The
   `Page` enum moved to `QuickViewWebView+Page.swift` to keep the class under the length ceiling. 16 app
   tests in three suites: what each kind of page resolves against, the policy, the pending heading, the
   wording; real clicks in a real page, including the server HTML case; and a real pane landing. Negative
   controls: without the scroll call, with the old `file://` folder base, without the existence check,
   and with server HTML loaded from its copy, each failed exactly its own test. **Run live** in
   `app.dirnex.Dirnex.live`. At pane size on this disk: an anchor scrolled in place; a sibling, a sibling
   carrying `#far-section`, `../top.md`, `sub/deep.md#part-two` and both links in an HTML file moved the
   pane and scrolled; Go ▸ Back came home on the row it left; and missing, `//nas.example` and `ftp:`
   each raised their alert. At full window: an HTML link and a Markdown link with a heading. On a
   throwaway `sshd`: the cross-folder link with a heading cost 3 sessions (stat, listing, download) and
   opened scrolled; a same-folder link cost no listing; the server HTML file's link worked after the
   fix and not before; a missing file got its sentence. Inside a zip: the cross-folder link with a
   heading. At full screen (run 2026-11-13, at Oleg's go): `sub/deep.md#part-two` entered `sub` and put
   the heading at the top, just under the strip the header drops into; Go ▸ Back came home and a second
   click did the same; a sibling took a cursor step; an anchor scrolled in place; and the missing file's
   alert came up over the full-screen window and left it there. **Not run live**: a web link opening
   the browser; a saved page's link; a link from a results listing, which its test covers.
6. **Markdown: GitHub alerts, footnotes and emoji shortcodes** (core and stylesheet). The shortcode
   table's source is asked when the slice opens. **Landed 2026-11-13**. Oleg chose GitHub's gemoji:
   v4.1.0's `db/emoji.json` (MIT, 1 913 names) is reduced by `scripts/generate_emoji_shortcodes.py`
   to one string literal, `MarkdownEmojiTable.swift`, and its notice is in NOTICE. GitHub writes none
   of these rules down, so each was read off GitHub's own renderer: its `/markdown` API, and real files
   served with `Accept: application/vnd.github.html` (docs/NOTES.md ▸ Working rhythm).
   **Shortcodes** (`MarkdownEmoji`) do not follow a word boundary. Within one run of text, which is
   the text between two elements with soft breaks included, the first `:word:` decides. If it opens
   the run or follows ASCII whitespace, every known name in the run is drawn; if not, none is. So
   `10:30:00 :smile:` stays text, and `requestOpenLink(source:link:)` keeps the selector that a
   plain search for names turned into `source🔗`. Shortcodes are drawn at render time, so
   `## :bulb: Highlights` draws 💡 and anchors as `#bulb-highlights`, as GitHub served nodelib's
   README; an image's alt keeps its shortcode. **Alerts** (`MarkdownAlert`): the marker in any case,
   alone on a quote's first line with something under it, inside a list item too (eslint-plugin-
   import's `order.md`); a second marker in the same quote stays text in the first alert, as GitHub
   draws baseline-browser-mapping's README. GitHub's classes and palette, which scores 4.87–6.60:1 on
   this page's own backgrounds, SF Symbols as CSS masks where GitHub draws Octicons, and titles in 14
   languages (`QuickViewMarkdownAlerts`). **Footnotes** (`MarkdownFootnotes`): a label holds no
   whitespace and matches in any case, and the first definition wins. Footnotes are numbered by first
   reference, with `fn-1` and `fnref-1-2` anchors percent-encoded as GitHub's are, and a `↩` back to
   every reference. A definition interrupts a paragraph and may sit inside a quote or an item; it
   continues lazily or at four columns. One departure: a reference in a heading adds nothing to its
   anchor, where GitHub gives `#heading3`. A block that draws nothing now leaves no line behind, which
   also took the stray newline off an empty `[[_TOC_]]`. 28 core tests and 7 app tests; the app's
   follow a footnote down and back in a real page, an encoded label included. **The corpus**: all
   27 756 `.md` files in the home folder render. 297 alerts are drawn where a text search finds 299
   markers, and the two are the baseline-browser-mapping case above. 14 files have footnotes. The
   shortcode pass cost 5–7 % of the whole render until a byte-level check went ahead of it; the corpus
   now renders within noise of before (23.9 s against 23.8 s, release build). **Run live** in
   `app.dirnex.Dirnex.live`, full window, dark appearance: emoji in a heading, its TOC entry and
   prose; `:smile:` kept in code and after `10:30:00`; the five alerts in their colors with their
   icons; footnote numbers 1, 2, 1. A click on the first jumped to the notes, which drew `↩ ↩²` and a
   two-paragraph note. `↩²` went nowhere visible, because its target was already in view: a probe in
   a real page read the hash as `#fnref-1-2` with the scroll unchanged, which is WebKit's behavior
   (docs/NOTES.md ▸ Previews: web views). **Not run live**: the light appearance, a translated title,
   and a server or archive location, which reach the same render through the file's bytes.
7. **Markdown: wiki links and definition lists.** Wiki links go through Slice 4's resolver. **Landed
   2026-11-14.** **The corpus first**: 12 603 distinct `.md` files in the home folder hold no definition
   list and no real wiki link outside Claude's memory notes (`[[dirnex-project-goal]]`, each naming a
   sibling `.md`), but they hold the prose each obvious rule misreads: JavaScript READMEs writing
   `[[Prototype]]` and `[[Get]]s`, changelogs writing `[[#4995]](url)`, HISTORY.md writing
   `[[swift-testing-…]]-adjacent`, and a wrapped HISTORY.md line opening with `: "conflicts"` inside a
   paragraph. Oleg's two calls on that: **a wiki link is a link only when its file is there**, and is
   its own text otherwise, as a footnote reference with no definition is; and **it looks in the
   document's folder**, the name or the path written in it, with no Obsidian vault search.
   **Wiki links** (`MarkdownWikiLink`): Obsidian's order, `[[name]]`, `[[name|text]]`, `[[name#Heading]]`
   and `[[#Heading]]`, `.md` tried before the name as written; the `href` is a percent-encoded relative
   path (`:` encoded, so `Notes: May` is no scheme) and the heading becomes its GitHub anchor, so a
   click takes Slice 5's road unchanged. A link whose text is in brackets, a code span and an escape win,
   no wiki link is read inside a link's text, and a heading anchors from its text as written, as GitHub
   would. Which files exist is the app's to say (`MarkdownRenderOptions.locateFile`, default none),
   answered as the file spells it: on this disk the disk beside the document, so `[[Note]]` finds
   `note.md` on a volume that ignores case and the click lands on that row
   (`QuickViewMarkdownWikiLinks`); anywhere else the files the active pane lists in the document's
   folder (`PanelViewController.namesListed(beside:)`), which costs no request. **Definition lists**
   (`MarkdownDefinitionLists`): Pandoc's rules where PHP Markdown Extra agrees, a one-line term over
   `: ` definitions, loose per definition after a blank line, continuing lazily or at four columns; a
   `:` line never interrupts a paragraph, which keeps HISTORY.md's line prose, no `~` marker and no
   several terms over one definition. Drawn in GitHub's `dl` style. `plainText` moved from
   `MarkdownInlineParser` to `MarkdownInline` when the parser reached `type_body_length`. 20 core tests
   and 5 app tests (one a real click handed on as the file and its heading). Negative controls: without
   the `(` exclusion, without the existence check, with the disk asked for a server's document, and
   without the disk's spelling, each failed exactly its own test. **The corpus after**: with the app's
   default options 0 of 12 603 files render differently, and with a real existence check exactly 25
   do, all memory notes, every link in them resolved. **Run live** in `app.dirnex.Dirnex.live`, dark
   appearance. At pane size on this disk: the four links drawn and `[[Prototype]]`, `[[Get]]s` and the
   code span left as text; `[[#Definitions]]` scrolled in place; `[[Note|…]]` put the cursor on
   `note.md`, whose `[[index]]` came back; `[[sub/deep#Part Two|…]]` entered `sub` with the heading at
   the top; the definition list drew with its italic terms. Inside a zip at pane size and full window:
   `[[note]]` and `[[index]]` linked and moved the cursor, `[[Note|…]]` and `[[sub/deep…]]` stayed
   text as the listing says. **Not run live**: a server, which takes the zip's path through its
   listing; full screen; the light appearance.
8. **Markdown: math.** GitHub's four spellings, a TeX subset to MathML, an unknown command left as its
   text. **Landed 2026-11-14.** **Probed first**, three ways. GitHub's renderer, with synthetic
   samples and two real files served as HTML: math is off in `mode=markdown` and on in `mode=gfm`
   (docs/NOTES.md ▸ Working rhythm). A `$` opens at the start of a run of text or after ASCII
   whitespace or `(`, with no whitespace after it, and closes at the next `$` with no whitespace
   before it and no ASCII letter, digit or `_` after it, so `$5 and $10`, `word$x$` and `"$x$"` are
   text; `` $`…`$ `` has no boundary rules; a ```` ```math ```` fence is math and ```` ```Math ```` is
   code; `${a}, which is (${b})` is text (a closer before `{` closes nothing when the content opened
   with `{`); a `$` inside a later code span closes nothing; and none is read in a link's text. **The
   corpus**: 12 600 distinct `.md` files in the home folder, whose real math is a Hugging Face paper
   template, opentelemetry's `ieee_754.md`, three llama.cpp READMEs and a math-olympiad prompt, from
   which the subset was sized. And **WebKit**, construct by construct in an offscreen `WKWebView`
   (docs/NOTES.md ▸ Previews: web views): a plain `(` stretches unless told not to, `columnalign` works
   only on an `<mtd>`, a superscript prime draws tiny, `&#x2061;` gives `sin` no space, accents need
   chosen glyphs and no operator spacing, and `<math display="block">` will not scroll.
   **The spellings** (`MarkdownMath`, read in the inline pass): `$…$`, `$$…$$` inline or alone between
   lines, `` $`…`$ `` and the fence. **One departure from GitHub, on purpose**: the TeX is kept as
   written. GitHub reads Markdown's escapes first, so the paper template's `$X = \{x_1, …\}$` draws
   with no braces there, and `*` pairs into emphasis across two formulas; here, as in pandoc, VS Code
   and GitHub's own `` $`…`$ ``, the braces are drawn and emphasis never reaches inside. **The
   converter** (`TeXMath`, `TeXMathParser`, `TeXMathSymbols`, `TeXMathFont`): letters, numbers,
   operators with TeX's sign rule; scripts and primes; `\frac`, `\sqrt`, `\binom`, `\over`; Greek and
   some 350 commands by name; large operators with their limits under and over in display and beside
   inline (`movablelimits`); the named functions with TeX's thin spaces; `\left…\right`, `\middle`, the
   `\big` family; `\mathbb`, `\mathcal`, `\mathbf` and the rest as Unicode's math letters; `\text`; the
   accents; spacing; `\not`; the style and size switches; and the matrix, `cases`, `aligned`,
   `gathered` and `array` environments. An unknown command draws as its own text in GitHub's danger
   red (5.24:1 light, 4.97:1 dark), and what follows it is read as usual. A brace, `\left` or `\begin`
   that does not close, or a missing argument, fails the formula, which then draws as the text it was
   written as (a fence as its code block); nesting past 64 fails rather than exhausting the stack. A
   formula's heading anchors by its TeX, as GitHub's does (`## The $x^2$ term` → `#the-x2-term`). The
   app's half is three rules (`QuickViewMarkdownMath`): display math scrolls in its own box, an
   `aligned` pair sits close, an unknown command is red. 34 core tests and 3 app tests. Negative
   controls, each failing exactly its own test: without the code-span stop, without the template rule,
   with math allowed straight after math, with plain delimiters stretching, without a function's thin
   space, without the display box's scrolling (the page widened to 1 169 points in a 420-point window)
   and without the `aligned` padding rule (6.1 points between `a` and its `=`). **The corpus after**: 8
   of 12 600 files render differently, the six with real math and two bcrypt READMEs whose `$2a$` and
   `$2b$` GitHub also draws as math; the first pass changed 16, and the eight it should not have were
   the template and code-span rules above, both then read off GitHub. Rendering the corpus took
   14.97 s against 14.84 s before (release, warm). `ComparedDocumentPropertyTests` samples every seventh file
   of `Services`, so the new files moved its seeded edits onto a README case its loop bound did not
   allow for; the bound is now twice the changes (docs/NOTES.md ▸ Testing). **Run live** in
   `app.dirnex.Dirnex.live`, at pane size and full window in the dark appearance and at pane size in
   the light: math in a heading; inline formulas with `sin x + log n` spaced, `f′(x)`, a sign after
   `=`, the set's braces and a bold `O(n log n)`; prices and `${…}` templates left as text; `\foo` in
   red; a broken formula as its text; a `$$` block, `cases`, `aligned`, matrices with `\left|…\right|`,
   braces, limits, accents, a root and a binomial. A 20-term sum ended at the pane's edge in its own
   box and stood whole and centred at full window. **Not run live**: scrolling that box sideways,
   which the app test measures; full screen; a server or an archive, which reach the same render
   through the file's bytes.
9. **Highlighting: JSON keys, setext headings and indented code in a Markdown source, Ruby's
   `=begin`** (core). **Landed 2026-11-14.** **Probed first**: `ruby` itself for `=begin`, which counts
   only at a line's start with whitespace or the line's end after it (`  =begin` and `=beginning` are
   syntax errors, an indented `=end` or an `=endx` closes nothing, the closing line's rest is
   ignored); and GitHub's highlighter, which gives a JSON key the class of an HTML tag's name,
   comments `=begin` … `=end` whole, and draws an indented `# line` in Markdown as code.
   **JSON** (`LanguageGrammar.keysBeforeColon`): a closed string with a colon after it, across
   whitespace, is a key and takes `.typeOrTag`, since JSON spends `.keyword` on `true`, `false` and
   `null`; JSON5's bare names too. No other row can have it (`c ? "a" : "b"`, `if x == "a":`).
   **Ruby** (`LanguageGrammar.lineBlockComment`): a field for one language, which M17 called too rare
   to carry. Perl's POD is the same shape and stays out, since it opens on any `=word`. **Markdown**
   (`SyntaxMarkdownScanner`, with its line constructs moved to `+Constructs` to stay under
   `type_body_length`): an underlined paragraph is a heading on every line, its inline colors taken
   back; an indented block colors nothing, as an undecorated fence does, so a `# comment` inside one
   is no longer a heading. Between lines the scanner keeps the open paragraph, the latest list item's
   content column (one, not a stack, which errs toward missing code) and a code block's indent. The
   corpus asked for four more rules. Front matter is found by `MarkdownFrontMatter`'s rule: its lines
   color as before, but its closing `---` is no underline (1 869 files would have gained a heading).
   A GFM delimiter row makes the paragraph a table, which takes no underline. A bare `-` is an empty
   item, so a column of them is no heading. And **fences close by CommonMark's rule**, which the
   renderer already used: a closer at least as long as the opener, with no info string, fewer than
   four columns in, and no backtick in a backtick fence's info string. Without it the old any-run
   closer fell out of step with indented code: a ```` block closed on the ``` inside it, and the rest
   of the file flipped. A `markdown` fence recurses three levels and no further
   (`SyntaxMarkdownScanner.maxNesting`), since the length rule no longer bounds the depth.
   **Scored against an oracle each.** micromark (`mdast-util-from-markdown` with GFM, already in
   `dirnex-home`) over the 12 562 distinct `.md` files in the home folder, every line given what
   micromark says it is and scored before and after: indented-code lines right went from 1 551 to
   1 911 of 1 920, and headings, rules and fence lines from 278 466 to 293 276 of 293 453. No
   paragraph line became a heading. 18 lines got worse, all in three copies of zod's README, where an
   HTML comment holds a fence. Neither the scanner nor the renderer models HTML blocks, so there the
   source now agrees with the page where it used to differ. The remaining misses are micromark's own
   (after indented code it will not start a list at `2.`, which GitHub does) and lists the one column
   cannot follow. Ruby's Ripper over the 127 of 11 673 system Ruby files that hold a `=begin`: 146 of
   146 blocks, against 0 before. A JSON lexer that keeps its container stack, over 17 089 JSON files:
   5 910 096 keys, none missed and none extra, against all missed before. 22 core tests in two new
   suites (`SyntaxJSONAndRubyTests`, `SyntaxMarkdownBlockTests`), and the old JSON test asks for keys.
   Negative controls, 16 of them, each failing exactly its own tests: every rule above taken out in
   turn, plus the column-zero check, empty items withheld under any paragraph, and indented code read
   as blocks or as inline text. The first version of the last one passed, because nothing in the test
   colored inline; the test gained a `*y*` inside the code. **Cost**, release build, three runs each:
   Markdown 1.33 s to 1.37 s for the 97 MB of `.md`, JSON 2.04 s to 2.42 s for 517 MB, which is
   0.7 ms a megabyte and about 3 ms at the preview's 4 MB. The `=begin` check, run at every position
   of every language, cost JSON a further 7 % until a `Bool` went ahead of it. The key lookahead is
   the rest, and not by reading whitespace twice: resuming past it changed nothing. **Run live** in
   `app.dirnex.Dirnex.live`, full window, dark appearance, source style: a `.md` with front matter, a
   setext heading, a two-line paragraph underlined with `---`, indented code at the top level and in
   a list item, a ```` fence holding a ```swift one, and a table with `---` under it, each drawn as
   above; a `.json` with its keys teal apart from salmon strings, nested and in an object on one
   line; a `.rb` with its `=begin` block one comment and an indented `=begin` left as code. **Not run
   live**: the light appearance, a rendered page's ```` ```json ```` fence, and the compare and merge
   windows, which color through the same scanner.
10. **The theme picker** (app). Settings, the source view and the rendered fences. **Landed 2026-11-14.**
   Oleg's call on the probe: all three themes, in Settings ▸ Panels over a code sample. **Probed first**:
   Xcode's `Default (Light)` and `Default (Dark)` `.xccolortheme` files inside Xcode.app, and GitHub's
   `--color-prettylights-syntax-*` values from its own Markdown stylesheet, every value measured on the
   system text background (`#FFFFFF`, `#1E1E1E`), which every theme keeps. Two needed a decision: Xcode's
   dark comment `#6C7986` scores 3.74:1 (it fails in Xcode too) and is lightened along its hue to
   `#7C8996`, 4.66:1; GitHub's light palette gives a tag the constant's blue (`#0550AE` for both), so
   `typeOrTag` takes its `entity` purple. Xcode colors no diff: a removed line takes its string red and
   an added one the teal of `identifier.function`. VS Code stays the default, M17's table value for value
   (`SyntaxColorTheme`, `Dirnex.pref.syntaxTheme`, an unknown value reading as the default). **The
   mechanism**: `SyntaxTheme`'s colors stay one `NSColor` per kind and now resolve through the selected
   theme at draw time, since a dynamic color asks its provider on every resolution (probed, `cgColor`
   included; docs/NOTES.md ▸ Color and contrast). So nothing anywhere rebuilds a document: the shared
   preferences alone move `SyntaxTheme.current`, and `SyntaxThemeRepaint` walks every window marking each
   view for display, which reaches the source view, the JSON and XML tree, a CSV's columns and the
   compare and merge windows without listing them. A Markdown page's token colors sit in a `<style>` of
   their own, rewritten in place by a client-world script (page scripts off), so the page keeps its
   scroll; a page loaded later is generated in the new theme. The sample is three lines of Swift through
   the real grammar, its comment translated; three new strings in 14 languages. **Tests**:
   `SyntaxThemeTests` now holds every theme to 4.5:1 in both appearances, its pairs apart, its code kinds
   distinct and VS Code unchanged, and a following color to its source; `SyntaxThemeChoiceTests` (8)
   covers the preference, the sample, the page's stylesheet, a real page restyled twice in place with
   its scroll kept, the walk finding that page inside its surface, and an HTML page left alone. Negative
   controls, each failing exactly its own tests: a scratch instance moving the screen's theme, the walk
   not descending, a following color ignoring its source, and the token colors back in the main
   `<style>`. **Run live** in `app.dirnex.Dirnex.live` at pane size. Dark: the Swift source, the Markdown
   source, a rendered page scrolled to its last fence (it stayed there), the JSON tree and the CSV source
   each took the new theme the moment a segment was pressed, nothing reopened; a relaunch came back in
   the saved theme. Light: all three on the rendered page and in the sample. Two controls in the running
   app: with the text view's layout no longer invalidated it still recolored, so that code went; with the
   walk switched off it kept the old colors. One thing seen: Xcode's dark keyword (`#FC5FA3`) and string
   (`#FC6A5D`) are near hues, so a CSV's second and third columns read close there, as they do in Xcode.
   **Not run live**: the compare and merge windows, which the same walk reaches; full window and full
   screen; a 4 MB file; a translated Settings tab.
11. **Export, core.** The self-contained HTML document and the names. **Landed 2026-11-14.** Oleg's three
   calls when it opened: a link to another file stays as written, relative, as pandoc and GitHub leave
   it; a remote image keeps its URL, for the browser to fetch; and the file holds what the preview drew,
   so a server's or an archive's document carries no sibling image, since its preview draws none (now
   written down, LOCATION-SUPPORT.md <sup>aat</sup>). **Probed first.** APFS limits a name to 255
   **UTF-16 units**, not bytes (255 `é` created, 128 `😀` refused), where ext4 counts 255 bytes. A
   `<meta>` Content-Security-Policy in a `file://` page, in `WKWebView` and headless Chrome beside a
   throwaway server: scripts, an `onerror` and a `javascript:` link stopped, and `data:`, sibling and
   remote images all drew (docs/NOTES.md ▸ Previews: web views). And the corpus, 5 655 distinct `.md`
   files: 4 302 open on a level-1 heading, 18 have one only later (release changelogs), 467 a
   front-matter `title`. **`MarkdownExport`**: `fileName(forSource:as:)` drops the last extension by
   `NSString`'s rule (`.md` gives `.md.html`) and, when the name outgrows a limit, trims whole
   characters off the stem until it fits every limit the source fitted, units always and bytes when
   the source kept to them; `htmlDocument(title:stylesheet:body:)` is the file's UTF-8 bytes, charset
   first, then the policy (`script-src`, `object-src`, `base-uri` and `form-action` all `'none'`, and
   nothing on images or styles), the escaped title, the app's stylesheet and the page verbatim.
   **`MarkdownRender.title`** (`MarkdownTitle`): front matter's `title` in any case (`''` and a YAML
   block scalar name none), else the first heading when it is level 1, else, at export, the file's
   stem. The first version's corpus run found 305 titles carrying markup or a badge (`PostCSS Lab
   Function <img … align="right">`, `is-bigint <sup>Version Badge</sup>`); in the dependencies 500 of
   3 651 first headings hold an image and 247 a raw tag, against 1 each of Oleg's 511. So a title is the
   heading's words less its images and less any run CommonMark reads as a tag (§6.6's open tag, closing
   tag and comment), which GitHub draws as nothing; a code span and a formula keep every character, and
   shortcodes are drawn run by run as the heading draws them. After: 28 flagged, all real words but two
   badges whose references the file never defines, which the page draws as typed too. `MarkdownHeadings`'
   walk is one `visit` that the anchors and the title share, so they agree on the first heading. 21
   tests, 40 cases. Negative controls, each failing its own test: bytes never counted, trimming by
   scalar, any first heading, no block-scalar check, a case-sensitive key, the title unescaped or
   uncollapsed, `default-src 'none'`, an image's alt kept, no tag stripping, stripping run by run (only
   the tag that emphasis splits), a code span read as prose, shortcodes over the whole title, the walk
   skipping quotes (the anchors' test too) and comments unread; bytes always counted also failed the
   emoji and combining-mark names, which rely on it. Rendering the corpus: 7.14 s against 7.30 s.
   **For Slice 12**: the app's two `<style>`s become one string, a `max-width` for a browser window,
   the light palette for the PDF, and whether a source past the preview's 4 MB exports whole.
12. **Export, app.** The sheet, the PDF through the print path, the queued copy. **Landed 2026-11-14.**
   Oleg's three calls when it opened: **one File ▸ Export…** (`file.export`, in ⌘K and the `.sdef`, no
   key) whose sheet holds a format popup, remembered (`Dirnex.exportFormat`), above the name and the
   folder; it acts on **the cursor's Markdown file in either pane, Quick View on or off**; and it
   exports **the whole file**, up to 64 MB, where the preview reads 4 (`MarkdownExport.sourceByteLimit`,
   checked on the file's size before a byte is read). **Probed first**, a page printed headlessly
   through `WKWebView.printOperation` (docs/NOTES.md ▸ Previews: web views): pages of selectable text
   on the user's paper in under 0.1 s, the callback off the main thread; **a CSS mask is not applied
   on paper**, so an alert's icon printed as a square of its color with the black symbol over it,
   where a pre-tinted symbol printed right; backgrounds print only with `shouldPrintBackgrounds`;
   `@media print` and the margins apply; `scalingFactor` laid a page sideways across sheets. And
   **print is light by itself**: a view drawing the dark palette printed the light one, while
   `createPDF` of it came out dark, which is what the M39 probe had seen. **The page**
   (`MarkdownExportFile`) is the preview's render, so it holds what the preview drew, under one
   stylesheet (`QuickViewMarkdownStyle.exportStylesheet`): the preview's palettes and the theme's token
   colors, then `QuickViewMarkdownExportStyle`, a 980 px reading width in a browser and, for paper,
   11 pt text, wrapping code, nothing that scrolls, and each alert's symbol drawn in its light color
   (`QuickViewMarkdownAlerts.iconMask(_:tint:)`), which a browser printing the HTML file reads too.
   **The PDF** (`MarkdownExportPDF`) is that file printed in a window never shown, under the preview's
   block-remote rules (`QuickViewWebView.contentRules`), scripts off and no navigation past the page,
   with ¾-inch margins. **The flow** (`PanelViewController+Export`): a refusal before the sheet when
   the other pane cannot be written to (a browsed archive or a results listing included, since an
   export is a copy and not an add); the sheet's name follows the format
   (`MarkdownExport.renamed`), its folder is typed on the other pane's backend (`~` on this disk
   only), and a bad name or a missing or read-only folder is said under the form with the sheet still
   up; then the source is brought down through Share's funnel (`RemoteFetchPurpose.export`, on the
   open row), the page is staged under its real name in a folder of its own
   (`MarkdownExportStaging`), and **the queue copies it** with F5's `.ask` policy, conflict dialog and
   undo, into any backend F5 writes to. The staged file is kept for the session and purged at launch,
   since a redo of the copy reads it again. 16 strings in 14 languages, three of them shared with Pack
   and create-file. 4 core tests and 18 app tests in two suites
   (`MarkdownExportPageTests`, `MarkdownExportGestureTests`), the PDF's checked by its own pixels:
   more than one page, the title at the margin, under 10 % dark inside the margins, and the note's icon
   blue with no black. Negative controls, each failing exactly its own test: no print backgrounds, the
   default margins, the mask left on for paper, the preview's 4 MB read, the name not following the
   format, a file taken for a folder, `~` expanded on a server and no write check before the sheet. One
   did not fail, and that is the finding above: with the web view set dark the PDF still printed light,
   and the measure was shown able to see a dark page by printing colors set without the media query.
   **Run live** in `app.dirnex.Dirnex.live`, dark appearance, pane size: File ▸ Export… lit on
   `guide.md` and the sheet drew as designed; HTML landed in the other pane through the queue, titled
   from front matter, its image inlined and its link as written, and headless Chrome drew it at the
   reading width in both appearances; PDF landed as 4 A4 pages titled "Export check", light, both
   alert icons in their colors; a second HTML export raised F5's conflict dialog, Keep Both landed
   `guide copy.html`, Edit ▸ Undo Copy removed it and Redo Copy brought it back from the staged file;
   from inside a zip the member was extracted and exported, its image left as `pic.png` as
   LOCATION-SUPPORT.md <sup>aat</sup> says. The run cost Oleg two cloud-provider prompts before the copy
   was seeded away from Home (docs/LIVE-VERIFICATION.md). **Not run live**: a server as source or
   destination, which reach Share's funnel and F5's queue; the sheet's inline errors, which the tests
   cover and which a background run could not type into; full window and full screen; a translation.
13. **Mermaid: state diagrams.** **Landed 2026-11-15.** Oleg's three calls when it opened: a
   **self-loop is shared**, so a flowchart's `A --> A`, which had drawn nothing since M18, now loops
   too; **labels get a half-layer slot in state diagrams only**, so flowcharts stay as they were; and
   a transition into another composite's state **crosses the border** to reach it, as Mermaid draws
   it. **Probed first**, on Mermaid 12.3 drawing its own documentation page's editable examples
   (docs/NOTES.md ▸ Working rhythm), since its docs state few rules. One start and one end per region
   (`root_start`, `First_end`): the simple sample is five nodes. `s1 : a` then `s1 : b` draws "a" over
   a rule with "b" under it. A state belongs to the **last composite block that mentions it**, and the
   top level never claims it back: `x --> inner1` written before `state Outer { inner1 }` still puts
   `inner1` inside, with the line crossing in. A composite's inside runs top to bottom whatever the
   diagram's direction. Regions sit side by side, a fork bar lies across the flow, a note hangs on a
   dashed line, a label is everything after the first colon, and a repeated transition is drawn twice.
   The corpus holds one state diagram, undici's connection lifecycle (a fork, a composite with its own
   start and end, labels), now a test fixture. **The parse** (`MermaidStateDiagram`,
   `MermaidStateParser`, `MermaidStateBuilder`): both header spellings; one statement a line with no
   `;` split, which the flowchart's splitter would have turned into a state called `y` in
   `a --> b : x; y`; `state "…" as id`, `id : text`, `<<choice>>`, `<<fork>>` and `<<join>>` (or
   `[[…]]`), blocks, `--` and `direction`; notes on one line or to `end note`; `:::class` stripped;
   `classDef`, `class`, `style` and a floating note named in the caption; `accTitle` and `accDescr`
   skipped; a block that would put a state inside itself refused. **The layout**: the flowchart's
   ranking and placement moved out whole (`MermaidLayering`, `MermaidLayered`), and the state diagram
   lays each region out on its own from the inside, so a composite takes part in its parent as one box
   of its finished size. A crossing transition is ranked in the innermost region holding both ends,
   between the states there that contain them, and drawn to the real ones. Every transition crosses a
   half-layer of its own (`stride: 2`), where its dummy is sized to its label, so `A --> B : x` and
   `B --> A : y` sit side by side. **The first look, headless before any test, showed long transitions
   zig-zagging** as each layer centered its dummies on its own; so a state diagram is ordered by eight
   sweeps down and up, keeping the fewest crossings, and placed by a balancing pass that sets each
   layer as close to its neighbors as its order and gaps allow, which is isotonic regression and
   exact. A note's state lines up by its own box, not its slot. **Loops** (`MermaidSelfLoops`) leave
   the side across the flow, nest, and reserve their room on both sides so the column stays straight;
   the live run found a loop's label plate hiding the loop's outer edge, so a loop's label has none.
   Six new classes in the stylesheet, in both appearances through the existing variables. **Every
   flowchart and sequence fence on this Mac (45 fences, 24 files) renders byte for byte as before**;
   undici's fence went from its source to a drawing. 35 new core tests in four suites
   (`MermaidStateParserTests`, `MermaidStateLayoutTests`, and in the renderer and flowchart layout
   suites); the app's class sweep draws a state diagram with every construct. Negative controls, 13,
   each failing its own test: one stride, no balancing, no anchors, one ordering sweep, the top level
   claiming back (which also failed the two tests built on that rule), no cycle guard, the `;` split,
   no loop room, crossing transitions drawn to the composite, an inside following the parent's
   direction, flowcharts dropping loops, one start per diagram, and loop labels plated; the class
   sweep failed with `.mm-state-bar` removed. **Cost**, release, best of 20: undici 0.43 ms, 100 states
   9.8 ms, 300 states 66 ms against a 300-node flowchart's 9.6 ms, and 1 000 states 0.72 s, off the
   main actor; counting crossings is quadratic per layer pair, which nothing real reaches. **Run live**
   in `app.dirnex.Dirnex.live` at pane size, with the cloud probe in and seeded away from Home (no
   provider prompt, and the copy never took the front). Dark: the simple sample, a composite with
   labels, notes, three concurrent regions, loops with a crossing transition, undici, and the
   flowchart's loops. Light: the flowchart's loops after the plate fix, the loops file, and undici at
   full window. **Not run live**: full screen; the choice, fork, description, nesting, direction,
   left-to-right and `classDef` fixtures, which were checked only in headless Chrome's drawing of the
   same render with the app's metric; a server or archive location, which reach the same render
   through the file's bytes. **Left as found**: a fence opening with Mermaid front matter
   (`---` / `title:` / `---`) falls back for every type with "“---” is not drawn".
14. **Mermaid: class and ER diagrams.**
15. **Mermaid: gantt.**
16. **The slideshow timer.**

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

Everything through M38 is shipped, and the record of it — the milestone checklists, the dated
passes that landed outside a milestone of their own, and the reasoning behind every decision — is in
**[docs/HISTORY.md](docs/HISTORY.md)**, which also tells how everything else on this list came off
it (HISTORY.md ▸ the follow-on log). What is still open, rather than merely imaginable, is M39–M40
under *Next*, which take up the items in the table's *undone* column that were left by choice, plus
the list below. The column itself stays as each milestone's record.

- **The thumbnail grid, brief view and the `PaneSurface` extraction** — M15's cut, and one unit
  rather than three items, argued in HISTORY.md §M15. Any future grid inherits two constraints from
  it: skip `FileEntry.isDataless` rows, and move sort off the column header first. The list's own
  rows have drawn a picture of an image, a movie or a PDF since 2026-11-11 (View ▸ Show Icon
  Previews, HISTORY.md after §M38), and a grid would take its thumbnails from the same `RowIcon`
  rule and `RowIconLoader`.

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
| M17's highlighter grows into a parser by accretion — one heredoc, one regex literal, one interpolation at a time, each individually reasonable | The scanner's boundary is written into the milestone as a list of *decisions*, and each one carries a comment at the place in the grammar where it would have been handled. The tell that the boundary is being crossed is a grammar gaining a **state stack**: a single pass with one lookahead is the whole design, and anything needing to remember where it has been is a parser, which is a compiler's job and not a preview's. The affordable escape hatch is that highlighting only ever *adds* foreground color to a document that already renders correctly — so a construct the scanner gets wrong is a wrong color, never a wrong character, and the honest fix for a hard one is to stop coloring it. **Held through the milestone, and the escape hatch was used**: `prefix` and `postfix` came out of the Swift keyword set rather than gaining a rule, because both are contextual and `prefix` is one of the language's most common method names (HISTORY.md §M17 ▸ Slice 1). No grammar gained a state stack; the closest anything came is one `Bool` inside `SyntaxMarkupScanner.scanAttributes`, which is a lookbehind of one token and is argued at the site. **M39 Slice 9 came closer, still with no stack**: the Markdown scanner keeps three values between lines (the open paragraph, the latest list item's content column, a code block's indent), and a `markdown` fence's recursion, which the closing rule no longer bounds, is bounded by a count |
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
| M34's merge is wrong in the quiet direction: a region read as changed on one side when both sides changed it drops an edit, and nothing on screen shows what went missing. A stale base does the same | git is the oracle in two styles, `--diff3` for the regions and `--zdiff3` for the trimming, and the properties that need no git (a text merged with itself comes back, a side equal to the base yields the other, every one-sided change survives) run over random texts. No ignore option reaches a merge, the uploaded bytes replace the base after every upload, and Save is refused while a conflict is open. The tell is a merge offered without a real base, such as the server's copy standing in for one, or an ignore option reaching `ThreeWayMerge`. **Held (closed 2026-10-27).** git agreed in both styles on every corpus triple apart from 113 named ties, and the three properties ran over random texts. No ignore option reaches `ThreeWayMerge`. Merge… is offered only with a base that was the server's own bytes: taken when the edit's watch starts on a copy nothing has written, replaced by each upload's sent duplicate, forgotten with a record whose upload outcome is unknown, and never the server's copy standing in. Save is refused while a conflict is open, and no marker is written. The quiet failure the row names turned up once, in the check rather than the merge: over SFTP a same-size write in the minute of the last upload went unseen and was overwritten, and the save now compares the server's bytes with the base. **Held again through M37 (closed 2026-11-09)**, which added four more ways into the window: no ignore option reaches `ThreeWayMerge`, whose options carry only `isMinimal`, and a conflict that whitespace explains is labelled instead. A sync's base is a version both sides were found holding byte for byte, an archive member's is the member as extracted, and git's is git's own |

## 7. Open questions

**None open.** M25's was the last, and it closed on 2026-08-29. Every question this plan asked since
M0, and how each one closed, is in [docs/HISTORY.md](docs/HISTORY.md) ▸ **The questions the plan
asked**.
