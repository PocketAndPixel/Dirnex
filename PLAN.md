# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: **M0–M31 shipped** (14 languages; M29's licensing is on in betas, off in stable until the
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

### Shipped: M0 → M31 (2026-07-05 → 2026-10-22)

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
| M23 | Copy, paste and drag, wherever the file is | 08-26 | Dragging a *folder* out of a server as a promise (a promise is one file; a recursive fetch behind a Finder drop has no progress surface and no way to stop it) and dragging an archive **member** out to another app, for the same reason one layer along — an encrypted archive would have to raise a passphrase sheet behind somebody else's drop, and `extractArchiveSources` reports failures with an alert rather than through a completion handler, so it would need Slice 4's always-answers contract first (taken by the user 2026-08-26, F5 copy-out being the route); `⌥⌘V` move-paste into an archive, which stays gated where it was; a *drop* into a browsed archive, where ⌘V adds by repacking and a drag does not; and the pasteboard as an automation surface — nothing here is scriptable that F5 was not. **Left for a human**, since a drag *session* cannot be synthesized: an actual drag between two panes, a Finder drag onto a connected server, and a drag from a connected server into Finder |
| M24 | Every local-only feature, on a file that is not local | 08-28 | **Content-grep and tag search on a server**, withheld at M22 for the reason that has not changed — no remote backend can answer either without reading every file; **ACLs and extended attributes remotely**, which SFTP and FTP do not carry at all; **Open in Terminal for an SFTP account**, which is an `ssh` session and a different feature; and a **folder that is not already here**, refused by every one of the seven hand-offs — a folder is an unknown number of objects in an unknown number of requests, and copying a tree out is F5's job |
| M25 | What a remote write carries, and what a remote delete costs | 08-29 | **A Trash the protocols do not have** — taken at §7 on 08-29, and the one part of the milestone that closed by not being built; **owner and group in a remote Get Info**, because `chown`/`chgrp` take a numeric id while `sftp`'s own `ls -la` prints names, so a panel built on a listing has nothing to send; **comparing by timestamp on FTP and S3**, refused by construction and always will be — `LIST` is year-less and zone-less, and an S3 `LastModified` is when the object was *written*; and ACLs and xattrs again, which is a limit rather than a gap |
| M26 | Move to Trash, wherever the file lives | 08-31 | **The remote backends**, which have no Trash at all and are already degraded to a confirmed permanent delete (§M5, and M25 §7's decision not to invent one); **chasing the refusal further into TCC and `fileproviderd`**, which is not observable from here past the three candidates already eliminated — the fix does not depend on knowing which policy denies; and **Put Back for an item *Finder* deleted out of a provider domain**, or for anything trashed before the store shipped, both of which keep the honest answer the restore flow already gives by name. A **third** origin source landed 2026-09-20 — a network share's own `#recycle`, where the bin mirrors the original path so there is no record to be missing (HISTORY.md ▸ the follow-on log) |
| M27 | Legacy code-page archive names | 09-09 | **Inferring** the code page — no reader can, and a wrong guess is a plausible name for the wrong file, so it is a chooser over a preview and never a detector; **preserving an un-representable name byte-for-byte**, the rejected streaming rewrite, which keeps bytes nobody can read and still cannot extract that row *out* of the archive; and **persisting the declaration** across sessions, since it is a guess the user made about one archive and a wrong one silently outliving the session is worse than being asked again |
| M28 | iCloud Photos, as folders of originals | 09-13 | **Import, delete and album edits**, each a write Photos mediates with its own confirmation; **smart albums** — one a person made is returned by no PhotoKit fetch, and the system ones are views over the library rather than places; **shared albums, the Shared Library and hidden photos**, left out as Photos' own Library view leaves them out; **a per-asset time zone**, which PhotoKit does not expose, so months are cut in the Mac's; **⌘L inside the library**, which has no real directory to start from; and **Photos' lowercase `.mov`** for a Live Photo's movie, since a row's name is part of its path. **Exercised later that evening**: the download of an original that is only in iCloud, on clips recorded for it — the bar sat at zero and Stop was ignored until the request carried a progress handler (HISTORY.md §M28); after that fix a 219 MB copy arrived byte-identical and Stop on a 276 MB one stored nothing |
| M29 | A license, and the reminder it removes | 10-01 | **Revoking a refunded key inside the app** (the server marks it; an in-app list waits until refunds are actually abused); **trials that stop working, and activation limits**; **any copy protection beyond the signature**, since the source is open and the reminder is a request, not a lock; and **the Keychain** for the key, which is signed rather than secret. **Seen only in tests or a Debug build**: the Renew reminder on a release build, the prominent Renew… in Settings ▸ License, a pasted production key, and the 13:00 rule |
| M30 | Report a Bug, and a Help menu to hold it | 10-07 | **Anything the user didn't type or tick** in a report: no logs, no screenshots, no file names or paths, one crash report at most; **the website** naming Help ▸ Report a Bug…, until a stable release has it (the private repo's C8). **Seen only in tests**: Email Instead's draft, the rate-limit and refusal messages, and Escape. **Open**: a click in the email field once left the focus in Steps, in a computer-use run |
| M31 | A compare window of our own | 10-22 | **Editing, copying a block across and saving**, a later milestone's decision; **a three-way merge**; **a file over 64 MiB** in the window, refused by name and left to the external tools; **a binary comparison**. **Seen only through a probe**: a Mac with no external diff tool. **Not run live**: an external tool from the conflict dialog, FTP and S3 pairs, and Escape |

### Next: M32 (planned 2026-10-22)

