# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: **M0–M41 shipped, M42 open** (14 languages; M29's licensing is on in betas, off in stable until the
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

### Shipped: M0 → M41 (2026-07-05 → 2026-11-19)

Every milestone is closed. The checklists and the full per-pass progress log — what was probed,
decided, and rejected — live in **[docs/HISTORY.md](docs/HISTORY.md)**; source comments citing
`PLAN.md §M5` and the like refer to those sections.

| | Milestone | Landed | Left deliberately undone |
|---|---|---|---|
| M0 | Scaffolding | 07-05 | — |
| M1 | Read-only dual-pane browser | 07-06 | — |
| M2 | Operation engine | 07-07 | Side-by-side text diff in the conflict dialog — **since shipped** 2026-10-22 with M31 Slice 4, as Compare Contents… for two local files whose bytes are here |
| M3 | Discoverability layer | 07-08 | SQLite stores (JSON is fine); per-workspace palette entries — **since shipped** 2026-11-18 with M40 Slice 1 |
| M4 | VFS payoff | 07-12 | libarchive C-module gate (`bsdtar` instead); search tag chip + content-grep fallback — the chip **since shipped** with M6, the fallback 2026-11-18 with M40 Slice 3, for a folder Spotlight does not index |
| M5 | Network and sync | 07-14 | — |
| M6 | Mac-native power features | 07-19 | — |
| M7 | Release readiness | 07-19 | — |
| M8 | The sidebar as a first-class surface | 07-21 | Dragging a *remote* (SFTP) folder into the sidebar — stays menu-only, **since shipped** 2026-11-10 with M38 Slice 4, for SFTP, FTP, WebDAV and S3; Recents ordered by modification date, not the true last-used stamp — **since shipped** 2026-11-18 with M40 Slice 2 |
| M9 | iCloud Drive, for real | 07-21 | Per-item download percentage (macOS exposes none through the URL resource keys); Put Back inside the iCloud trash — the origin is an opaque provider reference with no path in it |
| M10 | Google Drive and Docs | 07-22 | A real Drive API backend (OAuth + Drive v3, native Docs export/import) — dropped 2026-07-22; sync status in Drive's *mirror* mode, which macOS exposes to no one but Finder |
| M11 | F4 Edit, and Quick View at full size | 07-22 (text preview 07-27) | A built-in text editor (F4 hands the file to the user's own); write-back for archive and SFTP files — **both since shipped**, archives 2026-08-09 and SFTP with M21 Slice 10; a slideshow timer or thumbnail filmstrip in the preview — the timer **since shipped** 2026-11-15 with M39 Slice 16, the filmstrip left to M15's grid |
| M12 | Localization — 14 languages | 07-29 | The stock Finder-tag *names* in the ⌃T menu (`DirnexCore` `systemTagName` data) — **since shipped** 2026-11-19 with M40 Slice 6, as the account's own Finder favorites; the AppleScript `.sdef` *terminology*, since renaming a verb breaks users' scripts (its error messages did translate); a lint rule keeping bare literals out of UI files (the repeated sweeps stand in for it) — **since shipped** with M40 Slice 6; the "Results for Search results" stutter, a wording decision rather than a translation gap — **since shipped** with M40 Slice 6, as "Search Results"; RTL — none in the shipped set |
| M13 | FTP and FTPS | 07-25 | `MLSD` (`curl` cannot send it) — **wrong, and since shipped** 2026-10-19: `curl -X MLSD` works, and it now times every row of a server that answers it, with a per-server time zone for those that do not; FTP-side `DirectorySync` by timestamp (unreliable by construction — LIST stamps are year- and zone-less); write-back for files edited in place over FTP — **since shipped** with M21 Slice 10, which generalized the remote edit path to every backend that accepts uploads; an opportunistic "TLS optional" client mode (a password-downgrade vector — rejected 2026-07-26) |
| M14 | Checksums and attributes | 07-30 (escalation 08-02) | Split/combine files (dropped 2026-07-29 — FAT32's ceiling, floppy/CD spanning and mail limits are all gone on macOS); multi-selection and recursive **privilege escalation** (the flat single-item path proves the mechanism; those sheets refuse a root-only change by name) — **since shipped** 2026-11-18 with M40 Slice 4, one password for any number of items; escalating the *undo* of a non-owned change (still refused with `attributeRestoreNeedsAdministrator`, not escalated) — **since shipped** 2026-11-19 with M40 Slice 5 |
| M15 | The tree view, and color the user chooses | 08-02 | The **thumbnail grid, brief view and the `PaneSurface` extraction** (cut 2026-08-02 — the three are one unit, and `FileTableView` is a 25-method contract a grid satisfies none of); a memo in front of `fnmatch` (measured unnecessary — 0.46 ms per full reload for 5 rules); size bars in tree mode, withdrawn at close and re-scoped per parent directory in a follow-up (`SizeVisualization(tree:)`) |
| M16 | Quick View: source or page | 08-06 | Markdown and RTF as dual-style types — markdown was taken up at M18, RTF **since shipped** 2026-11-12 with M39 Slice 3 — and `.webarchive` / `.mhtml`, which need `loadData` rather than a file load — **since shipped** 2026-11-12 with M39 Slices 1–2, sealed in the core; the JavaScript mark in the *pane*-size preview, which had no header to carry it — **since shipped** 2026-10-14, when ⌃Q took the full-window header |
| M17 | Syntax highlighting in Quick View | 08-06 | A **theme picker** (the colors are a fixed light/dark table, no Settings surface) — **since shipped** 2026-11-14 with M39 Slice 10: VS Code, Xcode and GitHub; the constructs a regex-free single pass cannot reach — string interpolation, JS regex literals, heredocs, Swift raw strings, JSX, and semantic coloring of any kind; **line numbers, folding and a minimap**, which are editor features Dirnex hands to the user's own editor; highlighting inside the *rendered* HTML style, which is the page's own business; a **key-vs-value** distinction in JSON, and Markdown's **setext headings** and **indented code blocks**, all three of which need a lookahead or a previous line the single pass does not keep, and Ruby's `=begin` block comment — all four **since shipped** 2026-11-14 with M39 Slice 9, still with no state stack; and any third-party highlighter — Highlightr (a JS engine on every cursor step) and tree-sitter (a C dependency plus a grammar per language), both rejected 2026-08-06 |
| M18 | Quick View: Markdown as a document | 08-07 | **Raw HTML passthrough** — CommonMark says to pass it and a preview that renders on *cursor movement* must not, which is also what keeps the generated page inert; **full CommonMark conformance** (the target is what the file's author sees on GitHub for an ordinary document, pinned by a corpus of real files, with an unreadable construct rendering as its literal text); **math and LaTeX, footnotes, definition lists, emoji shortcodes and wiki links** — **since shipped** 2026-11-13 → 11-14 with M39 Slices 6–8, math as MathML; every mermaid diagram type outside **flowchart and sequence** (a class diagram, gantt, state chart or ER diagram falls back to a code fence naming itself, as does an unsupported construct *inside* a supported type) — state, class, ER and gantt **since shipped** 2026-11-15 with M39 Slices 13–15; **following a link to another file**, since turning a preview into a browser needs its own history and its own way out — **since shipped** 2026-11-13 with M39 Slices 4–5, by moving the pane, whose Back is the way out; **RTF**, the other type M16 left in the same sentence — `NSAttributedString`'s job, sharing nothing with a renderer — **since shipped** 2026-11-12 with M39 Slice 3; **rendering as you type** and editing of any kind (§M11's call, unchanged); and **exporting the rendered page** to HTML or PDF, which is a file operation and belongs in the operation engine with a destination and a conflict policy — **since shipped** 2026-11-14 with M39 Slices 11–12, through F5's queue |
| M19 | Encryption | 08-09 | **`zipcrypt` and AES-128** (the first is broken, the second buys nothing on hardware AES — both taken at open); **encryption for any container but zip**, since libarchive's 7-Zip writer refuses it and tar has no notion of it; **a passphrase for the paths that are not F5** — preview and *nested*-archive entry failed with `passphraseRequired` rather than prompting, and the encrypted route extracted the whole archive rather than the requested members, so a member filter plus a per-archive passphrase held for the session was its own slice (the passphrase half **landed 2026-08-09**, user-reported — see HISTORY.md ▸ After M19; the **member filter landed 2026-08-25**, closing the milestone: `ArchiveMemberFilter` skips what nobody asked for, and one member of a 600 MB archive costs 0.001 s against 1.53 s); **encrypting in place**, or any gesture that removes the plaintext afterwards, because that delete belongs to the user with the Trash's own rules in view; and **vault paths in anything the user saved on purpose** — a named workspace or a favorite pointing inside a vault is kept, since §6's rule is about what Dirnex remembers *without being asked* (the derived-data clause itself was closed 08-09 by fixing the frecency index and session restore, not by stating the leak — see HISTORY.md §M19 ▸ Follow-up) |
| M20 | Every place reachable without the sidebar | 08-12 | Individual places as ⌘K palette results (the palette is a registry of *commands*, places are live data — a different mechanism, worth its own decision) — **since shipped** 2026-11-18 with M40 Slice 1, as rows of the one list, the way user scripts already were; reordering or editing places from the menu, which stays the sidebar's job; a Finder-style "Computer" or "Network" destination, which is not a place Dirnex has; and a **Help menu** — Slice 2 claimed Help ▸ Search made "Trash" findable and the app declares no Help menu at all, so adding one is its own decision and was not taken |
| M21 | Amazon S3, and the mounts we already reach | 08-19 | **Atomicity of any kind** — a prefix rename or delete is N copies and N deletes, so stopping partway leaves items under both names, and no layer can make it otherwise; **a byte counter during a server-side copy**, which would cost a round trip per object (~25 min of pure latency on a 50 000-file prefix), so those jobs report items; **`copyMetadata` and `DirectorySync` by timestamp**, since S3 has no settable mtime, no permissions and no symlinks; **a File Provider mount** (Mountain Duck / `rclone mount` territory — a different product with a different lifecycle); **AES-style client-side encryption, versioning, lifecycle rules and storage-class changes**, none of which a file manager's ten verbs have a place for; and **the 200-committed multipart refusal seen from Amazon**, which AWS documents and answers `412` with the code in practice, so it stays pinned against our own SigV4-verifying endpoint |
| M22 | Find Files on a connected server | 08-16 | **Content-grep and tags remotely** — no remote backend can answer either without reading every file, so `SearchFields` withholds them rather than skipping the clause (which would return *more* results under the same name); **an exact remote timestamp**, since FTP's `LIST` stamps are year- and zone-less on the server's clock — **since shipped** over FTP for servers that answer `MLSD` (2026-10-19); **searching an S3 *account* pane**, whose rows are buckets — "search every bucket" is a different and much more expensive question than the one ⌥F7 asks — **since shipped** 2026-11-10 with M38 Slice 5, each bucket up to a bound stated before the search; and GNU `find -printf`, retired at the probe rather than handled, since choosing it would have shipped the common case unverified — POSIX `find … -exec ls -ldn {} +` instead, at the cost of the date column |
| M23 | Copy, paste and drag, wherever the file is | 08-26 | Dragging a *folder* out of a server as a promise (a promise is one file; a recursive fetch behind a Finder drop has no progress surface and no way to stop it) and dragging an archive **member** out to another app, for the same reason one layer along — an encrypted archive would have to raise a passphrase sheet behind somebody else's drop, and `extractArchiveSources` reports failures with an alert rather than through a completion handler, so it would need Slice 4's always-answers contract first (taken by the user 2026-08-26, F5 copy-out being the route); `⌥⌘V` move-paste into an archive, which stays gated where it was; a *drop* into a browsed archive, where ⌘V adds by repacking and a drag does not; and the pasteboard as an automation surface — nothing here is scriptable that F5 was not. **Left for a human**, since a drag *session* cannot be synthesized: an actual drag between two panes and a Finder drag onto a connected server. A drag from a server into Finder **ran live 2026-10-24**, where a marked set dropped nothing until it was fixed (HISTORY.md §M32) |
| M24 | Every local-only feature, on a file that is not local | 08-28 | **Content-grep and tag search on a server**, withheld at M22 for the reason that has not changed — no remote backend can answer either without reading every file; **ACLs and extended attributes remotely**, which SFTP and FTP do not carry at all; **Open in Terminal for an SFTP account**, which is an `ssh` session and a different feature — **since shipped** 2026-11-10 with M38 Slice 3; and a **folder that is not already here**, refused by every one of the seven hand-offs — a folder is an unknown number of objects in an unknown number of requests, and copying a tree out is F5's job |
| M25 | What a remote write carries, and what a remote delete costs | 08-29 | **A Trash the protocols do not have** — taken at §7 on 08-29, and the one part of the milestone that closed by not being built; **owner and group in a remote Get Info**, because `chown`/`chgrp` take a numeric id while `sftp`'s own `ls -la` prints names, so a panel built on a listing has nothing to send — **since shipped** 2026-11-10 with M38 Slices 1–2, by name over the exec channel; **comparing by timestamp on FTP and S3**, refused by construction and always will be — `LIST` is year-less and zone-less, and an S3 `LastModified` is when the object was *written*; and ACLs and xattrs again, which is a limit rather than a gap |
| M26 | Move to Trash, wherever the file lives | 08-31 | **The remote backends**, which have no Trash at all and are already degraded to a confirmed permanent delete (§M5, and M25 §7's decision not to invent one); **chasing the refusal further into TCC and `fileproviderd`**, which is not observable from here past the three candidates already eliminated — the fix does not depend on knowing which policy denies; and **Put Back for an item *Finder* deleted out of a provider domain**, or for anything trashed before the store shipped, both of which keep the honest answer the restore flow already gives by name. A **third** origin source landed 2026-09-20 — a network share's own `#recycle`, where the bin mirrors the original path so there is no record to be missing (HISTORY.md ▸ the follow-on log) |
| M27 | Legacy code-page archive names | 09-09 | **Inferring** the code page — no reader can, and a wrong guess is a plausible name for the wrong file, so it is a chooser over a preview and never a detector; **preserving an un-representable name byte-for-byte**, the rejected streaming rewrite, which keeps bytes nobody can read and still cannot extract that row *out* of the archive; and **persisting the declaration** across sessions, since it is a guess the user made about one archive and a wrong one silently outliving the session is worse than being asked again |
| M28 | iCloud Photos, as folders of originals | 09-13 | **Import, delete and album edits**, each a write Photos mediates with its own confirmation; **smart albums** — one a person made is returned by no PhotoKit fetch, and the system ones are views over the library rather than places; **shared albums, the Shared Library and hidden photos**, left out as Photos' own Library view leaves them out; **a per-asset time zone**, which PhotoKit does not expose, so months are cut in the Mac's; **⌘L inside the library**, which has no real directory to start from; and **Photos' lowercase `.mov`** for a Live Photo's movie, since a row's name is part of its path. **Exercised later that evening**: the download of an original that is only in iCloud, on clips recorded for it — the bar sat at zero and Stop was ignored until the request carried a progress handler (HISTORY.md §M28); after that fix a 219 MB copy arrived byte-identical and Stop on a 276 MB one stored nothing |
| M29 | A license, and the reminder it removes | 10-01 | **Revoking a refunded key inside the app** (the server marks it; an in-app list waits until refunds are actually abused) — **since shipped** 2026-11-19 with M40 Slice 7, as a list compiled into the core, starting empty; **trials that stop working, and activation limits**; **any copy protection beyond the signature**, since the source is open and the reminder is a request, not a lock; and **the Keychain** for the key, which is signed rather than secret. **Seen only in tests or a Debug build**: the Renew reminder on a release build, the prominent Renew… in Settings ▸ License, a pasted production key, and the 13:00 rule |
| M30 | Report a Bug, and a Help menu to hold it | 10-07 | **Anything the user didn't type or tick** in a report: no logs, no screenshots, no file names or paths, one crash report at most; **the website** naming Help ▸ Report a Bug…, until a stable release has it (the private repo's C8). **Seen only in tests**: Email Instead's draft, since this Mac's Mail has no account |
| M31 | A compare window of our own | 10-22 | **Editing, copying a block across and saving**, a later milestone's decision — **since shipped** as M33, for whole lines; **a three-way merge** — **since shipped** as M34; **a file over 64 MiB** in the window, refused by name and left to the external tools; **a binary comparison**. **Seen only through a probe**: a Mac with no external diff tool. **Not run live**: an external tool from the conflict dialog, FTP and S3 pairs, and Escape |
| M32 | WebDAV | 10-24 | **Depth infinity**; **locks of our own**, which M38's probe found add nothing worth holding one; **NTLM, Negotiate and OAuth**, NTLM and Negotiate **since shipped** 2026-11-10 with M38 Slice 6; **setting a time on Apache**, which has no way to take one (Nextcloud's `X-OC-Mtime` is used where it is answered); **Apache's offset PUT** as a segmented upload; **quota**, **since shipped** 2026-11-10 with M38 Slice 7 where the server reports one; **CalDAV, CardDAV, versioning and WebDAV ACLs**; **a Trash**, which the protocol does not have, so a NAS's `#recycle` softens the delete sheet instead. **All run live 2026-10-24**, on the NAS and a throwaway Apache, which found and fixed three bugs: ⌥F5 with a server folder in the set, Put Back into a folder deleted since, and dragging a marked set out (HISTORY.md §M32) |
| M33 | Copy a change across, and save | 10-26 | **Typing in a pane** and **find and replace**, M11's call; **copying every change at once**, which is F5; **a save that changes the encoding or the line endings**, since a save keeps both; **editing in the conflict dialog's window**, whose right-hand file waits on that dialog. **Not run live**: FTP and S3 sides, a Synchronize row compared again after a save, a side with nowhere to save, and an editor's unsaved edit met by a save |
| M34 | A three-way merge | 10-27 | **Synchronize as an entry point**, until a sync keeps a record of the last one; **three files picked by hand**, whose base would be a guess; **an archive member** changed behind an edit; **being git's merge tool**, which needs a command-line entry point; **conflict markers** in any form; **a merge that ignores whitespace**; **a binary file**. **Not run live**: FTP in the app, a batch's question, a file past the content check's limit, the take keys and the light appearance. Over SFTP and FTP a write between the check and the upload goes unseen, since that upload carries no condition |
| M35 | An SMB server's shares, as a pane | 11-05 | **Anything that writes to the list**: creating, renaming or deleting a share, or copying onto it; **a comment column** — **since shipped** 2026-11-19 with M40 Slice 8, as the comment after the share's name; **a way up from a share Finder mounted**, which keeps `..` → `/Volumes` — **since shipped** with M40 Slice 8, to that server's share list. **Not run live**: the plain permission sentence, since no share is listed to `dirnex-test` and refused; ⌘Return into the other pane; a saved sidebar row; `..` from a share typed into the sheet while its server is not connected; and marks inside a share after a relaunch |
| M36 | Drag and paste, where M23 stopped | 11-08 | **A folder for Teams, Chrome and the rest of Chromium**, which refuse a promise — **since shipped** the same day as a zip of the folder for every app but Finder, after Gmail answered "Attachment failed" for a folder, and **since 2026-11-09 as the folder itself, with the zip for an app the pointer enters with ⇧ held**, after VLC was handed a zip of a whole season (HISTORY.md, after §M36); **a folder inside an archive**, which probe P1 answers for too, leaving the extraction of a subtree behind the promise; **a folder dragged with files** losing its promise once the pointer has been over another app, the board's rewrite to file URLs being one way. **Not run live**: Edit ▸ Move Items Here being enabled, F5 from a server into an archive, an archive member into a Chromium app, and a server folder crossing another app on its way to Finder |
| M37 | Compare and merge, past M31 and M34 | 11-09 | **Aligning a byte comparison across insertions**, which needs gaps in the rows and a size limit, and has no oracle; **whitespace in a merge's regions**, labelled and offered as a take instead, so no edit goes missing in silence; **a sync's record with a side on a server**, **since shipped** 2026-11-11 with M38 Slices 8–9, keeping only what each sync copied; Go to Offset, copying bytes and Swap Sides in the byte view |
| M38 | Remote: what M8, M22, M24, M25 and M32 left | 11-11 | **WebDAV locks of our own**, since a lock around the save cannot see a write made before it, and one held from the download on would lock everyone else out while an editor is open; **OAuth for WebDAV**, which needs a sign-in flow and a token store; **a faster Find Files walk in Photos**, which saves about 1 ms a month while a name costs 2.0 ms an asset; **a quota over SFTP**, which the protocol does not carry. **Not run live**: real AWS, IIS, a Windows domain and a hosted Nextcloud; root over GNU coreutils; a password pin reconnecting through the Keychain itself; and the NAS for Open in Terminal, whose accounts may not run a command |
| M39 | Quick View | 11-15 | **A thumbnail filmstrip**, a second file list, which is M15's grid under *Still open*; **a second style for `.rtfd` and `.odt`**, neither of which is text; **a history of the preview's own**, since a followed link moves the pane and its Back is the way back; **anything Mermaid reads as config** — front matter's `config`, the today marker's style, `classDef`, `style` and `click` are skipped or named in the caption; **an Obsidian vault search** for a wiki link, which looks only in the document's folder; **a sibling image in an export** of a server's or an archive's document, since the export holds what the preview drew. **Not run live**: full screen, apart from following a link and the slideshow; the light appearance for several slices; a server as the location for most, which reach the same render through the file's bytes; a web link opening the browser; an export to or from a server; the compare and merge windows under a new theme; and a translation |
| M40 | Everything else | 11-19 | **Text inside a PDF or a Word file** where Spotlight does not index, since the walk reads plain text only, and **"Everywhere"**, which stays Spotlight's index; **a revocation list fetched from a server**, since Dirnex never asks one whether a license is real; **a Created date in an escalated step**, which no stock tool sets; **joining items that take the same command into one call**, not needed at 3 ms an item; **Size and Date on a share's row**, which the share list does not carry. **Not handled**: a share the mount spells in another case, and a source whose account was dropped for length. **Not run live**: a place inside a vault in ⌘K's recents and the ⌘-click; Recents over the whole index; a system-immutable item, an ACL carried to root and a cancel on a second body's dialog; a `dirnex://` license link and a production key; a guest mount, a share with a space and a folder mounted inside a share; and every translation but German |
| M41 | Copy and move dialogs | 11-17 | **Drag and drop and ⌘V**, which keep the queue bar alone, since the gesture names the destination and Finder does not ask; **F5 into or out of an archive**, which adds or extracts by its own route; **a count of the jobs ahead**, since a snapshot does not say which disks a job shares; **an undo record for a folder an error dialog's Abort leaves**, which nothing promises. **Not run live**: ⇧F5, ⇧F6 and a Copy rebound to a chord, all pinned by tests; a server at either end; a keeping-folders transfer across tree levels; the queue bar's Pause while the dialog is up; the error dialog on the progress sheet; the light appearance; and a translation |

### Next

**M42 is open.** M36–M41 are archived in [docs/HISTORY.md](docs/HISTORY.md), and so is the
2026-11-24 pass over what the update to macOS 27.2 broke.

#### M42 — Video and audio in Quick View (L)

Asked 2026-11-19 (Oleg): Quick View for MKV, MP4 "and maybe the other video files". His samples, one
file per container, are in `~/swtest/video`. A real film, `~/Movies/Treasure Planet.2002.BDRip.1080.mkv`
(10.5 GB), is the other fixture.

**Today** no backend claims a movie or a sound, so both fall through to `QLPreviewView`. Quick View has
to swallow the mouse over that out-of-process view (docs/NOTES.md ▸ AppKit, "winning the hit test"), so
a movie's controls cannot be clicked, and no key reaches it.

**Probed 2026-11-19** (P0, a scratch tool over the samples):

- **AVFoundation opens and decodes a frame from** MP4, MOV and M4V (H.264, AAC), 3GP (MPEG-4 Part 2),
  MPG, MPEG and VOB (MPEG-1 and MPEG-2 video, MP2 audio), TS and MTS (H.264).
- **It refuses** MKV (VP8 and AAC), WebM (VP8 and Vorbis), AVI (H.264), ASF and WMV, OGV (Theora and
  Vorbis), RM, and the bare `.hevc` and `.mjpeg` streams. Matroska, WebM and WMV are not
  among the 104 `AVURLAsset.audiovisualTypes()`. `public.avi` is, and the H.264 AVI is refused anyway,
  so the type list does not decide what plays. Opening the file does.
- **Decoders on this Mac**: video H.264, HEVC, VP9, AV1, MPEG-1, MPEG-2, MPEG-4 Part 2, JPEG and ProRes;
  audio AAC, MP1 to MP3, AC-3, E-AC-3, FLAC, Opus, Vorbis, ALAC and PCM. **None for VP8, Theora, VC-1 or
  WMV3, or DTS.** VP9 and AV1 report hardware decoding here; other Macs still to check.
- **The film holds H.264, 5 AC-3 tracks, 4 DTS tracks and 3 SRT subtitle tracks.** Everything but the
  DTS tracks is in reach of the system's decoders. Oleg's MKV and WebM samples are VP8, which is not.

**Decided 2026-11-19 (Oleg):** **⌘P** plays and pauses. **Audio files take the same player.**

**Proposed with them, held when Slice 1 landed:**

- **Nothing plays on its own.** Stepping to another file, or closing Quick View, stops the player.
  *Reversed 2026-11-21 (Oleg):* a movie or a sound now plays once it is up, behind a setting that is
  on by default (▸ Autoplay, below). The stop on the way off a file stands.
- **The ⇧-keys move along the timeline the way they move down a document**: ⇧↑ / ⇧↓ 10 s, ⇧Page Up /
  ⇧Page Down a minute, ⇧← / ⇧→ the start and the end. They stay in the file table, so the cursor can
  walk on (`QuickViewScroll`).
- **A cloud placeholder is not opened**, since opening it downloads it. It keeps Quick Look's icon.
- **What AVFoundation refuses goes to Quick Look as today**, until the slice that reads it.

#### Slices

1. **The player** (core, then app). Core: the timeline rule for the ⇧-keys beside `QuickViewScroll`'s
   distances, and the Play/Pause command with ⌘P. App: an in-process `AVPlayerView` backend for any
   type conforming to `public.audiovisual-content` that AVFoundation opens. It takes the mouse, so it
   joins the hit-test exemptions. It routes after the TypeScript sniff (`isMistypedSource`), so a `.ts`
   that is a transport stream reaches the player and one that is TypeScript still reaches the text.
   Anything refused falls back to Quick Look. **Landed 2026-11-19**, and the four proposals above held.
   Core: `QuickViewScroll.timelineTarget` (10 s, a minute, the two ends, clamped, with an unknown length
   holding only the start) and `view.quickViewPlayPause` on ⌘P, with View ▸ Play/Pause in 14 languages.
   App: `QuickViewMediaView` and `QuickViewPreviewView+Media`. `show` stands the player down for every
   other file, so no backend has to remember it, and `clear()` stops it, which covers closing the mode,
   Tab and a change of size. The player joined `ContentTarget`, so the ⇧-keys reach it and zoom answers
   it as nothing to zoom. Nine app tests and six core ones. Negative controls: without the clamp three
   core tests fail, and without the player in the hit-test exemptions the mouse test fails. Live in
   `build/live-copy`, the pane preview: the MP4 opened paused on its first frame, ⌘P from the View menu
   played the silent MTS (frames changed over 3 s) and paused it (frames held), ⇧→ and ⇧← went to the
   last and first frames with the cursor on its row, and the MKV fell back to Quick Look's icon. Two
   things found:
   - **An `AVPlayerItem` has no duration until it is ready to play**, so a ⇧→ pressed before then stays
     put by the timeline rule. Alone the item was ready before the test's key, and in a full run it was
     not; the test now waits for `.readyToPlay`. A person cannot press the key that fast.
   - **AVKit's inline controls fade out while the pointer is away from the player**, so in a
     keyboard-only session nothing on screen says where in the file the player is, or whether it is
     playing. Slice 2's header is where that belongs.

   **Not run live**: the full-window and full-screen sizes, a sound, the light appearance, a translation,
   a cloud placeholder, and a movie on a server.
2. **What the file holds.** Length, picture size and codecs in the header, and where the player is
   and whether it is playing, since AVKit's controls fade with the pointer away. A card in place of Quick
   Look's icon for a file nothing here can play, naming the container, and the codecs where they are
   known. **Landed 2026-11-20.** Core: `MediaContainer`, read from a file's first 4 KiB (Matroska and
   WebM by the EBML `DocType`, AVI, ASF, Ogg, RealMedia, FLV, MPEG-4 and QuickTime) and named by
   extension for the containers macOS may leave untyped; `MediaCodecName` (Core Media's four-character
   codes, an unknown one shown as itself); `MediaSummary.facts` ("2560×1440 · H.264 · AAC", a codec once
   however many tracks carry it); and `MediaTimecode`, whose clock takes its shape from the length so it
   keeps its width past the hour. App: "▶ 0:42 / 1:35:20" at the header's leading edge, a button that
   plays and pauses as ⌘P does, and the facts before the position. Short of room the facts give way
   first, then the name, and the clock and the position not at all; the facts stay whole in a tooltip.
   ⌘P and the ⇧-keys bring a faded full-screen header back. `QuickViewMediaCard` takes Quick Look's place
   for a refused file: its icon, its name, the container and "Dirnex can’t play this file." (14
   languages). The surface swallows the mouse over the card as over the remote placeholder, since only
   the player itself is exempt. Twelve core tests, over the captured first bytes of all the samples and
   the film, and twelve app tests, with Slice 1's refusal test rewritten for the card. Negative controls:
   without the time observer the seek never reached the header, without the extension rule an untyped
   `.mk3d` went through the text sniff, with the whole media view exempt the card took the mouse, and
   with the facts' priority raised the position was pushed off its edge. Live in `build/live-copy`, the
   pane preview: the MP4 read "⏸ 0:00 / 0:53" and "2560×1440 · H.264 · AAC"; View ▸ Play/Pause on the
   silent MTS ran the clock from 0:01 to 0:10, a click on it paused at 0:19 and held, and ⇧→ read
   "0:53 / 0:53" with the cursor on its row; the Matroska sample, the film, the WebM and the AVI each got
   the card naming their container; the voice clip read "0:00 / 0:04" and "AAC"; and full window drew the
   same header. Found:
   - **AVFoundation reports nothing about a file it refuses**, not its tracks either, so the card's
     codecs come from AVFoundation only for a file it opens and still will not play (pinned on the
     card's line, since no system encoder writes such a file). Matroska's and WebM's reach the card
     with Slice 3's reader. AVI, Ogg and ASF headers are flat enough to read for theirs if wanted.
   - **`org.matroska.mkv` is VLC's type, not macOS's**, so on a Mac without VLC a `.mkv` conformed to
     nothing and would have gone to Quick Look. The containers AVFoundation refuses now route by name
     too. `.spx`, Speex in Ogg, is left off that list: macOS types it as a System Profiler report.
   - **A full app run let a one-second clip play out before the test's poll saw "playing"**, since
     AVFoundation tells its time observer of a start only once playback has begun. ⌘P tells the readout
     itself, and the test plays a minute-long clip.

   **Not run live**: full screen (the floating header's return on ⌘P), the light appearance, a
   translation, a narrow pane with a long name (pinned by a layout test), and a file AVFoundation opens
   and will not play.
3. **Matroska and WebM, read** (core). An EBML reader in `DirnexCore`: the segment's info, its tracks
   (codec, codec private data, language, default flag), its cues, and its clusters as an index of
   samples. Tested against generated files and against headers captured from real ones. **Landed
   2026-11-20.** Probed first over this Mac's corpus: the film, the samples, three TV seasons from
   mkvmerge 6.8, 57 and 88, and 23 WebMs from libwebm and Lavf. Core: `RandomAccessByteSource`
   (`pread`, so readers share a file), `EBMLReader` (a 16–64 KiB window over it), `MatroskaFile`,
   `MatroskaTrack`, `MatroskaCuePoint` and `MatroskaCluster`. Opening reads the head alone, the EBML
   header to the first cluster plus what the `SeekHead` names, and notes where the cues are: under a
   millisecond for the film, whose cues `cues()` then reads in 1 ms. `cluster(from:)` indexes one
   cluster's blocks (track, time, key, duration, each frame's byte range after Xiph, EBML or fixed
   lacing), steps over what lies between clusters, and ends a cluster of unknown size where the next
   begins; `frame(_:of:)` reads a frame, putting header-stripped bytes back, and refuses a zlib or
   encrypted track by name. Walking all 6 902 of the film's clusters took 10.4 s, I/O-bound, and found
   the same 6 902 its own second `SeekHead` lists. `MediaSummary(matroska:)` and
   `MediaCodecName.name(matroskaCodecID:)` give the card what AVFoundation would not: the film's card now
   reads "Matroska · 1816×1080 · H.264 · AC-3, DTS" (one app test). 47 core tests, six of them over
   sparse captures of real files (NOTES.md ▸ Testing ▸ Fixtures), with expected numbers from a separate
   Python walk and every laced AC-3 and DTS frame landing on its codec's sync word. Negative controls,
   each failing its tests: an EBML lace bias off by one, fixed lacing read as Xiph, a second `SeekHead`
   always followed (every film test failed at the open, the capture not holding it), an absent
   `Language` read as `und`, cue positions not counted from the segment, an empty
   `ContentCompression` read as none, and a `SeekHead` pointing at bytes that are no `SeekHead` refusing
   the file rather than being passed over. Found:
   - **Muxers leave out every element at its default**, so absent means the default: mkvmerge drops
     `Language` for English tracks and libwebm writes none, and mkvmerge 6.8's PGS subtitles are zlib
     through an empty `ContentCompression` (NOTES.md ▸ AppKit ▸ Previews).
   - **mkvmerge 3.4 gave the film's DTS tracks no default duration**, so a laced DTS frame after the
     first has no time the container states (`frameTime` answers `nil`); its codec will have to say.
   - **Cues after the clusters that no `SeekHead` names are not looked for.** Every muxer seen names
     them; finding them otherwise would mean stepping over every cluster at the open.

   Live in `build/live-copy`, the pane preview: the film's card read "Matroska · 1816×1080 · H.264 ·
   AC-3, DTS", the WebM sample's "WebM · 2560×1440 · VP8 · Vorbis" and Prism's MKV "Matroska · 2560×1440
   · VP8 · AAC". The copy, seeded at `~/Movies`, raised a Media & Apple Music prompt at launch, before
   Quick View opened (docs/LIVE-VERIFICATION.md).

   **Not met in a real file on this Mac**, so held by generated ones only: Xiph and EBML lacing, header
   stripping, and the segment and clusters of unknown size a live recording writes. **Not run live**: a
   Steam WebM (VP9 and Opus) on the card, a translation, and a file on a server.
4. **Matroska and WebM, played.** Opens with probe P1, which decides between two routes. One is a
   MediaExtension format reader (macOS 15 and later, out of process, `AVPlayerView` unchanged). The
   other is sample-buffer rendering, which works from macOS 14 (`AVSampleBufferDisplayLayer`,
   `AVSampleBufferAudioRenderer`, a render synchronizer). Either way it plays the codecs listed above,
   picks the first audio track the system can decode, and names the rest. **Landed 2026-11-20.**
   **P1 chose sample buffers** (Oleg, 2026-11-20). A format reader needs a restricted entitlement *with
   a provisioning profile*, which the Developer ID, CI and ad-hoc builds lack, a switch each user turns
   on in System Settings, and once installed it serves every app on the Mac. The other route already
   played every codec in this Mac's corpus that the system decodes (H.264, VP9, AC-3, E-AC-3, Opus,
   Vorbis), and **a slim timeline of our own** stands in for AVKit's control bar (Oleg's pick).
   Core: `MediaSampleFormat` (a track's codec, sizes and configuration as the system takes them, with
   AAC's and FLAC's cookies laid out as the system encoders' own and VP9's `vpcC` made from the first
   key frame by `VP9FrameHeader`), `MediaFrameCounter` (Opus's table of contents, Vorbis's modes),
   `MatroskaDemuxer` (each track's packets in its own order, a cluster at a time, with seeking by the
   cues or, with none, by walking, pictures before the target as preroll and sound before it dropped)
   and `MatroskaPlaybackPlan` (the first picture this Mac decodes, the default sound if it decodes or
   else the first that does, and a file whose picture nothing decodes refused). App:
   `MediaSampleBridge` (format descriptions, sample buffers, and whether a decoder answers),
   `MatroskaPlayer` and its queue-confined `MatroskaFeed`, `QuickViewMatroskaView` (the picture's layer
   and the timeline, which joins the hit-test exemptions), and `QuickViewMediaView+Matroska`, whose
   header tooltip names every sound: "▶ Russian · AC-3 · 5.1", and "English · DTS · 5.1 — can’t play"
   (14 languages, with "Timeline"). A file AVFoundation refuses goes to the Matroska player when the
   core reads it and something in it decodes, and to Slice 2's card otherwise. 30 core tests, over the
   film's, libwebm's and Prism's captures and generated files; 12 app tests, over Matroska files
   remuxed from the system encoders' own H.264, AAC and Opus, with a 0.5 tone decoded back to 0.5.
   Negative controls: without preroll, without waiting for a key frame after a seek, with Opus's two-
   frame codes read as one, Vorbis's window bit one along, AAC's cookie given an `esds` header, VP9's
   profile 1 read as 4:2:0, and no codec step for an unlaced frame, the core tests aimed at each went
   red. Without the timeline's exemption, the route to the player, or the stop of it, so did the app
   ones. AAC's cookie as the bare `AudioSpecificConfig` passed: AudioToolbox decodes both, so the
   layout is held by the byte test. Live in `build/live-copy`, the pane preview, muted with the sound
   renderer's status logged: the film opened on its first frame reading "0:00:00 / 1:35:23" and
   "1816×1080 · H.264 · AC-3, DTS"; ⌘P played it past the Disney logo on its default AC-3 track
   (`.rendering`, no error); a click on the header paused it at 0:00:24; ⇧→ showed its last frame at
   1:35:23 with the knob at the end; and a click halfway along the timeline drew 0:47:44. The GOT
   episode read "1:01:37 · 1920×1080 · H.264 · AC-3", the VP8 WebM got the card, and Steam's VP9 and
   Opus clip played to its end and stopped there, then ⌘P played it from the start. Full window drew
   the same header and timeline. Found:
   - **A stated length and the end of the data differ by a packet**, and the player waited for its
     clock, held at the stated 4.008 s, to pass the 4.021 s where the clip's last Opus packet ends: live,
     the clip "played" forever. It stops at whichever comes first now, with a test that failed first.
   - **An undecodable picture does not fail the renderer** (VP8's frames count as corrupted, and the
     status stays `.rendering`), so decodability is asked before anything is enqueued (docs/NOTES.md ▸
     AppKit ▸ Previews).
   - **Oleg's Silo episodes are user-immutable**, so no hard link reaches them, and E-AC-3 was not run
     live in the app; P1 rendered it through the same bridge, and decoded it to 6.04 s of sound.

   **Not run live**: sound heard (the run was muted; the renderer's status stood in), full screen, a
   real mouse drag on the timeline (a background click is an accessibility write), the sound tooltip
   (pinned by a test), the light appearance, a translation, Vorbis or AAC with sound in a real file
   (both samples are silent), a file on a server, and a VP9 or AV1 decoder on another Mac.

   **Fixed 2026-11-20 (Oleg): a movie widened its pane, and the pane stayed wide.** AVKit's inline
   control bar asks for 750 pt at priority 499, above the panes' 250, so the pinned player pushed the
   pane out to 762 pt, which was 455 / 762 where the split had been 608.5 / 608.5. Hidden views keep
   their constraints, so the player held the pane under the card and after Quick View closed, and the
   card's own preferred 280 pt held it at 312. No divider move could narrow it. `QuickViewMediaView`
   now lays its player, Matroska view and card out by frame, so nothing inside them reaches the pane
   (docs/NOTES.md ▸ Views, layout and hit testing). Three app tests in `QuickViewMediaWidthTests`, over
   two real panes in the app's split, with a stand-in for the bar since the test host never builds it.
   Negative control: without the fix all three fail (740 and 312). Live in `build/live-copy`, with a
   temporary probe logging the split: before the fix, opening the MP4 gave 455 / 762, and a move to 608
   left it there with the player up, with the card up and with Quick View closed. After it, the split
   held at 608.5 / 608.5 with AVKit's real bar built, and moved to 900 and back in all three states. At
   317 pt the bar fitted itself and clipped nothing.

   **Fixed the same day: the header held a narrow pane at 405 pt.** A rendered page's "1 Source · 2
   Page (no JavaScript)" resisted at 750 beside a centered name, and the header kept its last caption
   after Quick View closed, so a pane under 405 pt was pushed out to it and stayed there. Every piece
   of the header that can give way is now below the panes' 250 (`QuickViewHeaderPriority`), in this
   order: the mark or a movie's facts, then the name, then the styles. The readout and the position
   stay above 250. A header first opened with the cursor on `..` drew its style buttons with AppKit's
   title "Button" and now starts empty. Six app tests in `QuickViewHeaderWidthTests`, over the two-pane
   split now shared with the movie's (`QuickViewPaneSplit`). Before the fix the four that pin it failed
   (405, the mark whole and the name at 0, the placeholder strip), and the squeeze at 250.5, added
   after, fails with the styles at 251 (232 pt). Found on the way: a higher priority always wins
   whatever the amounts, so a first try at 470 and 490 moved nothing (docs/NOTES.md ▸ Views, layout and
   hit testing). Live in `build/live-copy` with the split probe: a rendered page left a 317 pt pane at
   317, reading "1 Source · 2 Page index.html ⊗ 1 of 1" with the mark gone; at 267 pt the name gave way
   to "…" and the styles stayed whole; with Quick View closed the pane went to 608.5, 267 and 517 pt.
5. **AVI.** Left to decide after Slice 4, and **decided 2026-11-20 (Oleg).** **Landed 2026-11-20.**
   Probed first over the AVI sample (Lavf, x264 core 164 with three B-frames and a B-pyramid, AAC behind
   ADTS headers): every frame decodes through VideoToolbox once its start codes are lengths and an
   `avcC` is made from its parameter sets, and **an AVI keeps no presentation times**, so the order
   frames are shown in has to come from the codec. A Python walk of the slice headers gave it, and in
   that order the decoded frames change half as much from one to the next (a mean step of 1 376 against
   2 538). Core: `AVIFile` (the RIFF walk to the headers, `avih`, each `strl`, OpenDML's `dmlh` and
   `AVIX` RIFFs); `AVIIndex` (OpenDML's standard indexes, else `idx1` with its base found by the chunk
   its first entry names, else a walk of the `movi` lists that tells key frames by their first bytes);
   `AVIStreamFormat` (H.264, MPEG-4 Part 2 under DivX's and Xvid's dozen codes, Motion JPEG; PCM, MP1 to
   MP3, AC-3, and AAC raw or behind ADTS); `H264PictureOrder` (all three picture order types);
   `MPEG4Visual` (the layer's time increment width, plane headers, DivX's packed B-frames, the `esds`);
   `MotionJPEG` (Annex K's tables put back into a frame without them); `AudioFrameHeader` and its
   splitter (whole frames however the chunks cut them); `PresentationReorder` (decoding order in and
   out, each picture given the tick it is shown at); and `AVIDemuxer` (pictures timed by ticks, sound by
   chunks or by bytes as `dwSampleSize` says, each stream seeking in its own index). Slice 4's plan
   became `MediaPlaybackPlan`, and `MediaDemuxing` lets one player take either demuxer. App:
   `MatroskaPlayer` became `SampleBufferPlayer` (with `SampleBufferFeed`, `SampleBufferPreparation` and
   `QuickViewSampleBufferView`); a refused file whose first bytes say AVI plays there when something in
   it decodes, and gets the card otherwise, which now names its codecs from its own headers. 60 core
   tests, over a 117 KB sparse capture of the sample, whose 1 344 display ticks match the Python walk,
   and generated files for OpenDML, offsets from the file's start, no index, `rec ` lists and packed
   bitstreams; 6 app tests, over AVIs made of VideoToolbox's own H.264 with B-frames (each comes out at
   the time the encoder gave it), AudioToolbox's AAC and ImageIO's JPEG. Negative controls, each failing
   its tests: a reorder depth of 0, sound not timed again at a chunk boundary, constant-rate sound timed
   by chunks, a packed B-frame not held for the next tick, `idx1` counted from the `movi` list alone,
   the AVI route taken out, the table insertion off, and the ADTS check of before the fix below. Live in
   `build/live-copy`, the pane preview, with no permission request in the log: the sample read "⏸ 0:00 /
   0:53" and "1920×1080 · H.264 · AAC" on its first frame, Play/Pause ran the clock to 0:06, and ⇧→
   showed the last frame at 0:53 with the cursor on its row; an AVI remuxed from the 3GP's Xvid and AAC
   read "1280×720 · MPEG-4 · AAC", played, and a click halfway along the timeline carried on from 0:27
   with a clean picture; a 2560×1440 Motion JPEG without its tables, beside PCM, played clean; and a
   `DIV3` file got the card "AVI · 640×480 · MPEG-4 v3". Found:
   - **A raw AAC frame holds a pattern that reads as an ADTS header often enough**, so the first such
     pattern made the Xvid remux's AAC 169 three-block "frames" for 1 345 chunks, with a configuration
     made from noise. A header now counts only when the next one follows where it says it ends
     (`AudioFrameHeader.confirmed`), with a test that failed first.
   - **A flat JPEG decodes alike with the wrong Huffman tables**, so the table test passed with the
     insertion off until its frames were made busy (docs/NOTES.md ▸ Testing ▸ Negative controls).
   - **FFmpeg's AVI muxer leaves empty chunks in a sound stream**, and they are ticks: the sample's
     fourth AAC frame plays at 64 ms, not 43.

   **Not handled**: `memory_management_control_operation` 5, which x264 never writes; E-AC-3 behind
   the AC-3 tag; HEVC, DV and uncompressed pictures; ADPCM, A-law and µ-law, which AudioToolbox
   decodes but which come in blocks the bridge does not build; a Motion JPEG chunk holding two fields.
   **Not run live**: sound heard, full screen, OpenDML or a file with no index (generated files only),
   DivX's packed B-frames in a real file (none on this Mac), MP3 or AC-3 in a real AVI, the light
   appearance, a translation, a file on a server, and Matroska after the player's rename (its nine
   app tests pass).

**Live checks before the archive, 2026-11-21**, in `build/live-copy`, with a temporary env-gated
mute everywhere sound was not the subject. They clear most of the slices' *Not run live* lists:

- **Matroska after the player's rename**: the film played on its AC-3 track with the renderer
  `.rendering`, paused from the header, went to 1:35:23 on ⇧→ and to 0:47:44 on a timeline click.
  Steam's VP9 and Opus clip stopped at its end.
- **An AVI at full window**: the header and the timeline across the whole width, and it played.
- **The light appearance and German**: the header, and the card ("Dirnex kann diese Datei nicht
  abspielen."). View ▸ Play/Pause reads "Wiedergabe/Pause".
- **A 300 pt pane with a long name**: the split came back 849 / 300 after the AVKit player, the card
  and the Matroska player had been up, and with Quick View closed.
- **A movie over SFTP**, against a throwaway `sshd`. A 7 MB clip arrived on its own and played. The
  48 MB MP4 drew the Download card without spending a session, and played after ⌘D. Then a 499 KB
  WebM and the 35 MB AVI arrived on their own, the AVI inside twice the size agreed to.
- **A cloud placeholder**: an evicted iCloud Drive clip drew Quick Look's thumbnail and was still
  `dataless`, with 0 blocks, afterwards.
- **With full-screen control**: sound heard (Oleg), from the film's AC-3 track and from an AAC voice
  clip. A real drag on the timeline: the clock and the picture follow the knob mid-drag. ⌘P brought a
  faded full-screen header back, on play and on pause.

The film plays Russian because its track 2, a Russian AC-3 dub, carries `FlagDefault`. It is also the
first sound, so both halves of the rule pick it. The English original is DTS (track 9), and the only
English AC-3 is the commentary. Found:

- **The timeline could not be seen in the light appearance. Fixed the same day.** It sits on black
  in both appearances, and `NSSlider` followed the window's, so its track and its played part were
  dark on black and only the knob showed. The strip is now `.darkAqua` (`QuickViewSampleBufferView`).
  One app test, `timelineIsDarkInLight`, which failed before the fix. Live, light: the track and the
  played part both show.
- **At the end of a file the AVKit player left the header on ▶**, the playing glyph, though it had
  stopped; the core's player showed ⏸ there. **Fixed the same day.** A scratch `AVPlayer` showed
  why: the periodic observer's last call at the end comes while `rate` is still 1, and `rate` drops
  32 ms later with no call after it (docs/NOTES.md ▸ AppKit ▸ Previews, which had said otherwise). A
  KVO on `rate` now tells the header (`QuickViewMediaView.rateObservation`). One app test,
  `endReachesTheHeader`, which timed out before the fix. Live: a 3 s clip played out to "⏸ 0:03 /
  0:03". The header still floors a 3.99 s clip to 0:03, where AVKit shows 00:04.
- **Not a bug: the header's tooltips.** In the takeover run none showed on the ⊗ or the facts, while
  the tab strip's + did. Probes found the tooltips registered and the hit test right, and buttons
  added to the header late showed theirs on the left and not on the right. The window moved left,
  the ⊗ said "Close Quick View" and the facts their line. During full-screen control, a stretch of
  screen from about x 1160 pt, at the height of the window's top, shows no tooltip from any view,
  the title bar's own update badge included (docs/LIVE-VERIFICATION.md).
- **In a 300 pt pane, a clock with hours leaves the centered name at "T…" while the facts keep
  "1816×…".** The priorities hold. What costs the name is its required centering, beside a readout
  that is wider by the hour, so whether the name may leave the center is a design question, left
  open.

**Not run live**: a translation other than German, a VP9 or AV1 decoder on another Mac, and Vorbis or
AAC with sound in a real Matroska or AVI file.

**Autoplay. Asked and landed 2026-11-21 (Oleg):** "play video and audio files automatically in the
quick view", with a setting, on by default. Settings ▸ Panels ▸ *Play video and audio automatically in
Quick View* (`AppPreferences.quickViewAutoplayMedia`, `Dirnex.pref.quickViewAutoplayMedia`, absent
means on, computed over `defaults` as `confirmTransfers` is, since the class file is at the lint
ceiling), with a footer, in 14 languages. The surface asks `autoplaysMedia` each time a file goes up,
so a change applies from the next file, and calls `QuickViewMediaView.play()`, which starts either
player and does nothing over the card. The surface's own answer is no. The window hands its three
surfaces Settings' answer (the pane's, full window and full screen), so a test that builds a surface
alone still opens paused and asserts about nobody's settings, as `findOptions` is an init argument
for. The core's player is told to play before its feed has handed the renderers a packet, as a seek
while playing already was, and its clock, pictures and AAC all start from there. Seven app tests in
`QuickViewMediaAutoplayTests.swift`: a movie, a sound, a Matroska file, the answer asked per file, the
default, the round trip and the pane's wiring. Negative controls: without the call to
`play()` the four playback tests failed, without the pane's wiring its test did, and with the
default off the fresh-install test did. The wiring test tells the two apart only while Settings holds
the default, which an untouched test host does. Live in `build/live-copy`, over two hard links to the
silent `sample-1080p.mts` in `build/`, with no permission request in the log: the pane's Quick View
opened the first reading "▶ 0:09 / 0:53" and then 0:14, with no key pressed; the switch in Settings ▸
Panels, with its footer, wrote `false`; the second file then opened at "⏸ 0:00 / 0:53" and held there;
with the switch back on, full window (⌃⇧Q) played it from "▶ 0:05". **Not run live**: full screen,
which takes the front, a sound heard, and a translation of the two strings.

**Sound tracks. Asked and landed 2026-11-21 (Oleg):** "an audio track picker for the quick view, and
play it in the language of app by default". **Decided with him:** the picker is a menu in the header
plus View ▸ Next Audio Track on ⌥⌘P, and a pick holds for the file on screen only; the next file opens
in the app's language again. Probed first: the film's nine sounds (Russian ×6, Ukrainian, the English
DTS original, an English AC-3 commentary) and the first episode of each series (GOT, Silo, The Boys:
Russian default, English last, spelled `rus`/`eng` in two and `ru`/`en` in Silo), Foundation's language
codes, and AVFoundation's handling of an MP4 with two sounds (docs/NOTES.md ▸ Previews: Quick Look,
PDF and images). **The rule** (`MediaSoundChoice`): the first decodable sound in the app's language
(`Bundle.main.preferredLocalizations`), the file's default within it, a commentary or audio
description passed over (Matroska's `FlagCommentary` and `FlagVisualImpaired`, AVFoundation's
auxiliary-content and video-description characteristics, or "commentary" in the name); with none, the
default if it decodes, else the first that does, which is Slice 4's rule. So an English Dirnex plays
each series in English and the film still in Russian, since its English tracks are DTS and a
commentary. Core: `MediaLanguage` (ISO 639-1, both ISO 639-2 spellings and BCP 47 folded to one code,
with the twenty bibliographic codes Foundation does not know mapped first), `MediaSoundChoice`, the two
Matroska flags, `MediaPlaybackPlan(tracks:language:canDecode:)`, and the command. Workspace and Window
moved to `CommandCatalogWindow.swift` for the catalog's `file_length`. App: `QuickViewSoundTrack` (one
description for both players: "Russian · AC-3 · 5.1 · LostFilm", with "— can't play" for DTS),
`QuickViewAudibleOptions` (AVFoundation's alternatives; tracks in no group play together as the file
says and offer nothing), `QuickViewMediaView+Sound`, and "🔈 English ⌄" after the readout
(`QuickViewHeaderView+Media`, split out of the header at 499 lines), shown when more than one sound
plays, giving way after the facts and before the name. The core's player switches by flushing and
seeking a demuxer made for the picture and the new sound to where the clock is; AVFoundation's by
`select(_:in:)`, and a pick in AVKit's own menu reaches the header through
`mediaSelectionDidChangeNotification`. Language names start with a capital ("Русский"). "Audio Track"
and the command in 14 languages. 12 core tests and 11 app tests. Negative controls, each failing its
tests: the commentary not passed over, the bibliographic map off, `FlagCommentary` not read, no pick
made for AVFoundation, no language handed to the core's player, and no selection observer (timed out).
`appliesMediaSelectionCriteriaAutomatically = false` was tried and taken out: the pick holds without
it. Live in `build/live-copy`, muted, with a probe logging the track the feed reads and the sound
renderer's status: in English, GOT opened on "English" (track 5); Next Audio Track while playing
went to "Russian", the feed read track 2 `.rendering` with no error, and the clock ran on to 0:00:10;
the film opened on its Russian default and stepped 2 → 6 → 7 → 8 → 10, past the four DTS tracks; the
grouped MP4 opened on English, its second option, and stepped to Russian; View ▸ Next Audio Track sat
under Play/Pause. In Russian (`-AppleLanguages (ru)`), GOT opened on track 2 and the film's header read
"Русский ⌄" after the capital fix, with View ▸ «Следующая звуковая дорожка». No permission request in
the log. **Not run live**: the header's menu opened by a click (a background click would have left a
menu up on Oleg's screen; the menu's items, checks and pick are pinned by a test), AVKit's own menu,
full screen, a sound heard, an AVI with two sounds (none on this Mac), and a translation other than
Russian.

