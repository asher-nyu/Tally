import SwiftUI

#if !DEBUG
@main
#endif
struct TallyApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(TallyMacAppDelegate.self) private var appDelegate
    #endif

    init() {
        #if DEBUG && os(iOS)
        if !MobileDocumentTestSupport.isEnabled && !MobileLaunchEnvironment.isLaunchTestEnabled { CloudDocuments.shared.start() }
        #else
        #if DEBUG && os(macOS)
        if !NativeDocumentTestSupport.isEnabled && !MacLaunchTestSupport.isEnabled {
            CloudDocuments.shared.start()
        }
        #else
        CloudDocuments.shared.start()
        #endif
        #endif
        ReminderBackgroundRefresh.shared.start {
            await NotificationCoordinator.shared.reconcileNow()
        }
        NotificationCoordinator.shared.start()
    }

    var body: some Scene {
        #if os(iOS)
        WindowGroup { MobileDocumentsView() }
        #else
        documents
            .commands { TallyPrivacyCommands() }
        Settings {
            TallySettingsView()
                .defaultAppStorage(MacLaunchEnvironment.defaults)
        }
        .defaultSize(width: 460, height: 180)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        Window("Privacy & Support", id: TallyPrivacyWindowContent.windowIdentifier) {
            TallyPrivacyWindowContent()
        }
        .defaultSize(width: 600, height: 640)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        #endif
    }

    private var documents: some Scene {
        DocumentGroup { document in
            ContentView(document: document)
                .tint(.accentColor)
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 420)
                .background(MacDocumentLocation())
                .background(MacDocumentLifetime(document: document))
                #endif
        } makeDocument: { configuration, _ in
            TallyDocument(configuration: configuration)
        }
        .defaultSize(width: 860, height: 680)
        #if os(macOS)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        #endif
    }
}

#if DEBUG
@main
enum TallyDebugMain {
    @MainActor
    static func main() {
        #if os(iOS)
        if MobileLaunchEnvironment.isLaunchTestEnabled {
            do { try MobileLaunchTestSupport.prepare() }
            catch { fatalError("Mobile launch test setup failed: \(error)") }
            TallyApp.main()
            return
        }
        if MobileDocumentTestSupport.isEnabled {
            TallyApp.main()
            return
        }
        #endif
        #if os(macOS)
        if MacLaunchTestSupport.isEnabled {
            do { try MacLaunchTestSupport.prepare() }
            catch { fatalError("Launch test setup failed: \(error)") }
            TallyApp.main()
            return
        }
        if NativeDocumentTestSupport.isEnabled {
            NativeDocumentTestSupport.install()
            TallyApp.main()
            return
        }
        #endif
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            TallyUITestApp.main()
        } else {
            TallyApp.main()
        }
    }
}

private struct TallyUITestApp: App {
    var body: some Scene {
        WindowGroup { UITestDocumentView() }
        #if os(macOS)
            .defaultLaunchBehavior(.presented)
            .restorationBehavior(.disabled)
            .defaultSize(width: 900, height: 760)
        #endif
    }
}

private struct UITestDocumentView: View {
    @State private var document: TallyDocument

    init() {
        var ledger = ProcessInfo.processInfo.arguments.contains("--ui-testing-populated")
            ? Self.populatedLedger : Ledger()
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-date-spacing") {
            ledger = Ledger(expenses: [
                Expense(
                    id: UUID(uuidString: "00000000-0000-4000-8000-000000000017")!,
                    merchant: "Meal delivery", amountMinor: 7_500, category: .food,
                    recurrence: .custom,
                    anchorDate: ScheduleDate(year: 2026, month: 10, day: 7),
                    customRecurrence: CustomRecurrence(frequency: .daily, interval: 16)
                )
            ])
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-scroll-overflow") {
            let day = ScheduleDate(date: .now, calendar: CashFlowPeriod.calendar).day
            ledger.expenses += (1...8).map { index in
                Expense(merchant: "Sample membership \(index)", amountMinor: 1_000,
                        billingDay: day, category: .subscriptions)
            }
        }
        _document = State(initialValue: TallyDocument(ledger: ledger))
    }

    private static var populatedLedger: Ledger {
        let today = ScheduleDate(date: .now, calendar: CashFlowPeriod.calendar)
        return Ledger(expenses: [
            Expense(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                merchant: "Apartment rent", amountMinor: 145_000, billingDay: today.day,
                category: .housing, websiteLink: "https://example.com/rent",
                reminder: PaymentReminder(daysBefore: 1, hour: 9, minute: 0)
            ),
            Expense(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                merchant: "Broadband", amountMinor: 6_500, billingDay: today.day,
                category: .utilities
            ),
            Expense(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
                merchant: "Cedar creative software subscription", amountMinor: 24_000,
                category: .subscriptions, recurrence: .annual, anchorDate: today,
                websiteLink: "https://example.com/software"
            ),
            Expense(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
                merchant: "Harbor Studio salary", amountMinor: 210_000,
                category: .income, kind: .income, recurrence: .everyTwoWeeks, anchorDate: today
            ),
            Expense(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000005")!,
                merchant: "Project bonus", amountMinor: 80_000,
                category: .income, kind: .income, recurrence: .oneTime, anchorDate: today
            ),
            Expense(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000006")!,
                merchant: "Transit pass", amountMinor: 9_000, billingDay: today.day,
                category: .transport
            ),
            Expense(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000007")!,
                merchant: "Electricity", category: .utilities
            )
        ])
    }

    var body: some View {
        ContentView(document: document)
            .tint(.accentColor)
            .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--ui-testing-accessibility-text") ? .accessibility5 : .large)
            #if os(macOS)
            .background(UITestWindowActivation())
            .frame(minWidth: ProcessInfo.processInfo.arguments.contains("--ui-testing-wide-window") ? 900 : 560,
                   minHeight: 760)
            #endif
    }
}

#if os(macOS)
/// A fresh test launch must not inherit a hidden or minimized production window.
private struct UITestWindowActivation: NSViewRepresentable {
    func makeNSView(context: Context) -> ActivationView { ActivationView() }
    func updateNSView(_ view: ActivationView, context: Context) {}

    final class ActivationView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            Task { @MainActor [weak window] in
                await Task.yield()
                window?.deminiaturize(nil)
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        }
    }
}
#endif
#endif
