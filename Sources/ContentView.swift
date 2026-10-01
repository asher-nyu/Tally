import SwiftUI
import UserNotifications

private struct WebsiteActionLabelStyle: LabelStyle {
    let showsTitle: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            if showsTitle { configuration.title }
        }
    }
}

private struct PeriodResetButtonStyle: ButtonStyle {
    @ScaledMetric(relativeTo: .subheadline) private var labelSize: CGFloat = 13
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: labelSize, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            #if os(macOS)
            .frame(minHeight: 24)
            .background(Color(nsColor: .quaternaryLabelColor), in: RoundedRectangle(cornerRadius: 5))
            #else
            .frame(minHeight: 32)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            #endif
            .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.65 : 1)
            #if os(iOS)
            // The surface follows the native segmented control's scale;
            // the transparent touch target remains comfortably tappable.
            .frame(minHeight: 44)
            #endif
            .contentShape(Rectangle())
    }
}

struct ContentView: View {
    @Bindable var document: TallyDocument
    var documentUndoManager: UndoManager? = nil
    #if os(iOS)
    var mobileDocumentCommands: MobileDocumentCommands? = nil
    #endif
    @Environment(\.undoManager) private var environmentUndoManager
    private var undoManager: UndoManager? { documentUndoManager ?? environmentUndoManager }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    @State private var currentDate = Date()
    @State private var periodKind = CashFlowPeriod.Kind.month
    @State private var selectedPeriodDate: Date?
    @State private var searchText = ""
    @State private var filter = ExpenseFilter.all
    @State private var sortOrder = ExpenseSort.billingDate
    @State private var editor: ExpenseEditorContext?
    @State private var expenseToDelete: Expense?
    @State private var openingWebsiteID: UUID?
    @State private var websiteOpenFailure: Expense?
    @State private var notificationSettingsError = false
    @State private var notifications = NotificationCoordinator.shared

    private var displayedPeriod: CashFlowPeriod {
        CashFlowPeriod(kind: periodKind, date: selectedPeriodDate ?? currentDate, today: currentDate)
    }

