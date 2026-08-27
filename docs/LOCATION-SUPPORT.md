# What works where

Every user-facing capability against every kind of location Dirnex can open, as of
**2026-08-27** (M0–M23 shipped, plus the post-M19 passes). The purpose is the parity question:
*where does working on a server still feel unlike working on the disk, and which of those gaps are
ours to close?*

Read [PLAN.md](../PLAN.md) for architecture and for the milestones that close what is still open,
[HISTORY.md](HISTORY.md) for why a decision was taken, and [NOTES.md](NOTES.md) for the measurements
behind the hard limits cited here. This file is a **status table**, not an argument and not a log:
every "no" that is a decision rather than a gap is marked as such and points at the entry that
argues it, and every one that *is* a gap points at the milestone that owns it. A cell that has
closed simply reads differently — it is not explained here.

## Statuses

| | Meaning |
|---|---|
| **yes** | Fully done. Behaves as it does on the local disk. |
| **yes, limited** | Fully done for what the technology allows. The remaining difference **cannot** be closed from our side — the protocol, the service or macOS does not expose it. |
| **yes, partially** | Done, and the gap **could** be narrowed to look more local. Parity backlog: PLAN.md §4, M24 or M25. |
| **no** | Not implemented, and nothing structural prevents it — so it is backlog too, and its footnote names the milestone. A "no" with no route to a yes is written **n/a** instead. |
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
| Live auto-refresh when it changes elsewhere | yes | yes | no<sup>d</sup> | yes, limited<sup>f</sup> | yes, limited<sup>f</sup> | yes, limited<sup>f</sup> | yes, limited<sup>f</sup> | n/a | yes |
| Folder size on `Space` / `⌥⇧⏎` | yes | yes | yes | yes, limited<sup>e</sup> | yes, limited<sup>e</sup> | yes, limited<sup>e</sup> | n/a | yes | yes |
| Size visualization bars (`⌃B`) | yes | yes | no<sup>nn</sup> | no<sup>nn</sup> | no<sup>nn</sup> | no<sup>nn</sup> | no<sup>nn</sup> | n/a<sup>nn</sup> | n/a<sup>nn</sup> |
| Git status column, `.gitignore`-aware sizes | yes | yes | n/a | n/a | n/a | n/a | n/a | n/a | n/a |
| Appears in Recents | yes | yes | n/a<sup>oo</sup> | n/a<sup>oo</sup> | n/a<sup>oo</sup> | n/a<sup>oo</sup> | n/a<sup>oo</sup> | n/a | n/a |
| Reopens at launch / in a saved workspace | yes | yes | yes | yes, limited<sup>ww</sup> | yes, limited<sup>ww</sup> | yes, limited<sup>ww</sup> | yes, limited<sup>ww</sup> | n/a | n/a |

<sup>a</sup> Entering a bucket row is a **connect**, not a listing: `S3AccountBackend` is depth 0
by design (everything below a bucket is the bucket backend). It carries the region-301 correction
and the path-style retry, so it usually just works — but the first entry can raise a connect
sheet where a folder never would.

<sup>b</sup> A virtual listing draws a label, not a walkable crumb trail — there is no directory
to walk to.

<sup>c</sup> Leaving a virtual listing resets the trail, so back cannot return to the hits.

<sup>d</sup> An archive re-reads when its file on disk changes identity (device/inode/size/mtime),
so repacking it under the same name is picked up — but only when something asks it to: `startWatching`
returns early for any backend but `.local`, so nothing wakes the pane. The decision is already made
and tested (`ArchiveIdentity`); the stream over the archive file is not built (PLAN.md §M25, smaller
than a milestone). There is no watcher on the members, and there cannot be one.

<sup>e</sup> Bounded at **1000 directories** (`DirectorySizeBudget.remote`) because a remote walk
is a billed request and a round trip each — measured 0.601–0.699 s per `ListObjectsV2`, so
1000 directories is ~10 minutes. Cancellable, and abandoned when the pane stops looking. Over
budget the pane says it gave up rather than showing a partial total as if it were the answer.

