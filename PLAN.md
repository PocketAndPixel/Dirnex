# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: M0–M13 shipped (14 languages) · M14 (checksums + attributes) in progress — Slices 1–4 landed; Slice 5 (privilege escalation) landed for the single-item flat case (the escalation command, both surfaces, non-owned editing), with multi-selection and recursive escalation deferred · Created: 2026-07-05 · Log: [docs/HISTORY.md](docs/HISTORY.md)

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

**Slice 1 landed (2026-07-30), as designed, plus three things the probe changed.** Seven core
files (`ChecksumAlgorithm`, `CRC32`, `ChecksumError`, `ChecksumEngine`, `ChecksumManifest`,
`ChecksumManifestParser`, `ChecksumVerification`), 73 tests, app untouched.

- **The interop claim is proven live in both directions, which is the exit criterion.** A harness
  compiled against the real core read 11 manifests written by the actual tools on this Mac —
  `shasum` (text, binary, SHA-1), `/sbin/sha256sum`, `/sbin/md5sum`, BSD `md5`, `md5 -r`,
  `openssl dgst` (SHA-256 and MD5), an `.sfv`, and a UTF-8-BOM + CRLF Windows-shaped file — and
  verified every one against the real bytes. Going the other way, `shasum -c`, `/sbin/sha256sum -c`
  and `/sbin/md5sum -c` all verify what Dirnex writes, and `shasum -c` correctly fails it after one
  byte is changed.
