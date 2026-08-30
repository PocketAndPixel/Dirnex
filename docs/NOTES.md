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
  `ls` is not GNU's; Finder's tag color indices are not its display order;
  `intercellSpacing.width` is 17 pt, not 2–3; the terminal drawer needs no shell-integration
  snippet because `proc_pidinfo` already knows. The one pass that assumed a format
  (`SFTPListingParser`) had to be reworked against reality.
- **When a format's rule is undocumented, the oracle is a corpus that already depends on it.** There
  is no specification for GitHub's heading anchors, so M18's slug rule was scored against **2282
  hand-written `](#…)` links** in 211 real `.md` files sitting on this Mac — a table of contents
  somebody wrote by copying anchors GitHub had actually produced is a recorded answer, whatever the
  question. It inverted the obvious implementation twice: an **allow-list** (letters, digits, space,
  `-`, `_`) resolved 25 anchors `github-slugger`'s published block-list regex does not, all of them
  emoji headings; and **nothing is trimmed**, so `## 🐛 Bugs` genuinely anchors as `#-bugs` and
  tidying that leading hyphen away breaks every document carrying one. Both are invisible at build
  time and read as *our* bug when a user's link lands nowhere. The same corpus handed over the
  duplicate rule's real shape — a file linking to `#all`, `#all-1` **and** `#all-2`, which is a
  counter that steps past a collision the author wrote, not "append the count".
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

- **A tab seeded with `defaults write -string` is silently not restored, because `TabPersistence`
  reads `data(forKey:)`.** The pane falls back to Home, the app looks perfectly healthy, and nothing
  logs — so the gesture under test runs against a *local* row and reports whatever a local row does.
  Seed with `-data <hex>` (`python3 -c "print(open(f,'rb').read().hex())"`). Cost two runs on M24
  Slice 7, and the tell was a **false witness**: the throwaway server's log showed sessions, which
  were the probe's own earlier `sftp` calls rather than the app's — this file's own rule that a
  session count is not evidence, met from the other side. Read the pane's *backend* instead, which
  one `NSLog` in the gesture answers outright.
  - Order matters as much as the encoding: **Dirnex rewrites its session on quit**, so a seed written
    while the app is still running, or before a quit that has not finished, is overwritten by the
    state being torn down. Quit, wait for the process to be gone, *then* seed, then launch.

- **Fully quit a running Dirnex before relaunching.** `open` re-focuses the stale process, so
  new menu items and behavior silently don't appear. A Debug build's code lives in
  `Dirnex.debug.dylib`, not the thin executable — grep the dylib to confirm new code actually
  compiled in. `xcodebuild` writes to `~/Library/Developer/Xcode/DerivedData/`, not the repo's
  `build/`.
- **When no gesture can reach a state, drive the *reader* from outside through whatever seam it
  already reads.** M23 Slice 5 had to prove that pasting a row from inside a `.zip` really extracts
  and copies it in the running app, and the gesture is unreachable headlessly twice over: session
  restore is `.local`-only (`PanelViewController+Restore` — a tab cannot come back inside an
  archive), and nothing in the `.sdef` or `CommandBinding` *enters* one. What is reachable is the
  pasteboard: a 10-line `swift` script writes the byte-identical `com.dirnex.locations` payload
  naming an archive member onto the real general board, and
  `osascript … run operation "edit.paste"` then runs the whole shipped path — the split, the
  passphrase check, `bsdtar`, the `stat` back into local entries, the queue. It landed `one.txt`
  with the right bytes, left the sibling in the archive, and left a temp extraction holding exactly
  one file.
  - **The payload has to be minted by hand, not copied from the app**, which is the half that makes
    it evidence: what is being tested is the *reader*, so handing it something the writer produced
    would prove the two agree rather than that either is right (▸ the same rule this file states for
    the `--pinnedpubkey` digest walk).
  - Generalizes past pasteboards to any feature whose input crosses a documented boundary — a
    pasteboard flavour, a URL scheme, a defaults key, a file the app watches. **Ask what the code
    under test reads, not how a person would get there**, and the unreachable half of a milestone is
    usually reachable after all.

- **Mint by hand only what is under test; mint the scaffolding through the type's own encoder.** The
  entry above says a probe payload has to be hand-written because the *reader* is what is being
  measured — and the corollary is the half that saves time. A live run usually needs several stores
  seeded, and only one of them is the subject: M24 Slice 5 seeded a persisted tab (whose endpoint was
  minted through `JSONEncoder` on the core's own `StoredServerEndpoint`, first try) and the user-script
  store (hand-written, and wrong — `UserScripts` encodes as `{"scripts": […]}` rather than as a bare
  array, so the app read an empty store and the AppleScript verb answered *"is not a known Dirnex
  operation"*, which reads as the feature being unwired rather than as the fixture being wrong). Ask
  which store the claim is about; every other one is scaffolding and should be produced by the code
  that reads it.
  - **A throwaway that needs `DirnexCore` is a six-line `Package.swift`, not a `swiftc` invocation.**
    SwiftPM leaves no library artifact to link against — `-L .build/…/debug -lDirnexCore` fails with
    `library 'DirnexCore' not found`, and adding `-I Modules` first fails earlier on the
    `CArchiveShim` module map. A scratch package with `.package(path: "…/DirnexCore")` and
    `swift run` builds in seconds and gets the language mode right for free, which is the *other*
    trap this file records about `swiftc` defaults (▸ Swift 6 and concurrency, the delegate-witness
    probe compiled in Swift 5 mode).

- **When a gesture ends in a *sheet*, no sibling helps and the honest instrument is a checked-in live
  suite.** M24 Slice 3 got Share for free because it fetches before it presents, and Slices 4 and 5
  each found a verb with nothing to click. ⌥F5 has neither: the pack sheet is the *first* thing it
  does, everything under test happens after the Pack button, and `run operation "file.pack"` returns
  with a sheet on screen and nothing else. Putting the download *before* the sheet would have made it
  drivable and is the wrong product — a user who backs out of the name or the collision question must
  have paid nothing. So the live half went into the app test target beside the suites that were
  already there (`SFTPLiveIntegrationTests`'s config-file gate, so CI skips it), driving the real
  transport, the real `bsdtar` and the real mount. That is *better* than a throwaway script and worth
  reaching for sooner: it is repeatable, it is reviewed, and it does not evaporate when the shell
  history does.
- **When a gesture ends in a menu you cannot click, look for its sibling that does not.** M24
  Slice 3 shipped two verbs over one selection and only one of them is drivable headlessly: Open
  With pops an `NSMenu` (a nested event loop — the AppleScript verb never returns), while **Share**
  fetches *before* it presents, so `run operation "file.share"` runs the whole chain — plan,
  confirmation decision, queued job, cache adoption, delivery — with nothing to click. Verified
  2026-08-27 against a throwaway `sshd`: two marked SFTP rows gave **two** `Accepted publickey`
  sessions and two copies under `DirnexRemote`, real names, right bytes. The same trick generalizes
  — ask which of the gestures sharing a code path has the *fewest* UI steps after the part under
  test, and drive that one.
  - **A session count is not evidence while a background poll is running.** The pane's remote
    refresh drifted the count by **four over ten idle seconds**, which swamps any single gesture, and
    setting the floor to 0 did not visibly quiet it. Measure the **delta across the gesture**, or
    better the thing only a fetch can produce: a file appearing under the temp root. That is what
    made "the Open With menu costs nothing" a measurement (0 copies before, 0 after) rather than a
    hopeful subtraction.
  - **"Nothing changed" cannot tell a cache hit from a gesture that did nothing**, which is the trap
    in the obvious second-run control. Delete **one** of the two copies and repeat: exactly one
    session, exactly that file back, the other untouched. One deletion turns an ambiguous null result
    into a positive one.
  - **A restored tab's cursor lands on the first row, which sorting puts on the folder** — so the
    first run measured the *refusal* of a remote directory instead of the transfer, and read as the
    feature not working. Seed `markedPaths` in the persisted tab to reach a marked set at all; and
    note that this made the refusal's own live check free, which is the half worth keeping.
  - The seed is `Dirnex.tabs.<pane>` holding a `PersistedTab` whose `endpoint` is a
    `ServerEndpoint.sftp` with `.key(identityFile:)` — no password, no Keychain, no prompt — and the
    app reconnects at launch since session restore learned to (▸ Design lessons). Back the domain up
    with `defaults export` first, and `ssh-keyscan` the throwaway host key into `known_hosts` or the
    connect raises a trust dialog that wedges a headless run; put both back afterwards.

- **For pixel and geometry work, probe the live view hierarchy — never eyeball a screenshot.**
  Measuring a captured screenshot by eye produced a *wrong* diagnosis twice in one session (a
  "13 pt gap" that was really 11, then an offset attributed to the wrong cause). The screenshot
  path is downsampled below 1x, so it does not resolve points. What works: a temporary `NSLog`
  in the view's `draw(_:)` dumping frames and `convert(_:to:)`-ed rects, with the binary run
  straight from a shell
  (`.../Dirnex.app/Contents/MacOS/Dirnex > log 2>&1 &`) to capture stderr.
- **SF Symbols carry ~1.25–1.5 pt of transparent margin inside their box**, so a symbol is
  never flush with its view's edge. Measure the ink, not the box.
  - **The corollary is that a gap constant copied from a symbol buys less space next to text.** The
    Git badge took the cloud badge's 3 pt leading gap and read visibly tighter beside a tag dot,
    because a glyph drawn as *text* has no such margin — the same number, ~1.5 pt less air. 5 puts
    the ink the same distance apart. Nothing catches this but looking at the two side by side.
- **A screenshot only verifies what you actually look at.** A bug once sat visible in a pass's
  own verification shots and went unnoticed.
- **An app-modal window runs the run loop in `.modalPanel`, so a `Timer.scheduledTimer` scheduled
  under it never fires.** `scheduledTimer` adds to `.default` only. Measured 2026-08-29 while driving
  the Synchronize sheet, which is `presentAsMovableWindow` and therefore app-modal: a 2 s probe timer
  simply never ran, twice, and read as the code under test doing nothing. `Timer(timeInterval:…)` plus
  `RunLoop.main.add(_, forMode: .common)` fires. The neighbouring fact from the same run: `tell
  application "Dirnex" to quit` is **refused** while such a window is up, so a script that quits,
  re-seeds and relaunches silently drives the *old* instance — `pkill` and wait for the process to be
  gone.

- **Synthetic Escape is not delivered into the app** during computer-use — it is swallowed
  before the responder chain *and* before a raw `NSEvent` local keyDown monitor. Any
  Escape-driven behavior needs a physical key press to verify. Letters arrive as `keyCode = 0`
  with the character set, so route typed input by character, not keyCode.
  - **`NSApp.postEvent` is the documented way in for a *monitor*, and it does not reach
    key-equivalent dispatch at all** — so it cannot verify a button's Escape or ⌘-key binding, and
    it fails in the quiet direction: the sheet simply stays open, which reads as a broken binding.
    Measured on a live `NSAlert` sheet, where a posted **Return** did not fire the default button
    either; that positive control is the whole finding, because without it the Escape run looked
    like a real bug in the code under test. The instrument that works is
    **`NSWindow.performKeyEquivalent(with:)` called directly** — it is the exact entry point
    `NSWindow.sendEvent` uses for a keyDown, so it measures the mechanism in question and leaves
    only "does a physical key reach the app" to the human. All four cases then behaved: Return →
    first button, bound Escape → last button, unbound → nothing.
  - **A field editor does *not* eat a button's Escape key equivalent.** Probed against a sheet whose
    accessory text field held first responder (the pack sheet's shape — `initialFirstResponder` is
    its name field): `performKeyEquivalent` returned `true` and the alert closed on the Cancel
    button. Key equivalents run ahead of `keyDown:`, so the field editor's own "revert the edit"
    never gets the key. Worth stating because the opposite is the natural worry, and it is the
    reason `enableEscapeToCancel` needs no carve-out for a sheet that opens with a field focused.
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
- **`Task.detached` is not a thread of its own — it is the *cooperative pool*, whose width is the
  machine's core count — so blocking inside one is spending a resource the whole process shares.**
  `FileOperationQueue` ran each synchronous engine in a detached task under a comment reading "run
  it detached so the actor stays responsive": true, and not the same claim. Each running job then
  held a cooperative worker for the length of the copy, and `OperationControl.checkpoint()` holds
  it **indefinitely** while the queue is paused — so a few concurrent jobs can occupy every
  cooperative thread the process has and stall `async` work with nothing to do with moving bytes.
  Send blocking work to a global `DispatchQueue` (`BlockingWork`) for exactly the property usually
  held against it: it overcommits, growing its thread count when its threads block, which is what
  the cooperative pool deliberately will not do.
  - **It fails as a *test* first, on someone else's machine, and reads as a broken feature.** The
    symptom was a CI release build failing on `"jobs sharing a volume run one at a time, in order"`
    — a queued job that simply never started within its 2 s wait. Nothing about the message points
    at threading, and it is invisible on a development Mac: the suite needed **three** cooperative
    threads to pass (the test's own blocking wait, the running job, the one starting), which 16
    cores always had spare and a CI runner did not. The same run's performance budgets showed the
    runner at roughly half the per-core speed, so "it is just slower" is the tempting and wrong
    reading.
  - **`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` is the instrument**, and it converts this from a
    flake into a measurement: forcing the pool to one thread failed all three scheduling tests on
    demand, and the fix made them green 3/3 — and 20× faster (6.6 s → 0.32 s), since what the old
    version spent was timeout. Reach for it whenever a concurrency test passes locally and fails on
    a narrower machine. The negative control is worth running in the same session: neutering
    `BlockingWork` back to an inline call failed six assertions immediately.
  - **The compiler catches the caller's half and not the callee's, which is why only one half of
    this shipped.** Swift 6 refuses `Thread.sleep`, `NSCondition.lock`/`unlock` and friends
    *directly* inside an `async` function ("unavailable from asynchronous contexts") — but a
    **synchronous helper** that blocks, called from async, compiles silently. That is exactly the
    shape the gate's `waitForStarted` had. When a wait must live in a test double, poll with
    `await Task.sleep`; the existing house rule under Testing said so already, for a different
    reason.
- **A handle that only exists *after* the work has started cannot be used to register a completion,
  and the race fails in the quiet direction.** `FileOperationQueue.enqueue` is an actor method that
  returns the job id and starts the job in the same call, so a caller doing `let id = await
  enqueue(…); completions[id] = handler` has a window in which the job can finish first — the report
  arrives at an id nobody is waiting on, and the gesture behind it simply never hears back. Nothing
  logs, nothing fails, and it is likeliest on the runs that matter least (a transfer refused on its
  first request) and rarest on the ones you test with.
  - **Pair the two halves instead of ordering them.** `MaterializeDeliveries` holds a waiting handler
    *and* an arrived report, and whichever lands second fires — so there is no ordering to get right
    at the call sites and no `await` anybody has to remember not to add. Twenty lines, and it is the
    only shape here that does not depend on how fast the job is.
  - It is worth one type rather than two dictionaries on the window controller: the pairing rule is
    the thing to keep in one place, and split across two properties it becomes a rule two call sites
    have to keep. (`BrowserWindowController` also sits near SwiftLint's body ceiling, which is the
    lesser of the two reasons.)
- **The app had the same bug 64 times, and the rule is that a `VFSBackend` call is *always* blocking
  — so `Task.detached` is never its home.** Audited 2026-08-20: 68 real `Task.detached` sites in the
  app against 5 `BlockingWork.run` ones, and 64 of the 68 blocked on a subprocess (19 — `bsdtar`,
  `hdiutil`, `git`, `mdfind`, `netfs`, `curl`), a remote transport (8), or filesystem/backend I/O
  (37). Every one of them held a cooperative worker for its duration, which on a remote backend is a
  network round trip: `DirectoryLoader.list` is 0.601–0.699 s per `ListObjectsV2` (▸ curl for S3), and
  a `CloudSyncStatusProvider` scan is 650–1000 µs *per row* inside a File Provider domain — 3–5 s of
  one worker for a 5000-row cloud folder.
  - **The pool's width really is the core count and really does not over-commit** — worth measuring
    once rather than citing. With 24 and then 64 concurrent blocking bodies on a 16-core Mac the peak
    in flight was **16** both times, for a task-group child and a `Task.detached` alike, and **1**
    under `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`; the same bodies through `BlockingWork.run` all ran
    at once (24 of 24). The two shapes are identical in this respect, so "detached" buys nothing.
  - **`BlockingWork.run` silently destroys `Task.isCancelled`, so a walk that reads it cannot be
    converted blindly.** Measured: a body polling `Task.isCancelled` inside `BlockingWork.run` runs
    to completion — 40 of 40 steps — because the body executes on a `DispatchQueue` thread, outside
    any task, and `withCheckedContinuation` carries no cancellation. Only two sites in the app read
    it inside a detached body (`DirectoryLoader.budgetedSize` and, as a child task,
    `cancellableSize`), and both were deliberately left alone. `SubtreeSearchRunner` shows the shape
    that converts for free: its cancellation already rides on an external `control.isStopped`, which
    is a plain flag and does not care what thread reads it. Where a bridge *is* wanted,
    `withTaskCancellationHandler` writing a `Sendable` flag restores it exactly (3–6 steps, normal
    pool and strict alike).
  - **The suite cannot see any of this, in either direction.** Under the strict-pool instrument the
    baseline was already green (600 tests, 106 suites, 31.3 s, zero issues) and stayed green after
    all 64 conversions (3/3 runs). The 2026-08-20 flakiness fix took the *live test suites* off the
    pool, and with them went the only thing that failed — so a green run says nothing about the
    product code, and this had to be argued from probes.
  - **A probe measuring cancellation must not put the canceller on the pool.** A first pass reported
    that today's `cancellableSize` never sees cancellation under a narrow pool (40/40 steps, 3/3) and
    that was the harness: the probe cancelled from a `Task.sleep` on the pool, which the walks
    themselves were starving — the instrumented timeline showed `cancel()` firing at **17114 ms**
    instead of 300. The real canceller is `cancelAllScans()` on the main actor, which AppKit serves
    from its own run loop. Re-run with a genuine independent thread, cancellation lands promptly even
    at pool width 1 (`[0,0,0,0,0,0,0,6]`). The claim to be careful with is not "does cancellation
    work" but "is my canceller reachable" — the same lesson this file records for the WebKit sandbox
    probe and the `swiftc`-defaults harness, arriving on a scheduler.
  - `DirectoryLoader.sorted` is the one deliberate `Task.detached` left in the listing path: it reads
    nothing and is ~350 ms of `localizedStandardCompare`, which is exactly the CPU work the
    cooperative pool exists to run. The two external launchers are the other exception — they call
    `process.run()` and return without waiting, so they block on nothing.

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
- **A security assertion that searches rendered *text* for a dangerous string is testing the
  document, not the renderer.** Three of M18 Slice 1's own assertions over the Markdown renderer
  were written that way and all three were wrong, in both directions. `!html.contains("onerror")`
  fails on a **correct** render, because the word is legitimate prose — PLAN.md contains one, and
  escaping the tag around it does not (and must not) remove it; `!html.contains("javascript:")`
  fails the same way on any document that *discusses* link safety, which is exactly the document
  most likely to be in the corpus. And a third, `name.first == "h" && name.count == 2` as "count
  the headings", quietly counted `<hr>` — so it over-reported rather than failing, which is worse.
  The assertions that hold ask what reached a **tag**: the set of attribute *names* against a closed
  allow-list (this is what catches an event handler), and every `href`/`src` **scheme** against
  another. Two corollaries worth keeping: a string that escaping makes *unrepresentable* is still
  safe to search for — a literal `<script` in the output could only have been written by the
  renderer, since prose renders as `&lt;script` — and the scheme reader in the test is written out
  by hand rather than borrowed from the code under test, since reusing it would prove the two agree
  rather than that either is right.
- **Spinning the run loop is not the same as awaiting, and a view-shaped test cannot tell.**
  `RunLoop.current.run(until:)` drives layout, so a helper built on it produces a view with real
  frames — enough for every assertion about *structure*, which is why Quick View's hit-test suite
  passed on it for two milestones. It does **not** land the result of a detached read: that
  continuation needs the main actor to *suspend*, which a run-loop spin never does. The first
  assertion about the view's **content** therefore reads an empty string, and it reads as a broken
  feature rather than a broken wait. Use `await Task.sleep` in a poll loop for anything asserting
  what an async load put on screen, and treat "the existing helper works" as evidence about the
  existing assertions only.
- **A *synchronous* test body that blocks is on the cooperative pool — or, for a `@MainActor` suite,
  on the main actor — and it starves every other suite's `await`.** This is `BlockingWork`'s own
  subject (▸ Swift 6 and concurrency) arriving one layer out, in test code, where the compiler is
  just as blind to it: Swift 6 refuses `Thread.sleep` *directly* inside an `async` function and a
  synchronous function that blocks compiles in silence. Six live suites each drove the real
  transports from plain `func … throws` bodies, so between them they held most of the pool for the
  length of real network round trips — the multipart round trip alone is **34 s** — and the two
  bucket tests in the `@MainActor` `S3AccountLiveIntegrationTests` held the *one* main actor, which
  is what nearly every headless suite here needs to be resumed on.
  - **What it looks like is somebody else's flake.** Reported 2026-08-20 as `RemoteFetchPrompt`,
    `RemoteDirectorySize` and `S3TransferProgress` failing about one run in three, all passing
    alone, on a Mac with Spotlight reindexing at 143 % CPU. Not one failure was in a live test:
    they were bounded waits in *other* suites expiring while the pool was full, so every failure
    named a feature that was working.
  - **`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` turns it into a measurement, and it is worth proving
    the instrument first.** A 20-line probe counting how many blocked `Task.detached` bodies can be
    inside at once read **16 → 1** with the variable set, and `ps eww` on the test host confirmed it
    arrives (`xcodebuild` strips shell env, so inject it into the `EnvironmentVariables` dict of a
    copy of the `.xctestrun` and run that with `-destination`). The controls then separate the cause
    from the machine outright: strict pool with the live suites **skipped** was 16 s and green 3/3,
    and with them in was **86–97 s with 1–5 failures**, same pool either way.
  - Fixed by wrapping each blocking body in `offCooperativePool`, which is `BlockingWork.run`
    plus a `Result` — `RemoteFileEditLiveIntegrationTests` had been doing it by hand at every call
    site since it shipped, so the rule already existed and had simply never been named. Re-measured:
    strict pool **6/6 green at ~30 s**, ten CPU spinners **5/5 green**, unloaded 3/3. The wall time
    falling from 86 s to 30 s is the same finding from the other side — the live transfers now
    overlap instead of queueing behind a pool they had filled themselves.
  - **Wrap the whole body, not each call, wherever a test measures durations**, so the clock, the
    subprocess and its progress callbacks stay on the one thread that ran it. Wrapping each call
    leaves the timing assertions measuring the scheduler.
- **A decision that reads live global state *inside itself* cannot be varied by a test, and the tell
  is a negative control that fails nothing.** `PanelViewController+Drop.resolvedKind` asked
  `NSEvent.modifierFlags` directly, so a rule keyed on ⌘ or ⌥ had exactly one reachable value — the
  keys nobody is holding during `xcodebuild test`. Reverting M23 Slice 5's "an archive member can
  only ever be copied" left **743 of 743 green**, which reads as "this rule is redundant" and is
  really "nothing here can see it": every *unmodified* archive drop is already a backend crossing,
  so it copies whichever way the rule goes, and only the ⌘-forced case differs. This is not the
  synthetic-event family (▸ AppKit) — the event mechanism is fine and the input never reaches the
  decision at all, because the decision fetched its own.
  - **A defaulted parameter is the whole fix**, and it costs the production callers nothing: Swift
    evaluates a default argument at each *call*, so `modifiers: NSEvent.ModifierFlags =
    NSEvent.modifierFlags` is the live keyboard everywhere but in the one test that passes
    `.command`. With the seam in, the same revert fails on the badge (`plan.kind → .move`), which is
    what the user is promised — `validateDrop` returns `plan.operation`.
  - **Run the narrowness control in the same pass or the seam quietly becomes the bug.** "⌘ over an
    ordinary local row still moves" is the assertion that stops "an archive member cannot move" from
    being implemented as "nothing can", and it is green throughout both directions.
  - The general form is worth more than the modifier case: **a rule whose input is read by the rule
    is a rule with one test case.** The same shape hides behind `Date()`, `NSEvent.modifierFlags`,
    `NSApp.currentEvent` and any `.shared` read taken mid-decision, and it always fails in the
    reassuring direction — the control passes.

- **A wait on a value the code under test sets *before* doing the work is a wait on nothing, and it
  makes a control read as inert.** The Synchronize sheet assigns its comparison synchronously on the
  way in and only then derives the rows, so `settleUntil { sheet.comparison == .content }` is
  satisfied in the same turn the picker was clicked — and a control that made the sheet re-*walk*
  both trees passed, because the listing count was read before any walk could land. Waiting instead
  on the thing that *ends* the work (`!isScanning`) failed it on demand. The general form is worth
  more than the case: **ask what the predicate would be true of in the broken build**, not only what
  it is true of in the fixed one, and prefer an observable the work **produces** over one the gesture
  merely records. Same family as the sheet-transient entry below and its mirror image — there the
  observable was destroyed too soon, here it existed too early.
  - The cruder way a control reads as inert cost a run in the same session: **the control's own edit
    did not match the file it was aimed at**, because swiftformat had rewrapped exactly those lines.
    A `replace` whose target never occurs reverts nothing and reports a pass, so assert the match
    rather than trusting the edit you meant to make.

- **An assertion inside `offCooperativePool` is filed under `Test «unknown»` while the test it came
  from still prints a tick — so a live suite's ✔ is not evidence.** The helper runs its body on a
  `DispatchQueue` thread, outside any task (which is the whole point — ▸ Swift 6 and concurrency),
  and Swift Testing tracks the current test in a task-local, so a failed `#expect` there has nothing
  to attribute itself to. Measured 2026-08-28: two live carry tests reported ✔ with their real
  failures listed separately as `«unknown»`, and only the run summary's issue count disagreed. A grep
  filtering on the test *name* is therefore blind to it — `✘ Test "` does not match
  `✘ Test «unknown»`, so a live control fires and reads as inert. **Read the issue count, not the
  ticks**, on any suite whose bodies block off the pool — and note the
  failure is reported, merely misattributed, so a run that says "0 issues" is still trustworthy.

- **A bounded wait that gives up *silently* reports the wrong thing when it expires, and "it passes
  alone" is the tell.** These suites polled a fixed count of 50 × 50 ms and then simply fell through
  to the assertion, so a starved run failed as `attachedSheet → nil → nil` — a dead button, not a
  late one. Two different budgets are hiding under one helper and they scale in opposite directions:
  waiting **for** something is free to be generous (a satisfied predicate returns on the next poll,
  so the budget only sets how much scheduling delay is absorbed before blaming the code), while
  waiting a delay **out** to prove nothing happens has its length *as* the claim and cannot be
  widened for a slow machine. Split them — `settle(within:until:)` at 10 s against a 1200 ms sheet
  delay, `hold(until:)` fixed at 2–2.5 s — rather than scaling one number for both.
  - **That split is right and both of its numbers were still wrong, because a third clock was
    hiding behind them: the *fixture's*.** Same suite, same message, 2026-08-27 — `attachedSheet →
    nil → nil` about **1 full run in 8–16**, passing alone every time, and this entry's own fix
    (the 10 s budget) had already been applied. What ends the fake transfer is `usleep` on a
    `BlockingWork` thread, which nothing in the process can starve, so it landed at a fixed 5 s of
    wall clock; everything watching it — the 1200 ms sheet timer, the prompt's `finish()`, the poll
    loop — is scheduled on the **main actor**, which is late by seconds. Past 5 s the sheet went up
    and was torn down in the same drain: **55 ms of visible life** in one measured run, sampled by a
    loop getting one poll a second. So the test was not slow, it was watching a transient the code
    under test destroys — and the run that *passed* had caught a 55 ms window by luck.
    - **The fix is to make the fixture wait to be cancelled** rather than count out a duration
      (`CountingBackend.blockBackstop`, now a 60 s backstop no assertion may rest on). The sheet is
      then taken down by the test that was watching it. The suite's slowest test drops from **22.8 s
      to ~7 s**, because two trailing waits that had been silently expiring at 10 s apiece now
      return in under a second — they were asserting the cancellation of a transfer that had already
      finished by itself, which is this entry's own failure one layer in. 18 full runs green
      afterwards, and note what that is and is not worth: a 16-run baseline of the *unfixed* tree
      caught the flake **0** times on this Mac against the 2-in-16 it was reported at, so the run
      count corroborates and the amplification below is the evidence.
    - **Shortening the same constant is the amplification**, and it is what makes the diagnosis a
      measurement rather than a story: at 2 s both sheet tests fail **3/3** full runs with the
      reporter's exact message, at 60 s the same tree is green.
    - **Ask what makes the thing you are sampling go away**, not only how often you sample. A wait
      whose subject is torn down by the code under test needs the teardown moved out of the run, or
      an observable that latches — polling harder only narrows the window it can miss.
  - **Audit the whole family once the first one is found, and audit it with controls rather than by
    reading.** Sweeping every negative wait in the app target on 2026-08-27 — 18 of them — turned up
    **four** more sized by a constant against a delayed product path, and only a negative control
    could tell which were still doing anything. Three were dead in a full run and alive alone:
    `RemotePreviewFetchTests`' `stopIsNotRestartedByItsOwnRedraw` and
    `failedFetchReportsOnceAndDoesNotLoop` (**0 failures in 4** full runs with the guard they protect
    deleted, **3 of 3** with the same build run alone) and `RemoteFetchPromptTests`'
    `automaticStandsAsideForAnExplicitFetch` (2 of 4, 3 of 3 alone). All three held 2.5 s against
    `RemoteFileCache`'s **400 ms** settle delay — nominally six times over, and not once the main
    actor is late by seconds.
    - The repair is the same shape as the sheet's and is worth having as a named helper rather than
      re-derived per test: `holdOutTheAutomaticFetchDelay()` schedules a fetch that *must* issue, on
      its own cache, and waits for it. Called immediately after the schedules under test, whose
      tasks were created first and therefore run first, it says "a fetch that was going to start has
      started" instead of guessing how long that takes. Re-measured with the same guard deleted:
      **4 of 4** full runs failing, from 0, 0 and 2.
    - **The ones that survived the audit are the useful half of the result**, because they say what
      makes a constant safe: `leavingTheRowTransfersNothing` fails 3/3 both alone and in a full run,
      and every Trash-less no-sheet wait fires reliably because `beginSheetModal` sets
      `attachedSheet` **synchronously** — measured here at `polls=0, elapsed≈2 µs`. A negative wait
      is safe exactly when what it is watching for would happen in the turn it is already waiting
      on, and unsafe the moment a timer stands between them.
  - **The stall is AppKit, not the cooperative pool, and four clocks in one process say so.** The
    family above (▸ Swift 6 and concurrency) trains you to suspect blocked cooperative workers;
    measured here with a real `Thread`, a `DispatchQueue.main` chain, a `@MainActor` `Task.sleep`
    loop and a detached one all running together, the thread and the detached task were **never**
    late while the main queue and the main actor stalled **together, by the same amount**, 0.6–5.0 s
    at a time. `sample` on the test host names it: the main thread is inside
    `CA::Transaction::flush_as_runloop_observer` → `NSDisplayCycleFlush` → `-[NSWindow
    layoutIfNeeded]` → `-[NSTableView layout]` → `PanelViewController.tableView(_:viewFor:row:)` →
    **IconServices**, laying out the tables of panes other suites keep alive for the life of the
    process. It is a run-loop observer, so nothing main-actor-isolated is drained while it runs.
    Two clocks stalling identically while an independent thread does not is the whole discriminator,
    and it costs twenty lines.
  - **A negative wait sized in seconds goes vacuous under that stall, and only a control finds it.**
    The sibling test pinning "no progress sheet over the placeholder card" held 2.5 s — "the 1200 ms
    delay, twice" — while the sheet actually lands 2.9–6.3 s in, so it expired before one could have
    appeared either way. Deleting the guard it exists to protect left it passing **3 of 3** full
    runs, and the *same build run alone* raised the sheet: a control that only fires on an idle Mac
    is not a control. The repair is to stop timing it with a constant — a second, identical fetch on
    its own window, started **after** the covered one so its sheet task is created after and its
    timer fires no earlier, is what says when to look. Reverted, it now fails 3/3. The two other
    waits in the suite were put under the same treatment and each still failed 3/3, which is what
    bounds the audit: they are settled by work already in flight, not by a timer nobody has armed.
- **A negative control over code that reports through a modal path *wedges* the run instead of
  failing it, and inverting a guard is the easy way to write one by accident.** Measured 2026-08-27
  while controlling M24 Slice 3's "a short set is a failure" rule: `presentOperationFailure` keeps
  the `runModal()` fallback for a window-less pane — correctly, since a hand-off is a gesture
  somebody made and is waiting on (▸ the who-is-waiting rule above) — so a control that makes *every*
  delivery report puts an app-modal alert in front of a test host nobody is looking at. Both attempts
  ran past five minutes and had to be killed; neither produced a failing assertion, and the second
  looked like a slow build rather than a dialog.
  - **The mistake is arithmetic, not judgement**: `guard urls.count == entries.count` inverted to
    `guard urls.isEmpty` reads as "only refuse an empty set" and means "refuse every non-empty one".
    Write a control as an **always-true** guard (`urls.count < 0`) rather than an inversion, so it
    can only ever take the *permissive* branch — the direction that fails an assertion instead of
    raising a dialog. Get the polarity right even then: `guard urls.count < 0` is always **false**
    and therefore reports on every delivery, which is the same wedge again wearing the fix's
    clothes — the always-true spelling is `>= 0`. Measured twice in one session, the second time
    against a note already written about the first.
  - **Size the control to the rule, not to the function.** The claim was about a *short* set, so a
    control that also changes what a complete set does is measuring more than the rule and can reach
    a path the tests never intended to exercise.
  - **And check the control fires at all before believing it.** The first version of this one —
    deleting the "report the failure" branch outright — left the suite **green**, because the
    delivery's own completeness check already refused the short set; what the branch really changed
    was the *sentence*. That is a finding about the code rather than about the control, and it is the
    reason the reporting collapsed to one site: the server's own reason is used for the wording, and
    what *decides* is whether every row resolved.
- **"A sheet appeared" is not an assertion, because the thing a refusal replaces is also a sheet.**
  M24 Slice 4's control on "a folder that is not on this disk is refused" left the suite **green**
  with the guard neutered — the test asked only `attachedSheet != nil`, and with nothing refused the
  gesture went on to raise the *create* sheet, which satisfies it exactly as well. Nothing about the
  run looked wrong: the two other assertions (`enqueued.isEmpty`, `materializedEntries.isEmpty`) are
  true of both branches too, because a confirmation sheet queues nothing until somebody clicks it. So
  all three passed in both directions and the test was measuring nothing at all.
  - **Count the sheet's buttons.** A refusal offers one (OK) and every confirmation here offers two
    or more — three for the create sheet, whose accessory carries a popup — which is a structural
    discriminator and, unlike matching the title text, survives the app test target inheriting the
    developer's own `AppleLanguages` pin (▸ Localization). `sheetButtonCount(in:)` is the helper.
  - The general shape is worth more than the sheet: **a control has to change the observable, not
    merely the code path**, and an observable shared by the branch under test and the branch it falls
    through to is not one. Ask what the *other* branch does before believing a negative wait or a
    presence check — here the alternative branch's first act was to present something of the same
    kind.
- **A `git checkout` is not available to revert a control here, because the work is uncommitted** —
  Oleg commits, so a control's cleanup has to copy the file aside and copy it back. Done anyway
  2026-08-29, and what made it recoverable is worth the sentence: the copy taken aside was of the
  file **with the control applied**, so the slice's work was still in it and only the control's own
  edit had to be undone. Copy aside *after* applying a control as well as before, or the reflex that
  throws the work away throws away the only copy of it too. Worth stating
  because the reflex is `git checkout -- <dir>`, which in this repo throws the whole slice away
  rather than the control. And a run killed by a timeout never reaches its own cleanup, so check the
  file's state afterwards rather than assuming the script finished.
- **Tearing a window down while a sheet it carried is still settling segfaults the test host, and
  the crash lands on a *later* test — one that may present no sheet at all.** This file's entry on a suite
  that presents real `NSAlert`s killing the runner (▸ AppKit, the `AlertKeyCatcher` tests) says it
  happens; this is the mechanism, and the cheap way out.
  Measured 2026-08-25 while covering the Trash-less flows: `EXC_BAD_ACCESS` in `objc_release` under
  **`-[_NSWindowTransformAnimation dealloc]`**, from a Core Animation transaction committing inside
  the *next* test's `XCTWaiter` run-loop spin — so of seven serialized tests, the two that crashed
  were #4 and #7 while the sheets belonged to #3 and #6. xcodebuild then restarts and lists whatever
  was in flight under "Failing tests:", naming features that work.
  - **Waiting for `attachedSheet` to go `nil` first is not enough** — the tests that crashed the run
    already did that. What fixes it is never tearing down: drop the `defer { window.close() }` and
    let the probe **retain** its windows for the life of the process (`TrashlessProbe.window()`). A
    handful of retained windows in a test host costs nothing against a crash that reads as several
    broken features. Re-measured: 7/7 green, no restarts, and the full app suite 6/6.
  - **The wall clock lies about which fix worked.** The crashing runs took 23 s against a 12 s
    baseline, which reads as "these tests are slow" and invites tuning the waits; the restarts were
    the whole difference, and with them gone the suite costs ~6 s.
- **A fixture identifier that merely *looks* real answers `nil` to whatever parses it, and the test
  then measures the fallback rather than the feature.** M24 Slice 6's crumb test used the hand-off
  suites' `VFSBackendID("sftp://user@host")` — a plausible string, not one `SFTPLocation.backendID`
  ever produces — so `backendRootTitle` could not parse it, returned `nil`, and the root crumb came
  out as the `?? "Macintosh HD"` fallback. The first version of the test asserted only a *suffix* and
  passed; strengthening it to the full list is what exposed both the wrong root title **and** a real
  bug beneath it (the remote origin was being walked as though it were an enclosing archive, drawing
  `… › srv › backup.zip › srv › backup.zip › docs` — a plausible-looking trail with everything twice).
  Build the id through the type's own constructor (`.sftp(SFTPLocation(host:username:))`), which is
  the same rule this file states for minting a probe's *scaffolding*, arriving in a unit test.
  - **Three green runs said nothing, and eight said it eight times.** The bug was in every run from
    the moment the stronger assertion existed; what had hidden it before was an assertion that could
    not see it. Worth pairing with this file's warning about baselines: a run count answers *is this
    flaky*, and only the assertion answers *is this right*.
  - **Assert the whole list, not a suffix or a `contains`.** Both weaker forms are true of the
    duplicated trail — the suffix matched and every individual crumb was a real place — which is the
    shape of a wrong answer this project keeps meeting: plausible, ordered, and containing everything
    it should, plus something it should not.
- **`-only-testing:` naming a single Swift Testing function can select nothing, and reports
  success.** Measured 2026-08-29: `-only-testing:Target/SuiteName/functionName` ran **0 tests in 1
  suite** and printed a tick — the same "green run that ran nothing" as the entry below, reached
  through a different door (a filter matching no test rather than a macro attaching to none). The
  tell is the same and is the only one there is: the **count** in the run summary.

- **A doc comment between `@MainActor` and `@Suite` discovers *zero tests*, and reports success.**
  Same run: the suite printed `✔ Suite "…" passed after 0.001 seconds` and the run summary read
  `Test run with 0 tests in 1 suite passed`, with no warning at build time and no error anywhere —
  attributes and the declaration have to be contiguous for the macro to attach. It is the quietest
  failure a test file has available (a green suite that ran nothing), and the only tell is the test
  *count*, which is why a run's count is worth reading rather than its verdict. It invalidated a
  measurement taken while it was in place, so re-take any measurement made across such an edit.
- **A live suite that drives one server, or writes one shared credential, has to be `.serialized` —
  and the collision fails in the *setup*, so it reads as the feature being broken.** Swift Testing
  runs a suite's tests in parallel by default, which for `S3AccountLiveIntegrationTests` meant four
  panes' worth of `curl` against a single-threaded probe server *and* one instance's `deinit`
  deleting the Keychain item another instance was still using. What lands on screen is
  `timed out waiting for the account root to list` — a failure of the shared `connectedPane` helper,
  naming the connect, when nothing about the connect is wrong. Two things follow. Reach for
  `.serialized` on the merits (shared external state), not as a flake workaround; and be suspicious
  of a failure inside a *helper* every test calls, since that is where a parallelism problem
  surfaces and where it looks least like one. The cleanup itself is still right: the flows file a
  secret on every successful connect, so leaving it behind puts a live-looking credential in whoever
  ran the suite — and removing it from inside the test host raises no authorization prompt, where
  `security` at a shell would.
  - **A headless suite that loads a pane's view raises the app's own error alerts, and an
    `NSAlert.runModal()` fallback then blocks the entire run until a human clicks OK.** The tell is
    a test "timing out" for a duration that is really somebody's reaction time. Measured
    2026-08-14: `RenameReachTests` calls `loadViewIfNeeded()` (it must, or the flow under test
    returns one guard earlier), `viewDidLoad` → `activateTab()` → `navigate(to:)` lists the
    fixture's path, and every non-local fixture — an unconnected bucket, an archive, `search:`,
    `trash:`, `icloud:` — ends at `presentLoadFailure`, which had the house `if let window …
    beginSheetModal … else runModal()` shape. With no window that is six app-modal alerts in one
    run. `S3AccountLiveIntegrationTests` was the suite that *reported* it, timing out at 72 s and
    209 s while passing in 1.2 s alone, because it was queued behind them.
    - **Three headless controls agreed on a wrong cause**, and each looked like evidence: skipping
      the new tests → green, skipping `RenameReachTests` instead → green, and
      `-parallel-testing-enabled NO` → all 459 green. Every one of them changes *how much runs*, so
      every one of them moves the dialogs around; none can see a window. What settled it was the
      **user saying they had clicked six dialogs away**. When a test suite's timing is
      unexplainable, look at the screen before theorising about scheduling — and note that a
      passing serial run is not evidence about parallelism if a human was clearing dialogs in both.
    - **The fix is to withhold the alert, not to fix the test.** A load failure is an alert raised
      *unasked* — a navigation the app performs by itself — so a pane with no window has nobody to
      tell; the same state is reachable in the app during launch restoration, before `showWindow`.
      Dropping it in place of the `runModal` fallback: 459 green in **16.2 s**, against **111 s for
      eight tests** with the fallback back in (all of it dismissing dialogs).
    - **The rule that came out of auditing the other 48 sites: `runModal` is right when a *user is
      waiting for the answer*, and the audit question is "who is waiting?", not "is there a
      window?".** Three kinds hide behind one `else runModal()`:
      1. **A user pressed something** — every confirmation, prompt and post-gesture failure (the
         great majority). An alert detached from the app beats no answer: keep the fallback.
      2. **A blocked worker is waiting** — `ConflictDialog` and `ErrorDialog`, called from the copy
         thread, which is parked until the answer comes back. Here `runModal` is not merely
         acceptable, it is *required*: dropping it hangs the job or silently picks a resolution.
      3. **Nobody is waiting** — the app raised it on its own schedule: a listing that failed during
         a navigation the app started, a queued job finishing minutes later, a watcher noticing an
         editor's save. With no window there is nobody to tell, and `runModal` does not just
         misplace the alert, it blocks the process on a dialog that arrived by itself.
      Only the third kind is the bug, and it was **six** sites: `presentLoadFailure`, both
      write-back offers (`EditedFileRegistry` is a watcher), and the queue's failure, pack and
      checksum reports — plus `presentIssues`, which is dual-triggered (⌘Z *and* a recursive-apply
      job) and therefore answers the harder half. They now share one funnel,
      `NSAlert.beginSheetIfVisible(over:)`, so the reasoning lives in one doc comment rather than in
      six copies of `if let window`. It routes through `sheetHost(over:)` as a side benefit: a
      report landing while a dialog is up now attaches to *that* dialog instead of being queued
      invisibly behind it.
      - Two launch-time one-shots (`DisplacedScriptKeysNotice`, the Full Disk Access wall) are
        unprompted by this rule and were deliberately **left alone**: each is handed a window by
        construction, and each is marked as shown once presented — so dropping it would consume the
        one-shot in silence, which is a worse failure than the one being prevented.
- **A test that measures *whether anything repainted* is measuring the whole process, and on a
  main-actor UI that is a much larger surface than the feature under test.** `PanelPassiveRefreshTests`
  pins the rule that a listing refresh finding nothing changed must not reload the table, and its
  observable has to be the table's **selection**, because `NSTableView` offers no reload count. That
  observable answers every repaint from anywhere. It failed about **one full run in four** while
  passing alone every time — which reads as machine load, and was not: three separate races, all in
  the fixture, found by logging every `renderRefresh` with its call stack (2026-08-22).
  - **Waiting for "the pane has listed" is the first one, and the `..` row is what makes it wrong.**
    The wait was `numberOfRows > 0 && selectedRow >= 0`, which an **empty** pane satisfies — the
    parent row is drawn and selected before any listing lands — so the navigation's own
    `reloadEverything` arrived 130 ms *inside* the quiesce that was supposed to follow it. Wait on
    the **entries** (`panel.displayedEntries.count == 3`), which only a real listing can satisfy.
  - **What a refresh *pulls* is the second, and it is invisible in the diff of anything.** Both
    refresh paths deliberately end by waking the git, tag and sync consumers unconditionally, and the
    sync provider's first scan publishes into a **shared cache after the listing has landed** — so
    the measured refresh collected it and repainted 650 ms into the quiet window. The pane was doing
    exactly its job. A fixture measuring "did the listing repaint" has to consume that first snapshot
    itself, by calling the same three funnels (`updateGitStatus`/`updateTagStatus`/`updateSyncStatus`)
    before it measures.
  - **And pulling on a 300 ms cadence starves the very scan it is waiting for.** Every one of those
    providers reads through `DirectoryScanCache`, whose `requestRefresh` runs the *first* look at once
    and debounces the rest by **300 ms**, cancelling the pending timer each time — so a pull every
    300 ms pushes the scan out in front of itself indefinitely, and it published 460 ms *after* the
    loop gave up. Any polling loop that also *requests* the thing it polls for has this shape; make
    the round outlast the debounce (750 ms here) and pull **again at the end of the round**, since a
    quiet round proves nothing if its only pull happened before the publish it was waiting for.
  - **The exact fix is to wait on the provider's own cache, and the tell that a duration is not
    enough is a *fast* failing run.** With rounds alone the residual was 1 run in 6, always the two
    tree tests together, always in a run that finished ~1 s faster than a green one — which is what a
    loop settling in a single round looks like from outside. Waiting until
    `CloudSyncStatusProvider.shared.cachedSnapshot(for:)` and `FinderTagProvider`'s are non-`nil`
    removes the race rather than narrowing it: 16 consecutive green full runs. Gate each wait on the
    pane's own `isSyncStatusVisible` / `areTagsVisible`, or a Mac whose owner has that setting off
    waits out the budget for nothing — the test host runs against the **developer's** preferences.
  - **The third race is the other suites, and it is worth knowing how large it is**: of the 58–66
    repaints the four fixture panes took in one run, *every one* came from another suite writing a
    preference (`applyPalette`, `applyRowDensity`, `applyFileColorRules`) through
    `AppPreferences.shared` and `NotificationCenter`, which every live pane in the test host observes.
    `NotificationCenter.default.removeObserver(pane)` after `loadViewIfNeeded()` takes the lot — every
    observer here is selector-based and installed once — and leaves what the suite measures untouched,
    since the FSEvents watcher is a stream callback rather than a notification. It is belt and braces
    rather than the fix (reverting it alone left six full runs green), and it is worth keeping anyway:
    nothing would announce itself the day another suite's timing shifts.
  - **The negative control is the whole point and must be re-run at the end**: with the two
    unchanged-guards removed from `directoryDidChange` and `refreshTree`, all three no-repaint tests
    fail on their own assertions while the narrowness control ("a real change still reaches the tree")
    stays green. A quiet fixture is only worth having if it still fails for the original reason.
  - **The fourth race was the product's, and "16 consecutive green runs" is not a claim with a shelf
    life — it expired.** Re-measured 2026-08-26 with an unrelated branch stashed, the baseline was 2
    failures in 8 full runs, always the two tree tests. Same probe as before (an `NSLog` in
    `renderRefresh` with its call stack, plus one on the cache's eviction), and it named the cause on
    the first run: the pane's own fixture directory **evicted from the shared `DirectoryScanCache`**
    — for `/Users/oleg`, for `/iCloud Drive`, for another suite's tree fixture, and once for a
    sibling pane in this very suite — after which the tail's `updateSyncStatus` read the miss and
    applied it, blanking the pane's badges through `applySyncSnapshot(nil)` and repainting inside the
    measurement window.
    - **A cache miss is "not known here", never "this directory has nothing", and the two are
      indistinguishable at the call site.** That cache is an LRU of **eight** shared by every pane
      and tab, evicting by *store* recency, which knows nothing about what is on screen — so two
      panes of four tabs fill it and a fifth tab anywhere drops a directory a user is looking at. The
      three pulls each read the miss as an answer, so a badge set that was perfectly current was
      erased and then re-drawn by the scan the same call had just started: two full `reloadData`
      passes and a visible flicker, over a directory nothing had happened to. Fixed by adopting only
      a **hit** (`if let cached = …`) in `updateSyncStatus`, `updateTagStatus` and `updateGitStatus`.
    - **Leaving the directory needs no bookkeeping for two of the three, and does for the third.** A
      tag or sync snapshot is keyed by absolute path, so one held for a folder the pane has left
      answers `nil` for every row of the folder it arrived at — the visibility gate is what drops it
      when badges stop applying at all. A **Git** snapshot is not purely per-row: it also names the
      branch in the path bar and decides whether totals are counted git-aware, so held across a move
      to a different repository it would put repo A's branch over repo B's rows. That one case still
      clears, on the previous root captured before the new one is stored.
    - **The suite is where it surfaced; the user-visible bug is the flicker**, and it is the same one
      this whole entry exists to prevent, reached through cache pressure instead of an unchanged
      listing. Worth carrying past this cache: **a bounded shared cache whose eviction policy cannot
      see what is on screen will eventually drop something that is**, so every reader of one owes an
      answer to "what does absent mean here" — and the reassuring answer is usually the wrong one.
    - Measured after the fix: **0 failures in 16 full runs**, against 2 in 8 for the baseline. The
      regression test (`evictionFromTheSharedScanCacheDoesNotRepaint`) forces the eviction on purpose
      and asserts both directions — the pane keeps its badges *and* does not repaint — with the
      adoption of a hit as its narrowness control, or "ignore the cache" would pass it by never
      reading the cache at all. Reverted, it fails on both assertions, and its ballast is enough
      pressure to fail `treeRefreshWithADeepChange` with the suite **run alone**, which nothing else
      here has managed.
    - **`RemoteFetchPromptTests` flakes in the same runs and is not this**, which took a control to
      say rather than a hunch: 2 failures in 16 with the new test in and **1 in 16 with just that
      test skipped**, on the same tree. It is the bounded-wait family already recorded above, and the
      baseline's 0-in-8 was a small sample rather than evidence of a regression — which is this
      file's own rule about baselines, met from the other side.
  - **The fifth race was the *fixture's own pressure running out*, and the tell is that it fails in
    the setup rather than in the claim.** `Expectation failed: aged` — the eviction the test
    arranges never happening — about 1 full run in 16, measured 2026-08-27 on a changed tree and
    reproduced 1-in-16 on a 16-run baseline of the unchanged one, so it is neither new nor anybody's
    regression. `ageOutOfTheScanCaches` fired 24 `requestRefresh` calls **once, before the wait**,
    and only a scan that *lands* evicts anything: logging every `store` and eviction of the suite's
    own keys shows all 24 landing within tens of milliseconds — and with them the burst is spent.
    Anything storing the directory afterwards (the debounced scan `quiesce`'s last pull leaves
    behind, or the replay `DirectoryScanCache` schedules when a request arrives mid-scan) puts it
    back at the recent end of an eight-slot LRU with no pressure left anywhere in the test, and the
    wait expires against a fixture that has already spent everything it had.
    - **What had been rescuing it was other suites**, which this test neither controls nor can rely
      on: a store forced 500 ms after the burst was cleared again 3 runs of 3 by pressure the
      fixture did not create. That is why the failure is rare and load-dependent rather than
      systematic.
    - **Fault injection is what reproduced it**, after **85** runs of the unmodified fixture caught
      it 0 times. Store the directory once, the first time the wait observes it gone — one line
      inside the predicate — and the burst version fails **3/3** with the reporter's own message.
      Reach for injecting the race when the race will not come when called: at that rate every "it
      passed" is no evidence at all, and 85 of them are still no evidence.
    - **The fix is pressure in rounds**: each round mints keys that have never been seen (a repeat
      only *moves* a key, it does not add an LRU slot) and then re-checks, so a late store is
      answered by more pressure rather than by a longer wait. Same injection, 3/3 green. The
      narrowness control is the product's own — reverting "a miss is not an answer" still fails the
      test on both of its assertions, so the rounds did not buy the green run by making it vacuous.
    - **An LRU whose eviction is driven by *stores* cannot be emptied by waiting**, which is the
      shape worth carrying past this suite: a fixture that arranges an eviction is really arranging
      a race between its own writes and everybody else's, and a burst fired before the wait has no
      answer to a write that lands after it.

- **`HeadBucket` goes on answering 200 for a bucket AWS has deleted — intermittently, and for longer
  than a test run — so any code that `stat`s before it creates can refuse a name that is not there.**
  Measured 2026-08-20 on the live account, polling immediately after a `DELETE` returned 204:
  `404 404 200 200 200 200 200 200 404 200 404 404`, while `ListAllMyBuckets` read the name as absent
  **12 times out of 12** and `HeadBucket` on a *settled* bucket answered 200 all 30 times. So the
  staleness belongs to a name that was just deleted, roughly one read in three disagrees with the
  truth, and **the listing is exact where the head is not**.
  - **It is a product behaviour before it is a test problem, and the fix is to pick a better
    witness rather than to drop the guard.** `S3AccountBackend.createDirectory` guarded on its own
    `stat`, which is that `HeadBucket` — so F7 with the name of a bucket just deleted answered
    "already exists" for a bucket that is gone, and only sometimes. Nothing logs, and the pane is
    *right*: its listing does not show the name. That contradiction is the tell, and it is the shape
    that reads as the app being confused rather than the service. The guard itself has to stay —
    a permissive endpoint, and AWS's own `us-east-1`, answer a re-create with a silent 200 — so what
    changed is what it rests on: the cheap head raises the question and the **listing** answers it,
    which also makes a refusal incapable of disagreeing with what the user is looking at. A free
    name still costs one `HeadBucket` and nothing more, since only a name about to be refused pays
    for the listing, and the opposite flap needs nothing at all: a 404 for a bucket that is there
    sends the create, and AWS's 409 is already mapped.
  - **A listing that cannot be had must not read as "the name is free."** The two failure directions
    are not equal — refusing wrongly is recoverable, while creating over a permissive endpoint
    reports work that never happened — so the helper answers `Bool?` and a `nil` leaves the head its
    old authority. That is the narrowness control the fix needs, and it is the one that keeps
    passing when the fix is reverted, which is worth knowing before reading a green run as evidence.
  - **The phantom branch is headless-only, and saying so is part of the fix.** Both other branches
    are covered live against AWS (a settled name refuses; a free name creates), but "the head says
    200 and the listing says no" cannot be arranged on demand — deliberate poisoning failed to
    reproduce it in six runs. It is pinned in `S3AccountBackendTests` with a fake, against the
    reverted version as the control.
  - **What it did to the live suite was flake in *both* directions**, which is why it read as two
    unrelated bugs: a lingering 200 from the previous run refused the setup create
    (`.alreadyExists` on a free name), and an unlucky 404 after a create let a second one through
    (`creates → 2` on the assertion that the guard costs no request). Both were in
    `recreatingAnOwnedBucketIsRefused`, ~2 failures in 5 runs.
  - **The predicted fix was unavailable, and one probe settled it.** That test's own comment named a
    UUID-suffixed bucket name as the answer "if this ever flakes", at the cost of an IAM policy on
    `arn:aws:s3:::dirnex-live-probe-*`. The live account grants `s3:CreateBucket` on the one exact
    ARN, so a unique name comes back **403 AccessDenied** and creates nothing. Check what the policy
    actually permits before designing around a name you cannot mint.
  - **The fix is to ask `HeadBucket` only about names whose answer is stable**, which turned out to
    cost nothing: the "guard let it through" control uses a name that has *never* existed (a stable
    404 — and its 403 is as good as any answer, since what is counted is that a request was made),
    the "guard refused without asking" claim uses the fixture's own settled bucket (a stable 200),
    and the service's own `409 BucketAlreadyOwnedByYou` — which does need the one creatable name —
    is asked **directly**, where no `HeadBucket` is involved (measured 3/3). The churned name is
    then only ever touched by `CreateBucket`/`DeleteBucket`, both exact.
  - **The control for the residual retry is a *leftover*, not a phantom.** Poisoning `HeadBucket`
    deliberately (create, delete, confirm it answers 200) failed to break the plain create in 6 runs
    — the flap decays faster than a suite restarts — so the phantom is not reproducible on demand.
    Pre-creating the bucket **is**: with a real leftover, the plain create fails with `.alreadyExists`
    and the retrying helper passes, which exercises the same branch. Reach for the reproducible
    neighbour when the failure you are guarding against will not come when called.
- **A live suite's cleanup is keyed on the *fixture's* identity, not on who filed the item — so
  "delete what we leave behind" deletes the user's own credential the day the fixture names an
  account they also use.** Both S3 live suites ended with `SecretKeychain.removePassword`, on the
  stated assumption that the fixture points at a scratch endpoint and the items are therefore the
  suite's own. The key is `accessKeyID@host:port/region[/bucket]`, which is a fact about the account
  and says nothing about which process wrote it, so pointing `/tmp/dirnex_s3_live_test.json` at a
  real AWS account addressed the very item the sidebar's saved row depends on. Reported 2026-08-20 as
  *"doesn't the app save credentials to the Keychain?"* — clicking the saved row re-opened the
  prefilled Connect sheet with the secret blank, on every build, because `xcodebuild test` had
  removed it. It is the quietest failure available: nothing logs, both suites and both linters are
  green, and the app's fallback is *correct* (a missing secret opens the sheet), so the bug wears the
  costume of a feature that was never implemented.
  - **Capture-and-restore is right whichever the fixture names**, which is why it replaces the delete
    rather than sitting beside it: an item the suite created still goes away (there was nothing to put
    back), and one it merely overwrote is returned to its value.
  - **Once per *process*, not once per test — and the obvious per-instance shape fails on exactly the
    collision `.serialized` does not cover.** That trait orders a suite's own tests and says nothing
    about two suites, and these two run concurrently over the one item; an instance whose `init`
    lands mid-flight captures the secret a neighbour has already written and dutifully "restores"
    that at the end. A `static let`'s initializer runs once however many tests race into it, and the
    put-back belongs in `atexit`, because any earlier point is inside somebody else's test.
  - **The instrument is a sentinel, and it doubles as the positive control.** File a recognisable
    value at the key, run the suites, and read it back: the per-instance version left the fixture's
    real secret standing, the process-wide one gave the sentinel back. That the tests still *pass*
    with a sentinel filed is the other half — `s3BucketConnectRequest` reads the account secret from
    the Keychain, so a green run proves the item really was overwritten during the run and restored
    afterwards, rather than never having been touched.
- **A parallel live suite can exhaust the *server's* connection budget, and that is shared external
  state nobody thinks of as state.** Six SFTP live suites run in parallel and every `VFSBackend` verb
  is a fresh `sftp`/`ssh` process — measured 2026-08-28, **250 logins for 24 tests** — so a stock
  OpenSSH server refuses part of the burst under `MaxStartups`, which by default (`10:30:100`) begins
  randomly dropping at **ten** concurrent *unauthenticated* connections. It fails as somebody else's
  bug: the refusal surfaces as `.io(code: 5)` or `kex_exchange_identification: read: Connection reset
  by peer` from whichever helper was connecting, so it names a feature that works, and every suite
  passes alone.
  - **The server's own log is the judge, and it says so outright** — `drop connection #11 …
    Maxstartups` — which is what turns "these live tests are flaky" into one measurement. One
    variable, three runs: `10:30:100` → **10 failures**, `1000:30:2000` → **0**, same tree.
  - **`.serialized` across the suites would have hidden it, and that is the trap worth naming.** The
    entry above says to reach for the trait *on the merits* (shared external state); the reflex here
    is to reach for it because the run is red, and it would have "worked" by keeping the burst under
    a limit nobody had measured — leaving the real precondition undiscovered and the suites serialized
    for no stated reason. Fix the budget, not the concurrency.
  - **The spelling is its own trap**: a bare `MaxStartups 500` sets only the *ceiling* and leaves the
    threshold at 10 (`sshd -T` reads back `10:30:500`), so it looks applied and merely **halves** the
    failures — 10 → 6, still 3 drops. The lever is the **first** field of the triple. Read the setting
    back with `sshd -T` rather than trusting the file.
  - The neighbouring product fact, unfixed and worth knowing: a throttled or connection-capped server
    reaches the user as `.io(code: 5)` too — a number nobody can look up — where the stderr naming
    `kex_exchange_identification` is sitting right there. The same shape ▸ curl for S3 records for a
    generic 403 telling the user to grant Full Disk Access.
- **An unstated *fixture* precondition in a live suite fails as a broken feature, and the tell is a
  `stat` nothing in the suite ever created.** `PackLiveIntegrationTests` assumed `alpha.txt`,
  `beta.txt` and a `backup.zip` holding exactly two members were already sitting at `remotePath`,
  where every sibling suite mints its own fixtures under a UUID-named subtree — so against a server
  nobody had hand-prepared it failed `.notFound(…/alpha.txt)`, which reads as a broken pack. Fixed
  2026-08-28 by provisioning both, and the control is sharp: the pre-fix version fails 2 of its 3
  tests on a fresh server while the third — already self-contained — passes in **both** directions,
  which is the narrowness half.
  - **The same test verified a remote file by reading it locally.** It compared the archive member
    against `String(contentsOfFile: config.remotePath + "/alpha.txt")` — a *local* read of a *server*
    path, which holds only while the server is this Mac and throws against any real account. The
    honest comparison is against the payload the test itself uploaded. Note this half is invisible to
    a loopback harness (the path exists locally either way), so it was fixed by reading rather than by
    measurement, and it is the reason a live suite pointed only at `127.0.0.1` is not a live suite.
- **A cancellation test whose fake finishes inside the same turn cannot see cancellation at all, and
  every assertion in it passes against a scheduler that never cancels anything.** Measured on the
  Quick View auto-fetch: with `cancelAutomaticFetch` neutered to a bare `pending = nil`, the whole
  suite stayed green — because the *identity guard* ("is this still the row we scheduled?") answers
  first, and a fake backend that returns immediately never gives the flag anything to interrupt. So
  the tests were about the guard, and the thing they were named for was untested. Two things fix it,
  and both are needed: a fake that **blocks** until it is told to stop, and a record of whether it
  **was** told — asserting the caller's `throws CancellationError` proves nothing here for the same
  reason it proved nothing one pass earlier (a post-transfer boundary check throws either way, ▸ curl
  for S3). The general form: when the subject is "does stopping reach the work", the fake has to be
  slow enough to stop, and only the *work's own* record is evidence.
- **A live test's probe size is a *duration* wearing a byte count, and it expires silently the day
  the suite meets a faster endpoint.** `S3TransferProgressLiveIntegrationTests` proves an upload
  reports its bytes *while it runs*, which needs a transfer long enough to carry several of `curl`'s
  once-a-second meter rows. Its 4 MiB was chosen against an S3-compatible server at ~285 KB/s — about
  fifteen seconds, a dozen rows. Against real AWS the same 4 MiB took **2.76 s**, the first row landed
  at 1.82 s, and `firstSighting < finished / 2` failed on a transport that was reporting perfectly.
  Nothing about the product had changed and nothing in the failure points at the constant.
  - **Sizing it from a measured rate is the natural fix and it is worse, because it fails
    *intermittently*.** One 1 MiB calibration upload is mostly connect, TLS and `Expect:
    100-continue`, so it read **2.57 MB/s** for a link doing nearer 9 and sized the probe about 3×
    too small — the direction that fails rather than merely slows. A two-point slope removes the
    fixed cost in principle and is dominated by variance in practice: green on three runs alone, then
    **1 sighting** inside the full suite, where every other test is competing for the same machine.
  - **What works is a ladder rather than a model**: try 4, then 16, then 48 MiB, stopping at the
    first transfer that lasted long enough for the claim, and *failing loudly* if even the top rung
    is too fast. The criterion is then the transfer's own measured duration — the quantity actually
    in question — and no arithmetic about the link survives to be wrong. Measured across three full
    suite runs the test's duration varies 3.3–9.2 s while the verdict does not, which is the ladder
    absorbing exactly the variance that broke the calculated version.
  - **The two tests in that suite read as twins and have clocks an order of magnitude apart**, which
    is why only one of them ever broke: a *download*'s progress is the destination file's size, asked
    at `ProcessWaiting`'s 100 ms poll, so even a two-second transfer reports twenty times, while an
    *upload* has no local observable and can only learn something when `curl` next prints. An
    assertion shape that is safe for one is not evidence for the other.

- **A live test that pins a value the flow under test exists to *correct* is asserting that the
  correction never happens.** `S3AccountLiveIntegrationTests` walked into a bucket and back out and
  checked the pane had returned to `config.accountRoot` — the account as **typed**. That reads as the
  obvious claim and holds only while nothing corrects anything, which was true of every endpoint the
  suite had met: the local probe endpoint and the S3-compatible account do not validate regions at
  all. Against real AWS with the region deliberately wrong it fails, because entering the bucket
  takes the 301, re-aims at the region the service named, and walking up quite correctly lands on
  **that** account — a different `VFSBackendID`, listing perfectly. The pane was right and the test
  was wrong, and it failed as a 30 s timeout inside a shared helper, which reads as a broken connect.
  - The fix is to assert the **relationship** instead: you land on the account that holds the bucket
    you were in, whichever region that turned out to be. Falsifiable in both directions, and
    independent of whether a correction fired.
  - Same family as the probe-size lesson above and worth stating as one rule: **a live test's
    constants are claims about the endpoint**, and the ones that expire are the ones nobody wrote
    down as claims — a bandwidth hidden in a byte count, a region hidden in an expected path.

## AppKit

- **`applicationShouldTerminateAfterLastWindowClosed` is asked from a run-loop *timer*, not at the
  moment a window closes — so a bare `true` lets the app quit itself during its own launch.** AppKit
  defers the check (`_scheduleCheckForTerminateAfterLastWindowClosed`) and asks whenever the main run
  loop is next pumped, which can be while `applicationDidFinishLaunching` is still on the stack:
  before `showWindow`, the browser window exists and is not visible, and neither is anything else
  AppKit knows about. `true` then answers "no windows left, quit" to a question that really means "no
  windows *yet*" → `NSApplication.terminate:` → `exit(0)`. `browserWindowController != nil` is the
  whole fix; it is nil for exactly the stretch that is unsafe.
  - **This was Dirnex's flaky `xcodebuild test`, and it cost a long hunt because every signal pointed
    away from it.** The test bundle is injected *during* launch and XCTest pumps its own run loop, so
    the timer landed inside the launch window and quit the host mid-suite — roughly half of runs. It
    left **no crash report**, because it was not a crash: the tell is xcodebuild's own wording, "The
    test runner exited with code **0** before finishing running tests", and an `atexit` handler's
    backtrace naming `-[NSApplication terminate:]` under `__CFRunLoopDoTimers`. Worse, the summary
    then listed whatever suites were in flight under "Failing tests:", so it read as several broken
    features rather than one lifecycle bug — always check whether the named tests *ran*.
  - **A run-loop spin in a test is what makes it fire, and the amplification is the proof.** Two
    Quick View helpers waited with `RunLoop.current.run(until:)`; forcing one to its full 3.5 s
    reproduced the failure in 5 of 7 runs, and the fix above made 6 of 6 green under that same forced
    spin. Reach for amplification whenever a flake will not reproduce on demand — it converts "I
    think this is it" into a measurement. (Both helpers now `await`, which is the house rule already
    stated under Testing and was the other half of the fix.)
  - **The obvious regression test is unsound, and measuring is what showed it.** Reading
    `NSApp.delegate`'s window and asserting fails about half the time on its own:
    `applicationDidFinishLaunching` **does not complete at all** in ~50 % of test-host launches
    (measured over six runs — the suite outruns it and XCTest exits the host when done), so the
    window is simply absent. Pin the invariant on a **freshly constructed** `AppDelegate` instead —
    that is the pre-`showWindow` state, deterministically. What that cannot catch is over-correction
    (a blanket `false`, or a guard keyed on `XCTestConfigurationFilePath`): with no window built all
    three answer `false`. Both were run by hand against the suite, and the live app was checked to
    still quit when its window is closed.
- **`NSAlert.runModal()` centers on the *display*, not on the window that raised it** — measured, a
  260 pt alert lands at x=734 on a 1728 pt screen whatever the app window's frame is. So every
  `runModal` alert reads as detached from the app, and on a large display it can be nowhere near the
  window it belongs to. The house rule is a sheet, with `runModal` kept only for the
  window-is-`nil` fallback; a scan for a `runModal` whose enclosing function never mentions
  `beginSheetModal` finds the ones that drifted (nine had, 2026-08-11).
  - **The reason they drift is real and is worth knowing before "fixing" them:** stacking a second
    sheet on a window that **already has one** queues it invisibly. Probed — the second alert's
    window reports `isVisible == false` and the window's `attachedSheet` is still the first — so a
    trust prompt raised from inside the Connect sheet's own attempt would never appear, deadlocking
    a flow that is waiting on its answer. `runModal` was the correct workaround for that constraint.
    - **Re-measured 2026-08-20 on macOS 26 and it no longer queues**: a second sheet raised on a
      window that already has one stacks *on top*, `isVisible == true` and key, `attachedSheet` now
      naming the newer one, and it answers its keys — dismissing either one leaves the other
      working. So the deadlock this bullet describes has gone, and with it the argument that made
      `runModal` the workaround. `sheetHost(over:)` still earns its keep for the other two reasons
      (an app-modal *window* is not its parent's `attachedSheet`, and a report should attach to the
      dialog in front rather than behind it) — but do not re-derive the queueing constraint from
      this entry without measuring it again, and note ~48 call sites still call
      `beginSheetModal(for:)` directly without it.
  - **Hosting it on the *sheet's* window is what makes the sheet version possible**: visible,
    attached, centered on its host (probed). Hence `NSAlert.sheetHost(over:)` —
    `NSApp.modalWindow ?? window?.attachedSheet ?? window`, the same ordering
    `PanelViewController+Compare` had already derived for its own case, `modalWindow` first because
    some dialogs are app-modal *windows* rather than sheets. Verify the nested case specifically: the
    plain one passes whether or not the host lookup is right, so it proves nothing about the bug.
  - Converting a synchronous prompt costs an `async` cascade, and it stops at the `@objc` action —
    each of the six here had exactly one caller, whose body moves into a `Task { @MainActor in … }`.
    Keep `selectText(nil)` on an accessory field: `initialFirstResponder` gives it *focus*, and only
    that selects the prefilled text, which is the whole ergonomics of a rename prompt.
- **Replacing an `NSViewController`'s `view` after it is presented redraws the window, height
  included** — `NSWindow.contentViewController` follows the swap rather than having taken the view
  once. Probed on macOS 26 in both directions: after assigning a fresh view, `window.contentView` is
  the **new** object, and a content view constrained 400 pt tall replaced by a 180 pt one moves the
  window frame from 432 to 212. Worth recording because the natural assumption is the opposite, and
  it is what makes "rebuild the panel from what the server actually stored" a redraw rather than a
  change to state nobody can see (`RemoteAttributesController.reload`).

- **`NSTitlebarAccessoryViewController` clips to its container's fixed frame.** A hardcoded
  width sized for three glyphs laid a fourth one out fine, with `isHidden == false`, and it was
  simply invisible. Derive each accessory container's width from what it holds, and pin each row
  at the edge it is anchored to, so a badge that comes and goes extends into empty title bar
  instead of shifting the controls already there. Only launching catches this.
- **Collapsing a split-view sidebar that holds first responder strands keyboard focus on the bare
  window.** When the focused view is hidden by the collapse, AppKit drops first responder to the
  `NSWindow` itself rather than to a sibling — so every pane goes gray and *Tab cannot recover it*,
  because Tab is a pane key that only fires while a pane is first responder (there is no window-level
  key-view loop to fall back on). `NSSplitViewController.toggleSidebar(_:)` is the one funnel both
  the menu/palette (`toggleSidebar:` selector) and the titlebar button call, so a subclass overriding
  it catches every collapse; capture whether the sidebar held focus *before* `super` (deterministic —
  a post-hoc KVO observer races the first-responder move) and hand focus to a pane after. Only
  reachable once the sidebar itself can hold focus, which it could not before M8.
- **A synthesized row's cell comes out of the *same* reuse pool as the real ones, so everything the
  real rows set has to be cleared on it — and the compiler cannot tell you what "everything" is.**
  `makeView(withIdentifier:)` keys on the **column**, so the `..` row's name cell is a recycled file
  cell; `parentRowCell` diligently reset the mark, the dim, the type color, the density, the palette
  and all four tree properties, and never touched the tag dots or the cloud badge — so scrolling a
  tagged file's cell up to the top hung its dots on the way *out of* the folder. It survived two
  milestones because a `reloadData` empties the pool outright (measured, see `FileCellView.density`),
  which is what makes it **scroll-only**: every code path that changes what a pane shows repairs it,
  and only the mouse can reach it. The shape to watch for is a per-row property added to the *real*
  render path with no matching line in the synthesized one, which is exactly what a diff does not
  show. One `clearBadges()` the two paths share is the fix; a checklist of properties is not.
- **A background `reloadData` while an inline rename field is open destroys the edit.** An
  FSEvents refresh or a directory-size total tears the shared field editor out of its cell and,
  because `NSTableView` recycles cell views, strands it on the `..` row — the rename silently
  vanishes and focus jumps. Guard both refresh sites and replay the owed refresh when editing
  ends. Only reproducible with a *real* FSEvents change landing during the edit window, not via
  synthetic F2 → type → Enter.
- **An `FSEventStream` is *recursive*, so a pane on a home directory is told about `~/Library` several
  times a second — and reacting to each with a `reloadData` is visible to the user, because AppKit's
  expansion tooltip dies with the cell view a reload discards.** `DirectoryWatcher` also discards the
  event's paths, so a ping proves only "something under here changed". Measured 2026-08-21 with a
  pane sitting on `/Users/oleg` and nothing touched: **62 FSEvents callbacks in 30 s** at the stream
  (every one from Chrome's cache, Spotlight's index, a sync client's metrics — not one about the
  directory itself), and **152 full `reloadData` calls in 31 idle seconds** over 27 rows that never
  changed. A truncated name floats its full value through `allowsExpansionToolTips`, which needs an
  uninterrupted hover to appear; at five reloads a second it never survives its own appearance delay.
  Reported by a user as a tooltip that "blinks" on any long folder in the home directory.
  - **The other three consumers of that event already had the rule, which is what makes it findable
    in the source rather than only in a profiler:** `applyGitSnapshot`, `applyTagSnapshot` and
    `applySyncSnapshot` each carry the sentence "a no-op when nothing changed, so the FSEvents-driven
    republish of an untouched directory costs no reload". The **listing** was the one consumer without
    it — and it is the one that repaints every row. When a single event wakes several consumers, the
    audit is to read each one's guard, not the event.
  - **Only the *render* may be skipped, not the wake-ups**, and the split is what keeps the fix from
    being a regression: none of git, tags or sync is derivable from a listing. `git add` moves the
    gutter without touching a worktree file; a Finder tag is an xattr, which changes no field of the
    `stat` a listing carries; and `invalidateDirectorySizes` must stay unconditional, since a change
    *below* a folder is exactly what makes its cached total stale while leaving the rows identical.
  - **The A/B is the whole proof, and it is the opposite of what "blinking" predicts.** Same pointer
    resting on the same row: with the guard in, the floated panel was present in **3/3** samples over
    4.5 s; with it reverted, **absent in 4/4** — the reload wins the race far more often than the
    tooltip does, so what the user sees is the rare frame where it got through.
  - **`NSTableView` offers no reload count, and the table's *selection* is the honest stand-in.**
    `renderRefresh` ends in `syncCursorToTable`, so a table deselected by hand comes back selected if
    and only if the pane re-rendered, and `reconcileCursorFromTable` returns early on an empty
    selection so deselecting does not disturb the cursor it would be read from. Two things the test
    needs: a **quiesce** step, because a freshly loaded pane has three legitimate first-snapshot
    renders still to come and measuring before they land reads their arrival as the bug; and the
    narrowness control, which is the half that keeps passing when the fix is reverted (a create in
    the pane's own directory must still appear) — without it, "never reload" would pass.
- **Every bare `NSTextField` initializer hands back a *wrapping* cell, so a value longer than the
  field hides its tail on a second line the field is too short to show.** Measured on macOS 26:
  `NSTextField()`, `NSTextField(frame:)` and both `NSSecureTextField` spellings all come back
  `wraps = true, isScrollable = false, lineBreakMode = .byWordWrapping`, while only
  `NSTextField(string:)` (and the `labelWithString:` family) is single-line by construction — which
  is why the pane's own F2 inline rename never had this and twelve dialogs did. Probed against the
  real ⇧F4 sheet with a 108-character name: field editor **48 pt tall inside a 20 pt clip**. What
  the user sees is the visible line breaking at the last word boundary — for a file name, a `-` or
  a `.` — leaving a gap of empty field beside it, so it reads as a *drawing* bug rather than as
  half the name being off screen. Reported by a user 2026-08-11 on the Edit File sheet;
  `keepToOneLine(truncating:)` is the one funnel, and `scripts/check_single_line_fields.py` keeps
  it applied, because a fix living in prose is not a fix (the `enableEscapeToCancel` lesson, twice
  over now).
  - **`cell.wraps` is what decides it, and `usesSingleLineMode` alone is the natural half-fix that
    changes nothing measurable.** With it alone the editor stays 252 pt wide, is not horizontally
    resizable, and the clip view scrolls **vertically** to the hidden line, so the tail is still
    unreachable; with `wraps = false` the editor is 621 pt wide and the clip scrolls horizontally
    to show it. `PathBarView`'s ⌘L field had exactly the half-fix, which is the shape to distrust:
    the property whose *name* matches the intent is not the one that acts.
  - **`isScrollable` and `lineBreakMode` clear each other — whichever is assigned last wins.**
    Probed: assigning a truncating break mode drops `isScrollable` to `false`, and assigning
    `isScrollable` resets the break mode to `.byClipping`. So the four-line configuration that
    reads as complete is really a choice between two of them, and `ConnectServerForm` — where this
    fix was first worked out — had been running with `isScrollable == false` since it shipped
    without anyone noticing, because scrolling never came from that property. Keep the truncation:
    it is what shows the host and share of an unfocused address instead of its scheme.
  - The whole class is invisible to every automated signal (2047 core tests, 333 app tests and both
    linters green throughout) and to any screenshot taken with a short name — the field really does
    hold the whole value, and nothing logs. A `cacheDisplay` of a live sheet is what shows it: the
    gap beside a name that stops at a hyphen is the tell.
- **macOS delivers ⌘A → `selectAll:` into a field editor only via a "Select All" menu key
  equivalent.** The text system does not self-bind ⌘A, so with no such menu item ⌘A is a dead
  no-op in every text field.
  - **The rule covers ⌘X, ⌘Z and ⇧⌘Z too, and "disable the item so the key falls through" is a
    myth.** Dirnex shipped exactly that: ⌘Z was the file-journal Undo, and its validator returned
    `false` while a field editor was up, on the stated assumption that `performKeyEquivalent` would
    then hand ⌘Z to the text. Measured in a throwaway AppKit app — it does not. A disabled item
    swallows the chord and the text is untouched; the *same* item carrying `undo:` undoes typing.
    ⌘X was simply absent from the menu and therefore dead everywhere. There is no fall-through to
    wait for: the menu item's **selector** is the whole mechanism.
  - **`NSTextView` implements `cut:`/`copy:`/`paste:`/`selectAll:` but *not* `undo:`/`redo:`.**
    Probed with `NSApp.target(forAction:to:from:)` against a live field editor: the first four
    resolve to the `NSTextView`, and the last two walk straight past it (no supplemental target
    either) to **`NSWindow`**, which owns text undo. So the two families need opposite designs. For
    ⌘C the pane can implement `copy:` and let the chain decide — a focused field editor gets there
    first. For ⌘Z it cannot: a `PanelViewController` implementing `undo:` shadows `NSWindow` in
    *both* cases, so it must detect `firstResponder is NSText` and hand the call back with
    `NSApp.sendAction(_:to: window, from:)`. Not to an undo manager you picked — the field editor's
    manager is provably not `window.undoManager` (`canUndo` reads `true` and `false` respectively),
    and driving the window's directly undid nothing.
  - The tell that this class of bug is present is a *comment* claiming a fall-through, and it fails
    in the quiet direction: nothing logs, every menu builds, and the key just does nothing.
- **An `NSMenuItem` that carries a submenu never fires its own key equivalent** — and it goes on
  reporting `isEnabled == true`, so the item looks armed and the chord does nothing. Measured
  directly: `NSMenu.performKeyEquivalent(with:)` returns **`false`** for a ⌃G item with a submenu and
  **`true`** for the byte-identical item without one. Since the menu bar is this app's only dispatch
  path for a registry shortcut (nothing else reads `KeyBindingStore` at event time), that decides a
  design rather than merely warning about one: M20's Go menu carries **two** Places entries, the
  submenu you browse and the plain `go.places` item its chord rides (⌃G when measured, ⌘G since).
  Three neighbours from the same probe — an **empty** submenu blocks it just the same, so it is the submenu's presence and not its contents;
  a **hidden** item's key equivalent *does* still fire (a tempting way to hide the second entry, and
  a mechanism nobody reading the menu later would find); and `menuNeedsUpdate` is **not** called
  during a key-equivalent search, so a delegate-populated menu is empty to that search.
  - **Pin such a claim against the *built* menu, not against the item builder.** A negative control
    is what showed it: removing `.command("go.places")` from the layout and hanging the chord on the submenu
    left an assertion over `MainMenuBuilder.commandItem(for:)` passing, because the item in isolation
    is still well-formed — it is simply in no menu. Flattening `MainMenuBuilder.build()` and looking
    for the *selector* catches it.
  - **The same rule governs the number keys typed *inside* an open menu, and two more measurements
    decide how they can be numbered at all.** Places' 1–9 jump keys (the ⌘F favorites popup's, one
    level up) were built assuming each menu could number its own rows from 1; a live run showed the
    opposite, in the direction that silently sends the user somewhere else. First, a section header
    cannot be numbered — AppKit does not even **draw** a key equivalent on an item with a submenu,
    the chevron owns that space, so the digit is invisible *and* dead while still consuming a number:
    the shipped attempt drew `Recents 1 … Trash 8`, the six carriers having eaten 2–7 with nothing on
    screen to say so. Second, the search **recurses into submenus and takes the first match in menu
    order, open or not**: with every section numbered from 1, typing `2` at the top level ran the
    second *saved search*, two levels down inside a closed submenu. Third, an open submenu gets **no
    precedence** — with Volumes open and highlighted, `1` still ran the root's Recents. So a digit
    must be unique across the whole tree at the moment it is typed, and since one flat 1–9 would let
    a long section swallow the range (leaving the Trash, the last row, permanently unreachable), the
    digits are *handed* to whichever menu is open and taken back on the way out (`PlacesDigits`).
    Restore on close has to be deferred a runloop turn and guarded by a generation counter: AppKit
    does not promise the section being left closes before the one being entered opens, and a restore
    that wins that race puts the root's digits back on top of the submenu the user is looking at.
  - **A bare digit on an item in a menu-bar menu is an app-wide chord, and the protection above is
    only good until the menu is opened once.** `performKeyEquivalent` searches the whole menu bar
    ahead of `keyDown:`, and the items a delegate-filled menu is left holding after an open *are*
    found: measured, `1` fires Recents from anywhere — out from under a rename field — where before
    the first open it does nothing. Emptying the menu in `menuDidClose` restores the safe state
    (measured `false` → `true` → `false`), and the chosen item's action still fires afterwards, since
    target and `representedObject` live on the item the dispatch retains. Any menu that carries
    unmodified accelerators needs that clear; without it the digits leak into every text field.
- **macOS's Help ▸ Search only exists if the app declares a Help menu, and Dirnex declares none.**
  M20 Slice 2 shipped with "since macOS's Help ▸ Search searches menu items, 'Trash' is now findable
  by typing the word" written into PLAN.md *and* into `PlacesMenu`'s doc comment — a benefit claimed
  twice for a search field this app has never had. One look at the running menu bar settles it
  (`Dirnex File Edit Select View Go Workspace Window`), which is the whole lesson: the claim was
  about a *surface*, and no test, no build and no code review looks at the menu bar. Whether a
  delegate-populated submenu would be indexed by that search, in an app that does have a Help menu,
  is unmeasured and should not be assumed either.
- **A branch added beside an existing one in a key monitor inherits none of its carve-outs, and the
  carve-outs are invisible at the call site precisely because they were factored out well.** The
  Quick View monitor's Esc branch reads `guard escapeBelongsToQuickView` — one line, no mention of
  field editors — so the `1`/`2` branch written three lines below it shipped with no field-editor
  test at all: with a preview up, ⌘L and typing `/tmp/12` put **`/tmp/`** in the path field, both
  digits eaten, caret visibly in the text. It cannot be caught by a test that drives the monitor
  (the monitor did exactly what it was told) and it is invisible in every screenshot that does not
  include someone typing. When adding a branch to a monitor, **read the predicate the neighboring
  branch guards on, not just its name** — and expect the answer to differ: `digitBelongsToQuickView`
  deliberately drops Esc's `FileTableView` exemption, because the table is where the digits must
  work and is where Esc must not.
- **A search field that owns a list's key handling is one click away from being cut out of it.** The
  ⌘K palette routes ⎋, ⏎ and ↑/↓ through `control(_:doCommandBy:)`, which fires *only* while the
  field is first responder — and a stock `NSTableView` takes first responder in `mouseDown:`. So one
  click on a result left the palette completely keyboard-dead: typing went nowhere, ⏎ ran nothing,
  ⎋ did not close it, and the only way out was a double-click or clicking outside. It fails in the
  quiet direction twice over — nothing logs, and the *keystrokes are silently dropped* rather than
  misrouted. The one visible tell reads as cosmetic: AppKit draws the same selection unemphasized
  (gray) without focus and emphasized (blue) with it, so "the row turns blue when I click it" is not
  a second highlight, it is the focus moving. Fix at the source — `acceptsFirstResponder = false` on
  the list subclass. `mouseDown:` still selects, so clicking keeps working and the selection settles
  on one appearance for mouse and keyboard alike.
  - **`NSTableView.doubleAction` mirrors `action` and cannot be cleared** — probed: assigning it
    `nil` reverts it to the mirror, so any table with a single-click action nominally has the same
    selector on double-click. Measured harmless *here* for the reason that generalizes: **ordering a
    window out during the first click swallows the remainder of that click session.** The command ran
    once, and the second click was not re-dispatched to the window underneath — verified by putting a
    palette row directly over a pane's `..` row, where a leaked double-click would have navigated up,
    and it did not. Worth re-measuring rather than assuming for any panel that closes on click.
  - A test can assert the first fact directly (`acceptsFirstResponder`) but not ⎋, since synthetic
    Escape never reaches the app (above). The proxy that *is* verifiable: click, then type a
    character and confirm it lands in the field — if the field kept focus it receives the whole
    `doCommandBy:` family, Escape included. After the click-to-run change the only click that leaves
    the panel open is one in the empty space below the last row, which is exactly where to aim it.
- **A coalescer must *defer* the update it withholds, never drop it — dropping latches, and it
  latches on the very first value.** The queue bar refreshes its byte readout at most once a second
  so the throughput and ETA are legible, and it did that by ignoring anything that arrived too soon.
  A job publishes the moment it is **enqueued**, before anything is scanned, so the honest readout
  then is `Zero KB of Zero KB` — and the update carrying the real total arrives microseconds later,
  inside that same second, and was discarded. Nothing publishes again for the length of the
  transfer, so there is no later update to correct it: reported 2026-08-14 as an S3 copy showing
  `Zero KB of Zero KB` for its whole duration. A one-shot `Timer` holding the pending value is the
  whole fix, and it is what makes the rule hold whether or not anything else ever arrives.
  - **A local copy hides it completely**, publishing every 8 MiB, so the readout catches up within
    the second and nobody ever sees the stale text. Only a slow-publishing job exposes it, which is
    why it shipped: the class of bug needs a *rate* to reproduce, not an input.
  - **The tell in the screenshot was two labels disagreeing about the same snapshot.** The status
    line beside it read `Copying DSC_0002.NEF` — correct, and drawn from the same publish — so
    something had certainly been measured. Whenever one field of a rendered snapshot is right and
    its neighbour is stale, suspect the *drawing* rule rather than the data.
  - Testable directly, which is worth doing because the fix is a timer and timers are where "it
    works when I try it" lives: drive `update(with:)` twice inside the window, then poll (never a
    run-loop spin) for the label to change on its own. Put the dropping version back as the negative
    control — it reproduces the user's screenshot verbatim, which is what proves the test and the
    report are about the same thing.
- **A view hidden when its work ends keeps the last value it was drawn with, and that value is what
  the user sees first the next time it appears.** Nothing on the queue bar is a live reading — the
  fraction, the byte readout and the status line all come from a `QueueSnapshot` and stay until the
  next one replaces them — and the window controller's idle branch hid the bar without drawing
  anything, so a drained queue left the previous batch's numbers standing on a bar that was merely
  off screen. Measured in the running app with the presentation layer sampled at 4 ms: the second
  copy of a file unhid the bar reading **1.00** and only then set it to 0. Reported 2026-08-19 as a
  bar that "starts at 100 %, drops to zero, and only then runs" — on the queue bar *and* on Quick
  View's placeholder card, which is hidden between downloads for the same reason and had the same
  bug. Reset when the work ends rather than when it starts: an idle snapshot now empties the bar, so
  the reset happens while it is off screen and there is no frame to catch.
  - **The inherited value is whatever was last *drawn*, which is why the report said "50–100 %"
    rather than "100 %".** A transfer that reports its final bytes together with its completion —
    an S3 upload does, the exact remainder arriving with the terminal snapshot nobody draws — hands
    the next batch something nearer half. A range in a bug report is a fact about the mechanism, not
    vagueness on the reporter's part.
  - **Two probes were needed because the model and the screen disagree, and only one of them is the
    bug.** `NSProgressIndicator` snaps its *model* — `cacheDisplay` into a bitmap showed the value
    change instantly and would have cleared the code — while its **presentation** layer carries an
    `overallDeterminateAnimation` whose width is what is actually on screen (a rise animates over
    ~500 ms, a fall settles within one frame). Read the presentation layer for anything about what a
    progress bar *shows*; the same rule this file already states for `layer.presentation()`.
  - **`AsyncStream` and an actor hop made the obvious cause the wrong one.** The natural reading is
    that the aggregate is stale — the queue keeps finished jobs, and `clearFinished` is dispatched
    in a `Task` — and `FileOperationQueue.clearFinished`'s own doc comment predicts exactly this
    symptom. Instrumenting `update(with:)` in the running app settled it in one run: every fraction
    was correct, including the new batch's first, and the only wrong number was the one already on
    the bar. When a value is right in the data and wrong on screen, instrument the *drawing*.
  - The app is drivable for this headlessly: seed `Dirnex.tabs.left`/`.right` in the defaults domain
    (back it up with `defaults export` first), run the binary from a shell to capture stderr, and
    drive two real copies with the `reveal` and `copy selection` AppleScript verbs. No screenshot,
    no accessibility grant, and the second copy is the one that matters.
  - **Zeroing the value on the way *in* looks like the same fix and is not one, because the model is
    not what the user sees.** Quick View's placeholder card already set `doubleValue = 0` in the
    same turn it unhid its bar (`startPolling` always had), so the *model* reads 0 for the whole of
    the next download — and the fill layer goes on showing the previous transfer's presentation
    until Core Animation catches up. Measured in the running app by sampling the fill layer's
    `presentation()` at 10 ms: a second download opened at **0.96** and reached empty 11 ms later,
    while the model read `0.00` at every sample. The queue bar's own fix worked only because it
    happened to reset the value while the bar was off screen. Reset on the way **out**, and verify
    against the presentation layer or the probe agrees with the bug.
  - **A reset keyed on a state change never runs on the exit that matters, because the ordinary exit
    is not a state change.** The card's first fix sat in `apply(_:)`'s non-downloading branch, which
    covers a transfer that *stopped* or *failed* — while the ordinary end of one hides the card
    outright (the bytes landed, so the surface shows the file) and applies nothing. It shipped inert
    on the only path most users take, and the user re-reported the identical symptom. The tell is a
    view whose disappearance goes through a `standDown`-shaped funnel rather than through its own
    state machine: put the reset in the funnel, and make the test's argument the *exit*, since a
    single-exit test passes against the half-fix (measured — the `.stopped` case passed while the
    show-a-file case failed at 1.0).
- **An `@objc` *optional* delegate requirement implemented on a `@MainActor` class in Swift 6 can
  compile, conform, and never be emitted as an Objective-C method at all — so the framework never
  calls it.** `QuickViewWebView` implemented `webView(_:decidePolicyFor:preferences:decisionHandler:)`
  — the completion-handler spelling — in an `extension … : WKNavigationDelegate`. It built clean, and
  `surface is WKNavigationDelegate` answered **true**, while `class_copyMethodList` over the class
  returned exactly `initWithFrame:`, `initWithCoder:` and `.cxx_destruct`. WebKit dispatches through
  `respondsToSelector:`, so the callback simply never ran and the rule it carried — a link in a
  previewed page must not navigate the preview somewhere else — was quietly absent.
  - **A bare `@objc` makes it worse in an instructive way**: the method appears, under the selector
    derived from the *Swift* labels (`webView:decidePolicyFor:preferences:decisionHandler:`), which is
    still not the requirement's `webView:decidePolicyForNavigationAction:preferences:decisionHandler:`.
    Two spellings, one right, and nothing in the compiler distinguishes them.
  - **The `async` variant is what Swift 6 recognizes as the witness**, and it emits the requirement's
    own selector. Prefer it for any completion-handler delegate method on a main-actor class rather
    than hand-spelling `@objc(...)`.
  - **`responds(to:)` is the assertion; `class_copyMethodList` is the diagnosis.** The first says
    "no" without saying why, and `x is SomeProtocol` says "yes" throughout — dumping the method list
    is what turns it from a puzzle into one line. Assert by **selector string**, not by
    `#selector(SomeProtocol.method)`: the latter resolves against the *protocol*, so it keeps naming
    the right selector even after the class has stopped implementing it, which is precisely the state
    the test exists to catch (same family as the Sparkle selector note above).
  - **The harness that "verified" the broken version is the second lesson.** A throwaway compiled
    with `swiftc` defaults to the **Swift 5** language mode, where the completion-handler method *is*
    the witness — so the probe passed, on the real source file, while the app target it was copied
    from was inert. A harness only agrees with the app about what it was told to agree about; when
    what is under test is *conformance or isolation*, compile it the way the target does
    (`-swift-version 6`) or check the claim inside the app's own test target.
- **A local HTML file previewed in a plain `WKWebView` reaches the network, and the page's own error
  handlers say it did not.** Measured against a real HTTP server on 127.0.0.1 before the M16 backend
  was written: one saved page issued **three** GETs — a stylesheet, an image and a `fetch` — while
  `window.probe` reported `img: 'error'` and `fetch: 'blocked'`, because the *responses* fail CORS
  from a `file://` origin and the *requests* go out regardless. A tracking pixel needs only the
  request, so a preview that renders on cursor movement confirms to a stranger that this Mac opened
  their file. The lesson generalizes past WebKit: **when the thing being measured is "did anything
  leave this machine", the instrument is a server's access log, not the page's opinion** — every
  in-page signal here pointed the wrong way, and a probe that trusted them would have shipped.
  - **Two content-rule-list lines stop all of it, and cost nothing that matters.** Block `.*`, then
    `ignore-previous-rules` for `^file://` — order matters, the second is what re-admits the page's
    own bytes and its local siblings. Re-measured on the same server: **zero** requests, while
    JavaScript still ran, the local stylesheet still applied, and `data:` images — what a
    self-contained report inlines — still loaded, since neither rule matches them. `blob:` is
    collateral and is blocked. So "JavaScript on, network off" is genuinely available: local scripts
    with no network cannot exfiltrate, and they are what makes a MathJax report render instead of
    showing raw LaTeX the way Quick Look does.
    - **But that measurement says the switch is safe to offer, not that it should be on.** Dirnex
      shipped it on for one day and flipped it: a preview renders on **cursor movement**, so scripts
      left on run a file's code because the cursor passed over it rather than because anyone opened
      it. Worth separating the two questions whenever a measurement clears a feature — "is this
      harmful" and "should this happen unasked" have different answers, and only the first is what
      an access log can settle.
  - **`prefers-color-scheme` follows the web view's effective appearance, with no `color-scheme`
    declaration, and re-evaluates live with no reload.** Probed on a real view: flipping
    `view.appearance` moved the page across its own media query (`matchMedia` 0 → 1) while nothing
    navigated. That inverts the natural design for a generated page — M18's plan said to re-generate
    on `viewDidChangeEffectiveAppearance` — and the difference is not cosmetic: a reload throws away
    the user's reading position every time the system crosses sunset. Emit **both** palettes under
    one media query instead. Two neighbors from the same run: `underPageBackgroundColor` already
    resolves to `#1E1E1E` in dark so there is no white flash to fix, and *assigning* it freezes it at
    the current appearance (the captured-`cgColor` trap); and the system fonts have no usable CSS
    family name (`.AppleSystemUIFont`), so the family comes from the CSS generics and only the
    **size** is read from AppKit.
  - **A generated `<svg>` with only a `viewBox` has no intrinsic size, so `max-width: 100%` makes it
    fill its container instead of constraining it.** M18's diagram emitter deliberately omitted
    `width`/`height` on the reasoning that the stylesheet should own the size — and a three-node
    flowchart came up stretched across the whole reading column, its 11 pt labels drawn at twice
    that, beside prose that was the right size. Emit **both**: the natural `width`/`height` *and* the
    `viewBox`, and the `max-width` rule can then only ever scale it down, on a window too narrow to
    hold it. Worth stating because the failure is the exact opposite of what the rule reads as, and
    because no assertion over the markup can see it — 1902 tests passed, and it was obvious in the
    first second of looking at the app.
  - **The rules compile asynchronously, which makes them a precondition rather than a setting.**
    `QuickViewWebView` has no public initializer — `withContentRules` builds one only once the list
    exists, and hands back `nil` if it cannot be compiled, where the caller falls back to showing the
    file as text. A view built before the rules land would render exactly one page unprotected, and
    it is the quietest failure available: the preview looks perfect, and only a server somewhere else
    knows.
- **`loadHTMLString(_:baseURL:)` grants the page no file access at all, and a probe put next to its
  own test data will tell you it does.** M18 needed a *generated* document to reach the sibling image
  a `.md` refers to. The first probe measured six candidates and reported the obvious one working —
  base URL = the document's directory, relative `src`, image loads, even with JavaScript off. It was
  wrong, and the app proved it within a minute of launching: every image a broken icon. The test
  directory had been created **inside the probe binary's own directory**, which the WebContent
  sandbox already lets it read, so what was being measured was the harness's own location. Moving the
  identical bytes one directory sideways flips every answer, and copying the binary next to the data
  flips them back — which is the A/B that settles it in one run.
  - The honest matrix, re-measured against a directory far from every binary: `loadHTMLString` with a
    file base URL **no** (relative *and* absolute `file://` src, so it is the sandbox and not URL
    resolution); `loadFileURL(<temp>, allowingReadAccessTo: <the document's dir>)` **fails to load at
    all** ("Ignoring request to load this main resource because it is outside the sandbox" — the main
    resource must be inside the grant); `loadFileURL(<temp>, allowingReadAccessTo: <temp>)` loads but
    reaches nothing outside it; `loadFileURL(<temp>, allowingReadAccessTo: /)` **yes**; a `data:` URI
    **yes**. A `WKURLSchemeHandler` is asked for the subresource and can serve the *document*, but its
    image responses did not render in either spelling — not pursued once two options measured working.
  - So the two that work are "hand the page the whole disk" and "hand the page the bytes", and the
    second is better on the merits rather than merely simpler: a preview that renders on cursor
    movement then reads exactly the files something decided to give it. Inlining measured cheap —
    **0.4 ms and 1.33× per megabyte** — so the price the plan worried about (holding the bytes twice)
    is not what decides it.
  - The generalizable half: **when a probe's subject is "may this process read that file", the
    probe's own location is part of the experiment.** Nothing about the result looked suspicious —
    six candidates, three clean noes, a control that behaved — and the two noes (`loadFileURL` cases)
    were even *correct*, which is what made the whole matrix read as credible. Put the fixture
    somewhere the harness has no claim on, and re-run one known-good case from a second location
    before believing any of it.
- **`.xhtml` does not conform to `public.html`.** Probed: it is `public.xhtml`, conforming to
  `public.xml` and `public.text` — so a `conforms(to: .html)` gate silently excludes it, which is how
  XHTML sat in the *text* backend unnoticed for the whole life of that exclusion. Name the family's
  types explicitly rather than deriving them from one conformance. (`.shtml` and `.htm` are both
  `public.html`; `.mhtml` and `.webarchive` conform to neither text nor html; `.svg` is an image
  *and* text, so backend order decides it.)
- **The shared `QLPreviewPanel` (⌘Y) is key while open**, so arrows navigate its preview items,
  not the table. `QLPreviewView` is not opaque and `init(frame:style:)` is failable — an
  embedded preview needs an opaque backing or the covered view bleeds through. It also only
  wires magnify-to-zoom for single-page PDFs, so multi-page PDFs route to a PDFKit `PDFView`.
  - **A sheet cannot cover it and cannot keep the keyboard away from it, so a preview left open
    makes every confirmation *unanswerable by keyboard*.** It is a floating panel and it is not the
    window's, so the two halves compound: a delete confirmation raised while ⌘Y is up opens
    **behind** the preview — measured once as entirely hidden but for a sliver of the default
    button — and clicking the panel to move it aside is what then takes key focus away from the
    sheet for good. Return lands on a panel with no default button and **beeps**, while the sheet
    goes on drawing its Delete button as the default *and* on answering the mouse. That is what
    makes it read as "the Enter key isn't bound" rather than as a focus problem, and it is invisible
    to every automated signal: no log, both suites green, and the screenshot is of a perfectly
    ordinary alert. It is also intermittent in a way that hides the cause — ⌘Y → ⇧F8 → ⏎ **works**,
    because the sheet takes key as it opens; only ⌘Y → ⇧F8 → *click the panel* → ⏎ is dead. Reported
    by a user 2026-08-09; three plausible mechanisms (a key monitor, a menu key equivalent stealing
    ⏎, keypad Enter not matching `"\r"`) were each probed and each cleared before the panel was
    suspected. The fix is one `willBeginSheetNotification` observer on the window that orders the
    panel out, rather than a line at each of the ~40 `beginSheetModal` sites — and it must ask
    `sharedPreviewPanelExists()` first, since `QLPreviewPanel.shared()` *creates* the panel.
    - `orderOut` on it is **not synchronous** — it animates — and a panel raised in the *test host*
      (no controller, no preview items) never reports `isVisible == false` afterwards however long
      it is polled. So the close is not assertable there; what a test can pin is that the guard
      never brings a panel into existence.
- **`NSView.clipsToBounds` is `false` by default, and `draw(_:)`'s `dirtyRect` can be larger than
  the view's bounds.** A backing fill of `dirtyRect` therefore paints over the view's *siblings*:
  the full-window Quick View overlay blacked out the sidebar and the function-key bar while its own
  frame was provably correct. The frame is what a screenshot shows, so eyeballing one points at the
  wrong culprit — an `NSLog` of `convert(bounds, to: nil)` settled it in one run. `NSBox` (what the
  M4 overlay used) clips, which is why nothing like this appeared until the container became a
  plain `NSView`. Set `clipsToBounds = true` *and* fill `dirtyRect.intersection(bounds)`.
- **An overlay pinned over a *sibling* subtree drops that subtree's controller out of the responder
  chain.** A preview covering the panes is a child of the content view, not of a pane — so one click
  into the document and every menu command whose selector lives on `PanelViewController` finds no
  target and goes quietly dead, checkmarks and all. Window-wide modes belong on the window
  controller (`view.terminal` was already there for the identical reason with the terminal drawer).
- **Winning the hit test is not the same as consuming the event, and an out-of-process view proves
  it.** `QLPreviewView`'s `QLLayerBasedPreviewContainerView` *answers* `hitTest(_:)` and then declines
  the click, and AppKit re-dispatches to whatever is behind — so a full-window preview let clicks and
  drags through to the file tables it was covering: the covered pane's cursor jumped to the row under
  the photograph, and a drag copied a file to the other pane, both invisibly. The probe is what
  settled it: the hit-test log named the Quick Look view while the cursor still moved, which rules
  out z-order and frames and points straight at the remote view. An overlay that must block the UI
  underneath has to return **`self`** from `hitTest` and override the mouse handlers to *swallow*
  rather than forward — `NSResponder`'s default hands an unhandled click to the next responder, which
  defeats the point. Exempt only the in-process backends that genuinely need the mouse (`PDFView`
  scrolls and zooms; verified separately, since a single-page PDF fitted to the view scrolls nowhere
  and looks like a regression).
  - **The corollary is that Quick Look can never give the user selectable text**, whatever the file.
    A `.txt` preview cannot be dragged across because the surface has to swallow the click, and there
    is no safe version of handing the remote view the mouse. Text therefore takes the route PDFs and
    images already took — decode it (`TextPreview`) and render it in an in-process `NSTextView`,
    where selection and ⌘C are the view's own. Worth stating because "just let this one through"
    looks like the small fix and is the one thing that is not available.
  - **The exemption list is a *set* and the container is a *stack*, so being on the list buys
    nothing if something else is on top — and the thing on top is invisible, which is why it reads
    as a dead button rather than as z-order.** Quick View's placeholder card carries the only
    controls a declined remote fetch offers (Download, Stop), both duly exempted from the blanket
    swallow. `showPlaceholder` then built the card *first* and called `showQuickLook(nil)` after,
    which leaves an item-less `QLPreviewView` **visible** in the same pinned container — added
    second, therefore in front. It renders out of process, so it draws nothing and the card is
    perfect; it answers `hitTest` and declines, so the surface swallowed every press and Download
    was dead for the whole session. Reported by a user 2026-08-14, on the *ordinary* way into the
    mode: ⌃Q with the cursor already on a remote file is a surface whose first content is the card,
    while previewing any local file first builds the Quick Look view early and hides the bug
    completely — so a verification pass that looked at one file before the remote one cannot see it.
    Raise the overlay explicitly (`addSubview(_:positioned: .above, relativeTo: nil)`, a pure
    reorder — probed, the pinning constraints and the frame survive) rather than relying on the
    order two `ensure*` calls happen to run in.
    - It is headlessly testable and worth pinning, because nothing else in the suite can see it:
      every other backend is the only *visible* thing in the container when it is asked about, so
      they pass whatever the ordering is. The test has to show the card on a surface that has
      displayed nothing else, and it needs the narrowness control beside it (a press on the card's
      **body** must still be swallowed) or "raise the card" quietly becomes "let the whole card
      through".
- **A backend the user can click into, inside a preview that covers the *inactive* pane, hands every
  command to the wrong pane.** The pane-mode preview is a subview of the pane it covers, so first
  responder lands inside that pane's hierarchy and the responder chain runs through the **covered**
  pane's `PanelViewController` — one F5 after a click into a text preview copied a folder out of the
  pane nobody was looking at, in the wrong direction and with no dialog. It fails silently and in the
  expensive direction: no error, a real file operation, and the *other* pane is the one on screen. The
  fix is one override — the surface returns the **window** as its `nextResponder` — which is what the
  two full-size modes already do by construction (a sibling of the panes has no pane controller in its
  chain, the note below), so a focused preview makes pane commands find no target instead of the
  wrong one. Note the shape of the override: skip from the *surface*, not from the text view, or an
  unhandled `scrollWheel` stops reaching the enclosing `NSScrollView` and the preview will not scroll.
  Present since the PDF backend shipped; only the text backend made it easy enough to hit.
- **Showing a file as text: the render is free, the *encoding* is where it goes wrong.** Measured on
  a `NSTextView` in a real window: TextKit 2 lays out lazily, so a **64 MiB** document shows in
  ~10 ms and scrolls to its end in ~5 ms — any read limit is about the I/O, not the layout. (Touching
  `.layoutManager` drops the view back to TextKit 1, where forcing layout on the same document takes
  **7 s**; don't reach for it.) Then, probed against real bytes:
  - **UTF-16 with no BOM is valid UTF-8** — its NULs are legal — so a UTF-8-first decode *succeeds*
    and renders `П\0р\0и\0в…` rather than failing over to the right encoding. Foundation's
    `NSString.stringEncoding(for:)` answers **nothing** (0) for those bytes, and nothing for 64 KiB
    of `/bin/ls`, so a NUL byte is the usable "this is not text" signal. Check the BOM (UTF-32's
    little-endian mark *starts with* UTF-16 LE's, so test it first) before that gate.
  - **That detector is right about Windows-1251 and Latin-1, wrong about KOI8-R** — it answers
    "Arabic (Windows)" — **and lossy about MacRoman** (`Caf<?> na夫e` for `Café naïve`). Refuse the
    lossy answers; take the rest. It is what TextEdit shows, and doing better means shipping a
    charset detector.
  - **`NSTextView.textStorage` is *not* the TextKit 1 trapdoor, and `.layoutManager` is** — worth
    stating because it is the natural next worry: `textStorage` is historically
    `layoutManager.textStorage`, so an attributed document installed through it looks like the exact
    thing the warning above forbids. Probed on a real window (macOS 26): `textLayoutManager` is still
    non-`nil` after *reading* `.textStorage` and after a **4 MB** `setAttributedString` through it,
    with `textContentStorage?.textStorage?` measuring identically. So syntax highlighting costs the
    lazy layout nothing — first display **0.03 ms**, scroll-to-end **2.7 ms** — and the real costs
    are elsewhere and are both linear: ~38 ms to *build* the `NSMutableAttributedString` for 4 MB and
    ~20 ms to install it, against 0.47 ms to assign the same text as a plain `String`. Prefer
    `textStorage` over the TextKit-2 spelling anyway: it is non-`nil` in both generations, where
    `textContentStorage?.textStorage?` fails as a **blank preview** if either optional is ever `nil`.
- **An overlay does not disable the `NSSplitView` divider it covers.** The split view keeps its drag
  region *and* its resize cursor whatever is drawn on top, so a full-window preview showed a `< | >`
  cursor over a photograph and a drag there resized two panes nobody could see — the divider was
  found 250 pt away once the preview was dismissed. Return `.zero` from
  `splitView(_:effectiveRect:forDrawnRect:ofDividerAt:)` while the cover is up: it is the one lever
  that withdraws the cursor along with the drag, and it needs
  `invalidateCursorRects(for:)` or the old cursor lingers until the pointer leaves the region. Still
  worth doing even once the overlay swallows the mouse (above): cursor rects are a separate
  mechanism from hit testing, so the `< | >` would otherwise still appear over a photograph.
- **`layer.presentation()` still shows the *previous* position for a frame after you set a
  transform**, so reading it as an animation's `fromValue` right after moving the layer animates from
  where it used to be. A page flip that placed the incoming file at the opposite edge and then read
  the presentation layer brought every new file in from the side it had just left — a bug that reads
  as inverted direction, not as a timing problem. State `fromValue` explicitly whenever the caller
  already knows where it just put the layer; read the presentation layer only when *interrupting* an
  animation in flight, which is the case it exists for.
- **A synthetic scroll event is not a trackpad**, so a two-finger gesture cannot be verified by
  computer-use — the same class of hole as synthetic Escape. `mcp__computer-use__scroll` arrives
  with `hasPreciseScrollingDeltas == false`, `phase == []` and one coarse delta, so any code gated
  on precise deltas (the right gate — a notched wheel's horizontal tilt is not a swipe) is skipped
  entirely. What does work: log the event shape to confirm the monitor is reached, then temporarily
  drop *that one gate* to prove the rest of the chain, and say plainly that the feel is unverified.
- **A two-finger swipe is `NSEvent.trackSwipeEvent`'s job, not yours.** Two hand-rolled versions and
  five rounds of tuning failed to converge, because every quantity the gesture needs is one the OS
  already owns. Measured, in order of how expensive each was to learn: travel a hand intends
  *identically* ranges over 82…611 pt (median 206), so mapping distance to a **count** deals 0–5 rows
  for the same flick; a threshold crossed mid-gesture (median 58 % in) fires while the fingers are
  still down, so the user cannot change their mind; and `scrollingDeltaX` is **acceleration-scaled**
  — 1.00× for a slow swipe against **5.18×** for a fast one over the same glass — so any threshold
  expressed in it silently demands more distance the slower you move, which reads as "I have to flick
  it to make it work". `trackSwipeEvent` answers all of that and gives the feel every other app on the
  machine has. Honor `NSEvent.isSwipeTrackingFromScrollEventsEnabled` rather than substituting your
  own gesture: a user who turned "Swipe between pages" off has already said what they want.
  - **But its *post-lift animation* is not yours to want.** Measured over 17 real swipes: the fingers
    are down **41–123 ms** (median 82) and the animation the OS then runs takes **177–745 ms**
    (median ~600) — five to eight times the gesture that asked for it — delivered as one callback
    every **~18 ms (57 Hz)** on a 120 Hz display, decelerating into a tail that crawls from 0.99 to
    1.0. Hand-driven transform sets at 57 Hz with a long asymptote is exactly what "laggy, and the
    image sticks" describes. Split the gesture at the lift: the system keeps everything before it
    (direction lock, acceleration, the rubber band at the ends, and the velocity-aware *verdict* —
    one measured swipe lifted at **0.07** of a width and still committed, so no distance threshold of
    your own can stand in for it), and you take the travel that is left as an ordinary Core Animation.
    Read the verdict rather than re-deriving it: one callback after the lift the amount is either
    growing towards ±1 or shrinking towards 0.
  - **`.ended` arrives exactly once, at the lift; every callback the OS's own animation makes after
    it carries `phase == 0`.** A take-over guarded on `phase == .ended` therefore sits out the whole
    animation and fires at `isComplete` — after the ~600 ms it existed to pre-empt. It looks correct,
    compiles, runs, and changes nothing, which is the worst shape a bug can have. Record the lift,
    then treat *every* later callback as post-lift whatever its phase.
  - **Finish by swapping outright, not by carrying the old file off first.** The two-segment version
    (run the remainder out, then flip in) needs a hand-off timed to the exit's end, and a second
    swipe arriving mid-flight lands inside it — leaving the surface showing bare backing with the
    header naming a file that is off-screen. One synchronous path has nothing pending to collide
    with, and the incoming slide covers the discontinuity.
  - **This one could only be answered by the user's hands.** A synthetic scroll has
    `hasPreciseScrollingDeltas == false` and never opens a real gesture, so two rounds of plausible
    reasoning about it were both wrong; one instrumented run by the person with the trackpad settled
    it in a minute. Prove the log path works with a synthetic event *first* (it reaches the monitor
    even though it fails the gate), then ask.
  - The corollary is the expensive one: **tested, headless code is not automatically the right place
    for a decision.** `SwipeStepper` was pure, and had 23 passing tests pinning behavior that should
    never have been Dirnex's to define. Tests keep a decision from drifting; they cannot tell you it
    was yours to make.
- **A preview the user can click into takes the mode's own keys away with it, and a *gesture* that
  keeps working is what hides it.** Clicking into the Quick View text view (to select a line) or the
  `PDFView` makes it first responder, and from there it eats the **arrows** — so ← / → stopped
  walking the file list in all three sizes while the two-finger swipe went on flipping perfectly.
  That asymmetry is not luck: the swipe is a *window-scoped monitor*, so no focused view can eat it,
  and every flip it makes ends in `restoreTableFocus`, so it silently repairs the focus the click
  moved. The keyboard had neither half, and the two read as twins, so a pass that verifies the
  gesture proves nothing about the keys. (`PDFView` had it from the day it shipped; the text backend
  is only what made it easy to hit — and that pass's own verification, "← / → still flipped files",
  was run *without clicking into the text first*, which is the one input that cannot expose it.)
  - **A local key monitor runs before responder dispatch, so moving first responder inside it
    delivers that same event to the responder it just set.** Probed in a throwaway app (two views, a
    posted keyDown, the monitor re-pointing focus mid-flight — the key landed in the *new* view).
    That is what lets the fix hand focus back to the table and then **let the key travel** instead of
    swallowing it and re-implementing the step: `FileTableView.keyDown` stays the single definition
    of what an arrow does, ends-of-list and `..` handling included, rather than a second copy in a
    monitor that can drift from it.
  - Take **bare** arrows only. ⇧← must still extend the selection in the text the user is in the
    middle of selecting; without that escape hatch, "the arrows belong to the file list" is not an
    affordable rule.
- **Transforming a layer that hosts an out-of-process view costs a round trip per frame.** A
  `QLPreviewView` renders in another process, so animating it judders visibly ("like 30 fps") — on
  exactly the content a preview swipe is used for. Route images to an in-process `NSImageView`
  (beside the `PDFView` that was already there) and the same animation runs at full rate.
- **Measure a dropped frame against the *layer's own motion*, not a wall-clock window.** A
  `CADisplayLink` sampling `layer.presentation()` every frame is what turns "it lags a bit" into a
  number, and logging the offset alongside the timestamp is what makes the number mean anything: a
  fixed 175 ms window scored the same build as 8 drops or 29 depending on when the slide happened to
  start, because **a ProMotion display idles down the moment nothing moves** and those gaps counted
  as judder. Window on the samples whose offset is non-zero and the metric stops arguing with
  itself. Pair it with a `CFRunLoopObserver` timing each main-thread iteration: for the Quick View
  flip that observer never fired once — **the main thread was never blocked, so the residual judder
  on a big photograph is render-server work and no amount of app-side threading moves it.** Knowing
  which side of that line a stall sits on is worth more than any fix attempted without it.
  - **PDFKit rasterizes page one lazily, and it lands mid-animation.** Parsing is nearly free
    (0.2 ms); the first page render is ~3–8 ms and arrives ~30 ms into the flip, costing four frames
    of it on every flip into a PDF. `document.page(at: 0)?.thumbnail(of:for:)` right after installing
    the document pays it while nothing is moving. This was the one app-side cause that measured.
  - **Three plausible fixes measured worse or identical, and all three are reverted.** Decoding
    images off-main via `CGImageSourceCreateThumbnailAtIndex` (so `NSImage(data:)`'s draw-time decode
    can't stall the slide) was *worse* — 36 dropped frames against 19 — because it re-pays a full
    decode per visit where `NSImage`'s own caching did not; adding an LRU store and neighbor
    prefetching on top brought it back to exactly par (13/13 against the plain path's 11/15), not
    better; and deferring the animation one run-loop turn so the texture lands first was worse again.
    A/B them in one binary behind an env var and alternate the runs — run-to-run variance is large
    enough that a single pair of runs will happily "prove" either direction.
- **`NSImageView` defends its image's size at priority 750, so a big image resizes the *window*.**
  An 8629 px panorama pushed the constraint chain outward until the window ran past the edge of the
  display and the function bar was cut off — while every frame *inside* the preview was provably
  correct, which sends you looking in the wrong place. Pin its compression resistance and hugging to
  the floor whenever it is a passenger in a layout rather than the thing being sized.
- **ImageIO identifies a file by its *name*, so `NSImage(data:)` cannot read a camera RAW at all —
  and what it returns instead is a plausible picture.** A NEF is a TIFF container, so bytes handed
  over with no name identify as `public.tiff` and the embedded **160×120** thumbnail comes back as
  the primary image; at its 300 dpi that is 38 pt, which `scaleProportionallyDown` will not upscale,
  so the preview draws a postage stamp with nothing logged (reported 2026-08-14). The control that
  settles the mechanism in one run is renaming the file to `.dat`: **every** route then collapses to
  160×120, including `CGImageSourceCreateWithURL`, which otherwise needs no hint at all because it
  can see the name. Generalizes past RAW — any format ambiguous from its bytes has this shape, and
  `Data` is where the name is thrown away.
  - **`CGImageSourceCreateImageAtIndex` does not apply EXIF orientation and `NSImage(data:)` does**,
    so "hand ImageIO the file name" is a fix that lays every portrait photograph on its side, JPEGs
    included. Measured on a JPEG tagged orientation 6: `NSImage(data:)` → 400×800, `CreateImageAtIndex`
    → 800×400. The one ImageIO spelling that transforms is
    `CGImageSourceCreateThumbnailAtIndex(…WithTransform: true)` — and it is not the safe uniform
    answer it looks like: with `maxPixelSize` set to the image's own larger dimension it returns full
    resolution, but it **diverged from a true demosaic on one RAW of five** (8.69 levels mean, with
    *higher* apparent detail, which is the shape of the camera's own sharpened preview). So it can
    silently substitute the embedded JPEG for the decode.
  - **`CIRAWFilter` is the RAW route, and it is not a quality upgrade — it is an orientation and
    speed one.** Measured at 1:1 over ARW/CR2/NEF/RW2/DNG, centre and edge, it agrees with
    `CreateImageAtIndex` to **0.02–0.10** levels of 255 with identical variance-of-Laplacian: the same
    demosaic. It applies orientation, and it is **3–4×** faster (99–170 ms against 370–509 ms) being
    GPU-backed. It handles RAW *only*, so it is a branch beside `NSImage(data:)` and never a
    replacement. Route on the `.rawImage` conformance rather than an extension list: of 24 RAW
    extensions checked, 21 resolve to a declared UTI and all 21 are among the 30 RAW types ImageIO
    knows, while `x3f`, `gpr` and `kdc` resolve to `dyn.…` types that conform to nothing — so they
    already fail an `.image` gate and route to Quick Look untouched.
  - **`CIContext.createCGImage` returns a *lazy* image in 0 ms and defers the whole demosaic to
    whoever first draws it**, which is the main thread, for 223–241 ms, on a preview that appears on
    cursor movement. So decoding "off the main actor" through it moves nothing; it relocates the
    stall. `render(_:toBitmap:)` does the work where it is called, and the finished bitmap draws
    cheaper afterwards too (7–9 ms against 18 ms). Render into a bitmap you own whenever the point of
    the call is *where* the work happens.
    - **Three natural assertions cannot see the lazy version**, which is why it shipped for an hour:
      the dimensions are right either way (five RAW files in 0.26 s — the tell is that it is faster
      than one decode), reading `dataProvider.data` merely **forces** the render it was meant to
      detect, and timing `decode` against a 20 ms floor failed by **16 µs**, since setting a RAW
      filter up costs about that much on its own. What discriminates is the *residual* work after the
      call returns — **0.0 ms** against 68–132 ms — which is a property rather than a stopwatch
      reading and so does not drift with the machine.
  - **An apparent quality difference measured at reduced scale was the harness**, not the decodes: a
    16-bit Display P3 image and an 8-bit `DeviceRGB` one drawn scaled into one context differ by 2–7
    levels over 23–72 % of pixels, while at 1:1 they are identical. Compare decodes at 1:1; a
    downscale is a second operation and it is the one being measured. (Core Image's own default output
    is that untagged `DeviceRGB`, so tag it explicitly or the preview's colour is whatever the display
    assumes.)
- **An animation that announces a change has to be timed against the change, not against the
  gesture — and "the content is up by now" is an assumption with a *rate* in it, so it expires
  silently the day something gets slower.** Quick View's page turn ran its 160 ms slide the instant
  the cursor moved, which was right while every image arrived within a frame or two, and became
  "slides the current image and only then changes it to the next one" the day RAW files started
  taking a real decode (149–231 ms, measured in the app). Nothing broke; the assumption simply came
  due, and the tell is that the *movement stops meaning what it said*.
  - **Instrumenting it answered a design question, not just the diagnosis.** The log showed
    `showImage` entered in the **same millisecond** as `flip` — so the load starts synchronously
    inside `advance()` even though it finishes much later, which is what makes a "still loading" flag
    visible to the caller and the fix four lines instead of a redesign. Worth checking rather than
    assuming, because this file's own warning about a selection notification landing a runloop later
    predicts the opposite and would have sent the fix somewhere much larger.
  - **Bound the wait.** Holding the animation until the content lands is right; holding it forever on
    a file that never decodes leaves the surface still, which is worse than the bug. Past the bound
    the old behaviour returns — wrong-looking rather than stuck.
  - **The assertion is the animation object, not the pixels.** A `CABasicAnimation` installed under a
    known key answers "has the page turned" with no window, no screenshot and no wait, which is the
    only reason this class is testable at all — the visible symptom is a 160 ms window that no
    screenshot will reliably catch. Pair it with the narrowness controls (it *does* slide at once
    when nothing is loading; a flip cancelled with the surface is not revived by a late load), or
    "wait for content" quietly becomes "never animate".
- **Verify a probe before spending someone else's time on it.** `NSEvent.touches(matching:in:)`
  raises on a scroll event and silently unwound the event monitor it was added to — so the feature
  under measurement stopped working, the document panned instead, and three rounds of a user's
  hands-on testing measured the instrumentation rather than the code. Nothing was logged, no
  exception surfaced, and the app kept running. A probe that cannot be exercised by the author needs
  a path that can: dropping one gate so a synthetic event reaches it proved the logging in one run.
- **A window posts no mouse-moved events unless `acceptsMouseMovedEvents` is set** — an
  `NSTrackingArea` carrying `.mouseMoved` is not enough on its own. A header meant to fade in on
  pointer movement simply never appears, with no error anywhere.
- **Constraining a content-view subview to a view *inside* an `NSSplitView` works and is the way to
  overlay panes.** An `NSSplitView` treats a plain subview as a pane, so the overlay cannot be added
  to it; anchoring across the hierarchy to its edges tracks the divider, the sidebar and the drawer
  for free. Anchor the *top* to `safeAreaLayoutGuide`, though — a window with `.fullSizeContentView`
  runs its content under the transparent title bar, and anything pinned to the bare top edge draws
  through the titlebar accessories living up there.
- **A new VFS backend that is a *place* has to be named at every site that lists the old ones, and
  the compiler checks none of them.** `PathBarView`'s location chain ends in an `else` that draws the
  search-results label, so a freshly connected FTP server's path bar read **"Results for /"** — the
  results phrasing, on a server nobody searched. Four more gates had the identical shape, each
  spelling `isSFTP` where it meant *"a real remote directory"*: the `wasVirtual` capture in
  `navigate` (which decides whether back/forward survives), ⌘C validation, the copy-destination
  guard, and the clipboard guard. All five compiled and all five were wrong; only connecting showed
  it. When adding a backend, grep for the previous one's predicate and read every hit — an `else`
  branch is where the omission hides, and its fallback is usually the *most* misleading option.
  - **The fix that survives the *next* backend is a name, not a third disjunct**, and S3 is where
    that was paid: `isRemoteConnection` now answers the question all five sites were really asking
    ("re-listable, and not on this disk"), so adding a backend is one line rather than five hits to
    find. The half worth stating is that it needed a **second** predicate, not a bigger one —
    `acceptsUploads`, which S3 is deliberately absent from while it is read-only, because the
    copy-destination guard is the one site asking a different question. Collapsing the two is the
    tempting simplification and it fails in the expensive direction: F5 would start a job that dies
    inside the queue instead of saying up front that the other panel cannot receive files.
  - **A backend with no dates is a second thing the compiler cannot see.** An S3 folder is a common
    prefix rather than an object, so it has no `LastModified` at all, and the Date column rendered
    the `.distantPast` every such producer already used as **01.01.1, 02:02** — a date, in a column
    of dates, for a row that has none. `FileEntry.unknownDate` names it (four producers were already
    spelling it) and one check at the display layer draws the same dash the Size column uses for an
    unmeasured folder. No fixture can catch it, since every listing fixture carries a real date; it
    was obvious in the first second of looking at the app.
  - **A backend's *root* is a third, and it hides in the one place a name is hardest to notice
    missing: `lastComponent` at a root is `"/"`, which is not empty, not wrong-looking, and not a
    crash.** `VFSPath.displayName` had a branch for an archive, for SFTP and for FTP and none for S3,
    so a bucket-root tab chip read `/` **directly above a crumb reading `probe — 127.0.0.1`** — the
    exact contradiction that property's own doc comment was written to prevent, one backend later.
    The same `"/"` reached a sentence: F7 offered «Create a folder in "/"», there via
    `creationDirectoryName`'s `lastComponent`, which means an SFTP or FTP root had said it since
    those shipped. Two lessons past "name the new backend": a **root title is wanted at two
    different depths** — `displayName` needs it only at the root, the path bar's crumb needs it at
    every depth — so keeping them in one property (`backendRootTitle`) is what stops the pair from
    drifting, which they already had; and a sentence that *interpolates a path component* is a site
    that lists backends without looking like one, so it is invisible to a grep for the previous
    backend's predicate.
- **A subview that overflows its superview draws perfectly and is unclickable, because `NSView` does
  not clip and hit testing *does* respect bounds.** This is the `clipsToBounds` note above from the
  other side, and the symptom is the opposite of informative: the control is on screen, correctly
  placed, correctly drawn, and every click on it goes nowhere — no log, no error, nothing to see.
  M21's bucket-picker button arrived this way. `ConnectServerForm` pins **every control it is handed**
  to the form's 364 pt column, so a row built as `[field, button]` and handed over as its *field*
  sized the field to 364 and left the enclosing stack 34 pt wider than its `NSGridView` cell. Hand
  the layout the **row**, not the thing inside it — and the general form of the rule is that when a
  container sizes what it is given, what you give it has to be what you want sized.
  - **Instrument it rather than reasoning about it.** Two rounds of plausible theories (a menu that
    failed to pop, a dealloc'd target, a modal sheet eating the click) were all wrong; one `NSLog` in
    the action, with the binary run from a shell, settled in a single run that the action was never
    reached at all — which is what turns "why does the menu not appear" into "the click never
    arrives", a completely different hunt.
- **`NSProgressIndicator.isDisplayedWhenStopped = false` stops it *drawing*, not *existing*, so a
  stopped spinner laid over a control eats every click that lands on it.** Measured on the same
  button, immediately after the frame bug above was fixed: the spinner is centered on a 28 pt button
  and is the last subview, so clicks on the **middle** did nothing while clicks on the **rim** fired
  the action perfectly. That asymmetry is the tell, and it is worse than a dead control — half of it
  works, so it reads as a flaky click or a mis-aimed cursor rather than as a bug. The property is
  about drawing; use `isHidden` for the overlay, since a hidden view is not hit-tested. Watch for it
  anywhere a spinner shares a frame with what it is reporting on, which is the natural way to build a
  button that shows its own progress without changing width.
- **An `NSFilePromiseProvider` can carry a private pasteboard type alongside its promise, and that
  is what keeps one drag from being two.** Measured 2026-08-26 on a real board while building M23's
  drag-out: a subclass overriding `writableTypes(for:)`, `writingOptions(forType:pasteboard:)` and
  `pasteboardPropertyList(forType:)` adds `com.dirnex.locations` to the promise's own types, and a
  **mixed** drag of one promise plus one plain `NSPasteboardItem` then exposes that type on **both**
  items, hands `readObjects` only the local URL, and still advertises `Apple files promise pasteboard
  type` at board level. So one drag serves Finder and serves the app's own drop handler, rather than
  the app accepting its own promise and round-tripping a server's file through this Mac.
  `NSFilePromiseProvider` **does** implement `writingOptionsForType:pasteboard:`, so the `override`
  compiles — worth checking rather than assuming, since it is an *optional* `NSPasteboardWriting`
  member and implementing it without `override` would silently strip the promised-ness of the
  superclass's own types.
  - **The Swift label and the Objective-C selector differ on the one method AppKit dispatches
    dynamically**: the requirement is `filePromiseProvider:writePromiseToURL:completionHandler:`
    while Swift spells it `writePromiseTo:`. That is the gap that swallowed `QuickViewWebView`'s
    delegate method (▸ above), so assert by **selector string** and confirm it in the built
    `Dirnex.debug.dylib` (`strings - <dylib> | grep '^filePromiseProvider:writePromiseToURL:'`), not
    only in a test.
  - **`fileType` raises for a UTI conforming to neither `public.data` nor `public.directory`**, and a
    name with no extension resolves to no UTI at all — so the `public.data` floor is not defensive
    tidiness, it is what stops a file called `README` from throwing while its neighbour drags fine.
  - **Not implementing `operationQueueForFilePromiseProvider:` puts the write on the *main* operation
    queue** (AppKit's documented default), so the callback arrives on the main thread — but the
    requirement is `NS_SWIFT_NONISOLATED`, and Swift 6 refuses to *send* the provider across an actor
    boundary because `NSFilePromiseProvider` is not `Sendable`. Read the row off it **before** the
    hop and send the `FileEntry` instead; the value is what the work needs anyway.
- **A promise runs outside every progress surface the app has, so the completion handler is the only
  thing that can report — and there are three ways to get that wrong, not one.** Unanswered is a
  beachball in somebody else's app; answered with `nil` after a failed transfer is a **zero-byte
  file** under the right name, which is worse, because nothing anywhere then says the bytes are
  missing; and answered *twice* is as wrong as never, which is why the test's observable is a
  **count** rather than a `Bool`. The paths that had to be taught to answer were the two that
  deliberately report nothing to anybody else: `RemoteFetchPrompt` swallows `CancellationError` (the
  user's own answer, already on screen), and the fetch funnel's `guard let cache = host?…` returns
  having started nothing. Both are correct for every gesture but the one holding somebody else's
  callback.
  - **The delegate is held `weak`**, which is a lifetime question and also a *test* trap: a fixture
    that binds the host to `_` deallocates it before the fetch starts, so every test then measures
    the no-host path instead of the one it named — and it fails as a plausible-looking
    `NSCocoaErrorDomain 256` rather than as "your fixture is wrong".
  - **A test that drives the failure path needs a window**, because a failed drag-out is a gesture
    somebody made and therefore keeps the `runModal` fallback (▸ the who-is-waiting rule above). With
    no window that is an app-modal alert blocking the entire run until a human clicks it — measured
    here first hand, as a run that simply never finished. **And with one it destabilises the
    neighbours**, which is the reason such a test was written, measured and then deleted: hosting a
    live pane in a window makes it do real pane work in the test host, and over 17 full runs that one
    test took the suite from **9/9 green to 7/8**, every failure landing in `PanelPassiveRefreshTests`
    — the suite that measures whether anything repainted and is documented above as starving on
    exactly this. The bisect is what settles it and is cheap:
    `-skip-testing:<Suite>/<oneTest>` over four runs, against a baseline of the unchanged tree, which
    is also what stops "it was green before" being read as evidence about the code rather than about
    the machine.

- **LaunchServices is keyed by *type* and `NSSharingServicePicker` by *items*, so only one of the two
  hand-off gestures can show its list before the files exist.** Open With's list is
  `urlsForApplications(toOpen: UTType)` — already measured to answer identically to the per-URL
  overload, which is why `OpenWithApplications` collapses a selection to its distinct types — so a
  row whose bytes are on a server can be typed by its **name** and the menu drawn for nothing; the
  transfer starts when an application is picked, and pressing Escape costs the user no bytes at all.
  The share sheet has no such seam: the picker is *initialized with the items*, and which services
  appear, their icons and their order are all derived from them, so Share can only fetch first and
  present afterwards. Worth stating because the two read as one gesture — `handoffTargets` was
  literally one helper serving both — and the asymmetry is in the API's keying rather than in
  anything about the files.
  - The corollary for a **context menu**: `standardShareMenuItem` cannot be built for a selection
    that is not on disk yet, so such a selection gets the registry's own plain *Share…* command
    instead of the system's nested submenu. One item where there would have been a submenu, rather
    than the gesture vanishing the way it did inside an archive.
  - **Type a row that is not here by its name whether or not its bytes are cached.** The tempting
    spelling is a fallback — read the file, and if there is none use the extension — and it makes
    the app list depend on what some earlier preview happened to download. It also quietly retires
    an existing rule: a *local* file deleted between the listing and the right-click has no type and
    must go on offering nothing, where an extension guess would offer applications that then fail.
- **`NSWindow.occlusionState` is the only property that answers "is anybody looking at this pane",
  and `isVisible` is the one everybody reaches for first and is wrong for the commonest case.**
  Probed on macOS 26 against a real window while building the remote poll, which must stand down
  whenever nobody is reading the pane (it costs a billed request on S3): `occlusionState
  .contains(.visible)` goes **false** for a window that is miniaturized, app-hidden, ordered out
  **and one fully covered by another window** — the last of which `isVisible` reports as `true`
  throughout. It answers for a window covered by another *application* too, since occlusion is the
  window server's own bookkeeping rather than the app's. One reading, four states, no bookkeeping to
  keep.
  - **Arm from `didChangeOcclusionState`, never from an activation notification.** The same probe
    caught the trap: at the instant `NSApplicationDidBecomeActive` fires, occlusion still reads
    *not visible* and is corrected a beat later by its own notification. So a gate that reads
    occlusion inside `didBecomeActive` stands the work down at the exact moment it should start —
    and it fails quietly, because the next genuine occlusion change papers over it.
  - **Reading it must not build the pane.** `view.window` *loads* the view, which for a
    `PanelViewController` runs `viewDidLoad` → `activateTab()` → a real listing. `viewIfLoaded?
    .window` is what makes "is anybody looking" a question rather than an event, and it is also what
    keeps a headless test host from opening network connections: an unloaded view is definitionally
    not on screen. Worth an explicit assertion (`viewIfLoaded == nil` after asking), since the
    reverted version passes every *other* test in the suite.
  - **Scope the observer to the pane's own window.** `object: nil` wakes every pane in the process
    on every window's occlusion change — panes in other windows, and in a test host every pane any
    suite has ever built, since suites there retain windows for the process's life. The registration
    has to wait for `viewDidAppear`, since a pane has no window at `viewDidLoad`, which is exactly
    what makes `nil` look necessary.
  - **A timer that is armed and stood down must not key its own state on what the stand-down
    clears.** The poll spaces its next round by subtracting how long it is since the last one
    finished, so a pane uncovered after twenty minutes catches up at once while one flicked away and
    back does not spend a request on the gesture. Both timings were reset whenever the *armed path*
    changed — and `stopRemoteRefresh` nils that path, so **every stand-down threw the timings away**
    and the catch-up silently became "wait out a fresh interval". Invisible at a 15 s floor and an
    hour of staleness at an hour's; no test could see it, because none arms a timer. Caught by
    reading `PROBE fire after 5.0s` in a running app where it should have said `0.0s`. Key the
    measurement **by the path it describes** and ignore a foreign one rather than clearing anything:
    there is then nothing to clear, and the arithmetic moves into the core where a negative control
    can fail on it.

- **Right-click menu items must capture their paths at build time** into `representedObject`,
  and entry-vs-`..` must be decided from the clicked row, not a cursor flag — a right-click on a
  marked row leaves that flag stale.
- **Two colors separated only by alpha will invert somewhere.** A progress track and its ink
  drawn in the same color at 0.25 alpha made an *empty* bar read as the heaviest row on screen,
  because the track owns the full column width where the ink may own a point. No test catches
  this; it was caught in a screenshot.
- **"Maximum contrast" is not the rule for text on a color — the system does not follow it, and
  copying the system is what a user is comparing against.** Measured in both appearances before
  designing the M15 palette: `.controlAccentColor` is `#007AFF`, relative luminance **0.2114**,
  where white scores **4.02:1** and black **5.23:1**. So a WCAG-maximum rule picks *black*, while
  macOS — and Dirnex's own active tab chip, which puts `.alternateSelectedControlTextColor` straight
  onto the accent — draws white. A user who picked a blue barely distinguishable from the one they
  already had would have watched the app's most familiar surface flip to black text. The rule that
  works is **white unless it drops below 3:1, black otherwise**: 3:1 is the floor the system itself
  clears with room to spare, and whenever it *is* black's turn the background is above L=0.3, where
  black scores at least 7:1 — so it never trades legibility for familiarity, it only breaks the tie
  in the band where both choices are legible. Note the two are measured against *different* colors:
  AppKit's emphasized selection is `.selectedContentBackgroundColor` (`#0064E1`, L=0.1455), a darker
  relative of the accent and not the accent itself, and there white wins under either rule.
  - **The corollary is that the Follow-System path must fall back to the system color, not derive
    one.** "An untouched install renders byte-identically" is only a claim you can make if nothing
    is recomputed for it, and the measurement above is exactly why: the derivation and the system
    disagree on the one color that matters most.
  - **A derived foreground is appearance-independent, and that is the only way to claim "legible in
    both appearances".** Only one appearance is on screen at a time, so no screenshot can check the
    other; a luminance test over the user's own sRGB color resolves identically under `.aqua` and
    `.darkAqua`, which is a claim a test can pin.
- **The `.system*` palette is tuned for *fills*, not for text, and in light mode most of it is
  unreadable on white.** "Use a system dynamic color, it resolves per appearance for free" is the
  natural answer to any two-appearance color problem — it is what M17 opened on — and it is only
  half true. Measured against `.textBackgroundColor` in both appearances with alpha composited:

  | | light, on `#FFFFFF` | dark, on `#1E1E1E` |
  |---|---|---|
  | `.systemGreen` · `.systemTeal` · `.systemCyan` · `.systemMint` | **2.22 · 2.16 · 2.16 · 2.12** | 8.25 · 8.97 · 9.48 · 9.38 |
  | `.systemOrange` · `.systemYellow` | **2.31 · 1.51** | 7.47 · 11.81 |
  | `.systemRed` · `.systemBlue` · `.systemPurple` · `.systemIndigo` · `.systemPink` · `.systemGray` | 3.57 · 3.52 · 4.17 · 5.09 · 3.65 · 3.26 | 4.86 · 5.16 · 4.59 · 4.75 · 4.73 · 5.81 |

  Every one of them clears AA on a dark background and half of them sit near **2:1** on a white one —
  and the failures are the hues anything text-shaped wants most. It fails in the direction that hides
  it, too: a developer working in dark mode sees a perfect palette and has no reason to look. The
  shape that works is `NSColor(name:dynamicProvider:)` with an **authored** light value and the system
  color in dark, which keeps everything the system-color answer was *for* (one color object per
  role, resolving itself, no persistence, no Settings) while making the claim testable.
  - `.secondaryLabelColor` and `.tertiaryLabelColor` carry **alpha** (0.50 and 0.26 in light), so
    `usingColorSpace(.sRGB)` alone reports them as pure black at 21:1. Composite onto the background
    before measuring or the two most tempting "muted text" colors score wildly wrong — the tertiary
    one is really **1.88:1** in light and **2.26:1** in dark, i.e. unusable in both.
  - **There is no system color for "a panel slightly off the text background", and the two obvious
    ones are the same color.** Measured against `.textBackgroundColor` for M18's code fences:
    `.windowBackgroundColor` and `.controlBackgroundColor` are **byte-identical** to it in both
    appearances (`#FFFFFF` / `#1E1E1E`), so either as a fill draws an invisible box;
    `.underPageBackgroundColor` is `#A1A1A1` in light and drops the M17 syntax palette to 1.77–3.31:1;
    and `.gridColor` **inverts** — `#E6E6E6` in light but `#1A1A1A` in dark, *darker* than the surface
    it would sit on (1.04:1), where `.separatorColor` behaves in both (1.25 / 1.34:1).
  - **A fill under colored text costs contrast the palette was measured without.** Even the gentlest
    one — `.quaternaryLabelColor` composited, `#E6E6E6` — takes `typeOrTag` from 4.59:1 to **3.68:1**,
    because M17 authored those values against `.textBackgroundColor` and they clear AA *there*. So a
    code fence that carries syntax colors is delimited by a **border** and keeps the page's own
    background; the fill is only safe on inline code, which carries `.textColor` and nothing else.
- **`NSTableView` makes a plain `NSTableRowView` when the delegate declines — in every one of its
  five styles.** Probed rather than assumed, and it inverted a design: a row-view subclass that
  defers to `super` is byte-for-byte the stock drawing, so it can be installed **unconditionally**
  instead of switched in only when a custom color is set. Switching classes as a preference changes
  leaves a reuse pool of the other kind to reason about; deferring leaves nothing to get wrong.
  `interiorBackgroundStyle` is derived from `isEmphasized` (probed: `true` → `.emphasized`, `false`
  → `.normal`), so a custom `drawSelection(in:)` and the cell's own `backgroundStyle` are driven by
  the *same* flag and cannot disagree — which is what lets a cell pick its text color without the
  row view telling it anything.
  - **Only the emphasized half is worth owning.** AppKit's *unemphasized* selection is a pure gray
    in both appearances — `#DCDCDC` light, `#464646` dark, zero saturation in each — so it discards
    the accent's hue on purpose, and in dark mode it is **darker** than the emphasized fill
    (L=0.0612 against 0.1175) rather than fainter. There is no relationship to re-derive: hand the
    inactive pane back to `super` and both panes keep the focus signal they already had.
  - A `swift`-script probe cannot make its window key, so `isEmphasized` reads `false` throughout
    and the two states cannot be told apart that way. Probe the *derivation* (`isEmphasized` set by
    hand on a detached row view) and leave the focus behavior to the app that already ships it.
- **A source list's selection is the same `drawSelection(in:)` — but the shape is a pill, and the
  probe that measures it needs its own override to exist at all.** Owning the sidebar's cursor color
  (the same one the panes draw) meant reproducing AppKit's geometry rather than filling a rectangle:
  measured by letting `super` draw into a bitmap and counting the ink, it is inset **10 pt** on each
  side, the **full row height**, with a corner radius of **8 pt** — constant across widths
  (180/257/400), row heights (24/32) and both appearances. A circular 8 pt arc tracks AppKit's own
  per-scanline edge coverage to within half a pixel, closer than 6, 7, 8.5 or 9.
  - **The probe's trap: a *stock* row (and a bare subclass) draws nothing into `cacheDisplay`.** Two
    rounds read "no fill" and looked like the selection was drawn by the table or a layer somewhere
    else; the same table with a subclass that merely *overrides* `drawSelection` and calls `super`
    renders it perfectly. So the measurement needs the override even when the thing being measured is
    AppKit's own drawing — and put no cell view in the row, or the label's glyphs are what the alpha
    scan finds.
  - **Tinting `super`'s output instead of drawing it was measured and is worse.** Rendering `super`
    into a `CGLayer` and painting the color through its alpha (`.sourceIn`) looks like the
    shape-proof answer and came out **half a point wide on each side** — a fatter pill than AppKit's.
    The hand-drawn path matched more closely than the one that reuses AppKit's own pixels.
  - **A cell cannot tell a selected-but-unfocused row from an ordinary one**: `backgroundStyle` is
    `.normal` for both (probed). That matters because a source list tints the *unfocused* selected
    row's glyph with the accent — a second place the cursor color belongs — so the row view has to
    **push** the color down to its cells from `isSelected`/`isEmphasized`, plus `didAddSubview`,
    since the controller hands the row its color before the cell is attached.
    - **The glyph and the label are two pushed values, not one.** They looked like one — both need a
      color on the filled pill — but the colors mean opposite things: the glyph wears the *cursor
      color itself*, while the label only ever takes the **derived** foreground that stays legible
      *on* that fill. Collapsing them into a single push therefore carried the raw color into the
      unfocused row's text too, so a custom palette recolored the sidebar's names — a change nothing
      asked for, in the one place the user reads rather than scans. Push the glyph's color and the
      label's separately: the label is then untouched in every state but the pill, and the sidebar's
      text reads the same whatever palette is set.
  - **`NSImageView.contentTintColor` is ignored for a template image in an *emphasized*
    `NSTableCellView`** — the cell draws it white regardless, pixel-identical to an untinted control,
    in either assignment order (probed both). It works while the cell is `.normal`, which is the
    half that already looked right, so the bug reads as "the icon didn't follow the label" on
    exactly one of two states: a pale cursor color gave a **black label beside a white glyph**.
    Bake the color into the image instead — draw it and `fill(using: .sourceAtop)`, which replaces
    the color and keeps the coverage, then clear `isTemplate` so there is nothing left for AppKit to
    re-tint. `NSImage.SymbolConfiguration(paletteColors:)` measured identical and is worse: it only
    answers for SF Symbols, while `.sourceAtop` tints any template image. Keep the *original* around
    and re-derive from it, or successive tints compound onto the last copy.
    - **It is the *cell*, not the image view — an `NSButton` inside the same emphasized cell is
      repainted white too.** The rule was written for `NSTableCellView.imageView` and reads as if it
      were about that property; the tree's disclosure triangle is a borderless `NSButton` with a
      template chevron, and it went white on a pale cursor row beside black text, i.e. the identical
      symptom one class further out. Measured on a cell rendered into a bitmap, `contentTintColor`
      set to black on both variants: `.normal` draws the glyph `#000000` either way, while
      `.emphasized` gives the tinted control a `#FFFEFF` glyph (no dark pixel anywhere in the cell)
      and the `.sourceAtop` copy `#000000`. So treat "an emphasized cell repaints template images
      white" as the rule and `contentTintColor` as never load-bearing there, whatever control carries
      the image. Bake only the emphasized half, though — off the cursor a template plus
      `.secondaryLabelColor` keeps resolving against the live appearance, where a baked copy would
      hold whichever appearance it was drawn in until the next render.
    - **The probe needs the cell in a real window *and* a full-bitmap scan.** `cacheDisplay` into
      `bitmapImageRepForCachingDisplay` drew nothing but the background for a detached cell (the same
      "a stock row draws nothing" trap as the pill measurement), and once in a window the rep is at
      the **backing scale** — a scan over point-space coordinates lands in the button's empty margin
      and reports "no glyph" twice over, which reads as the drawing being broken rather than the scan.
      Iterate `rep.pixelsWide`/`pixelsHigh`.
    - **This is also the class of bug a computer-use screenshot cannot judge**, and it was called
      *fixed* off one: a zoom of a 2 pt chevron over a pale row read as dark when the glyph was
      provably white. The capture is downsampled below 1x (the geometry note above), and color goes
      the same way as geometry once the ink is a couple of points wide. `screencapture` from the shell
      tool is refused (no permission), so the bitmap probe is the instrument — not the screen.
  - The window-key state is a third one and is not reachable from either side: states 2 (window key,
    pane focused) and 3 (window not key) both read `isEmphasized == false` with no callback between
    them, so the tint stays on in a background window where macOS would drop it.
- **`installSortedModel` swaps the model; `reloadEverything` is what puts it on screen.** A refresh
  path that installs and returns leaves the pane drawing the rows it already had — no error, no log
  line, just a model and a screen that disagree. Found live when an Empty Trash left the pane listing
  two files that had just been erased. The real-directory refresh ends with
  `reconcileCursorFromTable` → `installSortedModel` → `reloadEverything`; a new refresh path needs
  the same tail.
- **A bare `reloadData` drops the pane's cursor, because the cursor *is* the table's selection.**
  Three marks-only gestures — Invert Selection, ⌘A, Esc-clear — repainted with `tableView
  .reloadData()` and nothing else, so the blue row simply vanished while `panel.cursor` still pointed
  at the right entry: F5/F6/F8 kept working on a target nobody could see, and the pane read as having
  no focus at all. It fails in the quiet direction (no error, no log, and the *marks* are visibly
  correct, which is where the eye goes), and it hid behind the mouse and keyboard paths being fine —
  a Cmd/Shift-click goes through `reloadEverything` and Space through `redrawRow` + `syncCursorToTable`,
  both of which re-apply the cursor. Any full reload has to be followed by `syncCursorToTable(scroll:
  false)` — `false` because nothing moved and the reading position must not jump. One shared
  `redrawAfterSelectionChange` now owns that tail for every marks-only gesture, which is the real fix:
  three call sites each spelling out the same four-line sequence is how one of them ends up missing a
  line.
- **An `NSStackView` that cannot fit its arranged views does not overflow — it *compresses* them**,
  and a checkbox squeezed to nothing is a row that silently disappears. The Get Info panel's
  Permissions tab wants ~384 pt of rows in a ~320 pt tab, and the result was "Locked" overlapping
  "Hidden" with the Locked checkbox gone entirely — a missing row in a *permissions* panel, which is
  the worst possible direction for that surface to fail in. Nothing logs; there is no Auto Layout
  complaint, because the constraints are all satisfiable once something has been squashed. The fix
  is to let the pane scroll rather than to make the sheet taller: a taller sheet hides it in English
  and brings it straight back in a language whose captions and notes are longer (the same family as
  the pack sheet's clipped label column and the sync sheet's crushed segmented control).
  - **A scroll view's document must be flipped and pinned to the *clip view*.** An ordinary `NSView`
    document is bottom-origin, so the first row lands at the bottom of the clip view and everything
    above it is out of sight — the tab comes up **completely blank**, which is what the first attempt
    did. And a document under Auto Layout is not positioned by the scroll view: constrain its top and
    leading to `scrollView.contentView`, or it keeps whatever frame it was born with. Both failures
    look identical from outside (an empty pane), so check the flip before hunting the constraints.
- **A filtered-out row must be omitted, not zeroed.** Rendering an excluded folder as its
  filtered total gives "Zero KB · 0.0 %", which reads as *"measured, and empty"* — a claim about
  the folder where the truth is a claim about the question. Drop such rows from the projection
  entirely, including from any pending-work set, or a row with no total is pending forever and
  gets re-queued on every render.
- **A second row source is a second *index space*, and every site that maps a row to an entry has to
  be found by hand — the compiler sees `Int` on both sides.** The M15 tree renders more rows than the
  directory it is rooted at has entries, so `panel.model[row]` — which had been right for the whole
  life of the app — is an out-of-range crash the first time a user clicks the row *below* the last
  root-level one. Six sites had it (the click anchor, the Cmd/Shift range anchor, drag, drop, the
  context menu's mark check) and each is a plain `Array` subscript on a value that arrived as a table
  row. Three things worth carrying:
  - **It hides behind small test data and shallow gestures.** Every earlier verification pass —
    expand, collapse, arrow keys, disclosure clicks, marking across three levels — went through the
    *tree's* accessors and passed. Only a plain mouse click reaches the anchor code, and only one
    landing past the root's own count crashes, so a two-entry root with one expanded folder is
    already enough to be safe by accident. Click the **last** row of a deep tree.
  - **The tree-aware inverse already existed and was `private`.** `Panel.displayedIndex(ofID:)` was
    written for the cursor restore inside the value type, while every *app* caller reached for
    `panel.model.index(ofID:)` — so the fork was not a missing capability, it was an access level.
    When a value type grows a second row source, its row⇄entry mapping is API in both directions;
    leaving one half private guarantees callers re-derive the wrong one.
  - The general shape: a projection is affordable precisely because everything downstream keeps *one*
    index space (HISTORY.md §M8), and that only holds if nothing reads past the projection to the
    thing it projects. `command grep -n 'model\['` over the app is the whole audit, and it is worth
    running the day any new row source lands rather than waiting for a click to find it.
- **A *persisted* anchor is that same trap one launch later, and it has two independent halves —
  fixing either alone changes nothing.** `PersistedTab` stored the cursor and marks by **leaf name**,
  which is correct for a flat list and cannot address a tree row inside an expanded folder at all; so
  the spelling had to become root-relative, the shape `expandedPaths` was already using. The second
  half is *timing*: a restored tree lists each expanded folder lazily, so at the moment
  `applyPendingRestore` ran after the root's first listing there were no child rows to match against
  — the anchor was correct and the row did not exist yet. The re-apply therefore runs again on every
  restored listing that lands, drops each anchor **as it resolves** (a later pass must not yank a
  cursor the user has since moved), and drops the remainder when the last listing reports in — on
  every exit path, or a folder that fails to list leaves the window open forever. It fails in the
  quiet direction: the cursor is simply at the top, which reads as "restore doesn't cover the cursor"
  rather than as a bug.
  - **A live refresh mirrors the *table's* selection back into the model
    (`reconcileCursorFromTable`), which is what makes the restored cursor checkable with no
    screenshot and no screen-recording grant.** Seed the persisted state, launch from a shell, poke a
    watched directory (`touch` a dot-file inside it) so an FSEvents refresh runs, quit, and read the
    state back: if the *table* were sitting on row 0 while only the model held the nested row, that
    refresh would overwrite the model and the persisted cursor would come back as a root-level entry.
    It survived, so both agree. Worth reaching for whenever the thing to verify is "what is
    selected" — `screencapture` needs a permission the shell tool does not have.

## Localization

Two styles, deliberately: the app's own literals are keyed by their **English text**
(`String(localized: "Relaunch")`, and every SwiftUI literal automatically), so Xcode extracts them
and a missing translation falls back to readable English; `DirnexCore`'s registry strings are keyed
**symbolically by their stable id** (`command.file.copy.title`), because the core ships no resources
and hands its English over as data. `LocalizedCatalog` is the join, `L10n` its one primitive.

- **`Text("a " + "b")` silently does not localize.** The concatenation resolves to a `String`, which
  picks SwiftUI's *verbatim* `Text(_: String)` overload rather than the `LocalizedStringKey` one —
  so the string is never looked up, never extracted, and renders in English with a fully translated
  catalog sitting right there. It compiles, it lints, and it looks identical in an English
  screenshot; eight of these were hiding in the Settings panes and only a Russian run found them.
  Merge into one literal, using `\` line continuations inside a `"""` literal to keep it readable —
  the *literal* has to be single, the source line does not.
- **The same overload pair has a second, opposite trap: a literal that *does* bind to
  `LocalizedStringKey` is parsed as Markdown, so a glob example loses its wildcards.** The M15 color
  rules teach their syntax with `*.jpg;*.png`, which is a valid **emphasis pair** — `*…*` — so the
  rule editor's placeholder and its footer both rendered as an italic ".jpg;" followed by ".png",
  in the two strings whose entire job is to show what a pattern looks like. Note the symmetry with
  the note above, because it is what makes both easy to miss: there, a `String` was wanted as a key
  and silently went verbatim; here, a literal was wanted verbatim and silently went through the
  Markdown parser. It compiles, it lints, and unlike the localization case an **English screenshot
  shows the bug** — but only if you read the sample rather than the sentence, and the eye takes
  ".jpg" for a pattern quite happily. Two fixes, and which one to use depends on whether the string
  is prose: for a *sample* (a placeholder, a code example) hold it in a `String` constant so the call
  resolves to the verbatim overload — a glob is syntax, not something to translate; for *prose that
  contains* a sample, wrap the sample in backticks, which renders it as code and keeps the
  asterisks. Backslash escapes (`\*`) work too and are worse: they reach the translator, who then has
  to know not to touch them.
  - **What it takes is a *pair*, which is why one example is safe and two are not.** Probed through
    `AttributedString(markdown:)`, the parser SwiftUI uses: `*.jpg;*.png` loses both asterisks, while
    a lone `path/to/*.swift`, `one * two` and `50% * 2` all come back **unchanged**. So a placeholder
    showing a single pattern renders perfectly, and the bug arrives the day someone adds a second one
    to be helpful — with no edit to the code that displays it. Backticks were confirmed on the same
    run to preserve the characters exactly.
  - **Underscores are the one to *not* worry about, and guessing gets it backwards.** CommonMark
    ignores intraword `_`, so `my_file_name.txt`, `a_b_c` and `report_2026_final.pdf` are all
    untouched — but `_leading_underscore_` loses its outer pair. Inline `#` is safe too (it is only a
    heading at the start of a block). The one beyond `*` that is worth a look is **`[`**:
    `[a](b)` renders as `a`, so any string carrying bracket-paren text silently loses it.
- **The menu bar's titles were a second copy of the category names.** `MenuSpec(title: "File")`
  duplicated `CommandCategory.file.title`, so translating the registry left the whole menu bar in
  English while every menu's *contents* switched — visible only by launching. `MenuSpec` now carries
  the `CommandCategory` and derives its title, which is the general lesson: a display string that
  exists twice will be localized once.
- **Switch languages via `AppleLanguages` in the app's own defaults domain, not a private lookup.**
  It is the lever System Settings ▸ Language & Region ▸ Applications pulls, so AppKit's stock menu
  items, the open/save panels and Sparkle's dialogs follow along. A homegrown "resolve strings
  against a chosen bundle" scheme switches only *our* strings and leaves the rest in the system
  language — permanently half-translated. The price is that it lands at launch, not live.
- **Read the system's languages from the *global* domain.** `Locale.preferredLanguages` and
  `UserDefaults.standard.stringArray(forKey: "AppleLanguages")` both already reflect our own
  override, so asking either what the *system* prefers hands back our own answer — and "Same as
  System" resolves to whatever was last pinned. Same asymmetry on the way in: reading the pin needs
  `persistentDomain(forName: <bundle id>)`, because the standard search falls through to the global
  domain and would read the system list back as a pin the user never set.
- **A relaunch must wait for the old process to exit, not run alongside it.** Dirnex writes its tabs
  and workspaces on the way down, so an instance launched *before* the terminating one has finished
  restores the previous session and then has it overwritten. A detached
  `while kill -0 <pid>; do sleep 0.1; done; open <bundle>` is the whole fix, and the session came
  back intact across a live language switch because of it.
- **`Command.id` is now a translation key**, as its own doc comment always claimed it would be
  ("never localized, never changes"). Renaming one orphans its translations in every language, and
  nothing in the compiler notices — the English fallback renders, so an untranslated command looks
  *fine* in an English screenshot. `LocalizationCoverageTests` reads the real compiled `.lproj` and
  fails when a command, category or function-bar caption has no entry.
- **Every English name a command has must survive translation into the palette's keywords — the
  registry keywords *and* the English title. Never take either away.** Russian and Ukrainian users
  type on a Latin layout constantly (it is the common case, not an edge case), and English docs,
  screenshots and habits all name commands in English. `LocalizedCatalog` therefore *adds* the
  translated keywords to the core's English ones rather than replacing them, and folds the English
  title in beside them.
  - **The title is the half that was missing, and it is missing for a structural reason: it is the
    one string a translation *replaces*.** A keyword list is merged, so nobody thinks about it; the
    title is overwritten, so the single most obvious search term for a command is exactly the one
    that disappears. `file.copy`'s registry keywords are `f5, duplicate, transfer` — no "copy" — so
    in a Russian build typing `copy` matched **nothing whatsoever**, not even a bad result, while
    the shipped comment above `commandKeywords` claimed the merge already covered this case.
  - **The bug hid behind its own verification.** The pass that added the merge proved it by typing
    `duplicate` and getting «Копировать на другую панель» — a genuine pass of the mechanism that was
    built, over a *keyword*, which is precisely the input that cannot expose the missing title. When
    checking that a translated surface stays reachable in English, type the **title** word, not a
    keyword: the keyword is the case you just wrote code for.
  - Fold the title in **whole**, not split into words: `CommandMatcher` matches a subsequence, so
    "copy" still hits "Copy to Other Panel" with its prefix and boundary bonuses, while splitting
    would add "to", "by" and "the" as terms of their own and let a stopword rank the whole registry.
    Only add it when the displayed title actually differs, so an English build gains nothing.
  - Two tests pin it, and they are language-agnostic on purpose — the app test target inherits
    whatever `AppleLanguages` the developer pinned Dirnex to, so a test that only holds in English
    is a test that fails on the machine of anyone checking a translation.
- **String Catalogs handle multi-argument plurals, but only through `substitutions`.** A plain
  plural variation covers `"Put %lld items back?"`; a sentence with a count *and* another argument
  needs the count declared as a named substitution (`%#@items@` plus `argNum`/`formatSpecifier`) and
  the remaining arguments made positional (`%2$@`). That is also what lets Russian move the verb to
  the front — "Не удалось вернуть %#@items@" — which a fixed word order could not express.
  `xcstringstool` validates it at build time, so a malformed entry fails the build rather than the
  user.
- **The function-bar captions are whole verbs in every language — never abbreviations.** They are
  the app's primary buttons and are permanently on screen, so an abbreviation ("Копир.", "Перемещ.")
  reads as a cramped app rather than as a considered one, and a trailing period reads as a
  truncation bug. The rule, with its rationale, lives in the `comment` of every
  `functionBar.*.label` entry — a translator reads the catalog, not this file — and is restated in
  [HISTORY.md](HISTORY.md) §M12. Russian is the worked example: `Переименовать · Просмотр ·
  Править · Копировать · Переместить · Новая папка · Удалить`.
- **A String Catalog key with no value for the *source* language compiles to the key itself.**
  Not to "absent" — `xcstringstool` writes `functionBar.file.copy.shortLabel` as its own value into
  `en.lproj`, so a lookup succeeds and puts a dotted key on screen. An entry translated for `ru` and
  left blank for `en` is the natural way to write "this language needs no override", and it is a
  trap. `L10n.translation` therefore treats *value == key* as missing, which is safe precisely
  because the keys it serves are symbolic; the English-text keys, where value equals key by design,
  never go through it.
- **`NSStackView.fillEqually` equalizes the surplus, not the views** — it never squeezes an arranged
  view below its intrinsic content width. Measured on the function bar at the 640 pt window minimum:
  cells came out **108 / 94 / 89 / 87.5 / 87.5 / 87**, each sized to its own caption, and every full
  Russian verb ("Переименовать", "Переместить") fitted with room to spare; only above ~1400 pt do the
  cells become equal, because that is when there is surplus to share. So a caption-shortening
  fallback for narrow windows was **unreachable code**, and was written, measured, and deleted in
  the same pass. Two lessons: don't reason about a stack's widths from its distribution constant,
  and a "does it fit" mechanism needs the measurement *before* it is built, not after.
- **Don't derive point geometry from a computer-use screenshot — including for text fitting.** The
  capture is downsampled (1372 px for a 1728 pt display), so a caption that looked comfortably
  inside its cell and one that looked flush against the divider were both unresolvable, and two
  rounds of reasoning off the image contradicted each other. What settled it in one run: an `NSLog`
  in `layout()` dumping `bounds.width` beside the measured title widths, with the binary run from a
  shell. Also: `NSButtonCell.titleRect(forBounds:)` is not a usable measure for a borderless button
  — it returns the bounds unchanged (no reserved padding) and returns **zero width** on an early
  layout pass.
- **A fixed-width label column clips a longer translation.** The pack sheet laid its `Name:` /
  `Format:` captions in a hardcoded 48 pt right-aligned column that the English fit and Russian
  «Формат:» did not — the "т:" was simply cut, invisible in an English screenshot and at build time.
  Size such a column to the *wider of the localized captions* (`ceil(max(label.intrinsicContentSize
  .width, …))`) and offset the field/popup from that, not from a magic number — the same lesson as the
  function bar, applied to a manual frame layout instead of a stack view. An `NSTextField`'s
  `intrinsicContentSize` is a usable measure here (unlike `NSButtonCell.titleRect`, below); it needs no
  window. Only the live Russian run caught it.
- **A file-list column is the same trap in *two* dimensions at once, because its header follows the
  language and its content follows the *region*.** The Date column's default was a hardcoded 150 pt.
  Measured in the row font across regions and the shipped languages: the widest date ranges from
  `28.12.25, 22:58` (de_DE, 110 pt) to `2025. 12. 28. 오후 10:58` (ko_KR, 159) — Finnish inserts a
  word, `en_CA` runs `2025-12-28, 10:58 AM` — while the header spans `Date Modified` (95 pt with its
  sort arrow) to `Fecha de modificación` (139). No single number is right for both axes, and 150 was
  wrong in both directions simultaneously: ~20 pt of empty column in every `dd.MM.yyyy, HH:mm`
  region (what a user reported), and short of the Korean date. `DateColumnMetrics` measures instead.
  Three things it took to get right, none visible at build time:
  - **The wide form of the row font is *bold*, because a marked row is bold.** Size to the unmarked
    text and marking a file truncates its date — a truncation that appears on a keystroke, on rows
    that looked fine a moment earlier.
  - **Measure through the class that draws the cell, not a bare string.** `(s as NSString).size(…)`
    is the typographic advance; the live `FileCellView` came out ~13 pt wider once the text field's
    own padding and the cell's 4 pt insets were in. A `NSTextField`'s `fittingSize` and its
    `intrinsicContentSize` also disagree by ~4.5 pt, so pick the view, not a number.
  - **`NSTableColumn.sizeToFit()` on a *detached* column is the header's own arithmetic** — it fits
    the header cell and nothing else when there is no data source, needs no window, and with
    `setIndicatorImage` in place it accounts for the sort arrow (a constant 17 pt over the bare
    title, in every language). Reserve that slot whether or not the pane is sorted by that column,
    or the title reflows the first time someone clicks it.
  - The cell view gets the **full column width**: `intercellSpacing.width` (17 pt here) sits
    *between* columns, so a 150 pt column really does hand its cell 150 pt. Worth stating because
    the opposite is the natural worry once that 17 is known, and it would inflate every such
    measurement.
- **Measure a checkbox grid against every language *before* laying it out — and count the label
  column as part of the budget.** The ACL editor's rights matrix is 12 or 13 checkboxes whose labels
  are phrases ("Write Extended Attributes"), and the arithmetic decided the layout rather than
  confirming it. Measured in the real font over all 14 shipped languages, with `NSButton(
  checkboxWithTitle:).intrinsicContentSize` (a usable measure, like `NSTextField`'s and unlike
  `NSButtonCell.titleRect`; it needs no window):
  - Three columns need **506 pt** against the 410 an `AttributeRow` label column leaves — so *English
    itself* clipped "Execute" and "Append", which is the rare case where the English screenshot does
    show the bug.
  - Two columns in that same 410 fit English at 332 and **overflow Russian at 436**
    («Изменять расширенные атрибуты»), with Polish, Dutch and Ukrainian clearing by **4 pt** — which
    is not clearance, it is the next translation's bug.
  - The 130 pt label column is what costs it. Moving the caption *above* the grid gives the full
    548, where the worst language needs 436 and has 112 pt spare. **A grid is not a form row**: the
    `Label:  value` column that suits a popup or a date field is exactly the wrong frame for a block
    of checkboxes.
  - The same run caught a second overflow that no English screenshot could: the four inheritance
    checkboxes in one row need **589 pt in Ukrainian** and 579 in Russian against 548 available,
    while English fits at 486. 2 × 2 fits every language at 348.
  - Reach for the measurement first — it is a 20-line throwaway that reads the real catalog — and let
    a scrolling pane carry whatever a future translation adds anyway.
- **A *placeholder* cannot be measured the way a label is, and the two natural instruments both
  answer "it fits" for every language.** Measuring the S3 bucket field's hint across the 14
  catalogs: `field.placeholderString = text; field.fittingSize.width` reads **0.0**, and
  `field.stringValue = text; field.intrinsicContentSize.width` reads **-1.0** — `noIntrinsicMetric`,
  because a bare `NSTextField()` is a *wrapping* cell (see the single-line note above) and an
  editable field has no intrinsic width to give. Both are silent, and both fail in the reassuring
  direction: a table of zeros under a budget looks like clearance. What works is the text as a
  **value** in `NSTextField(string:)` — single-line by construction — with `sizeToFit()` and the
  resulting frame, which then reports the real 165–320 pt spread and finds the languages to shorten
  (Polish cleared a 330 pt field by 10 pt, which the note above says is not clearance). A
  placeholder is drawn in the value's own rect with the value's font, so measuring the value is the
  honest proxy; measuring the placeholder measures nothing at all.
- **A fixed-width horizontal `NSStackView` collapses a *segmented control* under a longer
  translation, not just a label.** The sync sheet's controls row (`Направление:` + a 3-segment
  direction control + `Сравнивать по:` + a 2-segment comparison control + a hint, pinned to 680 pt)
  read fine in English and, in Russian, squeezed the direction control down to a single unreadable
  «…» while the row *looked* laid out. Measured (an `NSLog` of each arranged subview's
  `intrinsicContentSize.width`, run from a shell — **not** eyeballed off the downsampled screenshot,
  which cannot resolve it): the row demanded **1163 pt** in 680 — the direction control alone wanted
  345 pt against English's ~250, the comparison control 233, and even dropping the hint the controls
  needed ~810. Two-part fix: (1) lower the **hint's** horizontal compression resistance
  (`.defaultLow`) so it is the element that truncates away — language-agnostic, and it stops the
  controls collapsing whatever the translation; (2) shorten the Russian segment labels so the
  controls' own intrinsic total drops under 680 (`Слева направо`→`Направо`, `В обе стороны`→`Обе`,
  `Справа налево`→`Налево`, 345→190 pt), then re-measure to confirm. Equal (750) compression
  resistance across every arranged view is why it collapsed the *wrong* thing; a segmented control
  has no `lineBreakMode` escape hatch, so it just crushes its cells.
- **A wrapping `NSTextField` with no width constraint does not wrap — it overruns.** It takes its
  *intrinsic single-line* width, so the connect sheet's plain-FTP note ran past the sheet's edge in
  Russian and lost its final period, while the shorter English text happened to fit. This is the
  third instance of the same family (after the pack sheet's fixed label column and the sync sheet's
  segmented controls) and the cheapest to prevent: give such a label the same width constraint the
  fields get, and measure the layout's reserved height with it *visible* so the second line is
  already accounted for. As with the other two, only the live Russian run showed it.
- **When a control's width is fixed by what it lines up with, the text has to leave — put a glyph in
  it and the words in the tooltip.** The Shortcuts tab's recorder pill is 148 pt because it forms a
  column with the shortcuts themselves (`⌥F5`, `⌘⇧N`), so none of the three fixes above applies:
  there is nothing to widen, nothing to compress, and the placeholder is the *only* thing in the
  pill. Measured in the pill's own font, "Add Shortcut" is 89 pt and its translations reach 215 pt
  (uk, de) and **252 pt** (it) — 7 of the 14 shipped languages over budget, and "Type shortcut…"
  another 5 — and because the label was merely centered with no width constraint it *overran* on both
  sides rather than truncating, so the words spilled outside the rounded rect. A `plus` symbol
  (recording: `keyboard`) fits every language by construction, and the tooltip has no width to
  overrun: the existing keys were reused, so all 14 translations carried over unchanged and their
  fuller phrasing ("Додати клавіатурне скорочення") now reads as an improvement rather than a
  clipped label. Set the same string as the accessibility label — a glyph-only pill is otherwise
  silent to VoiceOver. The general rule: prose belongs where its length is free; a fixed-width
  control is not that place, whatever the English happens to measure.
  - The one thing a glyph cannot say is *which* state you are in, so the two placeholder states must
    stay visually distinct without words — here the accent ring and tint already carried recording,
    and the glyph change is a second, redundant signal rather than the only one.
- **The status line under each pane is the same trap with the failure inverted: it is *correctly*
  set to truncate, so an over-long sentence loses its own ending and nothing anywhere complains.**
  `statusLabel` is `.byTruncatingTail` at `.defaultLow` compression resistance — deliberately, or a
  long type-to-filter string would shove the split divider across — which means the four preceding
  entries' remedies (widen it, compress a neighbor, constrain and wrap) are all unavailable by
  design, and the only lever left is the sentence's own length. What goes missing is the **tail**,
  which in an explanatory sentence is the explanation: M21 Slice 11's give-up message rendered as
  `Stopped measuring “x” — it holds more folders than Dirnex will…`, i.e. the half stating *why* was
  exactly the half cut. Measured in the label's own font across all 14 catalogs — **557 pt in
  English, 713 pt in Russian** against a pane of **542 pt** — it clipped in **10 of 14 languages**
  while the English screenshot with a short folder name looked perfect.
  - **`statusLabel.frame.width` is not the width available, and reading it is the trap that looks
    like the fix.** The label is sized to its own text, so its frame is the *sentence* plus ~3.5 pt
    — logging it during the give-up reported **409.5 pt** for a 406 pt sentence and **282.5** for a
    279 pt one, i.e. it measures the string you already have. Acting on it shortened a sentence that
    did not need shortening and, worse, wrote a fabricated "the label is 409.5 pt" into three files.
    Ask the **enclosing stack** for the constraint, and ask
    **`NSCell.expansionFrame(withFrame:in:)`** whether the text is actually truncated — AppKit's own
    answer, on the real label in the real pane, which needs no arithmetic and cannot be off by a
    sidebar. The general form: *a live probe is only a measurement of what you actually asked for*,
    and "I logged it from the running app" is not by itself evidence.
  - **Budget below the pane, not at it, because the interpolated file name is unbounded.** A
    40-character folder puts even a short sentence at 468 pt, so no wording makes truncation
    impossible — only unlikely. Which is what decides the *design*: a short note on the status line,
    and the explanation in a **tooltip** on the cell, where length is free and where it outlives the
    status line's four-second expiry. A glyph whose only explanation expires is unexplained for
    anyone who looked away.
  - **Sweep the whole surface once while the harness is written.** Harvesting every literal that
    reaches `showTransientStatus` and measuring all 18 took minutes and settled that no *other*
    sentence was over — which is what makes "the new one is the outlier" a measurement rather than
    a hope, and would have named the others if it were not.
  - Pin it with a test that reads the **compiled** `.strings` (a catalog entry can be absent from
    the build) and give it a negative control, or a later shortening leaves a budget nobody has
    watched fail.
- **Resizing a window for a probe: `defaults write "NSWindow Frame <autosave>"` then relaunch.**
  `System Events` needs assistive access that `osascript` does not have (`-1719`), Dirnex's `.sdef`
  exposes no windows (`-1728`), and a synthetic corner drag misses the resize edge. The frame
  autosave key is deterministic and gives exact point widths.
- **The app test target inherits the developer's own `AppleLanguages` pin.** `xcodebuild test` runs
  the tests *in the app*, so pinning Dirnex to Russian to check a translation makes any test
  asserting English display text fail — `AutomationIntentsTests` was asserting `"Copy to Other
  Panel"` when what it meant was "the Shortcuts entity draws its name from the registry". Assert
  against `LocalizedCatalog`, not against literals, and the suite passes in either language (both
  were run to prove it).
  - **It bites for a *system* framework's strings too, not just our own.**
    `OpenWithLauncherTests` asserted `"TextEdit"` and, under a Ukrainian pin, read
    «Мініредактор» — Apple localizes that app's `CFBundleDisplayName`, in `uk` but **not** in `en`
    or `ru`, so the literal held through every earlier language check and failed on the first
    Ukrainian run. There is no catalog of ours to assert against, so the shape that works is to
    guard the literal by the condition that makes it true —
    `Bundle(url:)?.preferredLocalizations.first?.hasPrefix("en")` — and keep the
    language-independent claims (no `.app` suffix, the bundle id) unconditional. Those are the
    claims the test existed for anyway; the app name was the incidental part.
- **Endonyms are data, not strings.** The language picker lists each language in its own language
  ("Русский", not "Russian"), because a user stranded in a UI they cannot read has to be able to
  find the way back. They live in `AppLanguages` beside the codes and are never translated.
- **Locale-dependent formatting came free and region stays put.** `ByteCountFormatter` and
  `DateFormatter` already follow the current locale, so sizes and dates localized with no code
  change — and because `AppleLanguages` sets the *language* only, a Russian UI on a European region
  keeps that region's separators.
- **A bare-literal sweep has to scan the *multi-line* constructor forms, not just `x = "…"`.** A
  grep for `messageText = "`, `addButton(withTitle: "`, `.title = "` and friends found the alerts but
  silently skipped every menu item written as a wrapped `NSMenuItem(\n  title: "New Tag…",\n  …)` —
  the literal sits on its own line, so the sink keyword and the string are never on the same line.
  The Favorites and tag menus shipped bare through a whole pass because of it, and only a *second*
  scan (strip comments, then match a sink keyword within a few lines of a bare literal) caught them.
  Corollary trap in that second scan: a `comment:` argument whose prose contains "title:" or
  "detail:" (`comment: "Copy failure title: …"`) trips a naive sink match — a false positive to
  filter, not a bare literal.
- **A sink-keyword sweep cannot see a string that reaches the screen through a *return value*.**
  Both scans above look for the assignment (`messageText =`, `title:`), and `PanelViewController`'s
  status line has none: `statusText() -> String` builds `"\(total) items"`, `"\(marked) of \(total)
  selected · …"`, `"Filter “\(shown)” · …"` and the Git-sizes tail as plain literals, and one caller
  far away assigns the result. So the *permanently visible* line under both panes — the one thing on
  screen at all times — read "26 items" in a fully translated Russian UI, through every pass of both
  sweeps. Scan for the shape instead: a bare prose literal (has a space, has a lowercase word) that
  is not inside `String(localized:)` and is not a symbolic key, over the whole app. That scan
  finishes in seconds and is the one that finds this class. Two filters keep it honest — SwiftUI
  literals are auto-extracted (so `Text("Show hidden files")` is a false positive; confirm by
  looking the string up in the catalog rather than by reading the call site), and `fatalError("init(
  coder:) has not been implemented")` is noise in every AppKit view.
- **A key already sitting translated in the catalog does not mean every site uses it.**
  `"Compare with %@…"` has had its Russian since the Synchronize sheet's row menu was localized,
  while `validateMenuItem`'s live retitling of the same menu item builds the identical sentence as a
  bare literal — so the menu draws English with the translation right there. The duplicate-display-
  string lesson (`MenuSpec` and the category names, above) has this second half: after de-duplicating
  the *string*, check that every site that produces it goes through the lookup. Grepping the catalog
  for a key proves the key exists, not that the screen uses it.
- **A free-form `String` payload on an error case is an untranslatable string with extra steps.**
  `VFSError.unsupported(String)` collected **30** authored sentences — 17 in `DirnexCore`, 13 in the
  app — and `VFSErrorText` ended its switch with `case let .unsupported(message): return message`, so
  every one went to the screen in English under a *translated* alert title, at the exact moment
  something had failed. No sweep could see them: each is a literal at a `throw`, not at a display
  site. The fix is the `UndoActionLabel` move applied to an error — name the vocabulary
  (`VFSUnsupportedReason`), keep the English as fallback *data*, key it by the case. Two things that
  only come up when the strings take arguments: carry the `%@` **format and its arguments
  separately** and splice *after* the lookup, or a translation can never reorder them positionally;
  and `CaseIterable` cannot be synthesized for an enum with associated values, so `allCases` is
  spelled out with placeholder arguments — the key doesn't depend on them, which is the whole reason
  that works. Worth a coverage assertion beyond "is it translated": **count the placeholders**, since
  a translation that drops a `%@` silently swallows the file name the sentence was naming.
- **The sink-keyword blind spot has a general shape, and it is worth scanning for directly.** Three
  separate sweeps across Slices 1–10 all looked for the *assignment* (`messageText =`, `title:`,
  `String(localized:`), and all three missed the same class: text composed in a computed property or
  a function that **returns** `String`, with the assignment a file away. Slice 9 fixed one instance
  of it (`statusText()`); Slice 11's audit found six more surfaces still leaking, including two that
  are on screen permanently (the cloud sync badge on every cloud row, the titlebar update indicator).
  The scan that finds them takes seconds: a bare prose literal (has a space, has a lowercase word)
  that is not inside `String(localized:)` and is not a symbolic key, over the app **and the core**.
  Two filters keep it honest — a `comment:` argument is a translator note, not a bare literal (it is
  the single largest false-positive class, ~450 of 512 hits in one run), and SwiftUI literals are
  auto-extracted. Cross-check the survivors against the compiler-emitted `.stringsdata`: a key that
  is *extracted but absent from the catalog* is wrapped-but-untranslated, which the coverage tests
  never see because they only check symbolic registry keys.
  - **That cross-check was written down here and never run, and 26 strings shipped English for two
    milestones because of it.** Found 2026-08-09: the whole Settings ▸ Panels surface M15 added — the
    row-height and size-visualization pickers with their footers, the three color wells, the
    file-type color rules editor — plus M18's undrawn-diagram sentence and M14's multi-selection
    failure detail. Every one was correctly `String(localized:)`-wrapped, so no bare-literal sweep
    could see it; every one was absent from the catalog, so it compiled **to itself** and rendered in
    English inside a fully translated build. Nothing logs, `swift test` and `xcodebuild test` were
    green throughout, and the English screenshot is perfect — the only surface that shows it is a
    translated build of the one Settings tab nobody opens while working in their own language.
  - **The lesson is not the class, which was already named above; it is that a check living in prose
    is not a check.** `scripts/check_localization_keys.py` now diffs every `.stringsdata` key against
    both catalogs and runs in CI right after the app build (it needs the build directory, which is
    why it cannot be a test). Two keys are legitimately absent and are named in its `ALLOWED` with
    the reason: the empty label of a `.labelsHidden()` control, and a `DisplayRepresentation`'s bare
    `%@` whose every argument is already localized.
  - **The `allCases` enums need a test as well as the sweep**, because the sweep only fires once the
    key exists — a `RowDensity` case added in the same commit as its catalog entry passes it while
    still being untranslated in thirteen languages. `LocalizationEnglishKeyCoverageTests` pins those,
    and it has to spell the English keys out in a table: `title` is what the **running** language
    resolves to, and the app test target inherits the developer's own `AppleLanguages` pin, so asking
    a Russian build for its key hands back the Russian. A second test guards that table against
    drifting off the strings it names, and skips itself under a non-English pin — which means on this
    Mac it is CI that runs it, so prove it with a negative control rather than a green run.
- **A presentation decision in the core is a string that can never be translated.** Three surfaces
  were fixed by *deleting* core API rather than keying it: `UpdateAvailability.tooltip`,
  `GitBranch.displayName`'s `"detached HEAD"`, and `SFTPTransportError.classify`'s empty-stderr
  fallback. `SyncBadgeStyle`'s own comment already stated the rule — "the core picks the *state*;
  this picks the pixels and the words" — and each of these was that rule skipped once. The tell is a
  computed property on a core value type that returns a *sentence* rather than a fact. Moving the
  words is cheaper than keying them, and it takes the tests with it: the three core tests asserting
  the tooltip's English became app tests, while the state they rested on stayed covered where it was.
  The exception proves the shape — a payload that is genuinely the *remote's* words (`sftp`'s stderr)
  should stay a raw `String` and be allowed to come back **empty**, with the app supplying the
  localized stand-in, rather than the core authoring a sentence it cannot translate.
- **Interpolating a plain `String` into a `LocalizedStringResource` extracts the key `%@`.**
  `case .noWindow: return "\(Scripting.noWindowMessage)"` compiles, reads as wrapped, and puts an
  untranslated sentence in the Shortcuts error banner — because the *format* is all the compiler
  sees, and the sentence itself lives in a `static let` that no sweep looks at. It is worse than a
  bare literal: a bare literal is at least findable, while this one shows up in `.stringsdata` as a
  legitimate-looking entry. Declare such a message as a `LocalizedStringResource` **once** and hand
  it over whole; the `NSScriptCommand` side, which needs a plain `String` for `scriptErrorString`,
  resolves the same resource through `String(localized:)`. The tell in a stringsdata diff is a key of
  exactly `%@` — legitimate only when every argument is *already* localized (`DisplayRepresentation(
  title: "\(name)")`, whose `name` came out of `LocalizedCatalog`).
- **App Intents strings are extracted by the compiler; App Shortcut *phrases* need their own
  catalog.** Every `LocalizedStringResource` in an `AppIntent` — `title`, `IntentDescription`,
  `categoryName`, `@Parameter(title:description:)`, `Summary(…)` — lands in that file's
  `.stringsdata` under the `Localizable` table with no annotation, so "App Intents can't be
  localized" is wrong; they are simply keys nobody added to the catalog. The phrases in an
  `AppShortcutsProvider` are the exception: the extractor writes them to an **`AppShortcuts`** table,
  which compiles from `AppShortcuts.xcstrings`, not `Localizable.xcstrings` — a phrase left in the
  wrong file is silently English. Every phrase must keep `${applicationName}` in every language.
  Under file-system-synchronized groups the new catalog joins the target by existing; confirm with
  `ls <app>/Contents/Resources/<lang>.lproj`. None of this is checkable in Shortcuts from a local
  build — see "macOS system gates" — so the compiled `.strings` is the verification.
- **`String(localized:comment:)` takes a `StaticString`, so a shared comment must be repeated
  verbatim.** It cannot be hoisted into a constant, and two sites keying the same string with
  *different* comments hand the translator whichever one `xcstringstool` kept. Three sites now draw
  "iCloud Drive" (sidebar row, tab title, path-bar crumb) and all three carry the identical comment
  literal. Watch the 120-column lint ceiling: a comment that reads well at 16 spaces of indentation
  is the thing that trips it.
- **`plutil -extract` reads a dotted key as a keypath.** Checking `vfs.unsupported.trash` against a
  compiled `Localizable.strings` reported every one of 27 keys MISSING from a bundle that contained
  all of them — a wrong answer in the alarming direction, right after a passing coverage test, which
  is exactly when a bad probe is most likely to be believed. `plutil -convert json -o -` and look the
  key up in the dictionary.
- **A pair of "identity" and "display" fields on one type invites a caller to pass the same value to
  both.** `ResultsPresentation` carries `pathSummary` (the stable English token that becomes the
  synthetic `VFSPath`) and `title` (what the tab chip draws). The Trash gets this right and its
  comment even *names* the rule — and `iCloudPresentation()` handed `ICloudLocation.mergedName` to
  both, so the tab title and the path bar's root crumb bypassed the catalog. It survived every sweep
  twice over: the value is a constant reached through a variable, so no bare-literal scan sees it,
  and Russian keeps "iCloud Drive" as the product name, so no screenshot sees it either. It would
  have surfaced only in a language that transliterates. When a type has both kinds of field, check
  each *caller* passes two different things, not just that the type documents the difference.
- **A virtual "place you visit" that borrows the search backend leaks English through its label.**
  Recents rides the `.search` results machinery, so its path bar drew `"Results for \(pathSummary)"`
  — and with `pathSummary` an English identity that reads "Результаты для Recents" in a Russian UI,
  the tab title likewise "Recents". This is the same distinction the Trash already makes ("a place
  you visited, not a search someone ran"): the fix is to *self-name*. Keep `pathSummary` a stable
  English identity (never displayed — `ResultsPresentation.recentsIdentity`), localize the tab title,
  and have `rebuildVirtualLabel` match on that identity to draw the localized name with the sidebar
  row's own glyph (`clock`), exactly as it special-cases `backend == .trash`. Only the live Russian
  run surfaced it — an English screenshot showed "Results for Recents", which reads as fine.
- **`NSAlert` binds Escape by matching the byte string `"Cancel"`, so translating the button silently
  removes the alert's way out.** Probed with the process pinned to `ru`: a button titled «Отмена» is
  given *no* key equivalent at all, and added first (to make it rightmost) it is given **Return**
  instead — while the English `"Cancel"` gets `\u{1b}` in either language. This is not cosmetic like
  the rest of this section: it changes what the keyboard does, in the one direction where the user
  is trying to get out. And it is invisible twice over — nothing logs, and an English screenshot is
  perfect. `enableEscapeToCancel` used to guess from a set of English titles for the alerts AppKit
  left alone, which fails identically and for the same reason, so the fix could not be "translate
  the set": it now takes the safe **`NSApplication.ModalResponse`**, the vocabulary the caller
  already reads the result back in, defaulting to the last button. Two live bugs fell out of the
  probe — the host-key alert (translated Cancel added first, no Escape at all in Russian) and Full
  Disk Access's already-granted alert, whose comment claimed "⎋ → OK" while the code handed Escape
  to *Open System Settings* in **both** languages, because `"OK"` was not in the set either.
  - The general shape, and the one worth carrying: **a decision keyed off displayed text is a
    localization bug waiting for a translator.** The title-matching sites are easy to grep once you
    know to look (`titles.contains($0.title)`, `if button.title == …`); what makes them expensive is
    that they fail as *behavior*, so no string sweep and no coverage test over the catalog can see
    them. Key off an identity the display layer doesn't own.
  - **Having the fix is not having applied it, and 21 of 60 alerts had not — including F7 New
    Folder, both deletes and the conflict dialog.** Found 2026-08-09 by a user pressing ⎋ on a
    Russian New Folder sheet. `enableEscapeToCancel` had existed since the audit above, correct and
    tested, with this very note explaining why every alert needs it; the sites that never called it
    simply inherited AppKit's English-only binding and were Escape-dead in all thirteen
    translations. Nothing logs, both suites and both linters stayed green, and the English
    screenshot is perfect — the same "a check living in prose is not a check" lesson the
    `.stringsdata` sweep had already taught one section below, arriving from the other direction:
    there a *documented check* was never run, here a *documented fix* was never applied.
    `scripts/check_alert_escape.py` now scans every `let alert = NSAlert()` in CI and fails on any
    that reaches a runner without the call. It also fails on an `NSAlert` built in any *other*
    shape, so the scan cannot quietly go blind the day someone writes one differently.
  - Two facts from re-probing the helper's edges, both load-bearing and neither obvious. A **fresh
    `NSAlert` already reports AppKit's synthesized `OK` in `.buttons`** (count 1, Return bound)
    before anything lays out — which is what lets the lone-button branch cover the plain
    "something went wrong" alerts that add no button at all; had it come back empty the helper
    would have done nothing, silently. And **with a text-field accessory the confirming button's
    Return moves off `keyEquivalent` onto the window's `defaultButtonCell`** — so reading the
    buttons of a live New Folder sheet shows `Создать=none`, which looks like a broken default
    button and is not one. Verify Escape on such a sheet with
    `NSWindow.performKeyEquivalent(with:)`; Return is not reachable that way at all, since it is no
    longer a key equivalent.
  - **Calling the fix is not the same as the fix taking, and the CI scan could only see the call.**
    Reported 2026-08-20 as ⎋ and ⏎ "sometimes" doing nothing but beep. The scan said *all 70 NSAlert
    sites call `enableEscapeToCancel()`* and it was right; three of them had no Escape whatever,
    because the helper was a **no-op in both call orders** for a single-button alert carrying an
    accessory — `accessoryView == nil` fails when the accessory is set first, and the caller's own
    assignment throws the catcher away when it is set second. That is every progress sheet the app
    has: remote download, iCloud download, search. Measured on a live bundled sheet,
    `performKeyEquivalent(⎋) == false` and the sheet did not dismiss. The generalizable half is the
    one this file keeps re-learning from a new direction: a check that a remedy is *invoked* says
    nothing about whether it *bound*, so the assertion has to read the binding back.
  - **The other half of the same report was Return, and it is AppKit's doing rather than the
    helper's: when the safe choice occupies the default (first-added, rightmost) slot, the alert has
    no default button at all.** Measured on a live sheet — `Cancel` added first comes back
    `Cancel[⎋] Trust[—]` with **`defaultButtonCell == nil`**, and both Return and keypad Enter fall
    straight through to the beep. The control that makes it a fact about AppKit and not about us:
    the identical alert with `enableEscapeToCancel` **removed** behaves the same, since AppKit
    matched the English "Cancel" itself and declined to make it the default. Four alerts shipped
    that way — the SSH host-key prompt, both FTPS certificate prompts, and Full Disk Access's
    already-granted notice — and a translated build reaches the same state by our own hand, because
    `safe: .alertFirstButtonReturn` assigns `⎋` over the `\r` that button was carrying.
  - **So which key may live on the safe button depends on whether anything *else* answers Return**,
    which is the rule the helper now encodes. A button cannot carry two key equivalents, so: while
    some other button is the default, Escape rides the safe button (the ordinary
    `Delete[⏎] Cancel[⎋]` confirmation, unchanged); otherwise the safe button *is* the default, it
    keeps Return, and Escape rides an `EscapeDismissingView`. Note what that means for the trust
    prompts — ⏎ now answers **Cancel**, which is the whole reason those sites put Cancel in the
    default slot to begin with.
  - **Put the catcher in the alert window's own `contentView`, never in the `accessoryView` slot.**
    That is what makes the helper independent of when it is called, and it is what the accessory
    collision above cost. Realising `window` early is free: probed in both call orders, the alert
    lays out to the same **292×170 pt** with the accessory on screen and inside the content bounds
    either way. Idempotent, too, or a second call leaves two catchers aimed at different buttons.
  - **Assert the two keys together or neither assertion means anything.** Each defect above is
    invisible to a test that checks only the other key, which is exactly how both shipped past a
    suite that had nine Escape tests: the progress sheets read `escape: DEAD, return: answered` and
    the trust prompts `escape: answered, return: DEAD`. `EscapeToDismissTests` now checks the pair
    over every shape the app builds; reverted, that suite fails with 18 issues naming both halves.
  - **Four mechanisms were probed and cleared first, and they are worth not re-suspecting.** With a
    sheet attached the parent window reports `isKeyWindow == false`, so the Quick View key monitor
    already bows out; `focusTable()`'s `makeFirstResponder` on the *parent* leaves the sheet key and
    answering; a sheet raised while an app-modal window is up is still key and still answers; and on
    macOS 26 a second sheet on a window that already has one is **no longer queued invisibly** —
    it stacks, visible and key, which retires the older observation recorded above under
    `sheetHost(over:)`. The bug was in the binding all along, not in who held focus.
- **A dialog's answer arrives at *nothing* if the object that asked the question is not retained
  across the sheet — and `[weak self]` in the completion handler is how that is written.**
  `RemoteFetchPrompt.confirm` did: `fetch` builds the prompt in a local, `beginSheetModal` returns
  immediately, and the alert retains the **closure**, not the object it captured weakly — so by the
  time anyone could press **Download** the prompt was gone and `self?.start()` was a no-op. What the
  user sees is a dialog that closes and does nothing at all: no transfer, no error, nothing logged,
  and the placeholder card behind it still offering the same button. Reported 2026-08-19 on a 14,5 MB
  S3 object under ⌃Q. The tell that makes it findable is a *sibling path that works* — the
  no-question path called `start()` directly, which launches a `Task` that captures `self` strongly,
  so the identical click downloaded the file whenever nothing had been asked. Capture strongly: the
  closure is AppKit's and dies with the sheet, so there is no cycle, and a `[weak self]` reflex is
  exactly wrong wherever the closure is the only thing holding the object alive.
  - **It is testable, and the test is what settles that the diagnosis is right rather than
    plausible.** A real `NSAlert` on a real `NSWindow` (never ordered front — a sheet attaches and
    answers without it), `performClick(nil)` on its default button, and the assertion is the
    *backend's* copy count: every decision in the broken version was correct, so only "was the
    transfer asked for" can separate the two. Reverted, it reads `copyCount → 0`.
  - **On macOS 26 a modern alert's confirming button carries no `keyEquivalent` at all** — dumped
    from a live sheet, the two buttons read `Cancel ke="\u{1B}"` and `Download ke=""`, with Return on
    the window's **`defaultButtonCell`**. This file already recorded that shape for a sheet holding a
    text-field accessory; it is true of a plain one too, so a scan for `"\r"` finds nothing and reads
    as the dialog having no default button. `window.defaultButtonCell?.controlView as? NSButton` is
    the way in — and never a title match, which passes in English and fails in thirteen languages.

- **A dialog raised by a modifier chord is unanswerable until the user lifts the modifier, and it
  reads as a broken binding.** AppKit matches a key equivalent on the character **and** the exact
  modifier mask, so ⌃⎋ and ⌃⏎ are refused by an alert whose buttons carry bare ⎋ and ⏎ — measured on
  live sheets, `performKeyEquivalent` returns **false**, the event falls through to `keyDown:`,
  nothing handles it, and the user gets a beep. Standard macOS, and ordinarily unreachable, because
  a confirmation is raised by a *click*. Dirnex raises them from chords — ⌃Q, ⇧F8, ⌘F5, ⌘F2 — and
  the dialog is on screen **53 ms** after the chord (measured in the running app), so it asks its
  question while the finger is still on the modifier. Reported 2026-08-21 as ⎋ needing two presses
  and ⏎ never working at all.
  - **Every automated and headless signal was clean, and so was every window-state reading.** Both
    suites and both linters were green; `enableEscapeToCancel` had done its job (`Cancel[⎋]`,
    `Download[⏎]`, `defaultButtonCell = Download`); the sheet was key and the parent was not; no
    Quick Look panel existed; the Quick View key monitor bowed out exactly as designed. Four
    plausible mechanisms this file already documents were each checked and cleared. **The difference
    was in the *event*, which nothing was logging** — two presses from byte-identical window state
    with opposite outcomes is the tell, and it says to stop instrumenting the window and instrument
    the key.
  - **The instrument is a dump of `modifierFlags` beside a "would AppKit match this?" line**, per
    button: `chars` and `mods` compared separately is what turns a puzzle into one line —
    `Cancel:chars=true,mods=false` names the cause outright, where a bare "the key did nothing"
    does not. Log **every** key while a sheet is up, not just the one being reported: the first pass
    logged only Escape and letters, so ⏎ — the half that never worked at all — produced no evidence.
  - **"It works for this file and not that one" was a *timing* report wearing a data report's
    clothes.** The two files differed only in when the user's finger left Control; the log's
    intervals overlap between the working and failing presses (0.87 s worked, 0.74 s failed), which
    is exactly what a per-press human variable looks like and is why the timing could not settle it.
    What settled it in five seconds was asking for a deliberate A/B — hold Control, tap ⎋; release,
    tap ⎋.
  - **The fix forgives *stale* modifiers, not any modifiers**, and the narrowness is the whole
    design. `enableEscapeToCancel` captures `NSEvent.modifierFlags` at build time — it runs
    synchronously inside the action the chord invoked, so that set is exactly the chord's — and
    `AlertKeyCatcher` answers ⎋/⏎ whose modifiers are a **subset** of it. Two properties follow: an
    alert raised by a click captures nothing, so both keys stay strict and every such dialog is
    byte-identically unchanged; and a deliberate ⌘⏎ can never confirm a ⇧F8 delete, because ⌘ was
    not held when that alert was built. That matters because ⏎ is the committing direction, where
    being wrong costs a file — the asymmetry that made forgiving *both* keys affordable rather than
    only the safe one. Bare ⏎ is deliberately never claimed: it already works, and two answers on
    one key is undefined.
  - **A test suite that presents real `NSAlert` sheets kills the test host, and it reads as several
    broken features.** Tearing one down inside the runner segfaults in AppKit's own completion block
    (`objc_release` under `__destroy_helper_block_…`, EXC_BAD_ACCESS on the main thread) — so
    xcodebuild restarts, and its summary then lists every suite that was in flight under "Failing
    tests:", naming features that work. `.serialized` does not help; neither does letting the
    dismissal settle before closing the window. Split the rule out instead
    (`AlertKeyCatcher.button(for:)` decides, `performKeyEquivalent` clicks) and assert **which
    button the key reaches**, with no sheet presented — `defaultButtonCell` is already populated
    before presentation, so the decision is fully reachable. What that costs is "the click lands",
    which is covered by one live run against real sheets (13 cases, including bare ⎋/⏎ and three
    refusals) rather than by the suite.
  - One trap in the harness that measured it, worth not re-deriving: `window.endSheet(_:)` runs the
    completion handler itself with `NSModalResponse(-1000)`, so a test that reads the response
    *after* its own teardown turns every refusal into an answer.
  - **A second, *intermittent* refusal lives here — the alert's own buttons are bound and enabled
    and nothing answers — and the fix is to let the walk itself decide.** Same symptom (a **bare** ⎋
    or ⏎ doing nothing but beep), and every property that could explain it measured identical
    between a press that worked and one that did not, seconds apart: the sheet is `keyWindow`, the
    event's own `window`/`windowNumber` **is** that sheet, `Cancel[⎋]`/`Download[⏎]` are bound,
    enabled, unhidden and unoccluded, `defaultButtonCell` is set, the app is active, no modal window,
    no `QLPreviewPanel`, one alert panel alive, the `NSAlert` object itself alive, the Quick View
    monitor bows out, `fileTableCancel` never runs, and `charactersIgnoringModifiers` is
    `U+1b`/`U+d`. Three causes were proposed from that data and all three refuted by it (event
    routing; a running transfer — `transfer FINISH` was logged **8 s before** a dead press; and the
    chord modifiers, which are a real and *separate* bug).
    - **What cracked it was a witness inside the walk, and the finding is about the press that
      *works*.** `AlertKeyCatcher` is the last subview of the alert's content view, so
      `NSView.performKeyEquivalent` reaches it only when nothing before it matched — and it is
      reached on **every** press, the working ones included. So `Cancel[⎋]`'s own key equivalent
      never matches during the walk at all; the alert is normally answered *afterwards*, through the
      responder chain, and it is that second, invisible step that intermittently does not run. A
      dead press walks the tree (twice), finds everything in order, and answers nothing.
    - **So the catcher claims the bare keys too**, which converts a two-step dance into one
      deterministic step and cannot double-answer: being reached *means* no button matched. The
      buttons keep their bindings and still match first; this only changes which mechanism answers
      when AppKit's own matching has already declined.
    - **The instrument has to be cheap or it hides the bug.** A probe that logged a full state block
      from a key monitor cost milliseconds *before* dispatch and masked the race completely — five
      reproductions in a row looked clean, and a green session was read as evidence twice. One short
      `NSLog` inside the catcher caught it on the first try. When a bug survives instrumentation,
      suspect the instrument's *cost*, not the reporter.
    - **A green session proves nothing here**: 12 dialogs answered on the first press with the heavy
      probe in place, on a build whose shape had failed three times in the preceding half hour. The
      reproduction that provokes it is the **second** confirmation of a session (⌃Q on a large remote
      file, answer, then ⌃Q on another), and the dead stretch lasts seconds — six consecutive Enters
      ignored in one run — before recovering on its own with nothing touched.
    - `open` vs launching the binary from a shell was measured **irrelevant**, and was worth
      eliminating: it was the other variable that differed between the developer's runs and the
      user's, and it kept "it works in your build" alive as an explanation for two rounds.
    - Superseded, do not re-derive: **an intermittent refusal here is not unresolved.** Same symptom (a bare ⎋ or ⏎ doing nothing but beep on the confirmation), and
    every property that could explain it has been measured identical between a press that worked
    and one that did not, in the same session, seconds apart: the sheet is `keyWindow`, the event's
    own `window`/`windowNumber` **is** that sheet, `Cancel[⎋]`/`Download[⏎]` are bound, enabled,
    unhidden and unoccluded, `defaultButtonCell` is set, the app is active, no modal window, no
    `QLPreviewPanel`, one alert panel alive, the Quick View monitor bows out, `fileTableCancel`
    never runs, and the event's `charactersIgnoringModifiers` is `U+1b`/`U+d`. Calling
    **`sheet.performKeyEquivalent(with:)` by hand from a monitor returns `false`** on the failing
    press and `true` on the working one — so AppKit genuinely refuses, and it is not a routing,
    binding or focus problem. Three causes were proposed from this data and all three were then
    refuted by it (event routing; a running transfer — `transfer FINISH` was logged **8 s before** a
    dead press; the chord modifiers, which are a real and separate bug).


- **An `NSAlert` reserves vertical space for its `accessoryView` from that view's *frame*, so a
  pure-Auto-Layout accessory (only `translatesAutoresizingMaskIntoConstraints = false` + internal
  constraints) reports a **zero frame** and the alert draws it *overlapping* the informative text.**
  The escalation dialog's copyable-command view did exactly this — the "Or run this yourself…" label
  and the command field were painted on top of the body sentence. Invisible in every test and every
  build; obvious in the first launch. Give the accessory a concrete frame after building it —
  `view.layoutSubtreeIfNeeded(); view.frame = NSRect(origin: .zero, size: view.fittingSize)` — with a
  definite inner width (a fixed-width command field) so `fittingSize` resolves. Same family as the
  `NSStackView`-compression traps above: an AppKit container that is under-informed about size fails
  by drawing wrong rather than by complaining.
  - **The corollary everyone assumes is false: an accessory *may* change height while the sheet is
    up, and `NSAlert.layout()` re-fits around it synchronously.** "The alert takes its height from
    the frame" reads as "so the frame must be constant", and the pack sheet shipped a whole design on
    that — its passphrase rows were grayed rather than hidden, with the reasoning written into the
    doc comment. Measured on a live sheet: set the accessory's frame, call `layout()`, and the
    content is re-fitted in the same turn, to the pixel (438 → 288 pt for a 150 pt accessory) and
    back again with no drift; a modern alert sheet is *centered*, so it grows and shrinks about its
    own center and nothing jumps. So a form whose lower half is meaningless until a popup says
    otherwise can simply collapse — hide those rows, slide the survivors down by the height they
    vacated, resize the container, call `layout()`. Two things still hold and are what the original
    reasoning was really protecting: build the view **expanded** so anything that has to be
    *measured* (a wrapping footer) is measured holding its real text, and collapse before the alert
    first lays out, since there is nothing to re-fit yet.
- **`presentAsModalWindow(_:)` is the sheet replacement when a dialog has to be *movable*, and —
  against every expectation the word "modal" sets up — it does not block the caller.** A sheet is
  nailed to its window, so a verification report or a Get Info panel can never be dragged aside to
  read the pane behind it; this is AppKit's own answer and needs no window plumbing. Nothing about it
  is documented, so all of it was probed on a live window:
  - The call **returns immediately**, and main-queue work and default-mode timers keep firing while
    the dialog is up — the operation queue, the FSEvents refreshes and a running checksum job are
    unaffected. That is the fact that makes the move affordable; a nested `NSApp.runModal` would not
    have been. It is nonetheless genuinely app-modal (`NSApp.modalWindow` is it).
  - The window is `[.titled, .closable, .resizable]`, `isMovable == true`, and it is reachable
    **synchronously** right after the call — so `styleMask.remove(.resizable)` belongs there, with
    nothing deferred. Removing it leaves the frame untouched and disables the zoom button. Worth
    doing for any controller that pins a fixed width *and* height: a resize corner Auto Layout then
    refuses to honor is a worse lie than no corner.
  - The window draws its content view controller's `title`, and a **`nil` one renders as the literal
    word "Untitled"** — so a controller with no name gets a visibly broken title bar rather than an
    empty one. Set it in the designated initializer, before the animator builds the window.
  - An `NSAlert` raised *from* one of these still attaches to it as a sheet and still runs its
    completion handler; the close button ends the presentation properly (`presentedViewControllers`
    drops to 0, the modal state clears), so `dismiss(_:)`, a Done button and `EscapeDismissingView`
    keep working unchanged.
  - **The trap is `view.window?.attachedSheet`, which silently stops answering.** Any code asking
    "is a dialog covering the pane?" that way reads `nil` once the dialog is a window, and an
    `NSAlert` hung on the browser window while another window is app-modal is one the user *cannot
    click*. `PanelViewController+Compare` had two such sites (the compare alert's host, and the
    "Files are identical" report that otherwise fell back to a status line nobody can see behind a
    modal). `NSApp.modalWindow ?? view.window?.attachedSheet ?? view.window` is the ordering that
    covers both eras. Same family as naming a new backend at every site that lists the old one — one
    question, two spellings, and the compiler checks neither.
  - **Verify Escape by A/B against a sheet in the same script, not on its own.** A first probe sent a
    synthetic Escape into the modal window and *nothing* fired, which reads as a regression; the
    control run showed the sheet behaving identically, and the real cause was `EscapeDismissingView`'s
    own field-editor carve-out — the probe had put an `NSTextField` in the view. Without the control
    it would have looked like modal windows swallow Escape.
  - A title bar arriving also makes any in-content headline a **duplicate**, and a display string
    that exists twice gets localized once (below). Promote the existing headline to the window title
    and delete the label — its translations carry over untouched, since the key is the English text.
- **`setFrameUsingName` restores the *position only* on a non-resizable window, and preserves the
  top-left while doing it.** Probed after the move above, because the obvious worry — a size saved by
  an older build coming back and fighting a fixed-size container — turns out not to exist: a frame
  saved at 400×332 restored a 640×512 window as 640×512, with both frames' **tops at y=587**. AppKit
  clamps the restored size to the window's own min/max, which for a non-resizable window is its
  current size, and re-derives the origin from the top-left. So "remember where the user dragged this
  dialog" is `setFrameUsingName` + `setFrameAutosaveName` and no arithmetic at all — but only if
  `.resizable` is **already off** when the restore runs. On a resizable window the same call brings
  the stale size back with it.
  - The autosave is also the reason not to hand-roll it: a modal-window presentation **posts no
    `willCloseNotification`** (probed), so the natural save-on-close design silently never saves, and
    a `didMove` observer would need a lifetime hook that dismissal does not give you either. AppKit's
    autosave writes on every move and needs no teardown.
  - **Both `setFrameOrigin` and `setFrame(_:display:)` constrain the result onto a screen by
    themselves** — an origin of 99 999 came back as 1688, off-screen negatives came back with the
    title bar reachable — so a hand-rolled clamp only second-guesses AppKit. What AppKit *cannot*
    catch is a saved position that is perfectly valid on a display the app is no longer using: that
    needs its own check (is the restored center on the parent window's screen?), or every dialog
    opens back on the laptop screen the day an external display arrives.
- **A SwiftUI-hosted window can consume Escape before any AppKit handler runs, and a local key
  monitor is the way in.** A monitor runs *ahead of responder dispatch*, so it sees the key whatever
  the hosting view would have done with it — the same lever Quick View already uses to take Esc back
  from a focused `PDFView`. The cost is that it now sees **every** Escape in that window, so it has to
  hand the key back to whoever legitimately owns it: a field editor mid-edit (which reverts the edit),
  and any control that means something else by it — in Settings, the shortcut recorder, where Escape
  cancels the capture. Mark those with a protocol on the *control* rather than listing class names in
  the monitor; the knowledge belongs with the thing that wants the key.
  - Verify it in a **probe with `postEvent`, not through computer-use**: synthetic Escape is swallowed
    before the app entirely (above), so the tool cannot tell a working monitor from a broken one — it
    shows the window simply staying open either way. `NSApp.postEvent` does reach a local monitor, so
    a throwaway app carrying the identical monitor over a real `NSHostingController` pins all three
    branches (nothing focused → closes; `_SystemTextFieldFieldEditor` focused → does not;
    marked control focused → does not). The one step left for a human is the physical keypress.

## Lint ceilings and file splitting

SwiftLint enforces `file_length` 500 and `type_body_length` 250, and the big AppKit controllers
ride right at them. New panel code goes in a `PanelViewController+X.swift` extension;
`CommandCatalog` and `PathBarView` are near the type-body limit too.

- **When a type is at the ceiling, the next feature is the moment to split by *concept*, not to
  shave lines.** `ConnectServerForm` held two protocols' fields and sat at `type_body_length`; FTP's
  went into their own object, and SMB's followed immediately so all three are symmetric — each
  protocol owning its fields in its own file is what the form always implied. Watch for an index
  comparison while doing it: the picker read `selectedSegment == 1` for SMB, and inserting FTP at
  index 1 would have re-pointed `isSMB` at the new protocol with nothing to catch it. A named enum
  costs three lines and makes that class impossible.
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

- **`Process.waitUntilExit()` is a poll, not a wait, and it taxes every one of them a flat ≈71 ms.**
  Measured 2026-08-16 while verifying M22's FTP walk: `/usr/bin/true` costs the same as a full FTP
  listing, and a child that has been **dead for 300 ms** still costs **71.3 ms** (8 runs,
  70.1–72.5). That tightness is the tell — a timer does not vary with the work, and it does not go
  faster on a faster Mac. The same reap through `terminationHandler` + a semaphore is **2.1 ms** and
  a bare `posix_spawn` + `waitpid` **1.0 ms**, so what is being paid for is the polling and nothing
  else. `ProcessWaiting.joinTermination(of:into:)` is the one home; `exitWaiter(for:)` is the same
  mechanism for a site with no group of its own. Both must be installed **before** `run()`, and
  neither may be waited on after a `run()` that threw.
  - **Its relative size is inversely proportional to how fast the child is, which is exactly why it
    hid for the life of the app.** On `git status` (≈320 ms, measured on this repo) it is a quarter
    of the cost and reads as git being slow; on a listing it is nearly all of it. Nothing surfaces
    it until something spends *one invocation per directory* — M22's walk did, and a whole-tree FTP
    search over 12 directories went **1.04 s → 0.09 s** on the same server with byte-identical hits,
    confirmed afterwards in the built app against the server's own log.
  - **It is not what "one curl per directory" costs**, which is the natural first reading and would
    have sent the fix somewhere much larger. The same argv from Python's `subprocess` was 6.7 ms
    against Swift's `Process` at 68 ms, which is what isolates it to the *wait* rather than to the
    spawn, the flags or the network. Worth reaching for that control whenever a subprocess looks
    expensive: run the identical argv from something that is not Foundation.
  - **The batching idea it makes look attractive is mostly subsumed.** `curl` reuses one connection
    across many `ftp://` URLs — 11 LISTs on **1** connect, measured — which was **15×** against the
    shipped path and is only **1.4×** against the fixed one. So the FTP twin of the SFTP
    `sftp -b` batching note below is real, and is now worth far less than the arithmetic before the
    fix suggested. Re-measure before spending it.
  - The timing property is testable without a stopwatch reading anyone has to trust, because what it
    asserts is the *absence of a timer*: reap a process that has been dead for 300 ms and bound it
    well under the poll interval. The shipped path takes microseconds and the reverted one cannot
    beat its own interval however fast the host, so there is nothing for CI to drift past
    (`ProcessWaitingReapTests`, whose negative control fails that one test at 63 ms and leaves its
    three narrowness controls green).

### Owner, group and mode in a columnar listing

The same four parsers that share the date reader share these columns, and all three fields are
less trustworthy than they look. Measured 2026-08-27/28 against a live `sshd` and libarchive 3.7.4.

- **Owner and group are opaque text whose *type* changes with the format, not with the tool.**
  `sftp`'s `ls -la` and FTP's Unix `LIST` print **names** (`oleg     staff`); the SSH `find` walk runs
  `ls -ldn` and prints **numbers**; and `bsdtar -tvf` prints names for a **tar** and bare numbers for a
  **zip**, because a zip stores no owner names — same tool, same file, two shapes, with nothing in the
  row saying which. So the only honest model is a `String` (``FileEntry/ownerName``), and it must
  never feed a numeric `ownerID`: resolving a server's `501` through this Mac's `getpwuid` draws the
  local account of whoever is reading over a file belonging to a stranger, which is a plausible answer
  to a question nobody asked. FTP's DOS/IIS dialect has no such columns at all.
- **`ls(1)` overloads each class's execute column, so reading the glyph as a plain execute bit is
  lossy in four cases.** `s` is set-uid *and* execute, `S` is set-uid *without* it, and the other
  class spells the sticky bit `t`/`T` the same way. Harmless while nothing draws a remote mode;
  a `rwsr-xr-x` binary shown as `rwxr-xr-x` disclaims the one bit anybody inspects a remote binary
  for. `POSIXPermissions` already stores and renders all twelve bits, so being exact costs a lookup
  table. Verified against the OS: the parser fed a real server's bytes now agrees with this Mac's own
  `lstat` on every file, `setuid.bin` at **4755** and a sticky directory at **1777** included — and
  the old reader disagrees on exactly those two, which is what makes the agreement evidence.
- **`bsdtar -tvf` prints a real mode and `ArchiveTOCParser` used only the leading kind character**,
  so a browsed archive answered an invented `0o755`/`0o644` while the real one sat in column 0. A
  directory the archive *omitted* has no row at all and is synthesized, so it honestly has no mode —
  which is the same distinction the whole slice rests on, arriving inside one backend.

### Parsing a year-less timestamp

Every tool here prints a recent entry's date without a year (`MMM d HH:mm`) and an old one with
one, so all four columnar parsers — `bsdtar -tvf`, `sftp`'s `ls -la`, FTP's `LIST`, and M22's
`ssh … find … -exec ls -ldn` — share one date reader, `ColumnarListing`.

- **A listing's stamp is too coarse to compare two *files* with, and SFTP is the case this file had
  assumed went the other way.** Measured 2026-08-28 against a real `sshd`: `ls -la` prints
  `Aug 20 11:33` for a file whose true mtime is `11:33:37` — the **seconds are gone** — and
  `Dec 20  2025` for one older than about six months, where the time of day is gone entirely and the
  parse lands at local midnight, **41 617 s** from the truth. So a directory sync comparing a local
  side against an SFTP one by date reports a difference for fifty-nine of every sixty recent files
  and for every old one, on files nothing has touched. The exec channel's `ls -ldn` carries the
  identical stamp, so gathering the tree faster does not make it finer.
  - **Two sides of the *same* coarse dialect are no better, and that is the half that reads as
    safe.** Two files thirty seconds apart both list as the same minute, so a mirror calls them
    identical and skips the one that changed — the quiet direction, where one coarse side merely
    over-reports. `SyncComparison.available(between:and:)` therefore needs the clock on **both**
    sides, and only the local disk has one.
  - **It is a different question from the deleted `hasApproximateTimestamps`**, which asked whether
    two readings of *one* file could be compared and answered FTP alone. Two files, two listings and
    possibly two protocols is stricter, and SFTP passes the old test and fails this one — which is
    why the predicate came back under a new name (``VFSBackendID/hasComparableModificationTimes``)
    rather than being resurrected.
  - **S3 is the case that is exact and still wrong**, and it is worth keeping separate from the
    coarse ones: `LastModified` is a real ISO-8601 timestamp to the second, and it is when the object
    was *written* rather than when its contents last changed, with no verb that sets it. A file
    uploaded today from a 2018 source reads as today, forever. One predicate answers the caller's
    question for both reasons; the reasons do not merge.
  - **The transfer is exact and the read-back is not**, which is what makes this a *listing* fact
    rather than a protocol one: `put -p` carries both timestamps to the second (▸ sftp / ssh), and
    the `ls -la` that reads them back rounds. A live test that stamps a file, uploads it and compares
    the two is measuring the reader, so anchor the stamp's seconds — with an arbitrary "now" a run
    landing near `:00` sees the listing agree and passes for the wrong reason about once in thirty.

- **`DateFormatter.defaultDate` supplies *every* component the format does not name, not just the
  one you set it for — and a year-less format names no seconds.** So `defaultDate = Date()` stamps
  each parse with the second and millisecond it happened to run at, and **parsing one unchanged row
  twice yields two different dates**, up to a minute apart. Fix it by truncating the anchor to the
  minute, which leaves it able to contribute only the year (`ColumnarListing.yearAnchor`).
  - **It is invisible everywhere a date is *displayed*, which is why it survived four milestones.**
    The column is drawn to the minute, sorting is unaffected, and no fixture can see it: a test with
    a hard-coded expected date passes, because the *minute* was always right. What it breaks is any
    comparison of **two readings of the same file**, and there it breaks completely rather than
    approximately.
  - **What it did in the product was tell the user their colleague had overwritten a file.**
    `RemoteFileRevision.isSuperseded(by:)` compares size and date for **exact equality** — SFTP and
    FTP carry no entity tag — and a remote write-back compares the *listing's* date (recorded when
    the bytes were fetched) against the pre-upload `stat`'s. Two parses, so never equal: **every**
    save over SFTP and FTP answered *"The file on the server has changed since you downloaded it —
    someone else has edited it."* That is the one sentence `BrowserWindowController+RemoteWriteBack`
    exists to get right, and it was wrong 100 % of the time. Measured live 2026-08-22 against a real
    NAS: 36 bytes on both sides, dates **39 s** apart, `sizeDiff=0 dateDiff=1`.
  - **S3 is immune, and that is exactly why it shipped.** An entity tag settles `isSuperseded`
    before the date is consulted, and S3's stamps are ISO-8601 with real seconds — so the only live
    suite this feature has (`RemoteFileEditLiveIntegrationTests`, S3-only) could not have caught it,
    and neither could any of the 634 app tests. A backend-agnostic feature verified against one
    backend is verified against one backend.
  - **The neighbouring consumer degrades instead of breaking, which is worth knowing before
    assuming the blast radius.** `DirectorySync`'s `.sizeAndDate` compares with a **2 s** tolerance
    rather than for equality, so noise of up to 60 s could exceed it — but a sync between a local
    side and an SFTP one is comparing a second-resolution mtime against a minute-resolution stamp
    regardless, which is its own approximation and not this bug's.
  - **A listing cannot verify a carried timestamp, and a test that tries fails by a suspiciously
    round number.** Both directions were paid for in wrong assertions on 2026-08-28 while checking
    that a copy carries its source's mtime, and in both the *write* was exact and the **read-back**
    was the limit. Over SFTP a remote `stat` is `ls -la`, which drops the time of day for a file
    older than about six months: a 2018 fixture failed by **40150 s**, which is 11:09:10 — the
    source's own time of day, the parse having landed at local midnight. Over FTP the `LIST` stamp is
    zone-less on the *server's* clock, so the same assertion failed by **10800 s**, this machine's
    own +0300. A round failure — an exact zone offset, or exactly a file's time of day — is the tell
    that the instrument is the listing rather than the code.
    - What works is to size the tolerance to the *reader*: a **recent** fixture (so `ls` still prints
      a time) asserted to the minute over SFTP, and a whole day over FTP, which still separates the
      two answers that matter — a carried time lands within one zone offset of the source, and an
      uncarried one is the moment the transfer ran.
  - **The test has to be a property, because the obvious test passes on the broken code by luck.**
    "Parse the same row twice and compare" was written first and measured useless: two
    `formatters(for:)` calls a few microseconds apart can land on the same anchor, so the broken
    version passed it roughly half the time (and the FTP copy of it passed the negative control
    outright). Asserting that a parsed year-less date carries **zero seconds** cannot depend on
    timing, and it is what makes the negative control fail 3/3 instead of sometimes.

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
  2000. Set `defaultDate` on year-less formats and roll the year back if the result is in
  the future — but set it to **now truncated to the minute**, not to a bare `Date()`. This entry
  said `Date()` for four milestones and that is a bug, corrected 2026-08-22 (▸ Parsing a year-less
  timestamp, below): `defaultDate` supplies *every* component the format does not name, and
  `MMM d HH:mm` names no seconds, so each parse stamps the row with the second and millisecond it
  ran at. Shared by all four columnar parsers (`bsdtar`, `sftp`, FTP `LIST`, and the `ssh` `find`
  walk) through `ColumnarListing.formatters(for:)`.
- **`-C` may be interleaved with the names in create mode, so a set gathered from several
  directories needs no staging directory at all.** Measured against libarchive 3.7.4 before any
  Swift: `bsdtar -c -f out.zip --format zip -C /a alpha.txt -C /b beta.txt` exits 0 and writes both
  members under their bare names. That is what a pack over rows staged off a server looks like —
  `MaterializeRunner` gives every downloaded object its own directory so two objects called
  `report.pdf` cannot collide — and it removed the whole design that was about to be built: no
  gathering directory, no hardlink trick (and no cross-volume fallback for it), nobody's bytes
  copied twice. Emit the flag **only where the directory changes** and an ordinary one-folder pack's
  argv is byte-identical to what it always sent, which is the property that makes the general form
  safe to adopt everywhere. Absolute directories always: a *relative* `-C` resolves against the
  previous one, so a second one lands somewhere nobody named.
  - The libarchive side needed nothing, which is worth checking before designing around either:
    `ArchiveSourceItem` has split the absolute `onDiskPath` from the relative `archivePath` since
    M19, so only the *entry point* (`items(inDirectory:names:)`) ever assumed one directory. Both
    writers already wanted the general shape and neither could express it.
- **`bsdtar` answers **SIGINFO** with exact input-byte progress, on a pipe, and that is the only
  progress it will ever give you.** It prints nothing on its own and no flag turns one on — but
  signalled, it writes two lines to stderr and carries on with its exit status untouched. Measured
  2026-08-30 against libarchive 3.7.4 over 229 MB:

      In: 3 files, 42894848 bytes; Out: 32440320 bytes, compression 24%
      Current: file11.dat (15990784/20000000 bytes)

  - **It works over a real pipe, not just a terminal**, which is what makes it usable from a spawned
    process at all — the exact opposite of `sftp`'s meter, which OpenSSH draws only for a foreground
    process group on a controlling terminal and which therefore cannot be had by an app in any
    configuration (▸ sftp / ssh). Two signals mid-run left the pack at exit 0.
  - **Read `In:` bytes, never `Out:`.** The input side is the quantity a walk can measure *before* the
    pack starts, so a numerator and a denominator that are the same kind of thing; the archive's own
    growth has no denominator until the compression ratio is known, which is at the end.
  - **SIGTERM stops it promptly and leaves a partial archive**, which must be swept — a half-written
    archive is worse than none, because it opens. Measured: cancel at 0.50 s returned at 0.51 s with
    52 MB of partial removed.
  - The cost is one ask per signal, so poll rather than signal per turn: `ProcessWaiting.wait`'s
    100 ms loop signalling every fourth turn is ~2.5 asks a second, which is more than a bar can show.
    Keep only the tail of the stderr buffer — a long pack is asked thousands of times and only the
    newest sample is ever wanted — and cut it on a line boundary, since the parser's own rule is that
    a half-arrived line is not a sample.

- **`--options compression-level=N` must go in *unprefixed*.** A module prefix has to name the
  writer actually running (`zip:`, `gzip:`, `bzip2:`, `7zip:`), so one prefixed string breaks the
  moment the user picks another format — `bsdtar: Unknown module name: 'zip'`, exit 1, no archive.
  Unprefixed, libarchive offers the option to whichever module is running. Two more sharp edges:
  a value outside 0–9 fails with the *misleading* `Undefined option: 'compression-level'` (it is
  defined; the value is out of range), and plain `.tar` rejects the option outright with the same
  message — so the flag has to be **withheld** for an uncompressed format rather than passed and
  hoped over. All three fail the whole pack, not the setting.
  - **The dial has almost no range above the default, which is not what the numbers suggest.**
    Measured on 980 KB of Swift source: zip 314 221 → 313 960 at level 9 (0.08 %), 7z 193 706 →
    193 704 (**2 bytes**), and bzip2 *identical*, because libarchive's bzip2 default already **is**
    9 — only gzip gains anything (261 253 → 259 482, 0.7 %). Level 1 is where the real difference
    lives: +9.7 % size on zip and **+16 % on 7z for a 4× speedup** (0.20 s → 0.05 s). Deflate can
    even invert — on one 840 KB text file level 1 beat level 9 by 1 087 bytes. So a
    compression-level control is a *fast* switch, not a *smaller* one, and "Maximum" is honest
    about intent while delivering ~0 %.
  - **Level 0 means three different things**, so it is not offerable as one "Store" item: a true
    stored container for zip and gzip (output larger than the input), silently clamped to 1 by
    bzip2, and still compressing for the 7z writer (540 259 — *smaller* than its own level 1).
  - `.normal` is therefore modeled as **passing no option at all**, not as an explicit `6`:
    libarchive's per-format defaults are not all 6, and the default is what "normal" means.

### sftp / ssh

- **Copying a *tree* off a server needs a **routing** backend; copying one file does not — and the
  difference fails before a byte moves.** `CopyEngine` creates directories and writes files on the
  **destination** side, so handed a bare `SFTPBackend` it refuses the local temp path with
  `pathOutsideConnection`; a one-file fetch is a single `copyFile` the remote backend answers itself
  and never notices. The app always holds a `CompositeBackend`, so this is a *harness* trap rather
  than a product one — measured 2026-08-30, when a live test of folder staging failed naming a temp
  directory nobody had asked about, which reads as a broken fetch rather than as a fake that is one
  backend short.

- **`sftp` batch `ls -la` is not GNU `ls -l`**: the link-count column is `?`, names are printed
  as full paths (reduce to last component), symlink targets are not shown, and there is **no
  `ls -d`** — stat a directory via the `.` self-row of its own listing.
- **`sftp`'s `ls` follows symlinks**, so classify an item for recursive delete from its *parent
  listing*, not a stat, or a link-to-directory deletes the target's contents. There is no `rm -r`;
  walk depth-first then `rmdir`.
- **`sftp -b -` forces `BatchMode=yes`, which kills the password prompt** — password auth cannot
  use `-b` and must run interactively over piped stdin. Interactive mode exits 0 on a failed
  command, so scan stderr rather than trusting the exit code.
- **`sftp` prints no progress meter to a spawned process, and there is no flag that changes that.**
  Measured 2026-08-16 over a 1 GiB transfer against a real local `sshd`, in six configurations:
  `-b -` and interactive, stdout on a **pipe** and on a **PTY**, and with the `progress` batch
  command explicitly enabling it — which replies `Progress meter enabled` and then prints nothing
  for the whole three seconds. Every run's entire output was the echoed command. OpenSSH draws the
  meter only for a *foreground process group on a controlling terminal*, which a child spawned by an
  app is not, so neither `-q`'s absence nor a PTY is the lever it looks like. What follows for a file
  manager: an SFTP **download** reports progress by watching its own destination file grow (exact
  and free), and an SFTP **upload** has no observable at all — the only remaining route is polling
  the remote size, which on a transport with no session is a fresh connection and handshake per
  tick. Report the exact count once, at the end, and say why; do not reach for a PTY.
  - The `progress` reply is the trap worth naming on its own: it is an affirmative answer from the
    tool that changes nothing observable, so a probe that stops at "the command was accepted" reports
    a working meter.
- **`SSH_ASKPASS_REQUIRE=force`** (OpenSSH ≥ 8.4) makes ssh call the askpass program with no TTY,
  which is why password auth needs no PTY. Pass the secret only in the child's environment —
  never argv, never disk. Offer **only** `PreferredAuthentications=password`:
  `keyboard-interactive` hangs ~60 s on a wrong password under askpass (macOS PAM).
- **Drain both pipes concurrently** or a two-pipe deadlock wedges the process, and bound the wait
  — some appliances hold the SSH channel open after every command and never return.
- **`sftp` spells the port `-P` and `ssh` spells it `-p`, and getting it wrong is a *usage* error
  that reads as a very fast success.** It exits 1 having printed six lines of help to stderr, so a
  benchmark timing `sftp -p 2222 …` measured **5 ms** "listings" and a sanity check counting output
  lines counted the help text. Two rounds of reasoning were built on that number before the shape of
  the output gave it away. Any harness driving these two tools wants an assertion on
  `usage: sftp` / `usage: ssh` in stderr, not just a nonzero-exit check — the exit code is 1, which
  is also what a real failed command gives.

- **Under `sftp -b`, a batch aborts on the first failed command and exits 1 — so a metadata step
  sent after a transfer reports a *successful* copy as a failure.** Measured 2026-08-28: a `put`
  followed by a `chmod` the server refuses leaves the bytes on the server, correct and complete, and
  exits **1**, which every caller reads as a failed transfer. `sftp`'s **`-` prefix** ("allowed to
  fail") is the exact fix — the same run exits 0, the file is still there, and the refusal is **still
  printed to stderr**, which is the half that keeps the loss reportable rather than merely swallowed.
  A step that *succeeds* prints nothing at all (stderr exactly 0 bytes), so the prefix costs the
  ordinary transfer nothing and a non-empty stderr is itself the signal. It works in interactive
  (password-auth) mode too, where the batch would not have aborted anyway.
  - **Riding the same batch is worth the care, because the alternative is a connection.** `sftp`
    reads one command per line, so a transfer and its follow-up are one session; a second invocation
    is a fresh TCP connect, key exchange and authentication, measured at **71 ms** against a loopback
    server and a real round trip over a network.
  - **A metadata refusal must never reach the transfer's classifier, and it has a family in each
    direction.** `SFTPTransportError.detect(stderr:)` scans the *whole* stream for `permission
    denied` and `no such file` before anything else, so one refused `chmod` turns a completed copy
    into `.permissionDenied` — and in interactive mode, where a failed command exits 0, that is the
    only thing the caller has to go on. The strings are OpenSSH's own, read out of `/usr/bin/sftp`
    rather than guessed: **`remote setstat "%s": %s`** for the remote side (`put -p`, `chmod`,
    `chown`, `chgrp`) and **`local chmod "%s"`**, **`local chmod directory "%s"`**, **`local set
    times "%s"`**, **`local set times on "%s"`** for what `get -p` cannot do on this machine. The
    local family is the easy one to miss and fails identically: a finished *download* classified as
    denied. Anchor the match at the **start of a line** — matching a substring is the bug, since it
    cannot tell whose failure it found.
  - The corollary for the exit code: an exit whose stderr is **nothing but** metadata refusals is a
    transfer that worked. The transfer's own `-p` cannot be `-`-prefixed (a failed `put` has to stay
    a failed copy), so that rule is what covers a `put -p` whose `setstat` the server refuses.

- **There is no way to create a file exclusively over `sftp`, and all three candidates fail
  differently.** Measured 2026-08-23 against a real `sshd` while building ⇧F4's remote route, because
  "create an empty file" reads as though one of them must work: `put` of an empty file **truncates**
  an existing one (exit 0); `put -a` cannot create at all (`stat remote: No such file or directory`)
  *and* refuses an existing file (`destination file same size or larger`), so it is useless in both
  directions; and `rename` onto an occupied destination **overwrites** it silently, exit 0 — OpenSSH
  uses the POSIX-rename extension, so put-to-a-temp-name-then-rename is not exclusive either. So a
  create is a client-side `stat` followed by a `put`, and the window between them is real. Worth
  stating plainly rather than leaving as an implementation detail: FTP has `APPE` and S3 has
  `If-None-Match`, so SFTP is the one backend here where the race cannot be closed at all.
  - Note the third measurement contradicts `RemoteTransportBackend.moveItem`'s own doc comment,
    which claims `.alreadyExists` for an occupied destination. Over SFTP it does not.
- **`put /dev/null` is refused — `local "/dev/null" is not a regular file`, exit 1, nothing
  created.** The obvious spelling of "upload nothing", and it works over FTP (measured) while
  libcurl's HTTP side accepts it and chunk-frames it into a *non*-empty body (▸ curl for S3). Three
  protocols, three answers; a real empty temp file behaves the same everywhere, which is why
  `EmptyUploadFile` exists rather than each transport picking what its own tool tolerates.
- **`put <local> <an existing directory>` exits 0 and creates `<directory>/<the local basename>`.**
  The same basename-appending trap `curl -T` has on a trailing-slash URL, arriving where there is no
  slash to warn you — and it is the quietest failure available, because every layer reports success.
  For ⇧F4 that means a create aimed at a folder's name would drop a file named after a *temporary*
  file inside a folder nobody was editing. `curl` refuses the same thing with 550, so this half is
  SFTP's alone and cannot be found from the FTP side. It is what makes `createFile`'s `stat` guard
  load-bearing for two reasons rather than one, and it is only assertable against a real server: the
  witness is the directory still being **empty** afterwards.
- A failed `put` classifies correctly on both auth paths without any new vocabulary: a missing parent
  gives `dest open "…": No such file or directory` and a read-only one `… Permission denied`, which
  `classify` maps by exit code and `detect` catches on its `no such file` / `permission denied`
  substring checks before its prefix scan (neither message starts with `can't`/`couldn't`/`remote`,
  so the prefix scan alone would have missed both).

- **There is no way to fetch a byte *range* over SFTP, so a segmented download is not SFTP at all.**
  Two dead ends, both cheap to check and both decisive: the system `curl` is built without libssh2 —
  its `--version` protocol list carries no `sftp` and no `scp` — so the one-`curl -Z`-with-N-sections
  shape that serves S3 and FTP cannot be spelled here; and `sftp(1)` has no range verb (`get -a`
  resumes from the local file's length and reads to EOF, with no way to stop). What is left is the
  **exec channel** below, which makes a segment a remote `tail | head` and brings that section's
  caveats with it. Measured 2026-08-24; the whole feature turns on it, and it is one command to
  re-check when the system `curl` next moves.

- **`sftp` *does* have a server-side copy verb, and this file said twice that it did not.** Probed
  2026-08-28 against a real `sshd` (OpenSSH 10.2p1): the server advertises **`copy-data revision 1`**
  and `sftp`'s `cp`/`copy` is genuinely server-side — **64 MiB in 0.08 s** for the whole session,
  connect, authentication and all, with the two files SHA-256 identical. So a duplicate inside one
  SFTP account need not be a download and an upload through this Mac, which is what `RelayCopy`'s own
  doc comment and this file's FTP entry both assumed it must be. `RelayCopy` stays the fallback: it
  is still the only mechanism for a pair of ends on *different* backends, which no server-side verb
  can address.
  - **Detection is the client's own sentence, not a probe.** A server without the extension makes
    `sftp` print **`Server does not support copy-data extension`**, and a `cp` that fails for any
    other reason exits **1** with the reason on stderr (a missing source gives
    `stat remote: No such file or directory`). So it degrades **per connection** exactly as M22's
    exec-channel search walk does — attempt it, latch the refusal for that connection, fall back —
    and there is nothing to ask a server in advance.
  - **`cp` preserves the low nine permission bits and drops the special ones**, like `-p` below, so a
    server-side duplicate of a `rwsr-xr-x` binary is `rwxr-xr-x`. The corrective `chmod` is the same
    one the `-p` entry needs, which is the argument for having one place that finishes a copy's mode
    rather than two.
  - **It carries no timestamp at all, and that is the price of the whole route.** Re-measured
    2026-08-28 with an *old* source (2018): `cp` stamps the copy with **now**, while the relay it
    replaces — `get -p` then `put -p` — reproduces the source's mtime exactly, in the same run
    against the same server. `sftp`'s batch language has no verb that sets a time (`help` lists
    `chmod`, `chown` and `chgrp` and nothing else), so the fast path is the *less* faithful one and
    the honest answer is to count the time as dropped rather than to pretend. It is also the
    measurement a first pass will get backwards: a source created moments ago has an mtime of "now"
    already, so a probe that does not choose an old timestamp reports a carry that is not there.
  - **An occupied destination is overwritten *in place* and keeps its own mode** — `100600` stayed
    `100600` while its bytes became the source's. So the corrective `chmod` is worth sending for an
    *ordinary* mode too and not only for a special bit, which is the one live case that can tell the
    two plans apart: a set-uid mode gets its `chmod` under either rule, so a test using one measures
    nothing about that decision.
  - **It is regular files only and it follows a symlink.** `cp` of a directory is
    `Cannot copy non-regular file: …` at exit 1, and `cp` of a link copies the *target's* bytes into
    a plain file. Neither reaches `CopyEngine`, which walks a tree itself and recreates a link with
    `ln -s` — and both would matter to anything that did not.
  - **A server that refuses it can be built rather than waited for**: `sftp-server -P copy-data`
    bans the request, so the server stops advertising it and the client answers
    `Server does not support copy-data extension` on **stderr**, exit 1, with nothing created. That
    is what makes the whole degradation — the refusal, the latch, the fallback — reachable on one
    Mac, in a live test, on demand. `-P` is the same lever for any other extension.
  - **The `-` prefix works on `cp` too**, so a refused copy mid-batch exits 0 with the sentence still
    on stderr — which matters for the *interactive* (password-auth) path, where a failed command
    exits zero regardless: OpenSSH's sentence matches none of `detect(stderr:)`'s prefixes (it opens
    "Server does not…"), so without an explicit check a refused copy reads as a copy that happened.
    That is the quiet direction, and it is the one no key-auth test can see.
  - **`ssh <host> cp -p` over the exec channel carries everything** — mode *and* both times, 0.07 s
    for the same 64 MiB — and was deliberately not taken. It depends on the exec channel an
    `sftp`-only account does not have, and `runCommand` returns no exit status by design (M22: a
    status cannot classify an exec answer), so proving the copy happened would cost a verifying
    `stat` — a round trip on the one route whose whole point is not spending one. Worth knowing it
    exists before anyone re-derives it.

- **`get -p` / `put -p` carry *both* timestamps exactly and silently drop every special mode bit —
  which is the opposite of the man page on one point and beyond it on the other.** `sftp(1)` says
  `-p` preserves "full file permissions and access times". Measured 2026-08-28 in both directions:
  the **modification** time is carried exactly (the man page does not promise it), the **access**
  time is too, and the low nine permission bits are exact — while **setuid, setgid and sticky are
  dropped**, on a mode the server itself puts on the wire (`ls -la` prints `-rwsr-xr-x` and
  `-rw-r--r-T`). The client masks them off; the protocol does not.
  - **Plain `get`/`put` carries the mode only approximately**, which is worth knowing because it
    looks like it works: the umask applies and a download's local `open` forces owner-write, so
    `0777` arrives as `0755` and `0444` as `0644`, while `0600`, `0640`, `0700` and `0754` all
    survive untouched. A probe that happens to pick one of the second group measures a preservation
    that is not there.
  - **The measurement inverts if the source has been read once already, and that is the probe's own
    doing.** The first run here reported that `-p` did *not* carry the access time — because the
    preceding no-`-p` `get` had bumped the **source's** atime to now, so `-p` copied a "now" that was
    perfectly faithful. Reset the source's times immediately before each run and read *both* sides
    afterwards, or the instrument manufactures the answer (▸ the WebKit sandbox probe, and "verify a
    probe before spending someone else's time on it").
  - **The explicit `chmod` batch verb is strictly more capable than `-p`**, which decides the design
    rather than merely padding it: `chmod 4755` over the wire really does produce `-rwsr-xr-x`. So a
    mode carrying special bits needs one corrective `chmod` after the transfer, and only then — an
    ordinary mode costs nothing extra.
  - `chmod`, `chown` and `chgrp` all take **`-h`**, and it works on both sides of the question:
    `chmod -h 700` on a symlink changed the *link* (`120755` → `120700`) and left its target alone,
    while the same command without `-h` changed the *target* and left the link. `chgrp` to a group
    the account belongs to succeeds; `chown` to another uid is refused with exit 1 and
    `remote setstat "…": Permission denied` — the ordinary unprivileged answer, not a misconfiguration.

- **`sftp`'s `chmod` reports success for a mode the server did not store, and the only evidence is a
  read-back.** Measured 2026-08-28 against a real `sshd`: `chmod 2755` on a file whose group the
  account is **not** a member of exits **0**, prints **nothing** on stderr, and leaves the file at
  `100755` — set-group-ID silently gone. It is POSIX's rule for `chmod(2)` (a non-member cannot set
  S_ISGID) rather than OpenSSH's choice, so it is true of every server, and from a client the run is
  indistinguishable from one that worked.
  - **The control is what makes it a fact about the *write* rather than about the server**, and it
    costs one line: the identical command on a file in a group the account *is* in stores `102755`.
    Both runs, same session, same binary. Without it the natural reading is "this server refuses
    set-gid", which is wrong and would have sent the fix somewhere else.
  - Set-uid and sticky are **not** affected — `4755` → `104755` and `1755` → `101755` — so a probe
    that happens to test either reports a preservation that is only two-thirds there. This is the
    same shape as the `get -p` measurement one entry along, and the same trap: the bits do not
    travel together.
  - **What follows for the product is that a gesture which writes a mode must read it back and report
    what the item *carries*, never what it sent** (`RemoteAttributeVerdict`). A gesture the user made
    and is waiting on can afford the round trip; the bulk *carry* deliberately cannot, which is why
    Slice 2 pays nothing per file and Get Info pays once. Note the asymmetry that keeps the check
    honest: the **mode** is verifiable this way and a **timestamp is not**, because a remote `stat`
    here is a listing row — `ls -la` is minute-resolution and FTP's `LIST` is zone-less on the
    server's clock — so comparing a written time against one would report a false refusal for an
    exact `MFMT`, an hour off for every user in a different zone from their server.
  - **A remote `chgrp` clears set-uid and set-gid as a side effect**, exactly as the local `chown(2)`
    does (measured: `106755` → `100755`, exit 0, nothing printed) — so the ordering rule
    ``AttributeChangePlan`` already encodes locally (group before mode) applies unchanged over the
    wire. It is also half of why owner and group are **not** offered in a remote Get Info: the other
    half is that `chown`/`chgrp` take a **numeric id** and `sftp`'s own `ls -la` prints *names*, so a
    panel built on a listing has nothing to send.

- **A symlink's target is unreadable over `sftp` and readable over the exec channel, so it degrades
  per connection exactly as the search walk does.** Confirmed 2026-08-28: `ls -la` of a *directory*
  prints the kind (`l`) and no ` -> target`, and `ls -la` of the **link itself follows it** — it
  reports the target's mode and size, which is the same trap this file already records for classifying
  an item before a recursive delete. There is no `readlink` in the batch language. Over `ssh`,
  `/usr/bin/env readlink` returns the raw text (`plain.txt`, `/etc/hosts`, `../nowhere` — relative,
  absolute and dangling alike), so an account confined by `ForceCommand internal-sftp` cannot read one
  at all. The honest answer where it cannot be read is to keep refusing.
  - **Correction, 2026-08-28: proceeding without a target was a *crash*, not a broken link.** This
    entry (and PLAN.md, twice) said `CopyEngine`'s `entry.symlinkDestination ?? ""` "would write
    `ln -s "" link`". That is true of the **syscall** — `symlink("")` returns 0 on macOS and leaves a
    0-byte dangling link, measured — and true of the SFTP side, and false of a **download**, which is
    the direction anybody actually meets: `LocalBackend` puts the target through
    `fileSystemRepresentation`, which raises `NSInvalidArgumentException` for the empty string
    (*"Cannot form file system representation of empty string"*). Nothing in Swift catches an
    Objective-C exception, so copying a folder of links off a server **terminated the process**. The
    two halves are independent and both are fixed: the engine refuses a `nil` target by name, and
    `LocalBackend` hands an **empty** one to `symlink(2)` directly so a link that genuinely points at
    nothing is still copyable. Worth keeping as a shape: *a syscall's tolerance says nothing about
    the wrapper's* — the note was written from `symlink(2)`'s manual and the wrapper was never asked.
  - **`readlink` is the wrong verb over the exec channel, on three counts, and `ls -ldn` answers all
    three.** It cannot be **authenticated**: `runCommand` returns stdout and deliberately no exit
    status, and an `sftp`-only account replies with prose *on stdout*, so a bare `readlink` reader
    recreates the link pointing at "This service allows sftp connections only." It cannot be
    **batched**: with several operands it prints one line per *successful* one and silently skips the
    failures (measured — three arguments, two lines), so zipping outputs to inputs gives one link
    another link's target, which is worse than having none. And it cannot be **framed**, since a
    target may contain a newline. An `ls -ldn` row echoes the path it describes and carries a mode
    field, so prose cannot pass and correspondence rides in the data rather than in the order.
  - **A symlink row's size column is its target's byte length, and it is the only thing that can
    frame the target.** ` -> ` is four ordinary characters that a name *and* a target may contain:
    a link **named** `a -> b` pointing at `c` prints `…/a -> b -> c`, where splitting at the first
    arrow answers `b -> c` — a plausible wrong target, which for a copy is a real link pointing
    somewhere nobody wrote. Checked against nine adversarial targets on a real server (two containing
    newlines, one a tab, one a trailing space, one containing ` -> `, one ending in it): the column
    equalled the true byte length **every time**, which is POSIX's definition of a symlink's size
    rather than a habit of one `ls`. `ColumnarListing.linkTarget` takes the separator whose suffix is
    exactly that many bytes and falls back to the first arrow, so it can only sharpen a target;
    the exec-channel parser additionally *requires* the match and drops what it cannot verify.
  - **The cost is the connection, not the row**, so the seam takes a batch: one exec is **77 ms**
    against a loopback `sshd` and reading **twelve** links costs **79 ms**. A per-path API would
    compile, read correctly, and turn a directory of links into a directory of handshakes — which is
    why `VFSBackend.resolvingSymlinkTargets(in:)` is plural and `CompositeBackend` groups by backend
    before routing.
  - **`sftp`'s own `ls -la` never prints a target, so every arrow it emits belongs to a name** —
    re-measured against OpenSSH 10.2, where a plain link shows none. `SFTPListingParser` nonetheless
    splits at ` -> ` "for compatibility with a plain shell `ls -la`" it is never fed, so a link named
    `a -> b` was listed under the shorter name `a`: a wrong **filename** on copy, which the size rule
    cannot save because the coincidence is exact (suffix `b` is 1 byte and the link's size is 1).
    Fixed by giving `unixRow` a `splitsLinkTarget` seam that only this dialect turns off — the
    other three still split, since `bsdtar`, FTP's `LIST` and the exec walk all really do print
    targets. The test that had pinned the old behaviour was pinning a fiction ("compatibility with a
    plain shell `ls -la`", output this parser is never handed), which is the tell worth keeping: a
    test named for a *hypothetical* caller is one to check against the real one before trusting it.

#### The SSH exec channel (M22's server-side search)

`ssh <host> <command>` is the *other* thing an SSH connection can do, and Dirnex uses it for exactly
one thing: having the server walk its own tree with `find` instead of paying a connection per
directory. All measured 2026-08-16 against a real `sshd` (a non-root one on a high port — Remote
Login need not be switched on, and `/usr/sbin/sshd -f <config>` with a generated host key just
works, which makes this whole family probeable on any Mac).

- **A second consumer arrived at M25 and the arithmetic held: a directory *sync* is a listing per
  directory too.** Re-measured 2026-08-28 on the same kind of throwaway server, seventeen
  directories: **1010 ms** as separate `sftp` invocations (59 ms each) against **76 ms** for one
  exec walk. So `DirectorySync` gathers each side through
  ``VFSBackend/subtreeListing(at:isCancelled:)`` before it walks, and a backend without one answers
  `nil` and nothing changes. Worth stating because the seam was built for *search* and reads as
  search's: what it really encodes is "everything under here", which two features now want.
  - **A capped answer must fall back to the walk, not be used and not refuse.** SFTP stops at a row
    limit it chose and says so (``VFSSubtreeListing/isComplete``); a search may present a truncated
    result and a **sync may not**, because a mirror over a subtree that stopped early deletes the
    other side's matching files. Measured with a control: using a capped listing anyway, on a fixture
    whose difference sits at depth two, reports **zero rows** — "these folders are already in sync"
    about a tree it only saw the top of. Slower and right beats faster and destructive.
  - **The degradation is reachable on one Mac, on demand**, which is what makes it testable rather
    than argued: `ForceCommand internal-sftp` in the server's config removes the exec channel, and
    the same live suite then passes every test through the per-directory walk while the shortcut
    answers `nil`. Run it in both configurations — a live test that only ever meets one kind of
    account has measured one branch.

- **The saving is the *connection*, not the walk, and it is enormous even at zero latency.** Over
  501 directories on loopback: **98 ms** for one exec against **34.3 s** as separate `sftp`
  connections (68.5 ms each). A per-directory transport pays a full TCP connect, SSH handshake and
  authentication every time, and on a real network each of those is several round trips. The
  corollary is that a *local* benchmark cannot be used to argue the other way: it flatters the walk
  by removing the only cost the exec route was replacing.
  - The same run measured the option nobody had costed: **one `sftp` session carrying all 501 `ls`
    commands is 239 ms** — `sftp -b` takes many commands, so a breadth-first walk could batch a
    whole level per session and be 140× faster than the shipped one, on every account, with no exec
    channel at all.
- **Neither the exit status nor the choice of stream can classify the result**, which is the finding
  that decides the design. An account confined to the `sftp` subsystem (`ForceCommand
  internal-sftp`) answers an exec request with the sentence "This service allows sftp connections
  only." on **stdout**, exit **1**, stderr **empty** — while `find` answers exit **1 with correct
  rows** whenever one subdirectory was unreadable, and a missing binary answers 127. So a reader
  keyed on the exit code treats a good run as a failure, and one keyed on stdout parses an English
  sentence as its listing. The only usable evidence is what the output *looks like*: `find` echoes
  the operand it was given, so the root's own row is a sentinel that costs nothing to arrange, and
  its absence means "this is not a listing". An empty folder still prints that row, which is exactly
  the case "empty" and "no exec channel" have to be told apart on.
- **An exec channel runs the user's login shell and sources their rc, so a shell *function* shadows
  the command.** Probed: `find() { echo SHADOWED; }; find /tmp` printed `SHADOWED`, and bash reads
  `~/.bashrc` when it detects it was run by sshd — this Mac's own rc ran (errors and all) on every
  `ssh host <command>`. `/usr/bin/env find` execs the binary from `PATH` with no shell lookup and is
  immune; if `env` is somehow absent the command exits 127 and the caller degrades, which is the safe
  direction. Only the words the *shell* resolves need it — a `-exec ls …` inside `find` is spawned by
  `find` itself and cannot be shadowed. The rc is also on the stream: it wrote to stderr here, but
  nothing guarantees that, which is the second reason the parser must be anchored rather than
  trusting.
- **A remote path reaches a shell, so quoting it is a security boundary and not formatting.** POSIX
  single-quoting (`'` → `'\''`) held against a crafted `…/tree'; touch CANARY; echo '` — no canary,
  and `find` reported the whole string as one missing path — while a directory genuinely named
  ``it's $a `b` ;x.txt`` round-tripped byte-for-byte. Inside single quotes `$`, backtick, `;`,
  newline and `*` are all literal, so the quote character is the only thing to escape. Note the path
  can arrive from a listing the *server* produced, so the name being quoted may be a stranger's
  choice — the same reasoning that makes FTP refuse a name carrying CR or LF.
- **Reading a byte range: `tail -c +N | head -c M`, not `dd` — and the reason is short reads.**
  Measured 2026-08-24, both are byte-exact in practice and both reassembled SHA-256 identical, but
  only the pipeline is exact *by construction*: `dd` performs one `read()` per block and BSD has no
  `iflag=fullblock`, so a short read gives a short piece, silently. It happened not to here (a 32 MiB
  block read `1+0 records in`), which is precisely the kind of luck not to build on. `tail` and
  `head` are stream-oriented and read to completion, and they need no block alignment — so a shared
  segment plan works unchanged rather than growing an alignment rule for one backend.
  - **`tail -c +N` seeks.** The obvious worry is that skipping to a late offset reads everything
    before it. Over a 256 MiB file the same 8 MiB piece took **0.31 s at offset 1 and 0.28 s at
    offset 224 MiB** — O(1) in the offset.
  - **`tail -c +N` counts from one**, where a byte range counts from zero. One character, and it is
    the difference between a correct assembly and every piece starting a byte early.
  - **A pipeline's exit status is its last stage's, so this route cannot report a failure.** A
    missing remote path gives `ssh` exit **0** and a **zero-byte** piece, because `head` succeeded.
    `set -o pipefail` is not POSIX and the shell here is the user's own login shell, so there is
    nothing to set. The piece's **length** is the only evidence, which is what makes a length check
    on the assembled pieces load-bearing rather than defensive.
  - **The `sftp`-only refusal lands in the data.** An account with `ForceCommand internal-sftp`
    answers an exec request *successfully* with prose on **stdout** — where the piece's bytes go — so
    a refusal arrives as a 43-byte file rather than as an error. Same finding as the search's, one
    consequence further: there it corrupts a *listing*, here it would corrupt a *file*.
- **N `ssh` children need no drains, if their streams are files rather than pipes.** The two-pipe
  deadlock this file documents everywhere else is a property of pipes: point each child's stdout at
  its own output file and its stderr at a small file beside it, and there is nothing to drain and
  nothing that can fill. That is what keeps "four concurrent transfers" to four spawns joined into
  one `DispatchGroup`, one bounded wait, and one `terminate()` each — rather than the orchestration
  the S3 design rejected when it chose one `curl -Z` over N processes.
- **`find … -exec ls -ldn {} +` is the portable metadata printer, and GNU `-printf` is the trap that
  looks like the right answer.** `-printf '%y\t%s\t%T@\t%p'` is exact, NUL-framable and locale-free —
  and GNU-only, so it needs a capability probe, a second parser and a fallback, and on a Mac with no
  Linux host and no GNU coreutils **none of it can be measured**: the only server available exercises
  the fallback while the common case ships unverified. The POSIX form prints the same nine-column
  `ls -l` row `ColumnarListing.unixRow` already reads for `sftp` and FTP, needs no probe, and has no
  "the server's find is not GNU's" failure mode at all. What it costs is the date column — year-less
  for recent files, zone-less, on the server's clock — which is the coarse-stamp compromise FTP had
  already accepted. Three details of the invocation: `-d` stops `ls` listing each directory it is
  handed (which would duplicate every row `find` already produced), `-n` avoids a passwd lookup per
  row, and `| head -n N` caps the response **on the server** (probed: exit 0, exactly N rows — `find`
  takes its `SIGPIPE` quietly), which matters because the whole output is read into memory.
- **`find`'s row order is its own traversal — depth-first — so it is not safe to truncate.** Probed,
  the depths are visibly non-monotonic. Sort shallowest-first before applying any result cap, the
  same rule S3's flat listing needs and for the same reason: otherwise the cap keeps one deep branch
  and drops everything at the top, which is where the file usually is.
- **A capped shortcut must be able to say so.** The cap is applied by the server, so a truncated run
  is indistinguishable from a complete one — every row is real and nothing failed. Counting rows
  against the cap that was asked for is the only evidence there is, and reporting "complete" is a
  claim about a folder made from a slice of it.
  - **That rule is unreachable at its shipped value, and a negative control is what showed it.** Six
    of seven controls fired; the seventh — always claiming completeness — broke **nothing**, because
    no fixture has 50 000 rows. The cap had to become settable before the branch could be tested at
    all. Worth generalizing: a constant chosen to be *never hit in practice* makes its own rule
    untestable, so either the constant is injectable or the rule is unwatched.

### curl (FTP and FTPS)

macOS ships **no `ftp`, `tnftp` or `lftp`** — probed, only `/usr/bin/curl` (8.7.1). Every
`VFSBackend` verb maps onto it, and the mapping was exercised against a live server rather than read
off a man page.

- **The exit code is the classification — do not scrape stderr.** Every failure that matters has its
  own documented code, each observed by provoking it: **6/7** unreachable, **28** timed out, **60**
  certificate not trusted, **67** login denied, **78** file not found, **90** pinned key mismatch,
  **9** "couldn't cd into the directory", **21** a `-Q` command the server refused. This is the one
  place FTP is *easier* than SFTP, whose classifier greps English prose and would misread a localized
  OpenSSH; an exit code says the same thing in every language.
  - Only **9** and **21** need the reply code out of the message, and the scan must be narrowed to
    **4xx/5xx** and take the **last** match — `curl`'s text routinely carries the server's address,
    and `192.168.1.50` yields a three-digit `192` that a first-match scan classifies on.
  - **FTP's own 550 is ambiguous** — RFC 959 "file unavailable" covers both a missing path and a
    forbidden one, and servers use it for both. Read it as *not found*: that is what a browse
    recovers from, and sending the user to check permissions on a path that isn't there wastes their
    time.
- **`-C -` resumes in both directions, and `-w` hands back the delta.** Verified byte-exact: a
  resumed download from a 1 MiB partial of a 3 MiB file reported exactly 2 097 152 and compared
  identical to the whole file, and `-C -` on an *upload* makes `curl` query the remote `SIZE` itself
  (no `--append` needed). So `%{size_download}` / `%{size_upload}` are the bytes moved *this run* —
  unlike the `sftp` path, which reports a final size the backend has to subtract a prior length from.
- **The credential cannot go in `argv`** (`-u user:pass` is readable by any `ps`) and should not go
  on disk. `-K -` — a config file on **stdin** — is neither. Escaping there is an injection guard,
  not formatting: probed, an unescaped newline in a quoted value makes `curl` read the remainder as
  further *directives* and abort with `'"' is unknown`.
- **FTP has no quoting at all**, so a `-Q` argument is the rest of the line. A name containing CR or
  LF is therefore two commands (`DELE a\r\nDELE important.txt`), and there is nothing to escape it
  *with* — refuse such a path outright. Neither POSIX nor Windows allows these in a name.
- **Percent-encode a URL path more strictly than `CharacterSet.urlPathAllowed`**, which permits the
  sub-delimiters: a `;` in a name is read as FTP's `;type=a` URL suffix and a `#` as a fragment, so a
  legal file name can change *which file* is fetched. Keep only `A-Za-z0-9-._~/` literal.
- **A listing URL needs its trailing slash** or the server answers with the file of that name instead
  of a `LIST`.
- **`LIST` is not standardized and its stamps are unusable for comparison.** Real bytes are Unix
  `ls -l` (bare names, *no* `.`/`..` rows, symlink targets shown — all three differ from `sftp`'s
  dialect); IIS emits a DOS form instead. The timestamp is year-less for recent files **and**
  zone-less, on the *server's* clock, so an FTP mtime is approximate by construction: fine to display
  and sort by, not fine to compare two files with (`DirectorySync` must not use `.sizeAndDate` on an
  FTP side). `MLSD` would fix it and **`curl` cannot send it** — only `LIST` and `NLST`. A per-file
  `-I` does give an exact, zone-anchored `Last-Modified`, so it is a stat-one-item path, never a
  listing path.
  - **The coarse stamp belongs to `LIST`, not to FTP** — which matters because the obvious reading
    is that an FTP timestamp is approximate *by protocol* and therefore unfixable in both
    directions. Probed 2026-08-28 against a real server: `MDTM` reads back `20180607080910` and
    **`MFMT` writes** the same, both **exact to the second and anchored to UTC** (RFC 3659) —
    verified by setting a time through `MFMT` and reading the local truth back, `1528358950`, on a
    host whose own offset is `+0300`, so a timezone error could not have hidden. Both ride
    ``-Q``, so they need no new transport. What is genuinely coarse is the *listing*, and what is
    genuinely absent is a symlink verb.
  - **`SITE CHMOD` carries the mode** the same way (`100754` → `100600`, measured). Neither verb is
    guaranteed by any server, so both degrade per connection like `sftp`'s `copy-data`.
  - **Every `-Q` refusal is `curl` exit 21, and the reply code is what separates the two cases that
    need different sentences**: an unsupported verb answers **500** (`SITE UTIME` and a bogus verb
    both did) and a file problem **550** (`MFMT` on a missing name). That is exactly the
    last-4xx/5xx-token reading `FTPTransportError.classify` already does for exit 21, so a server
    that has never heard of `MFMT` is distinguishable from one refusing the file — without which
    "this server cannot keep timestamps" and "that file is not there" would be one sentence.
- **`curl`'s progress meter is a bar, not an accountant**: measured at ~1 update/second, rounded to
  `k`/`M` (`339k`). Exact counts come from `-w` at the end.
  - **It is also the only observable an upload has, so `-sS` silences the one verb that needs it.**
    The S3 finding applies unchanged over FTP (measured 2026-08-16 against a throttled local server:
    an 8 MB upload silent for 8.02 s with `-sS`, five reports with `-S`), and the write-out still
    arrives on **stdout** afterwards, so nothing that reads it changes. A **download** must keep
    `-sS`: its destination is a local file that grows, which is exact where the meter is a rounded
    percentage.
  - **Letting the meter through means it shares stderr with `curl`'s error prose, and over FTP that
    stream is the *classification*.** `FTPTransportError.classify` reads the **last** three-digit
    4xx/5xx token for two exit codes, and a meter's speed column is three digits and a unit — so a
    transfer moving at `553k` when the server refuses it reads as FTP reply 553 ("file name not
    allowed") and turns a missing path into a permission failure. Keep the table out of the string
    that gets classified (`CurlProgressMeter.prose`).
    - **The live control for that is inert, and knowing why saves a hunt**: every failure provoked
      against a real server classified identically with and without the meter, because a transfer
      that fails has usually not moved enough for its meter to print anything but zeros. It is
      reachable by arithmetic rather than by luck, so pin it headlessly with a hand-built row.
    - **Identify the meter's two header lines structurally, never by their wording.** They are
      whatever precedes the first meter row — nothing else can be, since `curl` prints them when a
      transfer starts and an error arriving first is terminal. Matching `% Total` or `Dload` is a
      rule about this version's phrasing, and "drop the first two lines" eats the whole message on
      the invocations that carry no meter at all (every listing, every `-Q`), which is the common
      case.
  - **The table is printed for every `-S` transfer, including one that never connects** (probed: an
    unreachable host still yields the header and two zero rows before `curl: (7) …`). So on a
    transfer invocation there is always a row after the header, and the structural rule above always
    has something to key on.
- **A `-Q` command refused after a transfer fails the whole invocation — and `curl`'s
  continue-on-failure prefix buys that back only by destroying the attribution.** Measured
  2026-08-28: an upload carrying a post-transfer quote command the server refuses reports **16 bytes
  up and exit 21**, so a successful upload is a failed copy. Prefixing avoids the exit and then
  `%{http_code}` reports only the **last** reply, so a refused `SITE CHMOD` sitting behind a good
  `MFMT` is invisible and a connection can never learn which verb it lacks. Sent in an invocation of
  their own the answer is exact — exit 21 with **500** is a verb this server does not implement,
  **550** is that file's own problem — which is the split `FTPTransportError.classify` reads and the
  only one a per-connection latch can rest on.
  - **The prefix order is `-*`, not `*-`, and the wrong one fails silently.** `-` marks the command
    as post-transfer and `*` as allowed-to-fail, and `curl` reads them in that order: traced on the
    wire, `*-SITE CHMOD …` sends the literal **`-SITE CHMOD …`** *before* the transfer, is answered
    **500 Command "-SITE" not understood**, and still **exits 0** — the mode never applied, on a run
    reporting complete success. `-*SITE CHMOD …` sends `SITE CHMOD` after `STOR` and works. Trace the
    control channel rather than reading the exit code; curl's own documentation phrases the asterisk
    as "prefix the command", which is what makes the wrong order the natural one to write.
  - `%{http_code}` on an FTP invocation is the **last reply code**, not the transfer's — a plain
    upload carrying two quote commands reported `213` (MFMT's) rather than 226. Anything reading it
    as the transfer's status has to account for the quote commands changing it.

- **An FTPS data connection can return zero bytes and exit 18 on this `curl`** when TLS 1.3 is
  negotiated; `--tlsv1.2 --tls-max 1.2` fixes it, on both SSL backends. Apply it as a **retry after
  exit 18**, not up front — forcing every server to 1.2 is a real downgrade for the ones that do 1.3
  correctly. It fails in the quiet direction (an empty listing reads as an empty directory), so a
  smoke test must assert *non-empty* rather than merely "no error".

- **`APPE` is FTP's create-if-absent, and it is the reason a create there is non-destructive where
  SFTP's cannot be.** Measured 2026-08-23 against a real server with `-v` read for the verb:
  `curl --append -T <empty file>` sends **`APPE`**, which **creates** the file when it is absent
  (exit 0, zero bytes) and — appending nothing — leaves an existing one **byte-for-byte untouched**.
  Plain `--upload-file` sends `STOR` and truncates. So the window between a client-side existence
  check and the write is benign over FTP and genuinely destructive over SFTP, for the same feature.
  - **But `APPE` is not universally offered, and the fallback is not optional.** A server that grants
    `STOR` and refuses `APPE` answers **exit 25 / 550** — reproduced by withdrawing exactly the
    append permission from a real account, with `STOR` succeeding on the same connection seconds
    later. So an `APPE`-only create simply fails there, and `FTPCurlTransport.createEmptyFile` tries
    `APPE` first and falls back. The fallback is safe to run blind because every *other* reason
    `APPE` could fail — a missing parent, a read-only directory — fails `STOR` identically.
  - **`-T` onto an existing directory is refused with 550** (exit 25), unlike `sftp`'s `put`, which
    fills it silently (▸ sftp / ssh). Two protocols, opposite failure directions, one guard — which
    is the argument for the guard living in `RemoteTransportBackend` rather than in either transport.
  - The **trailing-slash** rule holds here as it does for S3: `-T` against a URL ending in `/`
    appends the *local* file's basename, so a create URL must be the file's own path. Measured over
    FTP directly rather than inherited from the S3 note.
  - A create must **not** borrow `upload`'s `-S`. There is no progress in zero bytes, and letting a
    meter onto stderr puts a three-digit speed column in front of the classifier that reads FTP reply
    codes out of that same stream — a bug this project has already paid for once.

- **`curl -Z` splits a download over FTP too — and the *answers* work nothing like the HTTP twin's,
  which is what decides the design.** Measured 2026-08-24 against a real `pyftpdlib` server. The
  transfer half is exactly as hoped: eight `range` sections of a 40 MiB file came back as eight exact
  pieces reassembling **SHA-256 identical**, and the server logged **eight control connections and
  eight logins** opened within about a millisecond, each with its own `REST` + `RETR`. So a segment is
  a *login*, not a request, which is why FTP's policy allows four of them where S3's allows eight, and
  raises the threshold to 16 MiB. Throughput on a 4 MB/s per-connection cap, alternating rounds over
  32 MiB: **1 stream 16.02 s, 4 segments 4.01 s, 8 segments 2.01 s** (3/3 each).
  - **A section's reply code is a race and cannot classify anything.** One *successful* run reported
    `225` and `226` mixed across its sections — a range download closes the data connection early, so
    whichever reply `curl` last saw is what `%{http_code}` reports — and a *failed* section reports
    `221`, the goodbye. A whole run has **one** exit code. So over FTP there is no per-section
    classification at all, and the only per-section fact is the file that landed, checked against the
    range that was asked for. That is the opposite of the S3 side, where each section has a status
    worth attributing and 206-vs-200 is load-bearing.
  - **No `--fail`, and that is a real difference rather than an omission.** Over HTTP the flag stops a
    refusal's `<Error>` document being saved under the file's own name; FTP has no error document, and
    a refused `RETR` writes nothing at all (measured: the failing sections' files were simply absent,
    with the flag and without it).
  - **A server that caps concurrent connections fails the run rather than degrading — and it fails it
    expensively.** With `max_cons_per_ip=2` and eight sections, two completed *in full* and six were
    refused `421`. So the wasted work is a quarter of the file per attempt, not a round trip, which is
    what makes a per-connection latch worth having rather than merely tidy: measured live on the same
    server, two downloads over one connection cost **4 logins and 1 `REST`** with a latch and **6 and
    2** without. Latch on the narrow rule — *the server served something and the run still failed* —
    since a missing file serves nothing and latching on that would cost every later download its fast
    path for one absent name.
  - **The per-section options include the security ones**, and dropping them is the quiet direction:
    `curl` reads one option set per transfer, so `--ssl-reqd` and a certificate pin have to be
    repeated in every section or a segmented FTPS download is a downgrade nobody asked for, on the one
    path the user is not watching.
  - **The segmented attempt needs no TLS-1.2 retry of its own.** Exit 18 on an FTPS data connection is
    worth retrying pinned to 1.2 (▸ FTPS trust) — and a failed segmented run already falls back to the
    single-stream download, which *has* that retry. Repeating it would spend a second parallel attempt
    to reach the same place.

#### FTPS trust

- **`--cacert` cannot be used to trust a self-signed server.** Handing `curl` the server's own
  certificate as an anchor still fails the *host-name* check — `certificate subject name
  'test-server.local' does not match target host name '192.168.1.50'` — because a NAS certificate
  names itself, not the address the user types. "Add it to the trust store" is simply not an
  available design.
- **`--pinnedpubkey sha256//…` is, and it is exact.** Verified on both of this `curl`'s TLS backends:
  the right pin transfers, a wrong one aborts with exit 90 *before any data moves*. Pass `--insecure`
  **only** together with a pin — that pairing is trust-on-first-use with SSH's teeth; `--insecure`
  alone is the blanket "don't verify" that must never ship. Making it an enum rather than two
  booleans is what keeps a later edit from setting one without the other.
- **`curl -w '%{certs}'` prints the chain as PEM** plus labeled subject/issuer/dates, so the app
  needs no `openssl` to show the user what it is being asked to trust.
- **What `--pinnedpubkey` hashes is the `SubjectPublicKeyInfo`, not the certificate**, so it must be
  walked out of the DER (skip the optional `[0]` version, then five fields of `TBSCertificate`) and
  digested as a complete TLV. Display the *certificate's* SHA-256 alongside it — that is the value
  every other tool shows and the one a user compares against a NAS admin page — but pin the key,
  which survives a certificate renewal *that reuses the key*. Verify the walk
  against a **real** captured certificate whose two digests were computed by `openssl`, not by the
  code under test: a drifted walk would pin a key the server never presented, and comparing against
  your own output could never catch it.
  - **That qualifier is load-bearing, and this file used to omit it** ("survives a routine renewal
    the way SSH's key pinning does"). Corporate PKI and ACME renewals typically mint a **new
    keypair**, so a mismatch is the ordinary outcome of a renewal rather than a rare one — which is
    what makes the changed-key alert a *dialog with a Trust button*, not a report. Shipped, the
    optimistic reading became an informational alert telling the user to delete their saved server:
    advice that loses the record and its Keychain association, gives them no fingerprint to compare,
    and is exactly what someone being intercepted would also do.
- **A recoverable-error flow gated on one error case leaves its twin a dead end, and a doc comment
  claiming the two are mirrors is not the mirror.** `PanelViewController+ConnectFTP` opened with
  "this is the same shape as the SFTP host-key flow" — true for **first contact** (exit 60 → show
  the fingerprint → pin → retry) and false for the changed-key case, which fell through the `guard
  case .certificateUntrusted` to the generic reporter for the whole life of the feature. The
  structural reason is worth carrying past FTPS: SFTP's pin lives in `known_hosts`, a file the app
  repairs out of band with `ssh-keygen -R`, while FTPS's lives **inside the saved record** — and the
  request reaching the failure handler carried no route back to it (`saveName` is `nil` on a sidebar
  connect precisely because the server is already saved). A missing *handle*, not a missing
  decision, which is why it reads as deliberate.
  - **Adding the second case turns a retry into a possible loop, and the first case terminated by
    accident.** Trust-then-retry is bounded for `certificateUntrusted` only because a pin that
    doesn't match comes back as a *different* error; once both cases retry, a server answering the
    probe and the connect from two different machines re-raises the same question forever. One
    `hasWeighedCertificate` flag on the request is the guard, and the state it protects deserves its
    own sentence rather than the generic one — "still presenting a certificate that doesn't match
    the one you just trusted" is a fact, where re-prompting is a loop.
  - **The same gap silently swallowed first-contact pins from the sidebar**: with `saveName == nil`
    there was nowhere to write, so trusting a certificate for a saved server that had none connected
    and asked again on the next click. One bug, two surfaces, and only the changed-key one gets
    reported — because the other looks like the app being cautious.
  - **The instrument is `pyftpdlib` + two self-signed certificates**, and it is worth the ten
    minutes: a real explicit-FTPS server on `127.0.0.1:2121` restarted with a second certificate is
    a *renewal*, so all four branches (first contact, trust-and-connect, silent reconnect, decline)
    are reachable by hand. Seed the stale state directly — write the saved record with certificate
    **B**'s pin while the server presents **A** — rather than performing the first flow to get
    there; and read the fingerprint off the live alert against `openssl x509 -fingerprint -sha256`,
    which is what proves the dialog is showing the certificate actually presented rather than
    whatever it last stored.

### curl (Amazon S3 and everything that speaks it)

M21's backend. All probed 2026-08-12 against **real** buckets before any Swift; the first result is
what made the milestone affordable and the rest inverted rules borrowed from the FTP backend.

- **The stock `curl` signs SigV4, so S3 needs no SDK and no dependency.** macOS 26 ships 8.7.1 with
  `--aws-sigv4 aws:amz:<region>:s3`, and one spelling reaches AWS, Cloudflare R2, Backblaze B2,
  Wasabi and MinIO alike. Verify with a **control**, since "it returned an error" proves nothing
  here: a fake key against real AWS answers `InvalidAccessKeyId` — meaning a well-formed signature
  was computed and the key looked up — where an *unsigned* request to the same URL returns an empty
  body. Without the second run the first reads as a failure.
  - **The key pair goes on stdin, exactly as FTP's password does.** `--aws-sigv4` takes its
    credential from `curl`'s ordinary `user` setting, so `-K -` carrying `user = "<id>:<secret>"`
    keeps the secret out of `argv` with no loss of function — re-measured 2026-08-13 with the same
    signed/unsigned control, so what is proved is that the secret *arrived*, not merely that it was
    accepted.
  - **`curl` sorts the query string itself when it signs, so callers must not.** Unmeasured, this is
    the assumption that fails as `SignatureDoesNotMatch` for one user with one prefix, and no fake
    key can expose it: AWS rejects an unknown access key id *before* weighing the signature, so every
    error looks the same. What settles it in one run is arithmetic rather than a server — sign a
    deliberately out-of-order query, capture the `Authorization` header with `-v`, and recompute
    SigV4 by hand from the request's own `X-Amz-Date` and `x-amz-content-sha256`. The **sorted**
    canonical query reproduces `curl`'s signature byte-for-byte; the as-written order does not.
    The same run is a full positive control on the chain: an independent implementation of the
    documented algorithm agreeing to the last hex digit says the signing is understood, not just
    working.
- **The exit code is *not* the classification — this is the exact inverse of the FTP rule above.**
  Every S3 failure that matters comes back as HTTP with `curl` exiting **0**: measured, a missing key
  is 404 `NoSuchKey`, a denied bucket 403 `AccessDenied`, a bad key 403 `InvalidAccessKeyId`, a wrong
  region 301 `PermanentRedirect` — four exit codes of 0. Read the HTTP status and the `<Code>`
  element; demote the exit code to the narrower question of whether anything was reached at all
  (6/7 unreachable, 28 timeout, 60 certificate). Borrowing FTP's rule here classifies every failure
  as success.
  - **403 covers two things that send the user to different places**, and only the `<Code>`
    separates them: `InvalidAccessKeyId`/`SignatureDoesNotMatch` is a credential they retype, while
    `AccessDenied` on a key that authenticated fine is a bucket policy they have to go and change.
- **A wrong region answers 301 and hands back the endpoint that would have worked**, in
  `<Endpoint>`. Worth parsing the body for that field alone: from outside, a wrong region is
  indistinguishable from a missing bucket, so without it the connect form reports a failure the user
  has no way to diagnose — and the server already knows the answer. Note the corollary that the
  *regional* host is the only safe one to build (`s3.<region>.amazonaws.com`); the legacy global
  `s3.amazonaws.com` is right only for `us-east-1`.
  - **But read `x-amz-bucket-region` first — the element is a trap in two ways at once.** AWS sends
    that header on *every* response, the 301 included, and it names the region on its own
    (measured 2026-08-13). The `<Endpoint>` element does not: it comes back **bucket-prefixed** and
    in the legacy **dash** spelling — `nasa-nex.s3-us-west-2.amazonaws.com` — neither of which is a
    shape this project ever builds, so a reader written against our own `s3.<region>.amazonaws.com`
    recovers nothing from the one document that exists to hand the answer over. Keep the element as
    the fallback for S3-compatible servers that send no header, and parse it by finding the segment
    that *begins* `s3` rather than by counting from the left: a bucket name may contain dots, so the
    segment count is not fixed.
- **A `NextContinuationToken` must be percent-encoded when it is sent back**, or the page is refused.
  Encode query values to the unreserved set only (`/` included), and path segments to the same set
  plus `/`, which is the stricter-than-`urlPathAllowed` rule the FTP backend already needed and for
  the same reason: a `?` or `#` left literal in a key changes *which object* the request names.
  - **What the refusal *is* was recorded wrongly here for the life of the backend, and the wrong
    version is the reassuring one.** This note used to say AWS answers `InvalidArgument` ("The
    continuation token provided is incorrect"). Re-measured 2026-08-18 against a real bucket: a
    **raw** token answers **403 `SignatureDoesNotMatch`**, and `400 InvalidArgument` is what a
    *correctly encoded but corrupt* token gets — two different failures, and the earlier note had
    the sentence of one attached to the cause of the other. It matters because of where each sends
    the user: `SignatureDoesNotMatch` reads as a bad key, so a **pagination** bug arrives wearing
    the sentence for a credential the user then retypes. PLAN.md §M21 Slice 8 recorded the same
    thing as a *difference* between AWS and an S3-compatible endpoint; there is no difference —
    both answer `SignatureDoesNotMatch`, because `curl` signs the query as written and the service
    re-derives it.
  - **It is `+` and `=` that break it; a raw `/` does not** (isolated in one run: a token carrying
    `/` and no `+` listed the next page fine at 200, a token carrying `+` was refused, and so was
    one carrying only `=`). So the intermittency is a *measurable rate*, not a hunch: at the page
    size the app asks for, 40 sampled tokens were 65 characters with no padding and **22 carried
    `+`**, so about one listing in two would fail — and with the encoder deliberately reverted, a
    1005-object folder listed correctly in **3 of 6** runs seconds apart, throwing
    `VFSError.permissionDenied` in the other three.
  - **Every token is minted per request.** 40 requests at the *same* page boundary returned 40
    distinct tokens, so nothing can pin a token's value, a retry genuinely re-rolls the dice, and a
    small `max-keys` is a legitimate way to reach the loop — at 2 keys the tokens are 57 characters
    and **always** end `==`, which is what makes a test of this deterministic where the shipped page
    size makes it a coin toss.
- **Keys and common prefixes arrive whole at every depth.** A listing of `prefix=tiles/1/` returns
  `CommonPrefixes` of `tiles/1/C/`, not `C/` — so a parser that renders what it is given draws the
  full path in every row, at every level. Take the last component, after dropping a folder's trailing
  delimiter (or every folder row comes out nameless).
- **The trailing delimiter on a listing prefix is load-bearing.** `prefix=doc` matches `docs/`,
  `document.txt` and `doctor/` alike, because a prefix is a string comparison that knows nothing
  about path components — so a folder named `doc` lists its *siblings'* contents as its own.
- **An empty folder is a zero-byte object whose key is the prefix itself**, and it comes back as an
  ordinary row in that folder's own listing. Rendered, it is a duplicate of the folder drawn inside
  itself (the last component of `docs/` is `docs`). Drop the marker whose key equals the prefix being
  listed — and only that one: `docs/sub/` inside a listing of `docs/` is the single row an empty
  subfolder has, so a rule that drops every trailing-slash key deletes empty folders from the UI.
- **`encoding-type=url` has to be read from the response, not assumed from the request.** A server
  that ignores the parameter would otherwise have every key decoded anyway, turning a literal `100%`
  in a legal key into a decode failure — and `%20` into a space that was never there. AWS echoes
  `<EncodingType>url</EncodingType>`; key the decode on that.
- **And what that parameter produces is `application/x-www-form-urlencoded`, not the
  percent-encoding its name implies — so a space comes back as `+`.** Measured 2026-08-18 against a
  real bucket, the same three keys listed with the parameter and without it: a key stored `c d.txt`
  arrives as `c+d.txt`, `trailing␣` as `trailing+`, and a literal `a+b.txt` as `a%2Bb.txt`.
  `removingPercentEncoding` reads straight past the `+`, so **every key holding a space was
  misnamed** — and since every byte-moving verb re-encodes that name into a URL, where a literal `+`
  becomes `%2B`, each one then addressed an object that is not there: `stat` and F5 answered
  `notFound` for a row visible in the pane, and F8 reported success having deleted nothing. Substitute
  before percent-decoding, never after: a real plus always arrives as `%2B`, so a bare `+` in that
  input can only have been a space, while decoding first collapses both onto a space and loses the
  distinction for good.
  - **It is the whitespace-trim bug below with its two hiding places exchanged**, which is why one
    corpus could not find it after the other had already been burned by the same class. That one was
    unreachable against AWS (which honors the parameter, so the space arrives as `%20` and there is
    nothing to trim) and reachable on an S3-compatible endpoint; this one is the reverse — the
    endpoint **ignores** the parameter and never echoes it, so `isURLEncoded` is false there and no
    decoding happens at all, while the public AWS buckets the other fixtures came from have no
    spaces in any key. Neither corpus can carry it. It took a bucket somebody had written a file
    name with a space into, and the general form is worth carrying past S3: **when a rule is keyed
    on a flag the server sets, the fixtures that exercise the flag and the fixtures that exercise
    the rule may be disjoint sets** — having one of each is not coverage.
- **`ISO8601DateFormatter` cannot read both stamp shapes with one option set.** AWS sends
  `…:15.000Z` and several S3-compatible servers send `…:15Z`, and `.withFractionalSeconds` makes the
  fraction **required** rather than optional — so one formatter returns `nil` for half the servers the
  backend exists to reach, i.e. a listing with no dates at all. Two formatters, tried in order. They
  are also not `Sendable`, so they cannot be `static` under Swift 6; hold them per-parse rather than
  per-object, which is where the parser is hot.
- **A stat is one request, and taking the first row of it names the wrong file.** Listing with
  `prefix=` the key itself answers all three outcomes at once — a `Contents` row whose key is
  *exactly* that one is a file, a `CommonPrefixes` of `key/` is a folder, and neither is a path that
  is not there — which is why S3 needs no `HEAD`-then-`LIST` dance. The catch is the same
  string-comparison fact as the trailing delimiter above, arriving where it is much less obvious:
  probed, `prefix=README` came back with `README.alignment_data`, `README.analysis_history`,
  `README.complete_genomics_data`, `README.crams` and **no `README`**. A first-row reading therefore
  reports a *sibling's* size and date under the name that was asked about — a plausible answer about
  the wrong file, which is the quiet direction.
  - **A file can never be missed by paging and a folder can**, which is worth knowing before adding
    a second request "for safety". Keys come back in lexicographic order and a string sorts before
    every string it prefixes, so the object named exactly `key` is always the *first row of the first
    page*. But `/` is 0x2F, so siblings like `docs.txt` and `docs-old` sort ahead of the `docs/`
    group and could in principle fill a page before it appears. So the fallback is worth exactly one
    request, on a truncated page that answered nothing, and never on the ordinary path.
- **Resume works over S3, answers 206, and 416 is what a complete file gets.** Verified byte-exact
  against a real object: `-C -` from a 100 000-byte partial of a 257 098-byte object moved exactly
  157 098 bytes and compared identical to a whole download. Two things follow that are easy to get
  wrong in opposite directions — **success is the 2xx range, not `== 200`**, or every correct resume
  is classified as a failure (and only for the users whose transfer was interrupted once); and
  resuming onto an already-**complete** local file answers **416 Range Not Satisfiable**, so the
  remote size has to be checked first rather than left to `curl -C -` to discover, exactly as the
  FTP backend does. Note the second is invisible until the first is right: with a `== 200` rule
  every resume fails anyway.
- **`%{stderr}` in `--write-out` is what carries the status back without a temp file**, since the
  body owns stdout and the *status* is this backend's whole classification. Emit **labelled** lines
  (`s3-status=…`), not bare values: stderr is not ours alone, and on a transport failure `curl`
  prints its own prose there *first* — measured, an unresolvable host gives
  `curl: (6) Could not resolve host: …` followed by `000`, so a reader that takes the stream, or its
  first line, reads prose as a status. `%header{x-amz-bucket-region}` and `%header{content-length}`
  ride the same mechanism, and an absent header renders empty rather than failing — which is the
  only way to read a HEAD's size, since `size_download` is 0 for one.
- **A mock is not a server, and `moto` answered the upload question wrongly in the confident
  direction.** Probing whether `curl` can PUT a body under SigV4, `moto` stored an **empty object and
  returned HTTP 200** for `--data-binary` while accepting `-T` — which reads exactly like a curl bug
  worth writing down. `--trace-ascii` settled it: curl had sent `Content-Length: 4`, the four bytes,
  and a real `x-amz-content-sha256`, so the bytes went out fine and the mock dropped them. What *is*
  true and still unmeasured against real S3: curl signs an in-memory body with a computed payload
  hash and uses `UNSIGNED-PAYLOAD` for `-T` uploads. Same family as the `swiftc`-defaults harness
  that "verified" a broken delegate conformance — when the subject is behavior rather than request
  shape, trace what was actually sent before believing what came back.
- **A download that is refused writes the refusal into the destination file, under the object's own
  name.** `--output` saves whatever the server sends and an S3 refusal is still a *response*, so
  measured 2026-08-13 against real AWS with a bad key, `README.analysis_history` came away as a
  354-byte `<Error>` document: a file that looks downloaded, in the place the real one was going,
  with `curl` exiting **0**. `--fail` is the fix and it is the one flag a *transfer* wants that a
  listing must not have — the error document is the whole classification for a listing, and for a
  byte copy the status alone says everything. With it, nothing is created (probed: the destination
  is `ABSENT`), the exit is 22, and `s3-status=403` still comes back through the write-out, so no
  diagnosis is lost.
  - **`--remove-on-error` is the reflex pairing and it is wrong here**: it deletes the partial that
    `-C -` exists to resume from. What made it look necessary is also false — probed both with and
    without `-C -`, `--fail` leaves an existing partial **byte-identical**, so a transient refusal
    costs the user nothing they had already downloaded.
  - **416 does not trip `--fail`, and resuming onto a complete file is harmless.** Measured: `curl`
    reports exit 0 and `s3-status=416`, downloads the 373-byte error body and does **not** append it
    — the local file is untouched. So the remote-size check before a resume is about the
    *classification* (416 is not 2xx, so a correct no-op would read as a failed copy) rather than
    about protecting the file, which is the opposite of how it reads.
  - The general shape, and the reason it is worth a note rather than a comment: **when a tool writes
    a response to a file, "did it fail" and "what is in the file" are two questions**, and a
    classifier that only answers the first leaves plausible garbage on disk. It cannot be caught by
    any test over the argument builder, and the file is the *right size for a document*, so nothing
    downstream complains either.
- **An archived object is a normal-looking row that refuses only when its bytes are wanted, and the
  generic 403 mapping tells the user the worst possible thing.** Measured 2026-08-18 against real
  AWS: `PUT` with `x-amz-storage-class: GLACIER` answers 200, `HEAD` answers **200** carrying
  `x-amz-storage-class`, the listing draws an ordinary row with a real size and date — and a plain
  `GET` answers **403 `InvalidObjectState`** ("the operation is not valid for the object's storage
  class") with `<StorageClass>GLACIER</StorageClass>` in the body. So `stat` succeeds, the pane looks
  perfect, and only F5 or a preview fails. Since every non-credential 403 mapped to
  `permissionDenied`, the sentence offered was **"Dirnex may need Full Disk Access in System
  Settings"** — a macOS TCC grant, for an object on Amazon's servers, when nothing is wrong with the
  credentials and the remedy is a restore request on the service.
  - **The wider half is that the sentence never knew which backend it was describing.**
    `VFSErrorText.sentence(for:)` takes only the error, so *every* remote permission failure said
    that — an S3 bucket policy, an SFTP mode, an FTP account — and had done since those backends
    shipped. `VFSError.permissionDenied` carries a `VFSPath` and a path carries its backend, so the
    split needed no change to the error type; it had simply never been asked for. The general form
    is worth more than the S3 case: **a sentence naming a remedy on *this machine* is making a claim
    about where the failure happened**, and any such string needs to know that before it can be
    right. Grep for user-facing text naming System Settings, a disk or a permission dialog and ask
    what it says on a server.
  - **The "is it on a server" test is not the whole rule, and the case it misses is on this Mac.**
    A sync client's mount under `~/Library/CloudStorage` is an ordinary local path with an ordinary
    `.local` backend, so `isRemoteConnection` answers `false` and the Full Disk Access sentence is
    handed straight to it — and that directory is **not TCC-gated** (probed 2026-07-21), so the
    advice names a switch that is already on and could not help if it were off. It is reachable in
    one keystroke rather than in theory: measured 2026-08-31, a Google Drive mount root is
    `dr-x------` on both live accounts, so creating or deleting there answers `EACCES` →
    `.permissionDenied`. The refusal belongs to the *account's* sharing, which is set in the cloud.
    So the honest predicate is not "is this remote" but **"can a macOS grant affect this at all"**,
    and the two questions part company exactly where a remote filesystem is mounted locally.
  - **The two File Provider roots are opposites for this question and twins for the trash route**,
    which is the trap worth naming: `TrashLanding.providerRoots` lists `Library/CloudStorage` and
    `Library/Mobile Documents` together because `FileManager.trashItem` refuses both (▸ The Trash).
    For the *sentence* they invert — `Mobile Documents` is TCC-gated, so Full Disk Access is exactly
    right for an iCloud path and exactly wrong for a `CloudStorage` one. Reusing the trash list here
    is the tempting one-liner and it silently takes the correct advice away from iCloud; only a
    narrowness control catches it, since the fix's own tests pass in both directions.
  - **Only AWS can produce it**, which is why it went unmeasured for a milestone: an S3-compatible
    endpoint refuses every storage class but `STANDARD` outright (`400 InvalidStorageClass`), so
    there is no archived object there to fail on.
- **`409 OperationAborted` is not a name collision, and the generic 409 mapping says it is.** S3
  answers it while another conditional operation on a bucket name is still settling — "a conflicting
  conditional operation is currently in progress against this resource. Please try again." Mapped to
  `alreadyExists` it reads as *"pick another name"* for a name that is available and merely busy.
  Two measurements bound it: create/delete/create of one name **inside a single region** succeeds
  every time (so a deleted name is *not* held — the folklore worth discarding), while changing the
  region between attempts reproduces the refusal on demand, and it does **not** clear quickly —
  three retries over 15 s failed on a name a `HEAD` reported as 404. So the sentence must say "try
  again" without promising when, and anything re-creating a fixed bucket name across regions wants a
  fresh name instead.
- **A remote request's floor is a *round trip*, so a delay threshold tuned against a local wait is
  below it and the sheet always appears.** Measured 2026-08-14 against the real third-party
  endpoint: time to first byte for a small object is **0.512–0.519 s** over five runs, decomposing
  as DNS 0.003 + connect 0.17 + TLS 0.34 + ~0.17 s of server turnaround. Every request is a fresh
  `curl` — HTTP keeps no session, which is why the transport re-signs each invocation — so the
  handshake is paid *per request* and half a second is the floor for anything remote, not the price
  of something big. `CloudDownloadPrompt`'s 400 ms deferral was tuned against iCloud
  materialization, where the wait is either ~0 (bytes present) or long (a download); against a
  network round trip it sits **below the floor**, so a progress sheet would flash up on every
  preview and be dismissed ~115 ms later. Any "don't show a spinner for a fast operation" threshold
  has to be measured against the *transport* it will run over.
- **Every storage class but `STANDARD` can be refused outright, which makes the archived-object
  errors unreachable on a non-AWS endpoint.** Probed 2026-08-14 on the real third-party account:
  `REDUCED_REDUNDANCY`, `STANDARD_IA`, `ONEZONE_IA`, `INTELLIGENT_TIERING`, `GLACIER`,
  `DEEP_ARCHIVE` and `GLACIER_IR` each come back **400 `InvalidStorageClass`** on the `PUT`, and
  only `STANDARD` is accepted. So `403 InvalidObjectState` — the answer a real Glacier object gives
  a plain `GET`, and the one a file manager pointed at a backup bucket most needs to word well —
  cannot be produced there at all. Worth knowing before planning a probe around it: any handling
  written for it ships unmeasured unless somebody has an AWS account, and that is a fact to state
  rather than a gap to paper over.
- **Stop does not stop a remote transfer, and it never has — `isCancelled` is honoured at the *file*
  boundary while the transfer is one `curl` that nothing kills.** Measured 2026-08-14 through the
  real `S3Backend` and the app's own `S3CurlTransport` against a server trickling 4 MiB over 16 s:
  Stop pressed at 1.00 s, `copyFile` returned at **16.98 s**, and the server's own log read
  `SERVED all 4194304 bytes` — no client disconnect — with the destination holding the **complete**
  file and `CancellationError` thrown after all of it. So the whole cost is paid and the result is
  then discarded, which is the opposite of the failure everyone expects to find (a truncated file);
  a partial download is impossible here, and that is exactly why nothing ever looked wrong.
  - **It is the shape of all three remote backends, not an S3 bug.** `S3Backend`, `FTPBackend` and
    `SFTPBackend` each check `isCancelled()` before and after the transfer and hand the byte-moving
    to a transport whose `process.terminate()` is reachable *only* from its own timeout backstop.
    True for SFTP since M5 and FTP since M13. Grep for `process.terminate()` in a transport and read
    what guards it — if the guard is a timeout, cancellation is decoration.
  - **It fails in the quiet direction and the UI actively hides it**: the Stop button dims, the
    operation eventually reports "cancelled", and the file that arrived is correct — so on the small
    files anybody tests with, the two are indistinguishable. It needs a transfer slow enough to
    press Stop *during*, which is why a deliberately rate-limited local server is the instrument and
    a real object is not.
  - **Fixed 2026-08-14 by making the join a poll** (`ProcessWaiting.wait`, one home shared by all
    three transports): wait on the `DispatchGroup` in 100 ms slices, and between slices check
    `isCancelled` and the deadline, terminating the process for either. Re-measured on the same
    server: **16.98 s → 1.11 s** against a Stop at 1.00 s, and the server logged no `SERVED all`.
    The flag reaches the transport because the three protocols' **byte-moving verbs** now take it
    and the metadata verbs deliberately do not — a listing is one round trip, over before anyone
    could press anything, and giving it a cancellation parameter would promise a responsiveness it
    cannot use.
  - **The `throws` assertion is not evidence, and that is worth knowing before writing the test.**
    With one backend reverted to the old shape, every `#expect(throws: CancellationError.self)`
    still passed — the *post*-transfer boundary check throws whether or not anything was stopped,
    which is exactly what the shipped bug was. What separates them is a record of whether the
    transfer verb was **asked**, so that is the assertion each test rests on.
  - **The fix makes a partial file possible for the first time, which is the hazard everyone
    expected to find already there.** Before, a cancelled download left a *complete* file (278 528
    of 4 194 304 bytes now, where it used to be all of them). That is right for F5 — it is the
    partial `-C -` resumes from, which is why `--remove-on-error` is deliberately absent — and it is
    a trap for anything that **caches** a fetch, because a truncated file renders as a damaged
    document rather than as an error. A cache must drop, not keep, whatever a cancelled fetch left.
- **An upload has no local observable, so `curl`'s progress meter is the only thing that knows — and
  `-s` silences it.** Every S3 invocation carried `-sS`, chosen for "no meter, but keep the error
  text", which for a *transfer* means the byte count reaches the caller exactly once, when there is
  nothing left to report: measured 2026-08-14 against the real endpoint, **29 MB took 99 seconds**,
  every one of them silent. A user reported that as the copy not working, which is the honest
  reading of a bar that never moves. `-S` alone keeps the error text and lets the meter through, and
  the labelled `s3-…` write-out fields still land after it — exactly what a labelled reader is for.
  A **download** needs none of this and should not be given it: its destination is a local file that
  grows, so its size is the byte count, exactly, and that invocation's carefully measured flags
  (`--fail`, `-C -`, no `--remove-on-error`) are left alone.
  - **What to parse is the leading integer, and the separator is a carriage return.** Captured from
    that run: `\r  1 27.6M    0     0    1  447k      0   228k  0:02:03  0:00:01  0:02:02  228k`.
    Rows overwrite themselves, so a reader splitting on newlines sees one enormous line and reports
    nothing at all; every other column is human-rounded to three significant figures (`447k`,
    `27.6M`), so the percentage is the only field exact as printed. It is `% Received` for a
    download and `% Xferd` for an upload, and `curl` puts the same number first in both. Everything
    else on that stream — two header lines, `curl`'s own prose, the write-out fields — fails to
    start with an integer, which is the whole filter.
  - **A percentage is an estimate, so it must not decide the final count.** At 1 % resolution a
    transfer reports about a hundred times, which is what a bar needs; the exact figure is the
    write-out's. Report the **remainder** at the end (exact less what was streamed) rather than
    summing the estimates, and only ever forward — a queue's byte tally adds, so a negative delta
    walks its bar backwards.
- **`FileHandle.read(upToCount:)` is not a chunked read: it loops until it has the count asked for
  or EOF.** Probed on a child writing three lines a second apart, it returned **once, at exit,
  holding all three**, where `availableData` delivered them at +0.01 s, +1.01 s and +2.02 s. So a
  drain written the obvious way hands the whole of `curl`'s meter over *after* the transfer it
  describes — which is precisely the silence above, reintroduced one layer down by the code fixing
  it. It fails in the quietest direction available: every byte still arrives, so the response is
  classified correctly, both suites stay green, and only the progress never moves. It survived every
  headless test and was caught by the first live run.
- **The upload question is a *memory* question wearing a cryptography question's clothes.** "Does
  real S3 want a signed payload or `UNSIGNED-PAYLOAD`?" is what the plan carried for a milestone as
  the thing needing credentials to settle — and it never needed them. Measured 2026-08-13 on one
  512 MiB upload: `-T` peaks at **5.3 MB** resident and `--data-binary @` at **1.08 GB**, twice the
  file, because it buffers what it hashes. A file manager cannot spend 2× every uploaded file's size
  in RAM, so `-T` is the only shape available and `UNSIGNED-PAYLOAD` — which `curl` uses because it
  cannot hash a stream it has not read — arrives as a consequence rather than a choice. The request
  is fully signed either way, so it cannot be replayed or re-pointed; only the bytes are TLS's
  rather than the signature's. Worth carrying past S3: **when a question has been open a long time,
  check whether it is the question that is stuck** — this one had an unreachable form (ask AWS) and
  a reachable one (measure the client) that decided it outright.
- **Three spellings of "PUT nothing", and only one is safe.** All measured against an endpoint that
  verifies SigV4 by hand, which is what a folder marker and an empty file both need:
  - **`-T /dev/null` is wrong twice over.** It is not a regular file, so `curl` cannot state a
    length and falls back to **`Transfer-Encoding: chunked` with `UNSIGNED-PAYLOAD`** — a
    combination S3 rejects outright, since a chunked upload needs its own streaming signature. And
    the write-out reports **5 bytes uploaded for an empty file**, which is the chunk framing, so a
    progress counter reading it is wrong about a file that has no bytes.
  - **A bare `-X PUT` sends no `Content-Length` header at all** — legal HTTP, and one more thing for
    a strict S3-compatible server to disagree about.
  - **`--data-binary ""`** sends an explicit `Content-Length: 0` and the real SHA-256 of the empty
    string. It is the one that both states its own emptiness and is fully signed.
- **`-T` against a URL ending in `/` appends the *local* file's basename.** Measured:
  `-T /tmp/tiny.txt <bucket>/trailing/` arrived as the key `trailing/tiny.txt`. So an upload URL
  must never end in a slash — while a **folder marker's must**, since that trailing slash is the
  whole content of the operation. Two rules pointing opposite ways over one character, which is why
  they belong in two different argument builders rather than one with a flag. Nothing in the key
  translation catches it: the key is right and the URL is what changed.
- **`curl` signs `x-amz-copy-source` and `Content-MD5`, and produces neither.** Both appear in
  `SignedHeaders` (measured — `host;x-amz-content-sha256;x-amz-copy-source;x-amz-date`), which is
  what makes a server-side rename and a batch delete reachable at all, since S3 requires every
  `x-amz-*` header to be signed. But the copy source is passed through **byte for byte** (probed with
  spaces and `+` in the key, both arriving exactly as written), so its percent-encoding is the
  caller's — the same stricter-than-`urlPathAllowed` rule the URL path uses, or a `+` or `#` in a
  key renames a *different object*. And the digest's value is the caller's too.
  - **A wrong `Content-MD5` signs perfectly and only the server catches it** (`BadDigest`), which is
    what makes it worth enforcing in the probe rather than merely recording: a lenient endpoint
    agrees with a broken client. Confirmed both directions in one run — the right digest 200, a
    deliberately wrong one 400.
- **A `DeleteObjects` batch reports its failures in the *body*, and a 200 can carry them.** Up to
  1000 keys per request, which is what makes deleting a prefix affordable on a verb where every
  request is billed — but a caller reading only the status reports a folder as deleted with the
  files a bucket policy protects still in it. The quiet direction, and invisible to any test that
  only checks the status. Parse the per-key `<Error>` rows and name the failure on **that key's**
  path, not the folder's; pointing the user at the folder sends them to check permissions on
  something that is fine.
  - `<Key>` nests under **two** parents (`<Deleted>` and `<Error>`), so unlike S3's flat `<Error>`
    document this cannot be read with a name-keyed dictionary — the parent decides which list a key
    joins, and each container must reset the fields it fills or a second row inherits the first
    row's code, turning one refused key into a batch of them.
- **`size_upload` and `size_download` must stay two numbers.** A *refused* upload has both: the whole
  file went out and the `<Error>` document came back. Collapsing them into one "transferred" figure
  reports a failed 3 MiB upload as 3 MiB plus the 153 bytes that rejected it, and picking
  "whichever is non-zero" picks wrong on exactly that request. The caller knows which direction it
  asked for; make it say so.
- **A server that ignores `Expect: 100-continue` costs a flat 1.02 s per upload** (measured against
  one that answers: ~0.01 s). Do not reach for `-H 'Expect:'` to remove it — `curl` only adds the
  header above ~1 KiB, which already restricts the cost to files big enough that the alternative is
  worse: without it, an upload to a bucket the key cannot write to sends the **whole file** before
  learning about the 403. The default already encodes the trade.
- **A folder rename needs no new job type, and reaching for one is the expensive mistake.**
  `CopyEngine.perform` already falls back to a recursive copy-then-delete when a `moveItem` throws
  **`EXDEV`** — with progress, cancellation, conflict policy and a per-item failure report, on the
  operation queue. So a backend whose rename is not atomic for a *prefix* answers `EXDEV` and gets
  all of that for one line, exactly as `RemoteTransportBackend` does for a cross-*backend* move. The
  same signal, used for a cross-*shape* one. Check what the engine already does with a failure
  before designing a job around it.
- **A probe endpoint that does not verify the signature will agree with a broken client.** The
  `moto` lesson above says a mock is not a server; the constructive half is that a ~200-line Python
  handler recomputing SigV4 from the documented algorithm *is* a usable instrument, and cheaper than
  a container. What makes it evidence rather than theatre is the **negative control in the same
  run** — a wrong secret must come back refused, or "every request verified" only means the checker
  is permissive. Two of this session's findings came from that endpoint's log rather than from any
  return value: what `-T` claims as its payload hash, and the basename appended to a trailing-slash
  URL.
- **A multipart *part* is a byte range, and `curl` will only send one from something it can
  `fstat`.** `-T` is already forced by memory (above), and it needs a length it can state: a part
  piped to `-T -` goes out `Transfer-Encoding: chunked`, which S3 refuses for an `UNSIGNED-PAYLOAD`
  upload. The natural fix is the trap — `-H "Content-Length: N"` on a stdin upload does **not**
  stop the chunking, it makes `curl` send *both* headers, a contradictory pair that a lenient
  endpoint reads without complaint (measured: it accepted 5 242 880 bytes and reported
  `size_upload` 5 243 557, the difference being framing it counted as payload). So a part is cut to
  a temp file. The price is one part of temp space and the file's bytes written and read once more,
  which is ~1 % of the wall time of the transfer it pays for — worth computing rather than
  agonizing over.
  - **Two zero-copy routes measure working and both cost more than they save.** The credential can
    move to **`-K /dev/fd/3`**, freeing stdin for `--data-binary @-` — verified end to end, wrong
    secret on fd 3 still refused, so the secret really does arrive that way — and it signs a **real
    payload digest** instead of `UNSIGNED-PAYLOAD`. What kills it is not `curl`: `Foundation.Process`
    exposes only stdin, stdout and stderr, so fd 3 means dropping to `posix_spawn` file actions, and
    writing a body while draining two pipes is a three-way pump on a transport whose deadlock
    behaviour is already settled. The other is an **APFS clone**: `clonefile`, truncate the tail,
    `-C <offset>` to skip the head, `-H "Content-Range:"` to strip the header `-C` adds — it sent the
    exact range with nothing copied. It is APFS-only, needs a writable spot on the *source* volume
    (which a mounted image or a read-only share has not), and therefore needs the copy path as its
    fallback regardless.
  - **`-C <offset>` on an *upload* skips the head and sends everything to the end** — no way to bound
    it — **and adds `Content-Range: bytes <from>-<to>/<total>`**, which it does not sign. Harmless in
    a plain resume and wrong for an `UploadPart`, which has no partial-write semantics. `curl` will
    remove any header it generates if given it with an empty value, which is what makes the clone
    route expressible at all.
- **`%header{etag}` carries a part's ETag through the write-out already in use**, so a part upload
  needs no `-D -` competing with `--output` for a stream. It arrives **quoted**
  (`"f804fb237efd0e539f99f64aa7299653"`) and must be quoted back in the completion manifest — S3
  compares it byte for byte, so tidying the quotes away fails the completion with `InvalidPart` on
  every part.
- **An upload id is the continuation token's twin and needs the same query encoding.** It is an
  opaque server-chosen token, so it round-trips raw right up until a server issues one carrying `/`,
  `+` or `=` — intermittent, per-server, and indistinguishable from a signature problem when it
  happens.
- **`CompleteMultipartUpload` can answer 200 with an `<Error>` body.** AWS may begin the response
  before it has finished assembling, holding the connection open, and then send an error under the
  status it already committed to. Documented rather than measured here — the local endpoint does not
  reproduce it — but it is the shape `DeleteObjects` *was* measured to have, and the asymmetry
  decides it: reading a body that never carries an error costs one parse, while not reading it
  reports an object that does not exist as uploaded.
- **An unfinished multipart upload is a bill, not a mess.** S3 keeps the parts and charges storage
  for them, and they are invisible to an ordinary listing — so an upload that dies without aborting
  leaves the user paying for bytes they cannot see and did not keep. Abort on every failing exit
  including cancellation, and let the abort swallow its own failure: it runs where something has
  already gone wrong, and the caller's error is the one worth reporting.
- **`curl -Z` runs the first transfer alone unless you tell it not to, and nothing says so.** A
  batch of transfers given as `-K` config sections runs in parallel — except that `curl` holds the
  rest back until the first one finishes, so it can see whether the connection is reusable.
  Measured 2026-08-23 (8.7.1, four 8 MiB `-T` uploads against a local endpoint logging each
  request's start and end): **1.02 s** without `--parallel-immediate`, the first part alone and
  then three together, against **0.51 s** with it and all four opening at 0.000. A batch of N
  therefore costs two rounds instead of one, which reads as "parallelism is only helping half as
  much as it should" and produces no error, no log line and no failing test.
  - **Every per-transfer option belongs in the section, not in `argv`.** The credential, the
    signature specifier and both timeouts are repeated per section; `argv` carries only `-Z`, the
    concurrency cap and the silencing. The credential repeated per section still never reaches
    `argv`, which is the property that matters — and the *time budget* moving into the config is a
    trap one layer out: a runner deriving its own backstop from `--max-time` in the arguments finds
    none and falls back to the metadata timeout, terminating a healthy upload part-way through.
  - **A section's write-out is emitted the moment that section finishes**, not at the end of the
    run — which is what makes it a *progress* source and not merely a result. It is the only
    observable a parallel upload has: several transfers share one meter, and nothing local grows the
    way a download's destination file does.
  - **With the meter on, a section that finishes mid-row glues its first field to that row** —
    `…15.9M      s3-part4-status=200` — and a reader keyed on a line *prefix* drops it. Two answers,
    both taken: the batch runs with the meter off (`-sS`), and every write-out opens with a newline
    of its own. It costs a byte and it covers `curl`'s own prose, which shares the stream regardless.
  - **Index the labels by transfer.** Four sections printing `s3-status=` into one stream cannot be
    told apart at all; `s3-part<n>-status=` can, in any order. And the distinction that decides the
    error is *absence*: a section that ran and was refused has a status, while one `curl` never ran
    (a bad argument, a terminated process) prints nothing — so "no status" is a transport failure
    and "status 403" is a service refusal, and a reader that conflates them reports the wrong thing
    on every cancelled batch.
  - **`--fail` is the flag to leave off here**, for the reason this file already gives for every
    other S3 invocation: the `<Error>` document *is* the classification. A refused `UploadPart` is
    the only thing that writes a body on that verb (a successful one answers with headers alone), so
    stdout in the ordinary single-failure case is exactly that part's error, and `--fail` would
    throw it away.
  - **The download half is the same shape with `--fail` back *on*, and the reason is where the bytes
    go.** A segmented download is N `range`/`output` sections in one `-Z` run (measured 2026-08-24
    against a Range-serving local endpoint: eight ranges of a 40 MiB object opening within **98 ms**
    of one another, 0.45 s against 0.72 s without `--parallel-immediate`, which ran section 1 alone
    from +0.000 to +0.306 and the rest from +0.316). Here `output` writes whatever the server sends,
    so without `--fail` a refused section saves an `<Error>` document into a piece that assembly
    would splice into the middle of the user's file — the same inversion the single-stream download
    already documents, per section.
  - **A `Range` request answered with the *whole object* under a 200 is the failure with no symptom,
    and `S3Response.isSuccess` cannot see it** — it is a range by design, because a resumed download
    answers 206. Eight sections then each hold a full copy, every one a "success", and splicing them
    produces a file eight times too long under the right name. Check for **206 specifically** on this
    verb, and treat anything else 2xx as "this endpoint does not honour ranges" rather than as an
    error: the single-stream route produces the right file, so such a server should be slow, not
    broken. Reproducible on demand only by writing a server that does it (`IGNORE_RANGE=1` in
    `Tooling/fake-s3-endpoint.py`), which is why it is designed against rather than waited for.
  - **A download batch's progress is the files, not the meter — and the object's size has to ride
    along as a cap.** Several sections share one meter, so the upload batch reads its own write-out
    lines; a download is writing several files on this machine, whose combined size is exact and
    continuous. The cap is what the paragraph above costs: with the meter's ceiling absent, an
    endpoint answering 200 to every range reports N× the file's size into a queue tally that only
    ever adds, and a bar that has drawn those bytes cannot un-draw them.

- **An additive protocol requirement may *forward* to the old one only when the two are
  indistinguishable in their result — otherwise it must throw.** Three of these now sit side by side
  in `S3Transport` and the rule is what keeps them from being one decision made three ways: a
  batched part upload forwards to a sequential loop (same object, slower), a segmented download
  forwards to a single stream (same file, shipped 2026-08-24), and a **cross-bucket copy must
  refuse**, because a transport that ignored the bucket would copy a different object under the right
  name and report success. The question to ask of a default is not "is this capability optional" but
  "can the caller tell that it was not honoured" — the same test ``S3WriteCondition`` applies to a
  precondition that went missing.
  - **When a default forwards, the *return shape* has to say which of the two happened.** The
    segmented download's stand-in produces the whole file in one stream, so there are no pieces to
    join and no per-segment answers to classify — and a caller told that as an empty array, or as a
    `false`, reads "this transport could not split the request" as a failure and reports one for a
    download that worked perfectly. `S3SegmentedDownload` is two cases for exactly that: the one
    thing a stand-in must never do is look like the thing it stood in for.

- **`curl` signs `If-Match` and `If-None-Match` too, so a conditional write needs no new machinery —
  and the ETag's *quotes* are part of the value.** Probed 2026-08-16 against an endpoint that
  recomputes SigV4 by hand, driven the way the app drives it (`-K -`, `--aws-sigv4`, `-T`): both
  headers arrive in `SignedHeaders` (`host;if-match;x-amz-content-sha256;x-amz-date`) and the
  signature verified every time, with a wrong-secret control refused in the same run. Same shape as
  `x-amz-copy-source` and `Content-MD5` above — the header is ours to spell, the signing is not. The
  sharp edge is the value: an **unquoted** digest is a different byte string, so on a server that
  compares strictly, tidying the quotes off a tag turns every conditional write into a 412. That
  fails in the quiet direction twice over, because a 412 reads as *"somebody else changed this
  file"* — so the app would report a conflict that never happened, confidently, on every save.
  `S3ListingParser` keeps the quotes; nothing between it and the wire may take them off.
  - **"Every conditional write becomes a 412" was over-generalized from the only server that had
    been asked, and Amazon is lenient.** This entry used to state it flatly; re-measured 2026-08-18
    against real AWS in one run, a *quoted* current tag answers **200**, an **unquoted** current tag
    also answers **200**, and only a genuinely wrong tag answers 412. The strict comparison was the
    probe endpoint's, whose 412 semantics are its own code — the same caveat this file already
    attaches to that instrument's *other* answers, arriving on a claim that reads like a fact about
    HTTP. Keep the quotes anyway: a strict server demonstrably exists, and RFC 9110 is on its side.
    The general form is worth more than the S3 case — **when the only server that can answer is one
    you wrote, its strictness is a property of your code, not of the protocol**, so a consequence
    derived from it needs the qualifier until a real service has been asked.
  - **A doomed conditional PUT costs a round trip rather than the file**, which is what makes
    conditioning a *large* save-back free — and it is the second reason for a header this backend
    already keeps for the 403 case. `curl` sends `Expect: 100-continue` above ~1 KiB, and a server
    answering the precondition there ends it before the body moves: measured, a **64 MiB** upload
    against a stale `If-Match` reported `size_upload=0` and returned in **0.0009 s**.
  - **A live test for a refused precondition needs no race, and the word "race" is what kept one
    unwritten for two slices.** PLAN.md carried "arranging the race against a service that honors the
    precondition" as the last unmeasured step of M21; a 412 rests on a **stale tag — a value** — and
    staleness is arrangeable sequentially. The window in production sits between the re-`stat` and
    the PUT; what it *produces* is an object whose tag is no longer the one held, and a second
    ordinary write produces that state exactly. Measured 2026-08-18 against real AWS, all four
    refusals fell out of straight-line programs: `.changedSince` (412 with
    `<Condition>If-Match</Condition>`), `.goneSince` (404 — the half `refusal(for:)` called inferred
    rather than measured), `.alreadyThere` on `If-None-Match: *`, and a refused multipart completion
    that published nothing. The general form: **when a test seems to need concurrency, ask whether it
    needs the timing or only the state the timing produces** — a precondition, a cache invalidation
    and a conflict dialog are all the second kind, and the second kind is deterministic.
    - **The `.ifAbsent` case can only be reached one level below the app, and that is a finding
      rather than a shortcut.** `S3Backend.createFile` does its own `stat` and throws
      `alreadyExists` *before* the conditional PUT is ever sent, so the app's own path never
      exercises the server's `If-None-Match: *` at all — the live test has to call
      `transport.putEmptyObject(key:condition:)`. Worth checking for the shape wherever a
      client-side guard sits in front of a server-side one: the belt makes the braces untested.
    - **Pair every refusal with the write that must succeed, or the suite cannot tell "the server
      honours this" from "we send something it can never match".** Both are green on a refusal-only
      test. The control's own negative control is what shows the teeth: appending one character to
      the tag fails the *control* write with `.remoteFileChangedSinceFetch`, which is a build
      reporting "somebody else changed this file" on **every** save — confident, wrong, and with the
      refusal test still passing.
  - **AWS refuses a `CompleteMultipartUpload` with the status *and* the code** — probed 2026-08-18,
    `HTTP 412` carrying `<Code>PreconditionFailed</Code>`, so a status-only reader would have
    sufficed on every real response seen so far. The body-side reading is still right to keep (AWS
    documents beginning the response before assembly finishes, and the probe endpoint reproduces it),
    but record it as *unseen from Amazon* rather than as measured there. Same run: `?uploads`
    reported **zero** open uploads after the refusal, so the abort-on-every-failing-exit rule is
    confirmed by the bill rather than by reading the code.
  - **What no client can measure is whether a given server honours any of it.** A store that ignores
    `If-Match` answers 200 and overwrites, which is indistinguishable from having honoured it. So a
    conditional write is only ever worth building as **strictly additive** protection: keep whatever
    check already worked everywhere (here the re-`stat` of `RemoteFileRevision`), let the header
    close the window after it on the servers that can, and never let anything the user reads claim
    the write was guarded. The corollary is that a transport which cannot carry a condition must
    **throw** rather than write without it — a caller believing it is protected and not being so is
    strictly worse than one that knows.
  - The probe endpoint is the same ~200-line SigV4-verifying handler this milestone has now used
    four times, and it is worth keeping the negative control habit with it: the semantics it answers
    (412 / 404 / 204) are *its own code*, so what the run settles is the **client** half — signed,
    sent verbatim, canonicalized the way the documented algorithm says. Only AWS or a real account
    can answer the rest.
- **A `CompleteMultipartUpload` can refuse a precondition under a status it has already committed
  to, so on that one verb the `<Code>` is the only readable signal there is.** Probed 2026-08-16 by
  driving the same endpoint into AWS's documented late-failure shape — the response begins before
  the object has finished assembling, so an `<Error>` document arrives under the 200 already sent —
  and the identical refusal came back **`HTTP=200` carrying `<Code>PreconditionFailed</Code>`** where
  the ordinary run answers 412. A reader keyed on the status therefore answers *nothing is wrong*, on
  the one request whose entire job is to say the file arrived: the object silently does not exist and
  the save reports success. Read the status **or** the code, never the status alone, and read the
  body on this verb whatever the status says.
  - **The negative control is unusually sharp here and is worth reproducing rather than reasoning
    about:** the *same* binary with the body-side reading removed passes against a 412-refusing
    server and fails against a 200-committed one. Nothing about the client changed between the two
    runs, which is what says the second reading is reachable only in the shape it exists for — and
    why it would ship untested against any single endpoint.
  - **`curl` signs the header on this request too, and that is not inherited from the `PUT`.** The
    canonical request differs in every field — `POST`, a query string, and a **real** payload digest
    of the manifest where a `-T` stream signs `UNSIGNED-PAYLOAD` — and it verified anyway
    (`content-type;host;if-match;x-amz-content-sha256;x-amz-date`), `If-None-Match: *` alike.
  - **A conditional multipart upload cannot save the transfer, which inverts the `PUT`'s economics.**
    A doomed conditional `PUT` ends at `Expect: 100-continue` before the body moves (64 MiB in
    0.0009 s, above); every part is already sent and paid for by the time the completion is made. So
    the same header is a bargain on a small file and pure protection on a large one — and a retry
    after a refusal re-sends the whole file, since the alternative (holding the upload open across
    the user's answer) is a bill that is invisible to every listing.
  - **A refused completion leaves the upload open**, parts stored and billable — measured, the
    endpoint still held it — so the refusal has to reach whatever aborts. If the abort already runs
    on every failing exit, making the refusal a *throw* is the whole cost of the feature.
- **The bucket verbs invert two of this backend's own rules, and both inversions are measured.**
  `CreateBucket`, `DeleteBucket` and `HeadBucket` were probed 2026-08-13 against a SigV4-verifying
  local endpoint and then a real third-party account. They need **no new signing machinery** — all
  three sign as `host;x-amz-content-sha256;x-amz-date` with a *real* payload digest, never
  `UNSIGNED-PAYLOAD`, because they use `--data-binary` rather than `-T`; the memory argument that
  forces `-T` on a file (5.3 MB against 1.08 GB on 512 MiB) does not apply to a body that is either
  empty or 191 bytes. Two consequences worth having before writing any of them:
  - **A successful `DeleteBucket` is 204**, so a reader keyed on `== 200` classifies every correct
    delete as a failure — the resumed download's 206 trap, arriving on a verb where it is not about
    resuming at all. `S3Response.isSuccess` is already a range; the point is that a *new* verb has
    to use it rather than inherit it by luck.
  - **A trailing slash is safe on both write verbs** (probed both ways: the bucket lands under its
    own name, no slash in the name), which is what lets the account arguments reuse
    `S3Location.bucketURL` instead of growing a second definition of how a bucket is addressed. Note
    this is safe *because* `-T` is not involved — the same flag whose basename-appending behavior
    makes a trailing slash forbidden on an upload URL.
- **A real server can be the permissive one, and here it is: `CreateBucket` on a name the account
  already holds answers 200 and changes nothing.** Measured on a live third-party endpoint. **AWS
  does it too, in `us-east-1`** — re-measured 2026-08-19, a re-create there answers `200` with an
  empty body (three times, stable) where the identical request in `eu-north-1` answers `409
  BucketAlreadyOwnedByYou`, which is the documented legacy behaviour of the oldest region and not a
  quirk of one vendor. So there is no server behavior to rely on and the existence check has to be
  the client's — without it, "create a bucket" on a taken name reports
  success and does nothing, the quiet direction, on the one provider where it is easiest to test. The
  `moto` finding above says a mock will agree with a broken client; this is its twin, and the general
  form covers both: **when a probe's subject is "will this be refused", a single endpoint's yes is
  not evidence, whoever runs it.**
- **A bucket name another account holds answers `409 BucketAlreadyExists`, and it is not the
  collision the shared 409 mapping reads it as.** Measured 2026-08-19 against real AWS: *"The
  requested bucket name is not available. The bucket namespace is shared by all users of the
  system."* Mapped to `alreadyExists` it renders as "already exists **here**" in a pane listing the
  account's own buckets — where the name is absent and cannot be put there, so the user looks, does
  not find it, and retries. The namespace is S3-wide and that is the fact the pane cannot show.
  Note the pattern on this one verb: **409 has now meant three different things** — taken by you
  (`BucketAlreadyOwnedByYou`), merely settling (`OperationAborted`) and taken by a stranger — and
  only the `<Code>` tells them apart.
  - **A properly scoped key can never see it, because IAM is evaluated before the name registry.**
    Probed on `images`, `test` and `backup`, and on the account's *own* data bucket: all four answer
    `403 AccessDenied` ("no identity-based policy allows the s3:CreateBucket action") when the policy
    does not grant `s3:CreateBucket` for that ARN. So the state is unreachable from the ordinary
    credentials this backend is designed for, and reaching it in a test takes a grant on **one ARN
    somebody else already owns** — which cannot create anything, which is exactly what makes the
    grant safe. Worth generalizing: when a service refusal cannot be provoked, check whether the
    *authorization* layer is answering first, and pick a target whose success is impossible.
- **Every broken bucket-name rule comes back as one indistinguishable `400 InvalidBucketName`.**
  Probed with five deliberately different mistakes — an uppercase letter, a two-character name, an
  underscore, an IP-shaped name and a 64-character name — and the answer to all five is the same
  status, the same code and the same sentence ("The specified bucket is not valid"). So local
  validation is not a round-trip optimisation but the only way the user learns *which* rule broke,
  which inverts the usual instinct to let the service be the authority on its own names. The
  corollary is the one that bites later: a **dotted** name is perfectly legal and was accepted in the
  same run, and it is the one that strands the user, because a wildcard certificate is one label deep
  — so it belongs in a warning about *addressing* and never in a naming refusal.
- **A parsed page carries keys in the *wire's* spelling, and every consumer has to decode — the
  recursive delete was the one that did not, so deleting a folder whose contents hold a space
  deleted nothing and reported success.** `S3ListingPage.objects[].key` is deliberately raw, with
  `S3ListingParser.decoder(for:)` as the one decoder callers apply; `S3SubtreeListing` and the entry
  builder both use it and `S3Backend.allKeys(under:at:)` did not, so the sweep behind `removeItem`
  handed `DeleteObjects` `untitled+folder/a.txt` for a key stored `untitled folder/a.txt`. **S3's
  delete is idempotent**, so keys that had never existed answered deleted, `<Quiet>true</Quiet>` left
  the response body empty, there was no `<Error>` row to raise, and the folder was still on screen.
  Every request succeeded; nothing logged. Present since the backend shipped.
  - **It reached the user as a *rename*, which is the shape worth remembering, because the visible
    symptom names the wrong verb.** `moveItem` answers `EXDEV` for a prefix, `CopyEngine` copies the
    subtree and then calls `removeItem` — so what the user saw was a folder that came back under
    **both** names (reported 2026-08-22, on a folder called `untitled folder untitled folder …`). F8
    on the same folder had been silently deleting nothing the whole time, and nobody had noticed,
    because a delete that quietly does nothing looks like a refresh that has not caught up.
  - **The existing corpus was structurally blind to it.** Every fixture in `S3Fixtures` carries
    `<EncodingType>url</EncodingType>` — the flag the decode is keyed on — and not one of their keys
    holds a character the encoding touches, so the whole file exercises the flag and never the rule.
    That is the same disjoint-corpus trap the 2026-08-18 whitespace bug turned on, one layer down and
    with the halves swapped, which is why one had already been paid for and did not prevent the
    other. `S3EncodedKeyFixtures` is now a separate enum for exactly that reason: a gap is visible as
    a missing file and invisible as a missing case inside one whose name suggests coverage.
  - **A key that does not decode must fail the delete, where a listing is right to drop the row.**
    The asymmetry is the whole rule: a row nobody can name is one a listing should omit, and a key a
    delete omits is a file left behind under a folder reported as gone.
  - The reproduction needs a **stateful** double, and that is a finding about the instrument rather
    than an inconvenience: `FakeS3Transport` hands out pages by call index, which cannot express a
    walk that lists a directory per level, and the claim being made is about *what is left in the
    bucket* rather than about which requests were sent. `StatefulS3Bucket` (a key→size map plus the
    listing document) reproduces the user's screenshot exactly when the fix is reverted — the folder
    under both names — and it is the only test here that would.

- **A key's leading and trailing whitespace is part of its name, and one `trimmingCharacters` over a
  parsed XML value costs three verbs at once.** `S3ListingParser` trimmed every element it read,
  which is right for a size, a date, a boolean or a token and wrong for a `<Key>` or a `<Prefix>`.
  Measured 2026-08-13 against a real third-party endpoint: an object stored as `edge2/name ` drew as
  `name`, so F5 and F2 answered **`notFound` for a row sitting in the pane**, and F8 **reported
  success having deleted nothing** — the row was still there afterwards. A common prefix of
  `" folder/"` drew as `folder` and **entered empty**, its contents invisible.
  - **`stat` is what kept it quiet, by working.** The trim is applied to both sides of that
    comparison, so the listed name and the stat'ed key agreed with each other while both disagreed
    with the server. Only the verbs that touch *bytes* build a URL from the name, and only they
    missed — so the pane looked entirely healthy right up until the file was used.
  - **It cannot be reproduced against AWS, which is why it survived the whole milestone.** AWS
    honors `encoding-type=url`, so an edge space arrives as `%20` and the trim finds nothing to
    take; it takes a server that *ignores* that parameter to send the space as itself. The echo
    protects the **decode** (`isURLEncoded`, above) and nothing protected the **trim** — the same
    parameter, one layer further down, with no second reader to notice.
  - The same one-line shape sits in `S3DeleteBatch`'s response parser, where a trimmed `<Key>` only
    reaches an error message — and names a file one character off from the one the server actually
    refused. `S3BucketListParser` is deliberately left trimming: a bucket name cannot contain
    whitespace at all.
  - **A probe that re-types the name it wrote cannot see this class of bug, and that is structural
    rather than careless.** Re-running the whitespace object through download and save-back
    (2026-08-14, PLAN.md §M21 Slice 10 probe 4), the first version built each request from its own
    string literal and passed everything — because the bug is a disagreement between *the name the
    listing produced* and the URL built from it, and a literal is on neither side of that. Address
    the object through the path the **listing** returned, the way the app does, and reintroducing
    the trim kills it instantly with `notFound` on the shortened key. The general form is the one
    this file already records for the WebKit sandbox probe, arriving on a parser: when the subject
    is a round trip, the probe must not supply the value the round trip is supposed to carry.
  - Two controls for that probe measured **inert**, and are worth naming so they are not tried
    again: handing the key over unencoded dies at the *first* verb (a malformed URL) rather than
    producing the sibling key the assertion exists to catch, and percent-encoding the separator
    changes nothing whatsoever, because this endpoint normalizes `%2F` back to `/`. A control that
    fails for the wrong reason is not evidence that the assertion works.
- **Three more things a real S3-compatible endpoint does that AWS does not**, all measured on the
  same account, and each of them retires a probe you would otherwise write against AWS and believe:
  - **The region is fiction and is not validated.** `us-east-1`, `lax`, `default` and `us-west-1`
    all signed and verified against the same bucket, with a wrong-secret control refused in the same
    run — so the signature *is* checked and the credential scope's region simply is not. No
    `x-amz-bucket-region` header on any response either, so the wrong-region 301 recovery path has
    nothing to recover from and cannot be exercised there at all.
  - **A raw continuation token fails as `SignatureDoesNotMatch`** — measured A/B on one token, since
    `curl` signs the query as written and the server re-derives it, so an unencoded `+` or `=` makes
    the two disagree. Listed here originally as a *difference* from AWS, and it is not one:
    re-measured against real Amazon 2026-08-18, the same request gets the same 403 (the entry above
    carries the correction, and what earns `InvalidArgument` is a well-encoded but corrupt token).
    What is genuinely this endpoint's own is *how often*: its tokens routinely carry `==`, so it
    exposes the bug on the first page, where AWS's shipped-page-size tokens carry `+` about half the
    time and a bucket too small to paginate hides it entirely.
  - **A single-label wildcard certificate forces path-style addressing**, and it fails before any S3
    conversation happens. `*.lax.sharktech.net` covers the endpoint and not `<bucket>.s3.lax…`, so a
    virtual-host request dies at **curl exit 60**. Worth knowing that the addressing mode can be
    settled from the *certificate* rather than by trying both: `openssl s_client` answers it in one
    run, and a wildcard is one label deep by RFC 6125 whatever it looks like.
    - **The message that exit code deserves depends on the request you sent, not on the server** —
      and getting that wrong sent users toward plaintext. Under virtual-host addressing the name
      being verified is `<bucket>.<host>`, which is not the endpoint the user typed and not a name
      they can see anywhere in the form, so a valid publicly-issued certificate fails and the remedy
      is an *addressing* checkbox. Dirnex's one certificate sentence had been written for the other
      case (a NAS's self-signed certificate, where the honest advice really is `http://`), so on the
      **default** path of every provider whose certificate is not wildcard-deep it diagnosed an
      addressing problem as a trust problem and recommended the one direction nobody should be
      nudged. Split such a message on the shape of the request; the exit code alone cannot tell you
      which failure you have.
    - **AWS reaches the same state, which is why the branch is not "is this an S3-compatible
      server".** `*.s3.<region>.amazonaws.com` is one label deep too, so a bucket whose own name
      contains **dots** cannot be addressed virtual-host over TLS on AWS either, and path-style is
      the same answer. A rule keyed on the service picker would be right for the endpoint that
      exposed the bug and wrong for Amazon.
    - **When a message names a control, interpolate that control's own title.** The path-style
      checkbox is localized, so spelling its English name inside a translated sentence would name a
      control that does not exist in thirteen of the fourteen languages — the duplicate-display-
      string trap from ▸ Localization, in the one place the user is being told what to click.
    - **That message was the wrong fix, and the reason is that the connect *cannot* detect this: a
      bucket-less connect never puts a bucket in the host.** `ListAllMyBuckets` is
      `GET https://<endpoint>/`, which the one-label wildcard covers perfectly — so connecting with
      the bucket field blank succeeds, lists the buckets, validates nothing about bucket addressing,
      and hands the failure to a *click* two gestures later. Reported by a user 2026-08-13 doing
      exactly that. The sentence then names a checkbox that is **not on screen**, because the sheet it
      lives in was closed when the account connected — a dead end where the whole diagnosis is
      correct, which is the shape to watch for: a probe that is blind to the one setting every later
      request depends on.
      - **The retry is a *measurement*, and it is what the region correction's own argument already
        licensed.** Path-style still verifies the certificate, against the host the user typed — no
        `--insecure`, no pin, no plaintext — so there is no weaker outcome to accept and nothing to
        ask about, exactly as with re-signing for a region the service named. Measured on the endpoint
        that exposed it: virtual-host is exit 60 while the path-style URL for the *same* bucket
        verifies and answers (`InvalidAccessKeyId` signed, `AccessDenied` unsigned — the
        signed/unsigned control above). And it settles the ambiguity the sentence could only guess at,
        since exit 60 alone cannot separate "wildcard too shallow" from "self-signed": if the retry
        connects it was the addressing, and if it fails again the endpoint really is untrusted. The
        second case is one the shipped message got **backwards** — it told a self-signed endpoint to
        tick a checkbox that cannot help it — and reporting the retry's own failure fixes it for free,
        because the certificate sentence reads a path-style location as being about the endpoint.
      - **A correction is worthless until it reaches the saved record, and the record is not always
        the one that was connected.** Entering a bucket from an account pane corrects a *bucket*
        connection nobody asked to save, while the row that will re-discover the same failure on the
        next bucket is the **account's** — so the handle to write back through (`savedServerName`,
        the shape FTPS's re-pin already needed) names the account there and the bucket elsewhere. The
        store method answers `false` when the mode already matches, which is what lets the app call it
        after every connect from a saved record rather than only after a corrected one.
      - **The live account is deliberately left uncorrected**, because its addressing rides in its
        descriptor and its descriptor *is* its `VFSBackendID` — correcting it would re-register the
        backend under `s3ap://` and pull the pane out from under the listing the user is standing in.
        The price is one failed handshake per bucket entered in that session, which happens below HTTP
        and is quick; the saved row is corrected, so the next connect from it costs nothing.

### The Trash

- **`FileManager.trashItem` refuses every item inside a File Provider domain, and *which process
  launched the app* is what decides it — so a developer running from a terminal sees a working
  feature.** Measured 2026-08-31 across all five live domains (Box, Dropbox, OneDrive, Google Drive,
  iCloud): it throws `NSCocoaErrorDomain` **513** with **no underlying POSIX errno**, while at the
  instant of the throw the same process can `open` the file, `rename` it in place, `rename` it into
  `~/.Trash`, and read `~/.Trash`. Nothing underneath refused anything and no grant the user can
  reach is involved — `tccutil reset FileProviderDomain` changes nothing and macOS never prompts.
  Same binary, same signature, back to back: launched from a shell it trashes fine (2/2), launched by
  LaunchServices — the Dock, Finder, `open` — it fails (2/2), because a shell-launched app inherits
  the launching process as its TCC *responsible* process. It is invisible to everything: both suites
  green, both linters clean, the pane lists the folder perfectly. **Any probe of a TCC-shaped
  behaviour has to be launched the way the user launches it**, and this trap cost the first two
  diagnoses of the bug.
  - **`NSWorkspace.recycle` is not the escape, and the run that said it was is the lesson.** It was
    measured succeeding in the failing context on all five domains — and that measurement was
    contaminated by the diagnostic probe a few lines above it, which had renamed each item out to
    `~/.Trash` and straight back, **detaching it from its provider** before `recycle` was asked. With
    no probe in front of it, `recycle` fails with the byte-identical 513: it wraps the same
    `trashItem`. Re-adding the bounce flips it back, 1/1 each way. This file's own rule about a
    probe's *actions* being part of the experiment, met for the third time in one investigation.
  - **The fix is to route, not to fall back**: `trashItem` wherever it works, and a plain rename for
    an item inside a domain. A *fallback* — try one, and on refusal try the other — is the shape this
    codebase keeps paying for; a route decided up front from a property of the path is what
    `CompositeBackend` already does. Routing is also what keeps the cost narrow: Finder's `ptbL`/
    `ptbN` **Put Back** record, which this package can read and cannot write, is lost only for the
    items that were already broken.
  - **Where it must land is the provider's own trash, and getting that wrong downloads the file.**
    Renaming an evicted placeholder *out* of its domain **materializes it** — a 4 MB iCloud file,
    evicted through `evictUbiquitousItem`, took **1.15 s and arrived with `st_blocks` set** — while
    renaming it into that provider's own trash took **0.001 s and left it `SF_DATALESS`**, which is
    exactly what `trashItem` does (0.019 s, still dataless). On a 14 GB placeholder the out-of-domain
    version is a multi-gigabyte download inside a delete.
  - **And the destination is asked, then verified, because it cannot be tabulated.** The entry above
    on `<mount>/.Trash` says a real delete is the only thing that answers which trash a provider
    uses; the constructive half is that
    `FileManager.url(for: .trashDirectory, appropriateFor:)` **plus a `stat`** reproduces that answer
    everywhere. The lookup alone does not — it is a path computation, and it happily names a
    `<mount>/.Trash` that is not there:

    | domain | lookup names | exists | so it lands | `trashItem` |
    |---|---|---|---|---|
    | Box | `<mount>/.Trash` | **no** | `~/.Trash` | `~/.Trash` |
    | OneDrive | `<mount>/.Trash` | **no** | `~/.Trash` | `~/.Trash` |
    | Dropbox | *throws 3328* | — | `~/.Trash` | `~/.Trash` |
    | Drive (streaming) | `<mount>/.Trash` | yes | `<mount>/.Trash` | `<mount>/.Trash` |
    | Drive (mirror) | `~/.Trash` | yes | `~/.Trash` | `~/.Trash` |
    | iCloud Drive | `~/Library/Mobile Documents/.Trash` | yes | that | that |

    Note Dropbox is settled by the lookup **throwing**, which is the one signal that separates a
    provider with a real trash from one that has the directory, the marker xattr and the declared
    capability and does not use it. Never pass `create: true`: that would put a folder inside
    somebody's cloud account, which then syncs.
  - **Use `renamex_np` with `RENAME_EXCL`, never `rename(2)`,** which replaces its destination
    silently — here that is destroying a file the user had already thrown away, the one direction a
    delete must never fail in. `EEXIST` is then the signal to stamp the name the way `trashItem`
    does, and that format is measured rather than invented: `<whole original name> HH-MM-SS-mmm` plus
    the **last** path extension if there is one, so `report.pdf` → `report.pdf 01-14-42-179.pdf`,
    `a.tar.gz` → `a.tar.gz 01-14-42-527.gz`, and a name with no extension gains nothing.
  - **`try?` on a resource-value read flattens the two optionals and erases the distinction the
    routing rests on.** `try? url.resourceValues(…).isUbiquitousItem` is `Bool?`, not `Bool??`, so a
    read that *succeeded with the key absent* — every ordinary file, and every **mirror-mode** Google
    Drive file, whose `<mount>/My Drive` is a symlink out to `~/My Drive` — becomes indistinguishable
    from a read that *threw*. Route on the flattened value and the mirror-mode file takes the
    provider path and loses Finder's Put Back for no reason. `do`/`catch`, with an absent key read as
    `false`. Caught by SwiftLint's `redundant_nil_coalescing` rather than by a test, which is the
    only reason it did not ship.

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
- **Every `~/Library/CloudStorage` mount has a trash too, one per *account*.** Probed 2026-07-22 after
  a file deleted from Google Drive appeared in Finder's Trash and not in Dirnex's — the identical
  report that turned up the iCloud trash a day earlier, which is the tell that "how many trashes are
  there" is answered per *file provider*, not once. It is `<mount>/.Trash`, the same shape as
  iCloud's: at the mount root, with no `<uid>` level, because a mount is already per-account. Two
  Google Drive accounts are two mounts and two trashes.
  - **`com.apple.fileprovider.trash` is the marker**, carried by iCloud's trash and every mount's and
    *not* by `~/.Trash`. Useful to confirm a candidate is the real thing; not needed to find one,
    since the mounts are already enumerated for the sidebar and a path costs nothing.
  - Unlike the iCloud trash this needs **no Full Disk Access** — `~/Library/CloudStorage` is not
    TCC-gated — so a Drive delete shows up even on a Mac that never saw the onboarding sheet.
  - **Put Back works here only for the deletes *Finder* made, and that asymmetry is measured rather
    than inferred.** The origin the provider itself keeps is useless — it rides on the item as
    `com.apple.fileprovider.trash-put-back#PN`, whose whole value is an opaque `__fp/fs/fileID(<n>)`
    with no path in it — but Finder does not rely on it: A/B'd 2026-08-18 in one run against a
    streaming Google Drive mount, a Finder delete **creates** `<mount>/.Trash/.DS_Store` carrying the
    ordinary `ptbL`/`ptbN` pair (read back through `TrashPutBack.origins`, resolving to `My Drive`),
    while `FileManager.trashItem` into the *same* directory writes no record at all — the count
    before and after is the whole measurement, since records outlive their files. So a file Dirnex
    deleted from Drive cannot be put back and one Finder deleted from the same folder can, which is
    the opposite of the shape "the trash has no `.DS_Store`" predicts. Note the corollary for a
    provider whose deletes land in `~/.Trash` (OneDrive, Dropbox — below): there `trashItem` writes
    the pair like any local delete, so Dirnex's own delete **is** put-back-able, and the mount trash
    being unused is what buys it.
  - The `.Trash` must sit **exactly one level below** the CloudStorage root. A `.Trash` deeper inside
    someone's Drive is ordinary content, and reading it as a trash turns F8 there into a permanent
    delete — wrong in the expensive direction.
  - **"Every mount" is Google's habit, not a rule — OneDrive keeps no `.Trash` at all.** Probed
    2026-08-17, the first non-Google provider installed here: `OneDrive-Personal` has no `.Trash` and
    never grows one, and a `FileManager.trashItem` on a file inside it (the F8 path, run through the
    app's own `LocalBackend`) succeeds and answers **`~/.Trash`** — the file leaves the provider
    domain entirely and lands in the boot volume's trash like any ordinary file. So the existence
    filter in `SidebarLocations.trashDirectories` is doing real work rather than being a formality:
    it contributes a row for the Drive mounts, nothing for OneDrive, and the OneDrive delete is
    already visible through `~/.Trash`. Nothing to add for it, and adding a constructed
    `<mount>/.Trash` row would be a dead one.
  - The tell in advance is `fileproviderctl dump <provider>`: OneDrive's domain reports its own
    `.trash` node failing `fetch-children-metadata` with **Cocoa 3328** (*"the feature is not
    supported"*) — the same code `FileManager.url(for: .trashDirectory)` throws — while declaring
    `AllowsTrashing` in its item capabilities (`0x2000003F`, bits 0–5). **A provider can therefore
    claim the trashing capability and still have no local trash to enumerate**; the capability says
    the *item* may be trashed, not that the provider hosts a trash directory. Where a trashed item
    ends up is a question only a real delete answers.
  - **Dropbox is the third shape, and it is the one that says the last sentence above is the whole
    rule: it *has* the trash and does not use it.** Probed 2026-08-18 against a live `Dropbox-Home`
    mount, where every signal this code keys on says yes — `<mount>/.Trash` exists, carries
    `com.apple.fileprovider.trash` (plus a `com.apple.fileprovider.unsynced-trash` no other provider
    here has), and the domain's own dump shows a reconciled `.trash` node with `cap:rwdpfTe--`. A
    real delete answers `~/.Trash` anyway, and so does **Finder's**, which names that destination
    itself (`item .Trash of folder oleg`). The control is what makes it a fact about Dropbox rather
    than about macOS 26 or about the caller: the same binary in the same run trashed a file inside a
    **streaming** Google Drive mount and got `<mount>/.Trash`, and Finder did too. So existence is
    necessary and not sufficient, `SidebarLocations.trashDirectories` contributes a Dropbox row that
    is a permanently empty directory, and that costs one `readdir` and shows nothing — the merged
    Trash is one row over many sources, which is why an unused source is invisible rather than dead.
    Worth stating in that order: the *reason* nothing needs fixing is the merge's shape, not the
    filter.
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
- **A volume can refuse `trashItem` outright — an SMB share does — and the same 3328 that means
  nothing above is the whole verdict here.** Reported 2026-08-25 as *"The system reported an error
  (code 3 328)"* on F8 over a NAS share. `LocalBackend.mapCocoaError`'s `default` branch rendered
  `NSFeatureUnsupportedError` as `.io(code: 3328)`, so a volume that works perfectly and simply
  keeps no Trash was reported to the user as a number. The two readings of that code are the trap:
  from `url(for: .trashDirectory, appropriateFor:)` it is noise (the entry above — measured again
  on freshly created **ExFAT and HFS+** images, both of which threw it and then trashed happily
  into `<volume>/.Trashes/501`), while from **`trashItem` itself** it is the volume's answer.
  The SMB half is the *report* rather than a measurement taken here — no share was mountable on
  this Mac, and no disk image can stand in for one, since every filesystem `hdiutil` makes trashes.
  What was measured is everything on this side of the syscall.
  - **There is no pre-check, so `capabilities(for:)` cannot be taught this.** Probed 2026-08-25:
    no `VOL_CAP_FMT_*` or `VOL_CAP_INT_*` bit names a Trash, and no `URLResourceKey`/`kCFURL*`
    does either — the `volumeSupports…` family covers cloning, renaming, immutable files and a
    dozen more, and stops short of this one. The attempt is the only instrument, which is why the
    degradation happens *after* the refusal rather than in the capability set the way SFTP's does.
  - **It is not a failure and must not be reported as one.** Nothing has moved when the refusal
    arrives, so the honest answer is the confirmed permanent delete the app already has for a
    Trash-less backend — offered, not performed, and worded as the ordinary permanent-delete
    question with the *reason* in the body. Finder does exactly this on a share, down to renaming
    its own menu item. `LocalBackend.trashFailure` names the case and `TrashRefusal` reads it back.
  - **Read the outer code before the underlying errno**, which is the reverse of what the shared
    Cocoa mapper does. A 3328 carrying an `NSPOSIXErrorDomain` `ENOENT` underneath is real (the
    lookup produced exactly that shape on both probe volumes), and letting the errno win reports a
    Trash-less volume as *"not found"* — a second wrong answer wearing a more plausible sentence. A
    genuinely missing file never arrives this way: `trashItem` reports that as
    `NSFileNoSuchFileError`, so nothing is being swallowed.
  - **The two `try?` callers were the same bug in silence, which is worse, and they are fixed**
    (2026-08-25): `removeArchiveMoveOriginals` (F6 into an archive) and `runSyncDeletes` both
    swallowed the refusal, so on such a volume the move left its originals — F6 silently meaning F5
    — and the sync left its deletions while reporting a mirror it had not made. Neither is reachable
    from F8, so neither inherited its fix.
    - **A `try?` around a byte-touching verb cannot tell "it worked" from "it was refused" from "it
      failed", and all three need different answers** — which is what made one line the whole
      defect. ``DeletePass`` is now the one loop all three flows run (F8 included), returning the
      three outcomes apart: `restorations` to journal, `refused` to *ask* about, `failures` to
      report. The rule generalizes past deletes: a `try?` is only honest where the caller genuinely
      does not care *which* of those happened, and a delete is never that caller.
    - **Each flow's answer had to be its own, and the shape of the gesture decides it.** F6's
      originals are already copied into the archive when the refusal lands, so declining is a good
      outcome (a copy) rather than a lost one — it offers the permanent delete that would finish the
      move, and *says so* when declined, since a move quietly meaning something else is the defect
      itself. A sync's refusals arrive one per item inside a batch that may span hundreds, and
      cannot be anticipated (there is no pre-check, above), so they are collected and asked about
      **once at the end** — which costs nothing, because a refusal moves nothing, so every refused
      item is still there when the sheet goes up.
    - The permanent re-run each answer performs can raise no second question: `removeItem` consults
      no Trash, so `.unsupported(.trash)` cannot arise there. That is what makes the offer
      terminate, and it is asserted rather than assumed — a backend answering otherwise would loop
      the sheet forever.
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
  - **Re-granting can *fail*, with the row reading as switched on the whole time — and `auth_value`
    is then the wrong thing to read.** A TCC record stores a **code requirement** alongside the
    authorization, and flipping the switch writes only the authorization: it does not re-derive the
    requirement from the app now on disk. So a bundle id whose signing identity has changed (an
    ad-hoc local build copied over a Developer ID one, which is what testing App Intents asks for —
    ▸ macOS system gates) keeps a record nothing can satisfy, and every read is refused however many
    times the toggle is flipped. Measured 2026-08-26: `tccutil` shows the grant on, the app reads
    `NSCocoaErrorDomain` 257, and the tell is in the log rather than the database —
    `log show --last 10m --predicate 'process == "tccd"' | grep -i dirnex` printing **`Failed to
    match existing code requirement for subject com.dirnex.Dirnex and service
    kTCCServiceSystemPolicyAllFiles`**, at *launch*, seconds after a `TCCDEvent: type=Modify` for
    that same service. Two consequences worth having before the next hunt. The **requirement it
    prints is cert-based and carries no cdhash** (`anchor apple generic and identifier "…" and …
    certificate leaf[subject.OU] = A9N92VGA2M`), so a Sparkle update signed by the release pipeline
    — which pins one `SIGN_IDENTITY` — satisfies it unchanged and a *user's* grant survives every
    update; this is a developer-machine failure, not one to design the product around. And
    `codesign --verify -R=<that requirement>` on the installed bundle answers **exit 0, "explicit
    requirement satisfied"**, which is what makes the state so confusing: the app qualifies, and the
    stored record is what is stale. The only fix is to delete the record so macOS mints a new one —
    `tccutil reset SystemPolicyAllFiles com.dirnex.Dirnex`, then re-add the app with **+** rather
    than re-flipping a row that is still listed. Expect **several** stale records per bundle id
    (`SystemPolicyDocumentsFolder` was still failing here after `SystemPolicyAllFiles` was reset),
    so reset the service the failure actually names.
  - **The app's own one-shot latch turned that into a permanent silent wrong answer, which is the
    half that was ours.** iCloud Drive offers the grant *once* (`hasOfferedFullDiskAccessForICloud`)
    because the listing works without it, one section short — right as an anti-nag rule, and unable
    to tell "the user declined" from "it was working and has since broken". With the grant dead the
    pane drew **2 of 19 rows** with no error, no log and a perfectly plausible listing, and the
    prompt never returned. `ICloudAccessOffer.decide` now takes a second latch recording whether the
    libraries have *ever* been read — the only positive proof available, and proof of exactly the
    capability worth rescuing — so a loss buys one more ask while a decline still buys silence. The
    general shape: **a latch that suppresses a prompt is a claim that the state cannot change back**,
    and when it can, the latch needs to know which direction it moved.
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
  - **`FileManager.attributesOfItem` cannot see the flag at all**, which is what makes a sweep built
    on it *structurally* blind rather than merely missing a check. Probed against the real evicted
    file: it hands back nineteen keys, `NSFileType` = regular and `NSFileSize` = the real 1 151 048,
    and **nothing** for `st_flags` — there is no key to add. `ByteComparator` was written on it and
    was the last sweep still reading through placeholders; the fix is a raw `stat`, where the type,
    the size and `SF_DATALESS` all come out of one syscall, so the guard costs nothing over the type
    check that had to happen anyway (`ChecksumEngine` had already made the same move). Watch the
    real flags word: it came back `0x40000060`, `SF_DATALESS` plus `UF_COMPRESSED|UF_TRACKED`, so
    the test is a mask and never an equality.
  - **No test can produce a placeholder**, so the gate needs a seam. Probed: `chflags` with
    `SF_DATALESS` **returns success** and the kernel silently drops it — the flag belongs to the file
    provider, not to the file's owner — and a following `stat` reads `0x00000000`. That is why
    `ChecksumEngine`'s own guard shipped with no coverage. `ByteComparator` splits at the syscall
    instead: the decision half takes a `ComparisonSubject` (path, is-regular, size, is-dataless) and
    only the thin reader supplies real ones, so every rule is testable and one live run against an
    actual evicted file covers the syscall. Add the `Bool` where an existing bare trailing closure
    binds to `isCancelled` and nothing re-points, but a second *closure* parameter would (above).
  - **The guard belongs immediately before the first read, not at the top of the function.** It
    exists to stop a *download*, and a placeholder carries its real size — so a size mismatch, two
    empty files, and `prescan`'s `tooLargeToScan` are all correct answers that cost nothing, and
    refusing them would abort a content sync over pairs it had already classified. The verification
    that matters is the one that reads *no* bytes: assert the file is **still** `SF_DATALESS`
    afterwards.
  - **Who asks and who refuses is a per-caller decision, and the split is "did the user point at
    this file".** A compare of two files under the cursors downloads them — the same explicit
    request Enter and F4 already answer that way, through the same `CloudDownloadPrompt` (silent
    start, sheet after 400 ms, Stop) — while `DirectorySync`'s tree sweep stops and names the first
    placeholder, because a folder is not a file anybody pointed at. Checksums will meet the same
    fork. The trap is on the *asking* side: an app that catches the refusal and then hands the pair
    to an external diff tool has merely moved the blocking read into FileMerge, where nothing on
    screen says why — so the materialize has to sit at the launch, covering the outcomes that reach
    a tool without the comparator ever having read a byte.
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
  Nothing separates the sets: not mtimes, not emptiness (three of the seven are empty), not install
  state, not `bird`'s `client.db` (`app_libraries`, per-zone item counts, tombstones), and
  `fileproviderctl dump` — the authority for Google Drive — enumerates nothing here, because the
  iCloud extension is not running (`not dumping extension`). Don't spend an afternoon on it a third
  time. Dirnex shows **all 17**: between two wrong sets, a folder Finder hides is recoverable noise
  and a folder Finder shows but Dirnex hides reads as lost files.
  - One correlation *is* perfect on this Mac and is still not worth using: a `.DS_Store` in the
    **container** directory (not in `Documents`) is present for exactly the 7 Finder shows and
    absent for the 10 it hides. It is Finder's own bookkeeping, so keying on it means "show what
    Finder has already shown" — a rule that answers nothing on a Mac where Finder never opened
    iCloud Drive.

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
- **Sync status works on Google Drive with no Drive-specific code — but only in *streaming* mode.**
  Verified 2026-07-22 with one account of each kind mounted side by side. A streaming mount is a real
  File Provider domain: every row answers the standard `ubiquitousItem*` resource keys
  (`isUbiquitousItem == true`, `NotDownloaded` for un-materialized items) *and* carries `SF_DATALESS`,
  so `CloudItemAttributes.status` classifies it unchanged and the existing badges were already
  correct in the shipped build. Drive even reproduces iCloud's quirk — `isDownloading` flips true
  while the downloading *status* still reads `NotDownloaded` — which is exactly what the reordered
  precedence in `CloudItemAttributes.status` exists for, so it transferred for free.
  - **In *mirror* mode there is no sync status to read, and that is not a bug to fix.** `My Drive` is
    a symlink out to `~/My Drive`, whose files sit outside any provider domain: every ubiquity key is
    `nil`, `st_flags` is `0`, there are no xattrs, and DriveFS's `metadata_sqlite_db` carries only
    cloud metadata (`trashed`, `starred`, `subscribed`) with no local sync state outside an opaque
    `proto` blob. Finder still badges those files — through Google's own
    `com.google.drivefs.finderhelper.findersync` extension, which only Finder hosts and no
    third-party file manager can consume. Showing nothing is the honest answer.
- **OneDrive needs no OneDrive-specific code either, and this is now measured rather than predicted**
  (2026-08-17, `OneDrive-Personal`, the second provider installed here). The mount root, every folder
  and every file answer `isUbiquitousItem == true`, so `isCloudDirectory`'s *attribute* check opens
  the gate on its own and the `~/Library/CloudStorage` prefix clause stays what it was for Drive:
  insurance, not load-bearing. Reads cost **774 µs median** (n=40, warm, fresh `URL` each time),
  inside the 650–1000 µs band below — so the budget written for iCloud and Drive holds for a third
  provider, and the first read after a cold domain is ~13 ms, which is the number a first paint pays.
  - **The naming forms all resolve correctly**, run through `CloudStorageMounts.mounts()` itself
    rather than its tests: `OneDrive-Personal` alone draws **"OneDrive"** (the account `Personal`
    is withheld, because with one OneDrive-family mount it disambiguates nothing), and
    `OneDrive-SharedLibraries-<tenant>` draws **"SharePoint"**. Add a second account of either family
    and the label moves to the front where truncation cannot eat it — "Personal — OneDrive" beside
    "Contoso — OneDrive", "Contoso — SharePoint" beside "Fabrikam — SharePoint". The two-identical-
    rows collision that motivated the table does not occur in any combination.
  - **`.DS_Store` inside OneDrive badges as a permanent upload, and iCloud's `.DS_Store` does not.**
    Under iCloud it reports `isUbiquitous == false` (the discovery `CloudItemAttributes.status` is
    built on); under OneDrive it reports `isUbiquitous == true` with `isUploaded == false` and stays
    there — sampled repeatedly over minutes — because the client excludes `.DS_Store` from sync while
    the domain still lists it as an item. So the row is a blue "uploading" arrow forever. Note
    `isExcludedFromSync` is **`false`** on it, so `.excluded` — the state that would describe it —
    is not reachable from what the system reports, and the reader is right to say what it is told.
    Only visible with hidden files shown, which is why it is a note and not a bug.
  - **Files On-Demand has to be *unpinned* before `NotDownloaded` can be observed at all.** This
    mount's root carries content policy `keepDownloaded` and OneDrive's own `Pinned` decoration
    ("Always Available on This Device") with children `lazy`; all 186 files were materialized,
    `st_flags 0x40` (`UF_TRACKED`), not one `SF_DATALESS`. A fully pinned account is therefore a
    legitimate state in which the placeholder badge never appears.
  - **Eviction is not scriptable from outside the provider.**
    `NSFileProviderManager.getIdentifierForUserVisibleFile(at:)` happily answers for someone else's
    domain (`item=226 domain=OneDrive`), but `evictItem` on the manager built from it fails
    `NSFileProviderErrorDomain -2001` *"The application cannot be used right now"* (underlying
    `-2014`) from an ad-hoc-signed binary, and `fileproviderctl` (macOS 26) has no `evict` verb —
    only OneDrive's own `FileProviderActions.Debug.Evict`, gated behind `showDebugActions`. Producing
    a placeholder for testing is a Finder or OneDrive-UI gesture, not something a probe can arrange.
- **Dropbox needs no Dropbox-specific code either — a fourth provider, the same answer, and the same
  measurement is what says so** (2026-08-18, `Dropbox-Home`, a team account whose root holds a Team
  Folder and the user's own Team Member Folder). Mount root, folders and files all answer
  `isUbiquitousItem == true`, so the attribute check opens `isCloudDirectory` on its own and the
  `~/Library/CloudStorage` prefix clause is insurance for the fourth time running. Reads cost **903 µs
  median at the root and 762 µs on a file** (n=40, warm, fresh `URL`), against **32 µs** for an
  ordinary local file measured beside them — inside the 650–1000 µs band, so the budget holds.
  - **The naming needs no new table entry, and the reason is worth keeping**: Dropbox's own id
    carries no hyphen, so the fallback split at the *first* hyphen is exactly right for it. Run
    through `CloudStorageMounts.mounts()` itself: `Dropbox-Home` alone draws **"Dropbox"** (the
    account is withheld — with one Dropbox-family mount it disambiguates nothing), a second account
    moves it to the front as **"Home — Dropbox"** beside "Personal — Dropbox", and a *hyphenated team
    name* — the case that broke OneDrive — resolves correctly as `Dropbox-Acme-Corp` →
    account "Acme-Corp", because the hyphen falls inside the **account** rather than inside the
    provider's name. A bare `Dropbox` directory beside `Dropbox-Home` is collision-free too
    ("Dropbox" and "Home — Dropbox").
  - **The mount root is a namespace container, not a folder, and it undoes what you do there.**
    Dropbox's dump gives the root `cap:r-----e--` while its children are `cap:rwdpfTe--`, and the
    filesystem does *not* enforce that — it enforces it afterwards. Measured: a file created at the
    root is accepted and kept, and never uploads (permanently "uploading", where an ordinary file in
    a team folder goes uploading → uploaded in ~4 s); one such file was silently **relocated by
    Dropbox into the member folder** as `… (view-only conflicts 2026-08-18).txt`; and `rm` at the
    root reports success and the file is **back within 5 s**, re-materialized at mode 600. A `mv` out
    of the root is honoured where the plain unlink is not, which is what let the probe clean up after
    itself. This matters because `entryDirectory` deliberately lands a click at the mount root
    whenever it has more than one visible child, which a team account always does — so F7, F5 and F8
    at the Dropbox row are gestures the provider will quietly revert, with the syscall having
    succeeded and nothing to report. Nothing in the ubiquity keys exposes "view-only", so there is no
    honest gate to write; this is a fact about the provider, recorded rather than papered over.
  - **`.DS_Store` badges as a permanent upload here too, and Dropbox is where the two explanations
    separate.** OneDrive's entry above reads it as the client excluding `.DS_Store` from sync; the
    root's own never-uploads behaviour is an equally good fit and a different cause. The control:
    inside a **writable team folder**, a `.DS_Store` is stuck at `isUploaded == false` while an
    ordinary file created beside it reaches `uploaded` in ~4 s. So it is the file name, not the
    folder, and the OneDrive reading holds for a second provider — `isExcludedFromSync` staying
    `false` included, which is why `.excluded` remains unreachable from what the system reports.
  - **`NotDownloaded` is finally measured, and it took a human's right-click.** Dropbox's content
    policy is `lazy` (its dump) and its own `make_online_only` action evaluates **YES** on a
    materialized file — unlike OneDrive's fully pinned account, where the state cannot exist at all —
    but the route to it from a probe is the same dead end as OneDrive's: `evictItem` on a hand-built
    manager for someone else's domain fails `NSFileProviderErrorDomain -2001` (underlying `-2014`)
    from an ad-hoc-signed binary, and `fileproviderctl` still has no evict verb. Made online-only in
    Finder instead (2026-08-18), the file reads exactly as the iCloud shape this file has recorded
    since M6: `st_flags` **`0x40000060`** — `SF_DATALESS` plus `UF_COMPRESSED|UF_TRACKED`, which is
    why the test is a mask and never an equality — `st_blocks` 0, and the **real** `st_size` under
    the real name, no `.icloud` stub. `CloudSyncStorage` answers `notDownloaded` with
    `isDownloading == false`, `FileEntry.isDataless` is `true` off the same `stat` the listing
    already does, and the pane draws the download badge beside a row still reporting 3.1 MB.
    - **The control that matters is that nothing materialized it**: 40 resource-value reads, a real
      `LocalBackend.listDirectory`, and the app's own per-row cloud scan all ran against it and it
      is still `0x40000060` with `st_blocks` 0 afterwards. That is the property the whole
      `SF_DATALESS` guard exists for — one byte read would have downloaded it — so it is worth
      asserting rather than assuming, and it is the half a badge screenshot cannot show. Measured
      twice, on two independent evictions, to the same numbers.
    - **A file some process has *mapped* cannot be evicted, and the provider says so in a way that
      names nothing.** Dropbox refuses with a bare **"Unable to Remove Download"** — no file, no
      reason — and the culprit here was `QuickLookUIService`, holding the JPEG `txt` (mapped) since
      Finder had previewed that folder. `lsof <file>` is the whole diagnosis and it takes one run;
      killing that XPC service (it relaunches on demand) and moving Finder off the folder made the
      same gesture succeed immediately. Worth knowing because the natural readings are all wrong —
      a Dropbox bug, a permissions problem, an unsynced file — and because a *file manager showing
      previews is itself the thing most likely to be holding the mapping*, so anyone reproducing
      this state has probably created the obstacle by looking at the file.
    - The state is not stable on its own: Dropbox's dump carries `speculative disk management:
      <inGreedyState:true>` with a background download pacer, and the first eviction was silently
      re-hydrated within about five minutes with nothing of ours touching the file. So a placeholder
      is something to measure promptly rather than to set up and come back to.
- **A resource-value read inside a File Provider domain costs ~650–1000 µs, not ~24 µs.** It is a
  round trip to the provider, not a `stat`, and it holds for iCloud Drive and Google Drive alike
  (measured warm, fresh `URL` each time). The original ~24 µs figure in the M6 comments was taken on
  an ordinary local file — i.e. on precisely the case `isCloudDirectory` skips — so it under-budgeted
  the only case that runs by ~30×. A 5000-row cloud folder is ~3–5 s of background scanning. This is
  what makes the one-read directory gate worth far more than it looked, and it is worth knowing before
  adding any second per-row read to a cloud listing.
- **A `.gdoc` stub contains no URL**, despite every description (including this repo's own plan)
  saying it holds one. Probed 2026-07-21, the whole file is
  `{"":"WARNING! DO NOT EDIT THIS FILE! …","doc_id":"1aOaGA2IB…","resource_key":"","email":"…"}` —
  note the warning sits under an **empty-string key**. Opening one means *constructing* the URL from
  `doc_id` plus the type implied by the extension (`.gdoc` → `document`, `.gsheet` → `spreadsheets`,
  `.gslides` → `presentation`), not reading a `url` field that isn't there.
  - **Google's own URL segments are inconsistent, and deriving them costs a broken link.** Three of
    the five are plural and two are singular: `document`, `spreadsheets`, `presentation`, `drawings`,
    `forms`. There is no rule; they are a lookup table.
  - **The stub's JSON is identical across kinds**, so the *extension* is the only thing that says
    which editor owns the file. That also means the parse must be handed the file name, not just the
    bytes.
  - **`doc_id` comes out of a file's contents and goes into a URL the app then opens**, which makes
    it an injection surface, not a formatting concern — a `doc_id` of `../../…` or one carrying a
    `?`/`#` re-points the link at somewhere the user never asked for. Real identifiers and resource
    keys are `[A-Za-z0-9_-]`; anything else is refused outright and the file falls back to opening
    in its default app.
  - **A doc opens into whichever Google session the browser already has**, so on a Mac with two
    Drive accounts mounted, a second-account document lands on "You need access" — for a file the
    user owns. Observed live 2026-07-21. `?authuser=<email>` (the stub carries the address) is the
    documented lever and is verified *harmless* — Google accepted it and rewrote the URL to
    `?tab=t.0` on a successful open — but it could not be verified as a *fix* here, because only one
    of the two accounts is signed into this Chrome profile. Nothing on the Dirnex side can do better:
    the handoff is a URL, and which session receives it is the browser's to decide.

- **Box needs no Box-specific code either — a fifth provider, the same answer** (2026-08-18,
  `Box-Box`, a personal account whose domain had been created that morning). Mount root, folders and
  files all answer `isUbiquitousItem == true`, so the attribute check opens `isCloudDirectory` on its
  own and the `~/Library/CloudStorage` prefix clause is insurance for the fifth time running. Reads
  cost **821 µs at the root, 605 µs on a folder and 508–829 µs on a file** (n=40, warm, fresh `URL`),
  against **27 µs** for `/etc/hosts` measured beside them — inside the 650–1000 µs band, so the budget
  holds. The naming needs no table entry: Box's own id carries no hyphen, so the first-hyphen fallback
  is right for it and `Box-Acme-Corp` resolves to the account `Acme-Corp`. Run through
  `CloudStorageMounts.mounts()` itself, the one form worth knowing is that Box labels a personal
  account `Box`, so a second account draws **"Box — Box"** beside "Enterprise — Box" — which looks odd
  and is honest, and does disambiguate.
  - **A `<mount>/.Trash` can be there and then not be there, and Box is where that shows up.** Every
    other provider's answer to "is there a mount trash" has been constant; Box's changes within the
    first quarter-hour of a domain's life. Measured minutes after domain creation: `.Trash` on disk
    carrying `com.apple.fileprovider.trash` *and* `com.apple.fileprovider.unsynced-trash`,
    `SF_DATALESS` (`0x40000020`), **65535** links and a 2 MB size, with a reconciled `.trash` node in
    the domain — i.e. every signal `SidebarLocations.trashDirectories` reads. Thirteen minutes later
    the node had failed `fetch-children-metadata` twice with **Cocoa 3328** (the OneDrive signature,
    two entries below) and the directory was gone from the filesystem permanently. A `stat` reaching
    into it during the changeover returned **`ETIMEDOUT`**. So an existence filter is not merely
    necessary and insufficient (the Dropbox lesson) — its answer is not even *stable*, and the
    unstable window is exactly the one a new user is in.
    - **It degrades correctly and it is worth knowing why, because the near miss is a false Full Disk
      Access sheet.** `LocalBackend.listDirectory` maps `ETIMEDOUT` through `VFSError.fromErrno`,
      which has no case for it, so it lands on `.io` — and `gatherTrash` only treats
      `.permissionDenied` as fatal, dropping everything else with `catch { continue }`. Had the errno
      mapped to a permission error instead, a Box trash timing out would have told a user whose grant
      is fine to go and grant Full Disk Access. Nothing to fix; the merge skips the source and
      presents the rest.
    - How *long* that timeout is stays unmeasured, and the state cannot be re-created to find out:
      macOS 26's `fileproviderctl` has no verb that rebuilds a node (only `dump`, `diagnose`,
      `evaluate`, `check`/`repair`, `obfuscate`), and re-adding the domain would resync the account.
  - **Box is the first provider where the delete's destination depends on *who* deleted it.**
    `FileManager.trashItem` — the F8 path, driven through the real `LocalBackend` — answers
    `~/.Trash`, and the item is **put-back-able**: its `ptbL`/`ptbN` pair reads back through
    `TrashPutBack.origins` naming `…/Box-Box/badge-probe.bin`. Finder's delete on the same mount, in
    the same run, named no destination and left the file **nowhere on this Mac** — not `~/.Trash`, not
    any mount trash, not any volume — so it went to Box's own server-side trash, which is not a
    filesystem location anything can merge. The Google Drive control in that same run answered
    `<mount>/.Trash` for both callers. Note this inverts Drive's asymmetry, where Finder's delete is
    the recoverable one: on Box, *Dirnex's* delete is.
  - **With five providers measured, the two signals are exhausted and neither predicts anything.**
    Box declines trashing outright — `cap:rwdpf-e--` on root, item and trash alike, and
    `capabilities = 0x2000006F` with bit 4 (`allowsTrashing`) clear — where Dropbox, OneDrive and
    Drive all declare `rwdpfTe--`. So every combination of (declares trashing, has a `.Trash`) has now
    been observed, and only Google Drive's delete stays in its mount. **A real delete is the only
    thing that answers where an item goes**; the capability says an item may be trashed, not where to,
    and the directory's existence says nothing at all.
  - **`.DS_Store` badges as a permanent upload here too**, which makes three providers and settles the
    reading. Still `isUploaded == false` nine minutes after it was written, while **two ordinary files
    in the same folder** reached `uploaded` in ~7 s — the control that makes it the file name rather
    than the folder. `isExcludedFromSync` stays `false`, so `.excluded` remains unreachable from what
    the system reports.
  - The upload transient is real and visible: `uploading` at 0.54 s → `uploaded` at 6.94 s on a 72 KB
    file, and drawn live in the app as the uploading badge on a 12 MB one while the materialized JPG
    beside it carried none.
  - **The cheapest route to `NotDownloaded` is a file that has never been on this Mac, not an eviction
    of one that has.** Two milestones were spent trying to *evict* — OneDrive's account was pinned so
    the state could not exist, Dropbox needed a human's right-click in Finder, and both hit the same
    `evictItem` refusal (`NSFileProviderErrorDomain -2001`) with no `fileproviderctl` verb to stand in.
    Box offers no way out of the downloaded state either (`fileproviderctl evaluate` shows
    `MarkForOffline` and **no** unpin for a file that was never pinned), and it did not matter: Box
    streams by default, so a file uploaded from the **web** and never opened here arrives as a
    placeholder on its own. Ask whoever owns the account to upload one; it takes a minute and needs no
    gesture on this Mac at all.
    - Measured on a 13.8 MB one: `st_flags` **`0x40000060`** (`SF_DATALESS|UF_COMPRESSED|UF_TRACKED` —
      the same word iCloud and Dropbox give, which is why the test is a mask and never an equality),
      `st_blocks` 0, the real size under its real name, no stub. `CloudSyncStorage` answers
      `notDownloaded` with `isDownloading == false`, `FileEntry.isDataless` agrees off the listing's
      own `stat`, and the pane draws the download badge beside a row still reporting 14,5 MB. The
      narrowness control rides in the same listing: the materialized JPG next to it reads
      `0x00000040` and `isDataless == false`.
    - **The control worth keeping is that nothing materialized it**: 40 resource-value reads, a real
      `listDirectory`, and then the running app having listed, scanned and badged the row, it is
      *still* `0x40000060` with `st_blocks` 0. That is the whole point of the `SF_DATALESS` guard —
      one byte read would have downloaded 13.8 MB — and it is the half a badge screenshot cannot show.
    - The file's name was Cyrillic, so the non-ASCII path travelled the listing, the resource-value
      read and the badge unchanged. Incidental, and free.

### shasum, md5sum and the checksum-file formats

macOS 26 ships more producers than expected — `/sbin/md5sum`, `/sbin/sha1sum` and `/sbin/sha256sum`
(hardlinks of one Darwin binary) alongside BSD `md5`, the Perl `shasum`, `openssl` and
`/usr/bin/crc32` — and **they do not agree with each other**, which is what makes a tolerant parser
the actual feature rather than gold-plating. `shasum -c` refuses the `openssl` and BSD forms
outright ("no properly formatted SHA checksum lines found"), so a user with an `openssl dgst` output
next to a download has no stock way to check it.

- **The two Apple-shipped *checkers* disagree about escaping, and the disagreement is silent.**
  For a name containing a backslash, `shasum` writes `\<hex>␣␣back\\slash.txt` — a leading `\` marks
  the line and the name is escaped, the GNU coreutils convention — while `/sbin/sha256sum` (Darwin
  1.0) writes `<hex>␣␣back\slash.txt` raw. Measured on both checkers: **the raw form is read
  correctly by both**, while the escaped form makes `/sbin/sha256sum -c` and `/sbin/md5sum -c` print
  "WARNING: 1 line is improperly formatted", **exit 0 anyway**, and check one file fewer. So a
  writer must escape *only* a name containing a newline, which has no raw form any parser can split;
  escaping a backslash costs compatibility and buys nothing. The reader has to accept both, and the
  leading marker is the only thing that says which it is looking at. This flipped a decision that
  was already written and tested — the design read as obviously right until both checkers were
  actually run against it.
- **`crc32` prints a bare digest with no name at all**, so a `.crc`/`.sfv` companion's subject can
  only come from the manifest's own file name (`disk.iso.crc` → `disk.iso`). A parser for that form
  needs the name passed in; there is nothing in the file to recover it from.
- `-Q`-style ambiguity in the *other* direction: a `.sfv` line is `<name>␣<hex>` and a `md5 -r` line
  is `<hex>␣<name>`, so a line whose name happens to be all hex (`deadbeef 4dbf2cc1`) parses either
  way. Prefer the leading-digest reading — that is what every GNU-family tool emits — and say so.
- **Cross-check a digest against the system tool, never against your own implementation.** Every
  expected value in `ChecksumEngineTests` came from `/usr/bin/crc32`, `md5 -q` and `shasum` over the
  same bytes; a fixture the engine computed would only prove it agrees with itself. The published
  CRC-32 check vector (`"123456789"` → `0xCBF43926`) is worth its own test for the same reason: it
  pins the polynomial, the reflection, the initial value and the final XOR all at once, and nothing
  else will tell you which one is wrong.
- **The speed intuition is inverted on Apple Silicon.** Measured over 256 MiB through the real
  engine: SHA-256 2245 MiB/s and SHA-1 2287 (ARMv8 crypto instructions) against MD5 778 and CRC32
  550 (ordinary code) — **CRC32 is the slowest of the four, not the cheapest.** All four in one pass
  is 274 MiB/s, which is what makes "compute everything while the bytes are in hand" affordable.
  Chunk size is irrelevant between 64 KiB and 4 MiB.

### Encryption: encrypted archives (libarchive) and vaults (`hdiutil`)

M19's two halves. Everything here was probed before any Swift was written, and the first probe
overturned the decision the milestone opened on.

- **`bsdtar` cannot be given a passphrase safely, and that is what broke §2's "bsdtar over
  libarchive".** Measured by capturing the live process's argv by PID: `--passphrase` sits in
  `argv` in plain text (`bsdtar -c -f … --passphrase SUPERSECRET123 …`), readable by any `ps` —
  the exact practice this file already forbids for `curl -u`. Unlike `curl` there is **no escape
  hatch**: `--passphrase` is undocumented in `--help`, and the only alternative is the interactive
  prompt, which on a non-tty stdin **loops `Enter passphrase:` forever** rather than failing (the
  first probe produced 166 KB of prompts before it was killed). A `-K -`-style config on stdin does
  not exist.
  - **The system libarchive is linkable and takes the passphrase in memory.**
    `/usr/lib/libarchive.2.dylib` (3.7.4) ships with macOS and the SDK carries `libarchive.2.tbd`
    with all 427 symbols, so this is a *system* library, not a dependency — `archive_write_set_
    passphrase`, `archive_read_add_passphrase` and both callback variants are all exported. No
    `archive.h` in the SDK, so declare what you use by hand; Swift 6 mode imports it through a module
    map with `link "archive"` and it builds clean. Confine the exception to the encrypted path:
    browsing and ordinary packing have no reason to leave `bsdtar`.
  - Three things came free and are the reason to reach for it again: byte-accurate progress, real
    cancellation between chunks, and errors as return codes instead of scraped English.
- **An AES-256 zip is unopenable by everything Apple ships.** `unzip` says `skipping: … unsupported
  compression method 99`, `ditto` says `Unknown compression type`, and Archive Utility is the same
  code — so a Mac recipient needs Keka or The Unarchiver, and a Windows recipient needs 7-Zip or
  WinRAR (Explorer's built-in zip cannot either). The format is right — verified from the bytes:
  local-header method **99**, extra field `0x9901` carrying AE version **2**, vendor `AE`, strength
  **3** = AES-256, inner method 8 — it is the *platform* support that is missing. Say so in the UI
  rather than letting the recipient discover it. The only interoperable-everywhere option is
  `zipcrypt`, which has a published known-plaintext break, so it must never be offered under a
  checkbox saying "Encrypt".
- **No zip encrypts file names**, ever — the central directory is plaintext by design. `bsdtar -tvf`
  on an AES-256 archive, with no passphrase, prints every name, size and mtime. The only fix is to
  wrap the payload in one inner archive and encrypt *that* single entry. Make the inner container a
  **tar**, not a second zip: tar stores bytes verbatim so the outer zip's deflate is the only
  compression pass (nesting zip in zip compresses everything twice and produces a *larger* file), and
  tar carries permissions and symlinks losslessly. Give the wrapper a fixed mode and the current time
  — a real file's mode or mtime would leak a fact about the contents into the part that stays
  readable.
- **Skipping an archive entry is a *seek*, so extracting one member of a large encrypted archive is
  free for the members nobody asked for — and the saving belongs to not reading the data, not to the
  skip call.** M19 shipped without a member filter: `EncryptedArchiveReader.extract` placed every
  entry however little was requested, so previewing one file inside a 600 MB AES-256 archive
  decrypted all 600 MB. Measured 2026-08-25 against exactly that archive (seven entries, a 6-byte
  one fourth): reading every entry's data is **1.48 s** and reaching the small one past three 100 MB
  ones is **0.001 s**, byte-identical output. Re-measured through Dirnex's own reader afterwards:
  1.53 s → 0.001 s, and 0.256 s for a 100 MB member, i.e. the cost is now what was asked for.
  - **`archive_read_next_header` already skips whatever is left of the previous entry**, at an
    identical 0.001 s over three rounds — so `archive_read_data_skip` buys nothing measurable and is
    called only so the loop's `continue` says out loud that it is leaving an entry alone. Worth
    knowing before anyone attributes the speed to the call and defends it as load-bearing.
  - **A skipped entry is never decrypted, so a skip cannot notice a wrong passphrase** — probed, it
    answers `ARCHIVE_OK` in silence for every entry, and only the member whose data is actually read
    reports `Incorrect passphrase`. That is right rather than lax (copying a symlink or an empty
    folder out of an encrypted archive genuinely needs no passphrase) and it is the reason nothing
    may claim a *filtered* extraction validated one.
  - **It holds for a stream, too, which is what makes the filter safe on any format.** The same
    member came back byte-identical from a seekable zip, a zip **written** to a pipe (data
    descriptors — read from a file it still uses the seekable reader, so 0.001 s), and a `.tar.gz`,
    where the gzip filter has to be read through and a 100 MB skip costs 0.032 s.
  - **The filter's matching rule is `bsdtar`'s, because the two routes serve the same gestures and a
    user cannot see which one ran**: a directory member takes its subtree (or F5 on a folder inside
    an archive copies out an empty folder and reports success), matched on whole path components so
    `docs` never takes `docs2`. Glob metacharacters are *not* escaped here, unlike
    `ArchiveExtraction.member(forInnerPath:)` — that one builds a shell pattern for `bsdtar` and this
    one compares strings, so the two spellings sit a few lines apart and disagree on purpose.
  - **A filter must reach *inside* a hidden-names wrapper, and applied outside it fails as a claim
    about the wrong thing.** Such an archive holds one entry, `Contents.tar`, with the requested
    member inside it — so a filter matched against the outer places nothing, and the caller reports
    "Couldn't read the archive". Recognize the wrap from the headers `inspect` has already read, take
    the wrapper unconditionally, and hand the filter down to the inner extraction.
  - **The cache that existed to amortize the old cost is dead the day the cost goes, and it is not in
    the diff.** `ArchivePreviewCache` kept a second dictionary holding where each archive's
    whole-archive extraction landed, so arrowing onto a sibling was free; `ArchiveExtractor.Extraction
    .isWholeArchive` existed only to feed it. Both went with the filter, along with the test that
    pinned *shared temp directories* as the observable — which had to be inverted rather than
    deleted, since the property the user cares about (arrowing through a large encrypted archive must
    not re-decrypt it per keystroke) is unchanged and is now bought by not decrypting at all.

- **A zip probe that reads "the first entry" reads the *directory*.** Packing a folder puts its own
  entry first, and a directory has no data, so it is stored with method 0 and carries no AES field
  however the archive was encrypted — a probe written that way reports method 0 for a perfectly good
  AES-256 archive. Look entries up by name. Same run: scan the extra-field area as (id, size,
  payload) triples rather than searching for the `0x9901` marker bytes, which occur inside compressed
  data often enough to fool a global scan.
- **An archive is untrusted input, and `bsdtar` will happily build the attack for you.** `bsdtar -s
  '|payload.txt|../../escaped.txt|'` stores a literal `../../escaped.txt` member (it strips a leading
  `/` but not `../`), which is Zip Slip in one stock command. The second shape is the one that
  survives a naive fix — an archive holding `escape -> /tmp` *and* `escape/pwned.txt`, where every
  **name** is innocent and it is the symlink created one entry earlier that puts the write outside.
  So a name check is necessary and not sufficient: hold link *targets* to the same rule (judged by
  where they end up, since `../sibling` is an ordinary symlink), and `lstat` every directory
  component on the way down, refusing to descend through a link — the path-shaped equivalent of
  `openat(O_NOFOLLOW)`. Both layers earn their keep: with the name rule deliberately neutered as a
  negative control, the `lstat` walk still blocked the write.
- **`hdiutil -stdinpass` keeps the passphrase out of argv entirely** — confirmed by scanning the
  whole process tree mid-run (`hdiutil`, `diskimages-helper`, `copy-helper`, `diskimagesiod`) for a
  known passphrase and finding it in none of them. That is what makes an encrypted disk image the
  right shape for a vault. `-puppetstrings` turns the drawn meter into machine-readable
  `PERCENT:25.897619` lines, so a real progress bar is available; **`-1.000000` is a sentinel, not a
  percentage**, and it brackets the run at *both* ends — read literally it drives the bar to −1 % at
  the start and back to −1 % at the moment of success. Values also repeat, so anything driven from
  them must tolerate a value that does not advance.
  - `attach -plist` reports **several** `system-entities` and only one carries a `mount-point` —
    "the first entity" is the GUID partition scheme, which reads as "attach didn't work". Detaching
    an **already-detached** image exits **1** with "No such file or directory": treat that as
    success, or a second Lock (or a Lock after ejecting in Finder) looks broken. A wrong passphrase
    and a missing image *both* exit 1, so the "Authentication error" phrase is the only separator —
    same shape as libarchive's "Incorrect passphrase", and worth a test driving the real failure so
    a reworded message fails loudly instead of degrading every wrong passphrase into "damaged".
  - A growable encrypted `SPARSEBUNDLE` costs **23 MB** for a declared 10 GB APFS volume, so a vault
    need not ask the user to predict how much they will ever store. It is a *directory*, though, so
    it is awkward to send — which is fine, that is the archive half's job.
  - **`-stdinpass` reads that pipe verbatim to EOF, so a trailing newline is part of the
    passphrase.** Measured both ways on macOS 26: an image created with `printf 'p\n'` refuses to
    attach with `printf 'p'` (`hdiutil: attach failed - Authentication error`) and vice versa; with
    the newline on both sides, or neither, it attaches. Writing a *line* to a subprocess is the
    natural thing to do — and doing it here mints vaults whose real passphrase is not the phrase
    their owner typed, so Disk Utility, Finder and Dirnex on any other Mac are locked out of them
    permanently, with no recovery and nothing on screen ever hinting why. The bytes and then a
    close, and nothing else: `ArchivePassphrase.withUnsafeBytes` exists to be the one spelling of
    that, sitting next to a `withUnsafeCString` that differs from it by exactly the byte that would
    break this. Both spellings look right at the call site, which is the whole problem.
  - **A sparse bundle's creation is constant-time in its declared ceiling, and reports no progress at
    all.** Measured: 100 GB, 500 GB and 2 TB each took **1.02 s** and each cost **34 MB** on disk,
    with `-puppetstrings` emitting **zero** `PERCENT:` lines in all three (a *fixed* `UDIF` image
    reports properly — 2 GB in 4.0 s over six lines). So the progress machinery above is real and is
    for the kind nobody should pick, and the growable vault needs no bar, no cancel and no deferred
    sheet — a measurement that deleted a whole piece of planned UI rather than confirming it. It is
    also why the size field can offer a generous default: a bigger ceiling costs nothing, in bytes or
    in seconds.
- **A vault is a *place* the app knows about through the sidebar and an ordinary *file* on disk, and
  every gesture that reaches it by path knows nothing.** A `.sparsebundle` is a directory, so the
  pane's generic "enter the directory under the cursor" branch swallowed it whole: an unlocked vault
  — open padlock in the sidebar, eject button beside it — read as **locked** from the pane, showing
  `bands/`, `Info.plist`, `lock` and `token`, with the files on a mounted volume the user was never
  taken to. Reported by a user 2026-08-10, and it had been true since vaults shipped. Nothing catches
  it: the sidebar is correct, the mount is real, `hdiutil info` agrees, no test is wrong, and the
  screenshot is of a perfectly ordinary directory listing. The tell to grep for is a **feature whose
  entire surface is one control** (a sidebar row, a menu item) over a thing that is *also* a path —
  the pane can always reach the path, and the knowledge lives somewhere the pane cannot see.
  - The fix belongs **ahead of** the generic branch, not inside it, and the funnel it calls has to be
    the same one the control uses — otherwise the two spellings drift, which is this file's most
    repeated finding. Here that meant lifting the suffix test both callers had written out
    (`DiskImageArguments.Kind.isImageName`) rather than adding a second copy at the new site.
  - **The narrowness is the design decision, and it is not the same one the deliberate command
    makes.** The Unlock command takes *any* `.dmg` or `.sparsebundle` because the user named it;
    Enter is pressed on everything, so widening it identically would attach a stranger's disk image,
    prompt for a passphrase and file it in the sidebar's Vaults section — three things nobody asked
    for, from a key that means "show me what is in there". Same fork as Quick View's "is this safe"
    vs. "should this happen unasked": a gesture the cursor makes and a gesture the user makes are
    allowed different answers.
  - Test the decision with the store **handed in**. The obvious app test seeds `Dirnex.vaults` in
    `UserDefaults.standard` — which, in a target that runs *inside the app*, is the sidebar the
    person running the tests is looking at.
- **Renaming a vault is `diskutil`'s job, not `hdiutil`'s, and the volume — not a row label — is the
  only name a vault has.** `VaultLocation.volumeName` is re-derived from the mount point on every
  unlock, so a Favorites-style nickname would be silently reverted the next time the vault opened,
  and until then the sidebar would disagree with the pane's own path bar. `diskutil rename
  <mountPoint> <name>` does it for real, **unprivileged**, on a mounted encrypted sparsebundle: the
  mount point moves synchronously (`/Volumes/Personal` → `/Volumes/Work`), it works with a process
  standing inside the volume, and the new name survives a detach-and-reattach because it lives in the
  encrypted filesystem. Nothing readable does — a locked bundle's `Info.plist` carries no volume name
  at all, which is why the name has to be stored in the first place. The price is that the vault must
  be unlocked, so Rename goes through the unlock funnel rather than graying itself out.
  - **The volume does not land where you asked.** A name already in use still succeeds and remounts
    at **`/Volumes/<name> 1`**, and a `/` in a name is legal and reaches the path as `:` (`a/b` →
    `/Volumes/a:b`). So *re-read* the mount point from `hdiutil info` afterwards and derive the
    sidebar's label from that — building `/Volumes/` + what the user typed names a directory that
    may not exist, and would send a pane following the rename to nowhere.
  - **The name limit is 255 UTF-8 *bytes*, not characters**, and this is the localization trap in its
    purest form: 255 ASCII characters are accepted and 256 refused, while **127** Cyrillic characters
    (254 bytes) are accepted and **128** (256 bytes) refused. A character count passes every English
    test and rejects nothing a Russian user would notice — until the file system does. For the same
    reason the refusal sentence must not name the number: "255 characters" is a lie in half the
    shipped languages.
  - `diskutil` refuses empty, `.` and `..` itself (exit 1, "does not appear to be a valid volume
    name for its file system") and **accepts** a name containing a newline or a tab — so control
    characters are the one rule that has to be ours, and they are the one nothing else will catch.
    A leading `-` is taken as the name, not a flag (probed: a volume really was called `-force`), so
    with an argv rather than a shell there is nothing to escape.
- **A vault is addressed by its image's *path*, in two stores, so moving that file in a pane breaks
  it — and the one funnel that already knows is the undo journal.** A saved vault's row and its
  Keychain account are both keyed on the image path, so an ordinary F2 on the `.sparsebundle` left
  the row pointing at nothing and the passphrase filed under a path nothing would ever ask about
  again. It fails in the quiet direction: the row looks perfectly normal until it is clicked, and
  then says the image "may have been moved or damaged" — true, and unhelpful, since the app is what
  moved it. `UndoRecord` is where every rename, move, multi-rename and sync already reports, so one
  hook covers gestures that share nothing else.
  - **Read *both* ends of each step and let the disk decide, rather than tracking direction.** An
    `UndoStep.restore(from:to:)` names both paths, so pairing a vault with the *other* end in both
    directions makes undo and redo need no inverse of their own — and a half-applied revert still
    lands each vault on wherever its own image actually ended up. Judge by `fileExists`, not by what
    the operation was nominally doing.
  - **`moveToTrash` journals the identical step and must *not* be followed.** Following it re-points
    the row into `~/.Trash`, where the vault still unlocks — not what throwing something away means
    — and leaving the path alone is also what makes Put Back repair the row by itself. So it is a
    decision, not something the shape rules out; a copy is excluded for free, since it journals
    `removeCopy` rather than `restore`.
  - **The trap underneath: `hdiutil info` reports an image by the path it had when it was attached,
    forever.** Probed — renaming a *mounted* `.sparsebundle` succeeds, the volume stays mounted, and
    the info plist goes on naming the old path until detach, with **no other identifier to match on**
    (no inode, no device id for the image file). So the moment the saved list follows the move, every
    "is this vault unlocked?" question — all six of them, asked by path — starts answering *no* for a
    vault the user can see mounted: shut padlock, no eject, Lock unreachable. Correct it once, on the
    way out of the function that produces that answer, and every caller is fixed with no API changed.
    Honor the alias **only while the reported path is missing from disk**, which is precisely the
    state a rename-while-attached creates: it needs no expiry, and it stops applying by itself the
    moment something occupies that path again.
  - Measured before designing any of it, and it is what kept the fix small: attaching the *same*
    image under its new name exits **0**, mounts nothing extra, and hands back the existing mount
    point. So the failure this guards against is cosmetic rather than dangerous — worth knowing
    before spending effort proportionate to a corruption risk that isn't there.
- **`resolvingSymlinksInPath` and `standardizingPath` fold `/private` only for paths that currently
  exist.** Probed on macOS 26: `/private/tmp/x` → `/tmp/x` when `x` is there, and stays
  `/private/tmp/x` when it is not. So neither is a normalizer — both are filesystem *queries* wearing
  one's clothes, and a stable identity built on either changes the moment the file moves or is
  deleted, which is exactly when you still need to find its Keychain entry in order to clean it up.
  `hdiutil` answers with the `/private` spelling while the user says `/tmp`, so the comparison is
  unavoidable; fold the three firmlink prefixes in string space instead. Generalizes past vaults: any
  path used as a persistent key needs an existence-independent normalizer.
- **`-nobrowse` can be withdrawn from a *mounted* volume, unprivileged — but a remount keeps only the
  options it is handed.** `mount -u -o browse <point>` puts an unlocked vault into Finder's Locations
  immediately, and `nobrowse` puts it back, with no unmount and no passphrase; that is what makes
  "show this one vault in Finder" a per-vault setting rather than something that only applies at the
  next unlock. The trap is the second half, and it is silent: a bare `-o browse` took the volume's
  flags from `0x04B09218` to `0x04809218` — clearing **`MNT_IGNORE_OWNERSHIP`** along with
  `MNT_DONTBROWSE`, so a vault that ignored ownership quietly started enforcing it, with every file in
  it owned by a uid from whichever Mac wrote it. `MNT_NOSUID` and `MNT_NODEV` happened to survive,
  which is exactly the kind of "it seems fine" that makes this ship. Re-state the whole current flags
  word (read it with `statfs`, not by parsing `mount`) and change only the browse bit.
  - **A read-only volume refuses the remount entirely and fails clean**: `mount_apfs: volume could not
    be mounted: Permission denied`, exit 66, flags byte-identical afterwards. So it needs no error
    vocabulary of its own — the setting is stored either way and the next attach honors it, which is
    the honest sentence for any refusal here.
  - **The measurement that mattered was of the *wrong* reading first.** `mount`'s own output line was
    read by eye and reported as dropping `nodev,nosuid`; the `statfs` probe showed those surviving and
    `noowners` going instead. Same family as this file's "don't derive geometry from a screenshot" —
    a flags word is a number, so read the number.
- **Making a vault browsable puts it in `mountedVolumeURLs` too, so the sidebar lists it twice.**
  `Places.volumes()` enumerates with `.skipHiddenVolumes`, and `-nobrowse` is what made a vault
  invisible to it — so "a vault never appears under Volumes" was true *by construction* for the whole
  life of the feature, and `SidebarViewController`'s own comment said so. The moment one vault can be
  shown, that becomes a rule somebody has to keep: verified live, `/Volumes/SecDocs` came back from
  `mountedVolumeURLs` the instant the setting went on. The duplicate is worse than untidy — the
  Volumes row carries a plain eject button that detaches the image with none of Lock's bookkeeping
  (evicting the panes standing inside it, and dropping what `VaultPrivacy` must forget). Two general
  shapes worth carrying: **an invariant held by a flag becomes a bug the day the flag becomes a
  setting**, and the tell is a comment explaining why two things *cannot* collide; and the fix has to
  resolve the vault mount points **before** the section that filters on them, which is an ordering no
  test of the filter can see.
- **A new field on a persisted `Codable` value is a migration, and Swift's synthesized decoder throws
  on a missing key whatever default the property declares.** `SavedVaults` is loaded through a
  `try?`, so adding `showsInFinder` without a hand-written `init(from:)` would have decoded every
  existing user's vault list to **nothing** — the sidebar's Vaults section empty on first launch after
  the update, every vault's Keychain item orphaned, nothing logged, and it reads as a feature that was
  removed. `decodeIfPresent` is the whole fix; the property's `= false` initializer does *not* do it,
  which is the part that looks like it should. Worth a test with real legacy JSON in it, and worth
  running the negative control — neutering the decoder failed it with `keyNotFound`, which is the
  proof the test is about this and not about nothing.
  - The same edit has a quieter twin one layer up: a store's `add` that **replaces** an entry will
    reset any field a caller didn't know to carry. Two of the unlock entry points *construct* a
    `VaultLocation` from the file under the cursor, so unlocking from the pane rather than the sidebar
    would have silently cleared the setting. Resolve against the store once, in the funnel every
    caller already goes through, rather than teaching `add` to merge — a merge would make the setting
    impossible to turn back *off*.
- **What remembers an unlocked vault's file names is *this app*, not the OS caches everyone worries
  about.** PLAN.md §6 named three leaks to warn users about — Spotlight's index, Quick View's caches,
  the thumbnail store — and measuring all three found nothing, while the thing nobody had named was
  writing the file names to `UserDefaults` in the clear.
  - **Spotlight does not index a disk-image volume at all.** `mdutil -s` on a mounted encrypted
    sparsebundle reports `Indexing disabled`, no `.Spotlight-V100` is created, and `mdfind -onlyin`
    over it returns nothing. Two controls in the same run are what make that worth trusting: the boot
    volume reports `Indexing enabled`, and an **unencrypted** sparsebundle is *also* disabled — so it
    is a property of disk images rather than something encryption is buying. The corollary is that
    Recents, which is an `mdfind` query, can never show a vault's contents and needs no rule.
  - **A thumbnail request cached nothing.** A real `QLThumbnailGenerator` call against a file on the
    volume produced a 512×512 thumbnail, after which no file anywhere under
    `getconf DARWIN_USER_CACHE_DIR` named it and the thumbnail agent's own store held no files.
    Nothing survived the detach.
  - **The real leak was ours, and it was two stores deep.** `FrecencyStore.recordVisit` records every
    `.local` directory — a mounted vault is local — and `PersistedTab` carries the directory, the
    cursor's file name, the marked names and the expanded folders. Both outlive the lock. Hence
    `VaultPrivacy` in the core and `VaultMounts` in the app: **implicit** memory refuses a vault path,
    while a store the user filled *explicitly* (a named workspace, a favorite) keeps working, because
    silently dropping half of something someone asked for by name is the worse surprise.
  - The lesson that generalizes past vaults: **when the question is "what still remembers this", audit
    your own preferences before the system's caches.** The OS caches are the famous answer, they are
    the ones a risk register writes down, and here all three were clean — while the app's own two
    were not, precisely because nobody thinks of a fuzzy-jump index as storage.
- **Verifying "the app did not write that down" is headless, and needs a control token in the same
  run.** `defaults export com.dirnex.Dirnex` plus a script that decodes each JSON blob answers "does
  any key mention this string" exactly; the AppleScript `reveal` verb drives a pane to a path with no
  screenshot and no accessibility grant. The half that makes it evidence rather than absence: browse a
  **control** folder carrying its own token in the same session, and require that one to *appear* —
  it goes through the identical `recordVisit` / `persistState` code, so a probe that cannot see it is
  blind rather than reassuring. To reach the app's own unlock path (not just an image mounted from a
  shell), pre-file the passphrase with `security add-generic-password -A -s com.dirnex.Dirnex.vault
  -a <resolved image path>`: `-A` is what stops the Keychain prompting an app that did not create the
  item, and `go.unlockVault` then attaches silently through `run operation`. Back the domain up with
  `defaults export` first and `defaults import` it afterwards — the probe overwrites the real
  session's tabs.

### ACLs and file attributes (`acl_*`, `chmod`/`chflags`, `mbr_*`)

The M14 attributes work rests on syscalls and the ACL C API, probed live before any Swift was
written. Several results changed the model, not just confirmed it.

- **`acl_to_text` wraps its output at ~column 60 with a trailing `\`** — a single logical entry can
  span several physical lines (`...:deny\` ⏎ `:delete`). So the parser's *first* step is to un-wrap
  (drop every backslash-before-newline); only then is each remaining non-header line one entry. A
  line-oriented parser that skips this reads garbage. `acl_from_text` **accepts** the un-wrapped
  single-line form, so Dirnex writes one line per entry and never re-wraps.
- **`acl_to_text` and `ls -le` disagree on the token names, and this reshaped the model.** Four ACL
  rights are aliased bits the kernel prints with their *file* names even on a directory —
  `list`≡`read`, `add_file`≡`write`, `search`≡`execute`, `add_subdirectory`≡`append`. `ls -le`
  shows the directory spellings; `acl_to_text` (what the parser consumes) **only ever** emits
  `read/write/execute/append`. Only `delete_child` is a genuinely directory-only token in canonical
  text. So model the **13 bits** `acl_to_text` produces, not `chmod(1)`'s 17 input tokens, or a
  directory ACL carries the same bit twice under two names. The UI count still holds: a file offers
  12, a directory 13 rights + 4 inheritance flags = 17 checkboxes, with the four data bits
  *relabeled* per kind at the display layer.
- **The canonical entry form `acl_from_text` accepts needs GUID + name + numeric id, all three.**
  Probed: `user:GUID:oleg:501:allow:read` round-trips, but `user:GUID::allow:read` (empty name) and
  `user:GUID:allow:read` (no id) are both `EINVAL`. So the serializer must carry the resolved name
  and id, not just the GUID.
  - **What that needs is the *field*, not the value — and reading, the OS writes two shapes a strict
    six-field parse rejects.** Both were found by probing the write path (2026-07-31) and both had
    the same shipped consequence: `AccessControlList.parse` threw, `AttributesSnapshot` degrades a
    failed ACL read to an empty list, and the Sharing tab reported **"No access control list"** for a
    file that has one. A wrong answer in the quiet direction, on the tab whose whole job is that
    answer.
    - **A rights-less entry has five fields.** `acl_to_text` *omits* the trailing rights field rather
      than writing it empty (`group:GUID:staff:20:allow`), and `ls -le` shows `0: group:staff allow`.
      Such an entry is legal, storable and does nothing — it occupies a position in the evaluation
      order while allowing and denying nothing — so an editor should refuse to *create* one while
      still displaying one it finds.
    - **A subject whose GUID answers to no account comes back with an empty name *and* an empty id**
      (`user:GUID:::allow:read`), which `ls -le` shows as the bare GUID. Ordinary for a file copied
      from another Mac or an account since deleted, so the numeric id has to be modeled as optional.
    - Both shapes are **accepted back** by `acl_from_text`, so they round-trip losslessly and an edit
      to a neighboring entry leaves them untouched — which is the case that actually reaches a user,
      since the editor writes the whole list back.
    - **The GUID is the identity and the name/id are its resolution, which the kernel re-derives.**
      Hand `acl_from_text` a GUID with a name and id it does not believe (`…:ghost:31337:allow:read`)
      and it is accepted, stored, and read back as `…:::allow:read`. So a name written into an entry
      is never authoritative, and "repairing" an unresolved subject by inventing one would name the
      wrong account.
- **`acl_set_file` preserves entry order exactly** — write deny-then-allow, read back with both
  `acl_get_file` and `ls -le`, and the order survives. Order is meaning (a deny before an allow is a
  different ACL), so the model is an ordered list that is never silently canonicalized. The kernel
  *does* re-canonicalize the rights *within* an entry, so serialize rights in any fixed order.
- **`acl_get_file` returns `nil` + `ENOENT` to mean "this file has no ACL"** — a normal answer,
  mapped to an empty list, not an error. Writing an empty list (`acl_init(0)` → `acl_set_file`)
  removes the ACL — the "deleted the last entry" case.
- **The ACL C API imports from Swift with no module map** (`acl_get_file/_link_np`, `acl_to_text`,
  `acl_from_text`, `acl_set_file/_link_np`, `acl_init`, `acl_free`) — the opposite of libarchive.
  But **`mbr_uid_to_uuid` / `mbr_gid_to_uuid` do not** (they live in `membership.h`, outside the
  Darwin module map). Resolve them through `dlsym(RTLD_DEFAULT, …)` — the pseudo-handle is
  `UnsafeMutableRawPointer(bitPattern: -2)`, and it cannot be a stored `static let` under strict
  concurrency (`UnsafeMutableRawPointer?` is not `Sendable`); recompute it per call. The GUID they
  return is byte-identical to the one `acl_to_text` prints for the same id — pin that against the OS's
  own answer, not against your own formatter.
- **`acl_set_file` is `EPERM` on a `UF_IMMUTABLE` file too, exactly like `chmod`** — and so is
  clearing the ACL (`chmod: Failed to set ACL on file: Operation not permitted`, exit 1). So an ACL
  change is a *step inside* the existing unlock → apply → relock window, not a second write beside
  it; two separate writes would either surface that EPERM or unlock the file twice. The two halves
  are otherwise **independent**, which is worth knowing because it is what makes the sequencing the
  *only* thing needed: measured, `chmod`, `chgrp` and `utimes` each leave an ACL intact **and in
  order**, and `acl_set` leaves the mode and the times untouched — so unlike the `chown`/set-uid and
  mtime/birthtime side effects below, this needs no repair step.
- **`chmod` fails with `EPERM` while `UF_IMMUTABLE` is set, and that EPERM is indistinguishable from
  the one that needs root.** So a change to anything but the flags on a locked file must clear the
  immutable bit, apply, then restore it — proven live, unprivileged, in one gesture. Encode the
  ordering as a pure, tested plan (`AttributeChangePlan`): the bug is invisible in any dialog
  screenshot, so only a test that pins the *step order* catches a regression.
- **`chown(2)` clears the set-uid/set-gid bits for an unprivileged caller**, so a plan that changes
  both owner and mode must `chown` **before** `chmod`, or the set-uid the user just asked for is
  silently dropped.
  - **And a plain `chgrp` is a `chown`, so a *group-only* edit drops the bits with no `chmod` in the
    plan to be ordered.** Measured: `0o6755` handed from `staff` to `admin` came back `0o755`. The
    ordering rule above reads as if it covered this and does not — it only fires when the user is also
    changing the mode. Both bits go; the fix is to re-write the *current* mode after the chown
    whenever the file carries either. This is the general shape worth carrying: **a syscall that
    rewrites a neighboring field breaks the diff-based contract** ("a field left alone is never
    written"), so the plan owes a repair step, not just an ordering.
- **Setting `st_mtime` earlier than `st_birthtime` drags the birth time back to match** — the same
  family, found in the same probe. A file born today, given an mtime of 2001, reports a *creation*
  date of 2001 afterwards; files and directories alike on APFS. Three details make it tractable: it
  is **mtime alone** (an atime in the same past leaves the birth time untouched), re-setting the
  birth time afterwards **repairs it exactly**, and `setattrlist(ATTR_CMN_CRTIME)` was measured *not*
  to disturb either of the other two times — so a plan that already sequences `utimes` before the
  crtime write can repair without undoing the edit that provoked it. Without the repair, "change
  Modified" quietly changes "Created" too, and the panel that re-reads afterwards shows a date the
  user never typed.
  - Both repairs need a **negative control** in the test suite — one test asserting the OS really
    does the damage with no plan involved. Otherwise a macOS that stopped doing it would leave the
    repair vestigial with every other test still green.
- **An undo can need privileges the change it reverses did not, and the asymmetry is invisible until
  someone undoes.** A file's group is inherited from its parent, so an item can sit in a group its
  owner is not in (`/private/tmp` children are `wheel`). Moving it *out* is legal — `chgrp` to a
  group you belong to — and moving it *back* is `EPERM`, so a perfectly ordinary edit is a one-way
  door. Shipped, that surfaced as the generic errno sentence: **"You don't have permission. Dirnex
  may need Full Disk Access in System Settings."** — true of the errno, wrong about the cause, and
  pointing the user at a settings pane that cannot help. Check `AttributePrivilege` at the *start* of
  the undo and name the reason (`VFSUnsupportedReason.attributeRestoreNeedsAdministrator`), which
  also means refusing before touching the file rather than half-applying. Same "an EPERM that needs
  root is indistinguishable from one that does not" trap as the immutable-flag case, arriving from
  the other direction — and only a live undo of a real edit exposes it.
- **The BSD flags word splits at the 16-bit line**: the low 16 bits are owner-settable (`UF_*`), the
  high 16 (`0xFFFF0000`) are super-user only (`SF_*`). Read "does this flag change need root?" off
  that mask, not a per-flag table, and a flag macOS adds later lands on the right side for free.
- **`setattrlist(ATTR_CMN_CRTIME)` sets the birth time `utimes` cannot** (pass `FSOPT_NOFOLLOW` for a
  symlink); the `setattrlist` `options` argument is `UInt32` on this SDK, and `timeval`'s field is
  `tv_usec`, not `tv_suseconds`. The `l*` variants (`lchmod`, `lchown`, `lchflags`, `lutimes`) all
  import and act on the link itself, matching Finder's Get Info.
- **`FileManager.removeItem` fails on a `UF_IMMUTABLE` file**, so a test that locks one must unlock it
  before teardown or it strands the temp tree.
- **`utimes` and `setattrlist(CRTIME)` are both `EPERM` on a locked file**, like `chmod` and `chown`
  — so date editing needs the same unlock/relock dance, not a separate design. Dates otherwise have
  no range to defend: a 2096 mtime and a pre-epoch 1938 one both applied cleanly, and a `Date`
  round-trips through `utimes` at microsecond fidelity.
- **An `NSDatePicker` resolves to whole seconds and a real timestamp does not**, which is a live bug
  and not a rounding nicety: read `dateValue` back unconditionally and the sub-second remainder every
  `st_mtime` carries makes all three fields differ from what was read *the moment the sheet opens* —
  Save lights up with nothing edited, and committing writes three dates nobody touched. Compare
  against the value the control was **given** (`picker.dateValue` right after assigning it), not
  against the model, so "untouched" means untouched at the control's own granularity.
- **A recursive attribute change must be applied *deepest-first*, and having gathered the paths up
  front does not save it.** Clearing a directory's `x` bit stops every path under it from resolving,
  so a pre-order run gets `EPERM` on every child — measured directly, with the child list already in
  hand: applying `0644` to the parent and then to each child gave "Permission denied" on all of them.
  The failure is in path resolution at apply time, not in the walk, which is why "gather everything
  first, then apply" reads like the fix and is not one. `chmod -R 0644` is the live demonstration and
  the *system tool* does it: exit 0, and afterwards `ls` and `find` both fail on a `drw-r--r--` root.
  Gather while the tree is still readable, write from the leaves up, and the run finishes.
  - **A locked parent is not part of this problem, which is worth knowing because it looks like it
    should be.** `uchg` on a directory still allows `chmod`, `chflags`, `utimes` and `chgrp` on
    everything inside; only *creating* there fails. And changing a child's attributes does not bump
    the parent's mtime, so a recursive date change needs no ordering of its own either.
- **Writing a *directory's* ACL onto a plain file succeeds, stores the directory-only bits, and hands
  them straight back.** Probed: `acl_set_file` returns `0` for a file given
  `…:allow,file_inherit,directory_inherit:read,write,execute,append,delete_child`, and `acl_get_file`
  reads that back **verbatim** — while `ls -le` shows only `allow read,write,execute,append`. So the
  bits survive on disk, mean nothing, and are invisible to every tool *except* one that reads the
  canonical text, which is exactly what an ACL editor does. `chmod(1)` strips them on the way in, so
  stripping is what the platform's own front end does; anything propagating a list down a tree has to
  do the same. The second half is the one that is easy to miss: `chmod +a "everyone allow
  delete_child" f` exits 0 and leaves `0: group:everyone allow` — **an entry with no rights**, which
  occupies a position in the evaluation order and decides nothing. Strip the bits, then drop whatever
  is left empty. Pair the rule with a negative control asserting the kernel really does store them,
  or a macOS that started stripping would leave the rule vestigial with every test still green.
- **Journaling is what limits a bulk operation's size, not the work.** Measured over 1k…200k steps: an
  `UndoStep.restoreAttributes` encodes to a dead-constant **246 bytes**, and because the journal is
  JSON in `UserDefaults` that is re-encoded on *every* later operation, a big record taxes everything
  after it — 10k steps is 2.3 MB and 60 ms, 50k is 11.7 MB and 280 ms, 200k is 47 MB and **1.1 s**,
  until it falls off the 50-record stack. The work it describes is nothing by comparison: read + plan
  + apply is **17 µs an item**, and a 5 000-entry listing is 16 ms. So the cap belongs on the journal,
  the count belongs in a confirmation the user sees *before* the run, and over the cap the honest
  answer is to journal **nothing** — reverting an arbitrary slice of a tree leaves it in a state
  nobody can reason about. Any future operation that can span a hundred thousand items inherits this
  arithmetic.
- **A bulk edit is a patch and a single-item edit is a value, and carrying one outward needs both
  halves translated — differently.** A changed **mode** travels whole (it is a shape the user chose,
  not twelve independent bits, so "apply these permissions to everything inside" means that shape),
  while **flags** travel bit by bit (they are independent switches, and a `UF_HIDDEN` on one file
  inside a folder must survive ticking Locked on the folder). Copying the whole flags word is the
  version that compiles, reads fine, and silently strips a bit the user never touched.
- **`mbr_uid_to_uuid` *synthesizes* a GUID for an id with no account behind it, so it can never be an
  existence check.** Probed: uid 31337 — no such user — answers
  `FFFFEEEE-DDDD-CCCC-BBBB-AAAA00007A69`, the well-known prefix with the id in the tail (groups take
  `ABCDEFAB-CDEF-ABCD-EFAB-CDEF` + gid the same way; that is where `everyone`'s
  `…CDEF0000000C` comes from). A real Open Directory record gets a random GUID instead — `oleg`(501)
  does, `root`(0) does not — so *which* form comes back says nothing usable either. A subject picker
  validating its input has to ask `getpwuid`/`getgrgid`, which return `nil` for the ghost. Nothing
  fails loudly here: the ACL would be written with a GUID naming nobody.

### Enumerating users and groups (`getpwent` / `getgrent`)

The subject picker and the owner/group fields both need the machine's accounts by name. Probed live
(2026-07-31) before the picker was designed, and both findings are invisible until measured.

- **The enumerators return every record twice.** Measured on this Mac: **265** `getpwent` records for
  133 distinct accounts, **322** `getgrent` records for **161** groups — Open Directory answering
  from both the local node and the search path, with identical `(name, id)` pairs. `dscl . list
  /Users` and `/Groups` independently report exactly 133 and 161, which is the OS agreeing with the
  de-duplicated set and is what makes it a usable test oracle. De-duplicate on the **whole record**,
  not the name: two accounts legitimately sharing a name with different ids must both survive.
- **Filter service accounts by the leading underscore, never by a numeric floor.** "Real accounts
  start at 500" is the tempting rule and it is wrong in the direction that matters: after
  de-duplication the underscore rule leaves **4 users and 34 groups**, including `wheel`(0),
  `everyone`(12), `staff`(20) and `admin`(80) — which are precisely the groups an ACL entry names. A
  `gid >= 500` filter hides all four and leaves the picker unable to express the common case.

### Extended attributes (`listxattr` / `getxattr` / `removexattr`)

- **Pass `XATTR_NOFOLLOW` everywhere, for the same reason the rest of the attributes machinery uses
  the `l*` syscalls.** Probed on a real symlink: following returned the *target's* attributes and the
  link's own set was different, so a panel that followed would list — and delete — the wrong file's.
  A symlink does carry its own (`com.apple.provenance`, at minimum).
- **`removexattr` on an attribute the file does not carry fails with `ENOATTR` (93).** This is the
  syscall behind the `xattr -d` exit-1 trap below, so the core's remove swallows `ENOATTR` and
  succeeds: the caller's intent — "this must not be here" — is already satisfied, and idempotence is
  what keeps a multi-selection "Remove Quarantine" from failing on the files that were already clean.
- **One ordinary download carries all three value shapes**, so a viewer cannot assume any of them:
  `com.apple.quarantine` is plain UTF-8 (`0281;6a5c94dc;Chrome;<UUID>`),
  `com.apple.metadata:kMDItemWhereFroms` and the Finder tags are **binary property lists** (`bplist`
  magic), and `com.apple.macl` / `com.apple.lastuseddate#PS` / `com.apple.provenance` are opaque
  bytes. Classify by **inspection, not by name**, or an attribute this build has never heard of
  renders as garbage.
  - **A UTF-8 decode alone is not the text test.** Short binary values decode as UTF-8 surprisingly
    often — the real 11-byte `com.apple.provenance` does — so the result must also be *printable*, or
    control characters go straight into the panel.
- `XATTR_MAXNAMELEN` is 127. `listxattr` hands back a NUL-separated buffer; `XATTR_SHOWCOMPRESSION`
  made no difference on any real file probed, and neither `com.apple.FinderInfo` nor
  `com.apple.ResourceFork` appeared.

### Attribute escalation (osascript, chflags, chmod +a#)

The M14 Slice 5 escalation reproduces an `AttributeChangePlan` as a `/bin/sh` command run as root. All
probed live (2026-08-01/02) before any Swift; several results decided the shape.

- **`osascript` can run a shell body as root with *no* AppleScript-string escaping** — pass the body as
  an argument, not embedded in the source: `osascript -e 'on run argv' -e 'do shell script (item 1 of
  argv) with administrator privileges' -e 'end run' -- "<body>"`. Probed: a body carrying single
  quotes, backslashes and `$(touch pwned)` came back through `argv` **inert** (returned as data, no
  substitution). Embedding it in the AppleScript text instead would add a third quoting layer (escape
  `\` and `"`) on top of the shell quoting inside the body — this avoids it entirely. Canceling the
  auth dialog is AppleScript error **-128** ("User canceled"), surfaced on stderr with a nonzero exit;
  treat it as a choice, not a failure. `do shell script` runs `/bin/sh` and, on a nonzero exit, reports
  `execution error: <stderr> (<code>)`.
- **`chflags` is *additive*, not absolute** — `chflags hidden` then `chflags uchg` yields `uchg,hidden`
  (probed). So reproducing a target flags word means emitting the minimal `keyword`/`nokeyword` delta
  against what is on disk at that step (`chflags nouchg` clears only `uchg` and leaves `hidden`), not
  the whole word. `chflags 0` / an octal *is* absolute, but opaque to a user reading the copyable
  command, so the keyword delta wins. `noschg` on a file without `schg` is a clean no-op (exit 0).
- **`chmod +a#` reproduces an *exact ordered* ACL, and the canonical rights spelling works on a
  directory.** `chmod -N` clears the list, then `chmod +a# <index> "<spec>" <path>` in order rebuilds
  it (probed: order preserved on readback via `ls -le`). The spec is the friendly form
  `<user|group>:<name> <allow|deny> <rights,inherit-keywords>`, and `read/write/execute/append` are
  accepted **verbatim on a directory** — `chmod` translates them to `list/add_file/search/
  add_subdirectory` itself — so no per-kind relabeling. Three entries `chmod` *cannot* express, which
  make the whole ACL a stated omission rather than a wrong write: a **bare-GUID / unresolved subject**
  (`chmod: Unable to translate '…' to a UUID`), an **inherited** entry (`+a#` creates it explicit,
  losing the `inherited` flag), and a token this build only keeps verbatim.
- **No stock shell tool sets the birth/Created date** — `SetFile` is Xcode-CLT-only (and whole-second,
  US-format), so a `setCreationDate` step is omitted and named, never faked. `touch -t` is
  **whole-second**, which matches `NSDatePicker`'s own resolution; set only the time that changed
  (`touch -a` / `touch -m` separately, since `touch -t` writes one value) so an untouched neighbor
  keeps its sub-second value. `chmod`/`chflags`/`chown`/`chgrp`/`touch` all take `-h` to act on a
  symlink itself, matching the `l*` syscalls the read path uses.
- **Verify the translation on an *owned* file, unprivileged.** The whole point is that the *same*
  commands the root path runs are ordinary CLI, so a throwaway harness can run the generated body on a
  file the tester owns and let `ls -le@` / `stat -f` judge — the locked-file unlock/relock, the setuid
  digit through `chmod 4755`, the ACL order, all provable with no password. Only the final `sudo` /
  auth-dialog step needs privilege, and that is the one part left to the user.

### xattr and sips (the stock tools a user script reaches for)

- **`xattr -d` exits 1 on a file that doesn't carry the attribute** ("No such xattr"), so
  `xattr -d com.apple.quarantine "$@"` over an ordinary selection *fails* — and in Dirnex that means
  the user-script failure alert, for a script that did exactly what was asked. **`xattr -dr` exits
  0** on the same input. The recursive form is the one to reach for, for its exit code rather than
  for the recursion.
- **`sips` exits 0 and warns to stderr on a non-image** ("not a valid file - skipping"), so a
  conversion run over a mixed selection converts the images and stays quiet instead of raising
  anything. Useful, and not ours: it is `sips`'s choice, so anything relying on it should say so
  before someone "fixes" it into a type-checking loop.
- **`sips -Z 1200 "$1"` overwrites the original.** `--out "${1%.*}-1200.${1##*.}"` writes beside it
  instead, which is what any one-click example acting on someone's photographs should do.

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
- **The `VERSION` file is *branch-local state*, so it is only current on the branch releases are cut
  from — and the same "one number line" argument that fixed build numbers fixes this too.**
  `release.yml` pushes its `Release vX.Y.Z` commit with `git push origin "HEAD:${GITHUB_REF_NAME}"`,
  i.e. to whichever branch ran; nothing carries it back. Dev therefore still read **0.0.1** while
  stable was **1.0.10**, and the first beta ever cut from Dev previewed `0.0.2`. It would not have
  been rejected, which is the dangerous part: the build number is already floored from the feed, so
  Sparkle ranks the item correctly and *offers* it — presenting the user a version going backwards.
  Both workflows now floor the base on `max(highest published vX.Y.Z tag, VERSION) + 1 patch`.
  - `release.yml`'s checkout needed **`fetch-depth: 0`** for it; a shallow checkout fetches no tags,
    so the floor would silently have been no floor at all. `beta.yml`'s resolve job already had it.
  - It hid for eleven releases because every earlier beta was cut from `main`, where the file is
    current by construction. A value that is only correct on one branch is a bug waiting for the
    first person to use another one.
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

- **A stand-in justified by a reader that does not exist is a bug waiting for its first reader, and
  it is invisible until that reader arrives.** S3 and FTP's DOS/IIS dialect both synthesized
  `0o755`/`0o644` for items that have no POSIX mode, each under a comment saying `0` "would render
  every remote row as unreadable in the permissions column" — and the pane's columns are `name`,
  `size` and `date`. There has never been a permissions column. The invented value was therefore
  *correct-looking and unread* for two milestones, and the pass that finally displayed a remote mode
  (M24 Slice 7's Get Info) would have presented it as the server's own word.
  - **The tell is a comment that justifies a value by naming where it is drawn.** Grep for the
    reader; if it does not exist, the value is unmeasured rather than safe. It is the mirror of this
    file's other recurring shape — a check or a fix that lives only in prose — with the prose here
    describing a *consumer* rather than a rule.
  - **The fix is to make absence representable, and an `Optional` is what forces the next reader to
    decide.** A sentinel could not work: `0` is a legal mode (`chmod 000`), so it cannot mean "not
    reported" without making an unreadable file indistinguishable from an object store. Optional cost
    almost nothing here — the only production reader was one pass-through, because the packer takes
    its mode from a real `stat` — which is worth measuring before assuming the blast radius is why
    the sentinel was chosen.
  - **A field with no answer must be *absent* from a panel, not blank and not defaulted** — and it
    then needs a sentence saying so, or a short panel reads as one that failed to load rather than as
    a fact about the server.

- **A place a tab can be restored to is not the same as a place it can be *reopened* to, and the
  difference is a field nobody was storing.** Session restore kept exactly the tabs it could list with
  no preparation — `backend == .local`, directory still there — so a browsed `.zip` and every
  connected server were dropped, while the saved connection sat in the sidebar looking fine
  (docs/LOCATION-SUPPORT.md's first ranked gap). The *place* had always been persisted: a
  `PersistedTab` carries the account's full descriptor. What it could not carry was the **way back**
  — a `VFSBackendID` is host, user, port and region, and says nothing about the auth method or an
  FTPS certificate the user chose to trust. The tab was therefore not restorable *from itself*, and
  the fix is a field, not a mechanism.
  - **Registering a remote connection costs no round trip**, which is the measurement that decided
    the whole design and is the opposite of what "reconnect" suggests. `CompositeBackend.connectSFTP`
    / `connectFTP` / `connectS3` build a transport object and file it under a descriptor; the network
    happens in the *listing* that follows. So a restore is synchronous, needs none of the connect
    flow's own machinery (the region-301 correction and the path-style retry have nothing left to
    correct — a restored bucket's path is already the one an earlier connect settled on), and the two
    failures separate cleanly: a connection that cannot be **registered** has no secret, and one that
    registers and then cannot **list** has a server problem. Check what a "connection" actually costs
    before designing around it.
  - **Put the seam in `navigate`, not in the activation.** Every way back into a tab — switching to
    it, clicking a crumb, ⌘L, back/forward — is a navigation, so one definition of "open this place
    again" covers the launch path and every gesture at once. It is also what gives a tab that came
    back *disconnected* a way out with no new UI, which is otherwise a real design problem: the state
    is reachable and nothing in the app would connect it.
  - **A relaunch is unasked, however true it is that the user left the tab open** — and Settings ▸
    Panels promises in so many words that a refresh floor of 0 means *"never contact a server
    unasked"*. Until a restored tab could reopen a connection, the poll was the only thing that
    reached a server unasked, so the promise and the timer were the same rule; they are not any more.
    One flag on the launch activation decides both halves of what that costs — whether a server may
    be contacted, and whether a failed listing is worth an alert (the "who is waiting?" rule ▸ Testing,
    arriving one step earlier, before a listing is even attempted). Every other caller leaves it false,
    which is what keeps 0 meaning "unasked" rather than "never".
  - **The endpoint has to *be* the path's backend, and comparing them costs a string.** A persisted
    tab is JSON in a defaults domain: its path and its endpoint are two fields, and a store that was
    hand-edited or half-migrated would otherwise connect to one server and list a path belonging to
    another — a plausible listing under the wrong name, which is the quiet direction.
  - **A `Codable` enum with associated values inside a persisted *array* is a session-emptying bug
    waiting for the next case.** This file already records that trap for `PersistedTab.viewMode`,
    where a raw string was chosen for it; an endpoint cannot be a raw string. A pane's tabs are one
    JSON blob, so one element that refuses to decode takes **every tab beside it** — the day a new
    protocol ships, a build that has it and a build that has not would empty each other's sessions.
    `StoredServerEndpoint` decodes to `nil` rather than throwing.
  - **Refuse what cannot come back on the way *down*, where the fact is still known.** A tab inside a
    **nested** archive is mounted from a temp extraction of a member of the enclosing one, and the
    registry that knows where it came from is session-scoped — so at restore time the only evidence
    left is a path under `NSTemporaryDirectory()`, which is a guess. At persist time it is a lookup.
  - **The independent judge is the server's own log, and it answers a *negative* as cleanly as a
    positive.** Verified against a throwaway local `sshd` (▸ The SSH exec channel — one is a
    generated host key and a config file away): seeded a session with `defaults write`, ran the
    binary from a shell, and read `sshd -E`. At the default floor the restored tab reconnected at
    launch and its cursor came back on a file that exists only on the server; at floor 0 the same
    launch left the log **0 bytes** and one scripted Go Up put an `Accepted publickey` in it. A byte
    count is what makes "contacted nothing" a measurement rather than a screenshot nobody can take.
    - **A throwaway server on a port you have used before fails preauth**, because `~/.ssh/known_hosts`
      still pins the *previous* throwaway's host key — and the app's own error then reads as a broken
      feature rather than as a stale pin. `ssh-keygen -R "[127.0.0.1]:<port>"` first, and reproduce
      the app's exact `sftp` argv from a shell before suspecting the code.
    - **`AppPreferences` keys are `Dirnex.pref.*`, not `Dirnex.*`.** A probe that seeded the wrong one
      read the *default* floor back and reported the promise broken; the tell was the value logged by
      the code under test disagreeing with `defaults read`. The tabs are `Dirnex.tabs.<pane>` and are
      **not** prefixed, which is what makes the mistake easy — one probe, two key conventions.

- **When two remotes *can* talk to each other, the question is whether one can *name* the other —
  and getting that wrong fails by succeeding.** S3 copies between its own buckets with
  `x-amz-copy-source`, so staging those bytes through this machine would move them twice to produce
  a request the service would have made itself. What gates it is not "are both ends S3" but
  `S3Location.acceptsServerSideCopy(from:)`: the same **access key id** (there is one signature, and
  the destination's key is what reads the source) and the same **service** — because a bucket name
  means different things at different providers, so a MinIO bucket named in a request to AWS does
  not 404, it addresses whatever bucket *AWS* has under that name. That is the failure worth
  designing against, and it is the only one here that is not a refusal: a copy that completes, under
  the right name, with the wrong bytes.
  - **The one exception has to be a documented property, not a judgement.** Two `amazonaws.com`
    endpoints are allowed to name each other's buckets because an AWS bucket name is globally unique
    across every region and account — which is what `BucketAlreadyExists` means (▸ curl for S3) — so
    they cannot disagree about which bucket a name is. Anything softer than that ("they look like
    the same provider") is how the wrong-bytes case gets in.
  - **A fast path that the service may refuse must degrade, not report** — and then it is safe to
    attempt without knowing the answer in advance. `CopyObject` is capped at 5 GiB, an S3-compatible
    endpoint need not offer a cross-bucket copy, and a bucket policy can allow the read through one
    connection and not the other; all three are recoverable by moving the bytes ourselves, so the
    route falls back to staging on any failure that is not a cancellation. The tell that a fallback
    is honest rather than a mask: the error the user finally reads comes from the *slower* path, so
    nothing that would have failed before now succeeds quietly.
  - **The wire is the observable, and a fake endpoint that verifies nothing is the right instrument
    for it.** `Tooling/fake-s3-endpoint.py` writes down every request and checks no signature — it
    would agree with a broken client, which is why it can only be used for this question: *which
    requests were made*. It settled all three cases in minutes with no AWS account: one PUT and no
    GET for a compatible pair, three requests for a refused one, and — the safety rule, visible as an
    absence — **no copy request at all** for two buckets on two ports.
  - The headless control that separates "fell back" from "gave up" is the error's **path**: a refused
    server-side copy names the destination (its `PUT`), the staged download that follows names the
    source. No server needed to read it, and it fails loudly the day the fallback is removed.

- **A verb a protocol lacks is not a verb the *product* lacks, and the honest home for the
  substitute is the layer holding both ends.** `VFSBackend.copyFile` reads as "duplicate this file"
  and over SFTP and FTP it is a **direction** — `get`/`put`, download/upload — so both backends
  refuse any pair of ends with no local side. Correct at the backend, and it shipped as a dead end:
  F5 from a bucket to a server failed per file with *"Copying directly between remote locations
  isn't supported"*, and so did a duplicate **inside one account**, which nobody had thought to try
  because "same server" reads as the easy case. Neither backend can be fixed — neither has heard of
  the other — so the substitute (download, upload, delete the staged copy) belongs to whoever holds
  both connections, which is the router: `RelayCopy` in the core, called by `CompositeBackend`.
  - **Which pairs need it is a capability, never a list of backends.** `VFSCapabilities.internalCopy`
    says "this backend can copy with both ends inside itself" — the local disk, and S3, whose
    `x-amz-copy-source` keeps the bytes inside the service — and the router asks each backend rather
    than naming them at the one site that decides. The alternative is this file's most repeated bug,
    and here it has an expensive form: a same-bucket duplicate staged through this machine would
    download and re-upload a file the service copies for nothing.
  - **The tell to grep for is a backend's own doc comment explaining what it cannot express.** Both
    said so plainly, for a milestone, in the file where nobody asking "why can't I copy this" would
    look. A refusal that names a *missing mechanism* rather than a rule is a feature request with a
    date on it (the archive-member edit lesson, arriving on a transfer).
  - **A relay must count the file once.** The queue's denominator is the file's size, so reporting
    both legs drives the bar to 200 %: report each at half weight and reconcile the tail against the
    staged file's exact size, which also covers a leg that reports nothing at all (an SFTP upload
    has no observable — `sftp` prints no meter a spawned process can read). And it costs the file's
    own size in temp space for the length of the transfer, which is what "no single backend can
    carry these bytes" means in practice rather than a shortcoming of the staging.
  - **The move came free and is worth checking for before designing anything**: `moveItem` already
    answers `EXDEV` across backends, so `CopyEngine` runs it as copy-then-delete with progress,
    Stop, the conflict policy and an undo record — the same fallback an S3 prefix rename rides.

- **A confirmation raised by a *watcher* over a gesture the user already made is a confirmation of an
  intent already stated — and the test of whether it earns its modal is not "is this irreversible" but
  "did the check produce a fact they can act on".** The remote save-back asked on every ⌘S, and its
  body on the ordinary path said the server's copy was exactly as downloaded: a question about
  nothing, once per save, for the life of the edit (`EditedFileRegistry` keeps watching after an
  upload by design), where the **local** F4 it is the twin of asks nothing at all. Reported by a user
  2026-08-23. Nothing automated can see this class — the dialog was *correct*, both suites and both
  linters were green, and the English screenshot is perfect; it needs somebody saving a file ten
  times.
  - **The sharpest tell is a body that argues against itself.** The FTP wording named a real weakness
    — a `LIST` stamp is year-less, zone-less and on the server's clock, so "same size and date" misses
    most of a working day — and then offered two buttons resting on *that same evidence*, with no way
    for the reader to strengthen it and the identical sentence again on the next save. Both choices
    act on one input, so the dialog is asking a question it has already answered as well as it can be
    answered. `RemoteFileRevision` refuses to show a confidence percentage for exactly this reason
    ("a number nobody can act on"); a caveat with no action attached is the same thing in prose.
  - **A neighbouring feature's reason for asking is not transferable, and its doc comment will read as
    though it is.** The archive write-back asks because a repack rewrites the whole container and
    every other member with it, so an autosave triggering one is a big deal. An upload replaces the
    one file being edited with the version just saved — which is what "save" means. One
    `offerWriteBack` switch, two endings, and only one of them had the argument.
  - **What replaces it has to leave a trace, or "silent" becomes "did nothing".** An upload that
    reports nowhere is indistinguishable from one that never happened, so the routine half moved to
    the status line — which then owes the ▸ Localization budget check, since that label truncates its
    *tail* in silence (measured 230 pt, and 427 pt with a 43-character name, against 542 pt, across
    all fourteen catalogs).
  - **Both negative controls are needed and they separate cleanly**: restoring the always-ask version
    fails only the "an unchanged file must not interrupt" cases — spelled out over every shape such a
    verdict can have rather than sampled, because the weakest ones are where the argument for asking
    used to live — while over-correcting to never-ask fails only the ones that must still stop the
    user. Without the second, "don't interrupt" quietly becomes "never interrupt", which loses the
    sentence the whole mechanism exists to say.
  - **The grading that produced those four sentences had no reader left, and deleting it is part of
    the fix rather than tidying after it.** `RemoteRevisionEvidence` ranked how much an unchanged
    verdict was worth; it fed nothing but the wording, so when the wording went it became public core
    API used only by its own tests — and it took two more fields with it, since
    `timestampIsApproximate` existed only to feed the grading and `VFSBackendID
    .hasApproximateTimestamps` existed only to feed *that*. A chain worth walking whenever a display
    decision is withdrawn: the value that fed it, and the predicate that fed the value, are usually
    dead too, and each looks load-bearing on its own. What must not go with them is the *fact* — an
    FTP `LIST` stamp is still year-less, zone-less and on the server's clock, which is why it is
    recorded here (▸ curl) rather than only in a type.

- **When a gesture gains a *fetch* stage, every precondition it used to check afterwards has to move
  in front of it — and no test can see that it did not.** M24 Slice 4 put a download in front of ⌥F3,
  and `launchExternalDiff`'s own first act is "is a diff tool installed?", which is now asked *after*
  the bytes have been paid for: a Mac with no FileMerge, Kaleidoscope or BBEdit would download two
  files in order to be told there is nothing to open them with. Every suite was green — the tool
  question still gets asked and still reports correctly, just too late — and the ordering is
  invisible in the diff, because the two halves live in different functions and neither changed.
  Caught by setting up the live run and asking what it would do on a machine without the tool.
  - The audit is cheap once named: **read the callee's guards and ask which of them are questions
    about *this Mac* rather than about the files**. Those are the ones that were free before and are
    not any more. Here it was one call to one function, so asking it twice costs nothing and drifts
    nowhere — the other caller (the Synchronize sheet) reaches the launcher without passing through
    the gesture, so its own guard has to stay regardless.
- **A `VFSError` is already the answer, so normalizing it through an errno is how a server's own
  reason becomes `.io`.** `ChecksumRunContext.recordFailure` ran every failure through
  `VFSError.fromErrno`, which is right for a Cocoa or POSIX error — those can only have come from the
  file manager — and flattens a backend's refusal to a code nobody can look up. It cost nothing while
  the only thing that could fail was a local `Data.write`; it started mattering the day a manifest
  could be written somewhere that answers back, and what a user would have read in place of "the
  bucket is read-only" was an `.io` with a numeric code. `(error as? VFSError) ?? .fromErrno(…)` is
  the whole fix, and it is `MaterializeRunner`'s own spelling. Worth grepping for wherever an error
  crosses from a backend into a report: the tell is a call to `fromErrno` with no `as? VFSError`
  ahead of it.
- **A gesture that has to work out what a run will do must call the run's own function, not a second
  copy of it — and two phases is when that stops being optional.** Verifying a checksum manifest that
  is not on this disk cannot know what to fetch until the manifest has been read, so the *gesture*
  works out the claimed set in order to weigh and confirm it and the *run* works it out again in
  order to hash it. Written twice, they fail in the quiet direction: every file the gesture failed to
  predict is not fetched and comes back "not downloaded", for a file sitting right in front of the
  user, with nothing logged and every request having succeeded. `ChecksumVerifyScope.resolve` is
  therefore one function taking its listing as a closure, called once per phase — which also made it
  testable against literals, where it had been private inside a run that needed a temp tree.
  - **Keep the cheap phase cheap and the common case out of it entirely.** The manifest is kilobytes,
    so phase one is under every row of the size table and asks nothing; the walk between the phases
    costs listings and no transfers, so by the time anything is downloaded the total is exact rather
    than a floor. And a **local** manifest short-circuits before phase one, because its walk is
    rooted at its own parent and nothing there can need fetching — which is what keeps the ordinary
    gesture free of the second directory walk the two-phase shape would otherwise add to it.
- **A protocol doc comment is a claim, and an untested one drifts exactly like a duplicated
  predicate — except nothing at all checks it, not even a linter.** `VFSBackend.moveItem` promised
  "Throws `.alreadyExists` if `destination` is occupied" from M2 until 2026-08-23, and **no backend
  has ever done it** for the case that matters. Measured across all four: local `rename(2)`
  *replaces* a destination file (the bytes afterwards are the source's) and yields `.alreadyExists`
  only from `ENOTEMPTY`, i.e. a directory onto a **non-empty** directory; OpenSSH's `rename` uses the
  POSIX-rename extension and overwrites, its directory refusal arriving as a bare `Failure` →
  `.io`; FTP's `RNFR`/`RNTO` overwrote on the server measured, its refusal a 550 → `.notFound`; and
  S3's copy-then-delete overwrites unconditionally.
  - **The tell is that every caller had already worked around it, independently.**
    `PanelViewController+Rename` and `+TrashRestore` each `stat` the destination first, *both with a
    comment naming `rename(2)`'s overwrite*, and `MultiRename.plan` refuses a colliding name upstream
    of the apply loop. So the codebase knew; only the contract did not — three correct workarounds
    sitting under a sentence saying they were unnecessary. When a doc comment and several call sites
    disagree, the call sites are the measurement.
  - **The neighbouring claim had the same defect and a caller that actually believed it**, which is
    what made it a bug rather than a documentation tidy. `createDirectory` says "Throws
    `.alreadyExists` if something is already there" — true of local `mkdir(2)`'s `EEXIST` and false
    remotely: measured, `sftp`'s `mkdir` onto an existing directory gives `remote mkdir …: Failure`
    (OpenSSH's SFTP v3 has no "already exists" status, so `EEXIST` arrives as `SSH_FX_FAILURE`) →
    `.io`, and FTP's `MKD` gives 550 — its one ambiguous refusal → `.notFound`.
    `PanelViewController+Copy.submitBranchTransfer` catches `.alreadyExists` to skip an intermediate
    directory that is already there, so on a remote destination that `catch` never fired and the
    whole transfer failed instead of continuing; F7 on a taken name reported the wrong sentence for
    the same reason. **Fixed 2026-08-23** in `RemoteTransportBackend.createDirectory`, which
    disambiguates a *failed* create with a `stat` — the shape S3's own existence check already
    settled on, where the cheap answer raises the question and only a name about to be refused pays
    to have it answered. Two properties keep it honest and both are pinned, headlessly and live: a
    refusal that is **not** about the name (a missing parent, a read-only directory) keeps its own
    error, or the user is sent to rename a folder that was free; and a `stat` that cannot be had
    leaves the original error standing rather than reading as either answer.
    - **`S3Backend` is deliberately outside the fix and its `createDirectory` still throws
      nothing**, because a folder there is a zero-byte marker: writing one twice leaves one object,
      so there is nothing a second create could destroy and nothing to disambiguate. Worth stating
      because "make every backend honour the contract" is the tempting next step and would bill a
      listing to answer a question no caller asks.
  - The general shape: **an error case a caller `catch`es by name is API, and it needs a test per
    backend the same way a capability does.** A `catch` that never fires is invisible in every
    direction — it compiles, it reads as defensive, and the failure it was supposed to absorb
    arrives as something else entirely.

- **One transfer with two things reporting it is one reporter too many, and the modal one is the one
  to withdraw.** A remote preview download had a placeholder card standing exactly where the preview
  will appear — naming the file, its size, a determinate bar and Stop — *and* a deferred progress
  **sheet** that went up over it after 1200 ms. Not merely untidy: the sheet is modal, so it covered
  the card that was already answering the question and took the keyboard off the file list to do it.
  What makes the choice easy is asking who is standing where the user is looking; what makes the fix
  small is that the two were already computing the same two values, so the explicit transfer now
  registers its byte counter and its cancel flag with the same cache the cursor-following one uses,
  and one card draws either. The sheet stays for the callers that genuinely have no surface
  (⌘Y with the preview mode off, ⏎, F4) — "get rid of the redundant dialog" is a rule about
  redundancy, and deleting it outright would leave those with nothing at all.
  - **A progress surface drawn from a snapshot needs telling when the transfer *starts*, and that is
    not the same moment as the call.** A confirmed fetch begins when the user answers the dialog,
    long after the caller returned and the card was drawn — so without an `onStart` hook the card
    goes on offering a Download button over a download already running, which is the bug the fix was
    for, wearing different clothes.
  - **Widening who may report also widens who may *start*.** With the explicit fetch visible, the
    cursor-following one had to stand aside for a row already spoken for, or the redraw the Download
    button itself causes issues a second transfer of the same object — measured, the control fails at
    two copies where the rule allows one.

- **An opt-in seam whose default is "can't help, do it the slow way" fails with no symptom at all,
  which makes it the one kind of missing wiring nothing on screen can report.** `VFSBackend
  .subtreeListing` defaults to `nil` meaning "walk instead", and M22 Slice 3's whole point is that
  S3 need not walk — but the app holds a `CompositeBackend`, so until it *forwarded* the call every
  search inherited the default: same rows, same order, correct in every particular, at one billed
  request per folder instead of one per 1000 keys. Contrast the usual shape of this family (naming a
  new backend at every site that lists the old ones, ▸ AppKit), where the omission produces a
  *wrong* answer somebody eventually reports. Here the only evidence is the bill and the wait. So a
  seam like this needs its forward asserted, and the assertion has to separate "routed" from
  "answered" — pointing it at an **unconnected** backend does that with no network, since routing
  raises "not connected" where the inherited default quietly answers `nil`.
  - **The narrowness control is the other half and is not optional**: a forward that answered for
    *everything* passes the routing test and breaks every other search. Assert that the local disk
    still reports `nil`.
  - **It happened again, in the same shape, one milestone later — in a session that had already
    written a routing test for the sibling verb because of this very entry.** M25 Slice 5b added
    `VFSBackend.metadataTally(at:)` (what a connection has failed to carry, read before and after a
    job and subtracted) and `CompositeBackend` never forwarded it, so it inherited the `.zero`
    default: every job's delta was zero, every copy looked lossless, and the status line the whole
    slice exists for simply never appeared. Both full suites green, both linters clean, nothing
    logged. Only a live run against a real server found it, and only because the *expected* sentence
    was known in advance.
  - **The reason the obvious regression test does not exist is worth more than the bug**: a healthy
    connection's tally is zero and a missing forward's is zero, so **no fixture built on a working
    connection can tell them apart**. The discriminator has to be a connection that has *already*
    lost something — here a fake transport declaring **no** metadata capabilities, so every transfer
    through it records a loss. Generalizes to any seam whose good answer is also its default: the
    test needs a state the default cannot produce, and if the default is "nothing", that state is
    "something went wrong earlier".

- **A shortcut that replaces a walk has to reproduce what the walk *inferred*, not just what the
  source hands back.** A delimiter-less `ListObjectsV2` returns no `CommonPrefixes` whatsoever — S3
  is a flat keyspace, and the folder rows a directory listing shows are the *server* grouping keys
  on request. So the flat route must synthesize a folder for every component on the way down to a
  key, and for every trailing-slash marker (the only trace an empty folder leaves). Skip that and a
  search for `docs` finds nothing called `docs` while a Kind filter of Folders returns nothing over
  a bucket full of them — an empty result, which reads as "there is none" rather than "this route
  cannot see them". The general form: when two routes answer one question, list what the slower one
  *derives* rather than diffing what the two are given.
- **"An unreadable subdirectory is skipped, never fatal" is a good rule that must not cover the
  *root*, and the two are one line apart.** A walk skips what it cannot list, because permission gaps
  are ordinary and the matches found elsewhere are still real answers — true of everything the walk
  *found*, and not of the folder it was pointed at, where the same skip returns zero hits and
  `complete`: indistinguishable from "nothing matched", which is how an empty pane reads. It stayed
  unreachable while every scope was a directory the user was standing in, and arrived with **saved**
  searches, which carry an absolute path from an earlier session — so the scope may since have been
  renamed, deleted, or be on a server nobody reconnected to, and all three would have read as "no
  such files". The shape to watch for: a tolerant rule written for the *interior* of a traversal,
  applied at its entry point because the loop treats them identically.

- **A cost rule enforced at the gesture that opens a *mode* is not the rule it claims to be, and the
  rule it actually enforces is one nobody can discover.** Quick View's remote fetch was allowed only
  on the keystroke that switched the mode on, in the name of "an arrow key never spends a billed
  request". That rule is right. What shipped was **"one file per time you turn Quick View on"** —
  so entering a folder with the preview still up drew a placeholder for every file in it, and the
  mode read as broken. Reported by a user 2026-08-14; nothing else could have found it, since every
  test, both linters and the feature's own live verification pass had only ever exercised the
  gesture that *does* fetch.
  - **The tell is a mode whose per-item cost is gated on the mode's own on-switch.** A mode is a
    standing request, so the honest place for a cost rule is the *item*: bound it there (a settle
    delay so a sweep is free, a size cap, abandonment when attention leaves) and the mode goes back
    to meaning what its name says. The gate-at-the-switch version fails in the quiet direction — it
    is indistinguishable from a feature that only half works.
  - **A refusal is not a size, and folding the two loses the case that matters.** The size table
    answers "is this worth fetching"; what an *automatic* gesture needs on top is that being refused
    must not raise a dialog, because a question asked because the cursor came to rest somewhere is
    itself unasked. Hence a third decision (`decline`) rather than a lower threshold — the two acts
    are the same act, and a second constant a few megabytes from the first would only drift.
  - **Ask before picking, when a report is really a request to change a decision.** "The preview
    doesn't work" was a *design* the milestone had argued for at length and written down twice, so
    the three live options went to Oleg rather than being resolved by reading the plan back at him.
    A user reporting a documented behavior as a bug is evidence about the behavior, not about the
    user.

- **A precondition names the state the user agreed to overwrite, never the state you started
  from — and the natural way round refuses exactly the write the dialog exists to authorize.** A
  remote save-back downloads a file, re-`stat`s before uploading, and shows what that found; S3's
  `If-Match` then closes the window between the answer and the `PUT`. The tag to send is therefore
  the **check's**, not the download's, and reaching for the download's is the reading everything
  about the feature invites — it is the revision the cache holds, the one the type is named after,
  and the one the sentence "has anyone written this since we fetched it" is about. Conditioning on
  it makes the *conflict* branch permanently dead: a user told «someone else has edited it» who
  presses Upload has said they mean to replace that version, and the older tag answers 412 to their
  own decision, which the app then words as somebody having changed the file. Nothing catches it —
  it compiles, it reads correctly at the call site, and only a test that constructs *two* revisions
  and asserts which one reached the header can see the difference.
  - **The refusal deserves a decision rather than an error.** A 412 means the object moved in a
    window measured in milliseconds; nothing is broken, and the user has already answered one
    question about overwriting. An OK button leaves them with "save again in the editor" as the only
    route, which is not guaranteed to exist — an editor asked to save a file it has not changed may
    write nothing for a size-and-mtime watcher to notice. Offer the unconditional retry, once:
    re-`stat`-and-re-condition can be refused again by a third writer, which is a loop with a round
    trip in it (▸ curl, the FTPS trust retry).
  - **Whether the server honours any of it is unmeasurable from the client**, so this kind of
    protection is only ever worth building as *strictly additive* — the check the user reads stays
    the one that works everywhere, and nothing on screen may claim the write was guarded. The
    corollary that decides the code: a large upload that cannot carry the condition (multipart) says
    so in a return value and shows the user nothing, because announcing the absence of a protection
    nothing promised is worse than silence.

- **An assumption about the *shape* of a selection, made when only one shape existed, is invisible
  until the second one arrives — and it can be years.** ⌥F5 was handed `panel.path` plus bare names,
  which is exactly true of a flat listing of a real folder and was the only thing a pane could show
  when it was written. A **tree** can mark a row inside an expanded folder, so since trees shipped a
  marked row at depth named a file that is not in the pane's own directory: `bsdtar` failed with
  "Couldn't create the archive", and the *encrypted* path — whose walk skips a name that does not
  exist, correctly, because a selection can go stale between the keystroke and the walk — wrote a
  **smaller archive and said nothing**. Found while widening the same call site for M24 Slice 6, not
  by anybody using it.
  - **The tell is a pair of arguments that only travel together by luck**: a directory here and a
    list of names there, where the honest unit is a *pair per row*. Every such split is a claim that
    every row shares something, and the day a second row source appears (a tree, a results tab, a
    staged download) the claim expires with nothing to catch it — the compiler sees a `String` and a
    `[String]` either way, and the failing half is the one nobody tests, because the fixture that
    exercises the feature is a flat folder.
  - It is the projection-index lesson (▸ AppKit, a second row source is a second index space)
    arriving at a *gesture* rather than at a row lookup, and it failed in the quieter of the two
    directions: an out-of-range subscript crashes, and a missing name just packs less.
- **A guard whose comment explains why it can never fire is the one to re-read when a backend widens
  a signal — and the *reason* it fires is exactly the operation it was reached for.**
  `UndoJournal.crossVolumeRestore` required both ends of a restore to share a name, saying so out
  loud: "a rename never crosses volumes, so it never gets here". True on every filesystem, and
  retired the moment a **rename** could answer `EXDEV` — an S3 prefix, whose rename is N copies and
  is therefore handed to `CopyEngine` (PLAN.md §M21). Undoing one puts the item back under the name
  it had *before*, which is not the name it has now, so the guard would have refused precisely the
  case that made it reachable, with a bare `EXDEV` on a restore that had nothing wrong with it.
  Nothing catches this: the compiler sees an `Int32` on both sides, every existing test passes
  (they all restore same-name moves), and the tell is *prose*. The fix is to delete the invariant
  rather than special-case it — a rename-carrying operation whose target name is `entry.name` for a
  same-name move is one path with no branch. Same family as "an invariant held by a flag becomes a
  bug the day the flag becomes a setting" (▸ Encryption, the vault-in-Finder case), arriving from
  the other direction: there a *flag* became a setting, here a *signal* gained a second producer.
  - **Reach for the queue's existing `EXDEV` fallback before designing a job**, which is the
    constructive half and is the second time this milestone paid off: a folder *move* on S3 needed
    no new job type for the same reason (§M21 Slice 4). What a rename needed on top was four lines
    of value type — the one source's landing **name** — because everything else the operation wants
    (a determinate bar, Stop, the conflict policy, per-item failures, an undo record) is what the
    queue already is.
  - **A field on the existing kind beat a `Kind` of its own, and the cost of the alternative is the
    argument.** A `.rename` case would fork every `switch` over `FileOperation.Kind` — four label
    sites in the app, the undo journal's label map, the engine's own `kind == .move` tests — to
    change a *caption* on a job whose behavior is identical. Let the confirmation that raised it say
    what is really happening, and keep one code path.
- **A restriction whose comment explains *why* it exists is a feature request with a date on it, and
  the fix usually retires several of them at once.** F4 declined archive members with "would edit an
  extracted temp copy whose saves go nowhere"; the extracted copy Enter opened was `chmod 0444` for
  the same reason, argued at length in its own doc comment. Both were honest, both were correct, and
  both were the *absence* of one mechanism — watch the copy, offer to repack. Writing it deleted the
  chmod, the F4 refusal, and a paragraph of justification each. Worth grepping for the shape: a guard
  that names the missing capability rather than a rule.
  - **Watch the member's temp *directory*, never the file.** Nearly every macOS editor saves
    atomically — write a sibling, rename over the original — so the file the editor leaves behind is
    a different inode from the one handed to it. A descriptor- or inode-based watcher sits on a file
    nobody will ever write to again and fails in the silent direction: no error, no callback, and the
    user's edit simply never offered. Each extraction already has its own directory, so the watch
    costs nothing extra; the price is the editor's scratch files waking it, which a size+mtime
    comparison (`EditedFileRevision`) filters. Treat `nil` — the file momentarily absent mid-rename —
    as "not yet", not as a change.
  - **Advance the recorded revision when the offer is *raised*, not when it is answered.** The offer
    is a sheet, so an editor autosaving twice while it is up queues a second identical question
    behind the first.
- **`bsdtar` cannot rewrite an encrypted archive, and the failure is quiet enough to read as "not
  implemented".** Every archive write (F8 delete, F5/paste add) went through `ArchiveWriter.rewrite`
  → `bsdtar -x`, which on a real AES-256 zip **exits 1 having written nothing** — measured; it does
  not prompt and does not hang, unlike the member-list `-xf` form this file already documents. So the
  rewrite threw `archiveUnreadable` before touching the original, which is the *safe* direction and
  is exactly why it sat unnoticed: no corruption, no hang, just an operation that never worked.
  `ArchiveRewriteFormat` now picks the libarchive route off one header read.
  - **A rewrite has to re-state what it cannot re-derive.** An extracted tree says nothing about
    whether it came out of an *encrypted* archive, and — because the reader unwraps a hidden-names
    archive transparently — nothing about whether its names were hidden. Both must be read off the
    original's headers and passed to the repack. Forgetting the second is the expensive one: the
    contents would be perfectly correct while every file name of an archive whose whole purpose was
    hiding them became public, with nothing on screen to say so.
  - **libarchive's reader does not report a zip's cipher strength**, so an AES-128 archive made
    elsewhere comes back AES-256. Stated rather than guessed — the alternative is inferring a weaker
    cipher from no evidence.
  - The two routes spell entry names differently and that is pre-existing: `bsdtar` packs `.`, so its
    rewrites carry `./name`, while the libarchive route enumerates the top level and writes bare
    names (what the pack sheet produces). Both browse identically. Enumerate **including dot-files**
    or a rewrite silently drops the `.gitignore` somebody packed.
- **A credential-shaped feature has to split its entry point in two, and the half that follows the
  cursor is the one that must stay silent.** An encrypted archive browses fine — a zip's central
  directory is never encrypted — so the passphrase is wanted only when *bytes* are, and the natural
  implementation asks for it wherever the bytes are read. That is wrong for exactly one reason: the
  preview reads them on **cursor movement**, so a prompt raised there is a modal sheet on an arrow
  key. `withArchivePassphrase` is therefore only reachable from the gesture the user actually made
  (⌘Y, ⌃Q turning on, Enter, F5), and the passive refreshes read an already-unlocked passphrase and
  do nothing when there is none. Same split the Quick View JavaScript switch needed, arriving from
  the other side: there the question was "should this run unasked", here it is "should this *ask*
  unasked", and both are separate from whether the operation is safe.
  - **The gap it papered over stayed invisible because the passive path swallows errors, which it is
    right to do.** `prepareArchivePreview`'s `try?` exists so a damaged member does not raise an
    alert on every arrow key — correct, and it is also why an encrypted archive silently previewed
    nothing for the whole life of the feature. A swallow that is right for the cursor path is wrong
    for the key press; the fix is a second entry point that reports, not a narrower `catch`.
  - **`ArchiveExtractor`'s own doc comment named this as "its own slice", and PLAN.md named it twice
    more.** Three written records, no check, and it shipped — the third instance in this file of "a
    check living in prose is not a check" (the `.stringsdata` sweep and `enableEscapeToCancel` are
    the other two), and the first where what was documented was a *known missing feature* rather than
    a fix or a check. A user found it, which is the only instrument prose leaves available.
  - **Ask which gesture the user actually made before designing the fix.** "I can't open a file in
    it" was two independent bugs sharing one symptom: the passphrase gap, *and* Enter on a plain file
    member having never opened anything in **any** archive, encrypted or not — a deliberate no-op
    with a comment explaining itself. Fixing only the first would have left the report standing, and
    nothing in the code connects the two.
  - **The retry is the branch to verify, not the happy path.** A wrong passphrase re-raising the
    prompt (rather than dead-ending in an alert that makes the user re-select and press the key
    again) is the whole reason the funnel exists, and it is one line away from being a `catch` that
    reports. Type a wrong one first when checking it live; the correct one proves less.
- **A transparent unwrap is exactly wrong for the one caller that wants the container, and the pane
  is that caller.** `EncryptedArchiveReader.extract` undoes a hidden-names archive's wrapper and
  deletes it, which is right for everything that wants the *files* — and a browsed archive lists the
  wrapper as its only row, so Enter, F5, ⌘Y and F4 all ask for `Contents.tar` **by name**. The reader
  placed the payload, removed the very file that was requested, and the extractor handed back its
  nominal location anyway; entering it then mounted a path that had never existed and reported
  **"Couldn't read the archive “Contents.tar”"** — a claim about the archive where the truth was
  about the extraction. Reported by a user 2026-08-09. Two halves, and each is a shape worth watching
  for on its own:
  - **A guard living in one branch of a two-route function is a guard the other route does not have —
    and the callers will carry comments resting on it regardless.** The "did anything land" check sat
    in `ArchiveExtractor`'s `bsdtar` branch only, while *both* call sites said "`ArchiveExtractor`
    already threw if nothing landed, so this file exists". That is what turned a no-op into a phantom
    path travelling three files before anyone noticed. The fix is structural rather than a third copy
    of the check: split the engine choice into its own function and let the one `extract` own the tail
    both routes end on.
  - **The unwrap is the reader's default and the wrapper request is the exception, so state the
    exception where the request is read** — `ArchiveNamePrivacy.requestsWrapper(_:)`, matching the
    whole inner path and not a suffix, since a `Contents.tar` *inside* the payload is an ordinary file
    whose caller still wants the unwrap. `unwrappingHiddenNames: false` already existed and was
    already tested; what was missing was anybody passing it.
  - It is invisible to every automated signal — 2013 core tests, 313 app tests and both linters were
    green — and it fails in the quiet direction for the *neighbouring* gestures: F5 says "Couldn't
    extract the selected items", the preview simply shows nothing, and F8 on that row **silently does
    nothing at all**, because the rewrite unwraps too and its `try? removeItem` misses. That last one
    is still true and is design A's stated omission: under it the pane's row is the container while
    every write path speaks the payload, so the two disagree by construction. Making the *browse*
    transparent — prompt on entering a wrapped archive, list the real tree, never show the wrapper —
    is the fix that retires the disagreement, at the price of a passphrase prompt where entry has
    never asked for one.
  - The negative control is what makes the tests evidence, and it is cheap: neuter both halves
    (`unwrappingHiddenNames: true`, delete the guard) and re-run. The mount test then fails with
    `.unsupported(archiveUnreadable(archive: "Contents.tar"))` — the user's alert, verbatim — and the
    guard test fails by *returning* an extraction whose path is not on disk. The two narrowness
    controls keep passing throughout, which is the point of having them.
- **A layout is the one thing in this codebase a test cannot judge, and it fails by being *ugly*
  rather than wrong.** M18's flowchart layout passed 20 exact-number assertions — layers stacked,
  edges clipped to the right outlines, four directions mirroring correctly — while the first launch
  drew a back edge as a straight line through four boxes and both edge labels. Nothing was
  incorrect; it was unreadable, which no `#expect` can express. Two things follow. **Render it and
  look at it before believing any of it**: an HTML file plus a 40-line `WKWebView` snapshot harness
  (`takeSnapshot`, write a PNG) turns a layout into something the author can actually see, and it
  found this in one pass and two more the same way. And **when the picture shows the bug, write the
  assertion the picture would have made** — "the bend is outside every box it passes", "every point
  is on the canvas" — so the fix has a guard even though the original defect did not.
  - The specific lesson under it, for anyone laying out a graph: longest-path layering plus a
    barycenter pass is *not enough*. An edge spanning layers needs a **dummy node in each layer it
    crosses**, so the ordering pass can steer it between the real nodes. It is the one piece of
    Sugiyama layering it is not worth skipping, and its corollary bites immediately after — a canvas
    sized from the **boxes** leaves the bend outside it, so measure the bounds over what is *drawn*.
- **"Column" in a plan is a claim about *information*, not about an `NSTableColumn`, and three times
  out of three here the answer was a badge in the name cell.** M6 asked for a tags column, a
  sync-status column and a Git status column; tags and sync went into the name cell on the day they
  were built (that is where Finder puts them), and the Git gutter shipped as a real column and was
  moved on 2026-08-07. The arithmetic is what settles it: a column costs its own width **plus one
  intercell spacing** — 20 + 17 = 37 pt here — to draw a letter about 20 pt to the right of where the
  name cell's trailing edge already is, and a badge right-aligned in a fixed-width column lines its
  letters up in the same vertical run the gutter was bought for. A column earns its width when the
  content is *data the user sorts, resizes or reads across* (size, date); a per-row **state** with a
  glyph-sized rendering is a badge. The tell that a column is the wrong shape is a `title` that has to
  be `""` because one letter leaves no room for a heading.
- **Adding a second closure parameter silently re-points every bare trailing closure.**
  `size(of:using:) { true }` rebound to a new `excluding:` rather than the existing
  `isCancelled:`; only the differing arity made it fail loudly instead of inverting behavior.
  Label both at every call site.
- **A Swift `Character` is a grapheme cluster, so CRLF is *one* `Character` that equals neither
  `"\n"` nor `"\r"`.** `split(whereSeparator: { $0 == "\n" || $0 == "\r" })` therefore does not
  split a Windows-written file **at all** — the whole file comes back as a single unparseable line,
  which reads as "the parser rejects this format" and sends you into the parser. `\.isNewline` is
  the right predicate and is also more honest about line *numbers*, since it counts CRLF as one
  separator rather than two. The same trap sits behind any hand-rolled scan that compares against
  `"\r"`; anything splitting text a user's other OS produced should use `isNewline` on principle.
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
- **A cache keyed by a path outlives the file that path named, and "invalidate on our own writes" is
  the fix that looks complete and is not.** An archive's mount, its preview extractions and its
  nested temp mount are all remembered under its on-disk path — right, since the `bsdtar -tvf` and
  the decrypt behind them are the expensive part — and `invalidateMountedArchive(at:)` covers every
  edit Dirnex *makes*. It cannot cover the edit a user makes by **deleting the archive and packing a
  new one under the same name**, which is the ordinary way to redo one and does not go through the
  rewrite path at all. Reported live 2026-08-09: an archive repacked with one file went on listing
  the two the previous archive held, for the life of the window, while `bsdtar -tvf` on the same path
  from a shell printed the one. It fails in the quiet direction twice over — the pane shows a
  *plausible* listing rather than an empty or broken one, and nothing logs — and it is unreachable
  from any headless test that only drives the app's own writes.
  - The fix is to make each cache a cache rather than a memory: stamp it with what the file *is*
    (`ArchiveIdentity` — device, inode, size, mtime) and compare on every read. One `stat` against a
    subprocess spawn saved, so the freshness check is free at the scale that matters. **The inode is
    the load-bearing field**, since a repack writes a new file whatever the name, size and timestamp
    do; size and mtime only cover an in-place rewrite. Note it is the exact inverse of
    `EditedFileRevision`, which watches for a *save* and must therefore ignore the inode, because a
    macOS editor's atomic save replaces the file it was handed — same two quantities, opposite rule,
    decided by whether replacement is the event you are hunting or the event you are tolerating.
  - **Fix the sibling caches in the same pass, and rank them by what they hand the user.** The
    reported symptom was the *listing*; `ArchivePreviewCache` had the identical bug and is worse,
    because it hands over the previous archive's **bytes** under the new archive's member name, and
    `NestedArchiveRegistry.reusableMount` the same one level in. Grep for the archive path used as a
    dictionary key — all three were one `[String: …]` apiece.
  - **A missing file is a miss, never "unchanged".** Reading `nil` identity as "no change" would let
    a pane browse a deleted archive's ghost; treating it as a miss makes the re-read surface the real
    reason the file cannot be opened.
  - The tests need the negative control to mean anything, and it is cheap here: neuter the two
    identity checks, re-run, and confirm the three staleness assertions fail while the two
    "still cached when untouched" ones keep passing. The second half is what stops the fix from
    quietly becoming "re-read every time" — proved by withdrawing *read* permission after the first
    mount, since `stat` still answers while `bsdtar` could not open the file, so a second listing
    that succeeds could only have come from the cache.
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
- **A window-level completion handler has to name *which* pane it means, and the neighbor it was
  copied from is usually answering a different question.** An encrypted pack runs on the operation
  queue, so its outcome lands on the window rather than the pane that started it — and
  `presentPackOutcome` reached for `focusedPanel`, copied from the checksum outcome three files away.
  That is right *there*: a manifest is written beside the files it covers, so the focused pane is
  where it appears. A pack writes into the **other** pane, like F5 — so the finished archive asked
  the source pane to put its cursor on a file it does not contain, which fails silently, while the
  archive sat unselected in the pane that does. Nothing logs, the file is correct, and the only tell
  is a cursor that did not move — in the pane you are not looking at. The fix is to ask the question
  by *content* (which pane is showing this file's directory?) rather than by role, and to answer
  `nil` when neither is, since the user may have navigated both away during a job that runs for
  minutes. Same family as the two below: one question, two spellings, and the compiler checks
  neither.
- **A "can this apply here" predicate lives in *two* places — the behavior and the menu that gates
  it — and they drift silently.** Bringing size bars into the tree meant widening `areSizeBarsVisible`
  (drop `!panel.isTree`), and every core test, the app suite, both linters and the build passed with
  the bars fully wired — but the View ▸ Size Visualization menu item stayed **grayed out in a tree**,
  because `validateToggleItem` carried its own hand-copied twin of the same predicate
  (`… && !panel.isTree`). Nothing could catch it but launching: a disabled menu item swallows its own
  key equivalent too, so ⌃B was dead as well, and the feature was unreachable while every automated
  signal was green. When a mode gains a capability, grep the *selector's* validator for the predicate
  that used to forbid it — the enable/disable gate is a second copy of `areSizeBarsVisible` by
  construction, and the menu is the one surface no headless test drives. Same family as the "a display
  string that exists twice will be localized once" and "name the new backend at every site that lists
  the old one" traps: one rule, two spellings, and the compiler checks neither.
  - **The same rule can also be spelled *three* times and be wrong in all three from the day it was
    written — and then the missing feature is invisible, because there is nothing on screen to look
    at.** `parentRowCount`, `goToParent()` and the Go menu's validator each read
    `backend == .local`, so every **remote** pane had no `..` row, a dead Backspace and a grayed Go
    Up: SFTP since M5, FTP since M13, S3 since M21. The absent-feature shape is what makes it worse
    than the size-bar case above, where a *disabled* control at least admits something exists. Here
    the pane is a perfectly ordinary listing that is simply missing a row, and both remote listing
    parsers strip the server's own `..` (correctly — `sftp`'s `ls` emits `.` and `..`, FTP's `LIST`
    does not), so there was no accidental row to fall back on either. Found by connecting and walking
    into an **empty** folder, which is the case that removes every alternative at once: zero rows, so
    nothing to double-click; Backspace dead; Go Up gray; only the crumb, and only if you think to
    look up.
  - **The fix is a name — `canGoToParent` — and it is worth noting *which* name.** The tempting one
    is `backend == .local || backend.isRemoteConnection || isArchive` written out once and left as an
    expression; what makes it hold is that the two callers who cannot see each other (a row count and
    a menu validator) now ask a question rather than restate an answer. Note the narrowness the
    property has to keep and that a bare "does `parentPath` exist" would lose: a search snapshot's
    path *does* have a parent, and it is not somewhere to go.
  - **The third instance is the one that says when to look: a predicate whose behavior side has
    grown a *branch* has already drifted, and the drift is invisible until somebody adds a second
    one.** F4's key learned an archive route at M4 while `validateEditItem` went on answering
    `backend == .local`, so Edit was gray on every archive member and F4 dead there for the whole
    life of that feature; nobody noticed until M21 Slice 10 came to add a *remote* route beside it,
    which would have shipped the same miss twice. The tell is not a failing test — there is none —
    it is that the action is an `if`/`switch` over kinds while its validator is a single comparison.
    The fix is the same shape as `canGoToParent`, one step further: `editRoute(for:)` returns *which*
    route, so the key switches on it and the validator asks only whether it is `.unavailable`. A
    route added later cannot reach one without the other. Pin it by driving the **real** validator
    against a pane whose cursor stands on the entry — re-stating the route's own rule in the test
    passes however far the two have drifted, which is exactly the failure being guarded against.
  - **The fourth is a *resolver* rather than a validator, and it fails while the surface next to it
    looks perfect.** "Where are this row's bytes on disk" is asked by two things — the Quick View
    surfaces through `quickViewSourceURL`, and the `QLPreviewPanel` data source through its own
    `quickLookURL(for:)` — and M21 Slice 10 taught the first about servers and left the second
    knowing only about this Mac and about archives. So ⌘Y on an S3 object spent the download (the
    key does ask for one) and then drew Quick Look's **“No items selected”**, a foot away from an
    in-pane preview of that same row rendering correctly. Two things generalize past it. The tell
    that a resolver has a twin is a `switch`-shaped chain over *backends* in a file that is not the
    one the feature lives in — grep for the predicate the new branch added (`isRemoteConnection`)
    and read what else answers the same question in a different file. And the fix is a **deferral**,
    not a third branch: the second site hands everything but the trivial case to the first, so there
    is one definition and the next backend cannot miss it.
    - **A row whose bytes are already cached is what isolates it in one keystroke.** With the copy
      on disk the transfer is out of the question entirely, so an empty panel can only be the data
      source; without that step the obvious reading is that the fetch failed, which is a different
      hunt. Reach for it whenever a surface fed by a transfer looks broken.
    - **Nothing automated can see this class**, and it is worth being explicit about why: the panel
      is Apple's window, the data source's answer is never rendered by us, and both suites plus both
      linters were green throughout. It took pressing the key — the one the app's own placeholder
      card names in its hint, which is the detail that makes the failure read as a lie rather than
      as a limitation.
  - **The fifth disagreed in *both* directions at once, which is what a routing backend makes
    possible: `backend.capabilities` and `backend.capabilities(for:)` are two different questions and
    both spellings compile everywhere.** F2's and ⇧F2's flows guarded on the first — the
    `CompositeBackend`'s backend-wide set, which is *always* the local backend's — while
    `validateMenuItem` asked the second, the set of whoever owns the current path. So on a connected
    bucket File ▸ Rename… was gray while F2 renamed the object perfectly, and in the merged iCloud
    listing the item was **enabled** over a flow that returned in silence, because those rows are
    ordinary local files (local capabilities) inside a listing with no directory of its own. One
    predicate (`canRenameHere`, carrying `!isVirtualDirectory` as its second half) is the fix; the
    tell to grep for is a `capabilities` with no `(for:)` in a file that also knows about `panel.path`.
    - **A capability withheld from a backend that has the verb reads as a decision and is usually a
      miss.** `S3Backend` advertised `[.read, .write]` with `moveItem` implemented and a live bucket
      full of objects renamed through the UI. FTP and SFTP have carried `.rename` since they shipped,
      so the *asymmetry between backends* is the cheap scan — not the capability's own doc comment,
      which will happily explain a gap nobody chose.
    - **A negative control that presents a window wedges the suite instead of failing it, and that is
      worse than no control.** `beginMultiRename` ends in `presentAsMovableWindow`, so the reverted
      version put an app-modal window up in the test host: the run never finished and `xcodebuild`
      had to be killed at ten minutes, which reads as broken infrastructure rather than as the
      regression it is. The F2 half is drivable because `beginRename` sets `renamingEntryID` before
      it touches a view — but **only with `loadViewIfNeeded()` first**: `tableView` is a stored
      property, so an unloaded pane has one with no columns, and a flow that wrongly got past the
      guard returns at `nameColumnDisplayIndex` instead, leaving the assertion green. Measured both
      ways; without that one line the whole suite passes against a deliberately reverted flow.
    - **The pane's own routing is the instrument, and a `LocalBackend` pane cannot see this bug at
      all** — it answers its own capabilities for every path, so both spellings agree and any test
      built on one passes however far they have drifted. Build the pane on a real `CompositeBackend`
      and register the connection; that touches no network.
  - **The sixth is the whole family at once, and it says what the tell really is: a *results tab* is
    a pane whose rows live on a different backend than it does, so every property that resolves "the
    row under the cursor" has to ask the row.** M22 opened on the premise that a search hit is
    reached "exactly as a local one is, with no work", because a results tab's container is the
    synthetic `search:` path while every entry carries its real `VFSPath`. That is true of the paths
    and false of the four properties that resolve them, each of which asked `panel.path.backend`: ⌃Q
    drew **nothing** on an archive or server hit, ⌘Y reported **“No items selected”**, ⏎ inside a zip
    did nothing whatsoever, and F4 said the file could not be edited — all four about rows the
    *browse* route handles perfectly, and none of them reachable until a search could walk something
    other than this Mac. The fix is four one-line changes (`previewableArchiveMember`,
    `remoteFileUnderCursor`, `previewsCursorFileOnly`, `isWritableArchiveMember`); the finding is
    that it was **four**, having been found and fixed at a fifth site (`extractionArchivePath`, F5)
    one slice earlier without anyone asking what else shared its shape.
    - **A route decided in one file and undone in the file it calls is the sub-shape to watch.** ⏎
      and F4 both route by `entry.path.backend` — correctly, and had done for milestones — and then
      handed the entry to `openArchiveMember`, whose *own* guard read the pane. So the routing was
      right, the callee was wrong, and grepping the router finds nothing.
    - **Each fix's narrowness control is the one that matters more**, because the failure it could
      introduce is the opposite one: answering for an ordinary *local* results tab would send every
      Spotlight hit down the extraction or download path. All four are unit-testable with no window
      — build a pane on the `search:` path holding one hit and read the property.
  - **The seventh is the same family arriving on a gate that had *already* been fixed once, which is
    what says the fix has to name the subject rather than the site.** `canRenameHere` was corrected
    in Slice 10 from `backend.capabilities` to `capabilities(for: panel.path)` — the right *object*,
    still the wrong *subject* — so once trees could be rooted anywhere, F2 three levels inside an
    expanded bucket in an S3 **account** pane did nothing at all, the gate answering for the account
    (whose rows are buckets, which nothing renames) whatever the cursor was on. Reported 2026-08-22.
    The gate is now the row's own directory, which is what `performRename` had always built the
    destination in (`source.parent`); the two had simply never been asked to agree.
    - **Its other half was a listing flag standing in for a row property, and naming the property
      widened the feature for free.** `!isVirtualDirectory` was in the predicate for one honest
      reason — the merged iCloud listing draws an **app's** name over its `Documents` folder — and it
      refused every ordinary row standing beside those: a loose file in the same listing, a search
      hit, a row inside an expanded folder in either. `FileEntry.nameMatchesPath` says the thing that
      was actually meant, and it is false for exactly one row in this codebase, the one
      `ICloudDrive.libraryRow(for:stat:)`'s own comment already calls out as the single place where a
      row's name and its path disagree. The three refusals that had shared that flag now each state
      their own reason — an archive member and an account's buckets by the capability, a trashed item
      by the `.rename` a trash withdraws — which is what makes the next one findable.
    - **Widening a gate to a listing that cannot refresh itself brings its staleness with it.** A
      search snapshot re-lists nothing by design (`refreshCurrentDirectory` returns; `refreshTree`
      deliberately skips a results root), so renaming a hit would have left the row drawing a name
      that is no longer on disk — the exact symptom the S3 bug was reported by, reintroduced by the
      fix for it. One substitution (`substituteSearchHit`) closes it, and it is a substitution rather
      than a re-`stat` because a hit can be on a server. Worth asking of any gate being relaxed: can
      the surface behind it show the result?
    - **A rename inside a Trash is the one place "everywhere" had to mean *less*.** Put Back is keyed
      on the item's name in the trash — the origin lives in that folder's `.DS_Store` as a
      `ptbL`/`ptbN` pair looked up by it — so renaming a trashed item orphans the record silently and
      permanently. `.rename` is withdrawn alongside `.trash` in `capabilities(for:)`, which covers
      the merged listing, a pane standing in `~/.Trash`, a volume's `.Trashes` and a tree over any of
      them in one place; Finder refuses the same gesture.
- **The eighth is a *refresh* rather than a gate, and it says what the family's real subject is: the
  question is not only "who decides" but "who re-reads".** `refreshTree` re-listed every directory
  the tree holds with `DirectoryLoader.list`, which is not how half of them were produced — a
  **bucket row** hangs under an `s3account:` path, and `S3AccountBackend` answers for its root and
  nothing deeper by design, so the re-read threw `notFound` into a `try?` and the row simply kept the
  entries it already had. Reported 2026-08-22, one bug after the two above: the rename now worked
  perfectly on the server and the pane went on drawing the old name for the rest of the session.
  - **It is invisible in every direction at once**, which is what makes the refresh a worse home for
    this shape than a gate. Nothing logs, every request succeeds, both suites and both linters are
    green, and the *screenshot is of a correct listing* — just not of the bucket. And it is the whole
    funnel, not one gesture: F7, F8 and the queued rename an S3 prefix becomes all reach
    `refreshCurrentDirectory`, so "the view doesn't update" was true of every write in an expanded
    bucket.
  - **The fix is to re-read through the funnel that produced the rows** (`treeChildEntries`), not to
    add a branch to the refresh — the same rule this file keeps restating for *decisions*, applied to
    a re-read. The audit it suggests is cheap and worth running whenever rows can come from somewhere
    a listing cannot: grep the refresh path for `list(` and ask whether every row it covers was
    listed that way.
  - **Routing a refresh through a funnel that *connects* is where it costs something**, and the cost
    is not the request everyone would guess. Reconnecting to a bucket that is already open spends a
    second billed probe (`probeConnection` is a `ListObjectsV2` of the same root), re-files the
    secret in the Keychain and re-registers the backend — side effects a passive refresh has no
    business having. There is no session to keep alive on S3, so the root a connection settled on
    stays listable: record it where the rows were recorded (`PanelTab.s3BucketRoots`, the shape
    `mergedSources` already had) and re-list it, falling back to the full connect when that fails so
    a dropped registration heals rather than becoming a row that never refreshes again.
  - **A record of "where these rows came from" is also what makes the whole path testable with no
    network**: point it at a real local directory, rename a folder inside it, and drive the real
    `refreshTree`. Reverted, the test fails with `names → ["test3"]` — the reporter's screenshot,
    verbatim — while the narrowness control (an ordinary local child is still re-read by listing it)
    keeps passing, which is what stops the fix from becoming "everything is a bucket".
- **The ninth is not a gate and not a re-read but the *act*, which is the half a shared decision does
  not cover on its own.** F4 has asked `editRoute(for:)` since M21 Slice 10 — the function this list's
  third entry is about — and **⇧F4 never called it**: whatever its dialog resolved went straight to
  `openInEditor`, whose `localURL` is `file://` plus the path *inside* the backend. So ⇧F4 on an S3
  object asked macOS to open `/test2.txt`, Finder answered that the file couldn't be found, and
  nothing was downloaded, while F4 on the same row worked perfectly. Reported 2026-08-22.
  - **Extracting the decision is what made the act's copy invisible.** `editRoute` was pulled out
    precisely because a key and its menu validator had drifted, and it fixed both of *those* — so the
    file reads as having one rule, and the third caller sitting two hundred lines below simply never
    joined. The tell is a `switch` over the routes in one function and a bare call to the local-only
    verb in another; grep for what the `.local` branch calls, not for the enum.
  - **Two call sites, and only the first is ever in the report.** ⇧F4 opens a name that is already
    there *and* creates one that is not, and the create half reads as working for longer — the object
    really does appear on the server — before it hands the editor a path that has never existed.
  - **A created file has to be read back rather than assumed.** The route is decided from an *entry*,
    and a remote one's fetch and its later save-back are keyed on the size, time and entity tag only
    a `stat` carries (`RemoteFileRevision`), so a hand-built stand-in saves one round trip and makes
    the very first save look like somebody else's write.
  - **The observable in the test is the status *token*, not the message.** `openInEditor` shows
    "Opening …" before it launches anything, which is what makes the flow testable with no editor
    ever opening — but a transient message clears itself after four seconds and the reverted build's
    doomed `NSWorkspace` launch takes about **sixty** to fail, so the expiry wins that race and the
    line reads `nil` again by the time anything asks. Measured on the control: `token=1` in both
    tests, `status=nil` in one of them. A self-clearing observable is not one; count instead.
  - **A neighbour's suite failed beside this one and the accusation was wrong** — the diagnosis and
    the fix are under ▸ Testing, "a test that measures *whether anything repainted*". The lesson to
    carry from this end is the control: **run the baseline before believing your change caused a
    neighbour's failure**, because "it was green before" measures the machine as much as the code.
    Here two new 2 s-holding tests failed 3 full runs of 7 while the suite passed alone every time,
    which is a convincing-looking case; with both new files *skipped*, the same machine still failed
    1 run in 4. **And a three-run baseline is not a baseline**: measured again
    2026-08-26 while adding the remote poll, the same suite was 3/3 green with the change stashed and
    then 5/6 on a longer run of the *identical* tree — so the first control "cleared" the baseline and
    sent two plausible causes to be fixed before a six-run one showed the failure was there all along.
    Match the number of baseline runs to the failure rate you are trying to see, not to your
    patience.
- **The tenth is "which pane do I re-list", and it is the eighth's question asked from the *window*
  rather than from the pane.** The remote write-back finished its upload and called
  `refreshPanesShowing(path.parent)`, whose predicate was `pane.panel.path == directory` — the same
  sentence as "is this pane showing that folder" in a flat list, and not in a tree. An S3 object
  edited from an **account** pane with its bucket expanded has its parent two levels below the path
  being compared, so neither pane matched, nothing refreshed, and the row went on reading `Zero KB`
  with the old date for the rest of the session (reported 2026-08-22, immediately after the same
  day's rename and refresh fixes). Everything else was right: the `PUT` landed, the re-baseline ran,
  the server had the file.
  - **The rows are the subject, and the tree's own listing keys are the trap that looks like the
    fix.** `TreeProjection.listings` is keyed by the **row** that was expanded, which is not always
    the directory it holds: an expanded bucket files its children under `s3account:/<bucket>` while
    every row inside carries `s3://…`, so matching `listedDirectories` still answers no. Deriving the
    set from each displayed entry's own `path.parent` is what answers, and it needed measuring rather
    than reasoning — the listing-key version *passes* the same test written over a local tree, which
    is the version a first pass would have shipped (both controls run: pane-path-only fails 2 of 4,
    listing-keys fails 1 of 4, and the one it fails is the reported shape).
  - **Keep the pane's own path in the union whatever the rows say**, because an empty directory has
    no row to derive it from and is exactly where a create lands — a rows-only answer leaves the pane
    showing an empty folder un-refreshed by the work that fills it.
  - The sibling sites were checked rather than converted on principle: the **pack** outcome's
    `paneShowing` is safe because a pack writes to `destinationPane.panel.path`, so its destination
    *is* the pane's own path by construction, and the **archive** write-back keys on
    `backend.archivePath`, which every row in a browsed archive shares. Only the site whose
    destination can be a directory the pane merely *draws* needed the wider question.
- **A "can this apply here" gate can be testing the wrong *subject* entirely, and it then reads as a
  considered restriction rather than as a bug.** `canUseTreeMode` was `panel.path.backend == .local`,
  under a doc comment explaining that a per-level lazy listing "needs a real directory to read" —
  true of each **row**, which is what gets expanded, and never true of the pane's own path, which is
  what it tested. Nothing in the machinery agreed with the restriction: `DirectoryLoader.list` goes
  through `CompositeBackend`, which routes per path, and `TreeProjection` recurses into each entry's
  *own* path (`listings[entry.path]`) without ever assuming a row descends from the root. So a merged
  iCloud row, a bucket, an SFTP directory and a folder inside an archive were all expandable the
  whole time, and widening the gate needed **no core change at all**. The tell is a gate whose stated
  justification describes the rows while its expression reads the container.
  - **It failed as a *dead end* rather than as an absence, because the shape outlives the gate.**
    `Panel.setModel` re-roots a tree across a navigation instead of dropping one, and
    `installResults` — the in-place install a merged listing uses — never called `applyViewMode`, the
    one funnel that reconciles the two, while its own doc comment claimed "everything a `navigate`
    does for the pane's chrome happens here too". So clicking the sidebar's iCloud row while in tree
    mode left `panel.isTree == true` where `canUseTreeMode == false`, and the validator draws its
    **checkmark from the pane's real shape and its enablement from the gate**: ticked *and* gray,
    rows still drawing disclosure triangles, with no way to answer it — the command ships unbound, so
    the menu is the only route, and a bound shortcut would have been dead too (a disabled
    `NSMenuItem` swallows its own key equivalent, above). Reported by a user 2026-08-17. "Checked and
    disabled" is worth its own assertion: it is a setting nobody can switch off, and no test of
    either half alone can see it.
  - **Widening a gate makes reachable every hazard it was masking, and none of them are in the
    diff.** Tree watching had two, both harmless while trees were local-only. `startWatchingTree`
    asked `backend.capabilities` — the composite's *backend-wide* set, i.e. the local backend's,
    which is the `capabilities` vs `capabilities(for:)` trap above — and `treeWatchSources` handed
    `listedDirectories` to FSEvents **including the tree's root**, which for a merged listing is
    `icloud:/iCloud Drive` and on a server is an `sftp://` path. Neither logs: the stream simply
    watches nothing.
    - **The filter has to test the path for `.local`, not its capabilities for `.watch`.**
      `CompositeBackend.capabilities(for:)` answers the local backend's *full* set for the merged
      iCloud container — deliberately, since its entries are ordinary local files — so the
      principled-looking capability test is precisely the one that lets the synthetic path through.
    - What a merged root *can* watch is what the **gather** read (`mergedSources`), which is what
      list mode already watched. A tree over one watches those plus its expanded children, and the
      gather has to re-list those children when it re-produces the root: it only ever owned the top
      level, so without that the deeper rows keep drawing what they had.
  - Both halves have sharp negative controls, which is what makes the suite evidence rather than
    decoration: restoring the old gate fails only the reach tests, and restoring the unfiltered watch
    sources fails only the watch tests — printing `icloud:/iCloud Drive` and the `sftp://` path as
    the values it would have watched.
  - **The third hazard arrived a user later, and it is a row the tree can *draw* but not *open*.** A
    disclosure triangle is `entry.isDirectoryLike`, which a **bucket row** in an S3 account pane
    satisfies — while `S3AccountBackend` answers for its root and nothing deeper, by design, since
    everything below a bucket is the `S3Backend` that already ships. So `DirectoryLoader.list` on
    `s3account:/<bucket>` throws `notFound` straight into `loadTreeChild`'s `try?`, and the row opens,
    stays empty and says nothing: no log, no failed test, and a triangle promising children that
    cannot come. The thing missing is not a listing but a **connect** — a bucket's contents are
    reached by connecting to it, a gesture the tree had no way to make. Generalizes past S3: when a
    gate widens to *everywhere*, the rows to check are the ones opened by some verb **other than**
    `listDirectory`, because those are exactly the ones that draw perfectly and answer nothing.
    - **The fix is to split the connect from the navigation welded to it** (`establishS3Connection`),
      never to teach the tree a second way to open a bucket: the region-301 correction and the
      path-style retry apply to `→` for the same reasons they apply to Enter, and a second spelling of
      them is this file's most repeated bug.
    - **A child on another backend then retires the path arithmetic above it.** `←` climbed by
      `entry.path.parent`, which is the same answer everywhere a child descends from its parent and no
      answer at all where it does not — the parent of `s3://…/docs` is `s3://…/`, while the row above
      it is `s3account:/…`. Walk the rows by **depth** instead: it is what the tree actually draws, so
      it cannot disagree with what ← looks like it should do.
    - Live-verifiable headlessly, which is worth reaching for before a screenshot: driving the real
      controller against the real account inside the app's own test target reproduces the reverted
      version's failure in the reported shape — the expanded set holding the bucket and the listings
      holding only the root.
- **A *saved* search is the one place where the scope, not the pane, decides where a search runs, and
  an `mdfind` scope is a bare path with the backend thrown away — so what it silently did depended on
  how deep the scope was.** `FileQuery.mdfindArguments` takes `scope.path`. A saved search rooted at
  a **backend root** — every archive root, every bucket root, every server home — spells that `"/"`,
  so it ran `mdfind -onlyin /`: measured in the built app, "Zip reports" (saved inside a four-file
  zip) came back with **1275 hits** from `/System`, `/Library` and the crash logs, in a tab wearing
  the name the user gave it; `mdfind -onlyin / 'kMDItemFSName == "*report*"cd'` at a shell reproduces
  the number exactly. One level down (`/2026`, `/docs`) the same call answers **zero**. Both are the
  quiet direction and the **root case is the worse one**, which inverts the natural expectation: an
  empty pane at least reads as an answer about nothing, where a full one reads as an answer about the
  thing you asked for.
  - **It is invisible to every headless signal and to any test of the routing function**, because the
    bug is the app *not calling* it. The instrument is the built app with the fix reverted, clicking
    the same sidebar row — 4 hits against 1275 — which is also the only way to learn that the failure
    is a false *superset* rather than an empty set.
  - The general form, and the reason it belongs beside the entries above rather than under
    localization or search: **a persisted `VFSPath` is a path *and* a backend, and every consumer that
    reduces it to `.path` has silently re-pointed it at the local disk.** Grep for `\.path` on a value
    whose type is `VFSPath` — that is the whole audit, and the compiler sees a `String` on both sides.
- **Tree size bars are one directory per *level*, so the sizes have to live where the rows do.** The
  flat `SizeVisualization(model:)` reads one directory's siblings; a tree's rows span many, and its
  totals cannot sit in `DirectoryModel.directorySizes` — that map is pruned to the *root* listing on
  every refresh (`updateListing`), so a child sized at depth 2 vanished on the next FSEvents ping.
  `TreeProjection` grows its own cross-level `directorySizes` (unique paths, one flat map, handed to
  each level's `DirectoryModel` which prunes it to that level), and `Panel.computedSize`/`directorySizes`/
  the setters dispatch on `tree != nil` so the size *column* and the *bar* read one answer. Entering
  the tree seeds from the model (`freshTree`), leaving it merges the root level back
  (`exitTreeMode`) — the deep totals are dropped there on purpose, since the flat list has no row to
  hang them on and a stale one would resurface. The visible win, and the thing to check in a
  screenshot: an expanded folder's largest child fills its bar even when a root-level sibling is
  4× bigger — proof the denominator is the *parent*, not the projection. A whole-tree denominator
  cannot express it (a child's bytes are a subset of its parent's).
- **Reusing a flat rule per level is right for *ordering* and wrong for *filtering*, and the tree
  shipped with both.** `TreeProjection` deliberately projects each level through a `DirectoryModel`
  so sort, hidden and filter cannot fork from the list — correct for the first two, and for the
  filter it deleted the feature: `appendLevel` recursed only into entries that survived their own
  level, so a folder whose *name* missed the filter took every matching file under it off screen.
  Typing `report` in a tree hid `docs/` and with it `docs/report.pdf`, which is the only query
  anybody types. The rule that works is the one every outline filter uses — an entry survives if it
  matches **or if anything beneath it does** — and the honest framing is that a folder is not a
  peer of its contents: filtering it on its own name filters *the path to* the results, not the
  results. Three things worth carrying:
  - **The shipped tests pinned the bug's good half and not its bad half.** Both filter tests set up
    a parent that *matched* (`filter = "doc"` over a folder named `docs`), so they exercised
    "children filter out under a matching parent" and never the inverse. The asymmetry is easy to
    write without noticing, because the matching-parent case is the one you reach for when naming a
    fixture. Name the fixture for the query (`report.pdf` inside `docs/`), not for the folder.
  - **It is invisible to every automated signal.** 1634 core tests, 215 app tests and both linters
    were green while the filter was unusable in a tree; nothing logs, and the pane shows *a*
    plausible answer (fewer rows) rather than an empty or broken one. Same quiet-direction family as
    the size-bar menu validator — and, like it, only reachable by doing the thing a user does.
  - **"Only expanded folders can rescue an ancestor" is what keeps it a filter.** Reaching into
    unlisted directories would put I/O on a keystroke, which is search (⌘F), not a filter — so a
    collapsed folder rescues nothing even when its listing is still cached, and collapsing the
    folder that carried the only match makes it disappear. Verified live: the scaffolding row went
    away on the collapse, and clearing the filter brought the whole tree back with the expansion
    exactly as the user left it.
  - **Scaffolding splits "how many rows" from "how many did I find", and a status line needs both.**
    Once a folder can be on screen without matching, `rows.count` stops answering the question a
    filtered pane is asked — `Filter “dscf” · 7 items` over six files and the folder they were found
    in. Hence `TreeRow.matchesFilter` and `TreeProjection.matchCount`, equal to `count` in a flat
    list and in an unfiltered tree so only the case where the distinction is real ever differs. The
    rule for choosing between them: **a reporting number counts matches, an addressing number counts
    rows.** So the marked branch of the same status line deliberately keeps counting rows — marks
    land on scaffolding like any other row, and F5 copies the whole folder, so counting matches there
    would under-report the work in the one direction that costs the user something. The two lines are
    allowed to disagree across a ⌘A (`6 items` → `7 of 7 selected`); what is not allowed is a summary
    of an operation that is smaller than the operation.
- **A tree splits "the current directory" into two questions, and every write was answering the wrong
  one.** F7 New Folder, ⇧F4 Edit File and both pastes (⌘V / ⌥⌘V) all targeted `writeDirectory` — the
  pane's real on-disk directory — which in a *flat* list is also "where the cursor is", because every
  row of a flat list lives in it. That equivalence is what made it invisible: the two questions had the same
  answer for the whole life of the app, so nothing marked which one each site meant. A tree draws
  several directories at once, so with the cursor three levels down both keys created back at the
  **root** — the new row landed off screen or not at all, and New Folder's dialog said "Create a
  folder in *<root>*" while the user was pointing somewhere else entirely. It fails in the quiet
  direction: a folder really is created, the pane really does refresh, and the only tell is a name in
  a sentence nobody reads twice. Split it — `Panel.cursorDirectory` (core, pure, tested) answers
  *which* directory the cursor's row lives in, and `writeDirectory` goes on answering *whether there
  is a real one at all*, which is the only one that can be `nil`. Three things fell out:
  - **The displayed name is a third question, and folding it into the target regresses iCloud.** A
    dialog names *what the pane shows*, so the merged iCloud listing must keep saying "iCloud Drive"
    and never "com~apple~CloudDocs" — the target and its name coincide only in a tree, which is the
    one case where the pane genuinely draws the deeper folder with a row of its own. Swapping
    `panel.path.lastComponent` for the target's own is the obvious edit and is wrong everywhere else.
  - **The refresh needed nothing.** `refreshCurrentDirectory(selecting:)` already routes a tree
    through `refreshTree(selecting:)`, which re-lists every listed directory and lands the cursor on
    the target by identity — so a row created at depth 2 appears at depth 2 with the cursor on it, for
    free. It was written for a *rename* landing in a child; a create in a child is the same shape,
    which is the payoff of having one refresh funnel rather than one per operation.
  - **Reconcile the cursor before reading it.** The table's selection is the live cursor until its
    change notification fires a runloop pass later, so a write invoked straight after an arrow key
    reads the row the user just left. In a flat list that error was unobservable — both rows have the
    same parent — and in a tree it is a different *directory*. Every tree key already does this; a
    command that only became cursor-dependent now has to as well.
  - **A guard written for one shape becomes reachable in another.** `pasteRecurses` — refuse a paste
    whose destination is inside the source's own subtree — was written for the flat list, where it
    could only fire across panes; a tree makes it a *single-pane* gesture, since ⌘C a folder and then
    putting the cursor inside it is one arrow key away. It held (verified live: nothing was created,
    nothing logged), which is the point — the audit worth doing when a destination widens is over the
    guards that already constrain it, not only over the sites that compute it.
