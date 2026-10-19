@testable import PostMealSMBLockout
import XCTest

final class PostMealSMBLockoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let on = PostMealSMBLockoutPolicy(configuration: .init(enabled: true))
    private let off = PostMealSMBLockoutPolicy(configuration: .init(enabled: false))

    private func meal(_ at: Date, id: String = "pump-1") -> PostMealSMBLockoutPolicy.Event {
        .init(id: id, kind: .verifiedMealBolusDelivered, occurredAt: at, deliveredUnits: 4.2)
    }

    func testEnabledByDefault() {
        let policy = PostMealSMBLockoutPolicy()
        let state = policy.applying(meal(now), to: .init(), now: now)
        XCTAssertTrue(policy.decision(state: state, now: now).shouldSuppressSMB)
    }

    func testExplicitlyDisabledEvenWithConfirmedMeal() {
        let state = off.applying(meal(now), to: .init(), now: now)
        XCTAssertFalse(off.decision(state: state, now: now).shouldSuppressSMB)
    }

    func testThirtyMinutesStartsOnlyAfterConfirmedDelivery() {
        let state = on.applying(meal(now), to: .init(), now: now)
        XCTAssertTrue(on.decision(state: state, now: now).shouldSuppressSMB)
        XCTAssertTrue(on.decision(state: state, now: now.addingTimeInterval(1799)).shouldSuppressSMB)
        XCTAssertFalse(on.decision(state: state, now: now.addingTimeInterval(1800)).shouldSuppressSMB)
    }

    func testCarbsCorrectionsSMBsAndRemoteAcknowledgmentsDoNotStart() {
        let notMeals: [PostMealSMBLockoutPolicy.EventKind] = [
            .carbsEntered, .delayedCarbsEntered, .rescueCarbsEntered,
            .correctionBolusDelivered, .automaticSMBDelivered, .remoteBolusCommandAcknowledged
        ]
        for kind in notMeals {
            let state = on.applying(
                .init(id: "id-\(kind)", kind: kind, occurredAt: now, deliveredUnits: 4.2),
                to: .init(),
                now: now
            )
            XCTAssertFalse(on.decision(state: state, now: now).shouldSuppressSMB, "kind: \(kind)")
        }
    }

    func testDelayedCarbEntryDoesNotExtendLockout() {
        let state = on.applying(meal(now), to: .init(), now: now)
        let delayed = PostMealSMBLockoutPolicy.Event(
            id: "carbs-later",
            kind: .delayedCarbsEntered,
            occurredAt: now.addingTimeInterval(1700)
        )
        let later = on.applying(delayed, to: state, now: now.addingTimeInterval(1700))
        XCTAssertFalse(on.decision(state: later, now: now.addingTimeInterval(1800)).shouldSuppressSMB)
    }

    func testDuplicatePumpHistoryEventCannotRestartTimer() {
        let state = on.applying(meal(now), to: .init(), now: now)
        let duplicate = meal(now.addingTimeInterval(300), id: "pump-1")
        let next = on.applying(duplicate, to: state, now: now.addingTimeInterval(300))
        XCTAssertEqual(state, next)
    }

    func testSecondDistinctConfirmedMealRestartsItsOwnThirtyMinutes() {
        let first = on.applying(meal(now), to: .init(), now: now)
        let second = on.applying(meal(now.addingTimeInterval(900), id: "pump-2"), to: first, now: now.addingTimeInterval(900))
        XCTAssertTrue(on.decision(state: second, now: now.addingTimeInterval(1800)).shouldSuppressSMB)
        XCTAssertFalse(on.decision(state: second, now: now.addingTimeInterval(2700)).shouldSuppressSMB)
    }

    func testFutureOrZeroInsulinEventDoesNotStart() {
        let future = on.applying(meal(now.addingTimeInterval(300)), to: .init(), now: now)
        XCTAssertFalse(on.decision(state: future, now: now).shouldSuppressSMB)
        let zero = PostMealSMBLockoutPolicy.Event(
            id: "zero",
            kind: .verifiedMealBolusDelivered,
            occurredAt: now,
            deliveredUnits: 0
        )
        XCTAssertFalse(on.decision(state: on.applying(zero, to: .init(), now: now), now: now).shouldSuppressSMB)
    }

    func testRestartRetainsOnlyOriginalElapsedWallClockTime() throws {
        let state = on.applying(meal(now), to: .init(), now: now)
        let decoded = try JSONDecoder().decode(PostMealSMBLockoutPolicy.State.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(on.decision(state: decoded, now: now.addingTimeInterval(1200)).shouldSuppressSMB)
        XCTAssertFalse(on.decision(state: decoded, now: now.addingTimeInterval(1801)).shouldSuppressSMB)
    }

    func testInvalidDurationIsNeverApplied() {
        let state = on.applying(meal(now), to: .init(), now: now)
        let invalid = PostMealSMBLockoutPolicy(configuration: .init(enabled: true, durationSeconds: 10))
        XCTAssertFalse(invalid.decision(state: state, now: now).shouldSuppressSMB)
    }

    func testToggleOffImmediatelyDisablesAndPreventsRetroactiveTimer() {
        var policy = on
        var state = policy.applying(meal(now), to: .init(), now: now)
        XCTAssertTrue(policy.decision(state: state, now: now).shouldSuppressSMB)
        policy.setEnabled(false, state: &state, now: now.addingTimeInterval(120))
        XCTAssertFalse(policy.decision(state: state, now: now.addingTimeInterval(121)).shouldSuppressSMB)
        policy.setEnabled(true, state: &state, now: now.addingTimeInterval(240))
        XCTAssertFalse(policy.decision(state: state, now: now.addingTimeInterval(241)).shouldSuppressSMB)
        state = policy.applying(meal(now.addingTimeInterval(300), id: "new-meal"), to: state, now: now.addingTimeInterval(300))
        XCTAssertTrue(policy.decision(state: state, now: now.addingTimeInterval(301)).shouldSuppressSMB)
    }

    func testLatePumpHistoryFromBeforeEnableCannotStart() {
        var policy = off
        var state = PostMealSMBLockoutPolicy.State()
        policy.setEnabled(true, state: &state, now: now.addingTimeInterval(500))
        state = policy.applying(meal(now.addingTimeInterval(100), id: "earlier"), to: state, now: now.addingTimeInterval(600))
        XCTAssertFalse(policy.decision(state: state, now: now.addingTimeInterval(600)).shouldSuppressSMB)
        state = policy.applying(meal(now.addingTimeInterval(550), id: "later"), to: state, now: now.addingTimeInterval(600))
        XCTAssertTrue(policy.decision(state: state, now: now.addingTimeInterval(600)).shouldSuppressSMB)
    }

    func testPreferenceAndTimerSurviveRestartButOffIsPersistent() throws {
        var policy = off
        var state = PostMealSMBLockoutPolicy.State()
        policy.setEnabled(true, state: &state, now: now)
        state = policy.applying(meal(now.addingTimeInterval(5)), to: state, now: now.addingTimeInterval(5))
        let newPolicy = try JSONDecoder().decode(PostMealSMBLockoutPolicy.self, from: JSONEncoder().encode(policy))
        let newState = try JSONDecoder().decode(PostMealSMBLockoutPolicy.State.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(newPolicy.configuration.enabled)
        XCTAssertTrue(newPolicy.decision(state: newState, now: now.addingTimeInterval(130)).shouldSuppressSMB)
        policy.setEnabled(false, state: &state, now: now.addingTimeInterval(200))
        let disabled = try JSONDecoder().decode(PostMealSMBLockoutPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertFalse(disabled.configuration.enabled)
    }

    func testIdenticalToggleDoesNotResetExistingTimer() {
        var policy = on
        var state = policy.applying(meal(now), to: .init(), now: now)
        policy.setEnabled(true, state: &state, now: now.addingTimeInterval(900))
        XCTAssertTrue(policy.decision(state: state, now: now.addingTimeInterval(1799)).shouldSuppressSMB)
        XCTAssertFalse(policy.decision(state: state, now: now.addingTimeInterval(1800)).shouldSuppressSMB)
    }

    func testMatchingFinalPumpDeliveryRequiresUniqueMealIntent() {
        let matcher = VerifiedMealBolusMatcher()
        let intent = VerifiedMealBolusMatcher.MealIntent(
            transactionID: "smart-meal-1", requestedAt: now, requestedUnits: 4.2,
            linkedPumpEventID: "pod-dose-001"
        )
        let delivery = VerifiedMealBolusMatcher.PumpDelivery(
            eventID: "pod-dose-001", timestamp: now.addingTimeInterval(12),
            deliveredUnits: 4.2, programmedUnits: 4.2,
            isAutomaticSMB: false, isFinal: true
        )
        let result = matcher.confirmedEvent(for: intent, pumpHistory: [delivery], now: now.addingTimeInterval(30))
        XCTAssertEqual(result?.id, "pod-dose-001")
        XCTAssertEqual(result?.kind, .verifiedMealBolusDelivered)
        XCTAssertEqual(result?.deliveredUnits, 4.2)
    }

    func testMatcherRejectsAttemptWithoutPumpConfirmation() {
        let matcher = VerifiedMealBolusMatcher()
        let intent = VerifiedMealBolusMatcher.MealIntent(
            transactionID: "unconfirmed", requestedAt: now, requestedUnits: 4.2
        )
        XCTAssertNil(matcher.confirmedEvent(for: intent, pumpHistory: [], now: now.addingTimeInterval(30)))
        let pending = VerifiedMealBolusMatcher.PumpDelivery(
            eventID: "pending", timestamp: now.addingTimeInterval(5),
            deliveredUnits: 4.2, programmedUnits: 4.2, isAutomaticSMB: false, isFinal: false
        )
        XCTAssertNil(matcher.confirmedEvent(for: intent, pumpHistory: [pending], now: now.addingTimeInterval(30)))
    }

    func testMatcherRejectsPartialDeliveryAndSMB() {
        let matcher = VerifiedMealBolusMatcher()
        let intent = VerifiedMealBolusMatcher.MealIntent(
            transactionID: "meal", requestedAt: now, requestedUnits: 4.2
        )
        let partial = VerifiedMealBolusMatcher.PumpDelivery(
            eventID: "partial", timestamp: now.addingTimeInterval(8),
            deliveredUnits: 2.1, programmedUnits: 4.2, isAutomaticSMB: false, isFinal: true
        )
        let smb = VerifiedMealBolusMatcher.PumpDelivery(
            eventID: "automatic", timestamp: now.addingTimeInterval(8),
            deliveredUnits: 4.2, programmedUnits: 4.2, isAutomaticSMB: true, isFinal: true
        )
        XCTAssertNil(matcher.confirmedEvent(for: intent, pumpHistory: [partial, smb], now: now.addingTimeInterval(30)))
    }

    func testMatcherRejectsAmbiguousMatchingBoluses() {
        let matcher = VerifiedMealBolusMatcher()
        let intent = VerifiedMealBolusMatcher.MealIntent(
            transactionID: "meal", requestedAt: now, requestedUnits: 4.2
        )
        let a = VerifiedMealBolusMatcher.PumpDelivery(
            eventID: "one", timestamp: now.addingTimeInterval(4),
            deliveredUnits: 4.2, programmedUnits: 4.2, isAutomaticSMB: false, isFinal: true
        )
        let b = VerifiedMealBolusMatcher.PumpDelivery(
            eventID: "two", timestamp: now.addingTimeInterval(5),
            deliveredUnits: 4.2, programmedUnits: 4.2, isAutomaticSMB: false, isFinal: true
        )
        XCTAssertNil(matcher.confirmedEvent(for: intent, pumpHistory: [a, b], now: now.addingTimeInterval(30)))
    }

    func testMatcherRejectsMismatchedDoseAndOldDelivery() {
        let matcher = VerifiedMealBolusMatcher()
        let intent = VerifiedMealBolusMatcher.MealIntent(
            transactionID: "meal", requestedAt: now, requestedUnits: 4.2
        )
        let wrongDose = VerifiedMealBolusMatcher.PumpDelivery(
            eventID: "wrong-dose", timestamp: now.addingTimeInterval(8),
            deliveredUnits: 5.2, programmedUnits: 5.2, isAutomaticSMB: false, isFinal: true
        )
        let old = VerifiedMealBolusMatcher.PumpDelivery(
            eventID: "old", timestamp: now.addingTimeInterval(-180),
            deliveredUnits: 4.2, programmedUnits: 4.2, isAutomaticSMB: false, isFinal: true
        )
        XCTAssertNil(matcher.confirmedEvent(for: intent, pumpHistory: [wrongDose, old], now: now.addingTimeInterval(30)))
    }

    func testMatcherNeverAcceptsDeliveryInTheFuture() {
        let matcher = VerifiedMealBolusMatcher()
        let intent = VerifiedMealBolusMatcher.MealIntent(
            transactionID: "meal", requestedAt: now, requestedUnits: 4.2
        )
        let future = VerifiedMealBolusMatcher.PumpDelivery(
            eventID: "future", timestamp: now.addingTimeInterval(360),
            deliveredUnits: 4.2, programmedUnits: 4.2, isAutomaticSMB: false, isFinal: true
        )
        XCTAssertNil(matcher.confirmedEvent(for: intent, pumpHistory: [future], now: now.addingTimeInterval(20)))
    }
}
