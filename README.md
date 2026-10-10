# Tally

Tally brings income, expenses, and their timing into one clear view on iPhone, iPad, and Mac. See what is coming, how much, and when—from the next bill to the year ahead.

[Tally on the App Store](https://apps.apple.com/app/tally-cash-flow/id6816792539)

![Tally on Mac, iPhone, and iPad](Product%20Assets/Device%20Mockups/Tally-Devices.png)

## Features

- **Monthly and annual views.** Review scheduled income, expenses, and net cash flow for the current period or another month or year.
- **Flexible schedules.** Organize monthly bills, income every two weeks, annual subscriptions, bonuses, and one-time income or expenses. Custom schedules support repeat intervals, selected weekdays and dates, weekday patterns, and optional end dates.
- **Fixed and variable amounts.** Keep fixed and variable income and expenses together. Totals include fixed amounts, with variable amounts clearly identified and excluded.
- **Income and expense reminders.** Choose a reminder time, advance notice, and sound for each income or expense. Ripple is the default. Choose Ripple, Pebble, Glow, Lift, Signal, or None. Selecting a sound plays its preview each time, even when it is already selected; None stops playback and keeps the notification silent.
- **Provider websites.** Save a website with income or an expense and open it from the app or its reminder.
- **Native controls.** Search, filter, and sort your finances with layouts adapted to each device, system light and dark appearance, and accessibility text sizing.
- **A familiar start.** Open the last used file by default, or choose the file browser in Settings. On Mac, use Tally → Settings or press Command–Comma. On iPhone and iPad, open the … menu from the file browser or an open file. Each device keeps its own launch preference.
- **Files you control.** Save, rename, move, and recover `.tally` files using native document workflows, with autosave and undo support. On iPhone and iPad, rename or share an open file from the … menu.

## Build and run

Use **Xcode 27** with the **Swift 6** toolchain. The deployment targets are **iOS 27, iPadOS 27, and macOS 27**. Install an iPhone or iPad simulator runtime in Xcode for mobile development. The Mac UI-test fixture driver also requires **Python 3**.

With GitHub SSH access configured, run these commands in an empty project directory:

```sh
git clone git@github.com:asher-nyu/Tally.git .
open Tally.xcodeproj
```

In Xcode, select the **Tally** scheme and choose **My Mac** or an installed iPhone or iPad simulator. Select your Apple Developer team in **Signing & Capabilities**, then run the app.

For iCloud development, provision an iCloud Documents container under your team. The project uses the bundle identifier `com.asherbloom.Tally` and the container `iCloud.com.asherbloom.Tally`. If you use different identifiers, update the Xcode signing settings, `Sources/Tally.entitlements`, `Sources/Tally-macOS.entitlements`, `Sources/Info.plist`, and the container identifier in `Sources/Storage/CloudDocuments.swift` together.

## Files and privacy

A `.tally` file stores income, expenses, currency, schedules, provider websites, and reminder preferences. New files use the name **Cash Flow.tally** and default to **iCloud Drive → Tally** when iCloud Drive is available. You can choose another location through the native file controls. Apple handles synchronization of files saved in iCloud Drive across devices signed into the same Apple Account.

The file format is versioned JSON. Amounts are stored as integers in the currency’s minor units to preserve exact values. The document layer validates files, migrates earlier formats, and merges independent changes. Conflicting changes to the same item are preserved for review.

Tally does not send financial files or app usage to the developer. Reminder information is cached locally on each device so notifications can remain scheduled while a file is closed. The launch preference and a system bookmark for the last used file are also stored locally. See the [privacy policy](https://tally.asher-nyu.com/privacy) for details about file providers, reminders, external websites, and support.

## Reminders

Tally requests notification permission when an enabled reminder is saved. Reminder timing and sound preferences are stored in the file; permission and scheduled notifications are managed separately on each device.

Compatible schedules use repeating calendar notifications. Other schedules use upcoming dated notifications, with automatic maintenance through Apple’s background execution APIs. System notification settings, Focus, and operating-system scheduling determine presentation and delivery.

Before deleting a closed file in Finder or Files, disable its reminders in Tally and save the change on each device where those reminders were enabled. External deletion of a closed file does not remove its cached reminders. Deletion detected while a file is open cancels that file’s reminders.

## Testing

The project uses **Swift Testing** for unit tests and **XCTest** for UI tests. Unit coverage includes money parsing, recurrence rules, period totals, document validation and migration, merging, undo, file lifecycle, and reminder scheduling. UI tests exercise editing, navigation, search, accessibility layouts, document recovery, Settings, and relaunch behavior with isolated fixtures.

Run the Mac unit suite from the project root:

```sh
xcodebuild test \
  -project Tally.xcodeproj \
  -scheme Tally \
  -destination 'platform=macOS' \
  -only-testing:TallyTests
```

Run the Mac UI suite with its document fixture driver:

```sh
python3 Scripts/native_document_fixture_driver.py -- xcodebuild test \
  -project Tally.xcodeproj \
  -scheme Tally \
  -destination 'platform=macOS' \
  -only-testing:TallyUITests
```

The driver coordinates restoration and removal of specific disposable test files. It is required for the Mac Trash regressions. Keep the desktop available to the test runner while UI tests run.

List installed test destinations:

```sh
xcodebuild -project Tally.xcodeproj -scheme Tally -showdestinations
```

Run the suites on an iPhone or iPad simulator, replacing `<SIMULATOR_UDID>` with its destination identifier:

```sh
xcodebuild test \
  -project Tally.xcodeproj \
  -scheme Tally \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>'
```

Manual verification should cover Mac window sizes, iPhone and iPad layouts, light and dark appearance, larger text, document moves and recovery, and notification presentation. Verify iCloud changes across physical devices separately from simulator tests. Use fictional data for testing and product imagery.

Build-specific verification and submission records are kept in [Release](Release/README.md).

## Project structure

| Path | Purpose |
| --- | --- |
| `Sources/TallyApp.swift` | App entry point and native document scenes. |
| `Sources/TallyDocument.swift` | Document snapshots, serialization, undo, and incoming changes. |
| `Sources/ContentView.swift`, `Sources/Views/` | Cash-flow overview, lists, editing, and platform controls. |
| `Sources/Domain/` | Money, schedules, file validation, migration, and merging. |
| `Sources/Storage/` | iCloud locations and native document lifecycle. |
| `Sources/Services/` | Notifications, background maintenance, sound previews, and website actions. |
| `Sources/TallyIcon.icon` | Layered Icon Composer app icon. |
| `Tests/Unit/`, `Tests/UI/` | Automated tests and isolated fixtures. |
| `Scripts/` | Native document test utilities. |
| `Design/` | Icon artwork and sound provenance. |
| `Product Assets/` | Fictional scenarios, screenshots, and device mockups. |
| `Release/` | Release records, App Store metadata, and support website source. |

## Support

[Support website](https://tally.asher-nyu.com/) · [Privacy policy](https://tally.asher-nyu.com/privacy) · [asherbloom@nyu.edu](mailto:asherbloom@nyu.edu)

Copyright © 2026 Asher Bloom. All rights reserved.
