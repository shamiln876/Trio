import Foundation

/// Pure, non-actuating post-meal SMB permission policy.
///
/// This does NOT command a pump, alter basal insulin, or authorize a bolus.
/// In a future Trio integration, only verified pump-history delivery of a
/// separately identified MEAL bolus may create a lockout anchor. Carb entries,
/// correction boluses, SMBs, and remote command acknowledgments must not.
public struct PostMealSMBLockoutPolicy: Sendable {
    public struct Configuration: Codable, Equatable, Sendable {
        /// A new feature is OFF until tested and explicitly enabled.
        public var enabled: Bool
        public var durationSeconds: TimeInterval

        public init(enabled: Bool = false, durationSeconds: TimeInterval = 30 * 60) {
            self.enabled = enabled
            self.durationSeconds = durationSeconds
        }
    }

    public enum EventKind: String, Codable, Sendable {
        case verifiedMealBolusDelivered
        case correctionBolusDelivered
        case automaticSMBDelivered
        case carbsEntered
        case delayedCarbsEntered
        case rescueCarbsEntered
        case remoteBolusCommandAcknowledged
    }

    public struct Event: Codable, Equatable, Sendable {
        public var id: String
        public var kind: EventKind
        public var occurredAt: Date
        public var deliveredUnits: Double

        public init(id: String, kind: EventKind, occurredAt: Date, deliveredUnits: Double = 0) {
            self.id = id
            self.kind = kind
            self.occurredAt = occurredAt
            self.deliveredUnits = deliveredUnits
        }
    }

    public struct State: Codable, Equatable, Sendable {
        public var anchor: Event?
        public var consumedEventIDs: [String]

        public init(anchor: Event? = nil, consumedEventIDs: [String] = []) {
            self.anchor = anchor
            self.consumedEventIDs = consumedEventIDs
        }
    }

    public struct Decision: Equatable, Sendable {
        public var shouldSuppressSMB: Bool
        public var expiresAt: Date?
        public var remainingSeconds: TimeInterval

        public init(shouldSuppressSMB: Bool, expiresAt: Date?, remainingSeconds: TimeInterval) {
            self.shouldSuppressSMB = shouldSuppressSMB
            self.expiresAt = expiresAt
            self.remainingSeconds = remainingSeconds
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Idempotent ingestion. Record only real, delivered, classified MEAL boluses.
    /// Unknown/negative/future timestamps must not create a lockout.
    public func applying(_ event: Event, to state: State, now: Date) -> State {
        guard !event.id.isEmpty, !state.consumedEventIDs.contains(event.id),
              event.kind == .verifiedMealBolusDelivered,
              event.deliveredUnits.isFinite, event.deliveredUnits > 0,
              event.occurredAt <= now,
              event.occurredAt.timeIntervalSince(now) >= -24 * 60 * 60
        else { return state }

        var next = state
        next.consumedEventIDs.append(event.id)
        // Bound persisted deduplication records; the verifier should use stable pump event IDs.
        if next.consumedEventIDs.count > 256 {
            next.consumedEventIDs.removeFirst(next.consumedEventIDs.count - 256)
        }
        if let existing = next.anchor, event.occurredAt < existing.occurredAt {
            return next
        }
        next.anchor = event
        return next
    }

    /// Permission-only decision: when false, the ordinary Trio dosing algorithm still
    /// determines whether an SMB is needed. The policy never requests insulin.
    public func decision(state: State, now: Date) -> Decision {
        guard configuration.enabled,
              configuration.durationSeconds.isFinite,
              configuration.durationSeconds >= 30 * 60,
              configuration.durationSeconds <= 60 * 60,
              let anchor = state.anchor,
              anchor.kind == .verifiedMealBolusDelivered,
              anchor.deliveredUnits.isFinite, anchor.deliveredUnits > 0,
              anchor.occurredAt <= now
        else { return Decision(shouldSuppressSMB: false, expiresAt: nil, remainingSeconds: 0) }

        let expiration = anchor.occurredAt.addingTimeInterval(configuration.durationSeconds)
        let remaining = max(0, expiration.timeIntervalSince(now))
        return Decision(
            shouldSuppressSMB: remaining > 0,
            expiresAt: remaining > 0 ? expiration : nil,
            remainingSeconds: remaining
        )
    }
}
