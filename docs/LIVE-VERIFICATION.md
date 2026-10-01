# Live verification

Traps met while checking a change in the running app. CLAUDE.md loads this file in every session,
so a trap goes here only if it can bite any live run; one tied to an area goes under that area in
[NOTES.md](NOTES.md), which is read by area. Moved out of NOTES.md on 2026-10-01.

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

- **A measurement about a *TCC-shaped* behaviour needs its fixture chosen as carefully as its
  launch, and this Mac happens to carry the control already.** M26's whole subject is that
  `FileManager.trashItem` refuses an item inside a File Provider domain only when the app is its own
  TCC responsible process — so the run has to be LaunchServices-launched (`open`), since a
  shell-launched build borrows the terminal's grant and passes whatever the code does. That much is
  recorded in NOTES.md ▸ The Trash. The half worth keeping *here* is the fixture: with the fix, F8 deleted
  **6 of 6** across Box, OneDrive, Dropbox, streaming Drive, mirror Drive and iCloud; with
  `LocalBackend`'s default performer reverted, **1 of 6** — and the one that survived is the point.
  **Google Drive in *mirror* mode is a positive control that costs nothing**, because
  `<mount>/My Drive` is a symlink out to `~/My Drive`, so a file "in Drive" is an ordinary local file
  outside every domain and takes `trashItem` in *both* builds. Had it failed alongside the other
  five, the run would have been measuring a broken app, a bad path or a wedged AppleScript rather
  than the routing; passing in both directions is what makes the other five a measurement of the
  provider branch and nothing wider. Two Drive accounts of different modes is not a setup anyone
  arranged — check what the machine already has before building a control.
  - **The gesture is drivable headlessly because move-to-Trash does not confirm.**
    `AppPreferences.confirmTrash` defaults **off** (it is an opt-in "Ask before moving items to
    Trash"), so `deleteSelection` reaches `runDelete` with no sheet — which is the difference between
    this and the family above that ends in a sheet nobody can click. `reveal "<path>"` then
    `run operation "file.trash"` over the `.sdef` verbs runs the whole shipped path per item. Read
    the preference before assuming a delete is unreachable; ⇧F8 and every *permanent* delete do
    confirm, and are not drivable this way.
- **A second copy of the app with the same bundle id is the stale-binary trap wearing different
  clothes, and it fails as a *confident false negative*.** Measured 2026-09-10: with the DerivedData
  build correctly quit and rebuilt, launching by **name** (`open -a Dirnex`, or a computer-use
  `open_application`) started **`/Applications/Dirnex.app`** — an older *release* build LaunchServices
  resolves the name to — which then reproduced the exact bug under test, on the exact fixture, with
  the exact pre-fix alert. Every automated signal was green and the screen said the fix did not work.
  The two tells were both on screen before anything was checked: the alert's **wording** named the
  wrong error (`archiveExtractFailed`, "Couldn't extract from the archive", where the fix routes on
  `entryNameNotUTF8`), and the pane drew the legacy row as **pure octal escapes** where the current
  build draws escapes mixed with U+FFFD — i.e. it predated ``ChildProcessLocale`` and ``SubprocessText``
  entirely. `pgrep -lf "Dirnex.app/Contents/MacOS/Dirnex"` answers it in one line. **Launch by path**,
  and read the path back rather than trusting that a quit-and-relaunch settled which binary is up.
  - **An AppleEvent addressed by bundle id will *launch* that copy if the Debug build has died,
    and the event itself does not say so.** Measured 2026-09-14: the Debug build crashed while
    showing a preview, the next `tell application id "com.dirnex.Dirnex" to reveal …` timed out
    (`-1712`) and left `/Applications/Dirnex.app` running in its place, and a screenshot taken
    afterwards was of the release build. A timed-out event, or a window that looks like the
    pre-change app, is the moment to run the `pgrep` above and to check
    `~/Library/Logs/DiagnosticReports` for a crash report before believing anything on screen.
- **computer-use's `=` and `-` are the *keypad* keys, so it cannot type ⇧⌘= as a keyboard does.**
  Logged 2026-09-15 with a temporary local key monitor while verifying the zoom keys: `cmd+=` arrived
  as keyCode **81** (keypad `=`) and `cmd+-` as **78** (keypad `-`), both with the numeric-pad flag.
  `cmd+shift+=` arrived as keypad `=` with Shift set and characters still `=`, where a real ⇧⌘=
  (keyCode 24) carries `+`, so a test of the shifted spelling through the tool measures nothing.
  Two ways around it did not work either. `CGEvent.postToPid` from a shell was dropped without a
  trace (0 events reached the monitor), and System Events keystrokes need assistive access the shell
  lacks (`-1719`). Log the event before believing a key test, and settle what a real key
  would send with `NSMenu.performKeyEquivalent` on a hand-built event.
  - **Its Escape never reaches the app at all while it holds the screen.** Logged 2026-09-30 with a
    local `.keyDown` monitor on the M29 update notice: Return (36) and Space (49) arrived, while
    `Escape` and `esc` produced no event whatsoever, three times. The full-screen takeover keeps
    Escape for itself. So a live check that **Escape does nothing** passes whether or not the code
    works, and one that **Escape closes** fails whether or not it works. Slice 4's "Escape leaves the
    reminder up" was the first kind. Pin Escape with a test instead (`AlertKeyCatcher.button(for:)`,
    or `NSApp.sendEvent` on a hand-built event in a harness, which answered it on the same alert).
