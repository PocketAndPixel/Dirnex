# What works where

Every user-facing capability against every kind of location Dirnex can open, as of
**2026-08-26** (M0–M22 shipped, M23 landed, plus the post-M19 passes). The purpose is the
parity question: *where does working on a server still feel unlike working on the disk, and which
of those gaps are ours to close?*

Read [PLAN.md](../PLAN.md) for architecture, [HISTORY.md](HISTORY.md) for why a decision was
taken, and [NOTES.md](NOTES.md) for the measurements behind the hard limits cited here. This
file is a **status table**, not an argument — every "no" that is a decision rather than a gap is
marked as such and points at the entry that argues it.

## Statuses

| | Meaning |
|---|---|
| **yes** | Fully done. Behaves as it does on the local disk. |
| **yes, limited** | Fully done for what the technology allows. The remaining difference **cannot** be closed from our side — the protocol, the service or macOS does not expose it. |
| **yes, partially** | Done, and the gap **could** be narrowed to look more local. These are the parity backlog. |
| **no** | Not implemented. Nothing structural prevents it. |
| **n/a** | The concept does not exist there (a Trash inside the Trash, a checksum of a bucket list). |

## Locations

| Column | What it covers |
|---|---|
| **Local** | Internal and external volumes, disk images, **mounted vaults**, and **SMB/NFS** shares — SMB rides the OS mounter, so a share is an ordinary `/Volumes/…` tree (PLAN.md §M5). |
| **Cloud mount** | iCloud Drive, Google Drive, OneDrive, Dropbox and Box under `~/Library/CloudStorage` / `~/Library/Mobile Documents`. These are **real local paths**, so they inherit the Local column except where noted.<sup>1</sup> |
| **Archive** | A zip/tar/7z/… browsed as a folder tree (`archive:`), including nested archives.<sup>2</sup> |
| **SFTP** | A connected SSH account. |
| **FTP** | FTP and FTPS. |
| **S3** | A connected **bucket** (`s3:`) — Amazon S3 and every S3-compatible service. |
| **S3 acct** | An **account** pane (`s3account:`) whose rows are buckets, not files. |
| **Results** | A virtual results listing: ⌥F7 hits, a saved search, Recents, and the merged **iCloud Drive** sidebar row.<sup>3</sup> |
| **Trash** | The merged Trash — `~/.Trash` plus every volume's and every file provider's, presented as one place (PLAN.md §M8). |

<sup>1</sup> Two differences, both about **placeholder** (evicted / online-only) files: a byte-touching
operation downloads first, visibly, with a Stop (`CloudDownloadPrompt`), and a recursive sweep
refuses to materialize a placeholder rather than silently pulling a whole cloud drive
(`SF_DATALESS`). Google Drive in **mirror** mode exposes no sync state to anyone but Finder, so
badges are blank there — measured, not a gap.

<sup>2</sup> A **nested** archive is read-only: its own bytes are already a temp copy, so writes
have nowhere to land.

<sup>3</sup> The merged iCloud row is a *place* rather than a set of hits, so it navigates in
place, accepts creates and pastes (they land in the CloudDocs container underneath), and is
watched live. It is still a virtual container: no size bars, no pack, no Open in Terminal.

---

## 1. Browsing and navigation

| Functionality | Local | Cloud mount | Archive | SFTP | FTP | S3 | S3 acct | Results | Trash |
|---|---|---|---|---|---|---|---|---|---|
| List a folder | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| Enter a folder (`⏎`, double-click) | yes | yes | yes | yes | yes | yes | yes, limited<sup>a</sup> | yes | yes |
| `..` row and Go Up (`⌫`) | yes | yes | yes | yes | yes | yes | n/a | n/a | n/a |
| Path bar, breadcrumbs, `⌘L` | yes | yes | yes | yes | yes | yes | yes | yes, limited<sup>b</sup> | yes, limited<sup>b</sup> |
| Back / forward, history (`⌥↓`) | yes | yes | yes | yes | yes | yes | yes | yes, limited<sup>c</sup> | yes, limited<sup>c</sup> |
| Tabs, split panes, `Tab` focus | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| Sort, column layout, hidden files | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| Type-to-filter, marks, `⌘A`, invert | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| Tree view (`→` to expand) | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| Live auto-refresh when it changes elsewhere | yes | yes | no<sup>d</sup> | no | no | no | no | n/a | yes |
| Folder size on `Space` / `⌥⇧⏎` | yes | yes | yes | yes, limited<sup>e</sup> | yes, limited<sup>e</sup> | yes, limited<sup>e</sup> | n/a | yes | yes |
| Size visualization bars (`⌃B`) | yes | yes | no | no | no | no | no | no | no |
| Git status column, `.gitignore`-aware sizes | yes | yes | n/a | n/a | n/a | n/a | n/a | n/a | n/a |
| Appears in Recents | yes | yes | no | no | no | no | no | n/a | n/a |
| Reopens at launch / in a saved workspace | yes | yes | no | no | no | no | no | n/a | n/a |

