# Dirnex

A dual-pane, keyboard-first file manager for macOS in the spirit of Total
Commander — built native in Swift, with macOS-only superpowers: Quick Look,
Spotlight search, APFS clones, Finder tags, a command palette, and universal
undo.

See [PLAN.md](PLAN.md) for the full product plan, architecture decisions, and
milestone breakdown.

**Status:** M0 (scaffolding) complete. M1 (read-only dual-pane browser) in
progress — the headless core is done and tested (`LocalBackend`, `DirectoryModel`,
and the `Panel` cursor/selection state machine in `DirnexCore`); the AppKit panel
UI is next.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 26 / Swift 6 (strict concurrency)

No third-party project generator is required — the Xcode project is checked in
and uses file-system-synchronized groups, so new files under `Dirnex/` and
`DirnexTests/` are picked up automatically.

## Layout

```
Dirnex/
├── PLAN.md                 Product plan and milestones
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

TBD.
