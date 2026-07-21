# Engineering notes

Hard-won gotchas that cost real debugging time, distilled so they don't have to be
rediscovered. Chronological progress lives in [HISTORY.md](HISTORY.md); this file is the
durable residue — facts that stay true after the pass that found them is forgotten.

Keep it curated. A note earns its place by having burned an hour or by being invisible
at build time.

## Working rhythm

- **Probe the real thing before writing any Swift.** Capture real `git` / `sftp` / `xattr`
  bytes, or measure the real syscall, and design from what was observed. This has caught a
  wrong assumption in *every* pass that used it: the `-z` rename pair is reversed; `sftp`'s
  `ls` is not GNU's; Finder's tag colour indices are not its display order;
  `intercellSpacing.width` is 17 pt, not 2–3; the terminal drawer needs no shell-integration
  snippet because `proc_pidinfo` already knows. The one pass that assumed a format
  (`SFTPListingParser`) had to be reworked against reality.
- **Core first, then the app.** A slice opens with pure, tested, purely-additive `DirnexCore`
  files (app untouched, no rebuild) and lands in a second pass that wires the app. PLAN.md §2:
  if it touches bytes it lives in the core and has tests.
- **Verify live before claiming done.** A throwaway harness compiled against the real core
  driving the real binary, or the built app driven by computer-use. Let the OS be the
  independent judge — Finder read our tags back; Apple's own getter checked our writer.
- **Lint and format on every change**: `swiftformat --lint .`, `swiftlint --strict`,
  `swift test`.
- **Ask before a fork in the road.** Big design choices (SMB mounter vs. protocol backend;
  SwiftTerm vs. a TC-style command line) get a recommendation, not a survey.
- **Leave changes uncommitted.** Oleg commits, in terse one-liners.

## Live verification

- **Fully quit a running Dirnex before relaunching.** `open` re-focuses the stale process, so
  new menu items and behavior silently don't appear. A Debug build's code lives in
  `Dirnex.debug.dylib`, not the thin executable — grep the dylib to confirm new code actually
  compiled in. `xcodebuild` writes to `~/Library/Developer/Xcode/DerivedData/`, not the repo's
  `build/`.
- **For pixel and geometry work, probe the live view hierarchy — never eyeball a screenshot.**
  Measuring a captured screenshot by eye produced a *wrong* diagnosis twice in one session (a
  "13 pt gap" that was really 11, then an offset attributed to the wrong cause). The screenshot
  path is downsampled below 1x, so it does not resolve points. What works: a temporary `NSLog`
  in the view's `draw(_:)` dumping frames and `convert(_:to:)`-ed rects, with the binary run
  straight from a shell
  (`.../Dirnex.app/Contents/MacOS/Dirnex > log 2>&1 &`) to capture stderr.
- **SF Symbols carry ~1.25–1.5 pt of transparent margin inside their box**, so a symbol is
  never flush with its view's edge. Measure the ink, not the box.
- **A screenshot only verifies what you actually look at.** A bug once sat visible in a pass's
  own verification shots and went unnoticed.
- **Synthetic Escape is not delivered into the app** during computer-use — it is swallowed
  before the responder chain *and* before a raw `NSEvent` local keyDown monitor. Any
  Escape-driven behavior needs a physical key press to verify. Letters arrive as `keyCode = 0`
  with the character set, so route typed input by character, not keyCode.
- **A transparent overlay from another app can gate every mouse click.** LanguageTool for
  Desktop did this for four passes; keyboard input still reached Dirnex, which masked it.
  Quitting the overlay app restored mouse verification.

## Swift 6 and concurrency

- **Block/token `NotificationCenter` observers can't be torn down from a `nonisolated deinit`**
  — the `[NSObjectProtocol]` token array is non-Sendable. Use selector-based observers plus
  `removeObserver(self)`.
- **An `FSEventStream` must hold an *unretained* `Unmanaged` pointer to its watcher.** Retained
  is a cycle that never stops. The non-capturing C callback recovers the watcher and calls an
  immutable `@Sendable` closure; `stop()` is idempotent and runs from `deinit`.