<sup>f</sup> No remote protocol here reports a change — SFTP has no `inotify`, FTP has no verb,
and S3 has no session to hold a notification open on — so a pane on a server **asks again on a timer**
instead (`RemoteRefreshPolicy`). Limited in three ways, each deliberate. It runs only while the pane
is genuinely on screen: `NSWindow.occlusionState` was probed to go false for a window that is
miniaturized, hidden, ordered out **or covered by another window**, and any of those stands the poll
down entirely. The gap is never shorter than the floor in Settings ▸ Panels (15 s by default, and
**0 means never contact a server unasked**). And a folder that turns out to be slow or expensive to
list is asked less often still — the interval is derived from what the *previous* refresh actually
cost, holding a pane to ~5 % of its wall time, so a 50 000-object prefix (fifty billed
`ListObjectsV2` requests, ~32 s) settles to about one refresh every eleven minutes with no
per-backend number to keep. Nothing is repainted when the listing has not moved, so the ordinary
answer — "the same rows" — costs one request and no work. A pane stood down catches up the
moment it is visible again rather than waiting out a fresh interval. FSEvents stays exact and free,
which is why the local and cloud-mount columns are a plain yes.

<sup>nn</sup> A bar is a row's share of **its own directory**, so it needs every sibling's total
rather than the cursor's — remotely that is N bounded walks where the `Space` total above is one. In
an archive it is cheap (the whole table of contents is already in hand) and simply gated with the
rest; on a virtual listing whose rows live in a dozen different folders "share of this directory" has
no referent, which is why those two read n/a. So what is missing is a budget for the set, not a
capability (PLAN.md §M25, smaller than a milestone).

<sup>oo</sup> Recents is Spotlight's `kMDItemLastUsedDate` over the local index, so a location macOS
does not index cannot appear in it whatever Dirnex does. The same is true of the ⌘L fuzzy jump, which
records local directories only because it navigates by picking the first candidate still on disk.

<sup>ww</sup> The tab comes back and re-opens its connection when it is first shown — the active
one at launch, the others when you switch to them, so a window of five server tabs contacts one
server rather than five. Two things it will not do on its own, both deliberate. A connection whose
secret is no longer in the Keychain cannot be re-established unattended, so the tab returns saying
so and one gesture (any navigation, or the sidebar row) signs it back in. And with Settings ▸
Panels set to **0 — never contact a server unasked** — the relaunch itself opens nothing: the tabs
are all there and the first gesture connects them. A *nested* archive is the one location that
cannot come back at all: its bytes are a temp extraction of a member of the enclosing archive, so
the file it was mounted from is gone by the next launch.

## 2. File operations

| Functionality | Local | Cloud mount | Archive | SFTP | FTP | S3 | S3 acct | Results | Trash |
|---|---|---|---|---|---|---|---|---|---|
| Copy `F5` (source) | yes | yes | yes, limited<sup>g</sup> | yes | yes | yes | no<sup>h</sup> | yes | yes |
| Copy `F5` (destination) | yes | yes | yes, limited<sup>g</sup> | yes | yes | yes | no<sup>h</sup> | n/a | n/a |
| Move `F6` | yes | yes | no<sup>g</sup> | yes | yes | yes, limited<sup>i</sup> | no<sup>h</sup> | yes | yes |
| Copy between two different accounts | yes | yes | — | yes | yes | yes | — | — | — |
| Copy / paste `⌘C` `⌘V` | yes | yes | yes<sup>j</sup> | yes | yes | yes | no<sup>h</sup> | yes, partially<sup>k</sup> | yes, partially<sup>k</sup> |
| Drag and drop, inside Dirnex | yes | yes | yes, partially<sup>j</sup> | yes | yes | yes | no<sup>h</sup> | yes, partially<sup>k</sup> | yes, partially<sup>k</sup> |
| Drag **out** to Finder and other apps | yes | yes | **no**<sup>j</sup> | yes, partially<sup>k</sup> | yes, partially<sup>k</sup> | yes, partially<sup>k</sup> | no<sup>h</sup> | yes, partially<sup>k</sup> | yes |
| Drag **in** from Finder and other apps | yes | yes | **no**<sup>j</sup> | yes | yes | yes | no<sup>h</sup> | no<sup>k</sup> | no<sup>k</sup> |
| New Folder `F7` | yes | yes | no | yes | yes | yes | yes, limited<sup>l</sup> | no | no |
| New / Edit File `⇧F4` | yes | yes | no | yes | yes | yes | n/a | no | no |
| Rename `F2` | yes | yes | no | yes | yes | yes, limited<sup>i</sup> | no | yes | no<sup>m</sup> |
| Multi-rename `⇧F2` | yes | yes | no | yes | yes | yes, limited<sup>i</sup> | no | yes | no<sup>m</sup> |
| Delete `F8` → Trash | yes | yes | n/a | n/a | n/a | n/a | n/a | yes | n/a |
| Delete `F8` → permanent (confirmed) | yes | yes | yes, limited<sup>n</sup> | yes | yes | yes | yes, limited<sup>l</sup> | yes | yes |
| Put Back (restore from Trash) | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | yes, limited<sup>o</sup> |
| Undo `⌘Z` | yes | yes | no<sup>qq</sup> | yes, partially<sup>p</sup> | yes, partially<sup>p</sup> | yes, partially<sup>p</sup> | yes, partially | yes | no |
| Background queue, progress bar, Stop | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| Per-file conflict dialog | yes | yes | yes | yes | yes | yes | n/a | yes | yes |
| Preserve permissions / dates / xattrs on copy | yes | yes | yes, limited | **no**<sup>q</sup> | **no**<sup>q</sup> | n/a<sup>q</sup> | n/a | yes | yes |
| Copy a symlink as a symlink | yes | yes | yes | **no**<sup>pp</sup> | n/a<sup>pp</sup> | n/a | n/a | yes | yes |
| APFS clone fast path | yes | yes | n/a | n/a | n/a | n/a | n/a | yes | yes |

