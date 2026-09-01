# What works where

Every user-facing capability against every kind of location Dirnex can open, as of
**2026-08-31** (M0–M26 shipped). The purpose is the parity question:
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
| **yes, partially** | Done, and the gap **could** be narrowed to look more local. What is left of the parity backlog is the short list at PLAN.md §4 ▸ *Still open*. |
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
| Live auto-refresh when it changes elsewhere | yes | yes | yes<sup>d</sup> | yes, limited<sup>f</sup> | yes, limited<sup>f</sup> | yes, limited<sup>f</sup> | yes, limited<sup>f</sup> | n/a | yes |
| Folder size on `Space` / `⌥⇧⏎` | yes | yes | yes | yes, limited<sup>e</sup> | yes, limited<sup>e</sup> | yes, limited<sup>e</sup> | n/a | yes | yes |
| Size visualization bars (`⌃B`) | yes | yes | yes | yes<sup>nn</sup> | yes<sup>nn</sup> | yes<sup>nn</sup> | yes<sup>nn</sup> | n/a<sup>nn</sup> | n/a<sup>nn</sup> |
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
so repacking it under the same name is picked up — and since 2026-09-01 the pane **asks by itself**:
it watches the archive file through an FSEvents stream carrying
`kFSEventStreamCreateFlagFileEvents`, in list and tree mode alike, so a `.zip` rewritten in another
window reaches the rows with no gesture. The flag is the whole of it — a file path without it
reports the path appearing and disappearing and **not** a rewrite in place. There is no watcher on
the members, and there cannot be one: what changed is the container, and the container is what is
watched.

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
rather than the cursor's, where the `Space` total above needs one. That is what used to gate the mode
to the local disk, and it was two different mistakes. An **archive** never cost anything — its whole
table of contents is already in memory (5.8 µs a directory, against the local disk's 33 µs) — and it
was gated with the rest by accident. On a **server** the cost is real and is now bounded twice: the
sizer asks the backend for the whole subtree before walking it, which for SFTP is one exec and for S3
one delimiter-less listing, and whatever cannot be answered that way runs under one allowance shared
by the entire column rather than one per row. Measured in the app against a real `sshd`: **9 sessions
for the whole column, against 149** with the exec channel withdrawn. A row the allowance never
reached carries the same marker and tooltip a `Space` walk that gave up does, rather than a dash that
would read as "still measuring". FTP's shortcut is the weakest of the three and still helps: it
cannot move the work to the server, so it makes the same one `LIST` per directory, but it makes a
whole level of them over one login instead of one connection apiece.<sup>ss</sup> On a virtual
listing whose rows live in a dozen different folders "share of this directory" has no referent
whatever it would cost, which is why those two still read n/a.

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
| Copy **inside one account**, without the bytes crossing this Mac | n/a | n/a | n/a | yes, limited<sup>bbb</sup> | **no**<sup>bbb</sup> | yes | — | — | — |
| Copy / paste `⌘C` `⌘V` | yes | yes | yes<sup>j</sup> | yes | yes | yes | no<sup>h</sup> | yes, partially<sup>k</sup> | yes, partially<sup>k</sup> |
| Drag and drop, inside Dirnex | yes | yes | yes, partially<sup>j</sup> | yes | yes | yes | no<sup>h</sup> | yes, partially<sup>k</sup> | yes, partially<sup>k</sup> |
| Drag **out** to Finder and other apps | yes | yes | **no**<sup>j</sup> | yes, partially<sup>k</sup> | yes, partially<sup>k</sup> | yes, partially<sup>k</sup> | no<sup>h</sup> | yes, partially<sup>k</sup> | yes |
| Drag **in** from Finder and other apps | yes | yes | **no**<sup>j</sup> | yes | yes | yes | no<sup>h</sup> | no<sup>k</sup> | no<sup>k</sup> |
| New Folder `F7` | yes | yes | no | yes | yes | yes | yes, limited<sup>l</sup> | no | no |
| New / Edit File `⇧F4` | yes | yes | no | yes | yes | yes | n/a | no | no |
| Rename `F2` | yes | yes | no | yes | yes | yes, limited<sup>i</sup> | no | yes | no<sup>m</sup> |
| Multi-rename `⇧F2` | yes | yes | no | yes | yes | yes, limited<sup>i</sup> | no | yes | no<sup>m</sup> |
| Delete `F8` → Trash | yes | yes, limited<sup>o</sup> | n/a | n/a | n/a | n/a | n/a | yes | n/a |
| Delete `F8` → permanent (confirmed) | yes | yes | yes, limited<sup>n</sup> | yes | yes | yes | yes, limited<sup>l</sup> | yes | yes |
| Put Back (restore from Trash) | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | yes, limited<sup>o</sup> |
| Undo `⌘Z` | yes | yes | yes, limited<sup>qq</sup> | yes, partially<sup>p</sup> | yes, partially<sup>p</sup> | yes, partially<sup>p</sup> | yes, partially | yes | no |
| Background queue, progress bar, Stop | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| Per-file conflict dialog | yes | yes | yes | yes | yes | yes | n/a | yes | yes |
| Preserve permissions / dates / xattrs on copy | yes | yes | yes, limited | yes, limited<sup>q</sup> | yes, limited<sup>q</sup> | n/a<sup>q</sup> | n/a | yes | yes |
| Copy a symlink as a symlink | yes | yes | yes | yes, limited<sup>pp</sup> | n/a<sup>pp</sup> | n/a | n/a | yes | yes |
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

<sup>n</sup> Deleting an archive member **rewrites the archive**. No Trash — but it is
reversible: ⌘Z swaps the container back (▸ <sup>qq</sup>), and the confirmation says which
it will be before it runs.
Top-level archives only.

<sup>o</sup> Two halves, and they meet on a cloud mount. **Put Back** works for anything Finder
trashed to `~/.Trash`, a volume's `.Trashes`, or a Google Drive mount's `.Trash`, and — since M26
Slice 4 — for anything **Dirnex** trashed to any of them, the iCloud trash included. What it
**cannot** do is put back an item *Finder* deleted out of a provider domain, or anything trashed
before that slice shipped: those origins are opaque provider references with no path in them (on
Box a Finder delete does not land on this Mac at all — it goes to Box's server-side trash), and
the flow says so by name rather than guessing at a folder. **F8 on a cloud mount** was broken
outright until M26 — `FileManager.trashItem` refuses every item inside a File Provider domain
(Dropbox, OneDrive, Box, Google Drive, iCloud alike) whenever the app is responsible for itself,
which is every launch that is not from a terminal (PLAN.md §M26, docs/NOTES.md). Dirnex now
performs that move itself, into the same trash `trashItem` would have used, so **F8 works on all
five**; and since **Slice 5** it writes the `ptbL`/`ptbN` record too, so **Finder's own Put Back
works on such an item exactly as it does on one Finder deleted** — measured live in Finder's menu,
with a neighbouring item in the same trash and no record as the control. **Slice 4's own store
stays** and answers where that write cannot happen (no Full Disk Access, a read-only trash) and
for an item *Finder* deleted out of a domain; Put Back merges the two with Finder's record winning
wherever it exists, and where both speak they were written from the same origin. Such an item is
therefore restorable with **⌘Z** (which rides the landing path Dirnex journaled rather than
Finder's record, and is unaffected in every case above), with Dirnex's Put Back, *and* with
Finder's. An ordinary local delete is untouched and keeps Finder's own. What still refuses is what
the *account* refuses: a Google Drive mount root is `dr-x------`, so deleting `My Drive` itself
answers `EACCES` — which M26 Slice 3 stopped wording as a Full Disk Access problem, since that
grant does not gate `~/Library/CloudStorage` and the permission being refused is the one set in
the cloud account.

<sup>p</sup> Rename, move, New Folder and — since 2026-09-01 — an **attribute change** are journaled
and reversed through the backend, so they undo remotely (▸ <sup>tt</sup> for what that last one can
and cannot promise, since sending old values back is a write a server may refuse). A **permanent delete is not reversible anywhere** — which is every remote delete,
since no remote backend has a Trash. That is a **decision rather than a gap**: inventing one — a
managed `.dirnex-trash/` prefix and a sidecar naming the origin — was weighed and declined
(PLAN.md §7, 2026-08-29), because it costs one cheap rename over SFTP and FTP against N copies plus
N deletes on S3, and a Trash that exists on some backends and not others is a worse promise than
none. What stands in for it is the confirmation, which says outright that nothing can be undone.

<sup>q</sup> **The mode and the modification time are carried in both directions; extended
attributes and ACLs are not, and cannot be** — neither protocol has anywhere to put them, which is a
limit rather than a gap (PLAN.md §M25 Slice 2). What each side manages differs, and what it *cannot*
manage is reported rather than passed over in silence, which is the half that matters: a copy that
quietly drops a mode is indistinguishable from one that kept it until somebody inspects the
destination.

Over **SFTP** an upload rides `put -p`, which carries the nine `rwx` bits and both timestamps exactly
and silently drops set-uid, set-gid and the sticky bit; a mode holding one of those adds a corrective
`chmod` as a second line in the **same** batch, so it costs no extra connection. There is no batch
verb that sets a time, so an SFTP upload's mtime rides `-p` or not at all. Over **FTP** there is no
preserve flag: the mode goes as `SITE CHMOD` and the time as `MFMT`, which is exact and UTC-anchored
(RFC 3659) — the coarse, year-less stamp FTP is known for belongs to `LIST`, not to the protocol.
Both are extensions a server need not implement, and a refusal is latched per connection so no later
file pays to find out again.

A **download** is bounded by neither, because it lands on this machine: `chmod` and `utimes` always
work, so it carries whatever the source's listing reported even on a connection whose server has
refused to keep anything.

S3 remains `n/a`: it has no settable mtime, no permissions and no symlinks at all (PLAN.md §M21), and
a row that reports no mode is *absent* rather than dropped — the distinction the whole carry turns
on, since folding the two together would make every S3 copy claim damage it did not do.

**What a copy could not keep is said on the status line under the pane** (PLAN.md §M25 Slice 5b),
never in a dialog, and it is a per-*job* answer rather than a per-connection one — the connection's
accumulator spans its whole life, so reporting that would name the previous transfer every time. The
routine case is why it is not modal: a duplicate **inside one SFTP account** takes the server-side
`cp` route, which carries no timestamp at all, so every such copy drops the modification time by
construction and says so. A local copy carries everything and says nothing.

<sup>bbb</sup> A duplicate within one SFTP account is the **server's** work: OpenSSH's `copy-data`
extension gives `sftp` a real `cp` — measured against a real `sshd`, 64 MiB in **0.09 s** for the
whole session against 0.5 s to stage the same file down and back up over *loopback*, where the relay
is flattered by there being no network. It is "limited" because a server need not advertise the
extension and nothing can ask in advance: the client refuses on its own
(`Server does not support copy-data extension`, reproducible with `sftp-server -P copy-data`), the
refusal is latched for the connection, and every later copy is staged through this disk exactly as it
always was (PLAN.md §M25 Slice 3).

What it costs is the **modification time**, and it is reported rather than quietly dropped: `cp`
stamps the copy with *now*, and `sftp`'s batch language has no verb that could set one — so this is
the one route where the staged fallback is *more* faithful than the fast path. The mode is carried in
full, including the special bits `cp` drops, by the corrective `chmod` riding the same batch. That
`chmod` is sent for an ordinary mode too, because an occupied destination is overwritten **in place**
and keeps its own mode.

FTP has no copy verb of any kind — `curl` offers a download and an upload — so a duplicate inside one
account is staged, whatever the two paths are. S3 duplicates inside a bucket, and between two buckets
the same key and service can name unambiguously, with `x-amz-copy-source`.

<sup>pp</sup> Over SFTP the target is read from the SSH **exec** channel, so it works on an account
that has one and is refused by name on an account that does not (PLAN.md §M25 Slice 4). `sftp`'s own
`ls -la` prints the kind (`l`) with no ` -> target` and the batch language has no `readlink`, so
there is nothing in the protocol to fall back on — an account confined by `ForceCommand
internal-sftp` therefore keeps saying it cannot copy that link rather than writing a broken one.
It degrades per connection, like §M22's search walk: one exec answers a whole directory of links
(77 ms on loopback, the same for one link or twelve), and a refusal is remembered for that
connection. FTP has no symlink verb at all.

<sup>qq</sup> Every gesture that rewrites a browsed archive — F8 delete, ⌘V/F5/F6 add, an edited
member saved back — is one undo step. There is no diff to journal (the container is repacked whole),
so what is kept is the container as it was, and ⌘Z **exchanges** the two files: the archive takes the
old bytes and the copy takes the rewrite, which is what makes ⇧⌘Z free and costs no second copy. The
limit is the storage decision behind it — Dirnex keeps up to 5 GB of these, oldest given up first, so
an archive larger than the whole budget is rewritten and *not* undoable, and every confirmation sheet
says which of the two it will be before it runs. Undo refuses rather than proceeds if the copy has
since been given up, or if anything else has changed the archive in the meantime. On one APFS volume
the copy is a `clonefile` and consumes nothing: what it really costs is that the archive's old bytes
are not reclaimed until the record leaves the journal.

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
| Synchronize Directories | yes | yes | **no**<sup>x</sup> | yes, limited<sup>x</sup> | yes, limited<sup>x</sup> | yes, limited<sup>x</sup> | n/a | n/a<sup>x</sup> | n/a<sup>x</sup> |
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
The upload is a **queued job** since 2026-09-01 — a bar, a Stop and a place in the queue's ordering,
where it used to be a `Task` the window started and forgot — and several saves arriving together are
one job with one confirmation (▸ <sup>aaa</sup>).

<sup>v</sup> A member of a **writable** (top-level) archive only; saving repacks the archive,
preserving encryption and hidden names. A nested archive's member cannot. Several members saved
together are **one repack**, whatever folders they came from inside it (since 2026-09-01), with one
question for the archive rather than one per file.

<sup>w</sup> Both sides are brought down first, as one queued job with a determinate bar and a Stop
(PLAN.md §M24 Slice 4) — `ByteComparator` still only ever sees real local paths, and the diff tool is
handed the copies, which keep their real names. Two limits, both about what the pair *is*: a folder
has no contents to compare, and a diff tool has to be installed before anything is fetched (the tool
question is asked first, so a Mac with none pays for no download).

<sup>x</sup> A side stopped having to be on this disk at PLAN.md §M25 Slice 5c, and what it gains is
comparison by **size**, which is honest anywhere. Comparing by **timestamp** is withdrawn the moment
either side is remote, and for three different reasons: `sftp`'s `ls -la` drops the seconds and, past
about six months, the whole time of day (measured 41 617 s from the truth); FTP's `LIST` stamp is
year-less, zone-less and on the server's clock; and S3's `LastModified` is exact and is the *upload*
time, which nothing can set. Two sides of one coarse dialect are no better — two files thirty seconds
apart list as the same minute, so a mirror would skip the one that changed.

Comparing by **contents** works anywhere since §M25 Slice 5d, and it is the one comparison a coarse
listing cannot make dishonest — bytes are bytes. The scan is two phases over **one** walk: the walk
classifies every row by size, the pairs whose bytes decide the answer are named from that (both sides
present, both regular files, the same size), and *those* are fetched as one queued job with a
determinate bar and a Stop before anything is read. So the confirmation names the real total, a pair
a size mismatch already settled costs no transfer, and `ByteComparator` still only ever sees real
local paths. Two things it does **not** buy: a difference it finds is still never ranked newer or
older, because reading bytes says nothing about which came later and the clock is the same unusable
stamp; and an evicted cloud placeholder is refused rather than downloaded, because a tree sweep is
not a file anybody pointed at and its bytes cannot be weighed before they are asked for.

Three more things follow from the widening. The scan asks each side for its whole subtree first
(`VFSBackend.subtreeListing`), so a server walks its own tree in one command instead of a connection
per directory — 76 ms against 1010 ms for seventeen directories on loopback — and an account with no
exec channel falls back to the walk. A **delete** says what it will really do: no remote backend has
a Trash, so those items are named as permanent up front rather than promised the Trash and quietly
erased. And a direction whose destination cannot receive files is withdrawn rather than offered and
failed inside the queue. An **archive** stays refused because a sync deletes and deleting a member
rewrites the container — undoable since 2026-09-01 (▸ <sup>qq</sup>), but as one step over the whole
container rather than per item, which is not what a sync's per-file report means; an S3 **account** pane is a connection and
not a folder; a virtual listing has no directory to synchronize.

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
| Server-side walk (one request, not one per folder) | n/a | n/a | n/a | yes, limited<sup>dd</sup> | n/a<sup>ss</sup> | yes | n/a | — | — |
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

<sup>ss</sup> **n/a rather than "no": there is no route to a yes.** FTP has neither an exec channel
nor a delimiter-less listing, and no recursive verb `curl` can send, so its walk is one `LIST` per
directory and always will be — but since 2026-09-01 it is one **connection per level** rather than
one per directory, which is nearly all of the cost. One `curl` carrying a multi-section config lists
a whole level over a single login; measured against a real server over a 159-directory tree, 527
entries and identical results either way: **160 invocations and 159 logins against 4 and 4**,
11.264 s against 0.404 s with the server 50 ms away. `LIST -R` was retired at the
probe — `curl` sends it, but the servers that honour it are the minority and none reachable from
this Mac does, so the fast path would have shipped unverified.

## 5. Metadata and macOS integration

| Functionality | Local | Cloud mount | Archive | SFTP | FTP | S3 | S3 acct | Results | Trash |
|---|---|---|---|---|---|---|---|---|---|
| Get Info: permissions, flags, dates | yes | yes | read-only<sup>tt</sup> | mode editable<sup>tt</sup> | mode + date editable<sup>tt</sup> | read-only<sup>tt</sup> | read-only<sup>tt</sup> | yes<sup>ee</sup> | yes<sup>ee</sup> |
| Get Info: ACLs, extended attributes | yes | yes | n/a | n/a | n/a | n/a | n/a | yes<sup>ee</sup> | yes<sup>ee</sup> |
| Privilege escalation for a root-only change | yes | yes | n/a | n/a | n/a | n/a | n/a | yes | yes |
| Finder tags (`⌃T`, tag dots) | yes | yes | n/a | n/a | n/a | n/a | n/a | yes<sup>ee</sup> | yes<sup>ee</sup> |
| Cloud sync badges | yes | yes | n/a | n/a | n/a | n/a | n/a | yes | yes |
| Create / verify checksum files | yes | yes | verify only<sup>ff</sup> | yes, limited<sup>ff</sup> | yes, limited<sup>ff</sup> | yes, limited<sup>ff</sup> | n/a | no<sup>xx</sup> | no<sup>xx</sup> |
| Open in Terminal | yes | yes | n/a | **no**<sup>gg</sup> | n/a | n/a | n/a | no | no |
| Run a user script | yes | yes | yes<sup>aaa</sup> | yes<sup>aaa</sup> | yes<sup>aaa</sup> | yes<sup>aaa</sup> | no<sup>aaa</sup> | yes, limited<sup>aaa</sup> | yes, limited<sup>aaa</sup> |
| Pack `⌥F5` (create an archive) | yes | yes | yes<sup>hh</sup> | yes<sup>hh</sup> | yes<sup>hh</sup> | yes<sup>hh</sup> | n/a | yes<sup>hh</sup> | yes |
| Encrypted archives / hidden member names | yes | yes | yes | yes<sup>hh</sup> | yes<sup>hh</sup> | yes<sup>hh</sup> | n/a | yes<sup>hh</sup> | yes |
| Create / unlock an encrypted vault | yes | yes | n/a | n/a<sup>uu</sup> | n/a<sup>uu</sup> | n/a<sup>uu</sup> | n/a | no | n/a |
| Saved connection in the sidebar | n/a | n/a | n/a | yes | yes | yes | yes | n/a | n/a |
| Pin to Favorites / Places menu | yes | yes | no | yes, partially<sup>ii</sup> | yes, partially<sup>ii</sup> | yes, partially<sup>ii</sup> | yes, partially | no | n/a |

<sup>ee</sup> Gated per **row**, not per pane. A trashed file is an ordinary local file, so it
carries a mode, an ACL and tags like any other; a search hit is whatever it happens to be, and since
M22 it can be on a server — `AttributesRoute` then opens the *remote* panel for that row and the tag
and ACL rows are absent, exactly as they would be in the pane the hit lives in. Asking the pane
instead of the row would offer a control from the wrong account.

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
whatever happens. **A folder that is not already here is staged whole and packed** since 2026-08-30:
it is brought down by `CopyEngine` — F5's own engine pointed at a temp directory, which is what the
old refusal told the user to do by hand — and the staged tree is swept when the job finishes rather
than cached, since a directory's staleness cannot be read off a size and a date. **Every pack is a
queue job** since the same day, plain or encrypted, so the build and the upload both have a bar and a
Stop: `bsdtar` prints no progress of its own, but it answers **SIGINFO** with the bytes it has read,
which is the quantity the walk measures in advance (docs/NOTES.md ▸ bsdtar). One limit is left and it
is not ours: a **browsed archive cannot receive** an archive, because `ArchiveBackend` advertises
`.read` alone and writing into one is a repack.

<sup>ii</sup> A pin on a connected account **carries where to reconnect** — a
`StoredServerEndpoint`, the field `PersistedTab` already used — so it survives a quit and opens the
account again from any of the four surfaces that can pick one: the ⌘F popup, a sidebar row, that
row's Open item, and Go ▸ Places. The credential rules are the restore's, because it is the restore's
code: an account needing a password it no longer has comes back disconnected rather than prompting.
What stays partial is the *gesture* — a remote folder is pinned from the menu, never by dragging it
into the sidebar (PLAN.md §M8's deliberate omission) — and a pin made before the field existed, which
carries no way back and fails as it always did, naming the account.

<sup>tt</sup> Read-only since M24 Slice 7: a row that is not on this Mac opens
`RemoteAttributesController`, which states **what the listing actually reported** and nothing else.
*Editing* arrived at M25 Slice 5a and is narrower than reading (below), because the two fail
differently — a panel showing a mode it cannot change is honest, and one offering a change it
cannot make is not.

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

**Writing** (PLAN.md §M25 Slice 5a) is narrower than reading and is decided per connection: SFTP
offers the **mode** and no date, because `sftp`'s batch language has no verb that sets a time at all;
FTP offers **both**, because `SITE CHMOD` carries a mode and `MFMT` writes an exact UTC-anchored
modification time — the one place FTP is the richer protocol. An account that answers "no such
command" has the control withdrawn for the rest of that connection. Owner and group are offered
**nowhere**: `chown`/`chgrp` need a numeric id and `sftp`'s `ls -la` prints names, and a remote
`chgrp` clears set-uid and set-gid as a side effect. A saved change is **read back**, and the panel
redraws from what the item carries rather than from what was sent — `sftp`'s `chmod` reports success
for a mode the server did not store, measured (docs/NOTES.md ▸ sftp / ssh). It has been **undoable
since 2026-09-01**, and ⌘Z there is a *second write* rather than a rewind: the previous values go
back through the same `applyMetadata` Save used, are read back and weighed the same way, and a
server free to refuse the first change can refuse this one — which the panel's note says outright.
What goes on the stack is what the read-back proves **moved**, so a mode that landed as something
other than what was asked is still reversible, while a modification time the transport refused is
not journaled at all: a listing cannot measure a timestamp (`ls -la` rounds to the minute, `LIST` is
zone-less), so the time rests on the verb's own answer and declining to journal one costs a ⌘Z that
does nothing where journaling a wrong one would write an old date over a field the save never
touched.

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
server or repacked into the archive, through the machinery F4 already uses. Since **2026-09-01** the
**both** directions are gathered, so a script that rewrote forty files carries them back together
rather than one at a time: the remote ones as one queued run with a combined bar and a Stop, asking
**once** about whatever the pre-upload checks found, and the archive ones as **one rewrite per
archive** with one question each — where before, forty members meant forty full repacks of the same
container, each extracting and re-compressing everything the last had just written. Four limits, and
none of them is about the transfer. A **folder** that is not on this disk is not a target, for the hand-off's
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
| Multipart upload for very large files | n/a | n/a | n/a | **yes**<sup>vv</sup> | **no**<sup>ww</sup> | yes | n/a |
| Stop actually stops the bytes | yes | yes | yes | yes | yes | yes | n/a |
| Server-side copy (bytes never touch this Mac) | yes<sup>kk</sup> | yes<sup>kk</sup> | n/a | yes, limited<sup>ll</sup> | **no**<sup>ll</sup> | yes | n/a |
| Duplicate a file inside one account | yes | yes | n/a | yes, limited<sup>ll</sup> | yes, limited<sup>ll</sup> | yes | n/a |
| Conditional write (nobody overwrote it meanwhile) | n/a | n/a | n/a | yes, limited<sup>mm</sup> | yes, limited<sup>mm</sup> | yes | n/a |
| Certificate / host-key trust prompt, saved | n/a | n/a | n/a | yes | yes | yes | yes |
| Credentials in the Keychain, never in `argv` | n/a | n/a | n/a | yes | yes | yes | yes |

<sup>jj</sup> `sftp` prints no progress meter to a spawned process, and no flag changes that
(measured in six configurations over a 1 GiB transfer). A **download** watches its own destination
file grow, so it is exact; an **upload** has no observable at all and reports its byte count once,
at the end — unless it is **split**, in which case it reports once per part as each one lands, which
is the finest granularity this protocol allows (<sup>vv</sup>).

<sup>kk</sup> An APFS clone, which is instant and costs no bytes.

<sup>ll</sup> **SFTP has one and FTP has none.** A duplicate inside one SFTP account is the
server's own work through OpenSSH's `copy-data` extension, measured against a real `sshd` at M25
Slice 3 — what it costs is the modification time, and the rest of the detail is under
<sup>bbb</sup>. A server that does not advertise the extension makes the client refuse, the refusal
is latched for that connection, and the copy is staged instead. FTP has no copy verb at all, so its
`copyFile` *is* an upload or a download. Everything the fast path cannot serve — a refusing server,
and **every** pair of ends on two different backends, which no server-side verb can address — is
staged through this Mac (`RelayCopy`), costing the file's size in temp space and moving the bytes
twice.

<sup>mm</sup> S3 sends `If-Match`; SFTP and FTP re-`stat` before uploading and tell you if the
file changed since it was fetched, which is a narrower window and not a guarantee.

<sup>vv</sup> Above 32 MiB an SFTP upload is cut into parts of 16–32 MiB, **four sent at once**,
each under a hidden name beside the destination; the server joins them with one `cat` over the exec
channel and the file is renamed into place only once the size it reports matches what was sent.
Measured 2026-09-01 through the shipped backend against a real `sshd` behind a 2 MB/s-per-connection
throttle: **16.92 s in one stream against 4.73 s in four parts** for 32 MiB, byte-identical. Three
costs, all stated rather than waved at — the parts are staged one batch at a time on this disk
(128 MiB at most), the join needs the destination's own size again in scratch **on the server** until
it finishes, and the file is created by `cat` rather than by `put -p`, so the mode is applied
afterwards and the **times are reported lost**, the same trade the server-side `cp` makes
(<sup>bbb</sup>). An account confined to the `sftp` subsystem has no exec channel and cannot join
anything: it is asked once, before a byte is sent, and every upload on that connection takes the
single stream — measured, the file still lands byte-identical, in order, with nothing left behind.
What a **failed part** costs is the transfer, not the part: the run is abandoned, the server swept,
and the file sent again in one stream. S3's multipart has no retry unit either — it aborts the upload
and throws — so this is parity rather than a shortfall, and it is the one thing PLAN.md's wording for
this cell described that neither backend does.

<sup>ww</sup> **FTP cannot, and this is a measurement rather than an assumption.** `curl -C <offset>`
on an upload sends **`APPE`**, not `REST`+`STOR`, so it can only ever append at the end. A raw
`REST <offset>` + `STOR` *does* write at an offset — but only into a file that already exists at that
length (`550 No such file or directory` otherwise), and FTP has no way to make one without sending the
bytes: `ALLO` is advisory (`202 No storage allocation necessary`) and there is no `SITE TRUNCATE`.
Two concurrent `APPE`s to one file interleave arbitrarily, with nothing naming which half is which.
So the only route sends the file twice, which is worse than sending it once — see *Where remote still
feels unlike local*.

---

## Where remote still feels unlike local

The two milestones this list was written for have closed: **M24** (every local-only feature, on a
file that is not local) on 2026-08-28 and **M25** (what a remote write carries, and what a remote
delete costs) on 2026-08-29, both archived in [HISTORY.md](HISTORY.md). What is left of the **"no"**
and **"yes, partially"** cells that are *ours* to close is the short list at [PLAN.md](../PLAN.md)
§4 ▸ *Still open* — the cells that were too small to be a slice of either. This file is the status;
the plan is the work. Nothing that has already shipped is argued here — a closed gap is simply a
changed cell, and why it changed is in [HISTORY.md](HISTORY.md).

What is **not** scheduled, because it cannot be closed from here — these are the "yes, limited"
rows, and the app is already as close as the technology permits:

- A server-side *walk* over FTP: there is no recursive verb `curl` can send, so the tree costs one
  `LIST` per directory whoever asks. What was closeable — the connection around each of them — was
  closed on 2026-09-01.
- A **split upload over FTP**: the protocol has no way to write at an offset into a file that is not
  already there at full length, and no way to create one without sending the bytes. The full
  measurement is under <sup>ww</sup>; SFTP's own split, which *is* possible because `cat` over the
  exec channel can join what `sftp` cannot write in place, landed on 2026-09-01.
- Content search and Finder-tag search on a server: both need every file's bytes or its xattrs.
- Exact FTP timestamps: `LIST` stamps are year-less, zone-less and on the server's clock, and
  `curl` cannot send `MLSD`.
- Atomicity of an S3 prefix rename or delete: it is N copies and N deletes, whoever writes it.
- Upload progress over SFTP: `sftp` prints no meter to a spawned process, in any configuration.
- Per-item download percentages from macOS's cloud providers, and sync status in Google Drive's
  mirror mode: neither is exposed to anyone but Finder.
- Put Back for an item **Finder** deleted out of a provider domain — the iCloud trash keeps no
  `.DS_Store` at all, and on Box such a delete does not land on this Mac. The origin is an opaque
  provider reference with no path in it. Dirnex's *own* deletes there are covered (M26 Slices 4–5,
  which also give Finder's Put Back back for them).
- Live change notifications from any remote protocol: SFTP has no `inotify`, FTP has no verb, and
  S3 has no session to hold one open on. A poll is not a notification, and nothing can make it one.