- **Two-phase init forbids passing `self` as a delegate before `super.init()`.** A stored
  controller that needs `self` as its delegate becomes `var`, assigned once after `super.init()`.
- **A protocol witness that must be `nonisolated`** (e.g. `SPUUpdaterDelegate`) can either read
  thread-safe state directly — a `nonisolated static` reading `UserDefaults` is provably safe
  whatever the caller's threading — or funnel through
  `Thread.isMainThread ? MainActor.assumeIsolated : Task { @MainActor }` when the framework
  documents main-thread-only delivery.

## Testing

- **`#expect(optionalNumeric == arithmeticExpression)` can report a false failure** even when
  both operands display as equal. Confirmed on Swift 6.3 / Xcode 26:
  `let v: Int64? = 1_048_576; #expect(v == 1024 * 1024)` FAILS, while `#expect(v == 1_048_576)`
  and the non-optional form both pass. The RHS arithmetic resolves to a different numeric type
  than the optional's wrapped type. Fix: precompute the RHS as a typed literal, or unwrap with
  `try #require` first. Don't chase it as a bug in the code under test.
- **A `mutating` call or `coll.allSatisfy(\.x)` can't sit inside `#expect(...)`** — hoist the
  result into a `let` first.
- **Assert Objective-C selectors by name when a framework dispatches by selector.** Swift may
  import a delegate callback under a different Swift signature (Sparkle's choice callback comes
  in as `updater(_:userDidMake:forUpdate:state:)`, not `userDidMakeChoice:`). A drifted Swift
  signature silently stops being the witness; `#expect(x.responds(to: #selector(...)))` catches
  it, and `#selector` only compiles when the mapping is right.
- **`xcodebuild` does not forward shell env to the test runner** — gate live integration suites
  on the existence of a *file*, not an environment variable. Prove such a suite is genuinely
  live by making it fail with bad credentials rather than skip.
- **A date parsed from a year-less `ls` stamp lands at local midnight** (the formatter sets no
  zone), so read `.day` in the local calendar or the day shifts by one.

## AppKit

- **`NSTitlebarAccessoryViewController` clips to its container's fixed frame.** A hardcoded
  width sized for three glyphs laid a fourth one out fine, with `isHidden == false`, and it was
  simply invisible. Derive each accessory container's width from what it holds, and pin each row
  at the edge it is anchored to, so a badge that comes and goes extends into empty title bar
  instead of shifting the controls already there. Only launching catches this.
- **Collapsing a split-view sidebar that holds first responder strands keyboard focus on the bare
  window.** When the focused view is hidden by the collapse, AppKit drops first responder to the
  `NSWindow` itself rather than to a sibling — so every pane goes grey and *Tab cannot recover it*,
  because Tab is a pane key that only fires while a pane is first responder (there is no window-level
  key-view loop to fall back on). `NSSplitViewController.toggleSidebar(_:)` is the one funnel both
  the menu/palette (`toggleSidebar:` selector) and the titlebar button call, so a subclass overriding
  it catches every collapse; capture whether the sidebar held focus *before* `super` (deterministic —
  a post-hoc KVO observer races the first-responder move) and hand focus to a pane after. Only
  reachable once the sidebar itself can hold focus, which it could not before M8.
- **A background `reloadData` while an inline rename field is open destroys the edit.** An
  FSEvents refresh or a directory-size total tears the shared field editor out of its cell and,
  because `NSTableView` recycles cell views, strands it on the `..` row — the rename silently
  vanishes and focus jumps. Guard both refresh sites and replay the owed refresh when editing
  ends. Only reproducible with a *real* FSEvents change landing during the edit window, not via
  synthetic F2 → type → Enter.
- **macOS delivers ⌘A → `selectAll:` into a field editor only via a "Select All" menu key
  equivalent.** The text system does not self-bind ⌘A, so with no such menu item ⌘A is a dead
  no-op in every text field.
- **The shared `QLPreviewPanel` (⌘Y) is key while open**, so arrows navigate its preview items,
  not the table. `QLPreviewView` is not opaque and `init(frame:style:)` is failable — an
  embedded preview needs an opaque backing or the covered view bleeds through. It also only
  wires magnify-to-zoom for single-page PDFs, so multi-page PDFs route to a PDFKit `PDFView`.