**Changing size. Asked and landed 2026-11-22 (Oleg):** "when i change views of quick view, it resets
the position and stops the video. can we make it seamless?" Each size has its own surface and its own
player, and a change of size put the old surface away, which stopped its player, and opened the file
again at 0:00 on the new one. Now the window hands the player itself across
(`BrowserWindowController.handOffQuickViewMedia`, called in `setQuickViewMode` before the surfaces are
reconciled): `QuickViewPreviewView.handOffMedia(to:)` moves the `QuickViewMediaView` into the new
surface's content and rebinds its header, and `showMedia` leaves a file the player already has up as
it is. Nothing is opened or read again, so AVPlayer and the core's player go on with the picture and
the sound they have, playing or paused, and autoplay does not apply. Only a file done opening moves
(`QuickViewMediaView.settledURL`); one still opening stays behind. Two things it turned up: a `.ts` or
`.mts` movie would have taken the TypeScript sniff's way again and started over, so a file the player
has up skips it (in `show`'s branch condition, since a branch of its own put `show` over cyclomatic
complexity 15); and `clear()` never invalidated a read in flight, so a size change while a movie was
still opening, with autoplay on, played it in the hidden surface. `clear()` now bumps `loadToken`.
Six app tests in `QuickViewMediaHandOffTests.swift`: AVPlayer playing, AVPlayer paused under the other
autoplay answer, the core's player with its display layer, a `.ts`, another file stopping the player
handed over, and a movie still opening. Negative controls, each failing what it should: no hand-off
(five), no keeping a file already up (four), no `loadToken` bump in `clear()` (the opening one), and
either `.ts` change alone (the `.ts` one). Probed: AVFoundation would not open the MP4 fixture renamed
`.ts` (docs/NOTES.md ▸ Testing ▸ Fixtures). Live in `build/live-copy` with autoplay off, over hard links
to the silent `sample-1080p.mts` and `x264-adts.avi` in `build/`, with no permission request in the
log: the `.mts` played at pane size from "▶ 0:01", read "▶ 0:12" either side of the switch to full
window, ran on to 0:25 there and read "▶ 0:28" back at pane size; the AVI, paused and moved to 0:21 on
its timeline, read "⏸ 0:21" on the same frame at full window and back at pane size. **Not run live**:
full screen, which takes the front and a Space of its own on Oleg's screen; the film itself, with its
sound; and the core's player playing across a switch (pinned by its test).

