#if os(iOS)
import Foundation
import Testing
@testable import Tally

nonisolated struct MobileLaunchEnvironmentTests {
    @Test func ordinaryLaunchPermitsRestoration() {
        #expect(MobileLaunchEnvironment.permitsRestoration(arguments: ["Tally"], environment: [:], runningUnitTests: false))
    }

    #if DEBUG
    @Test func ordinaryUnitAndUITestsCannotRestoreAPersonalFile() {
        for arguments in [["--ui-testing"], ["--ui-testing-native-mobile"], ["--ui-testing-mobile-launch-settings"]] {
            #expect(!MobileLaunchEnvironment.permitsRestoration(arguments: arguments, environment: [:], runningUnitTests: false))
        }
        #expect(!MobileLaunchEnvironment.permitsRestoration(arguments: [], environment: [:], runningUnitTests: true))
        #expect(!MobileLaunchEnvironment.permitsRestoration(arguments: [], environment: ["XCTestConfigurationFilePath": "fixture"], runningUnitTests: false))
    }

    @Test func dedicatedLaunchTestRequiresBothFlagsAndAValidUUID() {
        let session = UUID()
        let environment = ["TALLY_MOBILE_LAUNCH_TEST_SESSION": session.uuidString]
        let flags = ["--ui-testing", "--ui-testing-mobile-launch-settings"]
        #expect(MobileLaunchEnvironment.launchTestSession(arguments: flags, environment: environment) == session)
        #expect(MobileLaunchEnvironment.permitsRestoration(arguments: flags, environment: environment, runningUnitTests: true))
        #expect(MobileLaunchEnvironment.launchTestSession(arguments: [flags[0]], environment: environment) == nil)
        #expect(MobileLaunchEnvironment.launchTestSession(arguments: [flags[1]], environment: environment) == nil)
        #expect(MobileLaunchEnvironment.launchTestSession(arguments: flags, environment: [:]) == nil)
        #expect(!MobileLaunchEnvironment.permitsRestoration(arguments: flags, environment: [:], runningUnitTests: false))
    }

    @Test func malformedSessionCannotEscapeIntoStandardPreferences() {
        let arguments = ["--ui-testing", "--ui-testing-mobile-launch-settings"]
        for token in ["", "../../user-defaults", "standard", "not-a-uuid"] {
            let environment = ["TALLY_MOBILE_LAUNCH_TEST_SESSION": token]
            #expect(MobileLaunchEnvironment.launchTestSession(arguments: arguments, environment: environment) == nil)
            #expect(!MobileLaunchEnvironment.permitsRestoration(arguments: arguments, environment: environment, runningUnitTests: false))
        }
    }
    #endif

    @Test func suiteNamesAreStablePerSessionAndDistinctAcrossSessions() {
        let first = UUID()
        let second = UUID()
        #expect(MobileLaunchEnvironment.suiteName(for: first) == MobileLaunchEnvironment.suiteName(for: first))
        #expect(MobileLaunchEnvironment.suiteName(for: first) != MobileLaunchEnvironment.suiteName(for: second))
        #expect(MobileLaunchEnvironment.suiteName(for: first).hasPrefix("TallyMobileLaunchSettingsTests."))
    }
}
#endif