<sup>g</sup> `F5` **out of** an archive extracts the marked members into the other pane (which
must be a real folder); `F5`/`F6` **into** a top-level archive adds files to it by repacking.
Move-*out* does not exist — there is nothing to remove from a read-only container.

<sup>h</sup> An account has no verb for "put this file in the account" — its rows are buckets.
Deliberate (`VFSBackendID.acceptsUploads`), not a gap.

<sup>i</sup> A rename or move of a **prefix** on S3 is N copies plus N deletes, so it is **not
atomic**: stopping partway leaves items under both names. No layer can make it otherwise
(PLAN.md §M21). Single objects are one copy + one delete.

<sup>j</sup> An archive member is **copied out**: ⌘V and a drop inside Dirnex extract it to a temp
directory and copy the real file on, through the same funnel `F5` copy-out uses
(`ArchiveTransferSources`), so a mixed selection of archive, local and remote rows travels as one
gesture. It is always a **copy** — a read-only container has nothing to remove afterwards, so ⌥⌘V
drops such a row and a ⌘-forced drag falls back to copying (`TransferAdmission.allowsMove`), the
same rule that makes `F6` move-out not exist. Two asymmetries: dragging a member **out** to another
app is the one gesture still missing (a promise is fulfilled behind somebody else's drop, where an
encrypted archive would have to raise a passphrase sheet with nothing on screen to answer it on —
`F5` is the route); and `⌘V` **into** a top-level archive adds files by repacking while a *drop*
into one does not, `⌥⌘V` into one being unsupported either way.

<sup>k</sup> What a drag can and cannot reach, in three parts. A row on a server is dragged **out**
as an `NSFilePromiseProvider`: the board advertises the file and the bytes are fetched only if
something accepts the drop, through the same funnel `⏎` and `F4` use — so a row already fetched for
a preview drags out with no transfer at all. A **folder** is not promised (a promise is one file,
and a recursive fetch behind a Finder drop has no progress surface and no way to stop it), so it
travels inside Dirnex only. And a **virtual listing** — a results tab, the merged Trash — is a
source and never a destination: its rows carry their real paths and copy or drag out per row, while
nothing can be pasted or dropped *into* a listing that has no directory of its own. The merged
iCloud row is the exception, landing in the CloudDocs container underneath.

<sup>l</sup> `F7` in an account pane creates a **bucket** (with S3's stricter naming rules, and a
listing-backed existence check because `HeadBucket` goes stale for ~1 read in 3 after a delete).
`F8` deletes a bucket, and only an empty one.

<sup>m</sup> Rename is deliberately withdrawn inside a Trash: Put Back is keyed on the item's name
in the trash folder's `.DS_Store`, so renaming would orphan the origin record silently and
permanently. Finder refuses the same gesture.

<sup>n</sup> Deleting an archive member **rewrites the archive**. No Trash, and not undoable.
Top-level archives only.

<sup>o</sup> Works for anything Finder or Dirnex trashed to `~/.Trash`, a volume's `.Trashes`, or
a Google Drive mount's `.Trash`. It **cannot** work in the iCloud trash or for a Finder delete on
Box — those origins are opaque provider references with no path in them.

<sup>p</sup> Rename, move and New Folder are journaled and reversed through the backend, so they
undo remotely. A **permanent delete is not reversible anywhere** — which is every remote delete,
since no remote backend has a Trash.

<sup>q</sup> `copyMetadata` is a no-op on the remote backends. S3 has no settable mtime, no
permissions and no symlinks at all (PLAN.md §M21); SFTP and FTP could carry more than they do, and
`sftp`'s own `get -p` / `put -p`, `chmod`, `chown` and `chgrp` are the verbs that would (PLAN.md
§M25). Over FTP it is the mode alone, through `-Q` quote commands.