<sup>a</sup> Entering a bucket row is a **connect**, not a listing: `S3AccountBackend` is depth 0
by design (everything below a bucket is the bucket backend). It carries the region-301 correction
and the path-style retry, so it usually just works — but the first entry can raise a connect
sheet where a folder never would.

<sup>b</sup> A virtual listing draws a label, not a walkable crumb trail — there is no directory
to walk to.

<sup>c</sup> Leaving a virtual listing resets the trail, so back cannot return to the hits.

<sup>d</sup> An archive re-reads when its file on disk changes identity (device/inode/size/mtime),
so repacking it under the same name is picked up. There is no watcher on the members.

<sup>e</sup> Bounded at **1000 directories** (`DirectorySizeBudget.remote`) because a remote walk
is a billed request and a round trip each — measured 0.601–0.699 s per `ListObjectsV2`, so
1000 directories is ~10 minutes. Cancellable, and abandoned when the pane stops looking. Over
budget the pane says it gave up rather than showing a partial total as if it were the answer.

## 2. File operations

| Functionality | Local | Cloud mount | Archive | SFTP | FTP | S3 | S3 acct | Results | Trash |
|---|---|---|---|---|---|---|---|---|---|
| Copy `F5` (source) | yes | yes | yes, limited<sup>f</sup> | yes | yes | yes | no<sup>g</sup> | yes | yes |
| Copy `F5` (destination) | yes | yes | yes, limited<sup>f</sup> | yes | yes | yes | no<sup>g</sup> | n/a | n/a |
| Move `F6` | yes | yes | no<sup>f</sup> | yes | yes | yes, limited<sup>h</sup> | no<sup>g</sup> | yes | yes |
| Copy between two different accounts | yes | yes | — | yes | yes | yes | — | — | — |
| Copy / paste `⌘C` `⌘V` | yes | yes | yes<sup>i</sup> | yes | yes | yes | no<sup>g</sup> | yes, partially<sup>j</sup> | yes, partially<sup>j</sup> |
| Drag and drop, inside Dirnex | yes | yes | yes, partially<sup>i</sup> | yes | yes | yes | no<sup>g</sup> | yes, partially<sup>j</sup> | yes, partially<sup>j</sup> |
| Drag **out** to Finder and other apps | yes | yes | **no**<sup>i</sup> | yes, partially<sup>j</sup> | yes, partially<sup>j</sup> | yes, partially<sup>j</sup> | no<sup>g</sup> | yes, partially<sup>j</sup> | yes |
| Drag **in** from Finder and other apps | yes | yes | **no**<sup>i</sup> | yes | yes | yes | no<sup>g</sup> | no<sup>j</sup> | no<sup>j</sup> |
| New Folder `F7` | yes | yes | no | yes | yes | yes | yes, limited<sup>k</sup> | no | no |
| New / Edit File `⇧F4` | yes | yes | no | yes | yes | yes | n/a | no | no |
| Rename `F2` | yes | yes | no | yes | yes | yes, limited<sup>h</sup> | no | yes | no<sup>l</sup> |
| Multi-rename `⇧F2` | yes | yes | no | yes | yes | yes, limited<sup>h</sup> | no | yes | no<sup>l</sup> |
| Delete `F8` → Trash | yes | yes | n/a | n/a | n/a | n/a | n/a | yes | n/a |
| Delete `F8` → permanent (confirmed) | yes | yes | yes, limited<sup>m</sup> | yes | yes | yes | yes, limited<sup>k</sup> | yes | yes |
| Put Back (restore from Trash) | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | yes, limited<sup>n</sup> |
| Undo `⌘Z` | yes | yes | no | yes, partially<sup>o</sup> | yes, partially<sup>o</sup> | yes, partially<sup>o</sup> | yes, partially | yes | no |
| Background queue, progress bar, Stop | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| Per-file conflict dialog | yes | yes | yes | yes | yes | yes | n/a | yes | yes |
| Preserve permissions / dates / xattrs on copy | yes | yes | yes, limited | **no**<sup>p</sup> | **no**<sup>p</sup> | n/a<sup>p</sup> | n/a | yes | yes |
| Copy a symlink as a symlink | yes | yes | yes | **no** | **no** | n/a | n/a | yes | yes |
| APFS clone fast path | yes | yes | n/a | n/a | n/a | n/a | n/a | yes | yes |

