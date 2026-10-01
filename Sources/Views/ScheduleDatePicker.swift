import SwiftUI

/// Presents a date as a complete localized label instead of padded day/month fields.
struct ScheduleDatePicker: View {
    let title: String
    @Binding var selection: Date
    let minimumDate: Date?
    let identifier: String

    @Environment(\.locale) private var locale
    @State private var showsCalendar = false

    init(_ title: String, selection: Binding<Date>, minimumDate: Date? = nil, identifier: String) {
        self.title = title
        _selection = selection
        self.minimumDate = minimumDate
        self.identifier = identifier
    }

    var body: some View {
        #if os(macOS)
        LabeledContent(title) {
            Button {
                showsCalendar = true
            } label: {
                Text(dateLabel)
                    .fixedSize()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityLabel(title)
            .accessibilityValue(dateLabel)
            .accessibilityIdentifier(identifier)
            .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
                VStack(alignment: .trailing, spacing: 12) {
                    calendar
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier(identifier + "Calendar")

                    Button("Done") { showsCalendar = false }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier(identifier + "Done")
                }
                .padding(12)
            }
        }
        #else
        calendar
            .accessibilityIdentifier(identifier)
        #endif
    }

    private var dateLabel: String {
        selection.formatted(Date.FormatStyle(
            date: .abbreviated, time: .omitted, locale: locale,
            calendar: CashFlowPeriod.calendar, timeZone: CashFlowPeriod.calendar.timeZone
        ))
    }

    private var calendar: some View {
        Group {
            if let minimumDate {
                DatePicker(title, selection: $selection, in: minimumDate..., displayedComponents: .date)
            } else {
                DatePicker(title, selection: $selection, displayedComponents: .date)
            }
        }
        .environment(\.calendar, CashFlowPeriod.calendar)
    }
}
