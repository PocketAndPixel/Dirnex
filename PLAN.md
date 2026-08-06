# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: M0–M17 shipped (14 languages) · **M18 in flight** · Created: 2026-07-05 ·
Log: [docs/HISTORY.md](docs/HISTORY.md)

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
├── docs/                       (NOTES.md gotchas · HISTORY.md M0–M14 log · RELEASING.md)
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

### Shipped: M0 → M17 (2026-07-05 → 2026-08-06)

Every milestone through M17 is closed. The checklists and the full per-pass progress log —
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
| M14 | Checksums and attributes | 07-30 (escalation 08-02) | Split/combine files (dropped 2026-07-29 — FAT32's ceiling, floppy/CD spanning and mail limits are all gone on macOS); multi-selection and recursive **privilege escalation** (the flat single-item path proves the mechanism; those sheets refuse a root-only change by name); escalating the *undo* of a non-owned change (still refused with `attributeRestoreNeedsAdministrator`, not escalated) |
| M15 | The tree view, and colour the user chooses | 08-02 | The **thumbnail grid, brief view and the `PaneSurface` extraction** (cut 2026-08-02 — the three are one unit, and `FileTableView` is a 25-method contract a grid satisfies none of); a memo in front of `fnmatch` (measured unnecessary — 0.46 ms per full reload for 5 rules); size bars in tree mode, withdrawn at close and re-scoped per parent directory in a follow-up (`SizeVisualization(tree:)`) |
| M16 | Quick View: source or page | 08-06 | Markdown and RTF as dual-style types, and `.webarchive` / `.mhtml`, which need `loadData` rather than a file load; the JavaScript mark in the *pane*-size preview, which has no header to carry it |
| M17 | Syntax highlighting in Quick View | 08-06 | A **theme picker** (the colours are a fixed light/dark table, no Settings surface); the constructs a regex-free single pass cannot reach — string interpolation, JS regex literals, heredocs, Swift raw strings, JSX, and semantic colouring of any kind; **line numbers, folding and a minimap**, which are editor features Dirnex hands to the user's own editor; highlighting inside the *rendered* HTML style, which is the page's own business; a **key-vs-value** distinction in JSON, and Markdown's **setext headings** and **indented code blocks**, all three of which need a lookahead or a previous line the single pass does not keep; Ruby's `=begin` block comment; and any third-party highlighter — Highlightr (a JS engine on every cursor step) and tree-sitter (a C dependency plus a grammar per language), both rejected 2026-08-06 |

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

### In flight: M18 — Quick View: Markdown as a document (M)

Goal: `.md` becomes the **second dual-style type**. `1` keeps the source, coloured by M17's Markdown
scanner; `2` renders the document those bytes describe — headings, tables, lists, coloured code,
`[[_TOC_]]` and mermaid diagrams — **hand-rolled end to end**, with no JavaScript in the page and no
third-party renderer anywhere in it. Opened 2026-08-06.

M16 named this in its own undone column ("Markdown and RTF as dual-style types"), and it is the half
worth taking: a `.md` is the format most likely to be *read in a file manager* rather than opened,
and what Quick Look shows for one today is plain text with the syntax on display. Almost everything
the milestone needs already exists — the render-style enum and its two keys, the sandboxed web view
with its compiled block-remote rules, and the scanner that can colour a fence's contents. What is
missing is a renderer.

**Where the work lives.** Markdown → HTML is a pure function over bytes, so §2 puts it in
`DirnexCore` with tests; the *stylesheet* is presentation and stays in the app — exactly the division
M17 already draws between `SyntaxToken.Kind` and `SyntaxTheme`, and the one `TextPreview`'s own doc
comment states. The core emits semantic HTML carrying class names and never a colour; the app hands
the web view a `<style>` block built from `SyntaxTheme` and the system label colours. That is what
makes the rendered page follow light and dark for free, diagrams included.

**Raw HTML in a `.md` is escaped, not passed through.** CommonMark says to pass it; a preview that
renders on *cursor movement* must not. That single decision is what keeps the generated page inert:
there is no script for the JavaScript toggle to be about, no remote `<img>` for the content rules to
have to catch, and therefore no reason for a markdown preview to carry M16's `(no JavaScript)` mark.
It is also honest about what this surface is — a `<details>` block rendering as its own text is a
much smaller surprise in a preview than a page that runs something because the cursor passed over it.

**Mermaid is hand-rolled too, over a named subset** — decided 2026-08-06 with the user, against
vendoring `mermaid.min.js`. Bundling it would have bought every diagram type at the price of a ~3 MB
third-party asset, a JS engine running on every cursor step, and output §2 cannot test: the same three
costs that got Highlightr and tree-sitter rejected at M17, arriving in a different shape. The subset
is **flowchart and sequence**, and every other diagram type falls back to a code fence — visibly, and
by name.

Three things to probe before any Swift is written (§"How to work here"), because each can change the
design rather than merely confirm it. Two are **answered**, in Slice 3:

- ~~**How a generated document reaches the file's own images.**~~ **Answered, after getting it wrong
  once.** `loadHTMLString(_:baseURL:)` grants the page **no file access whatsoever** — the first
  probe said otherwise and was measuring its own directory (Slice 3, and NOTES.md). The two shapes
  that work are granting the whole disk or inlining as `data:`; the second ships, scoped to the
  document's own directory. The failure mode the plan predicted is exactly the one that happened: a
  missing image read as a broken *file*, not as a broken preview.
- ~~**Whether a `#fragment` click still passes `decidePolicyFor`**~~ **Answered: yes, unchanged.**
  The generated page is loaded with the document's directory as its base URL — for *identity*, not
  for access — so a `#anchor` arrives as `<directory>#anchor` and `isPermitted`'s existing
  fragment-stripping comparison allows it, while a sibling `.md` and a remote URL are both refused by
  name. Verified live: a TOC link moves the reading position on a real click.
- ~~**What a text metric costs, and where it comes from.**~~ **Answered: it is cheap, and it is safe
  where it has to be.** `NSString.size(withAttributes:)` costs **5.4–6.7 µs a label** and agrees
  exactly with `NSAttributedString.size()` and `CTLineGetTypographicBounds`, so a hundred-node
  diagram is ~0.7 ms of measurement — per-node measurement is affordable and no cache is warranted.
  `CTFontGetAdvancesForGlyphs` is ten times cheaper and was rejected: summed advances are not
  shaping, and it measures `🐛 Bugs` 13 % too wide. The half that decided the seam's *shape*: it is
  **safe and exact off the main actor**, where the render runs — four concurrent background queues
  measuring 200 labels twenty times each produced **zero** disagreements with the main thread — so
  the metric is a plain `@Sendable` closure with no actor hop, like `resolveImageSource`.

Four slices, core-first (§2). The order is deliberate: the app wiring lands **third**, so the
milestone is a usable feature before mermaid is written and mermaid can be cut without leaving
anything half-built.

#### Slice 1 — The block and inline renderer (M, core-only) — landed 2026-08-06

- [x] `MarkdownBlockParser` — a line-oriented **block** pass, then an **inline** pass per block. Two
      passes rather than M17's one, and the departure is the point: that scanner is single-pass with
      one lookahead *because* it only ever adds colour, so a construct it gets wrong is a wrong
      colour. A renderer produces the document itself, and gets the previous line and the block's
      whole text. Which is also why **setext headings and indented code blocks** — both named in
      M17's undone column as needing a lookahead the scanner does not keep — are in scope here, and
      both landed.
- [x] Blocks: ATX and setext headings, paragraphs, thematic breaks, fenced (``` and `~~~`, with info
      string) and indented code, nesting blockquotes, ordered and unordered lists (nesting,
      tight/loose), GFM tables with per-column alignment, task-list items, link reference definitions,
      and **YAML front matter** — recognized rather than ignored, since an opening `---` otherwise
      parses as a thematic break and the document opens looking broken. Rendered as a subdued
      metadata table: a file manager shows what is in the file.
- [x] Inline: emphasis and strong, inline code spans, links, images, autolinks, GFM strikethrough,
      hard line breaks, entities, and backslash escapes. **Emphasis is what forced the inline pass
      into two stages of its own** — scanning forward and matching the first legal closer gets
      `*a **b** c*` wrong, because the `**` after `b` *is* a legal closer for the outer `*`. The
      scan therefore emits finished nodes with the delimiter runs left in place, and a second pass
      pairs them from the inside out.
- [x] **Escaping is the renderer's contract, not a step inside it**: every text run reaches the
      output HTML-escaped, and a raw tag in the source is text. A second wall behind it for the one
      thing escaping cannot reach — `[click](javascript:…)` is *valid Markdown* with no raw HTML in
      it, so `MarkdownURL` allow-lists the schemes and a refused link keeps its words and loses its
      `href`.
- [x] The output is a **fragment**, not a whole document. The `<html>` wrapper and the stylesheet are
      the app's, because the app is the only side that knows which appearance is on screen. (The
      heading list moves to Slice 2, where the TOC needs it.)
- [x] `MarkdownRenderOptions.resolveImageSource` — the seam the milestone's **first probe** lands in,
      added now with an identity default so no test in this slice depends on how that probe comes out.

Exit: **met.** 77 new core tests, and the corpus suite renders this repo's own `PLAN.md`,
`README.md`, `docs/NOTES.md` and `docs/HISTORY.md` structurally rather than against a golden file —
the output is balanced, every tag and every attribute is in a **closed set** the renderer chose, no
`href` carries a scheme outside the allow-list, and no heading is lost between source and page.
1823 core + the app suite green, both linters clean; the app is untouched and was not rebuilt for it.

Two findings worth carrying:

- **Rendering is affordable at the sizes that exist, and only just at the ceiling.** Release build:
  README 0.5 ms, `PLAN.md` (37 KB) 4.5 ms, `NOTES.md` (174 KB) 24 ms, `HISTORY.md` (683 KB) 96 ms,
  and 482 ms at `TextPreview.byteLimit`'s 4 MB (debug is ~2.2× each). So Slice 3 puts this on the
  detached read task beside `TextPreview.read`, exactly where M17 put the tokenizer and for the same
  reason — the preview re-renders on **every cursor step**. A `.md` large enough to be a problem is
  not a document anybody reads, and it already has the truncation notice.
- **A security assertion that searches the rendered *text* for a dangerous string tests the
  document, not the renderer** — three of this slice's own assertions were written that way and all
  three were wrong. `onerror` as a word is legitimate prose (this plan contains one), `javascript:`
  likewise, and `hr` matched a "starts with h" heading count. The assertions that hold ask what
  reached a **tag**: the attribute names against a closed set, and every `href`/`src` scheme against
  an allow-list. Now in docs/NOTES.md ▸ Testing.

#### Slice 2 — `[[_TOC_]]`, anchors, and coloured fences (S, core-only) — landed 2026-08-06

- [x] Heading slugs, GitHub's rule, emitted as `id` on every heading so any anchor in the document
      resolves — including the ones the file's author already wrote by hand. **Measured, not read**:
      there is no specification, so the rule was probed against 211 real `.md` files on this Mac
      carrying 2282 hand-written `](#…)` links, and two of the three things it settled would have
      been got wrong by reading `github-slugger`'s published regex (below).
- [x] `[[_TOC_]]` — Azure DevOps' spelling, with `[TOC]` recognized beside it — as a block of its
      own, replaced by a nested `<nav>` built from the heading list. Doing it in the block pass is
      what makes a marker inside a code fence stay text, and it does.
- [x] A fence whose info string names a language is tokenized through **M17's existing
      `SyntaxHighlighter`** and emitted as one `<span class="tok-…">` per `SyntaxToken.Kind`, so the
      fence in the rendered page and the file in source mode are coloured by the same scanner and the
      same table. No language, or one no grammar claims, is plain `<code>` — the same "an unknown
      type is not a special case" rule the text backend already keeps.

Exit: **met.** `PLAN.md`'s own 17 headings produce a TOC whose links and emitted `id`s are the same
set, counted as well as compared; README.md's ```` ```bash ```` fences carry the comment spans
`SyntaxHighlighter` itself claims for the same bytes. 20 new core tests, 1843 core + the app suite
green, both linters clean; the app is untouched.

Three findings worth carrying:

- **A corpus of files that already depend on an undocumented rule is an oracle for it.** Three
  candidate slug rules were scored against those 2282 real links: an allow-list (keep letters,
  digits, spaces, `-`, `_`) resolved **25 anchors the published block-list regex does not**, with
  none going the other way. The 25 are emoji headings — `## 🐛 Bugs` really does anchor as `#-bugs`,
  and `## Contributors ✨` as `#contributors-`. So **nothing is trimmed**, which is the tidying every
  reasonable person would apply and which breaks real documents. The corpus also produced the
  duplicate rule's own shape, in a file linking to `#all`, `#all-1` *and* `#all-2` — a counter that
  steps past a collision the author wrote by hand, not "append the count".
- **The anchors and the TOC's links are one derivation, not two.** The obvious arrangement — a
  slugger in the renderer, another where the outline is built — agrees right up until it doesn't,
  and the failure is a page that looks perfect with every TOC entry dead. So the parse gathers the
  headings once, in render order, and the renderer consumes that list by position. The one thing
  that could silently drift is the *order* the two walks visit headings in, and a test pins it
  against a document with headings inside both a blockquote and a list.
- **Highlighting costs nothing at the sizes that exist.** Release build, best of 20: README 0.95 ms,
  `PLAN.md` 4.6 ms, `NOTES.md` 24.0 ms, `HISTORY.md` 94 ms — all within noise of Slice 1's figures.
  The per-fence fixed cost (compiling a grammar) is **~7.5 µs**, so 1000 fences add 3.8 ms and no
  cache is warranted. The new per-byte cost only shows at the ceiling: 4 MB that is *one* `swift`
  fence renders in 564 ms against 177 ms untagged — still under the 579 ms the same 4 MB of prose
  takes, so the fenced case does not move where the detached-task argument sits.

#### Slice 3 — The app: routing, style, and the sites that name a backend (S) — landed 2026-08-06

- [x] `QuickViewPreviewView+Markdown` — `isRenderableMarkdown` (named types, never one conformance
      test: `.md`, `.markdown`, `.mdown`, `.mkd` and `net.daringfireball.markdown`, which is the
      lesson `.xhtml` taught M16), the render on the detached read task that already exists under the
      same `loadToken` guard, and the load into `QuickViewWebView`.
- [x] **One `offersBothStyles(_:)` predicate**, replacing the three app sites that spell
      `isRenderableHTML` today: the routing in `show(_:style:)`, `previewedFileOffersBothStyles`
      (which gates the `1` / `2` keys) and `quickViewCaption` (which draws the header hint). This is
      the trap NOTES.md names outright — a new backend has to be named at every site that lists the
      old one and the compiler checks none of them. The quiet failure available here is `2` doing
      nothing on a `.md` while the header says it should.
- [x] The `(no JavaScript)` mark is **suppressed for markdown** — true and meaningless, since the page
      we generate has no scripts to refuse. Same argument that already keeps it out of source mode.
      It is the one site that deliberately keeps asking `isRenderableHTML`, so it has its own test.
- [x] `QuickViewMarkdownStyle` — the stylesheet, built at load time from `SyntaxTheme` for fences and
      the system label colours for the document, with the system font for prose and the fixed-pitch
      font for code. **Not** re-generated on `viewDidChangeEffectiveAppearance`: probed, the page
      follows the appearance itself, so it carries both palettes instead (below).
- [x] `QuickViewMarkdownImages` — the answer to the milestone's first probe, which did not come out
      the way it was written (below): a generated page has no file access, so the images are read and
      inlined as `data:`, only from the document's own directory and inside a budget.
- [x] A truncated document says so. `TextPreview` stops at 4 MB and its own doc comment makes the
      caller responsible for saying it — the source view draws a floating strip, and a rendered page
      that just *ends* is the version of that lie which is hardest to notice.
- [x] Live verification at all three sizes and in **both appearances**, with the cursor stepped
      through a folder of `.md`.

Exit: **met**, live at all three sizes. `2` renders `PLAN.md` and a document exercising every
construct; `1` still shows the coloured source; a TOC link moved the reading position by real click;
← / → stepped and re-rendered even after clicking *into* the page; `⌘L` then `/tmp/12` put both
digits in the path field with the preview up (M16's own regression); and flipping the system to light
and back re-coloured the page **with the scroll position pixel-identical**. 29 new tests (16 app + 13
core), 1844 core + 253 app green, both linters clean.

Four findings worth carrying:

- **The first probe was wrong, and the harness's own location is what made it wrong.** It reported
  `loadHTMLString(_:baseURL:)` with the document's directory reaching sibling images — measured, with
  JavaScript off, by snapshot pixel rather than by asking the page. The app showed broken images
  within a minute of launching. The test directory had been created **inside the probe binary's own
  directory**, which the WebContent sandbox already reads; moving the identical bytes one directory
  sideways flips every answer. Re-measured honestly, only two shapes work: granting the page the
  **whole disk** (`allowingReadAccessTo: /`), or handing it the bytes as `data:`. Now in NOTES.md,
  with the general form — when the subject is "may this process read that file", the probe's own
  location is part of the experiment.
- **`data:` is the better answer on the merits, not just the simpler one.** A preview that renders on
  cursor movement then reads exactly the files something decided to give it — here, only what
  resolves inside the document's own directory, which is the same scope `loadFileURL` already grants
  a saved HTML page. The price the plan worried about is small: **0.4 ms and 1.33× per megabyte**, so
  a 4 MB screenshot costs 1.6 ms of the render it rides on. The seam Slice 1 added for this and Slice
  3 briefly deleted is back, filled — and it is now load-bearing for *security*, so the renderer
  sanitizes the resolver's **output**, not its input.
- **The page follows light and dark by itself, live.** `prefers-color-scheme` tracks the web view's
  effective appearance with no `color-scheme` declaration and re-evaluates with **no reload**, so the
  stylesheet carries both palettes under one media query. The design this replaced (re-generate on
  `viewDidChangeEffectiveAppearance`) would have thrown away the reading position on every flip.
- **There is no system colour for "slightly off the text background".** `.windowBackgroundColor` and
  `.controlBackgroundColor` are byte-identical to it in both appearances, `.gridColor` inverts in
  dark, and even the gentlest fill takes `typeOrTag` from 4.59:1 to **3.68:1** — because M17 authored
  that palette against `.textBackgroundColor`. So a code fence is bordered rather than filled. All in
  NOTES.md.

#### Slice 4 — Mermaid: flowchart and sequence, as SVG (M, core + a thin app seam) — landed 2026-08-07

- [x] `MermaidDiagram.parse` — `graph` / `flowchart` with a direction (`TD`, `TB`, `LR`, `RL`, `BT`),
      node shapes (`[]`, `()`, `(())`, `{}`, `[[]]`), edges (`-->`, `---`, `-.->`, `==>`, arrowheads
      at either end) and edge labels (`-->|text|` and `-- text -->`); `sequenceDiagram` with
      participants and aliases, `->>` / `-->>` / `->` / `--x`, activations and `Note over`.
- [x] Layout, pure and fully tested: a flowchart is a layered DAG — longest-path layering, one
      barycenter pass to order within a layer, x by centering — with **cycles broken by DFS back-edge
      removal**, so `A --> B --> A` draws instead of hanging. A sequence diagram is positional and
      needs no layout beyond column and row arithmetic. **One thing the plan did not name and the
      first live run demanded: dummy nodes** (below).
- [x] `MermaidSVG` — the emitter, in class names and `currentColor` and never a literal colour, so
      Slice 3's stylesheet colours the diagram in both appearances the way it colours everything else.
- [x] Text width through the injected metric from the probe above; the fixed-advance fake makes every
      layout assertion in the tests exact.
- [x] Anything else in a `mermaid` fence — a class diagram, a gantt, a state chart, an ER diagram —
      falls back to Slice 2's code fence **with a one-line note naming the type as unsupported**.
      Extended past what the plan asked for, in the same spirit: a construct inside a *supported*
      type that the subset does not draw — `subgraph`, `loop`, `alt`, `style` — is reported the same
      way, so the diagram still draws and the page still says what it left out.

Exit: **met**, verified live at full-window size in both appearances. `PLAN.md`-style prose carrying
a flowchart, an `LR` chart and a sequence diagram draws all three legibly; `stateDiagram-v2` shows
its source and names itself; a `subgraph` chart draws *and* reports the frame it did not draw; `1`
still shows the coloured source. 60 new tests (54 core + 6 app), 1902 core + 260 app green, both
linters clean.

Four findings worth carrying:

- **The layout needed dummy nodes, and only a picture said so.** Every test passed and the first
  launch showed `F ==> A` as one straight line through four boxes and both edge labels. Longest-path
  layering plus a barycenter pass is not enough on its own: an edge spanning layers needs a *dummy
  node in each layer it crosses*, so the ordering pass can steer it between the real nodes. That is
  the one piece of Sugiyama it is not worth skipping. Its own corollary bit immediately after —
  sizing the canvas from the **boxes** then leaves the bend outside it, and the back edge ran off the
  right-hand side of the picture and back. Measure the bounds over what is *drawn*.
- **An SVG with only a `viewBox` has no intrinsic size**, so the stylesheet's `max-width: 100%`
  stretched a three-node flowchart to the full reading column — 11 pt labels drawn at twice that,
  beside prose that was the right size. Emitting `width` and `height` **as well as** the `viewBox`
  makes the diagram draw at the size it was laid out for and lets the rule only ever scale it *down*.
  Both of these were invisible to 1902 tests and obvious in the first second of looking.
- **The font size is in three places and nothing relates them**: the layout measures in it, the
  stylesheet draws in it, and a disagreement is a diagram whose labels do not fit their outlines,
  with every signal green. Hence one constant, `QuickViewMarkdownDiagram.labelSize`, read by both —
  and a test that sweeps **every class the core emits** against the stylesheet, which found three
  unstyled on its first run. The same "one rule, two spellings" family docs/NOTES.md keeps finding.
- **Drawing is affordable, comfortably.** Release build, best of 20: a 10-node flowchart 0.24 ms,
  100 nodes **2.1 ms**, 500 nodes 12.8 ms, a 100-message sequence diagram 1.1 ms — against the 6 ms
  this repo's own `PLAN.md` already takes. The real metric adds ~6 µs a label on top. So a diagram
  costs about what the document around it costs, and it rides the detached read task either way.

Followed up 2026-08-07 after reading a page: a diagram laid out in the *small* system size reads
noticeably smaller than the prose beside it, so a finished drawing is now **magnified** —
`MarkdownRenderOptions.diagramScale`, 1.25 in the app — and the figure is centred in the reading
column. Magnifying the `<svg>`'s displayed size while the `viewBox` stays put is what makes it one
line rather than a second layout: boxes, gaps, strokes and labels all grow together, so no
proportion the layout measured can drift, and `max-width: 100%` still shrinks the whole thing on a
narrow window. Growing the label font instead would have grown the text inside boxes whose paddings
and layer gaps are constants. The centring needs its own carve-out for the fallback — a `<pre>`
inside a centred `<figure>` is *source code*, and it stays left-aligned.

#### Deliberately not in scope

- **Full CommonMark conformance.** The target is what the file's own author sees on GitHub for an
  ordinary document, pinned by a corpus of real files (this repo's), not by the spec's test suite.
  The escape hatch that makes that affordable is M17's, one step over: a construct the parser cannot
  read renders as its **literal text**, never as a wrong document.
- **Raw HTML passthrough** (argued above), **math and LaTeX**, **footnotes**, **definition lists**,
  **emoji shortcodes** and **wiki links**.
- **Following a link to another file.** `decidePolicyFor` refuses everything but the loaded document
  and its own fragments — M16's rule, unchanged — so a `.md` linking to a sibling is a navigation the
  preview will not make. Turning a preview into a browser needs its own history and its own way out,
  which is a different feature.
- **RTF**, the other type M16 left in the same sentence. It is `NSAttributedString`'s job, not a
  renderer's, and shares nothing with this.
- **Rendering as you type**, and editing of any kind — F4 hands the file to the user's own editor
  (§M11's largest deliberate call) and nothing here changes that.
- **Exporting the rendered page** to HTML or PDF. Plausible as a next thing, and it is a *file
  operation*: it belongs in the operation engine with a destination and a conflict policy, not bolted
  onto a preview.

### After M18

The scope that is already written down, rather than merely imaginable, is in the *undone* column above
plus M15's cut: the **thumbnail grid, brief view and the `PaneSurface` extraction** (one unit, argued
in HISTORY.md §M15, with the two constraints any future grid inherits — skip `FileEntry.isDataless`
rows, and move sort off the column header first). The one item two separate milestones have asked for
is **edit-temp-watch-repack write-back** — M11 named it for archives and SFTP, M13 for FTP — so it is
the candidate that would close the most open ends at once.

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
| M17's highlighter grows into a parser by accretion — one heredoc, one regex literal, one interpolation at a time, each individually reasonable | The scanner's boundary is written into the milestone as a list of *decisions*, and each one carries a comment at the place in the grammar where it would have been handled. The tell that the boundary is being crossed is a grammar gaining a **state stack**: a single pass with one lookahead is the whole design, and anything needing to remember where it has been is a parser, which is a compiler's job and not a preview's. The affordable escape hatch is that highlighting only ever *adds* foreground colour to a document that already renders correctly — so a construct the scanner gets wrong is a wrong colour, never a wrong character, and the honest fix for a hard one is to stop colouring it. **Held through the milestone, and the escape hatch was used**: `prefix` and `postfix` came out of the Swift keyword set rather than gaining a rule, because both are contextual and `prefix` is one of the language's most common method names (HISTORY.md §M17 ▸ Slice 1). No grammar gained a state stack; the closest anything came is one `Bool` inside `SyntaxMarkupScanner.scanAttributes`, which is a lookbehind of one token and is argued at the site |
| M18's Markdown renderer chases CommonMark, and its mermaid subset chases mermaid — both indefinitely, one individually reasonable case at a time. The renderer has it worse than M17's scanner, because a wrong answer here is a wrong *document* rather than a wrong colour | Two different mitigations, because the two halves fail differently. For **markdown**, the target is named as a corpus rather than as a spec — this repo's own files, plus whatever real `.md` the next bug report arrives with — and the escape hatch is that an unreadable construct falls back to its literal text, so the worst outcome is a paragraph that looks like its source. For **mermaid** the boundary is a *list of diagram types*, and crossing it is loud by construction: an unsupported type renders its fence with a note naming it, so the pressure to add one shows up as a user asking rather than as a silently wrong drawing. The tell that the mermaid half is going wrong is the layout gaining knobs — mermaid has a config surface of its own, and reproducing it is how a subset becomes a port |
| The tree becomes a *second* pane implementation by accretion — a refresh path, a mark gesture or a sort that quietly forks from the flat one | The tree is a flat projection over the same `NSTableView` and the same index space, not a parallel surface (HISTORY.md §M15 Slice 4); anything that forks is a signal the projection is wrong, not that the tree needs its own copy. Both fork points were answered in the slice — `SizeVisualization`'s per-directory assumption (the bars were withdrawn in tree mode at M15 close, then re-scoped *per parent directory* rather than forked — `SizeVisualization(tree:)` groups each row against its own level, so the projection stays one definition of "share of this folder") and the `installSortedModel` → `reloadEverything` → `syncCursorToTable` tail. It arrived once already, as the *second index space*: six `panel.model[row]` sites that crashed on the first click below the root's last entry, now routed through `displayedIndex(ofID:)` — NOTES.md ▸ AppKit |

## 7. Open questions

**Open now:** none. M18's one was posed and taken at open (below); M15's two closed with it, and
M17's one closed at open and was then
**re-taken twice** (2026-08-06, every time by the user):

- **How much of a syntax theme the user owns** — resolved in favour of **a small fixed set of
  semantic kinds, no Settings surface at all**. That half never moved. What moved, twice, is where
  the colours come from. The question closed on *system dynamic colours*, on the ground that each
  resolves per appearance for free — and Slice 3 measured them and found `.systemGreen` at
  **2.22:1** on a white text background, with teal, cyan, mint, orange and yellow all between 1.5
  and 2.4. The system palette is tuned for fills, not for text on white, so the premise held in
  dark mode and collapsed in light. Re-taken as authored light values with the system colour in
  dark; then re-taken again, the same day and on sight of the result, as **VS Code's Dark Modern
  and Light Modern on both halves** — the `dark_plus` / `light_plus` token colours. The reason is
  not aesthetic preference but *whose* theme: a preview is read next to the editor the file will be
  opened in, and matching that editor is worth more than any hue chosen in isolation. It cost
  nothing to check — every published value clears the same ≥ 4.5:1 floor `SyntaxThemeTests` already
  pinned, in both appearances, because `.textBackgroundColor` resolves to exactly `#1E1E1E` in
  dark, which *is* VS Code's editor background. Everything the original answer was *for* survives
  both moves: one `NSColor` per kind, resolving itself, no picker, no persistence. Reopening the
  *owned-theme* half still means the M15 palette machinery (persistence, a Settings section, a
  derived-foreground rule), which is why it stays written down.
- Kind count is the one detail the answer no longer pins: it opened at "six and no more" and is
  **eight**, `.inserted` and `.deleted` having been added with the diff scanner (HISTORY.md §M17
  ▸ Slice 2). That is two more entries in the same dictionary, not a Settings surface.

Opened with M18 (2026-08-06) and **closed at open, by the user**:

- **Where mermaid diagrams come from** — resolved in favour of **a hand-rolled SVG renderer in the
  core, over a named subset (flowchart and sequence)**, against the alternative of vendoring
  `mermaid.min.js` and running it in the preview. The fork is real because the two answers cost
  opposite things: bundling buys every diagram type mermaid supports, at ~3 MB of third-party
  JavaScript, a JS engine running on every cursor step, and output §2 cannot test — which is
  Highlightr's and tree-sitter's rejection at M17 arriving in a different shape. Hand-rolling buys a
  pure, tested renderer with no dependency and no script in the page at all, at the price of a
  subset that will visibly diverge from what the user's editor draws. The security half turned out
  *not* to be the deciding argument in either direction: escaping the file's raw HTML (M18, above)
  already means no script from the `.md` reaches the page, so a bundled mermaid would have been
  running our code over the file's data rather than the file's code — a materially different posture
  from M16's toggle, and one that would have needed saying out loud in the JavaScript policy.
  Reopening it means taking on a vendored asset with its own update cadence, which is why the
  reasoning stays written down.

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

Opened with M15 (2026-08-02) and **closed** in it the same day, as recommended — both about what a
*marked set spanning directories* means for an operation:

- **What F5/F6 do with marks spanning levels** — resolved: **TC's branch-view behaviour**, flatten
  *preserving relative paths* under the destination. Copying everything flat into one folder is the
  alternative and it silently collides the moment two folders hold an `x.jpg`.
- **F8 with an ancestor and its descendant both marked** — resolved: **dedupe to the ancestor**
  before enqueuing, since deleting the parent already takes the child. Implementing it added the half
  the settling did not say: **the dedupe belongs to F5/F6 too** — a copy fails *politely* there, with
  a conflict prompt over a file the user never chose to duplicate, which is quieter and no less wrong.

Both live in `TreeSelection` (core, 18 tests); the app keeps one `recursiveTargets()` for the
operations that recurse and the raw `selectionTargets()` for the ones that don't. See
[HISTORY.md](docs/HISTORY.md) §M15.
