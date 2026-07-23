# Dirnex

A dual-pane, keyboard-first file manager for macOS in the spirit of Total
Commander — built native in Swift, with macOS-only superpowers: Quick Look,
Spotlight search, APFS clones, Finder tags, a command palette, and universal
undo.

See [PLAN.md](PLAN.md) for architecture decisions and what's planned next, and
[docs/HISTORY.md](docs/HISTORY.md) for the milestone-by-milestone build log.

**Status:** M0–M11 shipped — dual-pane browsing, the queued/undoable operation
engine, the ⌘K palette, archive and SFTP/SMB backends, the Mac-native layer
(Finder tags, Git awareness, Quick Look, AppleScript + Shortcuts), a notarized
Developer ID release pipeline with Sparkle beta/stable channels, a
keyboard-drivable sidebar you can shape — pins, folds, Recents, and a merged
Trash with Put Back — an iCloud Drive that matches Finder's: the per-app
document folders merged in, and evicted files that download on open instead of
opening empty — and every cloud mount under `~/Library/CloudStorage` (Google
Drive, Dropbox, OneDrive, Box) browsed as a folder, with its own trash, sync
badges, and Google Docs that open in the browser — plus F4 Edit, which hands a
file to the editor you already use, and a Quick View that grows to fill both
panes or the whole display, flipped through with the arrows or a two-finger
swipe.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 26 / Swift 6 (strict concurrency)

No third-party project generator is required — the Xcode project is checked in
and uses file-system-synchronized groups, so new files under `Dirnex/` and
`DirnexTests/` are picked up automatically.

## Layout

```
Dirnex/
├── PLAN.md                 Architecture decisions and what's next
├── docs/                   Engineering notes, build history, release procedure
├── Dirnex.xcodeproj        App target (thin UI client)
├── Dirnex/                 AppKit/SwiftUI app sources
├── DirnexTests/            App-target smoke tests
├── DirnexCore/             SwiftPM package — all file logic, headless & tested
│   ├── Sources/DirnexCore/
│   └── Tests/DirnexCoreTests/
├── Tooling/                Fixture generator, CI helpers
└── .github/workflows/      CI
```

**Rule:** the app target contains no file-manipulation logic. If it touches
bytes, it lives in `DirnexCore` and has tests.

## Build & test

```bash
# Build
xcodebuild -project Dirnex.xcodeproj -scheme Dirnex -destination 'platform=macOS' build 2>&1 | tail -15

# Core package (fast, headless):
swift test --package-path DirnexCore

# App + app-target tests via Xcode:
xcodebuild test -project Dirnex.xcodeproj -scheme Dirnex -destination 'platform=macOS'

# Clean defaults
defaults delete com.dirnex.Dirnex "NSWindow Frame MainWindow"

# Run the app:
open "$(xcodebuild -project Dirnex.xcodeproj -scheme Dirnex -showBuildSettings \
  -destination 'platform=macOS' 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{d=$3} / FULL_PRODUCT_NAME /{p=$3} END{print d"/"p}')"
```

## Test fixtures

`Tooling/generate-fixtures.swift` builds nasty directory trees (deep nesting,
long paths, emoji/NFC/NFD names, symlinks, mixed sizes, large flat dirs) used
by core tests and manual browsing:

```bash
swift Tooling/generate-fixtures.swift ./.fixtures          # modest
swift Tooling/generate-fixtures.swift ./.fixtures --huge    # + a 100k-entry dir
```

## Signing

M0 builds with ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`) so it runs locally
and in CI without a team. Developer ID + notarization arrives in M7; set your
own team in the target's signing settings for local development if you prefer.

## License

Dirnex source code is licensed under the [Apache License 2.0](LICENSE) — fork
it, modify it, ship it commercially, keep your changes private.

Two things are carved out of that grant: the **name "Dirnex"** and the
**application icon**. A fork must ship under its own name and its own icon.
Saying "a fork of Dirnex" or "based on Dirnex" is explicitly fine — see
[TRADEMARKS.md](TRADEMARKS.md) for the full policy and a checklist of what to
change before distributing a fork.
