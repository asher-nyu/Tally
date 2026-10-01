# Tally release materials

The App Store copy and public support pages in this folder describe Tally’s implemented file, schedule, and reminder behavior. The confirmed price is **Free** and the support address is **asherbloom@nyu.edu**.

## App Store copy

[AppStoreMetadata.json](AppStoreMetadata.json) contains the English name, subtitle, description, keywords, category, copyright, support contact, and review notes. It is a readable content draft, not an App Store Connect API request.

| Field | Draft | Length |
| --- | --- | ---: |
| Name | Tally: Cash Flow | 16 / 30 characters |
| Subtitle | Income, expenses & reminders | 28 / 30 characters |
| Description | Full text in the JSON file | 1,460 / 4,000 characters |
| Keywords | Search terms in the JSON file | 85 / 100 bytes |

The support URL is [tally.asher-nyu.com](https://tally.asher-nyu.com/) and the privacy URL is [tally.asher-nyu.com/privacy](https://tally.asher-nyu.com/privacy). The legacy `/privacy.html` address redirects to `/privacy`; both addresses open the same policy. The review phone number is entered privately in App Store Connect and is intentionally omitted from these project files. No review credentials are required by the app. App Store availability, age-rating answers, and submission status are managed separately.

Apple documents the name and subtitle limits under [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/) and the description, keyword, and review-contact requirements under [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/).

## Public support pages

The static site lives in [website](website). Its authored public files are:

- [Support](website/dist/index.html)
- [Privacy Policy](website/dist/privacy.html)
- [Shared styles](website/dist/styles.css)
- [Automatic copyright year](website/dist/copyright.js)

Both pages use relative links and an embedded favicon derived from Tally’s current icon layers. A small local script updates only the copyright year from the visitor’s device date. Tally’s page code includes no advertising, analytics, external font requests, or contact forms. System light and dark appearance is automatic. Their privacy text covers user-chosen file storage, iCloud and other providers, local reminder information, external websites, voluntary support email, Apple-managed diagnostics, and hosting cookies and connection information.

Vercel hosts the static site at `tally.asher-nyu.com`. [website/vercel.json](website/vercel.json) publishes `website/dist` with clean URLs, which redirect `/privacy.html` to `/privacy`. A September 29, 2026 verification confirmed that support and privacy return their expected pages over HTTPS, the redirect succeeds, and both deployed pages, the stylesheet, and the copyright script exactly match their local source files. App Store drafts, sound provenance notes, and local audio previews are outside the published directory.

## Checks performed

- Parsed both HTML pages and verified their relative page and asset references.
- Checked name, subtitle, description, and keyword lengths against App Store field limits.
- Rendered both pages with headless Chrome at 320, 390, 768, and 1,440 pixels in light and dark appearance; none had horizontal overflow.
- Checked 200% text enlargement at a 640-pixel viewport on both pages.
- Checked keyboard access to the visible skip link and native FAQ disclosure control.
- Verified the exact copyright notice on both pages with simulated device dates in 2026 and 2027.
- Visually inspected the phone support and privacy pages and desktop support page.
- Compared the public privacy text with the in-app Privacy & Support screen; their substantive disclosures agree.

These checks cover the public pages. They do not assert physical-device iCloud validation, a complete accessibility audit, or App Review approval.

## Submitted build 21

Version **1.0 (21)** was submitted for iOS/iPadOS and macOS on September 29, 2026.
Both platforms show **Waiting for Review** and will release automatically after
approval. The previous build 18 submissions were removed by the developer before
review. [Submission.md](Submission.md) and [SubmissionReceipt.json](SubmissionReceipt.json)
record the current submissions and verification.

Settings provides a per-device launch choice, with **Open last
used file** selected by default and **Show file browser** available as an alternative.
Use Tally → Settings or Command–Comma on Mac; use the … menu in the browser or
an open file on iPhone and iPad. The saved system bookmark follows the file when
its provider supports it; if the file cannot be opened, Tally shows the browser.
[LaunchSettingsVerification.json](LaunchSettingsVerification.json) records the
launch, Settings, and platform validation.

The submitted sound palette has six choices, in this order:
**Ripple** (default), **Pebble**, **Glow**, **Lift**, **Signal**, and **None**.
Ripple retains its original audio; the four other audible options have been
redesigned. Original audio previews are available in
[Sound Previews](Original%20Sound%20Previews/Preview.html).

Existing files and cached reminders remain readable. Retained sound identifiers
map to the new palette; retired choices and missing sound settings use Ripple.
The migration applies when a file or reminder cache is decoded, and pending
notifications are refreshed to use the current audio resources.

[SoundPaletteVerification.json](SoundPaletteVerification.json) records the local
build, sound resource checks, and regression tests for the palette and repeated
preview selection.

`Product Assets/Product Screenshots/Tally-iPhone-03.png` and its matching release
copy in `Release/App Store Screenshots/iPhone/` were recaptured from Release build
21 with Ripple selected. [ProductScreenshotVerification.json](ProductScreenshotVerification.json)
records the fictional scenario, native image dimensions, and capture checks.
The replacement was uploaded and visually verified in App Store Connect before
the iOS submission. The other eight screenshots remain unchanged.

For a future App Store update, reuse this exact What’s New wording:

> Bug fixes and improvements.

Apple does not provide this field for the initial version 1.0.

Unchanged verification reports for builds 17 and 18, along with the original
build 18 submission records, are preserved beside their Xcode archives at
`~/Library/Developer/Xcode/Archives/2026-09-27/Tally Build Verification/`.
Build 21 archives, signed exports, upload logs, verification, and submission
evidence are preserved under `~/Library/Developer/Xcode/Archives/2026-09-29/`.

## Sound provenance

[ToneLibraryRights.md](ToneLibraryRights.md) records the review of the early copied system recordings and their replacement with original synthesized audio before build 18 was submitted. The current default is **Ripple**, with four other original sounds and a silent option. [Design/SoundSources.md](../Design/SoundSources.md) documents the generation process, bundled resources, compatibility, and validation.

Copyright © 2026 Asher Bloom. All rights reserved.
