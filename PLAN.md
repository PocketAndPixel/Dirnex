# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: M0–M13 shipped (14 languages) · M14 (checksums + attributes) planned · Created: 2026-07-05 · Log: [docs/HISTORY.md](docs/HISTORY.md)

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
├── docs/                       (NOTES.md gotchas · HISTORY.md M0–M13 log · RELEASING.md)
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

### Shipped: M0 → M13 (2026-07-05 → 2026-07-29)

Every milestone through M13 is closed. The checklists and the full per-pass progress log —
what was probed, decided, and rejected — live in
**[docs/HISTORY.md](docs/HISTORY.md)**; source comments citing `PLAN.md §M5` and the like
refer to those sections.

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

### Next: M14 — Checksums and attributes (planned 2026-07-29)

Two features that have nothing to do with each other except that both are byte-touching and
both are things a Total Commander user reaches for and currently cannot: **compute and verify
checksum files**, and **see and change a file's attributes**. Core-first per §2, in five slices.

**Split/combine was considered and dropped (2026-07-29).** Every reason it exists is gone —
FAT32's 4 GB ceiling, floppy and CD spanning, mail attachment limits — and on macOS the answer
to "this file is too big" is a split archive or a link. It is also the *cheapest* of the three
to build (a chunked read/write loop, which `LocalBackend+Copy` already is), which is exactly why
it should not be built on cheapness alone: it would cost two permanent command slots and eight
languages to serve a problem nobody on this platform has. Revisit only on a real request, and if
it comes, it rides on Slice 1's digests — TC writes a `.crc` companion beside the parts and
verifies it on combine, so the checksum work is its missing half.

#### What was probed first (2026-07-29)

Both halves rest on measurements, not on recollection — §"Working rhythm". Three of the results
changed the design.

**Hash throughput**, 256 MiB of `/dev/urandom`, warm cache, `swift -O`, Apple Silicon:

| Algorithm | Throughput | Note |
|---|---|---|
| `Insecure.SHA1` | 2335 MiB/s | hardware instruction |
| `SHA256` | 2096–2310 MiB/s | hardware instruction |
| `Insecure.MD5` | 790 MiB/s | software — **3× slower than SHA-256** |
| CRC32, byte-at-a-time table | 534 MiB/s | software — **the slowest of the four** |

**The intuition that picks CRC32 or MD5 "because they're cheap" is inverted on this hardware.**
SHA-1 and SHA-256 are ARMv8 crypto instructions; MD5 and CRC32 are ordinary code. So SHA-256 is
the honest *default* — it is both the strongest and among the fastest, and the legacy three are
carried for **interop** (matching a checksum someone else published), never for speed. Chunk size
is irrelevant between 64 KiB and 4 MiB (measured within noise), so `ByteComparator`'s existing
128 KiB stands with no tuning. Computing all four in one pass costs ~247 MiB/s combined, which
makes "compute everything while the bytes are in hand" affordable and avoids ever re-reading a
file to add a second algorithm.

**Unprivileged attribute changes**, uid 501, on this Mac:

| Change | Own file | Someone else's |
|---|---|---|
| `chmod` mode bits | OK | EPERM |
| `chflags UF_IMMUTABLE` (Finder's "Locked") | OK | EPERM |
| `chflags UF_HIDDEN` | OK | EPERM |
| `chflags SF_IMMUTABLE` and the other `SF_*` | **EPERM** | EPERM |
| `chown` to another user | **EPERM** | EPERM |
| `chgrp` to a group I belong to | OK | EPERM |
| `chgrp` to a group I do not belong to | **EPERM** | EPERM |
| `utimes`, and `.creationDate` via `FileManager` | OK | EPERM |
| ACL read (`acl_get_file` → `acl_to_text`) | OK | OK |
| ACL write (`acl_set_file`) | OK | EPERM |
| `setxattr` / `removexattr` | OK | EPERM |

**So "the full version" is an ordinary in-app panel, unprivileged, for every file the user owns —
which is nearly everything a file manager touches.** Root is needed for exactly three things:
another user's files, `chown` across users, and the `SF_*` system flags. That is the finding that
decides the escalation design (Slice 5): escalation is a narrow exception, not the general path,
and building the panel around a privileged helper would have been building the whole feature
around its rarest case.

Two gotchas found in the same run, both destined for NOTES.md:

- **`chmod` fails with EPERM while `UF_IMMUTABLE` is set.** A panel that shows "Locked" and the
  mode bits together must clear the flag, apply the mode, then re-apply the flag — in that order.
  Without it, a user editing permissions on a locked file gets "Operation not permitted", which
  reads *exactly* like "you need to be root" and would send the whole design down an unnecessary
  privilege-escalation path. The failure is indistinguishable from the one case that genuinely
  needs root, which is what makes it expensive.
- **`chmod()` follows symlinks; `lchmod()` exists and does not.** Verified: `chmod` through a link
  changed the target (0600) and left the link (0755). The panel has to decide link-vs-target and
  say which it did. Recommendation: act on the link (`lchmod`/`lchflags`/`lutimes`), as Finder's
  Get Info does.

**ACLs from Swift** — the open question of whether "full" can include them. It can, mostly:

- The C API (`acl_get_file`, `acl_to_text`, `acl_from_text`, `acl_set_file`, `acl_get_entry`,
  `acl_free`) **imports and links from Swift with no module map and no bridging header**. Probed,
  not assumed — this is what makes ACLs affordable at all, and it is the opposite of §M4's
  libarchive result.
- `acl_get_file` returns `nil` with `errno == ENOENT` to mean *"this file has no ACL"*. That is a
  normal answer, not an error.
- The canonical text is `!#acl 1\nuser:<UUID>:<name>:<uid>:allow:read,write,delete`.
  `acl_to_text` resolves the name for you, and `acl_from_text` round-trips its own output.
- **But `acl_from_text` rejects the friendly form `chmod +a` accepts** (`user:oleg allow read` →
  EINVAL), because the canonical form embeds the GUID. Adding an entry for a user picked in the UI
  therefore needs `mbr_uid_to_uuid`, which is **present in libSystem** but declared in
  `membership.h`, outside the Darwin module map — so it needs a small module map or a `dlsym`
  declaration. Reading and removing need none of that; full editing is in scope (decided
  2026-07-29), so the declaration is Slice 3's.
- **Adding an ACL does not change the mode bits** (verified: still 0644 with an ACL present),
  which is precisely why a panel that shows mode alone makes a false claim about a file's
  permissions on exactly the files where it matters.
- **The rights are not one set — they depend on the item's kind**, taken from `chmod(1)` rather
  than from memory: 8 apply to everything (`delete · readattr · writeattr · readextattr ·
  writeextattr · readsecurity · writesecurity · chown`), 4 only to non-directories (`read ·
  write · append · execute`), 5 only to directories (`list · search · add_file ·
  add_subdirectory · delete_child`), and 4 inheritance flags only to directories (`file_inherit ·
  directory_inherit · limit_inherit · only_inherit`). **12 checkboxes for a file, 17 for a
  directory** — so the editor's matrix switches on kind, and a mixed multi-selection cannot
  present one matrix at all. That constraint has to shape the panel from the start, not be
  discovered when the first folder is selected.
- **Entries are ordered and evaluated in order, and the order is editable** (`chmod +a#` inserts
  at an index, `chmod -C` tests for canonical order). A deny placed after an allow means something
  different from the same pair reversed, so the editor presents a *list*, not a set, and must not
  silently reorder. **Inherited entries are their own class** with an "inherited" bit (`chmod -i`
  / `-I`) and must be shown as inherited and not casually edited in place.

**One last finding, and it kills a badge before it gets built:** `ls -l`'s trailing marker is
useless on modern macOS. `@` (extended attributes) and `+` (ACL) share one column and `@` wins, so
a file with an ACL shows `@` and never `+` — and it is moot anyway, because
**`com.apple.provenance` is present on essentially every file on this Mac** (verified across the
repo, `~`, and freshly created files; `xattr -c` does not keep it away). So "this file has
extended attributes" carries no information and must not become a row badge or a panel line — it
would light up on everything. The xattrs worth surfacing are named ones the user acts on
(`com.apple.quarantine` above all), with `com.apple.provenance` filtered out. NOTES.md already
half-knew this from the Trash work ("a trashed file's only xattr is `com.apple.provenance`"); the
general form is that it is on everything, not just trashed items.

**Checksum file formats**, captured from the real tools rather than remembered. macOS 26 ships
more than expected — `/sbin/md5sum`, `/sbin/sha1sum` and `/sbin/sha256sum` all exist (hardlinks of
one binary) alongside BSD `md5`, `shasum`, `openssl` and a Perl `/usr/bin/crc32`:

| Producer | Line |
|---|---|
| `shasum`, `md5sum` (GNU) | `<hex>␣␣<name>` |
| `shasum -b` (GNU binary) | `<hex>␣*<name>` |
| BSD `md5` | `MD5 (<name>) = <hex>` |
| `openssl dgst` | `SHA256(<name>)= <hex>` |
| `md5 -r` | `<hex>␣<name>` |
| `crc32`, `.sfv` | bare `<hex>`, and `<name>␣<hex>` with `;` comments |

**Apple's own tools cannot read each other**: `shasum -c` refuses the `openssl`/BSD form outright
("no properly formatted SHA checksum lines found"). So a tolerant parser is not gold-plating, it
is the actual user-facing advantage over the stock tools — Dirnex reads all six and writes GNU
style (now natively produced on macOS too), with `.sfv` for CRC32.

#### Slice 1 — checksum core (additive, app untouched)

- `ChecksumAlgorithm` — `crc32 · md5 · sha1 · sha256`, carrying display name, digest width and
  canonical file extension as data. SHA-256 is the default; the other three are labelled as
  interop formats and the UI must never imply MD5 or SHA-1 is a security property.
- `CRC32` — table-driven, with the published vector as its first test (`"123456789"` →
  `0xCBF43926`, already confirmed in the probe). No zlib dependency for one function. If its
  534 MiB/s ever matters, slice-by-8 or the ARMv8 `CRC32*` instructions are the escalation, but
  simple wins until measured otherwise.
- `ChecksumEngine` — `ByteComparator`'s shape exactly: chunked at 128 KiB, never a whole file in
  memory, cancellation polled between chunks, progress reported by the caller's callback, and the
  caller decides where it runs. Computes **N algorithms in one pass**.
- `ChecksumManifest` — parse and serialize. Parsing accepts all six forms above; serializing
  writes GNU style, or `.sfv` for CRC32. Round-trip tests per form, plus the awkward real cases:
  names with spaces, a BOM, CRLF, `;` comments, a missing trailing newline, and a mixed-algorithm
  file (refused, with the reason named).
- `ChecksumVerification` — pure: manifest × directory listing → per-entry `ok / mismatch /
  missing / unreadable / extra`. "Extra" matters — a manifest that omits a file is a different
  answer from one that fails it.

#### Slice 2 — checksum app

- Two commands, `file.checksumCreate` and `file.checksumVerify`. `Command.id` is a translation key
  and renaming one orphans its translations, so these names are final.
- **Verify is the primary half.** Most people never author a checksum file; they download one next
  to an ISO and want to know whether the bytes survived. The results surface is a per-entry
  pass/fail list, and the nearest existing shape is the Synchronize Directories diff table.
- Runs on `FileOperationQueue`, which means extending `FileOperation.Kind` beyond `.copy`/`.move`
  for the first time — plus its `QueueSnapshot` status strings and their translations. A 50 GB
  file is ~25 s of SHA-256 and ~100 s of CRC32, so progress and cancel are not optional; a modal
  sheet over that is the thing §1 forbids.
- **The dataless gate is mandatory.** NOTES.md: reading one byte of an evicted iCloud or streaming
  Drive file materializes it and blocks. `FileEntry.isDataless` already arrives on the `stat` the
  listing performs, so a "checksum this folder" that would silently download the user's cloud
  drive is preventable for free — and must say what it is about to do rather than start.
- **Remote backends have no server-side hashing.** Neither `sftp` nor `curl` can hash on the
  server, so a checksum over SFTP/FTP is a full download. Genuinely useful (M13 shipped with no
  way to confirm an upload arrived intact) but it has to be stated, not discovered.

#### Slice 3 — attributes core (additive, app untouched)

- `FileEntry` gains `ownerID`, `groupID` and `flags`. **This is free at the syscall level** — the
  listing already `stat`s and already reads `st_flags` for `isHidden` and `isDataless`; the values
  are in hand and thrown away. Five construction sites across the backends, and the compiler finds
  all of them.
- `FileAttributes` — the value type the panel edits: mode bits, BSD flags, owner/group, the three
  timestamps. Pure, `Equatable`, and diffable against what was read, so the applier changes only
  what the user actually touched.
- `AttributeChangePlan` — the *ordered* syscall sequence for a diff, which is where the immutable
  gotcha is encoded once and tested: unlock → apply → relock. Tests pin the ordering directly,
  because the bug it prevents is invisible in any dialog screenshot.
- `AccessControlList` — the full editable model (decided 2026-07-29): an **ordered list** of
  entries, each carrying subject (user or group, with its GUID), allow/deny, the kind-appropriate
  rights set, and whether it is inherited. Read via `acl_to_text` (which resolves names for
  free), written via `acl_from_text` on the canonical form, with `mbr_uid_to_uuid` declared for
  the subject picker. Order is preserved exactly — never silently canonicalized — and inherited
  entries are marked as such. The parse/serialize pair is the testable core; a captured real ACL
  from a real file is the fixture, per §"Working rhythm".
- The **rights set is a function of item kind** (12 for a file, 17 for a directory), so it is
  modelled as such rather than as one flat option set — the compiler then prevents offering
  `add_subdirectory` on a file.
- `AttributePrivilege` — pure, from the probed matrix: given an entry's owner and the requested
  diff, does this need root? It is what greys the panel and decides whether Slice 5 is reachable
  at all, and it is a table, so it is a test.

#### Slice 4 — attributes app

- A Get Info-style panel. Dirnex currently cannot answer "what are this file's permissions?" at
  all, so the *visibility* is most of the value — `FileEntry.permissions` has been read on every
  listing since M1 and displayed nowhere.
- Multi-selection applies a diff, not a value, so a mixed field stays mixed unless touched.
- **The ACL editor is a list, not a checkbox grid**: entries in evaluation order, add / remove /
  reorder, allow-vs-deny per entry, inherited entries visibly distinct and not casually edited,
  and the rights matrix switching between the 12-right file form and the 17-right directory form.
  A mixed file+directory selection cannot show one matrix, so it offers the 8 common rights or
  nothing — decided up front rather than found later.
- The subject picker resolves a user or group to its GUID through `mbr_uid_to_uuid`. macOS spells
  ACL subjects by GUID, so the picker is the only place a name is turned into an identity, and
  it is worth one place.
- Extended attributes are listed with `com.apple.provenance` filtered out (it is on everything);
  `com.apple.quarantine` is the one worth acting on, and removing it is the case a user actually
  has — NOTES.md already records that `xattr -dr` is the form that exits 0.
- Recursive apply is a queued, cancellable operation and lands **after** the flat case. It is the
  one shape here that can wreck a tree, and undo needs the prior mode/flags/ACL journaled per path.
- Undo: a new `UndoActionLabel` case (the enum is closed, so this is a compile error until it is
  added — as designed in M12 Slice 10) plus its translation key.
- Lives in `PanelViewController+Attributes.swift`; the controller is at the lint ceiling. The ACL
  editor is its own controller from the start — on the M12 Slice 8 evidence that a panel this
  dense arrives at all three SwiftLint ceilings at once, and on the §"Lint ceilings" rule that a
  type at the ceiling splits by *concept*.

#### Slice 5 — the narrow privileged case

Only for what the matrix says needs root: another user's file, `chown` across users, `SF_*`.
Three options were weighed:

1. **`SMAppService` privileged daemon + XPC** — Apple's modern answer, and the wrong one *here*:
   it requires a Team-ID-signed bundle, so per NOTES.md's App Intents lesson every local build
   would be unable to run it and every local verification would be blind. A high price for the
   rarest case in the feature.
2. **`osascript` → `do shell script … with administrator privileges`** — the standard system
   authorization dialog, runs as root, stays in the app, needs no entitlement and works under
   ad-hoc signing. Not sandbox-legal, which §2 already settled by not sandboxing.
3. **Terminal handoff** — a pre-filled command line the user runs themselves.

**Decided 2026-07-29 (Oleg): (2) as the in-app path, with (3) always present beside it as a
read-only "or run it yourself" field.** (3) is nearly free, is the honest escape hatch for a user
who would rather not hand an app their admin password, and is the safest half to build first —
so it ships first and (2) is layered on. Note that `ExternalTerminal.invocation` opens a terminal
*at a directory* via `open -a` and types nothing, so delivering a pre-filled command line is new
machinery (Terminal.app's AppleScript `do script`); the existing launcher does not cover it.

Two constraints on (2) that follow from the probe rather than from taste. The escalation is
offered **only** where `AttributePrivilege` says root is actually required — never as a blanket
"try again as admin", because the matrix shows that is the rare case and a panel that reaches for
authentication by default trains the user to approve it. And the immutable-flag gotcha must be
fixed *before* this slice, not worked around by it: an EPERM from a locked file is
indistinguishable from an EPERM that needs root, so shipping (2) first would paper over the bug
with a password prompt the user never needed.

**Both (2) and (3) build a shell command out of file paths, which is an injection surface, not a
formatting concern** — the same lesson as FTP's `-Q` and the Google `doc_id`. The command is
composed in the core through the existing `ShellQuoting`, tested against names with quotes,
spaces, newlines and leading dashes, and never interpolated at the call site.

#### Exit criteria

- A checksum file written by Dirnex verifies with `shasum -c`, and files written by `shasum`,
  `md5`, `openssl` and an `.sfv` tool all verify in Dirnex — the interop claim tested in both
  directions, against the real tools.
- Verifying a folder containing an evicted iCloud file does not download it without saying so.
- The attributes panel round-trips against the OS as the independent judge: set it in Dirnex,
  read it back with `ls -le@` and `stat -f`, and set it with `chmod`/`chflags` and see the panel
  agree.
- Changing permissions on a **locked** file works, in one gesture, with no root prompt.
- A file carrying an ACL never displays its mode bits without saying an ACL is present.
- An ACL authored in Dirnex reads back correctly under `ls -le` **in the order Dirnex showed**,
  and an ACL authored with `chmod +a` / `+a#` displays in Dirnex in the same order — the OS as
  the independent judge in both directions, entry order included, since order is meaning here.
- The root-only cases are reachable two ways and neither is the default: the authenticate path
  and the copyable command produce the same result on the same file.

**Localization:** M12's rhythm was to fill the translations in the same slice rather than accumulate
English-only surface, and M14 assumes that — each slice ships its own catalog keys. The bill is now
**13 columns, not one** (M12 closed with 14 languages), and `LocalizationCoverageTests` fails on an
untranslated command in any of them, so this is enforced, not intended.

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
| Full Disk Access friction kills onboarding | Dedicated flow in M7; app degrades gracefully (browse home dir) before grant |
| Scope creep before the feel is right | M1 exit criteria are the gate; nothing from M3+ starts until M1 feels great |
| A system-CLI quirk changes under us (M13's TLS-1.2 pin for FTPS is a workaround for `curl` 8.7.1, not a property of the protocol) | The flag lives in a pure, tested `FTPProcessArguments` with the reason in its doc comment, so it is one place to re-measure — and a listing that comes back empty is the *symptom*, so an FTPS smoke test asserts non-empty rather than merely "no error" |

## 7. Open questions

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