<sup>pp</sup> Only the **read** half is missing, and only over SFTP: `SFTPBackend.createSymbolicLink`
ships and `CopyEngine` calls it, so a link can be written — but `sftp`'s `ls -la` prints the kind
(`l`) with no ` -> target`, and the batch language has no `readlink`, so the target would have to
come from the SSH exec channel an `sftp`-only account does not have (PLAN.md §M25). Writing an empty
link instead is the failure being refused. FTP has no symlink verb at all.

<sup>qq</sup> Deleting a member **rewrites the container**, and the journal has nowhere to put the
bytes that left. Reversing it means keeping them, which is a storage decision rather than a missing
hook (PLAN.md §M25, smaller than a milestone).

## 3. Preview, open and edit

| Functionality | Local | Cloud mount | Archive | SFTP | FTP | S3 | S3 acct | Results | Trash |
|---|---|---|---|---|---|---|---|---|---|
| Quick View pane / full size (`⌃Q`) | yes | yes | yes, limited<sup>r</sup> | yes, limited<sup>s</sup> | yes, limited<sup>s</sup> | yes, limited<sup>s</sup> | n/a | yes | yes |
| Quick Look (`⌘Y`) | yes | yes | yes, limited<sup>r</sup> | yes, limited<sup>s</sup> | yes, limited<sup>s</sup> | yes, limited<sup>s</sup> | n/a | yes | yes |
| Syntax highlighting, Markdown, diagrams in preview | yes | yes | yes | yes | yes | yes | n/a | yes | yes |
| Open in the default app (`⏎`) | yes | yes | yes, limited<sup>t</sup> | yes, limited<sup>u</sup> | yes, limited<sup>u</sup> | yes, limited<sup>u</sup> | n/a | yes | yes |
| Edit `F4`, with save written back | yes | yes | yes, limited<sup>v</sup> | yes | yes | yes | n/a | yes | yes |
| Open With… / Share sheet | yes | yes | yes, limited<sup>yy</sup> | yes, limited<sup>yy</sup> | yes, limited<sup>yy</sup> | yes, limited<sup>yy</sup> | n/a | yes | yes |
| Send to a **Service** | yes | yes | **no**<sup>zz</sup> | **no**<sup>zz</sup> | **no**<sup>zz</sup> | **no**<sup>zz</sup> | n/a | yes | yes |
| Compare By Contents (`⌥F3`) | yes | yes | yes, limited<sup>w</sup> | yes, limited<sup>w</sup> | yes, limited<sup>w</sup> | yes, limited<sup>w</sup> | n/a | yes | yes |
| Synchronize Directories | yes | yes | **no**<sup>x</sup> | **no**<sup>x</sup> | **no**<sup>x</sup> | **no**<sup>x</sup> | n/a | n/a<sup>x</sup> | n/a<sup>x</sup> |
| Browse *into* an archive file | yes | yes | yes | read-only<sup>y</sup> | read-only<sup>y</sup> | read-only<sup>y</sup> | n/a | yes | yes |

<sup>r</sup> The member is extracted to a temp file first; only the **cursor's** member is ever
extracted, never a marked set (a subprocess per row). With M19's member filter this is
0.001 s for a small member of a 600 MB encrypted archive, against 1.53 s before it.

<sup>s</sup> The bytes are downloaded first. A preview renders on *cursor movement*, so an arrow
key never spends a billed request: the surface draws a placeholder card with the name, the size
and a Download button, and the key you press is what starts the transfer. Only the cursor row
is ever fetched.

