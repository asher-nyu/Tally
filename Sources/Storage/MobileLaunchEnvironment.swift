#if os(iOS)
import Foundation

/// One preference store for the mobile browser, editor, and Settings sheet.
nonisolated enum MobileLaunchEnvironment {
    static var testSessionID: UUID? {
        launchTestSession(arguments: ProcessInfo.processInfo.arguments,
                          environment: ProcessInfo.processInfo.environment)
    }

    static var isLaunchTestEnabled: Bool { testSessionID != nil }

    static var isEnabled: Bool {
        permitsRestoration(arguments: ProcessInfo.processInfo.arguments,
                           environment: ProcessInfo.processInfo.environment,
                           runningUnitTests: NSClassFromString("XCTestCase") != nil)
    }

    @MainActor static let defaults: UserDefaults = {
        #if DEBUG
        if let session = testSessionID {
            return UserDefaults(suiteName: suiteName(for: session))!
        }
        if isAutomatedRun(arguments: ProcessInfo.processInfo.arguments,
                          environment: ProcessInfo.processInfo.environment,
                          runningUnitTests: NSClassFromString("XCTestCase") != nil) {
            // A malformed test flag or ordinary UI/unit test cannot touch the
            // person's launch preference through an incidental Settings view.
            return UserDefaults(suiteName: "TallyMobileLaunchInertTests.\(UUID().uuidString)")!
        }
        #endif
        return .standard
    }()

    static func suiteName(for session: UUID) -> String {
        "TallyMobileLaunchSettingsTests.\(session.uuidString)"
    }

    static func launchTestSession(arguments: [String], environment: [String: String]) -> UUID? {
        #if DEBUG
        guard arguments.contains("--ui-testing"),
              arguments.contains("--ui-testing-mobile-launch-settings"),
              let token = environment["TALLY_MOBILE_LAUNCH_TEST_SESSION"] else { return nil }
        return UUID(uuidString: token)
        #else
        return nil
        #endif
    }

    static func permitsRestoration(arguments: [String], environment: [String: String], runningUnitTests: Bool) -> Bool {
        #if DEBUG
        if launchTestSession(arguments: arguments, environment: environment) != nil { return true }
        if isAutomatedRun(arguments: arguments, environment: environment, runningUnitTests: runningUnitTests) { return false }
        #endif
        return true
    }

    private static func isAutomatedRun(arguments: [String], environment: [String: String], runningUnitTests: Bool) -> Bool {
        arguments.contains("--ui-testing")
            || arguments.contains("--ui-testing-mobile-launch-settings")
            || arguments.contains("--ui-testing-native-mobile")
            || environment["XCTestConfigurationFilePath"] != nil
            || runningUnitTests
    }
}
#endif
