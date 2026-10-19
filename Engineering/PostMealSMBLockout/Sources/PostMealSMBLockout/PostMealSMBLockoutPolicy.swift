import Foundation

/// Pure, non-actuating post-meal SMB permission policy.
///
/// This does NOT command a pump, alter basal insulin, or authorize a bolus.
/// In a future Trio integration, only verified pump-history delivery of a
/// separately identified MEAL bolus may create a lockout anchor. Carb entries,
/// correction boluses, SMBs, and remote command acknowledgments must not.
public struct PostMealSMBLockoutPolicy: Codable, Sendable {
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
        /// Earliest delivery timestamp eligible after an explicit ON transition.
        /// Prevents delayed pump history from resurrecting an earlier meal.
        public var enabledSince: Date?

        public init(anchor: Event? = nil, consumedEventIDs: [String] = [], enabledSince: Date? = nil) {
            self.anchor = anchor
            self.consumedEventIDs = consumedEventIDs
            self.enabledSince = enabledSince
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

    public private(set) var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Apply an explicit user ON/OFF transition, preserving preference until
    /// the next transition. Both transitions invalidate any old meal anchor.
    /// Pure policy only: no UI, algorithm integration, or pump commands.
    public mutating func setEnabled(_ enabled: Bool, state: inout State, now: Date) {
        guard configuration.enabled != enabled else { return }
        configuration.enabled = enabled
        state.anchor = nil
        state.enabledSince = enabled ? now : nil
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
        // Retain a stable ID even while OFF, but never activate an old meal.
        guard configuration.enabled, event.occurredAt >= (next.enabledSince ?? .distantPast) else {
            return next
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
              anchor.occurredAt <= now,
              anchor.occurredAt >= (state.enabledSince ?? .distantPast)
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


/// Correlates a *declared meal intent* with finalized pump history.
/// This is not a pump-command acknowledgement and must never be used to infer
/// that an attempted bolus completed without an immutable history record.
/// No dosing path currently calls this matcher.
public struct VerifiedMealBolusMatcher: Sendable {
    public struct MealIntent: Equatable, Sendable {
        public let transactionID: String
        public let requestedAt: Date
        public let requestedUnits: Double
        /// Trusted link established by the pump transaction/pump-history layer.
        /// No link means we cannot distinguish a meal from a same-sized correction.
        public let linkedPumpEventID: String?

        public init(
            transactionID: String,
            requestedAt: Date,
            requestedUnits: Double,
            linkedPumpEventID: String? = nil
        ) {
            self.transactionID = transactionID
            self.requestedAt = requestedAt
            self.requestedUnits = requestedUnits
            self.linkedPumpEventID = linkedPumpEventID
        }
    }

    public struct PumpDelivery: Equatable, Sendable {
        public let eventID: String
        public let timestamp: Date
        public let deliveredUnits: Double
        public let programmedUnits: Double
        public let isAutomaticSMB: Bool
        public let isFinal: Bool

        public init(
            eventID: String,
            timestamp: Date,
            deliveredUnits: Double,
            programmedUnits: Double,
            isAutomaticSMB: Bool,
            isFinal: Bool
        ) {
            self.eventID = eventID
            self.timestamp = timestamp
            self.deliveredUnits = deliveredUnits
            self.programmedUnits = programmedUnits
            self.isAutomaticSMB = isAutomaticSMB
            self.isFinal = isFinal
        }
    }

    /// Requires a trusted event-ID link, not merely an amount and timestamp.
    /// Only a unique, finalized, full-dose match may start the meal timer.
    /// Rejected/partial/cancelled/ambiguous/unmatched doses must be reviewed
    /// rather than silently disabling other sources of insulin.
    public func confirmedEvent(
        for intent: MealIntent,
        pumpHistory: [PumpDelivery],
        now: Date
    ) -> PostMealSMBLockoutPolicy.Event? {
        guard !intent.transactionID.isEmpty,
              let linkedID = intent.linkedPumpEventID, !linkedID.isEmpty,
              intent.requestedUnits.isFinite, intent.requestedUnits > 0,
              intent.requestedAt <= now,
              intent.requestedAt.timeIntervalSince(now) >= -24 * 60 * 60
        else { return nil }

        let candidates = pumpHistory.filter { delivery in
            guard delivery.eventID == linkedID, delivery.isFinal, !delivery.isAutomaticSMB,
                  delivery.deliveredUnits.isFinite, delivery.programmedUnits.isFinite,
                  delivery.deliveredUnits > 0, delivery.programmedUnits > 0,
                  delivery.timestamp <= now,
                  // Local pump event timestamps can precede request timestamps by
                  // small clock/rounding differences. Delayed uploads are separate.
                  (-15 ... 240).contains(delivery.timestamp.timeIntervalSince(intent.requestedAt))
            else { return false }

            // Omnipod dose increments vary; accept at most 0.05 U representation
            // difference, but reject materially incomplete boluses.
            let tolerance = 0.051
            return abs(delivery.programmedUnits - intent.requestedUnits) <= tolerance
                && abs(delivery.deliveredUnits - intent.requestedUnits) <= tolerance
        }
        guard candidates.count == 1, let match = candidates.first else { return nil }
        return PostMealSMBLockoutPolicy.Event(
            id: match.eventID,
            kind: .verifiedMealBolusDelivered,
            occurredAt: match.timestamp,
            deliveredUnits: match.deliveredUnits
        )
    }
}
