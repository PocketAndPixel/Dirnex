# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: **M0–M28 shipped** (14 languages) · **M29 in progress** (licensing: Slices 1–3 landed) ·
**M30 planned** (bug reports) ·
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

### Shipped: M0 → M28 (2026-07-05 → 2026-09-13)

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
| M26 | Move to Trash, wherever the file lives | 08-31 | **The remote backends**, which have no Trash at all and are already degraded to a confirmed permanent delete (§M5, and M25 §7's decision not to invent one); **chasing the refusal further into TCC and `fileproviderd`**, which is not observable from here past the three candidates already eliminated — the fix does not depend on knowing which policy denies; and **Put Back for an item *Finder* deleted out of a provider domain**, or for anything trashed before the store shipped, both of which keep the honest answer the restore flow already gives by name. A **third** origin source landed 2026-09-20 — a network share's own `#recycle`, where the bin mirrors the original path so there is no record to be missing (HISTORY.md ▸ the follow-on log) |
| M27 | Legacy code-page archive names | 09-09 | **Inferring** the code page — no reader can, and a wrong guess is a plausible name for the wrong file, so it is a chooser over a preview and never a detector; **preserving an un-representable name byte-for-byte**, the rejected streaming rewrite, which keeps bytes nobody can read and still cannot extract that row *out* of the archive; and **persisting the declaration** across sessions, since it is a guess the user made about one archive and a wrong one silently outliving the session is worse than being asked again |
| M28 | iCloud Photos, as folders of originals | 09-13 | **Import, delete and album edits**, each a write Photos mediates with its own confirmation; **smart albums** — one a person made is returned by no PhotoKit fetch, and the system ones are views over the library rather than places; **shared albums, the Shared Library and hidden photos**, left out as Photos' own Library view leaves them out; **a per-asset time zone**, which PhotoKit does not expose, so months are cut in the Mac's; **⌘L inside the library**, which has no real directory to start from; and **Photos' lowercase `.mov`** for a Live Photo's movie, since a row's name is part of its path. **Exercised later that evening**: the download of an original that is only in iCloud, on clips recorded for it — the bar sat at zero and Stop was ignored until the request carried a progress handler (HISTORY.md §M28); after that fix a 219 MB copy arrived byte-identical and Stop on a 276 MB one stored nothing |

### Next: M29 → M30 (planned 2026-09-29)

Dirnex starts selling licenses. The store, the key server, the website at dirnex.app and the launch
are planned in the private companion repo (`dirnex-home`, milestones C1–C15). These two milestones
are the app's share, and they come first. Neither changes what Dirnex *is*: it stays open source,
fully usable without paying, and it never asks a server whether a license is real.

### M29 — A license, and the reminder it removes (M)

**Planned 2026-09-29.** What is sold is a **license**: a signed key that turns off a reminder in
every version released during the key's period (one or two years), and keeps those versions
reminder-free for good. Updates keep reaching everyone. A version released after the period shows
the reminder again until the key is renewed. The milestone lands **dormant**: nothing appears
until a release is built with the licensing switch on — betas first, and stable on the day the store
opens.

Decided before Slice 1 (2026-09-28/29, with Oleg). Each is a recommendation that is cheap to
overturn until Slice 4 puts the reminder in front of a user:

- **Checked offline, never on a server.** The key is `dnx1.<payload>.<signature>`. The payload is
  base64url JSON (`v`, `id`, `to`, `issued`, `until`), and the signature is Ed25519 over the ASCII
  bytes of `dnx1.<payload>`. The app verifies it with a public key it carries (CryptoKit's
  `Curve25519.Signing`, already a core import). There's no launch-time request and no activation
  count. A key works on every Mac of the person it names, offline, whether or not the server is up.
  Unknown payload fields are ignored, so the format can grow.
- **Coverage is by release date.** A build is covered when its release date is on or before the
  key's `until` (UTC dates). The release workflow writes the date into `Info.plist`
  (`DirnexReleaseDate`) from the same timestamp it gives the appcast's `pubDate`, so an update can be
  judged *before* it is installed (`SUAppcastItem.date`). A missing date never punishes a customer:
  an undated build or update counts as covered.
- **Only official builds remind.** The reminder runs only in a build made by `release.yml` with its
  licensing switch on. A Debug build, an `xcodebuild test` host and anyone's own build from source
  never show it. Building Dirnex yourself is free, and that is the promise the open source makes. A
  Debug-only launch argument previews both reminder variants and fakes the clock.
- **Thirty quiet days.** The grace period counts from the first launch of a build with the switch
  on, not from install. So nobody who used an earlier, dormant build meets the reminder on the day it
  arrives.
- **When it appears.** After the 30 days, the reminder appears if there's no key, or if the key
  doesn't cover this build:
  - at every launch, and
  - at the first activation of each new calendar day while Dirnex stays running. Macs sleep rather
    than quit, so launch alone would almost never fire.

  It never stacks over the first-run tour or the Full Disk Access sheet; it waits for them.
- **What it is.** A sheet over the browser window. It's a custom window, not an `NSAlert`, so
  `scripts/check_alert_escape.py` isn't asked to allow an exception. It has three buttons:
  - a large **Buy a License**, in the accent color but deliberately *not* the default button;
  - **Enter License…**;
  - a small **OK**.

  **Escape and Return do nothing.** This is the one surface in the app where that is intended,
  because the sheet must not be dismissed by habit. It isn't a trap: OK is one click away, Tab
  reaches it (`KeyboardReachableControls`) and Space presses it, and VoiceOver reads and presses
  every button. Draft copy:
  - Title: *"Thank you for using Dirnex"*
  - Body: *"Dirnex grows from its users' wishes and feedback. If it's useful to you, a license keeps
    it going."*

  A key whose period has ended says so instead: *"Your license covers versions released until
  12 March 2027. This version came out later. Renew to remove this reminder."*, with **Renew** in
  place of Buy.
- **A quiet label.** While the reminder is due, a small **Unlicensed** (or **Renew License**) label
  sits in the titlebar's leading cluster, beside the update indicator. Clicking it opens the License
  tab. It's hidden during the 30 days and whenever a key covers the build.
- **Holding a key.**
  - Settings gains a **License** tab. It shows the status (*Licensed to Jane Doe · updates until
    12 March 2027*), a field that takes a pasted key (with the spaces and line breaks an email adds
    removed), Buy or Renew, and Remove.
  - `dirnex://license?key=…` activates a key from the email's link. It always asks first, naming who
    the key is for, since any web page can open that URL.
  - The key is kept in preferences, not the Keychain. It isn't a secret (it's signed, not hidden),
    and a Keychain read raises prompts on builds signed differently (CLAUDE.md).
  - A key that verifies but doesn't cover this build is still kept. It covers older versions, and a
    renewal replaces it.
