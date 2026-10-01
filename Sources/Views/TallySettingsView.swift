import SwiftUI

struct TallySettingsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @AppStorage(TallyLaunchBehavior.preferenceKey, store: MobileLaunchEnvironment.defaults)
    private var behavior: TallyLaunchBehavior = .lastUsedFile
    let onDone: () -> Void
    #else
    @AppStorage(TallyLaunchBehavior.preferenceKey)
    private var behavior: TallyLaunchBehavior = .lastUsedFile
    #endif

    var body: some View {
        #if os(iOS)
        NavigationStack {
            settingsForm
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                            .accessibilityIdentifier("settingsDoneButton")
                    }
                }
        }
        .tint(.accentColor)
        #else
        settingsForm
            .frame(minWidth: 440, idealWidth: 440, maxWidth: 560,
                   minHeight: 180, idealHeight: 180, maxHeight: 200)
            .tint(.accentColor)
        #endif
    }

    private var settingsForm: some View {
        Form {
            Section {
                if dynamicTypeSize.isAccessibilitySize {
                    accessibleLaunchMenu
                } else {
                    launchPicker
                }
            } header: {
                if dynamicTypeSize.isAccessibilitySize { Text("On launch") }
            } footer: {
                Text("Choose what appears when you open Tally.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.never)
        .accessibilityIdentifier("tallySettingsForm")
    }

    private var launchPicker: some View {
        Picker("On launch", selection: $behavior) {
            ForEach(TallyLaunchBehavior.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("launchBehaviorPicker")
    }

    private var accessibleLaunchMenu: some View {
        Menu {
            Picker("On launch", selection: $behavior) {
                ForEach(TallyLaunchBehavior.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            HStack(alignment: .center) {
                Text(behavior.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 12)
                Image(systemName: "chevron.up.chevron.down")
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("On launch")
        .accessibilityValue(behavior.title)
        .accessibilityIdentifier("launchBehaviorPicker")
    }
}
