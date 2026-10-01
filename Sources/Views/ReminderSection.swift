import SwiftUI

struct ReminderSection: View {
    @State private var soundPreview = ReminderSoundPreview()
    @Binding var isEnabled: Bool
    @Binding var daysBefore: Int
    @Binding var time: Date
    @Binding var sound: PaymentReminderSound
    let needsPaymentDate: Bool
    let permissionDenied: Bool
    let openSettings: () -> Void

    private let leadTimes = [
        (days: 0, title: "On the day"),
        (days: 1, title: "1 day before"),
        (days: 2, title: "2 days before"),
        (days: 7, title: "1 week before")
    ]

    var body: some View {
        Section {
            Toggle("Remind me", isOn: $isEnabled)
                .accessibilityIdentifier("entryReminderToggle")

            if isEnabled {
                #if os(macOS)
                LabeledContent("When") {
                    MacMenuPicker("Reminder date", options: leadTimes.map(\.title), selection: leadTimeIndex, identifier: "reminderLeadTimePicker")
                }
                #else
                Picker("When", selection: $daysBefore) {
                    ForEach(leadTimes, id: \.days) { leadTime in
                        Text(leadTime.title).tag(leadTime.days)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Reminder date")
                .accessibilityIdentifier("reminderLeadTimePicker")
                #endif

                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .environment(\.calendar, CashFlowPeriod.calendar)
                    .accessibilityIdentifier("reminderTimePicker")

                #if os(macOS)
                LabeledContent("Sound") {
                    MacMenuPicker(
                        "Reminder sound",
                        options: PaymentReminderSound.allCases.map(\.title),
                        selection: soundIndex,
                        identifier: "reminderSoundPicker"
                    )
                }
                #else
                Menu {
                    ForEach(PaymentReminderSound.allCases) { choice in
                        Toggle(choice.title, isOn: Binding(
                            get: { choice == sound },
                            // Keep one choice checked and audition every selection.
                            set: { _ in selectSound(choice) }
                        ))
                    }
                } label: {
                    HStack {
                        Text("Sound").foregroundStyle(.primary)
                        Spacer()
                        HStack(spacing: 4) {
                            Text(sound.title)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.tint)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reminder sound")
                .accessibilityValue(sound.title)
                .accessibilityIdentifier("reminderSoundPicker")
                #endif

                if permissionDenied {
                    Button("Open notification settings", action: openSettings)
                        .accessibilityIdentifier("reminderSettingsButton")
                }
            }
        } header: {
            Text("Reminder")
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            if isEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    if needsPaymentDate {
                        Text("Choose a monthly date in Schedule to set a reminder.")
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("reminderDateError")
                    }
                    if permissionDenied {
                        Text("Notifications are off for Tally. Enable them in Settings to receive reminders.")
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("reminderPermissionStatus")
                    } else if !needsPaymentDate {
                        Text("At the selected time on this device.")
                            .foregroundStyle(Color("SecondaryText"))
                    }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing-sound-previews") {
                        // Silent UI tests observe requests without playing audio.
                        Text("\(soundPreview.playbackRequestCount)")
                            .accessibilityIdentifier("reminderPreviewRequestCount")
                    }
                    #endif
                }
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { soundPreview.stop() }
        }
        .onDisappear { soundPreview.stop() }
    }

    private func selectSound(_ selectedSound: PaymentReminderSound) {
        sound = selectedSound
        // A selection is an audition even when the stored value is unchanged.
        if isEnabled { soundPreview.play(selectedSound) }
    }

    private var leadTimeIndex: Binding<Int> {
        Binding(
            get: { leadTimes.firstIndex(where: { $0.days == daysBefore }) ?? 0 },
            set: { index in
                guard leadTimes.indices.contains(index) else { return }
                daysBefore = leadTimes[index].days
            }
        )
    }

    private var soundIndex: Binding<Int> {
        Binding(
            get: { PaymentReminderSound.allCases.firstIndex(of: sound) ?? 0 },
            set: { index in
                guard PaymentReminderSound.allCases.indices.contains(index) else { return }
                selectSound(PaymentReminderSound.allCases[index])
            }
        )
    }
}