- **Right-click menu items must capture their paths at build time** into `representedObject`,
  and entry-vs-`..` must be decided from the clicked row, not a cursor flag — a right-click on a
  marked row leaves that flag stale.
- **Two colours separated only by alpha will invert somewhere.** A progress track and its ink
  drawn in the same colour at 0.25 alpha made an *empty* bar read as the heaviest row on screen,
  because the track owns the full column width where the ink may own a point. No test catches
  this; it was caught in a screenshot.
- **`installSortedModel` swaps the model; `reloadEverything` is what puts it on screen.** A refresh
  path that installs and returns leaves the pane drawing the rows it already had — no error, no log
  line, just a model and a screen that disagree. Found live when an Empty Trash left the pane listing
  two files that had just been erased. The real-directory refresh ends with
  `reconcileCursorFromTable` → `installSortedModel` → `reloadEverything`; a new refresh path needs
  the same tail.
- **A filtered-out row must be omitted, not zeroed.** Rendering an excluded folder as its
  filtered total gives "Zero KB · 0.0 %", which reads as *"measured, and empty"* — a claim about
  the folder where the truth is a claim about the question. Drop such rows from the projection
  entirely, including from any pending-work set, or a row with no total is pending forever and
  gets re-queued on every render.

## Lint ceilings and file splitting

SwiftLint enforces `file_length` 500 and `type_body_length` 250, and the big AppKit controllers
ride right at them. New panel code goes in a `PanelViewController+X.swift` extension;
`CommandCatalog` and `PathBarView` are near the type-body limit too.

- **Swift `private`/`fileprivate` do not cross files**, so members a companion file touches must
  widen to internal.
- **Worse:** a `private` stored `tableView` in a type that also conforms to `NSTableViewDelegate`
  will, in the *other* file, resolve to the delegate *method* `tableView(_:viewFor:row:)` instead
  of the property — producing "value of type '…' has no member 'clickedRow'" until the property
  widens to internal.
- Adding a menu-item `case` to `validateMenuItem` trips cyclomatic-complexity 15; extract a
  helper. Three-member tuples trip `large_tuple`; `.count == 0` trips `empty_count`.

## External CLI tools

The project deliberately shells out to system tools instead of taking library dependencies
(`bsdtar` over libarchive, `sftp`/`ssh` over swift-nio-ssh). Non-hermetic subprocess I/O lives
in the **app**; pure parsing lives in the **core**, behind an injected transport so it tests
against a fake.

### bsdtar

- **Each extract member is a shell-glob pattern, not a literal** — a name containing `* ? [`
  must be backslash-escaped or it goes unmatched. The extracted file keeps its real name, so the
  extracted-location path must *not* be escaped. Create-side args are literal paths, the opposite.
- **`--exclude` matches any trailing subpath with no anchoring**, so deleting an exact member by
  repacking with `--exclude` over-deletes: `docs/api/x.md` also drops `outer/docs/api/x.md`, and a
  bare root name hits every depth. An exact archive delete must extract-whole-then-repack by real
  filesystem path.
- **`-a` misreads the zip-family aliases `.jar` and `.cbz` as TAR** — force `--format zip` on
  create and repack. All other browsable suffixes infer correctly.
- **`-tvf`'s date column omits the year for recent files**, so a `MMM d HH:mm` parse yields year
  2000. Set `defaultDate = now` on year-less formats and roll the year back if the result is in
  the future.

### sftp / ssh

- **`sftp` batch `ls -la` is not GNU `ls -l`**: the link-count column is `?`, names are printed
  as full paths (reduce to last component), symlink targets are not shown, and there is **no
  `ls -d`** — stat a directory via the `.` self-row of its own listing.
- **`sftp`'s `ls` follows symlinks**, so classify an item for recursive delete from its *parent
  listing*, not a stat, or a link-to-directory deletes the target's contents. There is no `rm -r`;
  walk depth-first then `rmdir`.
- **`sftp -b -` forces `BatchMode=yes`, which kills the password prompt** — password auth cannot
  use `-b` and must run interactively over piped stdin. Interactive mode exits 0 on a failed
  command, so scan stderr rather than trusting the exit code.