    private var visibleExpenses: [Expense] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return document.ledger.expenses
            .filter { expense in
                filter.includes(expense) && (
                    query.isEmpty || [expense.merchant, expense.kind.title, expense.category.title, expense.recurrenceSummary, expense.notes]
                        .contains { $0.localizedStandardContains(query) }
                )
            }
            .sorted { sortOrder.comparison($0, $1, period: displayedPeriod) }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let isCompact = geometry.size.width < 760 || dynamicTypeSize.isAccessibilitySize
                let inset: CGFloat = isCompact ? 20 : 28
                if document.ledger.expenses.isEmpty {
                    emptyLedger
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                } else {
                    List {
                        periodControls(isCompact: isCompact)
                            .listRowInsets(EdgeInsets(top: isCompact ? 18 : 24, leading: inset, bottom: 16, trailing: inset))
                            .listRowSeparator(.hidden)

                        LedgerOverviewView(
                            ledger: document.ledger,
                            totals: displayedPeriod.totals(for: document.ledger),
                            isCompact: isCompact,
                            period: displayedPeriod
                        )
                            .listRowInsets(EdgeInsets(top: 0, leading: inset, bottom: 16, trailing: inset))
                            .listRowSeparator(.hidden)

                        expenseControls(isCompact: isCompact)
                            .listRowInsets(EdgeInsets(top: 8, leading: inset, bottom: 12, trailing: inset))
                            .listRowSeparator(.hidden)

                        if visibleExpenses.isEmpty {
                            noMatchingExpenses
                                .frame(maxWidth: .infinity, minHeight: 250)
                                .listRowSeparator(.hidden)
                        } else {
                            HStack(spacing: 14) {
                                Text(expenseCountLabel)
                                Spacer()
                                if !isCompact {
                                    Text("Date")
                                        .frame(width: 128, alignment: .leading)
                                }
                                if !dynamicTypeSize.isAccessibilitySize {
                                    Text("Amount")
                                        .frame(minWidth: isCompact ? 72 : 120, alignment: .trailing)
                                }
                                if hasWebsiteLinks && !dynamicTypeSize.isAccessibilitySize {
                                    Color.clear.frame(width: websiteAccessoryWidth, height: 1)
                                        .accessibilityHidden(true)
                                }
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color("SecondaryText"))
                            .listRowInsets(EdgeInsets(top: 4, leading: inset, bottom: 8, trailing: inset))
                            .listRowSeparator(.hidden)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(expenseCountLabel)

                            ForEach(visibleExpenses) { expense in
                                expenseRow(expense, isCompact: isCompact)
                                    .listRowInsets(EdgeInsets(top: 10, leading: inset, bottom: 10, trailing: inset))
                                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                                    .listRowSeparatorTint(.secondary.opacity(0.15))
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollIndicators(.never)
                    .scrollContentBackground(.hidden)
                    .background(.background)
                    .accessibilityIdentifier("expenseList")
                    .accessibilityLabel("Income and expenses")
                }
            }
            .navigationTitle("Cash flow")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(mobileDocumentCommands == nil ? .automatic : .hidden, for: .navigationBar)
            .onChange(of: mobileDocumentCommands?.addRequest) { _, _ in
                editor = ExpenseEditorContext(expense: nil)
            }
            .onChange(of: mobileDocumentCommands?.searchText) { _, text in
                if let text { searchText = text }
            }
            #endif
            .searchable(text: $searchText, prompt: "Search income and expenses")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editor = ExpenseEditorContext(expense: nil)
                    } label: {
                        Label("Add income or expense", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("Add income or expense (⇧⌘N)")
                    .accessibilityIdentifier("addExpenseButton")
                    .disabled(document.ledger.expenses.count >= LedgerCodec.maximumExpenseCount)
                }
            }
            .sheet(item: $editor) { context in
                ExpenseEditorView(expense: context.expense, currencyCode: document.ledger.currencyCode) { expense in
                    document.updateExpense(expense, original: context.expense, undoManager: undoManager)
                    notifications.attach(document.ledger)
                }
                .dynamicTypeSize(dynamicTypeSize)
            }
            .alert("Couldn’t update document", isPresented: Binding(
                get: { document.mutationError != nil },
                set: { if !$0 { document.mutationError = nil } }
            )) {
                Button("OK") { document.mutationError = nil }
            } message: {
                Text(document.mutationError ?? "")
            }
            .alert("Couldn’t open website", isPresented: Binding(
                get: { websiteOpenFailure != nil },
                set: { if !$0 { websiteOpenFailure = nil } }
            ), presenting: websiteOpenFailure) { expense in
                Button("Edit website") {
                    editor = ExpenseEditorContext(expense: expense)
                }
                Button("Cancel", role: .cancel) { }
            } message: { _ in
                Text("Check the website address and try again.")
            }
            .alert("Couldn’t open Settings", isPresented: $notificationSettingsError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Open Settings, choose Notifications, then select Tally.")
            }
            .confirmationDialog(
                expenseToDelete?.kind == .income ? "Delete income?" : "Delete expense?",
                isPresented: Binding(
                    get: { expenseToDelete != nil },
                    set: { if !$0 { expenseToDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: expenseToDelete
            ) { expense in
                Button("Delete \(expense.merchant)", role: .destructive) {
                    document.deleteExpenses(ids: [expense.id], undoManager: undoManager)
                    expenseToDelete = nil
                }
                .accessibilityIdentifier("confirmDeleteExpenseButton")
                Button("Cancel", role: .cancel) { expenseToDelete = nil }
            } message: { expense in
                Text("\(expense.merchant) will be removed from this document. You can undo this change.")
            }
        }
        .tint(.accentColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cash flow")
        #if os(macOS)
        .background(WindowAccessibilityLabel(label: "Cash flow"))
        #endif
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                currentDate = .now
                Task { await notifications.refreshAuthorizationStatus() }
            }
        }
        .onChange(of: document.ledger, initial: true) { _, ledger in
            notifications.attach(ledger)
        }
        .safeAreaInset(edge: .bottom) {
            if hasReminderNotice {
                reminderStatus
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.bar)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            currentDate = .now
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: RunLoop.main)) { _ in
            currentDate = .now
        }
    }

