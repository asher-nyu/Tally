import SwiftUI

/// A separate draft keeps Cancel from changing the entry's saved schedule.
struct CustomRecurrenceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var intervalFieldWidth: CGFloat = 72
    let firstDate: Date
    let onSave: (CustomRecurrence) -> Void
    @State private var rule: CustomRecurrence
    @State private var intervalText: String
    @State private var usesOrdinal: Bool
    @State private var hasEndDate: Bool
    @State private var endDate: Date

    init(rule: CustomRecurrence, firstDate: Date, onSave: @escaping (CustomRecurrence) -> Void) {
        self.firstDate = firstDate
        self.onSave = onSave
        _rule = State(initialValue: rule)
        _intervalText = State(initialValue: String(rule.interval))
        _usesOrdinal = State(initialValue: rule.ordinal != nil)
        _hasEndDate = State(initialValue: rule.endDate != nil)
        _endDate = State(initialValue: rule.endDate?.date(calendar: CashFlowPeriod.calendar) ?? firstDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    menu("Frequency", options: CustomRecurrence.Frequency.allCases.map(\.title), selection: frequencyIndex, identifier: "customFrequencyPicker")
                    intervalRow
                } footer: {
                    if validInterval == nil {
                        Text("Enter a whole number from 1 to 999.")
                            .foregroundStyle(.red)
                    }
                }

                if rule.frequency == .weekly {
                    Section("On") {
                        selectionGrid(values: Array(1...7), selected: $rule.weekdays, identifier: "customWeekday", title: { weekdayName($0, short: true) }, accessibleTitle: { weekdayName($0) })
                    }
                }
                if rule.frequency == .monthly {
                    Section {
                        menu("Repeat on", options: ["Days of the month", "Day of the week"], selection: ordinalMode, identifier: "customMonthlyModePicker")
                        if usesOrdinal {
                            ordinalControls
                        } else {
                            selectionGrid(values: Array(1...31), selected: $rule.monthDays, identifier: "customMonthDay", title: { String($0) }, accessibleTitle: { "Day \($0)" })
                        }
                    } header: {
                        Text("On")
                    } footer: {
                        if !usesOrdinal {
                            Text("For shorter months, the last day is used. Dates that fall on the same day count once.")
                        }
                    }
                }
                if rule.frequency == .yearly {
                    Section {
                        selectionGrid(values: Array(1...12), selected: $rule.months, identifier: "customMonth", title: { monthName($0, short: true) }, accessibleTitle: { monthName($0) })
                        Toggle("On a day of the week", isOn: $usesOrdinal)
                            .accessibilityIdentifier("customYearlyOrdinalToggle")
                        if usesOrdinal {
                            ordinalControls
                        }
                    } header: {
                        Text("In")
                    } footer: {
                        if !usesOrdinal {
                            Text("Uses day \(CashFlowPeriod.calendar.component(.day, from: firstDate)) of each selected month, or the last day in shorter months.")
                        }
                    }
                }
                Section {
                    menu("End repeat", options: ["Never", "On date"], selection: endMode, identifier: "customEndPicker")
                    if hasEndDate {
                        ScheduleDatePicker("Last date", selection: $endDate, minimumDate: firstDate,
                                           identifier: "customEndDatePicker")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollIndicators(.never)
            .navigationTitle("Custom repeat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("cancelCustomRepeatButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        guard let preparedRule else { return }
                        onSave(preparedRule)
                        dismiss()
                    }
                    .disabled(preparedRule == nil)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("saveCustomRepeatButton")
                }
            }
        }
        .tint(.accentColor)
        #if os(macOS)
        .frame(width: 480, height: 570)
        .background(WindowAccessibilityLabel(label: "Custom repeat"))
        #else
        .presentationDetents([.large])
        #endif
        .onAppear { seedSelections() }
        .onChange(of: rule.frequency) { _, _ in seedSelections() }
        .onChange(of: usesOrdinal) { _, _ in seedSelections() }
    }


    @ViewBuilder
    private var intervalRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                Text("Every")
                intervalField
                Text(intervalUnit)
            }
        } else {
            HStack {
                Text("Every")
                Spacer()
                intervalField
                Text(intervalUnit).fixedSize()
            }
        }
    }

    private var intervalField: some View {
        TextField("", text: $intervalText)
            .labelsHidden()
            .accessibilityLabel("Repeat interval")
            .font(.body)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: intervalFieldWidth)
            .fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .accessibilityIdentifier("customIntervalField")
    }

    private var frequencyIndex: Binding<Int> {
        Binding(get: { CustomRecurrence.Frequency.allCases.firstIndex(of: rule.frequency) ?? 0 }, set: { rule.frequency = CustomRecurrence.Frequency.allCases[$0] })
    }
    private var ordinalMode: Binding<Int> {
        Binding(get: { usesOrdinal ? 1 : 0 }, set: { usesOrdinal = $0 == 1 })
    }
    private var endMode: Binding<Int> {
        Binding(get: { hasEndDate ? 1 : 0 }, set: { hasEndDate = $0 == 1 })
    }
    private var ordinalIndex: Binding<Int> {
        Binding(get: { [1, 2, 3, 4, 5, -1].firstIndex(of: rule.ordinal ?? 1) ?? 0 }, set: { rule.ordinal = [1, 2, 3, 4, 5, -1][$0] })
    }
    private var weekdayIndex: Binding<Int> {
        Binding(get: { (rule.ordinalWeekday ?? CashFlowPeriod.calendar.component(.weekday, from: firstDate)) - 1 }, set: { rule.ordinalWeekday = $0 + 1 })
    }
    private var ordinalControls: some View {
        Group {
            menu("Occurrence", options: ["First", "Second", "Third", "Fourth", "Fifth", "Last"], selection: ordinalIndex, identifier: "customOrdinalPicker")
            menu("Day", options: (1...7).map { weekdayName($0) }, selection: weekdayIndex, identifier: "customOrdinalWeekdayPicker")
        }
    }

    @ViewBuilder
    private func menu(_ title: String, options: [String], selection: Binding<Int>, identifier: String) -> some View {
        #if os(macOS)
        LabeledContent(title) {
            MacMenuPicker(title, options: options, selection: selection, identifier: identifier)
        }
        #else
        Picker(title, selection: selection) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index]).tag(index)
            }
        }
        .accessibilityIdentifier(identifier)
        #endif
    }

    private func selectionGrid(values: [Int], selected: Binding<[Int]>, identifier: String, title: @escaping (Int) -> String, accessibleTitle: @escaping (Int) -> String) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 76 : 44), spacing: 6)], spacing: 6) {
            ForEach(values, id: \.self) { value in
                let isSelected = selected.wrappedValue.contains(value)
                Button {
                    if isSelected {
                        if selected.wrappedValue.count > 1 { selected.wrappedValue.removeAll { $0 == value } }
                    } else {
                        selected.wrappedValue.append(value)
                        selected.wrappedValue.sort()
                    }
                } label: {
                    Text(title(value))
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .padding(.vertical, 4)
                        .foregroundStyle(isSelected ? (colorScheme == .dark ? Color.black : Color.white) : Color.primary)
                        .background(isSelected ? Color.accentColor : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibleTitle(value))
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("\(identifier)-\(value)")
            }
        }
    }

    private func seedSelections() {
        let calendar = CashFlowPeriod.calendar
        if rule.weekdays.isEmpty { rule.weekdays = [calendar.component(.weekday, from: firstDate)] }
        if rule.monthDays.isEmpty { rule.monthDays = [calendar.component(.day, from: firstDate)] }
        if rule.months.isEmpty { rule.months = [calendar.component(.month, from: firstDate)] }
    }

    private var validInterval: Int? {
        let text = intervalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(text), (1...999).contains(number) else { return nil }
        return number
    }
    private var preparedRule: CustomRecurrence? {
        guard let interval = validInterval else { return nil }
        var result = rule
        result.interval = interval
        result.weekdays = rule.frequency == .weekly ? rule.weekdays : []
        result.monthDays = rule.frequency == .monthly && !usesOrdinal ? rule.monthDays : []
        result.months = rule.frequency == .yearly ? rule.months : []
        let ordinalApplies = usesOrdinal && (rule.frequency == .monthly || rule.frequency == .yearly)
        result.ordinal = ordinalApplies ? rule.ordinal ?? 1 : nil
        result.ordinalWeekday = ordinalApplies ? rule.ordinalWeekday ?? CashFlowPeriod.calendar.component(.weekday, from: firstDate) : nil
        result.endDate = hasEndDate ? ScheduleDate(date: endDate, calendar: CashFlowPeriod.calendar) : nil
        return result.isValid(anchor: ScheduleDate(date: firstDate, calendar: CashFlowPeriod.calendar)) ? result : nil
    }
    private var intervalUnit: String {
        let singular = ["day", "week", "month", "year"][CustomRecurrence.Frequency.allCases.firstIndex(of: rule.frequency) ?? 0]
        return validInterval == 1 ? singular : singular + "s"
    }
    private func weekdayName(_ day: Int, short: Bool = false) -> String {
        let symbols = short ? CashFlowPeriod.calendar.shortWeekdaySymbols : CashFlowPeriod.calendar.weekdaySymbols
        return symbols[day - 1]
    }
    private func monthName(_ month: Int, short: Bool = false) -> String {
        let symbols = short ? CashFlowPeriod.calendar.shortMonthSymbols : CashFlowPeriod.calendar.monthSymbols
        return symbols[month - 1]
    }
}