<sup>f</sup> `F5` **out of** an archive extracts the marked members into the other pane (which
must be a real folder); `F5`/`F6` **into** a top-level archive adds files to it by repacking.
Move-*out* does not exist — there is nothing to remove from a read-only container.

<sup>g</sup> An account has no verb for "put this file in the account" — its rows are buckets.
Deliberate (`VFSBackendID.acceptsUploads`), not a gap.

<sup>h</sup> A rename or move of a **prefix** on S3 is N copies plus N deletes, so it is **not
atomic**: stopping partway leaves items under both names. No layer can make it otherwise
(PLAN.md §M21). Single objects are one copy + one delete.

<sup>i</sup> An archive member is **copied out**: ⌘V and a drop inside Dirnex extract it to a temp
directory and copy the real file on, through the same funnel `F5` copy-out uses
(`ArchiveTransferSources`), so a mixed selection of archive, local and remote rows travels as one
gesture. It is always a **copy** — a read-only container has nothing to remove afterwards, so ⌥⌘V
drops such a row and a ⌘-forced drag falls back to copying (`TransferAdmission.allowsMove`), the
same rule that makes `F6` move-out not exist. Two asymmetries: dragging a member **out** to another
app is the one gesture still missing (a promise is fulfilled behind somebody else's drop, where an
encrypted archive would have to raise a passphrase sheet with nothing on screen to answer it on —
`F5` is the route); and `⌘V` **into** a top-level archive adds files by repacking while a *drop*
into one does not, `⌥⌘V` into one being unsupported either way.

<sup>j</sup> What a drag can and cannot reach, in three parts. A row on a server is dragged **out**
as an `NSFilePromiseProvider`: the board advertises the file and the bytes are fetched only if
something accepts the drop, through the same funnel `⏎` and `F4` use — so a row already fetched for
a preview drags out with no transfer at all. A **folder** is not promised (a promise is one file,
and a recursive fetch behind a Finder drop has no progress surface and no way to stop it), so it
travels inside Dirnex only. And a **virtual listing** — a results tab, the merged Trash — is a
source and never a destination: its rows carry their real paths and copy or drag out per row, while
nothing can be pasted or dropped *into* a listing that has no directory of its own. The merged
iCloud row is the exception, landing in the CloudDocs container underneath.

<sup>k</sup> `F7` in an account pane creates a **bucket** (with S3's stricter naming rules, and a
listing-backed existence check because `HeadBucket` goes stale for ~1 read in 3 after a delete).
`F8` deletes a bucket, and only an empty one.

<sup>l</sup> Rename is deliberately withdrawn inside a Trash: Put Back is keyed on the item's name
in the trash folder's `.DS_Store`, so renaming would orphan the origin record silently and
permanently. Finder refuses the same gesture.

<sup>m</sup> Deleting an archive member **rewrites the archive**. No Trash, and not undoable.
Top-level archives only.

<sup>n</sup> Works for anything Finder or Dirnex trashed to `~/.Trash`, a volume's `.Trashes`, or
a Google Drive mount's `.Trash`. It **cannot** work in the iCloud trash or for a Finder delete on
Box — those origins are opaque provider references with no path in them.

<sup>o</sup> Rename, move and New Folder are journaled and reversed through the backend, so they
undo remotely. A **permanent delete is not reversible anywhere** — which is every remote delete,
since no remote backend has a Trash.