The app's share of selling Dirnex (the private companion repo `dirnex-home`, milestones C1–C15) was
two milestones, **M29** (a license, and the reminder it removes) and **M30** (Report a Bug), both
shipped and archived in [docs/HISTORY.md](docs/HISTORY.md). Neither changed what Dirnex *is*: it
stays open source, fully usable without paying, and it never asks a server whether a license is
real. Before the store opens (the private repo's C12), the licensing switch goes on for stable, and
two small changes are proposed: Help ▸ Release Notes opening the website's changelog, and a "Lost
your key?" link in Settings ▸ License.

### M32 — WebDAV (M)

**Planned 2026-10-22.** WebDAV is the remote protocol that Nextcloud, ownCloud, Synology and QNAP
NASes, and a long list of hosted storage services offer, and Dirnex speaks none of it. SFTP, FTP and
S3 each got a backend of their own. This milestone adds the fifth protocol the same way: a
`WebDAVBackend` in the core, reached through stock `curl`, behind the connect sheet, the saved
servers and every gesture the other remotes already have. Oleg turned on the NAS's WebDAV Server for
it, on HTTP 5005 and HTTPS 5006, with anonymous access and `DavDepthInfinity` off, for the
`dirnex-test` account.

Probed 2026-10-22 against that server before any Swift, with `curl` 8.7.1 and the credential on
stdin:

- **The NAS is Apache `mod_dav`** (`Server: Apache`, `DAV: 1,2` plus Apache's own
  `propset/fs/1`, Basic realm `SYNO_WebDAV Storage`). **macOS ships the same server**:
  `/usr/sbin/httpd` 2.4.67 with `mod_dav`, `mod_dav_fs`, `mod_auth_digest` and `mod_ssl` ran
  unprivileged on `127.0.0.1:8088` from a twenty-line config and answered MKCOL 201, PROPFIND 207, a
  wrong password 401 and Depth infinity 403. So the live suite gets a throwaway server with nothing
  to install, and a wrong password can be tried there, never on the NAS (its Account Protection
  locks the account after a few failures).
- **That is one implementation family, not two.** A suite green against both proves agreement with
  Apache, not with WebDAV (§6 has the row). Docker is on this Mac, so a Nextcloud container (sabre/dav,
  a different codebase) can supply the second family, with Oleg's OK for the image download.
- **`nas.local` costs 5.37 s a request without `-4` and 0.016 s with it.** That is the mDNS stall
  NOTES.md ▸ Resolving a host name records, and `HostDialer` applies unchanged. The NAS's address
  moved from .3 to .7 since September, so the bare name is the handle worth saving.
- **The live properties arrive under the prefix `lp1`, bound to `DAV:` on each `response`**
  (`<lp1:getlastmodified>`), while `href`, `prop` and `status` use `D:`. A parser that matches the
  prefix `D:` reads every row and finds no size, date or type on any of them. Match by namespace URI.
- **A collection is known by `<resourcetype><collection/>`, never by a trailing slash.** The account
  root lists the shared folders as `/home`, `/share` and `/media` without one, while every href a
  level down has it. GET on a collection answers 403, not an index.
- **Hrefs come back percent-encoded in lowercase hex**, with `;`, `+`, `=` and `&` (as `&amp;`)
  left literal, `[` and `]` encoded, and a decomposed é kept byte for byte (`cafe%cc%81`). So paths
  are compared decoded, never as the string that was sent: the uppercase hex `curl` sent would miss
  the self row. A `+` is a plus, and decoding it as a form would rename the file to one with a space.
- **A PROPFIND with no `Depth` header is Depth infinity** (RFC 4918), so it gets the same 403 as an
  explicit one. Every listing sends `Depth: 1`, and a subtree is a walk.
- **The write verbs are richer than SFTP's and FTP's.** MKCOL answers 201, 405 when it exists and
  409 when the parent is missing. PUT answers 201 new and 204 replaced. **DELETE of a whole tree is
  one request**, the recursive delete `RemoteTransportBackend` walks for the other two. COPY and MOVE
  run on the server, across shared folders too (home → share); `Overwrite: F` answers 412 and a MOVE
  into itself 403.
- **There is a create-if-absent.** PUT with `If-None-Match: *` answers 201 when new and 412 when
  the file exists, bytes untouched. That is the guard `RemoteTransportBackend`'s doc comments say
  neither other protocol has. `If-Match` with a stale ETag answers 412 too, so a write-back can check
  the server's copy by its ETag, which `RemoteFileRevision` already carries for S3.
- **`Destination` must be an absolute URL.** A path-absolute one, which RFC 4918 allows, gets a bare
  400 "Bad Request" and nothing else. The server's IP spelling of itself was accepted.
- **The modification time cannot be set, and one way of trying reports success.** PROPPATCH of
  `getlastmodified` answers 409 "Property is read-only". `Win32LastModifiedTime`, which Windows'
  client sends, answers **200 OK** and changes nothing; it is stored as a dead property. Nextcloud's
  `X-OC-Mtime` header is ignored. A 200 from PROPPATCH is therefore never read as "time carried".
- **A lock held elsewhere is its own outcome.** With a LOCK on a file, PUT answers 423. A DELETE of
  the folder holding it answers **424 Failed Dependency**, deletes nothing, and names the locked
  member in a multistatus body. As with S3's batch delete, the body is the outcome, and the status is
  neither 204 nor 207.
- **Resume works**: a Range GET answered 206 and left a byte-identical file (60 000 of 100 000
  bytes moved), and onto a complete file 416, so the size is checked first, as for S3.
- **Apache writes at an offset**: PUT with `Content-Range: bytes 2-3/6` answered 204 and changed
  those two bytes. RFC 9110 says a server must refuse that, so it carries no feature until a second
  server family proves it.
- **No quota.** RFC 4331's `quota-available-bytes` comes back 404 in the propstat.
- **HTTPS presents the same self-signed Synology certificate as FTPS on port 21**, with an identical
  key pin. `curl` exits 60 without trust, 207 with `--pinnedpubkey`, and 90 on a wrong pin before any
  data moves. `FTPCertificate` and the trust sheet carry over unchanged.
- **A delete on this NAS lands in the share's `#recycle`**, which is an ordinary row in the listing
  (the probe folder is sitting there now). The protocol itself has no Trash.
- 32 MiB went up at 85 MB/s and came down at 95 MB/s, byte-identical, so one `curl` per transfer is
  not the limit on a LAN.

Decided before Slice 1:

- **A backend of our own over stock `curl`**, as FTP and S3 have. The credential rides on stdin
  (`-K -`), trust is `--pinnedpubkey` paired with `--insecure` through the existing enum, `-4` comes
  from `HostDialer` per config section, and the status is read from a labelled write-out with the
  exit code demoted, S3's inverted classifier, since this is HTTP. `URLSession` would rebuild the
  pin, the progress meter, the dialer and the classifier this codebase already has for `curl`, and
  would be the only in-process network stack among the remote backends. Its one real advantage,
  keeping the connection between requests, is what FTP's batched invocations already buy: many
  PROPFINDs in one `curl` run reuse one connection. Riding the OS mounter, as SMB does, is not this
  milestone: a mount trusts a certificate system-wide, where Dirnex pins it per saved server.
- **Basic authentication, and Digest when the server's challenge asks for it.** Basic goes out
  preemptively, with no 401 round trip. The scheme is read once from the connect probe's 401 and kept
  for the connection, instead of `--anyauth`, which pays the extra round trip on every request.
  NTLM, Negotiate and OAuth tokens are out; Nextcloud's app passwords are Basic.
- **HTTPS by default. Plain HTTP is a deliberate switch with a cleartext note**, as plain FTP is,
  because Basic sends the password in every request. It cannot be refused: the NAS's default port is
  plain HTTP.
- **A location is a base URL plus a root path**: scheme, host as typed, port, the path the account
  starts at (`/remote.php/dav/files/<user>/` on Nextcloud, `/` on the NAS) and the user name. The
  root is part of the backend id. The Keychain item follows FTP's shape without it,
  `<scheme>:<user>@<host>:<port>`, since two roots on one server share one password.
- **The parser reads the RFC, not Apache's spelling**: `XMLParser` with namespaces on, elements
  matched by URI, only `propstat`s whose status is 200, hrefs that may be absolute URLs (the RFC
  allows them, other servers send them), decoded to bytes before any comparison.
- **One request per verb, in its safe spelling.** Create uploads with `If-None-Match: *`, rename and
  move are MOVE with `Overwrite: F`, copy within a server is COPY (`ServerSideCopySupport`), delete is
  one DELETE whose body is read, and F4's write-back sends `If-Match` with the ETag it read.
- **No time is carried and none is compared.** `copyMetadata` reports the time as not carried
  through `RemoteMetadataPlan`, as for S3, and `DirectorySync` refuses comparing by timestamp: an
  uploaded copy is stamped when it was written.
- **No locks of our own.** Finder locks around a write; Dirnex relies on the ETag instead, and a 423
  or 424 says that the file is locked by someone else, by name, rather than "permission denied".
- **Never Depth infinity**, even on a server that allows it: the answer is one unbounded document,
  parsed whole. Folder sizes and Find Files walk with `Depth: 1`, batched per level.

#### Slices

1. **Location, hrefs, the listing parser and errors** (core, additive). `WebDAVLocation`,
   `WebDAVHref` (decoding, the strict encode set NOTES.md ▸ curl gives for FTP, decoded comparison),
   `WebDAVMultistatusParser` and `WebDAVResponseError` (401, 403, 404, 405, 409, 412, 423, 424 and
   507, and member errors inside a multistatus). The fixtures are bytes captured from the NAS and the
   local Apache, not written from the RFC, with negative controls for each finding above: the `lp1`
   prefix, lowercase hex, `+`, a decomposed name, a collection with no slash, a 404 propstat, a 424
   body.
2. **The read half** (core). `WebDAVProcessArguments` with its stdin config, `WebDAVTransport`,
   `WebDAVBackend` (list, stat by `Depth: 0`, read with resume, `capabilities` `.read`) and the
   connect probe (OPTIONS for the `DAV` header, the 401 for the scheme), against an injected fake fed
   the captured bytes.
3. **Connect and browse** (app). `WebDAVCurlTransport`, the connect sheet's fifth protocol
   (`ConnectServerWebDAVFields`: host or URL, port, HTTPS or HTTP with the note, root path, user,
   password), `PanelViewController+ConnectWebDAV`, routing and capabilities on `CompositeBackend`,
   `ServerKind.webdav` and `ServerEndpoint.webdav` with the trusted pin, the sidebar glyph, the path
   bar, Edit Server, reconnect and session restore, and the FTPS trust sheet for a self-signed
   certificate. Live against the NAS: browse, trust the certificate, F5 a file out byte-exact.
4. **The write half** (core, then app). MKCOL, upload by `-T` (never to a URL ending in `/`, which
   appends the local name, NOTES.md ▸ curl for S3), the create-if-absent guard, MOVE, COPY, DELETE
   with its body, the ETag-guarded write-back, `acceptsUploads`, and the metadata report.
   `capabilities` becomes `[.read, .write]`.
5. **Every gesture the other remotes have.** The batched subtree walk for folder sizes, ⌥F7 Find
   Files (M22's fields), copy, paste and drag (M23), M24's hand-offs, Quick View and F4.
6. **Live, and the record.** `WebDAVLiveIntegrationTests` against the throwaway Apache, over HTTP
   and over HTTPS with a self-signed certificate, gated on the config `scripts/live_test_servers.sh`
   writes; the NAS over both ports; the second server family if a container is approved; all 14
   languages; and a WebDAV column in [docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md).

**Done when:**
- the NAS's `dirnex-test` account connects over HTTPS after trusting its certificate once, and over
  HTTP with the cleartext note, and the bare name `nas` reaches it in well under a second;
- browsing, F5 both ways, F6 rename and move (on the server), F7, F8 (one request), F4 with its
  write-back, Quick View and folder sizes all work there, byte-exact;
- a name with Cyrillic, a decomposed é, and `# % ; + ? & = [ ]` survives create, list, rename and
  delete;
- a write-back over a file changed on the server since it was read is refused by its ETag, not
  overwritten, and a locked file says it is locked;
- the live suite is green against the throwaway Apache, and its executed-test count shows it ran;
- LOCATION-SUPPORT.md has a WebDAV column, every cell argued.

Expected to be left undone, each for its own reason: **Depth infinity**; **locks of our own**;
**NTLM, Negotiate and OAuth**; **setting the time**, unless a Nextcloud server makes `X-OC-Mtime`
measurable as a per-server capability; **Apache's offset PUT** as a segmented upload; **quota**;
**CalDAV, CardDAV, versioning and WebDAV ACLs**; and **a Trash**, which the protocol does not have.

#### Progress

**2026-10-23: Slice 1 landed** (core only; the app is untouched).

- **Core:**
  - `WebDAVLocation`: the descriptor `davs://` or `dav://` + `<user>@<host>:<port><root>`, the
    root stored decoded in one normal form, the mapping between the pane's paths and the server's
    (the root compared as bytes), request URLs, and the Keychain item `<scheme>:<user>@<host>:<port>`.
  - `WebDAVHref`: an href decoded segment by segment into a server path, byte comparison of paths,
    and the strict encoding for requests.
  - `WebDAVMultistatusParser`: elements by namespace URI, values only from a 2xx `propstat`, an
    href only directly under `<response>`, an outcome row reported once per href it lists, and
    RFC 9110's three HTTP date forms beside RFC 3339.
  - `WebDAVListing`: the folder found by decoded bytes, the rows directly inside it, and each row
    as a `FileEntry`.
  - `WebDAVResponseError`: `WebDAVMethod`, `curl`'s exit codes below HTTP, and a refusal
    classified by status, method and the members a 207 or 424 body names.
- **Tests:** 68 in five new suites. The fixtures are 13 real bodies under `Fixtures/WebDAV`: the
  same folder made on the NAS and on macOS's Apache and listed both ways, the account root, a
  listing that holds a locked file, and the refusals.
- **Measured while capturing them:**
  - **A tag read in the same second its file was written is weak, and `If-Match` with it answers
    412** for a file nobody else touched. Two seconds later the unchanged file reads back
    `"6-65e74002dd28e"` where it read `W/"6-65e74002dd28e"`, and `If-Match` with the `W/` dropped
    answered 204. So Slice 4's write-back cannot send the tag as it was read, and two readings of
    one file have to be compared without the `W/`. Which of the two fixes it takes, re-reading or
    dropping the marker, is Slice 4's decision; the second leans on Apache's way of making tags.
  - **A lock stops only writes.** With a LOCK held on a file, GET answered 200, PROPFIND 207, and a
    COPY *from* it 201. A 423 therefore first arrives with the write half.
  - The two servers return the same hrefs in different orders, and macOS's Apache sends no
    `getcontenttype` for a collection where the NAS sends `httpd/unix-directory`. A MOVE of a folder
    holding a locked file answers the same 424 body as a DELETE.
- **Decided in the slice:**
  - **The user name is split at the authority's last `@`, after the root is cut off at the first
    `/`.** Hosted services log in with an e-mail address, and Nextcloud's root contains it again.
  - **Four kinds of href are refused rather than repaired, and counted:** a segment that decodes
    to contain `/`, a `.` or `..` segment (F5 would write into the parent folder), bytes that are not
    UTF-8, and a relative href, which no server measured sends.
  - **When no row is the folder that was asked for, the folder is the row every other row sits
    in.** That is what a reverse proxy at a prefix the server does not know produces, and the
    entries are rebuilt from the folder the pane asked for. Rows with no such folder are refused.
  - **A lock maps to `EBUSY` until Slice 4.** Its own sentence needs a `VFSUnsupportedReason` and
    14 translations, and only writes can meet it.
  - An empty user name is a location without credentials, for a public share.
- **Found on the way:** the test meant to pin the href rule passed with the rule removed. A row of
  properties takes its first href, and the lock token comes after the file's own, so the fixture
  could not tell. The rule decides only for an outcome row whose `<error>` carries an href (RFC 4918
  §16), and a test of that shape now fails without it.
- **Negative controls:** each of four deliberate breaks fails tests: accepting every `propstat`,
  taking an href anywhere, comparing paths as `String`s, and decoding `+` as a space. In the tests
  themselves, Swift's `==` and `hasPrefix` are first shown to call the two spellings of é equal,
  S3's form decoder is shown to rename `d+e`, the fixture's text is checked to spell its properties
  `lp1:`, and a 424 without its body is shown not to be a lock.

**2026-10-23: Slice 2 landed** (core only; the app is untouched).

- **Core:**
  - `WebDAVProcessArguments`, with `WebDAVSession`, `WebDAVAuthScheme`, `WebDAVDepth` and
    `WebDAVConfigFile`: `-q` first, the scheme spelled `--basic` or `--digest`, `-K -` only when
    credentials go out, the pin through `FTPTrust`, PROPFIND with six named properties inline, a
    download with `--fail` and `-C -`, and the certificate probe.
  - `WebDAVWriteOut`: labelled lines plus `%{header_json}` on stderr, and the rule that turns one
    `curl` run into a `WebDAVHTTPResponse` or a transport failure.
  - `WebDAVTransport`: two verbs, `propfind` and `download`.
  - `WebDAVBackend`: list by `Depth: 1`, stat by `Depth: 0`, download with resume, and
    `capabilities` `.read`.
  - `WebDAVConnectProbe` with `WebDAVChallenge` and `WebDAVConnectError`.
- **Tests:** 68 in six new suites, 136 across WebDAV. 18 new fixtures, 14 of them `curl`'s own
  stderr from real runs against the NAS and macOS's Apache. The exit code is in each name, and the
  fake replays them through the shipped reader.
- **Measured while building it:**
  - **A download cut short by `--max-time` reported status 200 with exit 28**, and left 584 179 of
    3 129 010 bytes under the file's name. So the exit code decides before the status. S3's runner
    lets any status through, so a download that outruns its 3600 s budget would count as copied there
    (NOTES.md ▸ curl (WebDAV)).
  - **`%header{}` gives the first of several headers only.** The challenge `Negotiate`, `NTLM`,
    `Basic` came back as `Negotiate`, so the headers ride `%{header_json}`.
  - **`~/.curlrc` is read unless `-q` comes first.** A `--head` in it turned a GET into a HEAD that
    exited 0. FTP and S3 do not pass `-q`.
  - **Apache answers a PROPFIND for a file named as a collection (`photo.jpg/`) with a bare 400.**
    A listing that gets 400, 404 or 409 therefore asks once more without the slash, and a file there
    is `notADirectory`.
  - Digest is two requests per `curl` (no nonce in a new process), and a Basic header sent to a
    Digest location was logged with no user rather than as a failed login.
- **Decided in the slice:**
  - **The probe is two `Depth: 0` PROPFINDs of the root, not OPTIONS.** The NAS sends no `DAV` header
    without credentials, and with them answers OPTIONS on a missing path with 200 and `DAV: 1,2`.
    Nextcloud exempts OPTIONS from authentication. So OPTIONS proves neither the root nor the
    password. The first PROPFIND goes without credentials and the 401 names the scheme. The second
    goes with them, and its 207 proves the password, the root and WebDAV at once. A server without
    WebDAV answers 405.
  - **Both schemes offered: Basic over HTTPS, Digest over plain HTTP.** An account still logs in
    where reads are public (Basic, then Digest once if that is all the 401 offers), because such a
    server may want the account for writes.
  - **Redirects are reported with their target, not followed**, so credentials never go to a place
    nobody chose. The root is answered without a request, as FTP's and S3's are. Any transport
    failure in the backend is `EIO`, as theirs is.
- **Live, through the shipped argument builders and reader** (a throwaway package over the core,
  which checked every run's argv for the password):
  - **The NAS over HTTP 5005**, by the bare name `nas` dialed as `nas.local -4`: connected in 0.39 s
    and listed `/` and `/home`. A file listed as a folder was `notADirectory`; a missing file was
    `notFound` and left no file behind. A download from 100 000 bytes resumed with 3 029 010 reported,
    and came out byte-identical (SHA-256) to a direct `curl`.
  - **The NAS over HTTPS 5006:** exit 60 with no trust and 90 on a wrong pin; with the NAS's pin, the
    same run passed in full.
  - **macOS's Apache:** Digest picked and listed; Basic found behind Negotiate and NTLM; a wrong
    password `credentialsRefused`; a public folder with no account; `credentialsRequired`,
    `notWebDAV(405)`, `redirected` and `rootNotFound`. In the access log the first request of every
    connect went with no user.
- **Found on the way:** the first live run reported a root that is a file as a 400 refusal. The
  probe asks for the root as a collection, which gets Apache's 400, and its unit test had been fed a
  207 that Apache never sends for that request. The probe now applies the listing's rule, and a test
  feeds it the real 400.
- **Negative controls:** each of seven deliberate breaks fails tests: status deciding alone, the
  first header value only, no file fallback in a listing, credentials sent before the challenge,
  commas inside quotes splitting a challenge, backslash escapes ignored, and no `-q`. The probe's
  file-root rule fails its test when removed. The quoted-comma control first passed: no test string
  put `, Scheme ` inside quotes. A test now does.

**2026-10-23: Slice 3 landed** (core and app). Read-only, as planned: `capabilities` stays `.read`
and `acceptsUploads` leaves WebDAV out until Slice 4.

- **Core:** `ServerKind.webdav`, and `ServerEndpoint.webdav(location:authentication:trustedPublicKey:)`
  with `ServerConnections.settleWebDAV`. `WebDAVLocation.displayAddress` is the sidebar tooltip, the
  root's URL rather than `davs://`. The location files its password like any other, and a public
  share files none. `WebDAVAddress` splits what the Host field holds. `isRemoteConnection` and
  `LocationSource` name WebDAV.
- **App:**
  - `WebDAVCurlTransport`, over `CurlProcess`, a runner with no protocol in it. FTP and S3 keep their
    own copies for now.
  - `CompositeBackend` registers, routes and reports capabilities.
  - The connect sheet's fifth protocol (`ConnectServerWebDAVFields`): HTTPS by default, the HTTP note,
    a Path row, and a blank user for a public share.
  - `PanelViewController+ConnectWebDAV`: the core's probe, FTPS's trust alerts (which now take a host),
    and a sentence for each `WebDAVConnectError`.
  - Reconnect and session restore, Edit Server, the globe glyph, the path bar's root title, and 14 new
    strings in all 14 languages.
- **Tests:** 20 core tests in two new suites and 23 app tests in four. The new-tab, glyph and
  trust-alert suites now include WebDAV. Core 4340 and app 1857 green; the live server suites skipped
  for want of their config, and nothing under them changed.
- **Decided in the slice:**
  - **The scheme the probe settles is stored in the endpoint, as FTPS's pin is.** A restored tab
    registers without asking the server anything, and guessing costs a refused login rather than a
    round trip: the NAS offers Basic alone over HTTP and macOS's Apache Digest alone. A sidebar
    connect probes again, and a changed scheme or pin is written back into the saved record.
  - **The Host field takes a whole URL.** Leaving the field, or pressing Connect, spreads it over the
    security, port, path and user fields, so the sheet shows what will be dialed. With a scheme the
    path is percent-decoded under the href rules; without one it is literal, as the Path field is.
  - **An edit carries the scheme and the pin while scheme, host and port are unchanged**, and drops
    both otherwise. The user and the root may change without dropping them.
  - **Removing a saved server keeps the password if another saved root on the same account uses
    it**, since the Keychain item leaves out the root.
  - Five FTP failure sentences became named accessors, so each sentence WebDAV shares keeps one key.
- **Live, against a throwaway macOS Apache** (Basic over HTTPS with a self-signed certificate at
  `/basic`, Digest over HTTP at `/digest`). A temporary probe gave the build the password from its
  environment, so nothing touched the Keychain. It was removed afterwards and the build rebuilt.
  - The sidebar connect raised the trust alert. Its fingerprint, and the pin it saved, matched
    `openssl`'s for the served certificate. In the server log: a PROPFIND with no user drew the 401,
    then the Depth 0 probe and the Depth 1 listing went with credentials. The saved record was
    settled to `basic` and the pin.
  - F5 brought `random.bin` (3 MB) out byte-identical in one GET. `café #%;+?&=[].txt`, with a
    decomposed é, kept its name bytes exactly, and `Кириллица` listed.
  - After a quit and relaunch, the restored tab reconnected with one PROPFIND: no probe, no prompt,
    and the cursor back on its file.
  - Digest connected with its 401/207 pairs and settled to `digest`.
  - The sheet drew the WebDAV rows with the HTTP note. A Nextcloud URL pasted into Host spread to
    HTTPS, 443, the decoded path and the e-mail login on Connect.
  - The defaults domain was restored afterwards and compared unchanged.
- **Live against the NAS**, the same day, with two saved servers for `dirnex-test` by the bare name
  `nas`: HTTPS 5006 with no pin, and HTTP 5005. A second temporary probe had the app read the
  existing SFTP Keychain item itself (one prompt, answered by Oleg) and keep the password in memory.
  Nothing was written to the Keychain, the probe was removed, and the defaults domain was restored
  and compared unchanged.
  - HTTPS connected to the account root (`home`, `media`, `share`). The record settled to `basic`
    and the pin `gkHDtx…`, which is `openssl`'s for the NAS certificate and the saved FTPS server's
    pin. The trust alert was answered at the screen rather than by the run, so its contents were not
    read this time; the Apache run above read them.
  - F5 of `media/temp/_voices/female.wav` (1.7 MB) came out byte-identical to the same file read
    through the SMB mount of that share (SHA-256 `7c74bb7a…`): two protocols, one file on disk.
  - HTTP connected and settled to `basic` with no pin, since the NAS offers Basic alone there.
  - After a relaunch, both panes came back on their NAS tabs, HTTPS in `_voices` and HTTP at the
    root, with no trust prompt.
- **Not run live yet:** the changed-certificate branch, a public share, an edit saved through the
  sheet, and a timing of the bare name inside the app (Slice 2 measured 0.39 s through the core).
- **Negative controls:** each of four deliberate breaks fails tests: WebDAV dropped from
  `isRemoteConnection`, a schemeless path decoded, reconnect ignoring the stored scheme, and the edit
  carry ignoring the port.

**2026-10-23: Slice 4 landed** (core and app). `capabilities` is `[.read, .write, .rename]`, and
`acceptsUploads` takes WebDAV in.

- **Core:**
  - `WebDAVProcessArguments+Write`: MKCOL with the slash, an upload by `-T` with the meter, an empty
    PUT, MOVE and COPY with an absolute `Destination` and `Overwrite: F`, and DELETE. `WebDAVTransport`
    gains the six verbs.
  - `WebDAVBackend+Write`: `createDirectory`; `createFile` as one PUT with `If-None-Match: *`; `moveItem`
    as one MOVE, a folder included; `removeItem` as one DELETE whose body is read; uploads; a COPY
    tried for a duplicate inside the account (`mayAttemptInternalCopy`), latched on 501 or 405; the
    ETag-guarded `writeBack`; and the date carried onto a download, as FTP and SFTP carry theirs.
  - `HTTPEntityTag` and `RemoteFileRevision.preconditionTag`: two readings compare weakly, and only a
    strong tag guards a write.
  - `VFSUnsupportedReason.lockedOnServer(name:)`, which replaces Slice 1's `EBUSY`. The reasons'
    sentences moved to `VFSUnsupportedReason+Sentence.swift`, since the file had reached 500 lines.
- **App:** `WebDAVCurlTransport` gains the six verbs, with a 600 s budget for a request the server
  carries out on its own disk. The save-back reads `preconditionTag`. The lock sentence is in all 14
  languages. Routing needed nothing new: the composite already forwards every verb by path.
- **Tests:** 40 core tests in five new suites, 197 across WebDAV, and 40 new fixture files: each
  verb's answers captured from macOS's Apache through the shipped argument builders, including a
  lock held from outside and one file's tag read weak and then strong. Core 4381 and app 1859 green.
  The live server suites skipped for want of their config.
- **Measured while building it** (macOS's Apache, 2026-10-23):
  - **Apache's tag is the size and the modification time truncated to the whole second, and it is
    weak while the request is within a second of that.** In that second, `If-Match` answered 412 with
    the tag as read and with its `W/` dropped alike; 2.2 s later the strong tag answered 204. So
    dropping the marker, one of Slice 1's two candidate fixes, cannot make the guard pass. Comparing
    two readings is RFC 9110's weak comparison either way.
  - **`curl` 8.7.1 adds `Expect: 100-continue` only above 1 MiB, not ~1 KiB** as NOTES.md and three
    S3 doc comments said: 1 048 576 bytes were sent whole before a 412, 1 048 577 not at all. All six
    places are corrected.
  - **A cancelled PUT changes nothing.** Apache writes into a temporary file: a 64 MiB upload killed
    part-way left no file, and one killed over an existing file left its bytes as they were.
  - `If-None-Match: *` onto a folder answers **409**, which RFC 4918 also spends on a missing parent.
    `If-Match` onto a deleted file answers **412**, the same as a changed one. MOVE into a missing
    folder answers 500 and COPY 409.
  - **COPY keeps the mode and not the date**: a 2020 file copied as today.
  - A case-only MOVE on a case-insensitive disk is refused, 412 with `Overwrite: F` and 403 "Source
    and Destination URIs are the same" with `T`, and the file stays as it was.
  - Apache took a `Destination` naming another host, and answered 502 for another scheme.
- **Decided in the slice:**
  - **A weak tag sends no condition** (taken by Oleg 2026-10-23, over re-reading until the tag is
    strong). Apache hands one out for about a second after any write, exactly when a quick second ⌘S
    checks, and a guard refused every time is worse than none. Such a save rests on the re-`stat`, as
    SFTP's and FTP's always do. A weak tag is still kept verbatim for Get Info.
  - **An F5 upload is unconditional; only `createFile` carries `If-None-Match: *`.** The checksum
    manifest and the pack delivery rely on an upload replacing (`ChecksumCreateRun`), and `CopyEngine`
    makes the destination free before it copies.
  - **A 409 from the create-if-absent PUT is followed by one stat**, since only the server can say
    whether a folder is in the way or the parent is missing. A 412 against `If-Match` is followed by
    one stat as well, to say changed or gone.
  - **A 207 from a write is a refusal when a member refused, success when none did, and a failure
    when its body cannot be read.**
  - **COPY is attempted, not promised.** A 501 or 405 latches for the connection, and any refusal
    sends the copy through this disk.
  - **Only the date is counted as not kept**, on uploads, COPY and recreated folders. WebDAV has no
    permissions anywhere, so a mode has nothing to be missing from: S3's reading.
  - A lock names the member a 424 body names, since for a folder that is the file somebody has open.
- **Live, against the throwaway Apache over HTTP with Basic.** A temporary probe gave the build the
  password from its environment, so nothing touched the Keychain. The probe was removed and the build
  rebuilt (the binary checked for it), and the defaults domain was restored and compared unchanged
  (71 keys).
  - The seeded tab reconnected with one PROPFIND. F5 sent three files as one PUT each, with no
    condition, byte-identical, and the name `cafe\u{301} #%;+?&=[].txt` arrived byte for byte.
  - F5 down was one GET per file, byte-identical, and both copies carried the server's 2020 date.
  - F5 between two folders of the account was one COPY with the Cyrillic `Destination` encoded, and
    the status line read "Copied — the modification time wasn't kept on 1 item". F6 of the odd name
    was one MOVE.
  - F7 through the sheet made `Новая [папка] #1 + é` with one MKCOL. ⇧F4 made `new = 1 & ;.txt` with
    one PUT carrying `If-None-Match: *` and no content type.
  - F8 of a folder whose file was locked from outside was one DELETE answered 424; nothing was
    deleted, and the alert read "“held.txt” is locked on the server, usually because someone has it
    open. Try again once they have closed it." After UNLOCK, one DELETE removed the folder.
  - **F4's save-back, saves written into the edited copy from the shell:** the first save sent the
    strong tag as `If-Match` (204). A second inside the weak second sent no condition (204), with no
    question, where before this slice it would have sent `W/"…"` and been refused as somebody else's
    edit. A third, two seconds later, read the strong tag against the weak one recorded after the
    second save, asked nothing, and sent the strong tag (204). After another client wrote the file, the
    next save raised "The file on the server has changed since you downloaded it", and Keep Editing
    sent nothing.
- **Live against the NAS the same evening**, `dirnex-test` over HTTPS 5006 and HTTP 5005 by the bare
  name `nas`, dialed as `nas.local`. One temporary probe had the app read the account's SFTP Keychain
  item (Oleg answered the prompt) and hold the password in memory; afterwards no `com.dirnex.webdav`
  item existed. A second probe appended each `curl`'s method, URL, conditions and status to a
  scratch file, since the NAS's own log is out of reach, and `NSLog` arrives in the unified log as
  `<private>`. Both probes were removed and the build rebuilt (the binary checked for them), and the
  defaults domain was restored and compared unchanged (71 keys). The HTTPS endpoint carried the pin
  `gkHDtx…`, which `openssl` computed again for the served certificate.
  - **HTTPS:** F7 made `dirnex-slice4 [live] #1 + é` with one MKCOL. F5 up of four files and the
    folder `Папка` was one MKCOL and five unconditional PUTs, all 201. F5 down was five GETs, every
    file byte-identical to its original, the decomposed é's bytes kept, and each copy carrying the
    server's date. A copy inside the account was one COPY (201) with "Copied — the modification time
    wasn't kept on 1 item". F6 of the odd name was one MOVE (201).
  - **F4 over HTTPS:** the first save sent the strong tag (204), the second inside the weak second
    sent none (204) and asked nothing, and the third sent the new strong tag (204). Dirnex's own F5
    Replace then rewrote the file, as PUT to a hidden sibling, DELETE and MOVE with `Overwrite: F`.
    The next save asked "The file on the server has changed…"; Keep Editing sent nothing, and
    Upload All sent `If-Match` with the tag the check had found (204).
  - **HTTP:** F7 made `dirnex-slice4-http Кириллица` with one MKCOL. F5 from the HTTPS account was
    staged, a GET over HTTPS and a PUT over HTTP, and the relay's folder was empty afterwards. ⇧F4
    was one PUT with `If-None-Match: *` (201). F4's three saves went as over HTTPS. F5 down brought
    both files back byte-identical, the relayed 3 MiB file included.
  - F8 removed each test folder with one DELETE (204), over HTTPS and over HTTP. Both landed in the
    share's `#recycle` and were deleted there too (`%23recycle`, 204). The probe folders earlier
    slices left in `#recycle` were left alone.
  - **The NAS's tag carries the modification time to the microsecond** (`"1b-65e8692f53fde"`),
    where macOS's Apache truncates it to the second, so a rewrite there always changes the tag. It
    is still weak for the second after a write: the second save's check got no usable tag.
- **Not run live yet:** a lock on the NAS (an outside client would need the password in a shell;
  Slice 1's captured 423 and 424 bodies are in the unit tests, and the alert was seen on Apache),
  Digest, F2's inline rename (background computer-use cannot commit a text field), a refused
  `If-Match` read as changed or gone (the check catches the change first, so only the unit tests
  reach it), and a server without COPY.
- **Negative controls:** each of nine deliberate breaks fails tests: tags compared as strings, a weak
  tag sent as a guard, a 207 read as success, no stat after a create's 409, every COPY refusal
  latched, gone read as changed, a lock mapped to `EBUSY`, the mode counted as lost, and the form
  content type left on.

**2026-10-23: Slice 5 landed** (core and app). Only the walk needed new code. Every other gesture on
the list already keys on `isRemoteConnection`, `acceptsUploads` or `RemoteFetchPolicy`, and was run
live rather than written.

- **Core:**
  - `WebDAVProcessArguments+Batch`: `listings(session:requests:credentials:)` puts one `Depth: 1`
    PROPFIND per folder in a single `-K -` config, each section whole and its body in its own file.
    The first section alone carries `fail`, and the run `--fail-early`. `WebDAVBatchWriteOut` reads
    each section by its own `%{exitcode}`. `WebDAVTransport` gains `propfindBatch`.
  - `WebDAVBackend+Listings`: `subtreeListing` a level at a time, which the sizer, ⌥F7 and directory
    sync all ask before walking, and `listDirectories` for a tree refresh. `subtreeRowLimit` is FTP's
    50 000.
- **App:** `WebDAVCurlTransport+Batch`, with FTP's `BatchScratch` given a label. Get Info's
  permissions note named an object store and an IIS-style FTP listing as the reasons, which on a
  WebDAV row reads as a mislabelled server. It now names them, WebDAV among them, as examples of
  servers and protocols that send none, in all 14 languages.
- **Tests:** 32 core tests in two new suites, 223 across WebDAV, and 16 new fixture files: real
  batched runs through the shipped builder against macOS's Apache (a level with a missing folder, a
  refused login, a missing first folder, Digest, a refused connection, a wrong pin), and every
  folder of one tree. One new app test pins that the composite reaches both seams. Core 4413 and
  app 1860 green; the live server suites skipped for want of their config.
- **Measured while building it** (macOS's Apache, 2026-10-23; NOTES.md ▸ curl (WebDAV)):
  - **A wrong password cost one failed login per section**: four sections gave four 401s. With
    `fail` on the first section and `--fail-early`, one. `fail` does not survive `next`, and
    `--fail-early` acts only on a transfer that failed, which a 401 is not without `fail`.
  - **One run kept one connection, and reconnected by itself at Apache's keep-alive limit of 100**:
    250 sections made three connections and took 0.04 s, against 1.48 s as 250 runs. Digest stayed
    on the connection and paid its 401 per section.
  - `--fail-early` stopped a refused connection after one attempt, where four sections without it
    tried four times.
- **Decided in the slice:**
  - **A first folder refused on its own sends the rest of the level again; a 401 or a section with
    no answer ends the level.** A 404 there is a folder deleted since it was listed, while a refused
    login would be refused for every folder after it.
  - **A level not wholly answered is no shortcut**, stricter than FTP: skipping a folder nobody
    answered for would return a subtree short of a branch that still claimed to be complete, and
    the sizer would show its total as the folder's. A folder the server *refused* is skipped, as the
    walk skips it.
  - Never Depth infinity, as decided before Slice 1. One open folder goes the ordinary way.
- **Live, against the throwaway Apache**, over HTTP with Basic, then over HTTPS with a pinned
  self-signed certificate. A temporary probe gave the build the password from its environment, so
  nothing touched the Keychain; it was removed and the build rebuilt (the binary checked for it).
  The defaults domain was restored and compared unchanged (71 keys). A Debug copy nobody in the
  session had launched was running first, and was quit with Oleg's OK.
  - **Space on a folder of 250 folders** (folder *i* holding *i* bytes): 251 PROPFINDs over 4
    connections in 0.242 s, and the row read 31 KB for 31 375 bytes. Over HTTPS the same over 4 TLS
    connections, 0.237 s. **The same build with `WebDAVBackend+Listings.swift` moved aside walked:
    251 connections, 4.225 s.**
  - ⌃B sized the other folder in one connection per level (1, 4, 3, 1) and took the first from the
    total Space had just measured.
  - **A tree refresh**, 15.2 s after a tab switch, re-listed the root and three open folders as four
    requests on one connection. The first show of the tab lists each open folder separately, as it
    did before; that is the tree's restore path.
  - **⌥F7** offered name, kind, size and date. `r.b` found only `c d+é/r.bin`, 261 requests in six
    runs, 0.27 s.
  - ⌘C on that hit and ⌘V into a local pane: one GET, byte-identical, with the server's date. Quick
    View from the results tab: one GET. In the tree the cursor passed `f100` without fetching it, and
    `top.txt` drew its text.
  - The compare window drew the WebDAV `top.txt` against a changed local copy, "Change 1 of 1",
    from the copy Quick View had fetched. Synchronize Directories gathered its WebDAV side in the
    same six runs and offered Size and Content, with no Date. Create Checksum stat'ed the free name
    (404), fetched nothing, and wrote the manifest in one PUT; its digest matched `shasum`. Get Info
    showed the size, the date and the entity tag.
- **Found on the way:** the search's count was four over the walk's own, and the four were the tree
  pane's refresh landing mid-search on a connection of its own. Read the requests, not the count
  (LIVE-VERIFICATION ▸ a session count is not evidence while a background poll is running).
- **Not run live yet:** the NAS, which is Slice 6's; dragging out to Finder, since a drag session
  cannot be synthesized; Open With, Share, ⌥F5 and user scripts, which reach the same fetch the
  compare and checksum runs did; Digest in the app; and a refused login or a first-folder 404 in the
  middle of a walk, which the unit tests drive.
- **Negative controls:** each of six deliberate breaks fails tests: `fail` on every section, a resend
  after a 401, no resend after a folder's own refusal, a level not wholly answered taken as a
  shortcut, the first line for a section winning, and the status read without the exit code.

**2026-10-23: FTP's tree refresh stops at one failed login** (core and app). Slice 5's measurement
that a wrong password costs one failed login per section held for FTP too, and NOTES.md already
said so for 3 sections. What it cost had not been counted: a tree refresh runs on a timer, so a
password changed on the server spent it every round.

- **Measured first**, through the shipped builder against pyftpdlib: 4 sections, 4 failed logins
  and 4 sessions, and the fallback then tried once more. In the running app, a tree with four
  folders listed after the password changed spent **9 a round**, two rounds running, since the
  batch carried `MLSD` beside each `LIST` by then.
- **The fix, taken by Oleg over listing the first folder alone first:** the refresh's batch runs with
  `--fail-early`. FTP refuses a folder with a transfer error, unlike HTTP's 404, so the run also
  stops at the first refused folder, and `FTPBatchRun.reading` finds the stop by the first file that
  did not land and its cause by the run's exit code. A folder's refusal (9, or 19 for a folder that
  can be entered and not read) sends the rest again; a refused login ends the round; no answer
  falls back to one listing per folder as before. A refresh is still one login.
  - **Core:** `FTPBatchRun` and `FTPBatchStop`, `FTPTransport.listingsUntilFirstFailure` with a
    default that lists one folder at a time and stops at the first failure, the builder's
    `stopsAtFirstFailure`, and `FTPBackend.listDirectories`. The subtree walk keeps the run that
    does not stop.
  - **App:** `FTPCurlTransport+Batch` reads the run's exit for the stopping run only.
- **Tests:** 14 new and 5 rewritten, across the batched-listing suite, its request suite and two new
  ones for the reader and the protocol default. The batched-listing fake now counts sign-ins the way
  the server's log did; the old one counted a batch as one attempt, which is why the cost never
  showed. Core 4427 and app 1860 green; the live server suites skipped for want of their config.
- **Live,** the same tree in the running app with the password changed under it: 1 failed login a
  round, three rounds running, against the committed backend's 9. A temporary probe gave the build
  the password from its environment; it was removed and the build rebuilt, and the defaults domain
  was restored and compared unchanged (71 keys).
- **Negative controls:** each of six breaks fails tests: the committed backend, a refused login sent
  again, no `--fail-early`, a stop on `MLSD` ignored, 19 not read as a folder's refusal, and no
  answer not retried.

**2026-10-24: Slice 6, first half: the live suite and the record** (tests, a script and docs; no
product code changed). The NAS run of the suite, the second server family and a live look at the
sheet in other languages are still to come.

- **`scripts/live_test_servers.sh` stands up macOS's own `httpd`** beside `sshd` and pyftpdlib, on
  8088 and 8443, with nothing to install. It writes `/tmp/dirnex_webdav_live_test.json` naming four
  endpoints: Basic, Digest and a public folder over HTTP, and Basic over HTTPS with a self-signed
  certificate minted per `up`, whose pin goes into the config. `DavDepthInfinity Off`, as on the NAS.
  The access log carries the user and the status of every request. `up | tail` no longer hangs:
  pyftpdlib held the pipe open.
- **`WebDAVLiveIntegrationTests`, ten tests run once per endpoint** (39 cases), through the real
  `WebDAVCurlTransport`. A counting wrapper says what each verb cost in requests, which is the
  client's claim and holds on any server. A raw `curl` is the other client, spelled by hand, for a
  lock held elsewhere and a colleague's save. Covered: the connect settling each endpoint's scheme;
  no user, a wrong password, a wrong pin and no pin refused by name; the done-when list's awkward name
  through MKCOL, PUT, list, MOVE of the file, COPY and MOVE of the folder (one request each), download
  and one DELETE, compared as bytes and also read off the served folder on disk; a taken name refused
  with no `stat` before the PUT, the bytes there kept; the subtree shortcut against the walk; a
  missing folder in a batch, in the middle and first; a save-back over a colleague's save refused by
  its tag, then passing with the current tag, then refused as gone with nothing created; a lock
  naming `held.txt` on a write and on a folder's DELETE, deleting nothing, reads passing; resume of a
  partial copy and a restart onto a complete one; and a wrong password in a four-folder batch costing
  **one** failed login in the server's own log.
- Each endpoint's facts are written in the config, not inferred: the scheme it must settle on,
  whether its certificate is self-signed, whether a wrong password may be sent (never on the NAS),
  where its access log and its served folder are. A `keychain` entry stands in for `password`, so the
  NAS can join a run without its password in `/tmp`. A `recycleFolder` lets the suite empty its own
  folders out of the NAS's `#recycle`.
- Assertions run outside `offCooperativePool`, so a failure is filed under its own test and
  endpoint.
- **Measured:** 1811 tests executed with the servers up against 1755 with them down, and 18 suites
  ran that skip without them, under the same summary line both ways: `1870 tests in 295 suites
  passed`. CLAUDE.md and the script's
  hint carry the new numbers. Core 4427 and the app suite green; both linters clean.
- **Negative controls, six breaks in one build:** the save-back's `If-Match` dropped, the create's
  `If-None-Match` dropped, a 423 mapped to `EBUSY`, `fail` removed from the batch's first section,
  `#`, `?` and `+` left unencoded, and resume switched off. Each failed its own test on every endpoint
  it applies to. The literal `#` ended the URL, so the folder came back `notFound`. Without the
  batch guard a wrong password cost **4** failed logins for 4 folders. The connect, refusal and
  subtree tests stayed green, so no break leaked past its own test. Reverted with `git checkout`.
- **[docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md) has a WebDAV column**, 92 cells, after FTP.
  New notes: <sup>5</sup> (what was verified live, and that both servers are Apache), <sup>aai</sup>
  (no server-side walk, by decision: Depth infinity), <sup>aaj</sup> (downloads resume, uploads
  restart) and <sup>aak</sup> (no split download; no milestone owns it). Ten existing notes name
  WebDAV where it differs: the date carried one way, COPY latched and costing the date, `If-Match`
  only with a strong tag, and the tree refresh's one failed login.
- **Found on the way:**
  - **No split download for WebDAV.** SFTP, FTP and S3 each have one (`SegmentedDownloadPlan`), and
    Range requests answer 206 on the NAS, so nothing prevents it. M32 never planned it. One stream
    moved 95 MB/s on the LAN.
  - **Over WebDAV the delete confirmation promises a permanent delete on a NAS that keeps a copy.**
    The *may keep a copy in `#recycle`* wording is gated on `path.backend == .local`
    (`PanelViewController+DeleteFallback`), and a WebDAV delete on the NAS lands in `#recycle`. Whether
    the NAS's bin catches an SFTP or FTP delete has not been measured.
  - A Debug build from 2026-10-23 23:34 is still running (pid 52041), launched by nobody in this
    session; the test runs rebuilt the binary under it.

**2026-10-24: A large WebDAV download splits over several connections** (core and app). Slice 6's
first half found WebDAV the only remote without a segmented download; this closes that cell.

- **Probed first**, against the throwaway Apache and a second scratch one holding every connection to
  4 MiB/s with `mod_ratelimit`: four ranges in one `curl -Z` opened four connections at once and
  joined SHA-256 identical; 40 MiB took **10.12 s in one stream, 5.08 s in two, 2.46 s in four and
  1.25 s in eight** (two rounds alike), and the same over pinned HTTPS and Digest; with nothing
  limiting a connection, four ranges of 16 MiB cost 4 ms over HTTP and 8 ms over HTTPS. A stale
  `If-Range` answered 200 with the whole file, and a stale `If-Match` 412 with nothing sent, which
  decided the guard. Three more findings went to NOTES.md ▸ curl (WebDAV).
- **Core:**
  - `SegmentedDownloadLimits.webdav`: 8 MiB, 4 MiB, at most 4 ranges. S3's threshold, since a range
    costs one connection made in parallel; FTP's ceiling, since a NAS or a proxied server often caps
    connections per client, and eight beat four only on the throttled link.
  - `WebDAVProcessArguments.downloadSegments` and `WebDAVSegmentWriteOut`: one `-Z` run, each section
    carrying `fail`, `If-Match` with the tag, its range, its own file, its own write-out line and the
    connection's options (`-4`, scheme and credential, pin); `-q` first and `--parallel-immediate`
    in `argv`. Each section is read by its own `%{exitcode}`. `WebDAVTaggedFile` carries the path and
    the tag. The batch builder's connection lines and the exit-code rule (`WebDAVWriteOut.isAnswer`)
    are shared now rather than written twice.
  - `WebDAVTransport.downloadSegments`, whose default forwards to the plain download and says so.
  - `WebDAVBackend+Segmented`: a file whose listing says it is over 8 MiB, with nothing on disk, is
    stat'ed once for its current size and tag, then split. No strong tag, no split. All 206: joined.
    A 412: the file changed, so one stream, no latch. A 200: the server ignores ranges, latched for
    the connection. Some served and the rest refused or unanswered: latched, as a cap would be. Every
    range refused: one stream, no latch. A short piece: one stream, latched. One tally spans the
    split and its fallback, so no byte is reported twice. A stat the server refuses is thrown as the
    file's answer.
- **App:** `WebDAVCurlTransport+Segmented`, progress from the pieces growing and capped at the file's
  size, and a backstop of the transfer budget, since `max-time` sits in the config.
- **Tests:** 24 core tests in two new suites, 247 across WebDAV, and 12 new fixtures: ten runs
  captured through the shipped builder (four ranges over HTTP, HTTPS and Digest, out of order; a stale
  tag; a file shorter than the plan; a server ignoring `Range`; a wrong password; a refused
  connection; a wrong pin; a cut) and two `Depth: 0` answers for a large file, strong and weak. Two
  live tests on all four endpoints: F5's download of a 16 MiB file is one stat and four ranges,
  byte-identical, with the same file fetched unhinted as the control that must go in one GET; and
  ranges carrying a stale tag are refused, each one, writing nothing. The server's log agreed: four
  206s and one 200 per run, and Digest one challenge per range. Core 4451 and app 1872 green, 1846
  executed with the servers up; both linters clean.
- **Negative controls:** each of seven breaks fails its own core test: `If-Match` dropped, a section's
  exit code ignored, a weak tag allowed, the latch ignored, the 412 branch removed, the 200 branch
  removed, and the fallback reporting bytes again. The first run put the 412 and 200 breaks beside the
  latch break, which hid them; run alone, each failed. Live, dropping `If-Match` failed the guard
  test on all four endpoints and switching the split off failed the split test on all four, with the
  other ten tests green.
- **Found on the way:** the first half's subtree test compared entity tags as strings and failed on
  this run: the shortcut read `W/"40-…"` and the walk a moment later `"40-…"`, the weak second NOTES
  already records. It compares weakly now.
- **Not measured:** the NAS. One stream moved 95 MB/s there on the LAN, and whether its disks serve
  four readers of one file faster or slower than one is unknown; measuring it needs the account's
  password in a run.

**2026-10-24: The split, live in the app and on the NAS.** Three temporary probes, all removed
afterwards and the build rebuilt (the binary checked for them): a WebDAV password from the
environment, or from the account's SFTP Keychain item read once (Oleg answered the one prompt); a
log of each `curl` request with its timing; and a switch turning the split off, so the same build ran
both paths. The defaults domain was restored and compared unchanged (71 keys). A Debug build left
running since 2026-10-23 had exited by itself before the run.

- **In the app, F5 off the throttled Apache** (4 MiB/s a connection), 40 MiB dated 2020, from a
  seeded tab that reconnected with one PROPFIND: one `Depth: 0` stat, then four GETs on four
  connections, each 206 with exactly its range and the stat's tag as `If-Match` (the server's log
  read the `Range` and `If-Match` headers back). **2.81 s from F5 to a complete file; with the split
  switched off, one GET (200) and 10.27 s.** Byte-identical both ways, the 2020 date carried, no
  pieces left in the temp folder.
- **The whole WebDAV live suite against the NAS, over HTTPS 5006 and HTTP 5005** (22 cases; the
  wrong-password test has none there by design). It closes Slice 6's NAS item, two of Slice 4's
  "not run live yet" — a lock held by another client on the NAS says it is locked by name and
  deletes nothing, and a refused `If-Match` is read as changed or as gone — and Slice 3's timing of
  the bare name, which connected within the one second the config claims (through the test host,
  not the app). The awkward names, resume and the batched listing held there too. The split test came
  down as one stat and four ranges, byte-identical, and stale-tagged ranges were refused writing
  nothing. Its folders and their copies in `/home/#recycle` were removed by the suite's own cleanup,
  which was not read back afterwards.
- **On the NAS the split is slower.** 256 MiB over gigabit, three alternating rounds a port: one
  stream 2.43–2.62 s (102–111 MB/s), four ranges 2.62–3.29 s, on average **0.43 s slower over HTTPS
  and 0.29 s over HTTP**. Joining 256 MiB of pieces takes 0.05–0.16 s here; the rest is the NAS and
  the wire serving four connections where one already filled the link. Recorded in
  `SegmentedDownloadLimits.webdav` and LOCATION-SUPPORT.md <sup>aak</sup>. Whether to keep splitting
  where that is the case is open.
- **The live config's Keychain item is read once per run**, however many endpoints name it, so the
  NAS's two ports cost one prompt rather than two (`WebDAVLiveEnvironment`).
- **Seen once and not chased:** `Panes divider detent / a queued release from another window cannot
  end the divider drag` failed in one app run (the current event's location read 1642 pt where it
  expected 430) and passed on the rerun. Nothing in this change reaches it.

### Still open

Everything through M31 is shipped, and the record of it — the milestone checklists, the sixty
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
| M32's WebDAV backend is fitted to one server. The NAS and the throwaway `httpd` are both Apache `mod_dav`, so every fixture, every live run and every probe agree with Apache, and a parser can pass all of them while reading Apache's spelling rather than the protocol | The parser matches elements by namespace URI and reads only what RFC 4918 promises, so `lp1:` and `D:` are one case rather than two. The fixtures are captured bytes, and the corpus gets a second implementation family (Nextcloud's sabre/dav, in a container) before the milestone closes. The tell is a branch keyed on a prefix, on the `Server` header or on a slash at the end of an href. A capability only Apache has, such as the offset PUT, stays unused until a second server answers it the same way |

## 7. Open questions

**None open.** M25's was the last, and it closed on 2026-08-29. Every question this plan asked since
M0, and how each one closed, is in [docs/HISTORY.md](docs/HISTORY.md) ▸ **The questions the plan
asked**.
