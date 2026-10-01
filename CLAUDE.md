# Dirnex

A dual-pane, keyboard-first file manager for macOS in the Total Commander tradition.
Native Swift 6 with strict concurrency: a headless, fully tested `DirnexCore` SwiftPM package
holding every byte-touching operation, and a thin AppKit shell over it (SwiftUI is used only
for Settings and dialogs).

## Where the knowledge lives

- **[PLAN.md](PLAN.md) is the authoritative source of truth** — architecture rules (§2, locked
  unless proven wrong), the testing strategy, and the current milestone. Read the relevant
  section before starting work, and add a progress note when a slice lands.
- **[docs/HISTORY.md](docs/HISTORY.md)** — the M0–M29 build log; each milestone is archived here as
  it closes. Source comments citing `PLAN.md §M5` and the like point here. Read it for the
  reasoning behind a shipped decision; it's archive, not instruction.
- **[docs/NOTES.md](docs/NOTES.md)** — durable engineering gotchas: Swift 6 traps, AppKit
  behaviors, external CLI quirks, release-pipeline pitfalls. Too big to load at session start, so
  it is read by area: see [Using NOTES.md](#using-notesmd) below.
- **[docs/LIVE-VERIFICATION.md](docs/LIVE-VERIFICATION.md)** — traps met while checking a change in
  the running app. Loaded in every session, just below.
- **[docs/LOCATION-SUPPORT.md](docs/LOCATION-SUPPORT.md)** — what works where: every capability
  against every backend (local, cloud mounts, archives, SFTP, FTP, S3, the virtual listings), with
  the hard technical limits separated from the gaps that are still ours to close. Read it before
  claiming a feature does or doesn't work on a given location, and update the cell when a slice
  moves one.
- **[docs/RELEASING.md](docs/RELEASING.md)** — the release procedure.

@docs/LIVE-VERIFICATION.md

## Using NOTES.md

NOTES.md is not imported here. It is close to 300k tokens, and an import loads the whole file at
the start of every session (measured 2026-10-01), so it cost each session nearly ten times
everything else before any work began. Read it by area instead:

- **Before starting a slice**, read the NOTES.md sections for the areas it touches.
  `command grep -n '^##' docs/NOTES.md` prints the map with line numbers. Read a section with an
  offset and limit: the whole file is too big for one read.
- **Before debugging something that "should just work"**, grep NOTES.md for the API, the tool or
  the symptom.
- A source comment citing `docs/NOTES.md ▸ AppKit` points at that section.
- A new note goes under the section for its area. A trap that can bite any live run goes in
  LIVE-VERIFICATION.md instead.

The sections, and when each one matters:

- **Working rhythm**: its rules are in [How to work here](#how-to-work-here), below.
- **Swift 6 and concurrency**: actors, `Sendable`, tasks, isolation errors.
- **Testing**: writing or debugging a test, a flaky run, a live integration suite, one `###` per
  topic (waits, negative controls, runs that prove nothing, fixtures, live suites, …).
- **AppKit**: any window, view, table, sheet, alert, menu or key handling, one `###` per topic
  (windows, alerts and dialogs, focus, menus, tables, text, layout, previews, drag and drop, …):
  read only the ones you touch.
- **Localization**: adding or changing a user-visible string, one `###` per topic.
- **Lint ceilings and file splitting**: adding to a large controller.
- **External CLI tools**: a backend or a tool, one `###` each: `bsdtar`, sftp/ssh, curl for FTP
  and for S3, SMB, the Trash, iCloud Drive, Google Drive, iCloud Photos, encryption, ACLs and
  extended attributes, checksums, regex, `qlmanage`, `gpr_tools`, `git`. The big ones (sftp/ssh,
  S3, FTP, the Trash, Google Drive, encryption) split again into `####` topics.
- **Release pipeline**: a release, the workflows, Sparkle.
- **Distribution and licensing**: the license, `NOTICE`, license keys, bug reports.
- **macOS system gates**: App Intents, Vision and OCR.
- **Design lessons that generalize**: designing a gesture, an undo, a batch, a guard or a backend
  change, one `###` per topic.

## Architecture rules

- **If it touches bytes, it lives in `DirnexCore` and has tests.** The core is headless: no
  AppKit, no UI, no user interaction. I/O reaches it through the `VFSBackend` protocol.
- **`Panel` is a pure value-type state machine.** Cursor, selection, marks, filtering — no I/O.
  The caller performs I/O via the backend and hands results in.
- Non-hermetic subprocess I/O (`bsdtar`, `sftp`, `git`) lives in the **app**; the pure parse of
  its output lives in the **core**, behind an injected transport so it tests against a fake.
- The app target uses file-system-synchronized groups, so any `.swift` file added under
  `Dirnex/` joins the target automatically — no `project.pbxproj` edit, and `git mv` is enough
  to rename.

## How to work here

- **Probe the real thing before writing Swift.** Capture the real bytes or measure the real
  syscall and design from what you observed. This has caught a wrong assumption in every pass
  that used it.
- **When a format's rule is undocumented, test against a corpus that already depends on it**, such
  as real files on this Mac written against the real behavior (NOTES.md ▸ Working rhythm).
- **Core first, then the app.** A slice opens with purely additive, tested core files (app
  untouched, no rebuild) and lands in a second pass that wires the app.
- **Verify live before claiming done** — and fully quit any running instance first; `open`
  just re-focuses the stale binary. `xcodebuild` writes to
  `~/Library/Developer/Xcode/DerivedData/`, not the repo's `build/`.
  - **A live run that reads a saved secret raises a macOS Keychain password prompt you cannot see.**
    Secrets live in the login Keychain, and the Debug build is signed differently from the
    `/Applications` build that saved them, so macOS asks Oleg for his login password. Computer-use
    screenshots filter that window out, so it looks like an empty screen or a connect that stalls.
    Tell Oleg before such a run, and never try to answer the prompt yourself.
- **Ask before a fork in the road.** Big design choices get a recommendation, not a survey.
- **Leave changes uncommitted.** Oleg commits, in terse one-liners.

## Checks on every change

```sh
swiftformat --lint .
swiftlint --strict
swift test                 # DirnexCore
xcodebuild test -project Dirnex.xcodeproj -scheme Dirnex   # app target
```

Both suites must stay green and both linters clean. SwiftLint's `file_length` 500 and
`type_body_length` 250 are tight on the large AppKit controllers — see the file-splitting
section of [docs/NOTES.md](docs/NOTES.md) before adding to one.

**A green app run does not mean the live suites ran.** They are gated on a config file, and without
it fourteen suites *skip* under a run summary that is byte-identical either way (measured: 979 tests
executed with servers up against 922 without, both reported as `1018 tests in 169 suites passed`).
Before trusting anything the remote backends are supposed to be holding up:

```sh
scripts/live_test_servers.sh up      # throwaway sshd + pyftpdlib, writes both configs
xcodebuild test -project Dirnex.xcodeproj -scheme Dirnex
scripts/live_test_servers.sh down    # stop, remove the configs, unpin the host key
```

## Environment notes

- `grep` is shell-wrapped in this setup — use `command grep`.
- Local, machine-specific tool approvals go in `.claude/settings.local.json` (git-ignored).
  `.claude/settings.json` is the shared, checked-in set.
