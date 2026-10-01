import SwiftUI

struct ExpenseEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedField: Field?
    @ScaledMetric(relativeTo: .body) private var minimumFieldHeight: CGFloat = 44

    private let existingExpense: Expense?
    private let currencyCode: String
    private let onSave: (Expense) -> Void

    @State private var merchant: String
    @State private var kind: EntryKind
    @State private var category: ExpenseCategory
    @State private var amountKind: AmountKind
    @State private var amountText: String
    @State private var websiteText: String
    @State private var billingDay: Int
    @State private var recurrence: Recurrence
    @State private var anchorDate: Date
    @State private var customRecurrence: CustomRecurrence?
    @State private var showsCustomRepeat = false
    @State private var reminderEnabled: Bool
    @State private var reminderDaysBefore: Int
    @State private var reminderTime: Date
    @State private var reminderSound: PaymentReminderSound
    @State private var isSaving = false

    init(expense: Expense?, currencyCode: String, onSave: @escaping (Expense) -> Void) {
        existingExpense = expense
        self.currencyCode = currencyCode
        self.onSave = onSave
        _merchant = State(initialValue: expense?.merchant ?? "")
        _kind = State(initialValue: expense?.kind ?? .expense)
        _category = State(initialValue: expense?.category ?? .other)
        _amountKind = State(initialValue: expense?.amountMinor == nil && expense != nil ? .variable : .fixed)
        _amountText = State(initialValue: Money.inputString(expense?.amountMinor, currencyCode: currencyCode))
        _websiteText = State(initialValue: expense?.websiteLink ?? "")
        _billingDay = State(initialValue: expense?.billingDay ?? 0)
        _recurrence = State(initialValue: expense?.recurrence ?? .monthly)
        _customRecurrence = State(initialValue: expense?.customRecurrence)
        _anchorDate = State(initialValue: expense?.anchorDate?.date(calendar: CashFlowPeriod.calendar) ?? CashFlowPeriod.calendar.startOfDay(for: .now))
        _reminderEnabled = State(initialValue: expense?.reminder != nil)
        _reminderDaysBefore = State(initialValue: expense?.reminder?.daysBefore ?? 0)
        _reminderSound = State(initialValue: expense?.reminder?.sound ?? .ripple)
        _reminderTime = State(initialValue: CashFlowPeriod.calendar.date(
            bySettingHour: expense?.reminder?.hour ?? 9,
            minute: expense?.reminder?.minute ?? 0,
            second: 0,
            of: .now
        ) ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(EntryKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("entryKindPicker")

                    TextField("Name", text: $merchant, prompt: Text("Income or expense name"))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        #if os(iOS)
                        .frame(minHeight: minimumFieldHeight)
                        #endif
                        .focused($focusedField, equals: .merchant)
                        #if os(iOS)
                        .onSubmit { focusedField = nil }
                        #endif
                        .accessibilityIdentifier("expenseMerchantField")
                    if kind == .expense {
                        #if os(macOS)
                        LabeledContent("Category") {
                            MacMenuPicker("Category", options: expenseCategories.map(\.title), selection: categoryIndex, identifier: "expenseCategoryPicker")
                        }
                        #else
                        Picker("Category", selection: $category) {
                            ForEach(expenseCategories) { category in
                                Label(category.title, systemImage: category.symbolName).tag(category)
                            }
                        }
                        .accessibilityIdentifier("expenseCategoryPicker")
                        #endif
                    }
                } header: {
                    sectionHeading("Details")
                } footer: {
                    if merchant.count > LedgerCodec.maximumMerchantLength {
                        Text("Use a name of \(LedgerCodec.maximumMerchantLength) characters or fewer.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    #if os(macOS)
                    LabeledContent("Frequency") {
                        MacMenuPicker("Frequency", options: Recurrence.allCases.map(\.title), selection: recurrenceIndex, identifier: "entryFrequencyPicker")
                    }
                    #else
                    Picker("Frequency", selection: recurrenceSelection) {
                        ForEach(Recurrence.allCases) { frequency in
                            Text(frequency.title).tag(frequency)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("entryFrequencyPicker")
                    #endif

                    if recurrence == .custom, customRecurrence != nil {
                        Button {
                            showsCustomRepeat = true
                        } label: {
                            HStack {
                                Text(customRecurrenceSummary)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Text("Edit")
                            }
                        }
                        .accessibilityIdentifier("editCustomRepeatButton")
                    }
                    if recurrence == .monthly {
                        #if os(macOS)
                        LabeledContent("Monthly date") {
                            MacMenuPicker(
                                "Monthly date",
                                options: ["Date varies"] + (1...31).map { "Day \($0)" },
                                selection: $billingDay,
                                identifier: "expenseBillingDayPicker"
                            )
                        }
                        #else
                        Picker("Monthly date", selection: $billingDay) {
                            Text("Date varies").tag(0)
                            ForEach(1...31, id: \.self) { day in
                                Text("Day \(day)").tag(day)
                            }
                        }
                        .accessibilityIdentifier("expenseBillingDayPicker")
                        #endif
                    } else {
                        ScheduleDatePicker(scheduleDateTitle, selection: $anchorDate,
                                           identifier: "entryAnchorDatePicker")
                    }
                } header: {
                    sectionHeading("Schedule")
                } footer: {
                    if recurrence == .custom, let end = customRecurrence?.endDate?.date(calendar: CashFlowPeriod.calendar), end < CashFlowPeriod.calendar.startOfDay(for: anchorDate) {
                        Text("The start date must be on or before the end of the repeat schedule.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else {
                        supportingText(scheduleExplanation)
                    }
                }

                Section {
                    Picker("Amount", selection: $amountKind) {
                        ForEach(AmountKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Amount handling")
                    .accessibilityIdentifier("expenseAmountKindPicker")

                    if amountKind == .fixed {
                        HStack {
                            Text(currencyCode)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color("SecondaryText"))
                            TextField(amountTitle, text: $amountText, prompt: Text("0"))
                                .font(.body)
                                .labelsHidden()
                                .accessibilityLabel(amountTitle)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .fixedSize(horizontal: false, vertical: true)
                                .focused($focusedField, equals: .amount)
                                #if os(iOS)
                                .frame(minHeight: minimumFieldHeight)
                                .keyboardType(.decimalPad)
                                #endif
                                .accessibilityIdentifier("expenseAmountField")
                        }
                    }
                } header: {
                    sectionHeading(amountTitle)
                } footer: {
                    if amountKind == .variable {
                        supportingText("Variable amounts stay visible and are excluded from totals.")
                    } else if let amountError {
                        Text(amountError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        supportingText(recurrence == .monthly && billingDay == 0
                             ? "Counted once per month, even when the date varies."
                             : "The full amount is counted on each scheduled date.")
                    }
                }
                Section {
                    TextField("Website", text: $websiteText, prompt: Text("example.com"))
                        .labelsHidden()
                        .accessibilityLabel("Website, optional")
                        .font(.body)
                        .focused($focusedField, equals: .website)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: minimumFieldHeight)
                        .onSubmit { focusedField = nil }
                        #endif
                        .accessibilityIdentifier("providerWebsiteField")
                } header: {
                    sectionHeading("Website")
                } footer: {
                    if let websiteError {
                        Text(websiteError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("providerWebsiteError")
                    } else {
                        supportingText("Optional. Add a website for quick access.")
                    }
                }
                ReminderSection(
                    isEnabled: $reminderEnabled,
                    daysBefore: $reminderDaysBefore,
                    time: $reminderTime,
                    sound: $reminderSound,
                    needsPaymentDate: reminderNeedsPaymentDate,
                    permissionDenied: NotificationCoordinator.shared.authorizationStatus == .denied
                ) {
                    Task { _ = await NotificationSettingsOpener.open() }
                }
            }
            .formStyle(.grouped)
            .scrollIndicators(.never)
            .disabled(isSaving)
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .accessibilityLabel("\(kind.title) details")
            .navigationTitle(editorTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                        .accessibilityIdentifier("dismissEntryKeyboardButton")
                }
                #endif
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("cancelExpenseButton")
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                        .disabled(!canSave || isSaving)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("saveExpenseButton")
                }
            }
        }
        .tint(.accentColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(editorTitle)
        #if os(macOS)
        .frame(width: 480, height: 580)
        .background(WindowAccessibilityLabel(label: editorTitle))
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .sheet(isPresented: $showsCustomRepeat) {
            CustomRecurrenceView(rule: customRecurrence ?? initialCustomRule, firstDate: anchorDate) { rule in
                customRecurrence = rule
                recurrence = .custom
            }
            .dynamicTypeSize(dynamicTypeSize)
        }
        #if os(macOS)
        .onAppear { if existingExpense == nil { focusedField = .merchant } }
        #endif
        .onChange(of: kind) { _, newKind in
            if newKind == .expense && category == .income { category = .other }
        }
        .task { await NotificationCoordinator.shared.refreshAuthorizationStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await NotificationCoordinator.shared.refreshAuthorizationStatus() }
            }
        }
        .interactiveDismissDisabled(hasChanges || isSaving)
    }

    private var parsedAmount: Int64? {
        try? Money.parse(amountText, currencyCode: currencyCode)
    }

    private var editorTitle: String {
        "\(existingExpense == nil ? "Add" : "Edit") \(kind.title.lowercased())"
    }

    private var websiteError: String? {
        do {
            _ = try ProviderLink.normalizeWebsite(websiteText)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func supportingText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color("SecondaryText"))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var expenseCategories: [ExpenseCategory] {
        ExpenseCategory.allCases.filter { $0 != .income }
    }

    private var categoryIndex: Binding<Int> {
        Binding(
            get: { expenseCategories.firstIndex(of: category) ?? 0 },
            set: { index in
                guard expenseCategories.indices.contains(index) else { return }
                category = expenseCategories[index]
            }
        )
    }

    private var recurrenceIndex: Binding<Int> {
        Binding(
            get: { Recurrence.allCases.firstIndex(of: recurrence) ?? 0 },
            set: { index in
                guard Recurrence.allCases.indices.contains(index) else { return }
                recurrenceSelection.wrappedValue = Recurrence.allCases[index]
            }
        )
    }

    private var recurrenceSelection: Binding<Recurrence> {
        Binding(get: { recurrence }, set: { value in
            if value == .custom {
                focusedField = nil
                showsCustomRepeat = true
            } else {
                recurrence = value
            }
        })
    }

    private var initialCustomRule: CustomRecurrence {
        let calendar = CashFlowPeriod.calendar
        return CustomRecurrence(frequency: .monthly,
                                weekdays: [calendar.component(.weekday, from: anchorDate)],
                                monthDays: [billingDay > 0 ? billingDay : calendar.component(.day, from: anchorDate)],
                                months: [calendar.component(.month, from: anchorDate)])
    }

    private var customRecurrenceSummary: String {
        Expense(merchant: "", recurrence: .custom,
                anchorDate: ScheduleDate(date: anchorDate, calendar: CashFlowPeriod.calendar),
                customRecurrence: customRecurrence).recurrenceSummary
    }

    private var amountTitle: String {
        switch recurrence {
        case .monthly: "Monthly amount"
        case .everyTwoWeeks: "Amount every 2 weeks"
        case .annual: "Annual amount"
        case .oneTime: "One-time amount"
        case .custom: "Amount"
        }
    }

    private var scheduleDateTitle: String {
        switch recurrence {
        case .oneTime: "Date"
        case .custom: "Start date"
        default: "First date"
        }
    }

    private var scheduleExplanation: String {
        switch recurrence {
        case .monthly:
            billingDay > 28
                ? "For shorter months, the last day of the month is used."
                : "Choose a day of the month, or leave the date variable."
        case .everyTwoWeeks:
            "Repeats every 14 days from the first date."
        case .annual:
            "Repeats each year from the first date. February 29 uses February 28 in other years."
        case .oneTime:
            "Counted once, on this date."
        case .custom:
            "Repeats on matching dates from the start date. The full amount is included on each scheduled date."
        }
    }

    private var amountError: String? {
        guard !amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            _ = try Money.parse(amountText, currencyCode: currencyCode)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var reminderNeedsPaymentDate: Bool {
        reminderEnabled && recurrence == .monthly && billingDay == 0
    }

    private var preparedReminder: PaymentReminder? {
        guard reminderEnabled else { return nil }
        let time = CashFlowPeriod.calendar.dateComponents([.hour, .minute], from: reminderTime)
        return PaymentReminder(
            daysBefore: reminderDaysBefore,
            hour: time.hour ?? 9,
            minute: time.minute ?? 0,
            sound: reminderSound
        )
    }

    private var canSave: Bool {
        !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        merchant.count <= LedgerCodec.maximumMerchantLength &&
        websiteError == nil &&
        !reminderNeedsPaymentDate &&
        (preparedReminder?.isValid ?? true) &&
        (recurrence != .custom || customRecurrence?.isValid(anchor: ScheduleDate(date: anchorDate, calendar: CashFlowPeriod.calendar)) == true) &&
        (recurrence == .monthly || ScheduleDate(date: anchorDate, calendar: CashFlowPeriod.calendar).isValid) &&
        (amountKind == .variable || parsedAmount != nil)
    }

    private var hasChanges: Bool {
        merchant != (existingExpense?.merchant ?? "") ||
        websiteText != (existingExpense?.websiteLink ?? "") ||
        preparedReminder != existingExpense?.reminder ||
        kind != (existingExpense?.kind ?? .expense) ||
        category != (existingExpense?.category ?? .other) ||
        recurrence != (existingExpense?.recurrence ?? .monthly) ||
        (recurrence == .custom && customRecurrence != existingExpense?.customRecurrence) ||
        (recurrence != .monthly && ScheduleDate(date: anchorDate, calendar: CashFlowPeriod.calendar) != existingExpense?.anchorDate) ||
        billingDay != (existingExpense?.billingDay ?? 0) ||
        amountText != Money.inputString(existingExpense?.amountMinor, currencyCode: currencyCode) ||
        amountKind != (existingExpense?.amountMinor == nil && existingExpense != nil ? .variable : .fixed)
    }

    private func save() async {
        guard canSave, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        focusedField = nil
        if reminderEnabled {
            _ = await NotificationCoordinator.shared.requestPermission()
        }
        onSave(Expense(
            id: existingExpense?.id ?? UUID(),
            merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines),
            amountMinor: amountKind == .fixed ? parsedAmount : nil,
            billingDay: recurrence == .monthly && billingDay != 0 ? billingDay : nil,
            category: kind == .income ? .income : category,
            notes: existingExpense?.notes ?? "",
            kind: kind,
            recurrence: recurrence,
            anchorDate: recurrence == .monthly ? nil : ScheduleDate(date: anchorDate, calendar: CashFlowPeriod.calendar),
            customRecurrence: recurrence == .custom ? customRecurrence : nil,
            websiteLink: try? ProviderLink.normalizeWebsite(websiteText),
            reminder: preparedReminder
        ))
        await NotificationCoordinator.shared.reconcileNow()
        dismiss()
    }

    private enum Field: Hashable {
        case merchant, amount, website
    }

    private enum AmountKind: String, CaseIterable, Identifiable {
        case fixed, variable
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }
}
