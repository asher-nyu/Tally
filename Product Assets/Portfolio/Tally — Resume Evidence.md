# Tally resume evidence

Prepared September 27, 2026 and revised September 28, 2026 for post-launch use at the user's request. The master-resume entry uses the requested date, **Sep 2026 – Present**. The original master-resume attachment was read for style and was not modified.

| Resume claim | Local evidence |
| --- | --- |
| Shared SwiftUI app with native platform integration | `Sources/TallyApp.swift`, `Sources/ContentView.swift`, `Sources/Storage/MobileDocumentBrowser.swift`, `Sources/Storage/MobileTallyDocument.swift` |
| Monthly/yearly totals and recurrence rules | `Sources/Domain/Ledger.swift`, `Sources/Domain/CustomRecurrence.swift`, `Sources/Views/LedgerOverviewView.swift` |
| Exact integer amounts and locale-aware validation | `Sources/Domain/Money.swift`, `Sources/Domain/LedgerCodec.swift` |
| Versioned .tally documents, migration, autosave, undo | `Sources/TallyDocument.swift`, `Sources/Domain/LedgerCodec.swift`, `Sources/Storage/MobileTallyDocument.swift`, `Sources/Storage/CloudDocuments.swift` |
| Three-way merges and undo rebasing | `Sources/Domain/LedgerMerger.swift`, `Sources/TallyDocument.swift` |
| Coordinated moves, deletion, recovery, and scoped access | `Sources/Storage/MacDocumentLifetime.swift`, `Sources/Storage/MobileTallyDocument.swift`, `Sources/Storage/MobileDocumentBrowser.swift` |
| Reminder options, allocation fairness, serialized reconciliation | `Sources/Domain/PaymentReminder.swift`, `Sources/Services/NotificationCoordinator.swift`, `Sources/Views/ReminderSection.swift` |
| Automatic background maintenance | `Sources/Services/ReminderBackgroundRefresh.swift` |
| Adaptive layouts and accessibility features | `Sources/ContentView.swift`, `Sources/Views/ExpenseRowView.swift`, `Sources/Views/LedgerOverviewView.swift`, `Tests/UI/TallyPeriodAppearanceTests.swift` |
| 209 passing tests in 13 suites | `Release/Submission.md`, `Release/SubmissionReceipt.json` |
| UI regressions and isolated data | `Tests/UI/`, `README.md`, `Scripts/native_document_fixture_driver.py` |
| Icon, sounds, and fictional scenarios | `Sources/TallyIcon.icon`, `Design/IconSources/`, `Design/SoundSources.md`, `Product Assets/Scenarios/`, `Product Assets/Storyboard.md` |
| Signed and submitted releases | Build 18 verification report beside the Xcode archives, `Release/Submission.md`, `Release/SubmissionReceipt.json` |
| Public support/privacy site | `Release/website/dist/`, `Release/Submission.md` |

The saved submission receipt verifies **Waiting for Review** for both platforms on September 27, 2026. The user explicitly requested wording for the future point when the app has launched, so the resume intentionally says **published** under that post-launch assumption. This is not a newly verified release status, and the submission receipt was not changed. The resume includes **[Add App Store link]**, and the portfolio JSON leaves **projectUrl** empty for the user to supply the real App Store URL.

The portfolio description contains **169 characters**, comparable to the other supplied project descriptions, and emphasizes product value rather than implementation technologies.

No customer counts, performance improvements, full accessibility conformance, verified physical-device iCloud syncing, or guaranteed indefinite notification delivery are claimed. The background-maintenance bullet describes the implemented mechanisms without promising system execution.