- **`SSH_ASKPASS_REQUIRE=force`** (OpenSSH ≥ 8.4) makes ssh call the askpass program with no TTY,
  which is why password auth needs no PTY. Pass the secret only in the child's environment —
  never argv, never disk. Offer **only** `PreferredAuthentications=password`:
  `keyboard-interactive` hangs ~60 s on a wrong password under askpass (macOS PAM).
- **Drain both pipes concurrently** or a two-pipe deadlock wedges the process, and bound the wait
  — some appliances hold the SSH channel open after every command and never return.

### The Trash

- **`FileManager.trashItem` on an item already in a trash reports success and does nothing** — it
  hands back the path it was given. So "move to Trash" inside the Trash is a silent no-op that looks
  like it worked. Dirnex withdraws the `.trash` capability for any path inside a trash, which turns
  F8 there into the confirmed permanent delete via the existing degradation, and `LocalBackend`
  refuses such a call outright.
- **iCloud Drive has a *third* trash, and deletes from it go nowhere else.**
  `~/Library/Mobile Documents/.Trash` — a **sibling** of the containers, not a child of
  `com~apple~CloudDocs`, and with no `<uid>` subdirectory (the container is already per-user).
  Finder merges it into the one Trash it shows, so a merged listing that only knows about `~/.Trash`
  and `<volume>/.Trashes/<uid>` reports an **empty Trash** for a folder the user just deleted and can
  see in Finder. Reading it needs Full Disk Access (its parent is TCC-gated), and it is constructed
  rather than discovered, like the volume trashes. **Put Back cannot work there**: it keeps no
  `.DS_Store`, and the origin rides on the item as `com.apple.clouddocs.private.trash-parent-bookmark`
  — an opaque `com.apple.CloudDocs/<UUID>/<hash>` provider reference with no path in it.
- **`<volume>/.Trashes` is mode `d-wx--x--t` — unlistable even by its owner** — while
  `<container>/<uid>` inside it is a normal `drwx------`. A volume's trash must be *constructed* and
  opened directly; enumerating the parent to discover it always fails. (Same leaf-not-parent shape as
  the iCloud container.)
- **`FileManager.url(for: .trashDirectory, appropriateFor: <volume>)` cannot enumerate trashes.** It
  throws `NSFeatureUnsupportedError` (3328, "the feature is not supported") for a volume that merely
  has nothing trashed on it yet, and only starts answering once the directory exists — so trusting it
  reads as "external volumes have no Trash," a wrong answer in the quiet direction. It resolves `/`,
  `/System/Volumes/Data` and the `/Volumes/<name>` root symlink all to `~/.Trash`, which is why the
  boot volume is skipped when merging (or the home trash is listed two or three times).
- **Put Back has no API, and the data is in the trash folder's `.DS_Store`.** Probed: a trashed file's
  only xattr is `com.apple.provenance`, `mdls` exposes nothing, and every plausible `URLResourceKey`
  spelling (`NSURLTrashOriginalPathKey` and friends) returns an empty dictionary. The origin is a
  `ptbL` (folder) / `ptbN` (name) pair of `ustr` records in the `.DS_Store` — read by `DSStoreReader`,
  interpreted by `TrashPutBack`. Three things that bite:
  - **`FileManager.trashItem` writes the records too**, so items Dirnex trashed are restorable, not
    just Finder's.
  - **The recorded folder is relative to the trash's own volume, and is spelled two ways.** A volume
    trash writes a leading slash (`/deep/`); `~/.Trash` writes none (`Users/oleg/`), and when *Finder*
    did the trashing it goes through the boot volume's data firmlink
    (`System/Volumes/Data/private/tmp/…` for `/private/tmp/…`).
  - **`ptbN` is not the name in the trash.** A collision renames the newcomer — `alpha.txt` landed as
    `alpha.txt 13-12-35-977.txt` — and only `ptbN` still knows what to restore it as.
  - Every block offset inside a `.DS_Store` is **4 bytes short** of a file position (the allocator
    numbers from past the leading alignment word); that one detail is the difference between a
    working parse and garbage.