    private func periodControls(isCompact: Bool) -> some View {
        Group {
            if isCompact {
                VStack(alignment: .leading, spacing: 12) {
                    if dynamicTypeSize.isAccessibilitySize {
                        compactPeriodKindPicker
                        currentPeriodButton
                    } else {
                        HStack {
                            compactPeriodKindPicker
                            Spacer()
                            currentPeriodButton
                        }
                    }
                    HStack(spacing: 12) {
                        periodTitle
                            .frame(maxWidth: .infinity, alignment: .leading)
                        periodNavigation
                            .fixedSize(horizontal: true, vertical: true)
                    }
                }
            } else {
                HStack(spacing: 20) {
                    periodTitle
                        .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                    widePeriodActions
                }
            }
        }
    }

    private var compactPeriodKindPicker: some View {
        #if os(macOS)
        periodKindPicker.fixedSize(horizontal: true, vertical: true)
        #else
        periodKindPicker.frame(maxWidth: 180)
        #endif
    }

    private var widePeriodActions: some View {
        HStack(spacing: 16) {
            currentPeriodButton
            #if os(macOS)
            periodKindPicker.fixedSize(horizontal: true, vertical: true)
            #else
            periodKindPicker.frame(width: 160)
            #endif
            periodNavigation.fixedSize(horizontal: true, vertical: true)
        }
        .fixedSize(horizontal: true, vertical: true)
        .layoutPriority(1)
    }

    private var periodTitle: some View {
        Text(displayedPeriod.title)
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("selectedPeriodTitle")
    }

