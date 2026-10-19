@testable import Trio
import XCTest

final class SettingsExportTests: XCTestCase {
    func testCSVEscaping() {
        // Test CSV escaping functionality
        let testValue = "Test,Value\"With\nSpecial Characters"
        let escaped = csvEscape(testValue)
        let expected = "\"Test,Value\"\"With\nSpecial Characters\""
        XCTAssertEqual(escaped, expected, "CSV escaping should handle commas, quotes, and newlines")
    }

    func testCSVEscapingSimple() {
        // Test simple values don't get escaped
        let testValue = "SimpleValue"
        let escaped = csvEscape(testValue)
        XCTAssertEqual(escaped, testValue, "Simple values should not be escaped")
    }

    func testExportCSVStructure() {
        // Test that the CSV has the expected header structure
        let expectedHeader = "Setting Category,Subcategory,Setting Name,Value,Unit"
        // This test would require mocking the settings manager and file storage
        // For now, we verify the header format is correct
        XCTAssertEqual(expectedHeader.components(separatedBy: ",").count, 5, "CSV header should have 5 columns")
    }

    // Earlier ExportError assertions were removed: that API no longer exists
    // in Settings.StateModel. The file was previously absent from the Xcode
    // test target, so those stale references had never compiled.

    func testExportFileNaming() {
        // Test that export files have the correct naming pattern
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let fileName = "TrioSettings_\(timestamp).csv"

        XCTAssertTrue(fileName.hasPrefix("TrioSettings_"), "File name should start with TrioSettings_")
        XCTAssertTrue(fileName.hasSuffix(".csv"), "File name should end with .csv")
        XCTAssertEqual(
            fileName.components(separatedBy: "_").count,
            3,
            "Prefix and yyyyMMdd_HHmmss timestamp should contain two underscores"
        )
    }

    func testPostMealSMBLockoutDefaultOnAndRoundTrip() throws {
        XCTAssertTrue(TrioSettings().postMealSMBLockoutEnabled)
        var settings = TrioSettings()
        settings.postMealSMBLockoutEnabled = true
        let restored = try JSONDecoder().decode(TrioSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restored.postMealSMBLockoutEnabled)
        let oldRevision = settings.postMealSMBLockoutRevision
        settings.postMealSMBLockoutEnabled = false
        XCTAssertNotEqual(settings.postMealSMBLockoutRevision, oldRevision)
        let disabled = try JSONDecoder().decode(TrioSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(disabled.postMealSMBLockoutEnabled)
    }

    func testOldSettingsWithoutMealLockoutDefaultOn() throws {
        let settings = try JSONDecoder().decode(TrioSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.postMealSMBLockoutEnabled)
    }

    func testVerifiedPumpDoseStartPreventsCorrectionMisclassification() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let verified = PostMealSMBPumpHistoryVerifier.matches(
            requestedAt: t, requestedUnits: 4.2,
            observedPumpDoseStartAt: t.addingTimeInterval(12),
            deliveredAt: t.addingTimeInterval(12),
            deliveredUnits: 4.2, programmedUnits: 4.2,
            isMutable: false, isSMB: false, isExternal: false,
            now: t.addingTimeInterval(40)
        )
        XCTAssertTrue(verified)

        // Same-size correction at 30 seconds must not match a meal's
        // actual in-progress dose that started at 12 seconds.
        let correction = PostMealSMBPumpHistoryVerifier.matches(
            requestedAt: t, requestedUnits: 4.2,
            observedPumpDoseStartAt: t.addingTimeInterval(12),
            deliveredAt: t.addingTimeInterval(30),
            deliveredUnits: 4.2, programmedUnits: 4.2,
            isMutable: false, isSMB: false, isExternal: false,
            now: t.addingTimeInterval(40)
        )
        XCTAssertFalse(correction)
    }