- **A virtual location that carries `.write` will light up every write command.** The merged Trash
  needs `.write` so `deleteStrategy` resolves to `.permanent` — and that alone enabled New Folder and
  Paste in a Trash tab, over flows that then bail out at their own `isVirtualDirectory` guard. A
  capability granted for *one* operation is read by all of them; gate the ones that need a real
  directory on the directory, not on the capability.
- **Rebuilding can revoke Full Disk Access**, because the build is ad-hoc signed and the TCC grant is
  keyed to the binary — so a Trash click after an `xcodebuild` raises the onboarding sheet even though
  the toggle still looks on in System Settings. Re-granting needs a *relaunch* to take effect (the
  running process keeps the old denial), and the **first** click after that relaunch can still fail
  while TCC settles; try twice before concluding anything. Read the live state with
  `sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db "select auth_value from access where
  service='kTCCServiceSystemPolicyAllFiles' and client='com.dirnex.Dirnex'"` — `2` granted, `0` denied.
- **`~/.Trash` needs Full Disk Access** (`NSCocoaErrorDomain` 257 without it), and **"Put Back" has
  no public API**: the original path lives in the trash folder's `.DS_Store`, not in an xattr — a
  trashed file carries only `com.apple.TextEncoding` / `com.apple.provenance`.

### iCloud Drive

- **There is no `.<name>.icloud` stub any more.** Probed 2026-07-21 with `brctl evict`: an evicted
  file keeps its **real name and real `st_size`** with `st_blocks == 0` and `SF_DATALESS` (0x40000000)
  in `st_flags`. The `.icloud` stub is the pre-Catalina/iOS shape, and assuming it would have sent a
  slice chasing a name-rewriting bug that does not exist. The flag rides along in the `stat` a listing
  already does, so knowing costs nothing — but **reading one byte materializes the file and blocks**
  (measured 1.1 s for 200 KB), so every byte-touching sweep (recursive sizer, content grep,
  byte-compare) has to check it or it silently downloads the user's whole cloud drive.
- **Finder's iCloud Drive is two directories, not one.** `com~apple~CloudDocs` holds the loose files;
  every iCloud-enabled app's `Documents` folder is a **sibling** under `~/Library/Mobile Documents`,
  not a child. Only the CloudDocs leaf is TCC-carved-out — the parent and the app containers need
  Full Disk Access, which is why the M8 row could browse without the grant and the merge cannot.