<sup>p</sup> `copyMetadata` is a no-op on the remote backends. S3 has no settable mtime, no
permissions and no symlinks at all (PLAN.md §M21); SFTP and FTP could carry more than they do.

## 3. Preview, open and edit

| Functionality | Local | Cloud mount | Archive | SFTP | FTP | S3 | S3 acct | Results | Trash |
|---|---|---|---|---|---|---|---|---|---|
| Quick View pane / full size (`⌃Q`) | yes | yes | yes, limited<sup>q</sup> | yes, limited<sup>r</sup> | yes, limited<sup>r</sup> | yes, limited<sup>r</sup> | n/a | yes | yes |
| Quick Look (`⌘Y`) | yes | yes | yes, limited<sup>q</sup> | yes, limited<sup>r</sup> | yes, limited<sup>r</sup> | yes, limited<sup>r</sup> | n/a | yes | yes |
| Syntax highlighting, Markdown, diagrams in preview | yes | yes | yes | yes | yes | yes | n/a | yes | yes |
| Open in the default app (`⏎`) | yes | yes | yes, limited<sup>s</sup> | yes, limited<sup>t</sup> | yes, limited<sup>t</sup> | yes, limited<sup>t</sup> | n/a | yes | yes |
| Edit `F4`, with save written back | yes | yes | yes, limited<sup>u</sup> | yes | yes | yes | n/a | yes | yes |
| Open With… / Share sheet | yes | yes | **no** | **no** | **no** | **no** | n/a | yes | yes |
| Compare By Contents (`⌥F3`) | yes | yes | **no** | **no** | **no** | **no** | n/a | yes, limited<sup>v</sup> | yes, limited<sup>v</sup> |
| Synchronize Directories | yes | yes | **no** | **no**<sup>w</sup> | **no**<sup>w</sup> | **no**<sup>w</sup> | n/a | no | no |
| Browse *into* an archive file | yes | yes | yes | **no**<sup>x</sup> | **no**<sup>x</sup> | **no**<sup>x</sup> | n/a | yes | yes |

<sup>q</sup> The member is extracted to a temp file first; only the **cursor's** member is ever
extracted, never a marked set (a subprocess per row). With M19's member filter this is
0.001 s for a small member of a 600 MB encrypted archive, against 1.53 s before it.

<sup>r</sup> The bytes are downloaded first. A preview renders on *cursor movement*, so an arrow
key never spends a billed request: the surface draws a placeholder card with the name, the size
and a Download button, and the key you press is what starts the transfer. Only the cursor row
is ever fetched.