**Fixed 2026-11-22: CI on the 1.2.0 pull request.** The app job hung for 22 minutes in
`QuickViewSoundTrackTests.headerHidden`, inside an `AVAssetReader`, while seven sample-buffer queues
spun at full speed. They were sound renderers still asking for data from feeds already gone: a test
that played a file, paused it and dropped its surface left the request open, and nothing stopped it.
`SampleBufferFeed`'s `deinit` now stops both renderers' requests (docs/NOTES.md ▸ Previews: Quick
Look, PDF and images). `SampleBufferPreparation` moved to a file of its own for the line ceiling. One
app test, `SampleBufferFeedTests`, which failed without the `deinit`; a probe counting calls whose feed
was gone found the first open request in `QuickViewAVITests.playAndPause`. Two other failures in the
same run: `AttributeBatchEscalationTests` read osascript's log lines ahead of the body's message,
because the test host's `OS_ACTIVITY_DT_MODE` reached the child (docs/NOTES.md ▸ Attribute
escalation), and `AdministratorShell` now drops it; and `QuickViewScrollPageTests` read the PDF's
pages from before a scroll, so its wait is now for the page it expects.

**macOS 27.2.1, 2026-11-24: the update broke ten app suites that had passed CI on 26.6.2 two days
earlier.** All ten pass again, listed under *macOS 27.2* below. Two were the app's own: Settings'
menu pickers fell off the Tab loop (`SettingsPopUp`), and a double-click on the title bar's free
space stopped zooming (`TitleBarDoubleClickAction`, checked live). The rest were test instruments
that 27.2's gesture recognizers, a flipped PDF view and a field bezel that draws its states alike
took away. The full app run took about two minutes with no hang, and only two waits ran out, both
passing alone. Left: the keyboard checks a person has to make.

