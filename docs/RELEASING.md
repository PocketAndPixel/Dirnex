# Releasing Dirnex

Dirnex ships as a **signed, notarized DMG** that updates itself through **Sparkle 2**. Cutting a
release is one GitHub Actions run: [`.github/workflows/release.yml`](../.github/workflows/release.yml)
archives the app, signs it with Developer ID, notarizes the DMG, signs the Sparkle appcast, and
publishes both to a GitHub release. Users on an older build then see the update automatically,
because the app's `SUFeedURL` points at that release's `appcast.xml`.

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

- **Tag push** — `git tag v0.1.0 && git push origin v0.1.0`. The version comes from the tag.
- **Manual** — Actions → *Release* → *Run workflow*. Leave the version blank to bump the patch of
  the `VERSION` file (and commit the bump), or type an explicit version. Tick *draft* to stage the
  release without publishing it as latest.

The run produces, on the GitHub release for that tag:

- `Dirnex.dmg` — the signed, notarized, stapled disk image.
- `appcast.xml` — the Sparkle feed, served at the stable
  `releases/latest/download/appcast.xml` URL the app checks.

## What the app does with it

- **Check for Updates…** lives in the app menu (and the ⌘K palette as `app.checkForUpdates`); it
  asks Sparkle to check the feed now.
- Sparkle also checks periodically in the background once the user has opted in on first launch.
- Only a DMG whose appcast entry is signed with our EdDSA private key will ever be offered, and the
  hardened-runtime + notarization means Gatekeeper installs it without warnings.

## Building locally (without publishing)

`scripts/build_app.sh` archives and exports the app; `scripts/make_dmg.sh` packages it. Exporting a
Developer ID build needs the signing identity in your keychain. For a plain compile check, a normal
`xcodebuild -scheme Dirnex build` (or opening the project in Xcode) is enough — Sparkle is a regular
Swift Package dependency and builds in every configuration.