- **Escaping is narrower than planned, because the two checkers Apple ships disagree.** `shasum`
  escapes a name containing a backslash (leading `\` on the line, `\\` inside) and Apple's
  `/sbin/sha256sum` writes it raw — and the raw form is read correctly by *both*, while the escaped
  form makes `/sbin/sha256sum -c` skip the line ("improperly formatted") and silently check one file
  fewer. So Dirnex escapes only a name containing a **newline**, which has no raw form at all. Read
  side stays tolerant of both. Details in NOTES.md.
- **The dataless gate is in the core, not deferred to Slice 2.** `ChecksumEngine` already `stat`s
  for the regular-file check, so `SF_DATALESS` is free in the same call; a placeholder throws
  `wouldDownloadPlaceholder` unless the caller passes `allowDataless`, which is the app's cue to ask
  first. Putting it at the byte-touching layer is what makes it unforgettable.
- Measured on the real engine over 256 MiB, reproducing the probe: SHA-256 2245 MiB/s, SHA-1 2287,
  MD5 778, CRC32 550, **all four in one pass 274** — so the accumulator adds no per-chunk cost, and
  "compute everything while the bytes are in hand" stands.
- `ChecksumError` is a named vocabulary with a stable `key` (`LocalizationKey.checksumError(_:)`),
  not a `String` payload — the M12 Slice 11 lesson applied ahead of the display site. Its catalog
  entries and coverage test are **Slice 2's**, since the core ships no resources.

**Follow-on (2026-07-30): `ByteComparator` gated the same way, which settles the policy Slice 2
inherits.** NOTES.md named byte-compare among the sweeps that must check `SF_DATALESS`, and it was
the one that did not — `FileManager.attributesOfItem` **cannot see `st_flags` at all** (probed: 19
keys, no flags among them), so the check could not have been added without moving to a raw `stat`,
exactly as `ChecksumEngine` had. Now one `lstat` answers regular-file, size and dataless together,
and `allowDataless` is the same escape hatch under the same name.

- **The policy, and it is the one Slice 2 should copy: pointed-at file downloads, tree sweep
  refuses.** Compare By Contents fetches both sides through the shipped `CloudDownloadPrompt` — the
  same answer Enter and F4 already give the same request — while `DirectorySync`'s `.content` scan
  stops and names the first placeholder rather than pulling a folder nobody pointed at. So checksum
  *one selected file* asks and proceeds; *verify a manifest over a tree* refuses.
- **The gate sits immediately before the first read, not at the top.** A placeholder carries its
  real size, so a size mismatch, two empty files and `prescan`'s `tooLargeToScan` stay free correct
  answers; refusing them would abort a content sync over pairs already classified. `ChecksumEngine`
  guards at the top because it has no free answer — the two are consistent, not divergent.
- **The app half is a second, separate hole**: catching the refusal and then handing the pair to
  FileMerge just moves the blocking read into FileMerge. The materialize therefore sits at the
  launch, covering the outcomes that reach a tool without the comparator having read a byte.
- **`SF_DATALESS` cannot be produced in a test** — `chflags` reports success and the kernel drops it
  — which is why Slice 1's guard shipped uncovered. The comparator splits at the syscall
  (`ComparisonSubject`) so every rule is tested, and one live run against a real evicted iCloud file
  proved the syscall half: it refused, named the file, and left it **still dataless**. Worth
  retrofitting to `ChecksumEngine` in Slice 2.
- `VFSUnsupportedReason.contentComparisonWouldDownload(name:)` carries the sentence, translated in
  all 14 languages, so `LocalizationCoverageTests` covers it now rather than in Slice 2 — the
  comparator's errors were already in the `VFSError` vocabulary the app renders.

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

**Slice 2 landed (2026-07-30), as designed, and both exit criteria are met live.** Core: the pure
`ChecksumScope` (walk/scope rules, its own tests) and the queued `ChecksumRunner` in `CopyEngine`'s
shape, split into `ChecksumCreateRun` / `ChecksumVerifyRun` / `ChecksumRunContext` at the lint
ceiling by concept, not by shaving. `FileOperation.Kind` grew its first case beyond `.copy`/`.move`
(a `.checksum` kind carrying the report payload, with its `QueueSnapshot` status strings). App: the
two commands in File as *Create Checksum File…* and *Verify Checksums…*, the report sheet modelled
on the Sync diff table, and 40 extracted literals + the registry and `ChecksumError` keys across all
13 languages, with `LocalizationErrorCoverageTests` added. 1319 core tests, both suites green, both
linters clean.

- **The interop exit criterion is now proven through the UI, not just a harness.** Driving the real
  app: *Create Checksum File…* over a folder wrote a `sub.sha256` that is **byte-identical** to
  `shasum -a 256` and passes `shasum -c` ("OK"), with the entry spelled `sub/gamma.txt` relative to
  the manifest's own directory. The Slice-1 harness had proven the bytes; this proves the button.
- **The report has four verdicts and each was forced live.** `verified` → green "Everything checks
  out"; `mismatch` → red ✗ "Doesn't match — expected <hex>…" (the *expected* digest, from the
  manifest); `missing` → amber ? "Not in this folder"; and an *unlisted* file present on disk but
  absent from the manifest → grey + "Here, but not in the checksum file", with directories and the
  manifest file itself correctly excluded from that scan. The header flips red the moment any entry
  fails or goes missing; extras alone keep it green, since an unlisted file is an FYI, not a failure.
- **Verify's menu item gates on a manifest being the cursor row**, greyed otherwise — validated
  live by watching it enable only once `sub.sha256` was selected.
- **The dataless gate was retrofitted to the runner** (the Slice-1 follow-on's "worth doing in Slice
  2"), so a verify over a tree refuses the first placeholder and a pointed-at file asks — the
  `ByteComparator` policy, unchanged. Confirmed last pass against a real evicted iCloud file:
  reported `notDownloaded`, verdict false, file **still dataless** — no bytes fetched.

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

**Slice 3 landed (2026-07-30), as designed, plus what a fresh probe changed.** Twelve core files —
the pure models (`POSIXPermissions`, `BSDFileFlags`, `FileAttributes`+`AttributeDiff`,
`AttributeChangePlan`, `AttributePrivilege`, `AccessControlRight`, `AccessControlEntry`,
`AccessControlList`) and the metadata-touching I/O behind them (`FileAttributeIO`,
`AccessControlListIO`, `ACLIdentity`) — plus the `FileEntry` fields. ~55 new tests (1373 core total),
both suites green, both linters clean, app untouched but rebuilt to confirm the additive `FileEntry`
change compiles.

- **The ACL C API was probed live first, and three findings reshaped the model** (all now in
  NOTES.md). `acl_to_text` **wraps lines** at ~column 60 with a trailing `\`, so the parser un-wraps
  before splitting. `acl_to_text` and `ls -le` **disagree on token names**: four rights are aliased
  bits the kernel prints with their file names even on a directory (`list`≡`read`, `add_file`≡`write`,
  `search`≡`execute`, `add_subdirectory`≡`append`), so the parser only ever sees
  `read/write/execute/append` and the model is the **13 canonical bits**, not `chmod(1)`'s 17 input
  tokens — the "17 for a directory" is 13 rights relabelled per kind + 4 inheritance flags. And the
  canonical form `acl_from_text` accepts needs **GUID + name + numeric id**, all three.
- **Order is proven live in both directions, which is the exit criterion.** An ACL Dirnex writes
  reads back — through `acl_get_file` *and* `ls -le` — with deny-before-allow in the order written;
  `acl_set_file` preserves entry order and re-canonicalizes only the rights within an entry. Unknown
  tokens are kept verbatim, so writing an ACL back never strips a right a later macOS adds.
- **The locked-file exit criterion is met live.** `AttributeChangePlan` encodes unlock → apply →
  relock as a pure, ordering-tested value, and `FileAttributeIO` applied it to a real
  `UF_IMMUTABLE` file: the mode changed in one gesture, unprivileged, and the file stayed locked.
  `chown`-before-`chmod` is encoded and tested for the same "invisible in a screenshot" reason.
- **`AttributePrivilege` is the probe matrix as a table**, and `ACLIdentity` resolves uid/gid → GUID
  through a `dlsym`'d `mbr_*` (no module map, so no ripple into the app build), pinned against the
  GUID the OS itself writes into an ACL. Two fixtures are **real** captures — a file's ACL and a
  directory's, wrapping and inheritance flags included.

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

**Slice 4 opens core-first (2026-07-31), because two things the panel needs did not exist yet.** The
xattr list and the ACL subject picker are both byte/metadata-touching, so per §2 they land as tested
core before any AppKit. Three files — `ExtendedAttribute` (the pure value model and its display
classification), `ExtendedAttributeIO` (the syscalls), `IdentityDirectory` (+ the pure
`IdentityRoster`) — plus `ACLIdentity.subject(for:kind:)`. 29 new tests (1403 core total), both
suites green, both linters clean, app untouched.

- **Two probe findings reshaped the identity half before it was written**, both invisible until
  measured (details in NOTES.md). `getpwent`/`getgrent` return **every record twice** — 322 raw group
  records for 161 real groups — so the enumerator de-duplicates on the whole record, and `dscl . list`
  independently reporting exactly 161 is the OS agreeing, which is what the test asserts against. And
  the service-account filter has to be the **leading underscore, not a numeric floor**: after
  de-duplication that leaves 4 users and 34 groups including `wheel`(0), `everyone`(12), `staff`(20)
  and `admin`(80) — the exact groups an ACL names, all four of which a `gid >= 500` rule would hide.
- **`mbr_uid_to_uuid` cannot validate a picker's input**, which is a trap for the code Slice 4 is
  about to write: it *synthesizes* a GUID for an id with no account (uid 31337 answers
  `FFFFEEEE-…-AAAA00007A69`), so a non-`nil` GUID proves nothing and the ACL would be written naming
  nobody. `IdentityDirectory.userName(for:)` is the call that actually answers, and a test pins the
  asymmetry so nobody later reaches for the GUID.
- **Every xattr call takes `XATTR_NOFOLLOW`**, matching the `l*` syscalls the rest of the attributes
  machinery uses — probed on a real symlink, following returned the *target's* attributes, so a panel
  that followed would list and delete the wrong file's. `removexattr`'s `ENOATTR` is swallowed, which
  is the `xattr -d` vs `xattr -dr` lesson at the syscall: a multi-selection "Remove Quarantine" must
  not fail on the files that were already clean.
- **Values are classified by inspection, not by name**, because one ordinary download carries all
  three shapes at once — UTF-8 (`quarantine`), a binary plist (`kMDItemWhereFroms`) and opaque bytes
  (`macl`, `provenance`). The sharp edge: a UTF-8 decode alone is not the text test, since the real
  11-byte `provenance` value decodes cleanly and would put control characters on screen.
- The stock tools are the independent judge on both halves: a test reads back what Dirnex wrote with
  `/usr/bin/xattr -p`, and the roster count is checked against `dscl`.

**The read-only panel landed (2026-07-31), and it is verified against the OS in every tab.** Decided
with Oleg up front: a **sheet** (matching Sync, Multi-Rename and the checksum report — every dense
dialog here is one) and **display before editing**, since PLAN.md already argued the visibility is
most of the value and it makes the whole surface checkable before any write path exists. Eight app
files — `AttributesSnapshot`, `AttributesController` + its General/Permissions tabs,
`AttributeFormatting`, `AttributeRow`, the two table controllers, and
`PanelViewController+Attributes` — plus the `file.attributes` command (**Get Info**, ⌘I) and 69
catalog keys across all 14 languages.

- **Four tabs, because the panel is dense enough that one scroll buries the ACL** — General
  (location, the three timestamps), Permissions (owner, group, the mode grid, flags), Sharing (the
  ordered ACL), Attributes (xattrs). The split also keeps each tab's construction in its own file
  under the SwiftLint ceilings, and each table has its own controller object — the ACL's is the one
  the editor grows from, as this slice required from the start.
- **The OS was the independent judge on a fixture built to exercise every row at once** (setuid +
  a group-denied ACL + an allow ACL + quarantine + `UF_HIDDEN`, a directory with inheritance flags,
  and a symlink). Against `ls -le@` and `stat -f`: owner `oleg (501)`, group `wheel (0)`, mode
  `rwsr-x--- (4750)` — the panel shows the setuid digit `stat -f %Lp` truncates — `set-user-ID`,
  Hidden checked, quarantine 30 bytes exactly.
- **The ACL exit criterion is met in the order that matters.** `ls -le`'s `0: group:staff deny
  delete` / `1: group:everyone allow read,readattr` renders as rows 1 and 2 in that order, deny in
  red. On the directory, `list,search,file_inherit,directory_inherit` renders as "List, Traverse —
  files inherit, folders inherit", so the four aliased bits are relabelled per kind exactly as
  `ls -le` spells them.
- **The mode-vs-ACL criterion is met too**: whenever an ACL is present the Permissions tab says so
  in orange and points at the Sharing tab, because an ACL does not change the mode and the nine
  `rwx` bits alone are a false claim on precisely the files where it matters.
- **The `l*` path is proven end to end by the symlink**: the link shows its own `rwxr-xr-x (755)`
  and *no* ACL, while its target shows `rwsr-x--- (4750)` and two entries. Everything reads through
  `lstat`/`XATTR_NOFOLLOW`/`acl_get_link_np`, and the tab says so in words.
- **One real bug was found only by looking**, and it is in NOTES.md as the general lesson: an
  `NSStackView` too small for its rows *compresses* them rather than overflowing, which crushed the
  first flag row until "Locked" overlapped "Hidden" and its checkbox vanished — a missing row in a
  permissions panel, with nothing logged. Fixed by letting each form tab scroll, which is also what
  keeps a longer translation from reintroducing it.

**Mode-and-flags editing landed (2026-07-31), with undo, and round-tripped live against the OS.**
The Permissions tab's twelve mode checkboxes (the nine `rwx` bits plus set-uid/gid/sticky) and the
`UF_*` flag checkboxes are now live for the item's owner, committed on **Save** as one gesture —
Oleg's chosen model, and the one the diff-based core already assumed. `AttributeDiff` → the ordered
`AttributeChangePlan` → `FileAttributeIO` were already tested from Slice 3; this pass added the two
missing halves — the app wiring and *undo* — and nothing else touches bytes.

- **Undo is a new core `UndoStep.restoreAttributes` + `UndoActionLabel.changeAttributes`, tested and
  translated in all 14 languages.** The step carries the changed fields as a pair of inverse
  `AttributeDiff`s (old-for-undo, new-for-redo) so `inverse` is a plain swap, and it re-reads the
  item's *current* attributes at revert time to rebuild the plan — because the unlock/relock
  sequencing depends on what is on disk now, not on what it was. It executes straight through
  `FileAttributeIO`, not the `VFSBackend`, matching where attribute I/O lives; `AttributeDiff`,
  `POSIXPermissions` and `BSDFileFlags` gained `Codable` so it persists in the journal like any file
  op. Six new tests (1409 core), and `UndoJournal` split its attribute corner into
  `UndoJournal+Attributes.swift` to stay under the 500-line ceiling.
- **The OS was the independent judge on every claim, live.** Editing `f.txt` to `rwxr--r--` and
  Hidden in one Save gave `stat -f` exactly `mode=744 flags=hidden` (a `chmod` and a `chflags` in one
  plan); the pane re-listed and the now-hidden file dropped from view; **Undo Change Attributes**
  restored `644 flags=-`. The **locked-file exit criterion is met in the app**: changing the mode of a
  `uchg` file left it `mode=744 flags=uchg` in one gesture, no root prompt — the unlock → chmod →
  relock the plan encodes, end to end.
- **Privilege gating is display + a Save-time guard, not a promise it can't keep.** A file the user
  does not own shows the same grid disabled with a note and a Done-only footer (verified on a
  root-owned `/etc` symlink); the narrow root-only case an owner can still reach — a system-immutable
  file — is refused at Save with a stated reason rather than the bare `EPERM` it is indistinguishable
  from, which is exactly the seam Slice 5's escalation slots into.

**Owner, group and the three dates landed (2026-07-31), and the probe changed the core twice before
any AppKit was written.** Decided with Oleg: **offer only what works.** `chown` to another user is
`EPERM` even on your own file (re-measured), so Owner stays a stated fact with a note — this panel's
own precedent, since the `SF_*` flags are a note rather than a checkbox for the same reason — while
Group becomes a popup of `IdentityRoster.selectableGroups`, the groups the caller belongs to plus
whatever the item is in now. All three dates are editable, through the plan that was already tested.

- **Two syscall side effects were found by probing and are now repair *steps* in
  `AttributeChangePlan`, not just orderings.** A plain `chgrp` is a `chown`, so it clears set-uid and
  set-gid — and the shipped chown-before-chmod rule does **not** cover a group-only edit, because with
  no mode change in the diff there is no `chmod` to order (`0o6755` staff → admin came back `0o755`).
  And setting an mtime earlier than the birth time drags the birth time back with it, on files and
  directories alike, so "change Modified" quietly changed "Created". Both break the contract the whole
  diff-based design rests on — a field left alone is never written — so the plan puts each back. Nine
  new plan tests plus three live ones, including a **negative control** asserting the OS really does
  the damage, so a macOS that stopped would not leave the repairs vestigial and green.
- **The OS was the judge on both, live in the app.** A `wheel` file moved to `staff` read back
  `-rwsr-xr-x gid=20` — the set-uid survived — and `dates.txt` given a 2001 modification date kept
  `birth = 2026-07-31` while `mtime` went to 2001, with the access date untouched. ⌘Z restored the
  date exactly.
- **One real bug was found only by undoing, and it is the slice's lesson.** The group rule makes a
  change reversible in one direction only: moving a file *out of* a group you are not in is legal and
  moving it *back* is `EPERM`. Shipped, the undo surfaced the generic errno — *"Dirnex may need Full
  Disk Access"* — true of the errno, wrong about the cause, and pointing at a settings pane that
  cannot help. `UndoJournal.restoreAttributes` now asks `AttributePrivilege` first and names the
  reason (`VFSUnsupportedReason.attributeRestoreNeedsAdministrator`, translated in all 14 languages),
  refusing before it touches the file. Same "an EPERM that needs root is indistinguishable from one
  that does not" trap as the immutable flag, arriving from the other direction.
- **The one trap on the AppKit side is the control, not the syscalls.** `NSDatePicker` resolves to
  whole seconds and a real `st_mtime` does not, so reading `dateValue` back unconditionally makes all
  three fields differ the instant the sheet opens — Save enabled with nothing edited, and a `utimes`
  on commit for three dates nobody touched. `DateField.initial` holds what the control was *given*,
  which is what makes "untouched" mean untouched at the control's granularity. Verified live: the
  sheet opens with Save greyed.
- The root-only alert now builds its sentence from the reason the core gave rather than assuming the
  system-flag case — four whole sentences, not one frame with a clause spliced in, because a clause's
  grammar depends on the sentence around it. That is the seam Slice 5 escalates from.

**The ACL editor and its subject picker landed (2026-07-31), and the probe found two live bugs in
shipped core before any AppKit was written.** The Sharing tab is now a master–detail editor: the
ordered list with add / remove / move-up / move-down, and the selected entry's subject, allow-vs-deny
and rights matrix below it. Four core changes (parser tolerance, `AccessControlList.moving(from:to:)`
+ `Codable`, the ACL as an `AttributeChangePlan` **step**, and the `UndoStep
.restoreAccessControlList` half of the same record), three new app files, 12 catalog keys in all 14
languages. 1449 core tests and 161 app tests green, both linters clean.

- **`acl_to_text` writes two shapes the shipped strict six-field parse rejected, and both made the
  panel claim a file had no ACL when it had one.** A rights-less entry has **five** fields —
  `acl_to_text` omits the trailing field rather than writing it empty — and a subject whose GUID
  answers to no account comes back with an empty name *and* empty id (`user:GUID:::allow:read`,
  which `ls -le` shows as the bare GUID). `AccessControlList.parse` threw on both, and
  `AttributesSnapshot` degrades a failed ACL read to an empty list, so the tab said "No access
  control list" — wrong in the quiet direction, on the one tab whose job is that answer. Both are
  accepted back by `acl_from_text`, so `ACLSubject.numericID` became optional and both now round-trip
  losslessly, which is what keeps an edit to a *neighbouring* entry from rewriting them.
- **`acl_set_file` is `EPERM` on a `UF_IMMUTABLE` file exactly as `chmod` is**, so the ACL is a step
  *inside* the existing unlock → apply → relock window rather than a second write beside it. The two
  halves are otherwise independent — `chmod`/`chgrp`/`utimes` each leave an ACL intact and in order,
  and `acl_set` leaves mode and times untouched — so this needed sequencing and, unlike the ownership
  and mtime side effects, no repair step. Proven live: an ACL written to a locked file in one
  gesture, unprivileged, still `uchg` afterwards.
- **The exit criterion is met in both directions, live.** An ACL authored in Dirnex (`oleg deny
  delete` then `oleg allow read`) reads back under `ls -le` as `0: deny` / `1: allow` — the order
  shown — with the mode untouched at 644; moving the allow above the deny and saving flips the OS's
  order to match. ⌘Z restores the previous list whole (order included) and a second ⌘Z removes the
  ACL entirely, since the file had none — the empty list is a state to restore, not a missing value,
  which is why the step carries **whole lists** rather than a diff.
- **An entry with no rights is a real state that decides nothing**, and the probe is what showed it:
  `acl_from_text` accepts an empty rights field and `ls -le` shows `0: group:staff allow`. The editor
  displays such an entry ("Nothing — this entry has no effect") and refuses to write one — Save stays
  greyed even though the list changed, verified live.
- **Inherited entries are shown exactly as they apply and not edited in place** — greyed row, subject
  and rights disabled, a note explaining where they came from, and **remove** still available, since
  dropping an inherited entry from this item is the user's call. Writing a list back preserves the
  `inherited` marker verbatim (probed), so editing a neighbour never silently forks one from its
  parent.
- **The rights matrix was laid out from a measurement, not from the English.** Three columns need
  506 pt against 410 — English itself clipped "Execute" — and two columns in 410 overflow Russian at
  436 while Polish, Dutch and Ukrainian clear by 4 pt. Dropping the `AttributeRow` label column for
  the two grids buys the full 548, where the worst language has 112 pt spare; the same run caught the
  inheritance row overflowing at **589 pt in Ukrainian** against English's comfortable 486. Details
  in NOTES.md — the general form is that a grid is not a form row.

**Multi-selection landed (2026-07-31), and it round-tripped live against the OS.** Marking several
items and pressing ⌘I now opens a bulk sheet — General (a common "Where", the three dates gated by a
per-date **Change** box) and Permissions (tri-state mode/special bits, BSD flags, and a group popup).
Decided with Oleg: **mode + flags + group + dates**, owner read-only (`chown` is `EPERM`), and ACLs
and xattrs left out — an ordered, kind-dependent list has no meaningful "apply a diff to N items", so
the panel says so and points at editing those one at a time.

- **The one new core piece is `AttributePatch`, and it exists because a bulk edit is a *patch*, not
  a value.** Two selected files that disagree on a bit must keep disagreeing on it unless the user
  touches that bit, which a whole-value `AttributeDiff` cannot express — it would carry one file's
  bit onto the other. The patch is a mask + values over the mode word and set/clear sets for the
  flags; `diff(against:)` turns it into that item's own `AttributeDiff`, after which the tested
  `AttributeChangePlan` / `FileAttributeIO` / privilege / undo path all run unchanged, once per item.
  15 new tests, including the "forcing one bit leaves an untouched, differing bit at each item's own
  value" property proven against real files, and a batch `UndoRecord` (one step per item, the
  Multi-Rename precedent) reversed live in one Cmd+Z.
- **The controls are tri-state and that is the whole UX.** A checkbox the items agree on shows on/off;
  one they disagree on shows the mixed dash and *means "leave each item alone"*. Only a control moved
  off its starting state is written — `allowsMixedState` is on only for a box that starts mixed, so an
  agreed box toggles cleanly while a disagreeing one cycles through mixed. The app-side mapping (the
  place this could go wrong) is pinned by `MultiAttributesControllerTests`.
- **The OS was the judge, live.** Two files at `0600` and `0644`, marked; forcing owner-execute (a
  unanimous bit) and group-read (a mixed one) on both while leaving everyone-read *mixed* gave `0740`
  and `0744` — each file kept its own other-read bit, the mixed-stays-mixed property end to end — and
  one ⌘Z restored `0600` / `0644`. Both tabs rendered without the `NSStackView`-compression trap the
  single-item Permissions tab hit (it scrolls, and every row was present).
- **The group popup offers only the caller's own groups plus "Leave unchanged", never a per-item
  current group** the way the single-item picker does: there is no single current group across a
  selection, and offering one the caller is not in would only `EPERM` on the items not already in it.
  Privilege is pre-flighted across the whole set, so a system-immutable item among the selection
  refuses the batch by name before anything is touched.

**The recursive apply landed (2026-08-01), and the probe decided its shape before any Swift was
written.** "Apply to enclosed items" now sits in the footer of both Get Info sheets whenever a folder
is involved, with a Total Commander-style scope popup beside it (files and folders / files only /
folders only); Save then hands a `.attributes` job to `FileOperationQueue` instead of writing flat, so
one gesture covers the item on screen and everything under it, with one determinate bar, one cancel
button and one ⌘Z. Decided with Oleg: **the scope popup, a 10 000-item undo cap with the tree counted
up front, and the ACL propagating too.** Six core files, five app files, 18 catalog keys plus two
`VFSUnsupportedReason` sentences in all 14 languages. 1513 core tests and 169 app tests green, both
linters clean.

- **Post-order is not a preference — it is the only order that finishes, and gathering the paths
  first does not save it.** `chmod -R 0644` over a tree is the live demonstration, done by the
  *system tool*: it leaves the root `drw-r--r--`, after which `ls` and `find` both fail. The trap is
  one step deeper than it looks — with the child list already in hand, applying to the parent and
  then to each child gave "Permission denied" on **every one of them**, because the failure is in
  path resolution at apply time, not in the walk. So the run gathers while the tree is still
  readable and writes from the leaves up. `AttributeApplyRunnerTests.locksItselfOutWithoutPostOrder`
  is the one test a pre-order implementation fails, and it passes every other test in the suite.
- **The journal is the only thing that cannot scale, and the numbers set the cap.** Measured over
  1k…200k steps: an `UndoStep.restoreAttributes` encodes to a dead-constant **246 bytes**, and the
  journal is JSON in `UserDefaults` re-encoded on *every* later operation — 10k steps is 2.3 MB and
  60 ms, 50k is 11.7 MB and 280 ms, 200k is 47 MB and **1.1 s**, permanently, until it falls off the
  50-record stack. The work itself is nothing by comparison: read + plan + apply is **17 µs an item**
  (100k items ≈ 1.7 s) and a 5 000-entry listing takes 16 ms. Hence a cap rather than a hope, and
  over it the run journals **nothing** rather than an arbitrary first slice — reverting part of a
  tree leaves it in a state nobody can reason about. The confirmation sheet counts with the run's own
  walk and says so before anything is touched.
- **A locked parent needed no special handling, which is worth knowing because it looks like it
  should.** Probed: `uchg` on a directory still allows `chmod`, `chflags`, `utimes` and `chgrp` on
  everything inside — only *creating* there fails. And changing a child's attributes does not bump
  the parent's mtime, so a recursive "set modification date" needs no ordering of its own either.
- **Propagating an ACL onto files needed a rule the kernel does not enforce, and it fails in the
  quiet direction.** Probed: `acl_set_file` accepts a *directory's* canonical text on a regular file,
  returns `0`, and `acl_get_file` reads it back **verbatim** — `delete_child` and the inheritance
  flags still stored — while `ls -le` shows only the data rights. `chmod +a` strips them on the way
  in (and leaves `0: group:everyone allow`, an entry with nothing in it), so
  `AccessControlList.adjusted(for:)` does the same and **drops an entry reduced to no rights**, which
  the editor already refuses to create. Without it the Sharing tab would show `delete_child` on a
  file — a false claim on the one tab whose whole job is that answer. A negative-control test asserts
  the kernel really does store them, so the rule cannot go vestigial and green.
- **A bulk edit was already a patch; a single-item edit had to become one, and the two halves
  translate differently.** `AttributePatch(from:to:)` takes a changed **mode whole** (a mode is a
  shape the user chose, not twelve independent bits) and **flags bit by bit** (so a `UF_HIDDEN` on
  one file inside a folder survives ticking Locked on the folder). Getting the second one backwards
  is silent and destructive, so it has its own test.
- **The exit criterion is met live, with the OS as the judge.** A harness against the real core ran
  the exact chain the sheet assembles over a real tree with deliberately mixed modes: 8 items counted
  (5 files only, 4 folders only — the run's own walk), 8 changed, 0 failures, every mode `0750`
  including the file under a `drwx------` directory the walk had to descend and then re-permission.
  `ls -le` shows the directories carrying `list,delete_child,file_inherit,directory_inherit` and the
  files carrying plain `allow read` — the kind adjustment, in the OS's own spelling. One record of 16
  steps (8 attribute + 8 ACL) reverted the whole tree exactly, ACL marker and all.
- **Two smaller things fell out.** A job that moves no bytes would have left the queue bar at zero for
  its whole run and then jumped to full, so `AggregateProgress` now falls back to *items* before the
  job count. And an item that is both a marked root and a child of another marked root is visited
  once — applying twice is harmless, but the sheet's count and the report's would have disagreed over
  a selection the user made deliberately.
- **Driven live, in the real app, and the numbers matched the harness exactly.** ⌘I on a folder shows
  the footer row with the popup disabled until the box is ticked; ticking it enables the popup and
  Save. Over the scratch tree: *Files and folders* counted **"Change 8 items?"** and gave every item
  `0750` — including the file inside a `drwx------` folder the walk had to descend and then
  re-permission — with one ⌘Z restoring all three differing originals (`0700`, `0600`, `0644`)
  exactly. *Files only* counted **5** (four files plus the root, the roots-always-apply rule) and
  left all three enclosed folders untouched while still descending through the `0700` one. The
  multi-selection sheet carries the same row.
- **The over-the-cap path was forced live with a 10 500-file folder.** The confirmation read
  **"Change 10 501 items?"** with the can't-be-reversed wording *before* the run; afterwards the alert
  said "Changed 10 501 items — That was too many to undo, so ⌘Z will reverse whatever you did before
  this instead", and the Edit menu proved it true by still offering the *previous* action's undo. Both
  counts are locale-formatted by the plural entries, in every language.

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

**Slice 5 landed for the single-item flat case (2026-08-02), core-first, and it is verified live with
the OS as the judge.** Core: `EscalatedAttributeCommand` translates a tested `AttributeChangePlan`
into one `/bin/sh` body via `ShellQuoting` (24 tests, app untouched). App: `AdministratorShell` runs
it through the system auth dialog, and `AttributesController+Escalation` presents both surfaces from
that one command. Non-owned files became editable, which is what Slice 4's own comments deferred to
"Slice 5's escalation." Nine catalog keys in all 14 languages. Multi-selection and recursive
escalation are deferred (their sheets still refuse a root-only change by name), and were left so
deliberately — the flat single-item path is where the mechanism proves out.

- **One command serves both surfaces, which is the exit criterion.** Option 2 hands the body to
  `do shell script (item 1 of argv) with administrator privileges` — the body passed as an *argument*,
  never embedded in the AppleScript source, so the only quoting is the `ShellQuoting` already inside it
  (probed: a body with quotes, backslashes and `$(…)` round-trips through `argv` inert). Option 3 shows
  `sudo /bin/sh -c '<body>'` in a copyable field, the body single-quoted as one word. Same bytes, same
  result. Live: `chmod 744` on the root-owned `/etc/hosts` produced exactly
  `sudo /bin/sh -c '/bin/chmod 744 '\''/private/etc/hosts'\'''` on the clipboard.
- **The CLI translation is faithful except two aspects no stock shell can reproduce, and those are
  named, never dropped** (decided with Oleg). `chflags` is *additive* (probed), so each flags step is a
  minimal `keyword`/`nokeyword` delta against the word on disk at that point; `touch -t` is
  whole-second (which is the `NSDatePicker`'s own resolution) and only the *changed* time is touched, so
  an untouched neighbour keeps its sub-second value; `chmod +a#` reproduces an *exact ordered* ACL, and
  the canonical `read/write/execute/append` spelling is accepted verbatim on a directory (chmod
  relabels it to `list/add_file/…` itself). The two omissions: the **Created date** (no stock tool sets
  the birth time without Xcode) and an **ACL `chmod` cannot express** (an inherited entry, an
  unresolved-GUID subject, or a token this build only keeps verbatim — the whole list is left rather
  than written wrongly). The dialog states each omission as its own sentence.
- **The unlock/relock and the repair steps come through for free**, because the command is built from
  the same `AttributeChangePlan` the flat write uses. Verified on a real *owned* file (no root needed to
  run the exact commands): a locked file's mode change came back `mode=600 flags=uchg` — changed and
  still locked in one gesture — and the setuid digit survived a `chmod 4755`.
- **The journal records what actually landed, not what was asked** — an omitted Created date or ACL is
  masked out, so ⌘Z never tries to revert a change that never happened. Undo of an escalated change
  still needs root and is refused by `UndoJournal` with the existing
  `attributeRestoreNeedsAdministrator` reason (the same asymmetric-undo shape Slice 4 already handles);
  making the *undo* itself escalate is a follow-on.
- **One layout bug was found only by launching** and is the M14 AppKit lesson repeated: an `NSAlert`
  reserves vertical space for its accessory from the view's *frame*, and a pure-Auto-Layout accessory
  reports a zero frame — so the copyable-command view drew *over* the informative text until its frame
  was set to `fittingSize`. Invisible in every test; obvious in the first live shot.

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
