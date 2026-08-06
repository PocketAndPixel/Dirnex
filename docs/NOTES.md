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
- **A branch added beside an existing one in a key monitor inherits none of its carve-outs, and the
  carve-outs are invisible at the call site precisely because they were factored out well.** The
  Quick View monitor's Esc branch reads `guard escapeBelongsToQuickView` — one line, no mention of
  field editors — so the `1`/`2` branch written three lines below it shipped with no field-editor
  test at all: with a preview up, ⌘L and typing `/tmp/12` put **`/tmp/`** in the path field, both
  digits eaten, caret visibly in the text. It cannot be caught by a test that drives the monitor
  (the monitor did exactly what it was told) and it is invisible in every screenshot that does not
  include someone typing. When adding a branch to a monitor, **read the predicate the neighbouring
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
  (grey) without focus and emphasized (blue) with it, so "the row turns blue when I click it" is not
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
  - **The rules compile asynchronously, which makes them a precondition rather than a setting.**
    `QuickViewWebView` has no public initializer — `withContentRules` builds one only once the list
    exists, and hands back `nil` if it cannot be compiled, where the caller falls back to showing the
    file as text. A view built before the rules land would render exactly one page unprotected, and
    it is the quietest failure available: the preview looks perfect, and only a server somewhere else
    knows.
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
  machine has. Honour `NSEvent.isSwipeTrackingFromScrollEventsEnabled` rather than substituting your
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
    for a decision.** `SwipeStepper` was pure, and had 23 passing tests pinning behaviour that should
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
    decode per visit where `NSImage`'s own caching did not; adding an LRU store and neighbour
    prefetching on top brought it back to exactly par (13/13 against the plain path's 11/15), not
    better; and deferring the animation one run-loop turn so the texture lands first was worse again.
    A/B them in one binary behind an env var and alternate the runs — run-to-run variance is large
    enough that a single pair of runs will happily "prove" either direction.
- **`NSImageView` defends its image's size at priority 750, so a big image resizes the *window*.**
  An 8629 px panorama pushed the constraint chain outward until the window ran past the edge of the
  display and the function bar was cut off — while every frame *inside* the preview was provably
  correct, which sends you looking in the wrong place. Pin its compression resistance and hugging to
  the floor whenever it is a passenger in a layout rather than the thing being sized.
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
- **Right-click menu items must capture their paths at build time** into `representedObject`,
  and entry-vs-`..` must be decided from the clicked row, not a cursor flag — a right-click on a
  marked row leaves that flag stale.
- **Two colours separated only by alpha will invert somewhere.** A progress track and its ink
  drawn in the same colour at 0.25 alpha made an *empty* bar read as the heaviest row on screen,
  because the track owns the full column width where the ink may own a point. No test catches
  this; it was caught in a screenshot.
- **"Maximum contrast" is not the rule for text on a colour — the system does not follow it, and
  copying the system is what a user is comparing against.** Measured in both appearances before
  designing the M15 palette: `.controlAccentColor` is `#007AFF`, relative luminance **0.2114**,
  where white scores **4.02:1** and black **5.23:1**. So a WCAG-maximum rule picks *black*, while
  macOS — and Dirnex's own active tab chip, which puts `.alternateSelectedControlTextColor` straight
  onto the accent — draws white. A user who picked a blue barely distinguishable from the one they
  already had would have watched the app's most familiar surface flip to black text. The rule that
  works is **white unless it drops below 3:1, black otherwise**: 3:1 is the floor the system itself
  clears with room to spare, and whenever it *is* black's turn the background is above L=0.3, where
  black scores at least 7:1 — so it never trades legibility for familiarity, it only breaks the tie
  in the band where both choices are legible. Note the two are measured against *different* colours:
  AppKit's emphasized selection is `.selectedContentBackgroundColor` (`#0064E1`, L=0.1455), a darker
  relative of the accent and not the accent itself, and there white wins under either rule.
  - **The corollary is that the Follow-System path must fall back to the system colour, not derive
    one.** "An untouched install renders byte-identically" is only a claim you can make if nothing
    is recomputed for it, and the measurement above is exactly why: the derivation and the system
    disagree on the one colour that matters most.
  - **A derived foreground is appearance-independent, and that is the only way to claim "legible in
    both appearances".** Only one appearance is on screen at a time, so no screenshot can check the
    other; a luminance test over the user's own sRGB colour resolves identically under `.aqua` and
    `.darkAqua`, which is a claim a test can pin.
- **The `.system*` palette is tuned for *fills*, not for text, and in light mode most of it is
  unreadable on white.** "Use a system dynamic colour, it resolves per appearance for free" is the
  natural answer to any two-appearance colour problem — it is what M17 opened on — and it is only
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
  colour in dark, which keeps everything the system-colour answer was *for* (one colour object per
  role, resolving itself, no persistence, no Settings) while making the claim testable.
  - `.secondaryLabelColor` and `.tertiaryLabelColor` carry **alpha** (0.50 and 0.26 in light), so
    `usingColorSpace(.sRGB)` alone reports them as pure black at 21:1. Composite onto the background
    before measuring or the two most tempting "muted text" colours score wildly wrong — the tertiary
    one is really **1.88:1** in light and **2.26:1** in dark, i.e. unusable in both.
- **`NSTableView` makes a plain `NSTableRowView` when the delegate declines — in every one of its
  five styles.** Probed rather than assumed, and it inverted a design: a row-view subclass that
  defers to `super` is byte-for-byte the stock drawing, so it can be installed **unconditionally**
  instead of switched in only when a custom colour is set. Switching classes as a preference changes
  leaves a reuse pool of the other kind to reason about; deferring leaves nothing to get wrong.
  `interiorBackgroundStyle` is derived from `isEmphasized` (probed: `true` → `.emphasized`, `false`
  → `.normal`), so a custom `drawSelection(in:)` and the cell's own `backgroundStyle` are driven by
  the *same* flag and cannot disagree — which is what lets a cell pick its text colour without the
  row view telling it anything.
  - **Only the emphasized half is worth owning.** AppKit's *unemphasized* selection is a pure grey
    in both appearances — `#DCDCDC` light, `#464646` dark, zero saturation in each — so it discards
    the accent's hue on purpose, and in dark mode it is **darker** than the emphasized fill
    (L=0.0612 against 0.1175) rather than fainter. There is no relationship to re-derive: hand the
    inactive pane back to `super` and both panes keep the focus signal they already had.
  - A `swift`-script probe cannot make its window key, so `isEmphasized` reads `false` throughout
    and the two states cannot be told apart that way. Probe the *derivation* (`isEmphasized` set by
    hand on a detached row view) and leave the focus behaviour to the app that already ships it.
- **A source list's selection is the same `drawSelection(in:)` — but the shape is a pill, and the
  probe that measures it needs its own override to exist at all.** Owning the sidebar's cursor colour
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
    into a `CGLayer` and painting the colour through its alpha (`.sourceIn`) looks like the
    shape-proof answer and came out **half a point wide on each side** — a fatter pill than AppKit's.
    The hand-drawn path matched more closely than the one that reuses AppKit's own pixels.
  - **A cell cannot tell a selected-but-unfocused row from an ordinary one**: `backgroundStyle` is
    `.normal` for both (probed). That matters because a source list tints the *unfocused* selected
    row's glyph with the accent — a second place the cursor colour belongs — so the row view has to
    **push** the colour down to its cells from `isSelected`/`isEmphasized`, plus `didAddSubview`,
    since the controller hands the row its colour before the cell is attached.
    - **The glyph and the label are two pushed values, not one.** They looked like one — both need a
      colour on the filled pill — but the colours mean opposite things: the glyph wears the *cursor
      colour itself*, while the label only ever takes the **derived** foreground that stays legible
      *on* that fill. Collapsing them into a single push therefore carried the raw colour into the
      unfocused row's text too, so a custom palette recoloured the sidebar's names — a change nothing
      asked for, in the one place the user reads rather than scans. Push the glyph's colour and the
      label's separately: the label is then untouched in every state but the pill, and the sidebar's
      text reads the same whatever palette is set.
  - **`NSImageView.contentTintColor` is ignored for a template image in an *emphasized*
    `NSTableCellView`** — the cell draws it white regardless, pixel-identical to an untinted control,
    in either assignment order (probed both). It works while the cell is `.normal`, which is the
    half that already looked right, so the bug reads as "the icon didn't follow the label" on
    exactly one of two states: a pale cursor colour gave a **black label beside a white glyph**.
    Bake the colour into the image instead — draw it and `fill(using: .sourceAtop)`, which replaces
    the colour and keeps the coverage, then clear `isTemplate` so there is nothing left for AppKit to
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
      provably white. The capture is downsampled below 1x (the geometry note above), and colour goes
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
  `LocalizedStringKey` is parsed as Markdown, so a glob example loses its wildcards.** The M15 colour
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
  another 5 — and because the label was merely centred with no width constraint it *overran* on both
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
    that they fail as *behaviour*, so no string sweep and no coverage test over the catalog can see
    them. Key off an identity the display layer doesn't own.
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
    refuses to honour is a worse lie than no corner.
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
    needs its own check (is the restored centre on the parent window's screen?), or every dialog
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
  - `.normal` is therefore modelled as **passing no option at all**, not as an explicit `6`:
    libarchive's per-format defaults are not all 6, and the default is what "normal" means.

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
- **`curl`'s progress meter is a bar, not an accountant**: measured at ~1 update/second, rounded to
  `k`/`M` (`339k`). Exact counts come from `-w` at the end.
- **An FTPS data connection can return zero bytes and exit 18 on this `curl`** when TLS 1.3 is
  negotiated; `--tlsv1.2 --tls-max 1.2` fixes it, on both SSL backends. Apply it as a **retry after
  exit 18**, not up front — forcing every server to 1.2 is a real downgrade for the ones that do 1.3
  correctly. It fails in the quiet direction (an empty listing reads as an empty directory), so a
  smoke test must assert *non-empty* rather than merely "no error".

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
- **`curl -w '%{certs}'` prints the chain as PEM** plus labelled subject/issuer/dates, so the app
  needs no `openssl` to show the user what it is being asked to trust.
- **What `--pinnedpubkey` hashes is the `SubjectPublicKeyInfo`, not the certificate**, so it must be
  walked out of the DER (skip the optional `[0]` version, then five fields of `TBSCertificate`) and
  digested as a complete TLV. Display the *certificate's* SHA-256 alongside it — that is the value
  every other tool shows and the one a user compares against a NAS admin page — but pin the key,
  which survives a routine certificate renewal the way SSH's key pinning does. Verify the walk
  against a **real** captured certificate whose two digests were computed by `openssl`, not by the
  code under test: a drifted walk would pin a key the server never presented, and comparing against
  your own output could never catch it.

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
  - **Put Back cannot work here either**, and for the same reason as iCloud: no `.DS_Store`, and the
    origin rides on the item as `com.apple.fileprovider.trash-put-back#PN`, whose whole value is an
    opaque `__fp/fs/fileID(<n>)` with no path in it.
  - The `.Trash` must sit **exactly one level below** the CloudStorage root. A `.Trash` deeper inside
    someone's Drive is ordinary content, and reading it as a trash turns F8 there into a permanent
    delete — wrong in the expensive direction.
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
  *relabelled* per kind at the display layer.
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
      from another Mac or an account since deleted, so the numeric id has to be modelled as optional.
    - Both shapes are **accepted back** by `acl_from_text`, so they round-trip losslessly and an edit
      to a neighbouring entry leaves them untouched — which is the case that actually reaches a user,
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
    rewrites a neighbouring field breaks the diff-based contract** ("a field left alone is never
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
  `\` and `"`) on top of the shell quoting inside the body — this avoids it entirely. Cancelling the
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
  add_subdirectory` itself — so no per-kind relabelling. Three entries `chmod` *cannot* express, which
  make the whole ACL a stated omission rather than a wrong write: a **bare-GUID / unresolved subject**
  (`chmod: Unable to translate '…' to a UUID`), an **inherited** entry (`+a#` creates it explicit,
  losing the `inherited` flag), and a token this build only keeps verbatim.
- **No stock shell tool sets the birth/Created date** — `SetFile` is Xcode-CLT-only (and whole-second,
  US-format), so a `setCreationDate` step is omitted and named, never faked. `touch -t` is
  **whole-second**, which matches `NSDatePicker`'s own resolution; set only the time that changed
  (`touch -a` / `touch -m` separately, since `touch -t` writes one value) so an untouched neighbour
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
- **A "can this apply here" predicate lives in *two* places — the behaviour and the menu that gates
  it — and they drift silently.** Bringing size bars into the tree meant widening `areSizeBarsVisible`
  (drop `!panel.isTree`), and every core test, the app suite, both linters and the build passed with
  the bars fully wired — but the View ▸ Size Visualization menu item stayed **greyed out in a tree**,
  because `validateToggleItem` carried its own hand-copied twin of the same predicate
  (`… && !panel.isTree`). Nothing could catch it but launching: a disabled menu item swallows its own
  key equivalent too, so ⌃B was dead as well, and the feature was unreachable while every automated
  signal was green. When a mode gains a capability, grep the *selector's* validator for the predicate
  that used to forbid it — the enable/disable gate is a second copy of `areSizeBarsVisible` by
  construction, and the menu is the one surface no headless test drives. Same family as the "a display
  string that exists twice will be localized once" and "name the new backend at every site that lists
  the old one" traps: one rule, two spellings, and the compiler checks neither.
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
