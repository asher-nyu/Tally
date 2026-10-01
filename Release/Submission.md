# Tally 1.0 release

Version **1.0 (21)** was submitted for iOS/iPadOS and macOS on September 29, 2026.
Both platforms show **Waiting for Review** in App Store Connect. Each platform is
configured to release automatically after approval. This record confirms
submission; it does not assert App Review approval or public availability.

App Store Connect app ID: 6816792539. Store name: Tally: Cash Flow. Installed app
name: Tally. Price: Free. Primary category: Finance.

Copyright © 2026 Asher Bloom. All rights reserved. Website copyright year updates automatically.

## Submission status

| Platform | Version and build | Submitted September 29, 2026 | Status |
| --- | --- | --- | --- |
| iOS/iPadOS | 1.0 (21) | 8:20 PM America/New_York | Waiting for Review |
| macOS | 1.0 (21) | 8:16 PM America/New_York | Waiting for Review |

- [iOS/iPadOS submission](https://appstoreconnect.apple.com/apps/6816792539/distribution/reviewsubmissions/details/273a3c4d-c55f-47a7-a4a5-327c8c665a67)
- [macOS submission](https://appstoreconnect.apple.com/apps/6816792539/distribution/reviewsubmissions/details/5a92b018-e41e-4ce6-96e6-0081b82c7fbf)

The selected build and automatic-release setting were verified before each
submission. App Review shows both new submissions waiting and the previous
September 27 submissions removed. The developer withdrew build 18 before review
to replace it with build 21. [SubmissionReceipt.json](SubmissionReceipt.json)
records the submission identifiers, status, and verification paths.

## Included changes

Settings offers **Open last used file** by default and **Show file browser** as an
alternative. On Mac, Settings is available through the application menu and
Command–Comma. On iPhone and iPad, the options menu opens Settings from both the
file browser and an open file. System bookmarks retain the last file; an
unavailable file returns the user to the browser. Explicit file opens take
precedence over automatic reopening.

The sound choices are **Ripple** (default), **Pebble**, **Glow**, **Lift**,
**Signal**, and **None**. The five audible resources are original synthesized
recordings. Selecting the current sound previews it again. Existing files and
cached reminders migrate to the current palette when decoded.

The third iPhone screenshot was recaptured from Release build 21 with Ripple
selected, using the existing fictional scenario. Its status bar displays 9:41,
with the capture date set to Monday, September 28. The replacement was uploaded
and visually verified in App Store Connect. The other eight screenshots remain
unchanged. [ProductScreenshotVerification.json](ProductScreenshotVerification.json)
records the native capture and file hash.

## Verification

Both production archives were distribution-signed, exported, and uploaded
successfully. Their exports passed strict signature verification, use Production
iCloud with the expected container, have debugging disabled, and contain the
current icon, privacy manifest, and five audio resources matching source hashes.
The Mac export includes the security-scoped bookmark entitlement. Both upload
logs report success without errors or warnings.

[LaunchSettingsVerification.json](LaunchSettingsVerification.json) records the
pre-submission regression checks: 238 passing Mac unit tests, 32 passing focused
mobile unit tests, five passing Mac UI tests, and focused iPhone and iPad UI
runs covering Settings, reopening, explicit file opens, missing files, and large
text in system appearance modes. The report includes a Mac test runtime QoS
warning and distinguishes overlapping focused UI reruns; those reruns are not
summed as unique tests. [SoundPaletteVerification.json](SoundPaletteVerification.json)
records sound resource checks and repeated-selection regressions. The final
native screenshot capture passed its dedicated UI test.

Mobile validation used simulators. Physical-device iCloud syncing and
system-granted iOS background delivery have not been verified. Reminder delivery
and background execution remain controlled by the operating system.

The archives are preserved in Xcode’s usual Archives directory:

- `~/Library/Developer/Xcode/Archives/2026-09-29/Tally iOS 1.0 (21).xcarchive`
- `~/Library/Developer/Xcode/Archives/2026-09-29/Tally Mac 1.0 (21).xcarchive`

Signed exports, distribution checks, upload receipts, and App Store Connect
submission evidence are preserved in
`~/Library/Developer/Xcode/Archives/2026-09-29/Tally Build21 Distribution/`.
Original build 18 records and earlier verification reports remain unchanged in
`~/Library/Developer/Xcode/Archives/2026-09-27/Tally Build Verification/`.

## Public information

The support and privacy pages were verified over HTTPS before submission and
match their local source. The legacy privacy address redirects to the canonical
policy URL.

- Support: [tally.asher-nyu.com](https://tally.asher-nyu.com/)
- Privacy: [tally.asher-nyu.com/privacy](https://tally.asher-nyu.com/privacy)
- Support email: asherbloom@nyu.edu

The review contact phone remains entered privately in App Store Connect and is
omitted from these project files. No reminder backend was added; files and
scheduling remain on-device and in the user's chosen storage.

Apple does not provide a What’s New field for this initial version 1.0. For a
future update, retain the requested exact text: **Bug fixes and improvements.**
