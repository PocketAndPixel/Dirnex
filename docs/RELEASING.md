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