- **The app name and icon live in `bird`'s cache, not in the container and not in LaunchServices.**
  `~/Library/Application Support/CloudDocs/session/containers/<bundle-id>.plist` carries
  `BRContainerName`, `BRContainerLocalizedNames` and `BRContainerIsDocumentScopePublic` (the cached
  form of the app's `NSUbiquitousContainers` declaration); the sibling `<bundle-id>/` directory holds
  the icon PNGs. Three traps: `NSWorkspace.icon(forFile:)` on such a folder returns the **generic
  folder icon** (byte-identical to `~/Documents`'), so it looks like it works; the public-scope flag
  appears as both `1` and `true`, in the same file; and the container directory name is the bundle id
  with **dots replaced by tildes**, so the plist's own inner keys (`com.apple.iWork.Pages`) are not
  it. LaunchServices is the wrong source regardless — half these apps are iOS-only and not installed.
  `URLResourceValues.localizedName` on the `Documents` folder *does* return the app name, but it needs
  the real iCloud item, so it can't be unit-tested and the plist is used instead.
- **The name cache and the container it names are gated separately.** Without Full Disk Access,
  `~/Library/Application Support/CloudDocs/session/containers` is refused while
  `~/Library/Mobile Documents/com~apple~Pages/Documents` still *lists* perfectly — observed live on a
  freshly rebuilt (hence TCC-revoked) binary, where a path bar reading the plist for the app's name
  fell back to `com.apple.Pages` in front of a folder it had just enumerated. `URLResourceValues
  .localizedName` on that folder answers "Pages" and needs no grant, so it is the fallback; it can't
  be unit-tested (it only answers for a real iCloud item), which is why it is injected into
  `ICloudLocation.trail` rather than called from the core.
- **Which containers Finder lists is not derivable.** 17 declare public scope here; Finder shows 7.
  Nothing separates the sets: not mtimes, not emptiness (two of the seven are empty), not install
  state, not `bird`'s `client.db` (`app_libraries`, per-zone item counts, tombstones). Don't spend an
  afternoon on it a second time — Dirnex approximates with "public scope and not empty" and PLAN.md
  §M9 records why.

### Google Drive (and every other `CloudStorage` provider)

- **`~/Library/CloudStorage` lists without Full Disk Access**, unlike `~/Library/Mobile Documents`.
  Every File Provider sync client macOS 12+ hosts puts its mount there as
  `<Provider>-<account>` — `GoogleDrive-someone@gmail.com` — so one provider-agnostic scan covers
  Google Drive, Dropbox, OneDrive and Box, browsed by the ordinary `LocalBackend`. **Split the name
  at the *first* hyphen**: an account label is an email address and those contain hyphens, so
  splitting at the last one hands back a truncated address and a provider that doesn't exist.
- **A signed-in Drive account can mount completely empty, and that is not a bug in your scan.**
  Probed 2026-07-21: both accounts on this Mac mounted with only `.Trash`,
  `.shortcut-targets-by-id` and `.tmp` — no `My Drive` — while DriveFS's own
  `~/Library/Application Support/Google/DriveFS/<id>/metadata_sqlite_db` listed 83 real items
  (`items` table: `id`, `local_title`, `is_folder`). The roots had not been provisioned; Google's
  setup dialog was still sitting on its `ROOTS_PANE`. The authority is **`fileproviderctl dump`**,
  whose `<s:root … child:N>` line is the OS's own count — it read `child:3` for Drive against
  `child:53` for iCloud, which is how you tell "not provisioned" from "readdir didn't materialize".
  Neither a Finder `open` nor an `ls` populates it.
- **The `<account> - Google Drive` folders in the home directory are symlinks to the same mounts**,
  not separate content. Worth knowing before chasing them as a second source — and their naming is
  Google's own precedent for putting the account *before* the product name.
- **The mount root is not the content root**: it holds `My Drive` and nothing else visible (plus
  `.Trash` / `.shortcut-targets-by-id` / `.tmp`). An account with Shared drives gets a second child,
  so "descend into the mount's single visible child" is the rule that reaches the files without ever
  hiding one — not "look for `My Drive`", and not a fixed depth.
- **In *mirror* mode `My Drive` is a symlink**, not a directory: it points out to `~/My Drive`
  (or `~/My Drive (<account>)` for the second account), which is where the real bytes live. Streaming
  mode has no such indirection. Anything classifying that entry must follow the link —
  `FileManager.fileExists` does, reading the file type does not — or mirror-mode users get a mount
  that appears to hold nothing but a dead link.
- **A File Provider mount is not a volume and posts no `NSWorkspace` mount notification.** Connecting
  a second account is a *directory appearing inside* `~/Library/CloudStorage`, so FSEvents on that
  parent is what notices it; the volume notifications that refresh the Volumes section never fire.
  Watch the parent, not the mounts — watching the mounts wakes the watcher on every file Drive syncs.
- **A `.gdoc` stub contains no URL**, despite every description (including this repo's own plan)
  saying it holds one. Probed 2026-07-21, the whole file is
  `{"":"WARNING! DO NOT EDIT THIS FILE! …","doc_id":"1aOaGA2IB…","resource_key":"","email":"…"}` —
  note the warning sits under an **empty-string key**. Opening one means *constructing* the URL from
  `doc_id` plus the type implied by the extension (`.gdoc` → `document`, `.gsheet` → `spreadsheets`,
  `.gslides` → `presentation`), not reading a `url` field that isn't there.

### git

- **`git status --ignored=traditional` already collapses every ignored directory to one row**,
  including an ignored dir nested inside an untracked one, so ignore data comes free with the
  status snapshot — no second `git` run, no `check-ignore`. Note that **`.git` appears in no
  `status` output at all** (it needs an explicit rule, which also prunes nested repos' metadata),
  and a nested repository is a single `?? nested/` whose own rules are invisible to the outer
  snapshot.
- `.ignored` does **not** roll up to ancestors but **is** inherited by descendants.

## Release pipeline

See [RELEASING.md](RELEASING.md) for the procedure. The traps:

- **`github.run_number` is per-workflow-FILE, and under `workflow_call` the `github` context is
  the CALLER's.** A beta released via `beta.yml` therefore draws a fresh counter starting at 1
  while stable sits at ~5, silently breaking the monotonic-`CFBundleVersion` invariant the update
  channels rest on. It fails in the *quiet* direction: a beta stamped below the installed stable
  is simply never offered, so the channel looks empty rather than broken. Every build is now
  floored at `max(run_number, highest <sparkle:version> in the published feed + 1)` — the feed is
  the one number line all releases share, whatever started them. For the same reason,
  `github.event_name` reads as the caller's under `workflow_call`; use **`github.ref_type`**.
- **Sparkle ranks by `CFBundleVersion`**, which must stay globally monotonic *across* channels or
  an old beta outranks a new stable.
- **One "no" to Sparkle's first-run prompt disables update checking forever, silently.** The prompt
  writes `SUEnableAutomaticChecks = 0` and never asks again, so no scheduled check ever runs, no
  `didFindValidUpdate` ever fires, and the titlebar indicator stays dark through every release —
  while the feed, the channel opt-in and the indicator code are all provably correct. Found by
  reading the *installed* app's defaults
  (`defaults read com.dirnex.Dirnex | command grep '^ *SU'`), which is the first thing to check
  when an update does not surface; `SULastCheckTime` there is the proof a check actually ran.
  Dirnex therefore does not depend on Sparkle's scheduler at all: `AppUpdater` runs its own
  `checkForUpdateInformation()` — the *probing* check, which fetches the real appcast through the
  same delegate (so `allowedChannels` still applies) but presents **no UI whatsoever** — at launch
  and every 8 h, and only lights the indicator. That leaves the user's answer to the prompt intact
  (nothing pops up uninvited) while making the badge honest. Two Sparkle constraints the probe has
  to respect: it is a no-op while `sessionInProgress`, so a probe landing during a user-initiated
  check must still count as taken or a zero-delay retry spins; and skipped versions are not found,
  which is what keeps `UpdateAvailability.afterUserChoice(.skip)` from being re-raised on the next
  probe.
- **A timer does not fire while the Mac sleeps**, so an 8 h probe armed before a lid close is hours
  overdue on wake and still waiting for its original fire date. The catch-up is
  `NSApplication.didBecomeActiveNotification` re-asking the schedule, not a shorter interval.
- **A `GITHUB_TOKEN`-pushed tag does not re-trigger `on: push`** — which is exactly why the beta
  workflow calls `release.yml` as a reusable workflow instead of pushing a tag and hoping the tag
  trigger fires.
- Pick the next beta number with `sort -n` (`beta.10` → `beta.11`, not `beta.2`) and check out
  with `fetch-depth: 0`, or no tags are visible and every beta comes out `.1`.

## Distribution and licensing

- **Apache 2.0 §6 does not protect the app icon.** §6 withholds *trademark* rights; the icon PNGs
  are copyrighted artwork inside the repo, and the license grants "the Work" — everything in it.
  Absent an explicit carve-out the license would have *granted* forks the right to ship the icon.
- **The carve-out lives in `NOTICE`, and that is the whole trick:** §4(d) obliges every
  redistributor to carry `NOTICE` forward, making it the one file that propagates *by license
  terms* into derivative works. A carve-out stated only in the README travels exactly as far as
  the README — which a forker rewrites first.
- The fork checklist in [TRADEMARKS.md](../TRADEMARKS.md) includes **the Sparkle appcast URL**;
  that's the row with teeth, since a fork left pointing at our feed would push official Dirnex
  builds onto its users.

## macOS system gates

- **App Intents only register from a Team-ID-signed app in a standard install location.** Two
  independent gates, neither visible at build time: `linkd` logs
  `Unable to get teamId from <bundle id>` and drops the connection for an ad-hoc-signed local
  build; and even a Developer-ID-signed bundle under `DerivedData` gets no indexing transaction at
  all. Only after copying to `/Applications` does the log show `Registering "<bundle id>" in the
  metadata store` → `Interpolating AppShortcuts`. The `Metadata.appintents/extract.actionsdata`
  bundle is emitted correctly regardless, so every build-time signal looks green. Don't debug the
  intent code — check `codesign -dv --verbose=4` and the location, then
  `log show --last 2m --predicate 'process == "linkd"'`. To verify locally, re-sign **all** nested
  Mach-O first (a missed `*.debug.dylib` crashes launch with "different Team IDs"). Release
  pipelines satisfy both gates automatically, so this is a local-verification problem only.

## Design lessons that generalize

- **Adding a second closure parameter silently re-points every bare trailing closure.**
  `size(of:using:) { true }` rebound to a new `excluding:` rather than the existing
  `isCancelled:`; only the differing arity made it fail loudly instead of inverting behavior.
  Label both at every call site.
- **A notification that says "go re-read the cache" can lose results already computed.** One
  pane's FSEvents watcher invalidating every total on its root-to-leaf line produced a measured
  546 invalidations in two minutes — faster than a scan publishes — wiping freshly walked results
  with nothing to ever re-deliver them. Carry the results *in* the notification; the cache then
  goes back to being a pure latency optimization.
- **Churn that stale on-screen values were hiding becomes a permanent blank** the moment a feature
  legitimately clears them. The storm above was pre-existing and invisible for exactly that reason.
- **To browse a second VFS backend without touching every `self.backend` site**, wrap them in a
  `CompositeBackend` that dispatches on `path.backend`. A per-tab backend field is a much larger
  refactor.
- **A per-directory scan silently produces nothing for a virtual listing.** The cloud-badge scan
  gates on `isCloudDirectory(directory)` — a real read on a real path — which is exactly right for a
  folder and answers `false` for a synthetic `icloud:`/`trash:` container, so the merged iCloud
  listing rendered no badges at all while every row in it was a cloud item. The fix is not to widen
  the gate but to carry the fact **in the listing**: `FileEntry.isDataless` came in on the `stat` the
  listing already did, and backs the scan up wherever the scan cannot run. Same shape as carrying
  results *in* a notification instead of telling a cache to go re-read.
- **A merged listing needs a watcher even though it has no directory** — and FSEvents gives it for
  free: `FSEventStreamCreate` takes an *array* of paths, so one stream covers every trash (or every
  iCloud container) the listing was gathered from. Two things are easy to get wrong. The pane's
  single watcher follows the **active tab**, so a merged tab sitting in the background is watched by
  nothing and must re-gather when it comes back — the watcher alone is not enough. And the re-gather
  it triggers must not rebuild the stream, or every event tears down the thing that delivered it;
  rebuild only when the *set of sources* actually changed.
- **A virtual listing that names a *place* wants the opposite defaults from one that names a query.**
  The Trash and search results open a tab per click, refuse writes, and send an opened folder to the
  other pane — all correct for something you visited once. iCloud Drive is browsed repeatedly, so
  the same machinery had to be told, three times over, to behave like a folder instead: navigate in
  place, resolve writes to the real directory underneath (`writeDirectory`), and walk *into* and
  *out of* its rows within the same pane. Each of those was a one-line exception at a site that was
  never written as a policy — which is the tell that "results" was two concepts wearing one flag.
- **A view state that one listing *overrides* leaks the moment the next listing inherits it.** A
  results tab forces `showHidden` on (`ResultsPresentation.showsHidden`), and every "carry the
  current pane's settings over" site read it back out of the model — so clicking Home out of a
  search tab listed the whole dot-file wall with the eye toggled off. Sort inherits correctly
  because nothing overrides it. Re-derive an overridden setting from its source of truth
  (`AppPreferences.showHidden`) rather than from the model that overrode it.
- **A disambiguator placed at the end of a label does not disambiguate.** Two Google Drive accounts
  rendered as `Google Drive (someone@gmail.com)` came out of the real sidebar as the *identical*
  string — "Google Drive (ol…" — because the pane tail-truncates at its actual width. The unit test
  passed: the two strings genuinely differ, just not in any pixel the user sees. Front-load the
  varying part (`someone@gmail.com — Google Drive`) and assert on a *prefix* rather than on
  inequality, so the test fails for the same reason the screenshot did. Only a screenshot caught it.
