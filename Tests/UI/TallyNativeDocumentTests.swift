#if os(macOS)
import Foundation
import XCTest

/// These tests use the production DocumentGroup and real file operations on
/// owned fixtures. A DEBUG utility-queue seam performs writes because Xcode's
/// UI runner has read-only access to the app's container. It never invokes the
/// production lifetime handler; native presenter/filesystem events drive it.
@MainActor
final class TallyNativeDocumentTests: XCTestCase {
    private var fixture: NativeFixture?
    private var launchedApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        let cleanup: (root: URL, error: String?)? = await MainActor.run {
            guard let fixture = self.fixture else {
                self.launchedApp?.terminate()
                self.launchedApp = nil
                return nil
            }
            let app = fixture.app
            var failure: String?
            // Do not assert inside MainActor.run: XCTest's abort-on-failure
            // exception can prevent its async continuation from completing.
            if app.state == .runningForeground || app.state == .runningBackground {
                // Failure paths can leave a document-modal deletion alert open.
                // Acknowledge it before exercising the inspector's cleanup action.
                self.dismissDeletionAlerts(in: app)
                let button = app.buttons["nativeTestAction-cleanup"]
                if button.exists {
                    button.click()
                    let result = self.status("nativeTestMutationStatus", in: app)
                    let finished = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
                        guard let element = object as? XCUIElement else { return false }
                        let text = element.value as? String ?? element.label
                        return text == "complete:cleanup" || text.hasPrefix("error:cleanup:")
                    }, object: result)
                    let wait = XCTWaiter.wait(for: [finished], timeout: 10)
                    let description = self.text(of: result)
                    if wait != .completed || description != "complete:cleanup" { failure = description }
                } else {
                    failure = "The running fixture app has no cleanup control."
                }
                self.dismissDeletionAlerts(in: app)
                app.terminate()
            } else {
                failure = "The fixture app exited before owned-file cleanup."
            }
            self.fixture = nil
            self.launchedApp = nil
            return (fixture.root, failure)
        }
        guard let cleanup else { return }
        XCTAssertNil(cleanup.error, cleanup.error ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanup.root.path),
                       "The app-owned fixture cleanup must remove only this test's directory.")
    }

    func testExternalRenameAndMoveKeepBothNativeDocumentsOpen() throws {
        let fixture = try launchNativeDocuments()
        let originalA = try Data(contentsOf: fixture.a)
        let originalB = try Data(contentsOf: fixture.b)
        let renamed = fixture.root.appendingPathComponent("Renamed-A.tally")

        performFixtureAction("rename", in: fixture)
        expectStatus("nativeTestAURL", equals: renamed.path, in: fixture.app)
        assertDocument("A", isOpenIn: fixture.app)
        assertDocument("B", isOpenIn: fixture.app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.a.path))
        XCTAssertEqual(try Data(contentsOf: renamed), originalA)

        let folder = fixture.root.appendingPathComponent("Moved", isDirectory: true)
        let moved = folder.appendingPathComponent(renamed.lastPathComponent)
        performFixtureAction("move", in: fixture)
        expectStatus("nativeTestAURL", equals: moved.path, in: fixture.app)
        assertDocument("A", isOpenIn: fixture.app)
        assertDocument("B", isOpenIn: fixture.app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(try Data(contentsOf: moved), originalA)
        XCTAssertEqual(try Data(contentsOf: fixture.b), originalB)
        expectStatus("nativeTestBURL", equals: fixture.b.path, in: fixture.app)
        XCTAssertFalse(fixture.app.staticTexts["File in Trash"].exists,
                       "An ordinary rename or move must not present a deletion alert.")
        attachScreenshot("Both native documents remain open after external moves", app: fixture.app)
    }

    func testAtomicReplacementDoesNotCloseTheNativeDocument() throws {
        let fixture = try launchNativeDocuments()
        let originalA = try Data(contentsOf: fixture.a)
        let originalB = try Data(contentsOf: fixture.b)
        let oldResourceID = try fixture.a.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier as? NSObject

        performFixtureAction("replace", in: fixture)
        var refreshedURL = fixture.a
        refreshedURL.removeAllCachedResourceValues()
        let newResourceID = try refreshedURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier as? NSObject
        XCTAssertNotNil(oldResourceID)
        XCTAssertNotNil(newResourceID)
        XCTAssertNotEqual(oldResourceID, newResourceID, "The fixture must undergo an actual atomic file replacement.")

        // Allow presenter notifications to settle while rejecting a transient
        // close. An immediate existence check alone could miss a queued close.
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ OR label == %@", "false", "false"),
            object: status("nativeTestAOpen", in: fixture.app)
        )
        closed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 2), .completed)
        assertDocument("A", isOpenIn: fixture.app)
        assertDocument("B", isOpenIn: fixture.app)
        expectStatus("nativeTestAURL", equals: fixture.a.path, in: fixture.app)
        XCTAssertEqual(try Data(contentsOf: fixture.a), originalA)
        XCTAssertEqual(try Data(contentsOf: fixture.b), originalB)
        XCTAssertFalse(fixture.app.staticTexts["File in Trash"].exists,
                       "An atomic file replacement must not present a deletion alert.")
        attachScreenshot("Atomic replacement preserves the native document", app: fixture.app)
    }

    func testMovingToTrashOffersRestoreOrCloseWindow() throws {
        let fixture = try launchNativeDocuments()
        try requireTrashDriver(for: fixture)
        let originalA = try Data(contentsOf: fixture.a)
        let originalB = try Data(contentsOf: fixture.b)
        XCTAssertFalse(fixture.app.staticTexts["File in Trash"].exists)
        expectStatus("nativeTestAEdited", equals: "false", in: fixture.app)

        performFixtureAction("trash", in: fixture)
        let trashPath = text(of: status("nativeTestTrashURL", in: fixture.app))
        XCTAssertFalse(trashPath.isEmpty)
        XCTAssertNotEqual(trashPath, fixture.a.path)
        expectStatus("nativeTestAURL", equals: trashPath, in: fixture.app)
        assertDeletionAlert(in: fixture.app)
        assertDocument("A", isOpenIn: fixture.app)
        assertDocument("B", isOpenIn: fixture.app)
        expectStatus("nativeTestAEdited", equals: "false", in: fixture.app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.a.path))
        attachScreenshot("Moving the file to Trash immediately presents recovery before any edit", app: fixture.app)

        // The host proves the original SHA256 and ledger UUID. A sandboxed
        // runner cannot truthfully read or stat ~/.Trash on its own.
        performFixtureAction("verifyTrash", in: fixture)
        expectStatus("nativeTestTrashState", equals: "present", in: fixture.app)
        closeDeletedWindow(in: fixture)
        performFixtureAction("verifyTrash", in: fixture)
        expectStatus("nativeTestTrashState", equals: "present", in: fixture.app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.a.path))

        // Dismissing an editor does not permanently delete its file. Restoring
        // the exact original file must preserve its bytes without reopening A.
        performFixtureAction("restore", in: fixture)
        expectStatus("nativeTestTrashState", equals: "restored", in: fixture.app)
        expectStatus("nativeTestAOpen", equals: "false", in: fixture.app)
        XCTAssertEqual(try Data(contentsOf: fixture.a), originalA)
        XCTAssertEqual(try Data(contentsOf: fixture.b), originalB)
        XCTAssertFalse(fixture.app.staticTexts["File in Trash"].exists)
        attachScreenshot("Close Window preserves the trashed file for later restoration", app: fixture.app)
    }

    func testExternalRestoreDismissesAlertAndKeepsItsEditorOpen() throws {
        let fixture = try launchNativeDocuments()
        try requireTrashDriver(for: fixture)
        let originalA = try Data(contentsOf: fixture.a)
        let originalB = try Data(contentsOf: fixture.b)

        performFixtureAction("trash", in: fixture)
        assertDeletionAlert(in: fixture.app)
        performFixtureAction("restore", in: fixture)
        expectStatus("nativeTestTrashState", equals: "restored", in: fixture.app)
        XCTAssertEqual(try Data(contentsOf: fixture.a), originalA)
        let alert = fixture.app.staticTexts["File in Trash"]
        XCTAssertTrue(!alert.exists || alert.waitForNonExistence(timeout: 5),
                      "Moving the file out of Trash must dismiss its recovery sheet.")
        assertDocument("A", isOpenIn: fixture.app)
        XCTAssertEqual(try Data(contentsOf: fixture.a), originalA,
                       "External restoration must preserve the file and its open editor.")
        XCTAssertEqual(try Data(contentsOf: fixture.b), originalB)
        attachScreenshot("External restoration dismisses the recovery sheet and keeps editing available", app: fixture.app)
    }

    private func requireTrashDriver(for fixture: NativeFixture) throws {
        let driverMarker = fixture.root.deletingLastPathComponent()
            .appendingPathComponent(".tally-native-fixture-driver.json")
        let heartbeat = (try? Data(contentsOf: driverMarker))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["heartbeat"] as? Double
        try XCTSkipUnless(heartbeat.map { abs(Date().timeIntervalSince1970 - $0) < 5 } ?? false,
                          "Run this Trash test through python3 Scripts/native_document_fixture_driver.py -- xcodebuild …; the sandboxed runner cannot access Trash.")
    }

    func testPermanentRemovalClosesTheWholeWindowWithRecoveryPending() throws {
        let fixture = try launchNativeDocuments()
        try requireTrashDriver(for: fixture)
        let originalB = try Data(contentsOf: fixture.b)
        performFixtureAction("trash", in: fixture)
        assertDeletionAlert(in: fixture.app)
        performFixtureAction("delete", in: fixture)
        expectStatus("nativeTestTrashState", equals: "missing", in: fixture.app)
        assertDocumentAClosed(in: fixture)
        XCTAssertEqual(try Data(contentsOf: fixture.b), originalB)
        attachScreenshot("Permanent removal closes the document and its pending recovery sheet", app: fixture.app)
    }

    func testRestoreFileActionMovesTheFileBackAndKeepsTheWindowOpen() throws {
        let fixture = try launchNativeDocuments()
        try requireTrashDriver(for: fixture)
        let originalA = try Data(contentsOf: fixture.a)
        let originalB = try Data(contentsOf: fixture.b)
        performFixtureAction("trash", in: fixture)
        assertDeletionAlert(in: fixture.app)
        fixture.app.buttons["documentDeletedRestore"].firstMatch.click()
        expectStatus("nativeTestAURL", equals: fixture.a.path, in: fixture.app)
        let alert = fixture.app.staticTexts["File in Trash"]
        XCTAssertTrue(!alert.exists || alert.waitForNonExistence(timeout: 5))
        assertDocument("A", isOpenIn: fixture.app)
        assertDocument("B", isOpenIn: fixture.app)
        XCTAssertEqual(try Data(contentsOf: fixture.a), originalA)
        XCTAssertEqual(try Data(contentsOf: fixture.b), originalB)
        attachScreenshot("Restore File returns the same file to its original location", app: fixture.app)
    }

    private func assertDeletionAlert(in app: XCUIApplication) {
        let title = app.staticTexts["File in Trash"].firstMatch
        XCTAssertTrue(title.exists || title.waitForExistence(timeout: 5),
                      "Recovery must appear immediately, without editing or emptying Trash.")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "File in Trash", "File in Trash")).count, 1,
                       "Only the affected document must display a deletion alert.")
        let message = app.staticTexts["Restore this file to keep working, or close this window."].firstMatch
        XCTAssertTrue(message.exists, "The alert must explain the available choices.")
        let restore = app.buttons["documentDeletedRestore"].firstMatch
        XCTAssertTrue(restore.exists && restore.isHittable)
        XCTAssertEqual(restore.title, "Restore File")
        let close = deletionCloseButton(in: app)
        XCTAssertTrue(close.exists && close.isHittable, "The alert must offer Close Window.")
        let identifiedAlert = app.descendants(matching: .any).matching(identifier: "documentDeletedAlert").firstMatch
        let alert = identifiedAlert.exists ? identifiedAlert
            : app.sheets.containing(.staticText, identifier: "File in Trash").firstMatch
        XCTAssertTrue(alert.exists, "The deletion alert must be attached to the affected document.")
        XCTAssertEqual(alert.buttons.count, 2, "Recovery must offer Restore File and Close Window.")
        XCTAssertFalse(alert.buttons["Duplicate"].firstMatch.exists)
        XCTAssertFalse(alert.buttons["Cancel"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["documentTrashNotice"].exists,
                       "The earlier title-bar Trash notice must not accompany the deletion alert.")
        XCTAssertFalse(app.windows["nativeDocumentWindowB"].staticTexts["File in Trash"].exists,
                       "The second document must remain unaffected.")
    }

    private func deletionCloseButton(in app: XCUIApplication) -> XCUIElement {
        let identified = app.buttons["documentDeletedClose"].firstMatch
        if identified.exists { return identified }
        return app.sheets.containing(.staticText, identifier: "File in Trash").buttons["Close Window"].firstMatch
    }

    private func closeDeletedWindow(in fixture: NativeFixture) {
        let app = fixture.app
        deletionCloseButton(in: app).click()
        assertDocumentAClosed(in: fixture)
    }

    private func assertDocumentAClosed(in fixture: NativeFixture) {
        let app = fixture.app
        expectStatus("nativeTestAOpen", equals: "false", in: app)
        let window = app.windows["nativeDocumentWindowA"]
        XCTAssertTrue(!window.exists || window.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["File in Trash"].exists)
        expectStatus("nativeTestOpenCount", equals: "1", in: app)
        expectStatus("nativeTestOpenPaths", equals: fixture.b.path, in: app)
        assertDocument("B", isOpenIn: app)
    }

    private func dismissDeletionAlerts(in app: XCUIApplication) {
        // Teardown may observe A's pending alert, then B's cleanup deletion.
        // Bound the loop to the two fixtures; never click unrelated alerts.
        for _ in 0..<2 {
            let button = deletionCloseButton(in: app)
            guard button.exists && button.isHittable else { return }
            button.click()
        }
    }

    func testDeletingAnUnchangedFileClosesOnlyItsNativeDocument() throws {
        let fixture = try launchNativeDocuments()
        let originalB = try Data(contentsOf: fixture.b)
        expectStatus("nativeTestAEdited", equals: "false", in: fixture.app)

        performFixtureAction("delete", in: fixture)
        assertDocumentAClosed(in: fixture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.a.path))
        XCTAssertFalse(fixture.app.buttons["Duplicate"].firstMatch.exists,
                       "An unchanged deleted document does not need a recovery prompt.")
        assertDocument("B", isOpenIn: fixture.app)
        XCTAssertEqual(try Data(contentsOf: fixture.b), originalB)
        attachScreenshot("Deleting one unchanged document leaves the other open", app: fixture.app)
    }

    func testDeletingDocumentWithPendingUnsavedEditsClosesOnlyItsNativeDocument() throws {
        let fixture = try launchNativeDocuments()
        let app = fixture.app
        let originalA = try Data(contentsOf: fixture.a)
        let originalB = try Data(contentsOf: fixture.b)
        expectStatus("nativeTestAEdited", equals: "false", in: app)

        // Delayed autosave creates a deterministic pending-write edge case.
        // Permanent deletion must close this document too;
        // ordinary documents retain native autosave outside this test harness.
        app.activate()
        let originalWindow = app.windows["nativeDocumentWindowA"]
        let originalRow = fixtureRow("A", in: originalWindow)
        originalRow.click()
        let amount = app.textFields["expenseAmountField"]
        XCTAssertTrue(amount.exists || amount.waitForExistence(timeout: 5))
        replaceText(in: amount, with: "234.56")
        let saveEdit = app.buttons["saveExpenseButton"]
        XCTAssertTrue(saveEdit.isEnabled)
        saveEdit.click()
        XCTAssertTrue(!saveEdit.exists || saveEdit.waitForNonExistence(timeout: 5))
        expectLabel(originalRow, contains: "$234.56")
        expectStatus("nativeTestAEdited", equals: "true", in: app)
        XCTAssertEqual(try Data(contentsOf: fixture.a), originalA,
                       "The real editor change must still be unsaved when external deletion begins.")

        performFixtureAction("delete", in: fixture)
        assertDocumentAClosed(in: fixture)
        XCTAssertFalse(app.buttons["Duplicate"].firstMatch.exists,
                       "Permanent deletion must close the document without a recovery prompt.")
        XCTAssertFalse(app.buttons["Save"].firstMatch.exists,
                       "The deleted document must not ask to save its pending changes.")
        let resurrected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: fixture.a.path)
        }, object: nil)
        resurrected.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [resurrected], timeout: 2), .completed,
                       "Closing the deleted document must not recreate its file.")
        assertDocument("B", isOpenIn: app)
        XCTAssertEqual(try Data(contentsOf: fixture.b), originalB)
        attachScreenshot("Deleting a document with pending edits closes only that window", app: app)
    }

    func testPermanentRemovalClosesRecoveryAndAnOpenPaymentEditor() throws {
        let fixture = try launchNativeDocuments()
        try requireTrashDriver(for: fixture)
        let app = fixture.app
        let originalA = try Data(contentsOf: fixture.a)
        let originalB = try Data(contentsOf: fixture.b)

        app.activate()
        fixtureRow("A", in: app.windows["nativeDocumentWindowA"]).click()
        let amount = app.textFields["expenseAmountField"]
        XCTAssertTrue(amount.exists || amount.waitForExistence(timeout: 5))
        replaceText(in: amount, with: "345.67")
        let saveEdit = app.buttons["saveExpenseButton"]
        XCTAssertTrue(saveEdit.exists && saveEdit.isEnabled)
        XCTAssertEqual(try Data(contentsOf: fixture.a), originalA,
                       "The editor's draft must not have changed the file before deletion.")

        performFixtureAction("trash", in: fixture)
        assertDeletionAlert(in: app)
        XCTAssertTrue(saveEdit.exists,
                      "Recovery must be presented immediately above the open payment editor.")
        XCTAssertEqual(amount.value as? String, "345.67")
        assertDocument("A", isOpenIn: app)
        attachScreenshot("Recovery appears above a payment editor with a pending draft", app: app)
        performFixtureAction("delete", in: fixture)
        assertDocumentAClosed(in: fixture)
        XCTAssertTrue(!saveEdit.exists || saveEdit.waitForNonExistence(timeout: 5),
                      "Permanent deletion must close the document, recovery sheet, and payment editor.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.a.path))
        let resurrected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: fixture.a.path)
        }, object: nil)
        resurrected.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [resurrected], timeout: 2), .completed,
                       "Closing the expense editor must not save its draft into a recreated file.")
        XCTAssertEqual(try Data(contentsOf: fixture.b), originalB)
    }

    private func launchNativeDocuments() throws -> NativeFixture {
        let session = UUID()
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-native-documents",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-ApplePersistenceIgnoreState", "YES",
                               "-NSQuitAlwaysKeepsWindows", "NO",
                               "-NSRecentDocumentsLimit", "0"]
        app.launchEnvironment["TALLY_NATIVE_TEST_SESSION"] = session.uuidString
        launchedApp = app
        app.launch()
        let ready = status("nativeTestStatus", in: app)
        XCTAssertTrue(ready.exists || ready.waitForExistence(timeout: 15), "The native fixture inspector must appear.")
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                let text = element.value as? String ?? element.label
                return text == "ready" || text.hasPrefix("error:")
            }, object: ready
        )
        let readiness = XCTWaiter.wait(for: [finished], timeout: 20)
        if readiness != .completed {
            let actualStatus = ready.exists ? text(of: ready) : "Inspector status element is absent."
            let attachment = XCTAttachment(string: "Native fixture readiness: \(actualStatus)\n\n\(app.debugDescription)")
            attachment.name = "Native fixture startup status and window hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(readiness, .completed, "Native fixture status: \(ready.exists ? text(of: ready) : "absent")")
        XCTAssertEqual(text(of: ready), "ready")
        let root = URL(fileURLWithPath: text(of: status("nativeTestRootPath", in: app)), isDirectory: true)
        XCTAssertEqual(root.lastPathComponent, "TallyNativeDocumentTests-\(session.uuidString)")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".test-owner"), encoding: .utf8), session.uuidString)
        let a = URL(fileURLWithPath: text(of: status("nativeTestAURL", in: app)))
        let b = URL(fileURLWithPath: text(of: status("nativeTestBURL", in: app)))
        let fixture = NativeFixture(app: app, session: session, root: root, a: a, b: b)
        self.fixture = fixture
        try requireOwned(a, in: fixture)
        try requireOwned(b, in: fixture)
        expectStatus("nativeTestOpenCount", equals: "2", in: app)
        assertDocument("A", isOpenIn: app)
        assertDocument("B", isOpenIn: app)
        return fixture
    }

    private func assertDocument(_ name: String, isOpenIn app: XCUIApplication) {
        expectStatus("nativeTest\(name)Open", equals: "true", in: app)
        let window = app.windows["nativeDocumentWindow\(name)"]
        XCTAssertTrue(window.exists || window.waitForExistence(timeout: 5), "The native window for fixture \(name) must remain open.")
        let row = fixtureRow(name, in: window)
        XCTAssertTrue(row.exists || row.waitForExistence(timeout: 5), "Fixture \(name)'s actual document content must remain available.")
    }

    private func fixtureRow(_ name: String, in window: XCUIElement) -> XCUIElement {
        window.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
            "expenseRow-", "Native fixture \(name),"
        )).firstMatch
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.exists || field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        let empty = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ OR value == %@", "", field.placeholderValue ?? ""), object: field
        )
        XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 3), .completed)
        field.typeText(text)
        let replaced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [replaced], timeout: 3), .completed)
    }

    private func expectLabel(_ element: XCUIElement, contains text: String) {
        if element.label.contains(text) { return }
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 5), .completed)
    }

    private func performFixtureAction(_ action: String, in fixture: NativeFixture) {
        let app = fixture.app
        app.activate()
        let button = app.buttons["nativeTestAction-\(action)"]
        XCTAssertTrue(button.exists || button.waitForExistence(timeout: 5))
        if !button.isHittable {
            let attachment = XCTAttachment(string: "Fixture action \(action), frame \(button.frame)\n\n\(app.debugDescription)")
            attachment.name = "Fixture action visibility and native windows"
            attachment.lifetime = .keepAlways
            add(attachment)
            attachScreenshot("Fixture action is not hittable", app: app)
        }
        XCTAssertTrue(button.isHittable, "The visible fixture control must receive the intended action.")
        button.click()
        let result = status("nativeTestMutationStatus", in: app)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            let text = element.value as? String ?? element.label
            return text == "complete:\(action)" || text.hasPrefix("error:\(action):")
        }, object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 15), .completed,
                       "The bounded fixture operation must finish without blocking the document UI.")
        let description = text(of: result)
        if description != "complete:\(action)" {
            let attachment = XCTAttachment(string: description)
            attachment.name = "Fixture file-operation error with underlying NSError"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(description, "complete:\(action)")
    }

    private func requireOwned(_ url: URL, in fixture: NativeFixture) throws {
        let root = fixture.root.standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.pathComponents
        guard path.count > root.count, path.starts(with: root),
              try String(contentsOf: fixture.root.appendingPathComponent(".test-owner"), encoding: .utf8)
                == fixture.session.uuidString else {
            throw NativeTestError.unownedFixture
        }
    }

    private func status(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func text(of element: XCUIElement) -> String {
        element.value as? String ?? element.label
    }

    private func expectStatus(_ identifier: String, equals expected: String, in app: XCUIApplication) {
        let field = status(identifier, in: app)
        XCTAssertTrue(field.exists || field.waitForExistence(timeout: 5))
        if text(of: field) == expected { return }
        let match = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ OR label == %@", expected, expected), object: field
        )
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 8), .completed,
                       "Expected \(identifier) to be \(expected); got \(text(of: field)).")
    }

    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct NativeFixture {
        let app: XCUIApplication
        let session: UUID
        let root: URL
        let a: URL
        let b: URL
    }
}

private enum NativeTestError: Error {
    case unownedFixture
}
#endif
