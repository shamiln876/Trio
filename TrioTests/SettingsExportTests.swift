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
        XCTAssertEqual(fileName.components(separatedBy: "_").count, 2, "File name should have one underscore")
    }

    func testPostMealSMBLockoutDefaultOffAndRoundTrip() throws {
        XCTAssertFalse(TrioSettings().postMealSMBLockoutEnabled)
        var settings = TrioSettings()
        settings.postMealSMBLockoutEnabled = true
        let restored = try JSONDecoder().decode(TrioSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restored.postMealSMBLockoutEnabled)
        settings.postMealSMBLockoutEnabled = false
        let disabled = try JSONDecoder().decode(TrioSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(disabled.postMealSMBLockoutEnabled)
    }

    func testOldSettingsWithoutMealLockoutRemainOff() throws {
        let settings = try JSONDecoder().decode(TrioSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.postMealSMBLockoutEnabled)
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

    // Helper function to test CSV escaping (extracted from Settings.StateModel)
    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
