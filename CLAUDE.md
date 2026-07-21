# Dirnex

A dual-pane, keyboard-first file manager for macOS in the Total Commander tradition.
Native Swift 6 with strict concurrency: a headless, fully tested `DirnexCore` SwiftPM package
holding every byte-touching operation, and a thin AppKit shell over it (SwiftUI is used only
for Settings and dialogs).

## Where the knowledge lives

- **[PLAN.md](PLAN.md) is the authoritative source of truth** — architecture rules (§2, locked
  unless proven wrong), the testing strategy, and the current milestone. Read the relevant
  section before starting work, and add a progress note when a slice lands.
- **[docs/HISTORY.md](docs/HISTORY.md)** — the M0–M10 build log; each milestone is archived here as
  it closes. Source comments citing `PLAN.md §M5` and the like point here. Read it for the
  reasoning behind a shipped decision; it's archive, not instruction.
- **[docs/NOTES.md](docs/NOTES.md)** — durable engineering gotchas: Swift 6 traps, AppKit
  behaviors, external CLI quirks, release-pipeline pitfalls. Read it before debugging something
  that "should just work."
- **[docs/RELEASING.md](docs/RELEASING.md)** — the release procedure.

@docs/NOTES.md

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
- **Core first, then the app.** A slice opens with purely additive, tested core files (app
  untouched, no rebuild) and lands in a second pass that wires the app.
- **Verify live before claiming done** — and fully quit any running instance first; `open`
  just re-focuses the stale binary. `xcodebuild` writes to
  `~/Library/Developer/Xcode/DerivedData/`, not the repo's `build/`.
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

## Environment notes

- `grep` is shell-wrapped in this setup — use `command grep`.
- Local, machine-specific tool approvals go in `.claude/settings.local.json` (git-ignored).
  `.claude/settings.json` is the shared, checked-in set.
