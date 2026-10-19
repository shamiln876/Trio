import XCTest
@testable import PostMealSMBLockout

/// Regression tests for incorrectly classifying a similarly sized correction
/// bolus as a meal. No Trio pump or dosing code is called.
final class TrustedPumpHistoryMatchTests: XCTestCase {
    typealias Matcher = VerifiedMealBolusMatcher
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let matcher = Matcher()

    private func intent(link: String? = "meal-event") -> Matcher.MealIntent {
        .init(
            transactionID: "meal-request",
            requestedAt: now,
            requestedUnits: 4.2,
            linkedPumpEventID: link
        )
    }

    private func delivery(
        id: String = "meal-event",
        seconds: TimeInterval = 20,
        delivered: Double = 4.2,
        programmed: Double = 4.2,
        isSMB: Bool = false,
        isFinal: Bool = true
    ) -> Matcher.PumpDelivery {
        .init(
            eventID: id,
            timestamp: now.addingTimeInterval(seconds),
            deliveredUnits: delivered,
            programmedUnits: programmed,
            isAutomaticSMB: isSMB,
            isFinal: isFinal
        )
    }

    func testNoTrustedLinkCannotClassifySameSizedCorrectionAsMeal() {
        let event = delivery(id: "correction")
        XCTAssertNil(matcher.confirmedEvent(
            for: intent(link: nil), pumpHistory: [event],
            now: now.addingTimeInterval(40)
        ))
    }

    func testWrongLinkedEventDoesNotMatchEvenAtSameTimeAndDose() {
        let correction = delivery(id: "correction")
        XCTAssertNil(matcher.confirmedEvent(
            for: intent(), pumpHistory: [correction],
            now: now.addingTimeInterval(40)
        ))
    }

    func testTrustedLinkSelectsMealEvenWhenCorrectionLooksIdentical() {
        let correction = delivery(id: "correction")
        let meal = delivery(id: "meal-event")
        let result = matcher.confirmedEvent(
            for: intent(), pumpHistory: [correction, meal],
            now: now.addingTimeInterval(40)
        )
        XCTAssertEqual(result?.id, "meal-event")
        XCTAssertEqual(result?.deliveredUnits, 4.2)
    }

    func testDuplicateLinkedHistoryEntriesAreAmbiguousAndRejected() {
        let sameEvent = delivery()
        XCTAssertNil(matcher.confirmedEvent(
            for: intent(), pumpHistory: [sameEvent, sameEvent],
            now: now.addingTimeInterval(40)
        ))
    }

    func testLinkedPartialOrPendingDeliveryIsRejected() {
        XCTAssertNil(matcher.confirmedEvent(
            for: intent(), pumpHistory: [delivery(delivered: 2.1)],
            now: now.addingTimeInterval(40)
        ))
        XCTAssertNil(matcher.confirmedEvent(
            for: intent(), pumpHistory: [delivery(isFinal: false)],
            now: now.addingTimeInterval(40)
        ))
        XCTAssertNil(matcher.confirmedEvent(
            for: intent(), pumpHistory: [delivery(isSMB: true)],
            now: now.addingTimeInterval(40)
        ))
    }

    func testLatePumpHistoryDoesNotResetTimerToReceiptTime() {
        let event = delivery(seconds: 20)
        let receipt = now.addingTimeInterval(900)
        guard let match = matcher.confirmedEvent(
            for: intent(), pumpHistory: [event], now: receipt
        ) else {
            return XCTFail("Finalized linked pump history should match")
        }
        let policy = PostMealSMBLockoutPolicy(configuration: .init(enabled: true))
        let state = policy.applying(match, to: .init(), now: receipt)
        let decision = policy.decision(state: state, now: receipt)
        XCTAssertTrue(decision.shouldSuppressSMB)
        XCTAssertEqual(decision.remainingSeconds, 920, accuracy: 0.001)
        XCTAssertFalse(policy.decision(
            state: state, now: now.addingTimeInterval(1820)
        ).shouldSuppressSMB)
    }
}