    func testMissingPumpObservedDoseCannotClaimConfirmedMeal() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(PostMealSMBPumpHistoryVerifier.matches(
            requestedAt: t, requestedUnits: 4.2,
            observedPumpDoseStartAt: nil,
            deliveredAt: t.addingTimeInterval(10),
            deliveredUnits: 4.2, programmedUnits: 4.2,
            isMutable: false, isSMB: false, isExternal: false,
            now: t.addingTimeInterval(30)
        ))
    }

    func testIncompleteOrUnfinalizedPumpBolusIsRejected() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func match(delivered: Double, mutable: Bool) -> Bool {
            PostMealSMBPumpHistoryVerifier.matches(
                requestedAt: t, requestedUnits: 4.2,
                observedPumpDoseStartAt: t.addingTimeInterval(10),
                deliveredAt: t.addingTimeInterval(10),
                deliveredUnits: delivered, programmedUnits: 4.2,
                isMutable: mutable, isSMB: false, isExternal: false,
                now: t.addingTimeInterval(30)
            )
        }
        XCTAssertFalse(match(delivered: 2.1, mutable: false))
        XCTAssertFalse(match(delivered: 4.15, mutable: false), "One missing DASH pulse is partial delivery")
        XCTAssertFalse(match(delivered: 4.2, mutable: true))
    }

    func testAutomaticAndExternalPumpBolusesCannotConfirmMeal() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func match(smb: Bool, external: Bool) -> Bool {
            PostMealSMBPumpHistoryVerifier.matches(
                requestedAt: t, requestedUnits: 4.2,
                observedPumpDoseStartAt: t.addingTimeInterval(10),
                deliveredAt: t.addingTimeInterval(10),
                deliveredUnits: 4.2, programmedUnits: 4.2,
                isMutable: false, isSMB: smb, isExternal: external,
                now: t.addingTimeInterval(30)
            )
        }
        XCTAssertFalse(match(smb: true, external: false))
        XCTAssertFalse(match(smb: false, external: true))
    }

    func testPumpHistoryCannotConfirmDeliveryFromFuture() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(PostMealSMBPumpHistoryVerifier.matches(
            requestedAt: t, requestedUnits: 4.2,
            observedPumpDoseStartAt: t.addingTimeInterval(10),
            deliveredAt: t.addingTimeInterval(10),
            deliveredUnits: 4.2, programmedUnits: 4.2,
            isMutable: false, isSMB: false, isExternal: false,
            now: t.addingTimeInterval(5)
        ))
    }

    func testLiveThirtyMinuteEnactmentGateExpiresAtExactlyThirtyMinutes() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(PostMealSMBEnactmentGate.shouldBlockSMB(
            enabled: true, confirmedDeliveredAt: t, pendingCommandAcceptedAt: nil,
            now: t.addingTimeInterval(1799)
        ))
        XCTAssertFalse(PostMealSMBEnactmentGate.shouldBlockSMB(
            enabled: true, confirmedDeliveredAt: t, pendingCommandAcceptedAt: nil,
            now: t.addingTimeInterval(1800)
        ))
        XCTAssertFalse(PostMealSMBEnactmentGate.shouldBlockSMB(
            enabled: true, confirmedDeliveredAt: t, pendingCommandAcceptedAt: nil,
            now: t.addingTimeInterval(-1)
        ))
    }

    func testInitiatedMealWaitCoversThirtyMinutesWithoutFinalHistory() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(PostMealSMBEnactmentGate.shouldBlockSMB(
            enabled: true, confirmedDeliveredAt: nil, pendingCommandAcceptedAt: t,
            now: t.addingTimeInterval(1799)
        ))
        XCTAssertFalse(PostMealSMBEnactmentGate.shouldBlockSMB(
            enabled: true, confirmedDeliveredAt: nil, pendingCommandAcceptedAt: t,
            now: t.addingTimeInterval(1800)
        ))
        XCTAssertFalse(PostMealSMBEnactmentGate.shouldBlockSMB(
            enabled: true, confirmedDeliveredAt: nil, pendingCommandAcceptedAt: nil,
            now: t.addingTimeInterval(60)
        ))
    }

    func testLiveManualOffOverridesOldConfirmedDoseAndPendingGuard() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(PostMealSMBEnactmentGate.shouldBlockSMB(
            enabled: false, confirmedDeliveredAt: t, pendingCommandAcceptedAt: t,
            now: t.addingTimeInterval(1)
        ))
    }

    private func withMealWaitStore(_ body: (UserDefaults, String, Date) throws -> Void) rethrows {
        let suite = "PostMealWait.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testMealWaitSurvivesNewStoreAndExpiresWithoutHistory() {
        withMealWaitStore { defaults, suite, t in
            let store = PostMealSMBWaitStore(defaults: defaults)
            store.recordMealResult(success: true, id: "meal", commandRevision: "on", enabled: true, revision: "on", acceptedAt: t)
            let restarted = PostMealSMBWaitStore(defaults: UserDefaults(suiteName: suite)!)
            XCTAssertEqual(restarted.blockUntil(enabled: true, revision: "on", now: t.addingTimeInterval(1799)), t.addingTimeInterval(1800))
            XCTAssertNil(restarted.blockUntil(enabled: true, revision: "on", now: t.addingTimeInterval(1800)))
        }
    }

    func testMealWaitOffOnAndLateCallbackCannotReviveOldMeal() {
        withMealWaitStore { defaults, _, t in
            let store = PostMealSMBWaitStore(defaults: defaults)
            store.recordMealResult(success: true, id: "meal", commandRevision: "on", enabled: true, revision: "on", acceptedAt: t)
            store.synchronize(enabled: false, revision: "off")
            store.synchronize(enabled: true, revision: "on-again")
            store.recordMealResult(success: true, id: "late-old", commandRevision: "on", enabled: true, revision: "on-again", acceptedAt: t.addingTimeInterval(30))
            XCTAssertNil(store.blockUntil(enabled: true, revision: "on-again", now: t.addingTimeInterval(60)))
            store.recordMealResult(success: true, id: "new", commandRevision: "on-again", enabled: true, revision: "on-again", acceptedAt: t.addingTimeInterval(60))
            XCTAssertEqual(store.blockUntil(enabled: true, revision: "on-again", now: t.addingTimeInterval(60)), t.addingTimeInterval(1860))
        }
    }

    func testFailedAndDuplicateMealCallbacksCannotExtendWait() {
        withMealWaitStore { defaults, _, t in
            let store = PostMealSMBWaitStore(defaults: defaults)
            store.recordMealResult(success: false, id: "failed", commandRevision: "on", enabled: true, revision: "on", acceptedAt: t)
            XCTAssertNil(store.blockUntil(enabled: true, revision: "on", now: t))
            store.recordMealResult(success: true, id: "meal", commandRevision: "on", enabled: true, revision: "on", acceptedAt: t)
            store.recordMealResult(success: true, id: "meal", commandRevision: "on", enabled: true, revision: "on", acceptedAt: t.addingTimeInterval(300))
            XCTAssertEqual(store.blockUntil(enabled: true, revision: "on", now: t.addingTimeInterval(300)), t.addingTimeInterval(1800))
        }
    }

    func testConcurrentMealCallbacksKeepLatestAnchor() {
        withMealWaitStore { defaults, _, t in
            let store = PostMealSMBWaitStore(defaults: defaults)
            DispatchQueue.concurrentPerform(iterations: 100) { index in
                store.recordMealResult(success: true, id: "meal-\(index)", commandRevision: "on", enabled: true, revision: "on", acceptedAt: t.addingTimeInterval(Double(index)))
            }
            XCTAssertEqual(store.blockUntil(enabled: true, revision: "on", now: t.addingTimeInterval(100)), t.addingTimeInterval(1899))
        }
    }

    func testSettingChangeAndRestartDoNotReviveAnAnchor() {
        withMealWaitStore { defaults, suite, t in
            let store = PostMealSMBWaitStore(defaults: defaults)
            store.recordMealResult(success: true, id: "meal", commandRevision: "old", enabled: true, revision: "old", acceptedAt: t)
            XCTAssertNil(store.blockUntil(enabled: true, revision: "new", now: t.addingTimeInterval(1)))
            let restarted = PostMealSMBWaitStore(defaults: UserDefaults(suiteName: suite)!)
            XCTAssertNil(restarted.blockUntil(enabled: true, revision: "new", now: t.addingTimeInterval(2)))
        }
    }

    // Helper function to test CSV escaping (extracted from Settings.StateModel)
    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