- **`sips -s dpiWidth 72` on a JPEG exits 0 and leaves the old resolution.** Measured 2026-09-15 while
  making image-zoom fixtures: a 3000 px copy of a 240 dpi photo read back `dpiWidth: 240` after the
  call, in place and with `--out` alike, while the same call on a PNG took. An image preview sizes by
  `NSImage.size`, which is in points from that resolution, so the "large" fixture was 900 pt and
  opened at its own size rather than fitted, which looks like a broken fit. Read `sips -g dpiWidth`
  back after setting it, or make the fixture a PNG.
- **Background computer-use cannot press Return in a text field; it sets the field's selected text
  to a newline, which commits nothing.** Measured 2026-09-13 in Go ▸ Go to Location… while verifying
  M28 Slice 2: `app_key return`, aimed at the focused element and then at the field's own coordinate,
  both reported `set AXSelectedText="\n"`, and the pane stayed where it was with the path still in
  the field. The `.sdef` route worked first time: `reveal` a file *inside* the folder (an empty
  folder needs a marker), which points the active pane there. Reach for the AppleScript verbs before
  a synthetic key whenever a field has to be committed.
- **An accessibility element index goes stale as soon as the tree changes, and the click then lands
  somewhere else.** Measured 2026-09-13 while pressing Stop on a running copy: `app_ax_find` named the
  queue bar's "Cancel all" as element 37, and a click on element 37 seconds later landed on a sidebar
  row instead, because the window's tree had changed in between. The copy ran to the end and spent the
  iCloud-only clip it was there to test. The same button clicked by window coordinate went through as
  an `AXPress` on "Cancel all". Click anything that is updating by coordinate, and read the tool's own
  report of what it pressed before trusting the result.
- **Fully quit a running Dirnex before relaunching.** `open` re-focuses the stale process, so
  new menu items and behavior silently don't appear. A Debug build's code lives in
  `Dirnex.debug.dylib`, not the thin executable — grep the dylib to confirm new code actually
  compiled in. `xcodebuild` writes to `~/Library/Developer/Xcode/DerivedData/`, not the repo's
  `build/`.
  - **A grep for a Swift name can miss code that is there.** The mangler replaces a word the
    symbol has already spelled with a back-reference, so `CloudPlaceTitle.iCloudContainer` has no
    `Cloud` after the type's own and `strings`/`nm` counted **0** for `iCloudContainer` in a build
    that contained it (2026-09-16). `nm <dylib> | xcrun swift-demangle | command grep <name>` finds
    it. Grep for a string literal the change added, or demangle, before concluding a build is stale.
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
    would prove the two agree rather than that either is right (▸ the same rule NOTES.md states for
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
    trap NOTES.md records about `swiftc` defaults (▸ Swift 6 and concurrency, the delegate-witness
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
    app reconnects at launch since session restore learned to (NOTES.md ▸ Design lessons). Back the domain up
    with `defaults export` first, and `ssh-keyscan` the throwaway host key into `known_hosts` or the
    connect raises a trust dialog that wedges a headless run; put both back afterwards.

- **A speedup measured in the running app needs the slow path run *beside* it, and for a remote
  backend the server's own config is the cheapest way to arrange one.** Adopting
  `subtreeListing` in the sizer took a whole bar column over SFTP from 136 sessions to 9 — but "9"
  alone is a number with nothing to compare against, and a screenshot of correct bars says nothing
  about what they cost. Restarting the throwaway `sshd` with **`ForceCommand internal-sftp`**
  withdraws the exec channel, so the shortcut answers `nil` and the *same build* falls back to the
  walk: measured 2026-09-01, the identical bars and identical totals at **149 sessions** (eight
  refused execs plus 136 listings). One line of server config turns a measurement into an A/B, and
  it exercises the degradation path at the same time — which is the branch a live run over a healthy
  server can never reach.
  - Count `Accepted publickey` in the server's own log across the gesture, not requests in flight:
    it is the server's bookkeeping rather than the client's opinion, and the delta is immune to the
    pane's background poll drifting the absolute number (▸ the session-count warning above).
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
- **computer-use reports `AXError: failure` for a button that opens a sheet, and the sheet is up.**
  Seen twice on 2026-10-01 pressing Report a Bug…'s *Show What Will Be Sent…*: the AXPress came back
  as a failure each time, and a screenshot showed the preview sheet open. The press waits for an
  answer that a sheet presentation does not give in time. Take a screenshot before pressing again,
  or the second press lands on the sheet.
- **A transparent overlay from another app can gate every mouse click.** LanguageTool for
  Desktop did this for four passes; keyboard input still reached Dirnex, which masked it.
  Quitting the overlay app restored mouse verification.
