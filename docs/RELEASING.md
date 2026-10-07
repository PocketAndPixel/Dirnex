# Releasing Dirnex

Dirnex ships as a **signed, notarized DMG** that updates itself through **Sparkle 2**. Cutting a
release is one GitHub Actions run: [`.github/workflows/release.yml`](../.github/workflows/release.yml)
archives the app, signs it with Developer ID, notarizes the DMG, signs the Sparkle appcast, and
publishes the DMG to a GitHub release. A second workflow,
[`beta.yml`](../.github/workflows/beta.yml), is a thin convenience caller that picks the next beta
version and reuses that same pipeline. Users on an older build then see the update automatically,
because the app's `SUFeedURL` points at the persistent appcast feed (see
[Update channels](#update-channels-stable-and-beta) below).

## Update channels: stable and beta

Dirnex serves **one** Sparkle feed that carries two channels — stable and beta — and the git tag
decides which channel a release belongs to:

| Tag | Channel | GitHub release | Appcast item |
| --- | --- | --- | --- |
| `v0.1.0` | stable | marked **Latest** | untagged (everyone sees it) |
| `v0.1.1-beta.1` | beta | marked **Pre-release** | tagged `<sparkle:channel>beta</sparkle:channel>` |

The feed is the single `appcast.xml` asset on a fixed **`appcast`** GitHub release (created
`--latest=false` so it never shadows a real release). Every run **merges**: it replaces the item for
the channel being released and keeps the other, so the feed always holds the latest stable *and* the
latest beta. Build numbers are the GitHub run number, so they stay globally monotonic across both
channels — which is what lets a newer stable outrank a running beta.

- A normal install only ever sees **stable** releases.
- Ticking **Settings → General → Receive beta updates** opts in to the beta channel; Sparkle then
  offers newer beta builds too. It's read live on each check, so no relaunch is needed.
- A beta tester **graduates automatically**: when a stable release outranks their beta build, Sparkle
  offers the stable and rolls them back onto the stable line — the reason for one feed over two.

## One-time setup: repository secrets

The workflow needs these secrets on the GitHub repo (**Settings → Secrets and variables → Actions**).
The values are the same ones used by the sibling `system-utilities-macos` app — secrets are per-repo,
so they must be added here too.

| Secret | What it is | How to get it |
| --- | --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12` | base64 of the Developer ID Application `.p12` | `base64 -i dev-certificates.p12 \| pbcopy` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | the `.p12` export password | set when the `.p12` was exported |
| `APPLE_ID` | Apple ID email used for notarization | your developer account email |
| `TEAM_ID` | Apple Developer team id | `A9N92VGA2M` |
| `APP_SPECIFIC_PASSWORD` | app-specific password for notarytool | appleid.apple.com → Sign-In & Security → App-Specific Passwords |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key that signs the appcast | export from the login keychain (below) |

The **public** half of the Sparkle key is not a secret — it is committed in
[`Dirnex/Info.plist`](../Dirnex/Info.plist) as `SUPublicEDKey`
(`fCW4U7xNZWXNVPxhNxIbqRSbPk12zzDW1MjmmEv5oWA=`). Dirnex reuses the same Sparkle key pair as
`system-utilities-macos`, so `SPARKLE_PRIVATE_KEY` is the same value in both repos.

To export the private key from the login keychain (where `generate_keys` stored it):

```sh
/path/to/Sparkle/bin/generate_keys -x sparkle_private_key
# paste the contents of sparkle_private_key into the SPARKLE_PRIVATE_KEY secret, then delete it
rm sparkle_private_key
```

## Cutting a release

Two ways, both run the same job:

- **Beta (easiest)** — Actions → *Beta* → *Run workflow*. It picks the next `-beta.N` for you and
  hands off to the Release pipeline. See [Cutting a beta](#cutting-a-beta) below.
- **Tag push** — `git tag v0.1.0 && git push origin v0.1.0` for a stable release, or
  `git tag v0.1.1-beta.1 && git push origin v0.1.1-beta.1` for a beta. The version *and the channel*
  come from the tag (a `-beta.N` suffix means beta).
- **Manual** — Actions → *Release* → *Run workflow*. Leave the version blank to bump the patch of
  the `VERSION` file (and commit the bump), or type an explicit version — including a `-beta.N` one
  to cut a beta (a beta version is **not** written back to the `VERSION` file). Tick *draft* to
  stage the release without publishing it or touching the live feed.

### Cutting a beta

Actions → **Beta** → *Run workflow*. Both inputs are optional:

| Input | Leave empty | Or set it to |
| --- | --- | --- |
| `base_version` | previews the next patch — `VERSION` + 1 (so `0.0.3` → betas of `0.0.4`) | a plain `X.Y.Z` to preview a minor/major instead, e.g. `0.1.0` |
| `draft` | publishes normally | tick to stage without touching the live feed |

It reads the `v<base>-beta.*` tags that already exist and takes the next number — first run gives
`v0.0.4-beta.1`, then `-beta.2`, and so on — then calls
[`release.yml`](../.github/workflows/release.yml) through `workflow_call`. **All the real work
(signing, notarization, appcast merge, GitHub release) happens in that one workflow**;
[`beta.yml`](../.github/workflows/beta.yml) only answers "which version is next?", so there is no
second copy of the pipeline to drift. A beta never rewrites the `VERSION` file — that tracks the
stable line only.

**A staged draft is published by the next normal run.** A draft has no tag until it's published, so
the next run takes the same `-beta.N`, replaces the draft's DMG with its own, and publishes it from
the new commit. One trap remains: the draft and that release get the **same build number**, because
the number comes from the published feed, which a draft doesn't touch. So a copy installed by hand
from the draft is never offered that release. Reinstall such a copy from the published release.

> **Build numbers are shared across channels on purpose.** Sparkle ranks candidates by
> `CFBundleVersion`, so it must increase globally, not per channel. `github.run_number` is
> per-workflow-*file*, so a beta run counts separately from a stable one and would restart at 1 —
> which would stamp a beta *below* the installed stable and it would never be offered. The Release
> workflow therefore floors every build number at "highest build in the published feed + 1", so all
> releases share one number line no matter which workflow started them.

The run produces:

- On the **tag** release: `Dirnex.dmg` — the signed, notarized, stapled disk image. Stable tags are
  marked *Latest*; beta tags are marked *Pre-release*.
- On the fixed **`appcast`** release: `appcast.xml` — the merged Sparkle feed, served at the stable
  `releases/download/appcast/appcast.xml` URL every app checks. This release is infrastructure —
  don't delete it.

## The licensing switch and the release date

Two values are baked into every release build's `Info.plist` (PLAN.md §M29):

- **`DirnexReleaseDate`**, the UTC day the release was cut (`YYYY-MM-DD`). A license covers every
  build released on or before its end day. The *Resolve release values* step takes one timestamp
  for the whole run, and both this date and the appcast item's `<pubDate>` come from it. So the
  app can judge an update from the feed before installing it, and gets the same answer the installed
  build will give.
- **`DirnexLicensingEnabled`**, `YES` or `NO`. With `NO` (the default), nothing about licensing
  appears: no License tab, no license commands, no reminder, and a `dirnex://` license link is
  ignored. With `YES`, it all appears, and the reminder starts its 30 quiet days on the first launch.

The switch is the repository **variable** `DIRNEX_LICENSING` (Settings → Secrets and variables →
Actions → **Variables**, not Secrets):

| `DIRNEX_LICENSING` | Beta builds | Stable builds |
| --- | --- | --- |
| unset, or `off` | off | off |
| `beta` | **on** | off |
| `all` | **on** | **on** |

Any other value fails the run. The plan is `beta` for the first beta that should remind (M29 Slice
6), and `all` on the day the store opens. Each run's log says which it used ("Licensing switch: …"),
and `scripts/build_app.sh` reads both values back out of the exported app and fails the run if they
aren't what it passed.

Builds made any other way (Xcode, `xcodebuild`, anyone's own build from source) leave both values
empty: licensing off, and undated. A Debug build still *shows* the License tab and the two commands,
so they can be worked on, but it doesn't remind unless it's launched with a preview argument (next
section).

### Trying the reminder

- **In a Debug build**, launch with `-DirnexDebugLicenseDaysAhead 31`. Reminding switches on with
  the clock 31 days ahead, so the reminder appears at launch and the titlebar label shows. Add
  `-DirnexDebugLicenseBuildDate 2028-01-01` to pretend the build came out on that day: a license
  that ended before it then shows the **Renew** version. A Debug build keeps the reminder's record
  in memory only, and it accepts keys signed with the test key (`tools/license sign --test` in the
  private repo).
- **In a beta with the switch on**, fake the 30 days by moving the start of the quiet period back,
  with Dirnex quit:

  ```sh
  defaults write com.dirnex.Dirnex Dirnex.pref.licenseGraceStart -date "2026-01-01 00:00:00 +0000"
  ```

  The next launch reminds. `Dirnex.pref.licenseReminderLastShown` holds the last time it appeared.
  Delete both keys to start the 30 days again.

### Trying the update notice

The notice appears before an update that the license held doesn't cover. To try it without
releasing anything, serve a local feed offering Dirnex 1.4.0, released on a day after the key's
last day:

```sh
python3 Tooling/fake-update-feed.py 8766 2027-04-01 /tmp/feed.log
```

Quit Dirnex, then launch it pointed at that feed. The feed is a launch argument, so the real
preferences never gain it, and the next normal launch uses the real feed again:

```sh
open -n /Applications/Dirnex.app --args -SUFeedURL http://127.0.0.1:8766/appcast.xml
```

- **By hand.** With a key that covers the running build, the launch probe lights the titlebar
  indicator. Clicking it, or Check for Updates…, brings the notice. **Update Anyway** brings
  Sparkle's own update window; close it there. The feed answers the DMG with a 404, so nothing it
  offers can install, and every request for it is logged with `"download": true`.
- **In the background.** Add
  `-SUEnableAutomaticChecks '<true/>' -SUAutomaticallyUpdate '<true/>' -SUScheduledCheckInterval '<integer>3600</integer>'`
  and leave Dirnex running for more than an hour. Dirnex's own launch probe counts as Sparkle's last
  check, and an hour is Sparkle's shortest interval, so the first background check comes an hour
  after launch. With the key, the log shows the feed fetched again and no download. Run the same
  launch once **without** a key as the control: that one asks for the DMG. Without the control, a
  log with no download would also fit a background check that never ran.
- A key can be a launch argument too (`-Dirnex.pref.licenseKey dnx1.…`), which keeps it out of the
  real preferences. A release build accepts only keys signed with the production key; a Debug build
  also accepts test keys.

## Report a Bug's address

A third value baked into `Info.plist` (PLAN.md §M30): **`DirnexBugReportURL`**, where *Help ▸ Report
a Bug…* sends. The item and its command exist only in a build that carries one.

It comes from the repository **variable** `DIRNEX_BUG_REPORT_URL` (Settings → Secrets and
variables → Actions → **Variables**), for beta and stable builds alike:

- **unset or empty:** no Report a Bug in the build;
- **`https://dirnex.app/api/bug-reports`:** the item shows, and reports go to the store's server.

Anything that isn't an `https://` address fails the run, since the app would ignore it and hide the
item without a word. Each run's log says which it used ("Report a Bug: …"), and
`scripts/build_app.sh` reads the value back out of the exported app, as it does the other two.

Builds made any other way carry none. A Debug build shows the item when launched with
`-DirnexDebugBugReportURL <address>`, which also accepts plain `http` to this Mac (for
`Tooling/fake-bug-report-endpoint.py`, or the store's server on a laptop).

## What the app does with it

- **Check for Updates…** lives in the app menu (and the ⌘K palette as `app.checkForUpdates`); it
  asks Sparkle to check the feed now.
- Sparkle also checks periodically in the background once the user has opted in on first launch.
- **Receive beta updates** (Settings → General) decides whether beta items are eligible; see
  [Update channels](#update-channels-stable-and-beta).
- Only a DMG whose appcast entry is signed with our EdDSA private key will ever be offered, and the
  hardened-runtime + notarization means Gatekeeper installs it without warnings.

> **Feed migration (one-time):** the feed URL moved from `releases/latest/download/appcast.xml` to
> the persistent `releases/download/appcast/appcast.xml`. Builds from before this change (≤ v0.0.3)
> still check the old URL, so install the first release cut after the move manually once; every
> release after that updates in place.

## Building locally (without publishing)

`scripts/build_app.sh` archives and exports the app; `scripts/make_dmg.sh` packages it. Exporting a
Developer ID build needs the signing identity in your keychain. For a plain compile check, a normal
`xcodebuild -scheme Dirnex build` (or opening the project in Xcode) is enough — Sparkle is a regular
Swift Package dependency and builds in every configuration.