**The same day, the flaky items.** Three full runs with the live servers up. The NTLM failures were
the stand-in proxy's listen backlog, and that is fixed. Two suites' waits got 60 s, and two tests
that only passed when they won a race read their state after it now. Two full runs then passed
clean. One flake is still unexplained (below). The keyboard checks then passed with real keys, and
turned up two older gaps, both fixed below: the color rules' buttons off the Tab loop, and two
alerts whose Space pressed the action rather than the safe choice.

**Left undone so far:** VP8, Theora, VC-1 and WMV, RealVideo, MS-MPEG-4 v3 and DTS, which macOS cannot
decode. Any codec library (ffmpeg, libVLC, libvpx), for the licence, the size, and §2's rule that bytes
go through the core. Subtitles. Streaming a server's file without fetching it, since the remote
preview's size allowance still applies. Video in the slideshow.

The app's share of selling Dirnex (the private companion repo `dirnex-home`, milestones C1–C15) was
two milestones, **M29** (a license, and the reminder it removes) and **M30** (Report a Bug), both
shipped and archived in [docs/HISTORY.md](docs/HISTORY.md). Neither changed what Dirnex *is*: it
stays open source, fully usable without paying, and it never asks a server whether a license is
real. Before the store opens (the private repo's C12), the licensing switch goes on for stable, and
two small changes are proposed: Help ▸ Release Notes opening the website's changelog, and a "Lost
your key?" link in Settings ▸ License.

### Still open

Everything through M41 is shipped, and the record of it — the milestone checklists, the dated
passes that landed outside a milestone of their own, and the reasoning behind every decision — is in
**[docs/HISTORY.md](docs/HISTORY.md)**, which also tells how everything else on this list came off
it (HISTORY.md ▸ the follow-on log). M36–M40 took up the items in the table's *undone* column that
were left by choice; what is still open, rather than merely imaginable, is the list below. The column
itself stays as each milestone's record.

- **The thumbnail grid, brief view and the `PaneSurface` extraction** — M15's cut, and one unit
  rather than three items, argued in HISTORY.md §M15. Any future grid inherits two constraints from
  it: skip `FileEntry.isDataless` rows, and move sort off the column header first. The list's own
  rows have drawn a picture of an image, a movie or a PDF since 2026-11-11 (View ▸ Show Icon
  Previews, HISTORY.md after §M38), and a grid would take its thumbnails from the same `RowIcon`
  rule and `RowIconLoader`. M39 left its thumbnail filmstrip here too, since a filmstrip is a second
  file list.

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
| M18's Markdown renderer chases CommonMark, and its mermaid subset chases mermaid — both indefinitely, one individually reasonable case at a time. The renderer has it worse than M17's scanner, because a wrong answer here is a wrong *document* rather than a wrong color | Two different mitigations, because the two halves fail differently. For **markdown**, the target is named as a corpus rather than as a spec — this repo's own files, plus whatever real `.md` the next bug report arrives with — and the escape hatch is that an unreadable construct falls back to its literal text, so the worst outcome is a paragraph that looks like its source. For **mermaid** the boundary is a *list of diagram types*, and crossing it is loud by construction: an unsupported type renders its fence with a note naming it, so the pressure to add one shows up as a user asking rather than as a silently wrong drawing. The tell that the mermaid half is going wrong is the layout gaining knobs — mermaid has a config surface of its own, and reproducing it is how a subset becomes a port. **Held through the milestone, and both escape hatches were used**: the markdown half is pinned by a corpus suite over this repo's own `PLAN.md`, `README.md`, `NOTES.md` and `HISTORY.md` rather than against the spec's test cases, and the mermaid half reports by name — not only an unsupported diagram *type* but an unsupported construct inside a supported one (`subgraph`, `loop`, `alt`, `style`), which is more than the milestone asked for and in the same direction. The one thing that did arrive is the knob the risk names: a `diagramScale` and a shared `labelSize` (HISTORY.md §M18 Slice 4), both of them constants the *app* sets once rather than a config surface read out of the diagram's own source, which is the line worth keeping. **Held again through M39 (closed 2026-11-15)**: four diagram types arrived and no config surface with them, since front matter's `config`, the today marker's style, `classDef`, `style` and `click` are skipped or named in the caption; and every Markdown addition was scored against a corpus of real files, with GitHub's own renderer read where its rules are written nowhere |
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