<sup>s</sup> Opens the extracted copy. Read-only — `⏎` writes nothing back (that is `F4`'s job).

<sup>t</sup> Downloads to a temp copy, opens that, and registers it so a save is offered back up.

<sup>u</sup> A member of a **writable** (top-level) archive only; saving repacks the archive,
preserving encryption and hidden names. A nested archive's member cannot.

<sup>v</sup> Only for hits that are real local files; two archive members or two server objects
are not comparable.

<sup>w</sup> Deliberate for FTP by timestamp (`LIST` stamps are year-less, zone-less and on the
server's clock) and for S3 (no settable mtime). SFTP by **size** would be honest and is simply
not built.

<sup>x</sup> `⏎` on a `.zip` sitting on a server downloads it and hands it to the default app
rather than browsing it. Fetch-then-browse is the obvious shape and is not built.

## 4. Find Files (`⌥F7`)

| Functionality | Local | Cloud mount | Archive | SFTP | FTP | S3 | S3 acct | Results | Trash |
|---|---|---|---|---|---|---|---|---|---|
| Search at all | yes | yes | yes | yes | yes | yes | **no**<sup>y</sup> | yes, limited<sup>z</sup> | yes, limited<sup>z</sup> |
| by **name** | yes | yes | yes | yes | yes | yes | n/a | yes | yes |
| by **kind / size / modified** | yes | yes | yes | yes | yes | yes | n/a | yes | yes |
| by **file contents** | yes | yes | **n/a**<sup>aa</sup> | **n/a**<sup>aa</sup> | **n/a**<sup>aa</sup> | **n/a**<sup>aa</sup> | n/a | yes | yes |
| by **Finder tag** | yes | yes | n/a | n/a | n/a | n/a | n/a | yes | yes |
| Runs off an index (instant) | yes | yes | no<sup>bb</sup> | no<sup>bb</sup> | no<sup>bb</sup> | no<sup>bb</sup> | n/a | yes | yes |
| Server-side walk (one request, not one per folder) | n/a | n/a | n/a | yes, limited<sup>cc</sup> | **no** | yes | n/a | — | — |
| Live progress + Stop | yes | yes | yes | yes | yes | yes | n/a | yes | yes |
| Save the search to the sidebar, re-run later | yes | yes | yes | yes | yes | yes | n/a | yes | yes |

<sup>y</sup> Deliberate: the rows are buckets, and "search every bucket" is a different and far
more expensive question than the one ⌥F7 asks (PLAN.md §M22).

<sup>z</sup> A virtual listing has no directory, so the scope falls back to **Home** — the hits
are real files, but the pane you were looking at is not the scope.

<sup>aa</sup> Impossible without downloading everything under the scope in order to grep it.
`SearchFields` **hides** the field rather than accepting it and skipping the clause, which would
return *more* results under the same name.

<sup>bb</sup> A recursive walk of the backend's own listings, bounded by the same
`DirectorySizeBudget` and cancellable at one-listing granularity.

<sup>cc</sup> When the account allows an SSH **exec** channel, the server walks its own tree with
`find` — 501 directories in 98 ms, against 34.3 s of one connection per directory. An
`sftp`-only account (`ForceCommand internal-sftp`) falls back to the per-directory walk, decided
per connection at run time.

## 5. Metadata and macOS integration

| Functionality | Local | Cloud mount | Archive | SFTP | FTP | S3 | S3 acct | Results | Trash |
|---|---|---|---|---|---|---|---|---|---|
| Get Info: permissions, flags, dates | yes | yes | **no** | **no** | **no** | n/a | n/a | yes<sup>dd</sup> | yes<sup>dd</sup> |
| Get Info: ACLs, extended attributes | yes | yes | n/a | n/a | n/a | n/a | n/a | yes<sup>dd</sup> | yes<sup>dd</sup> |
| Privilege escalation for a root-only change | yes | yes | n/a | n/a | n/a | n/a | n/a | yes | yes |
| Finder tags (`⌃T`, tag dots) | yes | yes | n/a | n/a | n/a | n/a | n/a | yes<sup>dd</sup> | yes<sup>dd</sup> |
| Cloud sync badges | yes | yes | n/a | n/a | n/a | n/a | n/a | yes | yes |
| Create / verify checksum files | yes | yes | **no** | **no**<sup>ee</sup> | **no**<sup>ee</sup> | **no**<sup>ee</sup> | n/a | no | no |
| Open in Terminal | yes | yes | n/a | **no**<sup>ff</sup> | n/a | n/a | n/a | no | no |
| Run a user script | yes | yes | **no** | **no** | **no** | **no** | no | no | no |
| Pack `⌥F5` (create an archive) | yes | yes | n/a | **no**<sup>gg</sup> | **no**<sup>gg</sup> | **no**<sup>gg</sup> | n/a | **no** | no |
| Encrypted archives / hidden member names | yes | yes | yes | no<sup>gg</sup> | no<sup>gg</sup> | no<sup>gg</sup> | n/a | no | no |
| Create / unlock an encrypted vault | yes | yes | n/a | **no** | **no** | **no** | n/a | no | n/a |
| Saved connection in the sidebar | n/a | n/a | n/a | yes | yes | yes | yes | n/a | n/a |
| Pin to Favorites / Places menu | yes | yes | no | yes, partially<sup>hh</sup> | yes, partially<sup>hh</sup> | yes, partially<sup>hh</sup> | yes, partially | no | n/a |

<sup>dd</sup> Gated per **row**, not per pane — a search hit or a trashed file is an ordinary local
file, so it carries a mode, an ACL and tags like any other.

<sup>ee</sup> Neither `sftp` nor `curl` can hash server-side, so a remote checksum is a full
download. Buildable (a streaming read over the existing transports); not built.

<sup>ff</sup> A local shell cannot `cd` to a server. An `ssh` session to the SFTP account's own
host is a different feature and is not built.

<sup>gg</sup> Both ends of a pack must be real local folders. Packing *to* or *from* a server
would work through the existing staging path and is not built.

<sup>hh</sup> A remote folder can be pinned from the menu, but the pin is not restored at launch
and is not a drag target in the sidebar (PLAN.md §M8's deliberate omission). The **Servers**
section is the reconnectable surface.

## 6. Transfer behaviour

Where the local disk has no equivalent, the row is about how close a remote transfer feels to a
local one.

| Functionality | Local | Cloud mount | Archive | SFTP | FTP | S3 | S3 acct |
|---|---|---|---|---|---|---|---|
| Determinate byte progress, downloading | yes | yes | n/a | yes | yes | yes | n/a |
| Determinate byte progress, uploading | yes | yes | n/a | **yes, limited**<sup>ii</sup> | yes | yes | n/a |
| Resume an interrupted transfer | n/a | n/a | n/a | yes | yes | yes | n/a |
| Split one file over several connections | n/a | n/a | n/a | yes | yes | yes | n/a |
| Multipart upload for very large files | n/a | n/a | n/a | no | no | yes | n/a |
| Stop actually stops the bytes | yes | yes | yes | yes | yes | yes | n/a |
| Server-side copy (bytes never touch this Mac) | yes<sup>jj</sup> | yes<sup>jj</sup> | n/a | **no**<sup>kk</sup> | **no**<sup>kk</sup> | yes | n/a |
| Duplicate a file inside one account | yes | yes | n/a | yes, limited<sup>kk</sup> | yes, limited<sup>kk</sup> | yes | n/a |
| Conditional write (nobody overwrote it meanwhile) | n/a | n/a | n/a | yes, limited<sup>ll</sup> | yes, limited<sup>ll</sup> | yes | n/a |
| Certificate / host-key trust prompt, saved | n/a | n/a | n/a | yes | yes | yes | yes |
| Credentials in the Keychain, never in `argv` | n/a | n/a | n/a | yes | yes | yes | yes |

<sup>ii</sup> `sftp` prints no progress meter to a spawned process, and no flag changes that
(measured in six configurations over a 1 GiB transfer). A **download** watches its own destination
file grow, so it is exact; an **upload** has no observable at all and reports its byte count once,
at the end.

<sup>jj</sup> An APFS clone, which is instant and costs no bytes.

<sup>kk</sup> Neither protocol has a copy verb — their `copyFile` *is* an upload or a download. A
duplicate inside one account, or a copy between two accounts, is staged through this Mac
(`RelayCopy`), which costs the file's size in temp space and moves the bytes twice. Correct, and
slower than it looks.

<sup>ll</sup> S3 sends `If-Match`; SFTP and FTP re-`stat` before uploading and tell you if the
file changed since it was fetched, which is a narrower window and not a guarantee.

---

## Where remote still feels unlike local

Ranked by how often it is in the way, counting only the **"no"** and **"yes, partially"** cells —
the "yes, limited" ones are the technology and are already as close as they get.

1. **No live refresh on a server.** A file added by somebody else never appears until the folder
   is re-listed by hand. A cheap poll while a pane is frontmost would cover most of it.
2. **Session restore and workspaces drop remote tabs.** Quit with four bucket tabs open and they
   are gone. The saved connection survives in the sidebar; the *place* does not.
3. **Archives are local-only in every direction.** A `.zip` on a server cannot be browsed, and
   nothing can be packed to or from one — even though the staging path that would do it already
   exists for `RelayCopy`.
4. **Checksums, Compare By Contents, Synchronize and user scripts are local-only.** All four are
   "download, then run the local implementation"; none is built.
5. **Permissions and symlinks are not preserved on an SFTP/FTP copy.** `chmod` and `ln -s` are
   both available over SFTP; nothing consumes them.
6. **Open With / Share are dead remotely.** Both need a local URL, which the remote fetch path
   already knows how to produce.
7. **No Trash anywhere remote**, so every remote delete is permanent and unreversible. This is
   honest about the protocols, but a Dirnex-managed `.dirnex-trash` prefix would be a real
   improvement over a confirmation dialog.

Things that are **not** on this list because they cannot be fixed, and the app is already as
close as the technology permits: content search and tag search on a server, exact FTP timestamps,
atomicity of an S3 prefix rename, upload progress over SFTP, per-item download percentages from
macOS's cloud providers, and Put Back inside the iCloud trash.