<sup>t</sup> Opens the extracted copy. Read-only — `⏎` writes nothing back (that is `F4`'s job).

<sup>u</sup> Downloads to a temp copy, opens that, and registers it so a save is offered back up.

<sup>v</sup> A member of a **writable** (top-level) archive only; saving repacks the archive,
preserving encryption and hidden names. A nested archive's member cannot.

<sup>w</sup> Both sides are brought down first, as one queued job with a determinate bar and a Stop
(PLAN.md §M24 Slice 4) — `ByteComparator` still only ever sees real local paths, and the diff tool is
handed the copies, which keep their real names. Two limits, both about what the pair *is*: a folder
has no contents to compare, and a diff tool has to be installed before anything is fetched (the tool
question is asked first, so a Mac with none pays for no download).

<sup>x</sup> Comparing by **timestamp** is deliberately refused for FTP (`LIST` stamps are year-less,
zone-less and on the server's clock) and for S3 (no settable mtime), and always will be. Comparing by
**size** would be honest on any of them and is simply not built; by *contents* becomes reachable once
⌥F3 can fetch two sides (PLAN.md §M25). A virtual listing has no directory to synchronize.

<sup>y</sup> `ArchiveBackend.init(archiveOnDiskPath:)` needs a real path, so browsing an archive on a
server is fetch-the-whole-file-then-mount — the mirror of packing *to* one, and the only navigation in
Dirnex that says what it costs before it happens (PLAN.md §M24 Slice 6). It is the same confirmation
every M24 gesture raises, so a small archive opens with no dialog and the bytes are shared with every
later gesture over that row. The mount is **read-only**, exactly as a nested archive's is and for the
same reason — its bytes are a temp copy, so a write would land there rather than in the archive on the
server. Walking up at the archive root goes back to the *server's* directory and the breadcrumb names
the server, never the extraction. Writing into one is repack-then-upload and is not built.

<sup>rr</sup> Every one of these refused in one line — `backend == .local`, in
`PanelViewController+UserScript.swift` and its siblings — and none of them needs the file to be
*local*, only to be **a file**. The fetch that supplies one is the marked-set download M24 Slice 2
made a queue job, with a determinate bar, a Stop and per-item failures; what is left for these rows
is the gesture that hands the copies over. Open With and Share stopped refusing at Slice 3, Compare
By Contents and checksums at Slice 4, user scripts at Slice 5, and Pack at Slice 6 — which was the
last of them.

<sup>yy</sup> The marked set is brought down first, as one queued job with a determinate bar, Stop
and per-item failures (PLAN.md §M24 Slice 3). Two limits, both about what a hand-off *is*. A
**folder** that is not on this disk is not a target — it stands for an unknown number of objects in
an unknown number of requests, and copying a tree out is F5's job. And Open With draws its app list
from the row's **name** rather than from a file, so a row with no extension offers nothing to choose
from; the list is otherwise identical, and it appears *before* the download, so escaping out of it
costs nothing. Share cannot do that — `NSSharingServicePicker` derives its services from the items —
so Share fetches first and then presents.

<sup>zz</sup> Services fills a pasteboard **synchronously**, inside the call AppKit makes as the menu
opens, and there is nowhere in it to put a download — blocking the main thread on one is the failure
M24 exists to prevent. A limit rather than a gap: the Services menu simply does not offer this pane
until its rows are files on this disk.

## 4. Find Files (`⌥F7`)

| Functionality | Local | Cloud mount | Archive | SFTP | FTP | S3 | S3 acct | Results | Trash |
|---|---|---|---|---|---|---|---|---|---|
| Search at all | yes | yes | yes | yes | yes | yes | **no**<sup>z</sup> | yes, limited<sup>aa</sup> | yes, limited<sup>aa</sup> |
| by **name** | yes | yes | yes | yes | yes | yes | n/a | yes | yes |
| by **kind / size / modified** | yes | yes | yes | yes | yes | yes | n/a | yes | yes |
| by **file contents** | yes | yes | **n/a**<sup>bb</sup> | **n/a**<sup>bb</sup> | **n/a**<sup>bb</sup> | **n/a**<sup>bb</sup> | n/a | yes | yes |
| by **Finder tag** | yes | yes | n/a | n/a | n/a | n/a | n/a | yes | yes |
| Runs off an index (instant) | yes | yes | no<sup>cc</sup> | no<sup>cc</sup> | no<sup>cc</sup> | no<sup>cc</sup> | n/a | yes | yes |
| Server-side walk (one request, not one per folder) | n/a | n/a | n/a | yes, limited<sup>dd</sup> | **no**<sup>ss</sup> | yes | n/a | — | — |
| Live progress + Stop | yes | yes | yes | yes | yes | yes | n/a | yes | yes |
| Save the search to the sidebar, re-run later | yes | yes | yes | yes | yes | yes | n/a | yes | yes |

<sup>z</sup> Deliberate: the rows are buckets, and "search every bucket" is a different and far
more expensive question than the one ⌥F7 asks (PLAN.md §M22).

<sup>aa</sup> A virtual listing has no directory, so the scope falls back to **Home** — the hits
are real files, but the pane you were looking at is not the scope.

<sup>bb</sup> Impossible without downloading everything under the scope in order to grep it.
`SearchFields` **hides** the field rather than accepting it and skipping the clause, which would
return *more* results under the same name.

<sup>cc</sup> A recursive walk of the backend's own listings, bounded by the same
`DirectorySizeBudget` and cancellable at one-listing granularity.

<sup>dd</sup> When the account allows an SSH **exec** channel, the server walks its own tree with
`find` — 501 directories in 98 ms, against 34.3 s of one connection per directory. An
`sftp`-only account (`ForceCommand internal-sftp`) falls back to the per-directory walk, decided
per connection at run time.

<sup>ss</sup> FTP has neither an exec channel nor a delimiter-less listing, so its search is one
`LIST` per directory. `curl` reuses one connection across many `ftp://` URLs, which is the shape
worth measuring — and worth much less than it looks now that `ProcessWaiting` no longer taxes every
child ~71 ms (PLAN.md §M25, smaller than a milestone).

## 5. Metadata and macOS integration

| Functionality | Local | Cloud mount | Archive | SFTP | FTP | S3 | S3 acct | Results | Trash |
|---|---|---|---|---|---|---|---|---|---|
| Get Info: permissions, flags, dates | yes | yes | read-only<sup>tt</sup> | read-only<sup>tt</sup> | read-only<sup>tt</sup> | read-only<sup>tt</sup> | read-only<sup>tt</sup> | yes<sup>ee</sup> | yes<sup>ee</sup> |
| Get Info: ACLs, extended attributes | yes | yes | n/a | n/a | n/a | n/a | n/a | yes<sup>ee</sup> | yes<sup>ee</sup> |
| Privilege escalation for a root-only change | yes | yes | n/a | n/a | n/a | n/a | n/a | yes | yes |
| Finder tags (`⌃T`, tag dots) | yes | yes | n/a | n/a | n/a | n/a | n/a | yes<sup>ee</sup> | yes<sup>ee</sup> |
| Cloud sync badges | yes | yes | n/a | n/a | n/a | n/a | n/a | yes | yes |
| Create / verify checksum files | yes | yes | verify only<sup>ff</sup> | yes, limited<sup>ff</sup> | yes, limited<sup>ff</sup> | yes, limited<sup>ff</sup> | n/a | no<sup>xx</sup> | no<sup>xx</sup> |
| Open in Terminal | yes | yes | n/a | **no**<sup>gg</sup> | n/a | n/a | n/a | no | no |
| Run a user script | yes | yes | yes<sup>aaa</sup> | yes<sup>aaa</sup> | yes<sup>aaa</sup> | yes<sup>aaa</sup> | no<sup>aaa</sup> | yes, limited<sup>aaa</sup> | yes, limited<sup>aaa</sup> |
| Pack `⌥F5` (create an archive) | yes | yes | yes<sup>hh</sup> | yes, partially<sup>hh</sup> | yes, partially<sup>hh</sup> | yes, partially<sup>hh</sup> | n/a | yes, partially<sup>hh</sup> | yes |
| Encrypted archives / hidden member names | yes | yes | yes | yes, partially<sup>hh</sup> | yes, partially<sup>hh</sup> | yes, partially<sup>hh</sup> | n/a | yes, partially<sup>hh</sup> | yes |
| Create / unlock an encrypted vault | yes | yes | n/a | n/a<sup>uu</sup> | n/a<sup>uu</sup> | n/a<sup>uu</sup> | n/a | no | n/a |
| Saved connection in the sidebar | n/a | n/a | n/a | yes | yes | yes | yes | n/a | n/a |
| Pin to Favorites / Places menu | yes | yes | no | yes, partially<sup>ii</sup> | yes, partially<sup>ii</sup> | yes, partially<sup>ii</sup> | yes, partially | no | n/a |

<sup>ee</sup> Gated per **row**, not per pane — a search hit or a trashed file is an ordinary local
file, so it carries a mode, an ACL and tags like any other.

<sup>ff</sup> Neither `sftp` nor `curl` can hash server-side, so a remote checksum is a full
download of everything in scope — the marked-set fetch note <sup>rr</sup> describes, with
`ChecksumEngine` behind it and the manifest keeping the **remote** names rather than the temp ones
(PLAN.md §M24 Slice 4). **Verifying** is two-phase: the manifest comes down first, because nothing
can know what else to fetch until it has been read, and the files it names come down after — so the
one confirmation names the real total rather than a floor. **Creating** writes the manifest beside
the objects it describes, which on a server is an upload, so it needs a writable destination: a
read-only bucket greys the command out, and a browsed archive greys it out too, because writing into
one is a repack (PLAN.md §M24 Slice 6). Two further limits, both about scope rather than protocol: a
**folder** that is not already on this Mac is refused, since it stands for an unknown number of
objects in an unknown number of requests — copy it over with F5 and checksum the copy — and a file
the walk *discovers* by descending into a marked folder is still subject to the engine's own refusal,
so an evicted placeholder found that way is reported as "not downloaded" rather than silently pulled
down. A row whose transfer failed is reported the same way, never as a mismatch.

<sup>gg</sup> A local shell cannot `cd` to a server. An `ssh` session to the SFTP account's own
host is a different feature and is not built.

<sup>hh</sup> Neither end has to be on this Mac (PLAN.md §M24 Slice 6). The **sources** are brought
down first — the marked-set fetch note <sup>rr</sup> describes — and each one then names its own
directory, so a set staged off a server, a browsed archive's members and a tree's marks at two depths
all pack alike. The **destination** is asked `capabilities(for:)` on its own directory, so a writable
bucket or SFTP folder takes the archive and a read-only one is refused before anything is written; an
archive bound for a server is built in a temp directory and transferred, and the temp is swept
whatever happens. Three limits. A **folder** that is not already here is refused, in the hand-off's
words and for its reason — it stands for an unknown number of objects in an unknown number of
requests, so copy it over with F5 and pack the copy. A **browsed archive cannot receive** one, because
`ArchiveBackend` advertises `.read` alone and writing into an archive is a repack. And a *plain* pack
to a server has no bar and no Stop for its upload: a plain pack has never been a queue job — that is
the libarchive boundary §M19 drew, and it is the encrypted path alone that runs on the queue — so the
upload is reported by the status line. Encrypting the same archive puts both halves on the bar.
Both of the last two are ours to close rather than the protocol's, which is why these cells read
*partially*: staging a remote subtree is F5's engine pointed at a temp directory, and a plain pack on
the queue is a `bsdtar` job the queue does not yet have a kind for.

<sup>ii</sup> A remote folder can be pinned from the menu, but the pin is not restored at launch
and is not a drag target in the sidebar (PLAN.md §M8's deliberate omission). The **Servers** section
is the reconnectable surface. A `FavoriteEntry` carries a `VFSPath`, whose `VFSBackendID` says nothing
about the auth method — which is exactly the gap `PersistedTab` closed by carrying a
`StoredServerEndpoint`, so the same fix one type along is what would make the pin reconnect (PLAN.md
§M25, smaller than a milestone).

<sup>tt</sup> Read-only since M24 Slice 7: a row that is not on this Mac opens
`RemoteAttributesController`, which states **what the listing actually reported** and nothing else.
*Editing* is §M25, because the two fail differently — a panel showing a mode it cannot change is
honest, and one offering a change it cannot make is not.

What each backend reports differs, and the panel says so rather than filling a gap: `sftp`'s
`ls -la` and FTP's Unix `LIST` carry a real mode plus an owner and group **as the server spelled
them** (text, never resolved against this Mac's `getpwuid`); an archive carries whatever `bsdtar`
prints, which is names for a tar and bare numbers for a zip, and nothing at all for a directory the
archive omitted; and S3 and FTP's DOS/IIS dialect report **no mode, owner or group whatsoever**, so
those rows are absent and a note explains why. `FileEntry.permissions` is optional for exactly this
reason — the two backends with no mode used to synthesize `0o755`/`0o644`, which was invisible only
because nothing drew it. No remote listing carries an ACL, an extended attribute, an access time or
a birth time, so those are limits rather than gaps. A marked set that is not all local is refused,
because the bulk panel is an editor.

<sup>uu</sup> A vault is an encrypted disk image that macOS mounts as a volume, so it is a *local*
thing by construction; `hdiutil` cannot attach one over SFTP, FTP or S3. Copying the image file to a
server and back works today and is an ordinary transfer.

<sup>xx</sup> Not the remote reason: a virtual listing has no directory of its own, and a manifest
needs one — it is written *beside* the files it covers. The rows themselves are ordinary files, so
the same gesture works from the folder they actually live in.

<sup>aaa</sup> The marked set is brought down first, as one queued job with a determinate bar, Stop
and per-item failures, and the script is handed the copies (PLAN.md §M24 Slice 5). What makes it
more than a hand-off is the other direction: each copy is **watched**, so a script that rewrites its
argument — `exiftool -overwrite_original`, `sips`, a formatter — has that save carried back to the
server or repacked into the archive, through the machinery F4 already uses. Four limits, and none of
them is about the transfer. A **folder** that is not on this disk is not a target, for the hand-off's
own reason. A panel that is not a folder on this disk exports **no `DIRNEX_CURRENT_DIR`** — the
process runs in the folder holding the first file it was handed, and a script can test for the
variable exactly as it already tests for `DIRNEX_OTHER_DIR` — so a `combined` script with nothing
marked, which acts on the directory rather than on files, refuses there; that is what makes a results
tab and the Trash *limited* rather than a plain yes, and an **S3 account** pane a no, since its rows
are buckets and a bucket is a folder. Anything the script *creates* is not carried anywhere: only the
files it was handed are watched. And a member of a **nested** archive is handed over but not watched,
for the reason F4 gives it — its own bytes are already a temp copy, so a repack has nowhere to land.

## 6. Transfer behaviour

Where the local disk has no equivalent, the row is about how close a remote transfer feels to a
local one.

| Functionality | Local | Cloud mount | Archive | SFTP | FTP | S3 | S3 acct |
|---|---|---|---|---|---|---|---|
| Determinate byte progress, downloading | yes | yes | n/a | yes | yes | yes | n/a |
| Determinate byte progress, uploading | yes | yes | n/a | **yes, limited**<sup>jj</sup> | yes | yes | n/a |
| Resume an interrupted transfer | n/a | n/a | n/a | yes | yes | yes | n/a |
| Split one file over several connections | n/a | n/a | n/a | yes | yes | yes | n/a |
| Multipart upload for very large files | n/a | n/a | n/a | no<sup>vv</sup> | no<sup>vv</sup> | yes | n/a |
| Stop actually stops the bytes | yes | yes | yes | yes | yes | yes | n/a |
| Server-side copy (bytes never touch this Mac) | yes<sup>kk</sup> | yes<sup>kk</sup> | n/a | **no**<sup>ll</sup> | **no**<sup>ll</sup> | yes | n/a |
| Duplicate a file inside one account | yes | yes | n/a | yes, limited<sup>ll</sup> | yes, limited<sup>ll</sup> | yes | n/a |
| Conditional write (nobody overwrote it meanwhile) | n/a | n/a | n/a | yes, limited<sup>mm</sup> | yes, limited<sup>mm</sup> | yes | n/a |
| Certificate / host-key trust prompt, saved | n/a | n/a | n/a | yes | yes | yes | yes |
| Credentials in the Keychain, never in `argv` | n/a | n/a | n/a | yes | yes | yes | yes |

<sup>jj</sup> `sftp` prints no progress meter to a spawned process, and no flag changes that
(measured in six configurations over a 1 GiB transfer). A **download** watches its own destination
file grow, so it is exact; an **upload** has no observable at all and reports its byte count once,
at the end.

<sup>kk</sup> An APFS clone, which is instant and costs no bytes.

<sup>ll</sup> Neither backend uses a copy verb — their `copyFile` *is* an upload or a download — so
a duplicate inside one account, or a copy between two accounts, is staged through this Mac
(`RelayCopy`), costing the file's size in temp space and moving the bytes twice. Correct, and slower
than it looks. **One qualifier, unmeasured:** `sftp(1)` on macOS 26 (OpenSSH 10.2p1) documents a
`copy` / `cp` command, "only supported by servers that implement the `copy-data` extension". Nobody
here has asked a real server whether it does, which is where PLAN.md §M25 opens; `RelayCopy` stays
the answer for every server that does not. FTP has no such verb at all.

<sup>mm</sup> S3 sends `If-Match`; SFTP and FTP re-`stat` before uploading and tell you if the
file changed since it was fetched, which is a narrower window and not a guarantee.

<sup>vv</sup> S3 splits a large upload into parts that fail and retry independently; the other two
send one stream, so a transfer that dies late resumes from wherever `-C -` or `put -a` can pick it up
rather than from a part boundary (PLAN.md §M25, smaller than a milestone).

---

## Where remote still feels unlike local

Every **"no"** and **"yes, partially"** cell above that is *ours* to close is scheduled in
[PLAN.md](../PLAN.md) §4, as **M24** (every local-only feature, on a file that is not local) and
**M25** (what a remote write carries, and what a remote delete costs), with the cells too small for
either listed beside them. This file is the status; the plan is the work. Nothing that has already
shipped is argued here — a closed gap is simply a changed cell, and why it changed is in
[HISTORY.md](HISTORY.md).

What is **not** scheduled, because it cannot be closed from here — these are the "yes, limited"
rows, and the app is already as close as the technology permits:

- Content search and Finder-tag search on a server: both need every file's bytes or its xattrs.
- Exact FTP timestamps: `LIST` stamps are year-less, zone-less and on the server's clock, and
  `curl` cannot send `MLSD`.
- Atomicity of an S3 prefix rename or delete: it is N copies and N deletes, whoever writes it.
- Upload progress over SFTP: `sftp` prints no meter to a spawned process, in any configuration.
- Per-item download percentages from macOS's cloud providers, and sync status in Google Drive's
  mirror mode: neither is exposed to anyone but Finder.
- Put Back inside the iCloud trash, or for a Finder delete on Box: the origin is an opaque provider
  reference with no path in it.
- Live change notifications from any remote protocol: SFTP has no `inotify`, FTP has no verb, and
  S3 has no session to hold one open on. A poll is not a notification, and nothing can make it one.