- **Updates for a key whose period has ended.** Everyone keeps getting updates. The one change:
  before a version the key doesn't cover is installed, Dirnex says so once, with **Renew**, **Update
  Anyway** and **Not Now**: *"Your license covers versions released until … Dirnex 1.4.0 came out
  later, so it will show the license reminder. Your current version stays reminder-free."*
  - Sparkle must never install such a version silently in the background.
  - An install with no key sees no notice, because its reminder doesn't change.
  - Covered updates are untouched.
  - Dirnex's own probe (`checkForUpdateInformation`) installs nothing, so it proceeds and still
    lights the indicator.
- **Commands.**
  - `app.license` (*License…*) goes under *Check for Updates…* in the App menu, and `app.buyLicense`
    (*Buy a License…*) goes beside it. Both are in the palette.
  - They open `https://dirnex.app/buy` and `https://dirnex.app/renew?license=<id>`. Only the random
    license id goes in a URL, never a name or an email.
- **Not in this milestone:**
  - revoking a refunded key inside the app (the server marks it; an in-app list waits until refunds
    are actually abused);
  - trials that stop working, and activation limits;
  - any copy protection beyond the signature. The source is open, and the reminder is a request,
    not a lock.

#### Slices

1. **The contract.** The key format above, pinned by test vectors.
   - A throwaway test key pair signs about a dozen keys, made by the TypeScript signer in the private
     repo (the same module the store's server will use).
   - The vectors cover: a valid key; `until` in the past; one payload byte changed; a signature from
     another key; a wrong prefix; bad base64url; an unknown `v`; a missing field; an unknown extra
     field (accepted); and a non-ASCII `to`.
   - The vectors are committed here as fixtures. The test private key may be public; the production
     one never enters any repository.
   - The production key pair is generated once, in this slice, with its private half going into
     Oleg's password manager.
2. **The core** (additive, app untouched).
   - `LicenseKey`: parses, and never throws on hostile input.
   - `LicenseVerifier`: the public key is injected.
   - `LicenseCoverage`: release date against `until`.
   - `LicenseReminderPolicy`: the grace period, launch versus activation, calendar days in the Mac's
     time zone, and a clock that moves backwards.
   - `UpdateCoverageNotice`: from a key and a pending update, whether to show the notice.

   Tested against the vectors, with negative controls: a verifier that skips the signature, a
   coverage check off by one day, and a policy that ignores the grace period.
3. **The app: holding a key.** The License tab, paste-to-activate, the URL scheme with its
   confirmation, both commands in the menu and palette, the production public key, and storage.
   Translated into all 14 languages (`check_localization_keys.py` green).
4. **The app: the reminder.**
   - The switch and the release date run through `release.yml`, `build_app.sh` and
     `make_appcast.sh` from one timestamp; docs/RELEASING.md gains both.
   - The grace record; the sheet, queued behind onboarding; the titlebar label; the Debug preview.
   - App tests pin that Escape and Return leave the sheet up, that OK closes it, and that Buy has no
     key equivalent.
5. **Updates for a key whose period has ended.** Opens with a probe of Sparkle 2.9.4 against a local
   appcast, answering two questions:
   - Which hook holds back a background install? The candidate is
     `updater(_:shouldProceedWithUpdate:updateCheck:)`, throwing for `.updatesInBackground`.
   - How can a user-initiated install wait for the notice and then continue? For example, a one-shot
     allowance for that version, then re-running the check.

   The findings go into docs/NOTES.md before the wiring lands. An app test pins that a background
   check can't get past the hook.
6. **End to end, on a beta.** A beta cut with the switch on:
   - a key signed with the production key, activated from an email-style link;
   - the reminder after a faked 31 days, at launch and at the next day's first activation;
   - an uncovered update from a test feed, with its notice.

   Stable keeps the switch off until the store opens.

**Done when** a beta with the switch on:
- shows nothing for 30 days, then reminds;
- goes quiet the moment a real key is entered, pasted or by link;
- shows the notice before an uncovered update and never installs one silently;

and a self-built copy never reminds at all. Both suites green, both linters clean, every new string
translated.

#### Progress

**2026-09-29: Slices 1 and 2 landed** (core only; the app is untouched). One step is still Oleg's:
generating the production key pair (below).

- **Slice 1, the contract.** The signer is `tools/license` in the private repo: TypeScript on Node
  alone, with a `sign` command that never takes the private key as an argument. It generates
  **27 vectors** (5 valid, 22 refused) deterministically from a test key derived from a fixed
  phrase. They're committed here unchanged as `Fixtures/license-vectors.json`, and a test on the
  signer's side fails if its committed copy drifts from what the generator builds. Beyond the
  plan's list, the vectors pin every trap the probe found (docs/NOTES.md ▸ *License keys*): a
  non-canonical base64url spelling, a malleated signature (S + L), a byte-order mark, a boolean
  `v`, a byte that isn't UTF-8, an email-wrapped paste, and a `dnx2.` key.
- **What the slice decided, on top of the plan:**
  - The checks run in one order on both sides: whitespace removed, size (1024 UTF-8 bytes), prefix,
    shape and strict base64url, **the signature**, and only then the payload JSON. So no JSON parser
    ever sees bytes the store didn't sign.
  - The refusals have names both sides share (`LicenseKeyError`): `empty`, `tooLong`, `wrongPrefix`,
    `unsupportedVersion` (a `dnx2.` key, or a payload `v` above 1, which Slice 3 words as "needs a
    newer Dirnex"), `malformed`, `badSignature` and `invalidPayload`.
  - Key-pair halves are written `dnx1-public-…` and `dnx1-private-…`. `LicenseVerifier` takes only
    the public prefix, so pasting the private half into this repo fails at once instead of
    publishing it.
  - Dates in a key are 2000–9999 (NOTES.md says why there's a floor).
- **Slice 2, the core.** `LicenseKey` + `LicenseVerifier` (the vectors, a signature-skipping negative
  control, every one-character mutation of a key refused, hostile and random text),
  `LicenseDay` (UTC days compared without a `Date`, and `date(in:)` for display, which never shifts
  the day), `LicenseStatus` / `covers(releaseDay:)` (an off-by-one negative control),
  `LicenseReminderPolicy` (a grace-ignoring negative control) and `UpdateCoverageNotice`. Decided:
  - The 30 days are elapsed time from the first launch with the switch on. A start in the future is
    pulled back to now, so setting the clock back buys at most one more quiet period.
  - "Once a day" means a *different* local calendar day from the last showing, not a later one, so
    a clock set back doesn't silence it.
  - The notice shows only when the update would *start* the reminder: the key covers the running
    build and not the update. With no key, or a key that already doesn't cover the running build,
    the reminder is there either way. That generalizes the plan's "no key, no notice".
- **The production key pair** was generated by Oleg the same day, in his own terminal. The private
  half is in his password manager, and the public half is `LicenseVerifier.productionPublicKey`.

**2026-09-29: Slice 3 landed** (holding a key; nothing reminds yet).

- **Core:** `LicenseLinks` reads the key out of `dirnex://license?key=…` and out of a pasted
  `https://dirnex.app/activate#<key>` (wrapped across lines or not), and builds the buy and renew
  addresses (the renew one carries the license id and nothing else). `LicenseVerifier` carries the
  production and test public keys; a malformed constant would refuse every key rather than trap. The
  two commands (`app.license`, `app.buyLicense`) and `CommandCatalog.licensingCommandIDs`; the
  Application category moved to `CommandCatalogApplication.swift` when the pair took
  `CommandCatalogCategories.swift` past `file_length`.
- **App:** `LicensingSwitch`, `LicenseStore`, Settings ▸ License, the link handler with its
  confirmation, both commands in the App menu under Check for Updates… and in the palette, and the
  `dirnex` URL scheme in `Info.plist`. 29 catalog entries, all 14 languages.
- **Decided in the slice:**
  - **"Dormant" covers the surfaces too, not only the reminder.** The License tab, the two commands
    (menu bar, palette, Settings ▸ Shortcuts, AppleScript, Shortcuts) and the link handler exist
    only where `LicensingSwitch.isOn`: a build whose `Info.plist` has `DirnexLicensingEnabled` =
    `true` (Slice 4's release workflow writes it), or a Debug build. So stable shows no trace until
    the store opens, and the scheme, registered in every build, is ignored where the switch is off.
  - **Debug builds accept the test key as well as the production one** (Oleg, 2026-09-29), so the
    whole flow can be tried without the private key. Release builds accept production only. A key a
    Debug build kept is checked again at every launch, so a release build sharing the same
    preferences simply doesn't count it.
  - **`DirnexReleaseDate` is a UTC day, `YYYY-MM-DD`**, read now and written by Slice 4. Without it a
    build is undated, and every key covers an undated build.
  - **Buy a License… always opens the buy page.** Renewing lives in the License tab, since it needs
    the license id; it's offered for a key that still covers this build too (renewing early adds to
    the end), and made prominent once it doesn't.
  - Remove asks no confirmation: the key is still in the email.
- **Verified live** (2026-09-29, computer use). In the Debug build, in English and German:
  - the App menu order;
  - a refused paste;
  - an email-wrapped test key activating;
  - `dirnex://` links, with Cancel keeping the old key, Activate replacing it and naming both
    licenses, and a broken key refused with its reason;
  - Remove.

  A local Release build without the switch showed no License… or Buy a License…, only the four
  original Settings tabs, and ignored a license link without a word. The live run found one bug the
  tests could not: the key field had no visible placeholder (docs/NOTES.md ▸ AppKit).

### M30 — Report a Bug, and a Help menu to hold it (S)

**Planned 2026-09-29.** A way to tell Oleg something broke without a GitHub account. The report goes
to the store's server (`https://dirnex.app/api/bug-reports`, built in the private repo), which keeps
it and messages him. Apart from Sparkle's update check, it is the only thing in Dirnex that talks to
a server of ours. It sends only when the user presses Send, and only what the user was shown.

Decided before Slice 1:

- **A Help menu, finally.** M20 left adding one as its own decision; this takes it. It holds *Report
  a Bug…*, *Dirnex Website* and *Release Notes*, which is where every Mac user looks, and it brings
  macOS's menu search with it. `app.reportBug` is in the palette too.
- **What is sent.**
  - A description (required).
  - Steps to reproduce and a reply email (both optional; the email is remembered for next time).
  - Each behind its own checkbox, on by default: the Dirnex version and build, the macOS version,
    the Mac model, the UI language, and whether a license is present (never the key itself).
  - Optional and off by default: the newest Dirnex crash report from the last 7 days in
    `~/Library/Logs/DiagnosticReports`.

  The home folder is shortened to `~` everywhere.
- **Shown before it's sent.** *Show What Will Be Sent* opens the exact JSON body. File names and
  paths are personal data, so nothing reaches the payload that the user didn't type or tick.
- **When the server can't be reached,** the dialog keeps the text and offers *Copy Report* and *Email
  Instead* (a `mailto:` with the same body), rather than losing it.
- **Hidden until the endpoint exists.** The menu item and the command appear only when the build
  carries `DirnexBugReportURL` in `Info.plist`. The release workflow adds it once the server is
  live; until then the feature ships inert.

#### Slices

1. **The core** (additive).
   - `BugReport`: the payload and its redaction (home folder to `~`, a size cap, crash-report
     trimming).
   - Encoding to the server's JSON contract, which is defined in the private repo and mirrored here
     as a fixture.
   - Tests, including a negative control that leaves the home path in.
2. **The app.**
   - The Help menu, the command, the dialog, the preview, sending with a timeout, and the fallbacks.
   - A fake endpoint in `Tooling/` (the `fake-s3-endpoint.py` pattern) for the app tests to post to.
   - Translated into all 14 languages.
3. **Live.** Against the real endpoint once it exists (staging first), then in a beta with
   `DirnexBugReportURL` set.

**Done when:**
- a report sent from a beta arrives in the server's inbox with exactly what the preview showed;
- the same report with the network off survives as Copy or Email;
- a build without the URL shows no trace of the feature.

### Still open

Everything through M28 is shipped, and the record of it — the milestone checklists, the sixty
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
| M29: a paying customer meets the reminder after an update they didn't choose | The notice before any uncovered install, and no silent background install of one. Slice 5's probe decides the hook, and an app test pins that a background check cannot get past it |

## 7. Open questions

**None open.** M25's was the last, and it closed on 2026-08-29. Every question this plan asked since
M0, and how each one closed, is in [docs/HISTORY.md](docs/HISTORY.md) ▸ **The questions the plan
asked**.
