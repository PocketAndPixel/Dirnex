# Dirnex trademark and brand asset policy

Dirnex source code is licensed under the [Apache License 2.0](LICENSE). That
license is deliberately permissive: fork it, modify it, ship it commercially,
keep your changes private. **This policy does not take any of that away.**

What it does cover is the *name* and the *look* — the things users rely on to
tell an official Dirnex build from someone else's. Section 6 of the Apache
License already withholds trademark rights; this file spells out what that
means in practice, and extends the same idea to the icon artwork.

## What is not licensed

The following are **not** covered by the Apache License 2.0 grant and remain the
property of the copyright holder:

1. **The name "Dirnex"**, including confusingly similar variants
   (e.g. "Dirnex+", "Dirnex Pro", "DirnexX", "Dyrnex").
2. **The Dirnex application icon and any derivative of it**, including every
   file under `Dirnex/Assets.xcassets/AppIcon.appiconset/` and any other
   logo, wordmark, or brand artwork in this repository.

No trademark license, and no copyright license to the icon artwork, is granted
by the Apache License, by contributing to this project, or by this file.

## What you may do

- Fork the repository, modify it, and distribute your fork **under a different
  name and a different icon**.
- Use the name "Dirnex" in plain, factual, descriptive statements — nominative
  fair use. All of these are fine without asking:
  - "a fork of Dirnex"
  - "based on Dirnex"
  - "compatible with Dirnex"
  - "MyForkName, derived from Dirnex by Oleg Verhoglyad"
- Keep the copyright notices, `LICENSE`, and `NOTICE` files intact — the Apache
  License requires this, and it is how attribution is preserved.
- Reproduce the icon inside documentation, articles, reviews, or screenshots
  that discuss Dirnex itself.

## What you may not do

- Ship, publish, or distribute a build named "Dirnex" (or a confusingly similar
  name) that is not an official release from this project.
- Ship a build that uses the Dirnex icon, or artwork derived from it, as its own
  application icon.
- Use the name or icon in a way that suggests your fork is endorsed by,
  affiliated with, or an official continuation of this project.
- Register the name "Dirnex", a confusingly similar name, or the icon as a
  trademark, domain, or app-store listing.

## Practical checklist for forks

If you fork Dirnex and intend to distribute the result, change all of the
following before you ship:

| Where | What to change |
| --- | --- |
| `Dirnex/Assets.xcassets/AppIcon.appiconset/` | Replace every icon PNG with your own artwork |
| `Info.plist` — `CFBundleName`, `CFBundleDisplayName` | Your app's name |
| `Info.plist` — `CFBundleIdentifier` | Your own reverse-DNS identifier |
| Xcode scheme, target, and product name | Your app's name |
| Sparkle appcast feed URL and update endpoint | Your own feed — never point at the Dirnex feed |
| `README.md`, About panel, and user-visible strings | Your app's name |

Pointing a fork at the official Dirnex update feed is never permitted: it would
push official Dirnex builds onto your users, or your builds onto Dirnex users.

## Asking for permission

Anything this policy does not clearly allow, ask about first — permission is
often granted for reasonable uses. Open an issue at
<https://github.com/olegasd123/Dirnex/issues>.

## Not legal advice

This file describes how the project intends its name and artwork to be used. It
is a statement of policy, not a legal opinion, and it does not modify the
Apache License 2.0 in any way.
