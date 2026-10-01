import SwiftUI

struct PrivacySupportView: View {
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Privacy Policy")
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text("Your financial information stays in the files and storage locations you choose. Tally does not send your financial files or app usage to Asher Bloom and includes no advertising, tracking, or third-party analytics.")
                        Text("Last updated September 27, 2026")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    section("Your files") {
                        Text("Tally stores income, expenses, amounts, schedules, website links, and reminder preferences in your .tally files. You choose where to save, move, and delete them.")
                        Text("Files saved in iCloud Drive are stored and synchronized by Apple using your Apple Account. Files saved with another file provider are handled by that provider. Their privacy and security practices apply. Asher Bloom does not receive access to your files through Tally.")
                    }

                    section("Reminders") {
                        Text("When you enable reminders, Tally keeps a local copy of the relevant names, amounts, schedules, website links, and sound preferences on that device. This allows reminders to remain scheduled when the file or app is closed.")
                        Text("Before deleting a closed file, turn off its reminders in Tally and save the changes on each device where reminders were enabled. Deleting a closed file in Finder or Files does not automatically remove the reminders cached on that device. If the file is already deleted, you can stop Tally’s notifications in system Settings.")
                    }

                    section("Notifications") {
                        Text("Tally asks for permission when you save an enabled reminder. Notifications may show a payment’s name, amount, or other reminder details on the Lock Screen or in Notification Center. Your system notification settings and Focus settings control how these details appear.")
                    }

                    section("Website links") {
                        Text("Opening a website takes you to an external browser or another app selected by your device. That service’s privacy practices apply. Tally does not send your financial file with the link.")
                    }

                    section("Contact support") {
                        Text("For help with Tally or a privacy question, email Asher Bloom. Include only the information you want to share; you do not need to send your financial file.")
                        Link("asherbloom@nyu.edu", destination: URL(string: "mailto:asherbloom@nyu.edu")!)
                            .accessibilityLabel("Email support at asherbloom@nyu.edu")
                            .accessibilityIdentifier("privacySupportEmail")
                        Text("If you contact support, Asher Bloom receives your email address and the information you include, and uses them to respond to your request.")
                    }

                    section("System services") {
                        Text("Apple manages iCloud, device backups, and any diagnostics you choose to share through system settings under its own privacy practices.")
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: 640, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.never)
            .accessibilityIdentifier("privacyPolicyContent")
            .navigationTitle("Privacy & Support")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("privacyPolicyDone")
                }
            }
        }
        .tint(.accentColor)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

#if os(macOS)
struct TallyPrivacyCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Privacy & Support") {
                openWindow(id: TallyPrivacyWindowContent.windowIdentifier)
            }
        }
    }
}

struct TallyPrivacyWindowContent: View {
    static let windowIdentifier = "privacy-support"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PrivacySupportView { dismiss() }
            .frame(minWidth: 420, minHeight: 360)
    }
}
#endif
