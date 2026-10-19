import XCTest
@testable import PostMealSMBLockout

final class PostMealSMBLockoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let on = PostMealSMBLockoutPolicy(configuration: .init(enabled: true))
    private let off = PostMealSMBLockoutPolicy()

    private func meal(_ at: Date, id: String = "pump-1") -> PostMealSMBLockoutPolicy.Event {
        .init(id: id, kind: .verifiedMealBolusDelivered, occurredAt: at, deliveredUnits: 4.2)
    }

    func testDisabledByDefaultEvenWithConfirmedMeal() {
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
            let state = on.applying(.init(id: "id-\(kind)", kind: kind, occurredAt: now, deliveredUnits: 4.2), to: .init(), now: now)
            XCTAssertFalse(on.decision(state: state, now: now).shouldSuppressSMB, "kind: \(kind)")
        }
    }

    func testDelayedCarbEntryDoesNotExtendLockout() {
        let state = on.applying(meal(now), to: .init(), now: now)
        let delayed = PostMealSMBLockoutPolicy.Event(id: "carbs-later", kind: .delayedCarbsEntered, occurredAt: now.addingTimeInterval(1700))
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
        let zero = PostMealSMBLockoutPolicy.Event(id: "zero", kind: .verifiedMealBolusDelivered, occurredAt: now, deliveredUnits: 0)
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
}