    private var periodKindPicker: some View {
        Picker("Period", selection: $periodKind) {
            ForEach(CashFlowPeriod.Kind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("periodKindPicker")
    }

    private var currentPeriodButton: some View {
        let button = Button {
            selectedPeriodDate = nil
        } label: {
            Text("This \(periodKind.unit)")
                .fixedSize()
                .frame(minWidth: 76)
        }
        .buttonStyle(PeriodResetButtonStyle())
        .accessibilityIdentifier("currentPeriodButton")

        return Group {
            if displayedPeriod.isCurrent {
                // Reserve the native button's size without exposing an
                // unavailable action to sight, touch, or VoiceOver.
                button.hidden()
            } else {
                button
            }
        }
    }

    private var periodNavigation: some View {
        HStack(spacing: 4) {
            Button {
                selectedPeriodDate = displayedPeriod.adjacentDate(offset: -1)
            } label: {
                periodArrow("chevron.left")
            }
            .accessibilityLabel("Previous \(periodKind.unit)")
            .accessibilityIdentifier("previousPeriodButton")
            .disabled(displayedPeriod.adjacentDate(offset: -1) == nil)

            Button {
                selectedPeriodDate = displayedPeriod.adjacentDate(offset: 1)
            } label: {
                periodArrow("chevron.right")
            }
            .accessibilityLabel("Next \(periodKind.unit)")
            .accessibilityIdentifier("nextPeriodButton")
            .disabled(displayedPeriod.adjacentDate(offset: 1) == nil)
        }
        .buttonStyle(.borderless)
        .tint(.primary)
    }

    private func periodArrow(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            #if os(macOS)
            .frame(width: 28, height: 28)
            #else
            .frame(width: 44, height: 44)
            #endif
            .contentShape(Rectangle())
    }

    private func expenseControls(isCompact: Bool) -> some View {
        HStack(spacing: 16) {
            if dynamicTypeSize.isAccessibilitySize {
                #if os(macOS)
                MacMenuPicker("Filter income and expenses", options: ExpenseFilter.allCases.map(\.title), selection: filterIndex, identifier: "expenseFilterPicker")
                #else
                filterPicker.pickerStyle(.menu)
                #endif
            } else {
                filterPicker
                    .pickerStyle(.segmented)
                    #if os(macOS)
                    .fixedSize(horizontal: true, vertical: true)
                    #else
                    .frame(maxWidth: isCompact ? .infinity : 340)
                    #endif
            }

            Spacer(minLength: 0)

            sortControl
        }
    }

    private var sortControl: some View {
        Group {
            #if os(macOS)
            MacMenuPicker("Sort income and expenses", options: ExpenseSort.allCases.map(\.title), selection: sortIndex, identifier: "expenseSortMenu")
            .fixedSize()
            #else
            Menu {
                Picker("Sort income and expenses", selection: $sortOrder) {
                    sortOptions
                }
            } label: {
                Label("Sort income and expenses", systemImage: "arrow.up.arrow.down")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityValue(sortOrder.title)
            #endif
        }
        .accessibilityIdentifier("expenseSortMenu")
        .help("Sort income and expenses")
    }

    private var sortIndex: Binding<Int> {
        Binding(
            get: { ExpenseSort.allCases.firstIndex(of: sortOrder) ?? 0 },
            set: { index in
                guard ExpenseSort.allCases.indices.contains(index) else { return }
                sortOrder = ExpenseSort.allCases[index]
            }
        )
    }

    private var filterIndex: Binding<Int> {
        Binding(
            get: { ExpenseFilter.allCases.firstIndex(of: filter) ?? 0 },
            set: { index in
                guard ExpenseFilter.allCases.indices.contains(index) else { return }
                filter = ExpenseFilter.allCases[index]
            }
        )
    }

    private var sortOptions: some View {
        ForEach(ExpenseSort.allCases) { order in
            Text(order.title).tag(order)
        }
    }

    private var filterPicker: some View {
        Picker("Filter income and expenses", selection: $filter) {
            ForEach(ExpenseFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .labelsHidden()
        .accessibilityIdentifier("expenseFilterPicker")
    }

    private var hasWebsiteLinks: Bool {
        visibleExpenses.contains { (try? ProviderLink.websiteURL($0.websiteLink)) != nil }
    }

    private var websiteAccessoryWidth: CGFloat {
        #if os(macOS)
        28
        #else
        44
        #endif
    }

    @ViewBuilder
    private func expenseRow(_ expense: Expense, isCompact: Bool) -> some View {
        #if os(macOS)
        MacRowContextMenu(items: rowMenuItems(for: expense)) {
            expenseRowContent(expense, isCompact: isCompact)
        }
        #else
        expenseRowContent(expense, isCompact: isCompact)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contextMenu { rowMenu(for: expense) }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    expenseToDelete = expense
                }
            }
        #endif
    }

    private func expenseRowContent(_ expense: Expense, isCompact: Bool) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        return layout {
            Button {
                editor = ExpenseEditorContext(expense: expense)
            } label: {
                ExpenseRowView(
                    expense: expense,
                    currencyCode: document.ledger.currencyCode,
                    isCompact: isCompact,
                    period: displayedPeriod
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("expenseRow-\(expense.id.uuidString)")
            .accessibilityHint("Edit \(expense.kind.title.lowercased())")

            if let website = try? ProviderLink.websiteURL(expense.websiteLink) {
                Button {
                    openWebsite(website, for: expense)
                } label: {
                    Group {
                        if openingWebsiteID == expense.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Open website", systemImage: "arrow.up.right.square")
                                .labelStyle(WebsiteActionLabelStyle(showsTitle: dynamicTypeSize.isAccessibilitySize))
                                .font(.body)
                        }
                    }
                    .frame(minWidth: websiteAccessoryWidth, minHeight: websiteAccessoryWidth)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(openingWebsiteID != nil)
                .help("Open \(expense.merchant) website")
                .accessibilityLabel("Open \(expense.merchant) website")
                .accessibilityIdentifier("openWebsite-\(expense.id.uuidString)")
            } else if hasWebsiteLinks && !dynamicTypeSize.isAccessibilitySize {
                Color.clear.frame(width: websiteAccessoryWidth, height: 1)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    #if os(macOS)
    private func rowMenuItems(for expense: Expense) -> [MacRowContextMenuItem] {
        var items: [MacRowContextMenuItem] = [
            .action(title: "Edit…", systemImage: "pencil", action: {
                editor = ExpenseEditorContext(expense: expense)
            })
        ]
        if let website = try? ProviderLink.websiteURL(expense.websiteLink) {
            items.append(.action(title: "Open website", systemImage: "arrow.up.right.square",
                                 isEnabled: openingWebsiteID == nil, action: {
                openWebsite(website, for: expense)
            }))
        }
        items.append(.separator)
        items.append(.action(title: "Delete…", systemImage: "trash", isDestructive: true, action: {
            expenseToDelete = expense
        }))
        return items
    }
    #else
    @ViewBuilder
    private func rowMenu(for expense: Expense) -> some View {
        Button("Edit…", systemImage: "pencil") {
            editor = ExpenseEditorContext(expense: expense)
        }
        if let website = try? ProviderLink.websiteURL(expense.websiteLink) {
            Button("Open website", systemImage: "arrow.up.right.square") {
                openWebsite(website, for: expense)
            }
            .disabled(openingWebsiteID != nil)
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) {
            expenseToDelete = expense
        }
    }
    #endif

    private func openWebsite(_ website: URL, for expense: Expense) {
        guard openingWebsiteID == nil else { return }
        openingWebsiteID = expense.id
        Task {
            defer { openingWebsiteID = nil }
            if !(await ProviderWebsiteOpener.live.open(website)) {
                websiteOpenFailure = expense
            }
        }
    }

    private var expenseCountLabel: String {
        "Income & expenses"
    }

    @ViewBuilder
    private var reminderStatus: some View {
        if notifications.authorizationStatus == .denied {
            reminderNotice("Notifications are off for Tally. Enable them to receive payment reminders.") {
                Button("Open notification settings") {
                    Task { notificationSettingsError = !(await NotificationSettingsOpener.open()) }
                }
            }
        } else if notifications.authorizationStatus == .notDetermined {
            reminderNotice("Allow notifications to receive payment reminders on this device.") {
                Button("Allow notifications") {
                    Task { _ = await notifications.requestPermission() }
                }
            }
        } else if let error = notifications.schedulingError {
            reminderNotice(error) {
                Button("Try again") { Task { await notifications.reconcileNow() } }
            }
        } else if notifications.coverage.unscheduledEntryCount > 0 {
            reminderNotice(capacityNotice) {
                Button("Try again") { Task { await notifications.reconcileNow() } }
            }
        }
    }

    private var hasReminderNotice: Bool {
        let hasReminders = notifications.coverage.enabledEntryCount > 0 || document.ledger.expenses.contains { $0.reminder != nil }
        return notifications.schedulingError != nil || (hasReminders && (
            !notifications.authorizationStatus.allowsScheduling || notifications.coverage.unscheduledEntryCount > 0
        ))
    }

    private var capacityNotice: String {
        let count = notifications.coverage.unscheduledEntryCount
        return count == 1
            ? "One reminder could not be scheduled on this device."
            : "\(count) reminders could not be scheduled on this device."
    }

    private func reminderNotice<Action: View>(_ message: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "bell")
            }
            action()
                .buttonStyle(.borderless)
        }
        .font(.subheadline)
        .accessibilityIdentifier("reminderSchedulingStatus")
    }

    private var emptyLedger: some View {
        ContentUnavailableView {
            Label("Know what’s coming.", systemImage: "arrow.down.left.arrow.up.right")
        } description: {
            Text("Keep income, expenses, and payment dates together.")
        } actions: {
            Button("Add income or expense", systemImage: "plus") {
                editor = ExpenseEditorContext(expense: nil)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("emptyAddExpenseButton")
        }
    }

    private var noMatchingExpenses: some View {
        ContentUnavailableView {
            Label("No results", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("Try another search or adjust the filters.")
        } actions: {
            Button("Clear filters") {
                searchText = ""
                filter = .all
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct ExpenseEditorContext: Identifiable {
    let id = UUID()
    let expense: Expense?
}

private enum ExpenseFilter: String, CaseIterable, Identifiable {
    case all, scheduled, variable
    var id: Self { self }
    var title: String { rawValue.capitalized }

    func includes(_ expense: Expense) -> Bool {
        switch self {
        case .all: true
        case .scheduled: expense.billingDay != nil || expense.anchorDate != nil
        case .variable: expense.amountMinor == nil
        }
    }
}

private enum ExpenseSort: String, CaseIterable, Identifiable {
    case merchant, amount, billingDate
    var id: Self { self }

    var title: String {
        switch self {
        case .merchant: "Name"
        case .amount: "Amount: highest first"
        case .billingDate: "Date"
        }
    }

    var symbolName: String {
        switch self {
        case .merchant: "textformat.abc"
        case .amount: "banknote"
        case .billingDate: "calendar"
        }
    }

    func comparison(_ lhs: Expense, _ rhs: Expense, period: CashFlowPeriod) -> Bool {
        switch self {
        case .merchant:
            break
        case .amount:
            if lhs.amountMinor != rhs.amountMinor {
                return (lhs.amountMinor ?? -1) > (rhs.amountMinor ?? -1)
            }
        case .billingDate:
            let leftDate = period.sortDate(for: lhs) ?? .distantFuture
            let rightDate = period.sortDate(for: rhs) ?? .distantFuture
            if leftDate != rightDate { return leftDate < rightDate }
        }
        let result = lhs.merchant.localizedStandardCompare(rhs.merchant)
        return result == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : result == .orderedAscending
    }
}

struct CashFlowPeriod {
    enum Kind: String, CaseIterable, Identifiable {
        case month, year
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var unit: String { rawValue }
        var component: Calendar.Component { self == .month ? .month : .year }
    }

    let kind: Kind
    let date: Date
    let today: Date

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    var interval: DateInterval {
        Self.calendar.dateInterval(of: kind.component, for: date)
            ?? DateInterval(start: Self.calendar.startOfDay(for: date), duration: 0)
    }

    var isCurrent: Bool { today >= interval.start && today < interval.end }
    var referenceDate: Date { isCurrent ? today : interval.start }

    var title: String {
        Self.format(date, style: kind == .month ? .dateTime.month(.wide).year() : .dateTime.year())
    }

    func adjacentDate(offset: Int) -> Date? {
        guard let adjacent = Self.calendar.date(byAdding: kind.component, value: offset, to: interval.start),
              (1...9999).contains(Self.calendar.component(.year, from: adjacent)) else { return nil }
        return adjacent
    }

    func totals(for ledger: Ledger) -> PeriodTotals {
        kind == .month
            ? ledger.totals(inMonthContaining: date, calendar: Self.calendar)
            : ledger.totals(inYearContaining: date, calendar: Self.calendar)
    }

    func paymentCount(for expense: Expense) -> Int {
        kind == .month
            ? expense.occurrenceCount(inMonthContaining: date, calendar: Self.calendar)
            : expense.occurrenceCount(inYearContaining: date, calendar: Self.calendar)
    }

    func nextDate(for expense: Expense) -> Date? {
        guard let next = expense.nextDue(onOrAfter: referenceDate, calendar: Self.calendar),
              next >= interval.start, next < interval.end else { return nil }
        return next
    }

    func sortDate(for expense: Expense) -> Date? {
        if let next = nextDate(for: expense) { return next }
        guard let first = expense.nextDue(onOrAfter: interval.start, calendar: Self.calendar),
              first >= interval.start, first < interval.end else { return nil }
        return first
    }

    func rowDate(for expense: Expense) -> Date? {
        if let next = nextDate(for: expense) { return next }
        let dates = kind == .month
            ? expense.occurrences(inMonthContaining: date, calendar: Self.calendar)
            : expense.occurrences(inYearContaining: date, calendar: Self.calendar)
        return dates.last
    }

    static func format(_ date: Date, style: Date.FormatStyle) -> String {
        var format = style
        format.calendar = calendar
        return date.formatted(format)
    }
}

#Preview("Empty document") {
    ContentView(document: TallyDocument())
}
