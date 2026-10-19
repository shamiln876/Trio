// swiftformat:disable all
import CryptoKit
import Foundation

/// Wire contract shared verbatim with LoopFollow. No credentials or delivery implementation.
struct SmartMealConfiguration: Codable, Equatable, Sendable {
    let percentage: Decimal
    let maxIOB: Decimal
    let maxCOB: Decimal
    let maxBolus: Decimal
    let maxCarbs: Decimal
    let maxFat: Decimal
    let maxProtein: Decimal
    let bolusIncrement: Decimal

    var valid: Bool {
        [percentage, maxIOB, maxCOB, maxBolus, maxCarbs, maxFat, maxProtein, bolusIncrement]
            .allSatisfy { NSDecimalNumber(decimal: $0).doubleValue.isFinite && $0 >= 0 }
            && percentage >= 5 && percentage <= 150 && maxCOB <= 32767 && maxBolus <= 30
            && maxCarbs <= 1000 && maxFat <= 1000 && maxProtein <= 1000 && bolusIncrement == Decimal(string: "0.05")!
    }

    var identifier: String { (try? SmartMealWire.digest(self)) ?? "" }
}

struct SmartMealRequest: Codable, Equatable, Sendable {
    let id: UUID
    let confirmedAt: TimeInterval
    let calculationAt: TimeInterval
    let configurationID: String
    let immediateCarbs: Int
    let delayedCarbs: Int
    let delaySeconds: Int
    let fullRecommendation: Decimal
    let upfrontPercent: Decimal
    let bolusAmount: Decimal
    let includeFatProtein: Bool
    let protein: Int
    let fat: Int
    var lowPredictionAcknowledged: Bool? = nil

    var totalCarbs: Int { immediateCarbs + delayedCarbs }
    var digest: String { (try? SmartMealWire.digest(self)) ?? "" }
    var nowEntryID: UUID { SmartMealWire.entryID(id, suffix: "now") }
    var laterEntryID: UUID { SmartMealWire.entryID(id, suffix: "later") }
    var delayedAt: TimeInterval? { delayedCarbs > 0 ? confirmedAt + Double(delaySeconds) : nil }

    func validate(configuration: SmartMealConfiguration, now: Date) throws {
        let age = now.timeIntervalSince1970 - confirmedAt
        let calculationAge = now.timeIntervalSince1970 - calculationAt
        guard configuration.valid, configurationID == configuration.identifier,
              confirmedAt.isFinite, calculationAt.isFinite, (0 ... 120).contains(age),
              (0 ... 600).contains(calculationAge), calculationAt <= confirmedAt,
              (0 ... 1000).contains(immediateCarbs), (0 ... 1000).contains(delayedCarbs),
              (1 ... 1000).contains(totalCarbs), Decimal(totalCarbs) <= configuration.maxCarbs,
              delayedCarbs == 0 ? delaySeconds == 0 : (60 ... 86400).contains(delaySeconds),
              (0 ... 1000).contains(protein), (0 ... 1000).contains(fat),
              includeFatProtein || (protein == 0 && fat == 0),
              Decimal(protein) <= configuration.maxProtein, Decimal(fat) <= configuration.maxFat,
              [fullRecommendation, upfrontPercent, bolusAmount].allSatisfy({ NSDecimalNumber(decimal: $0).doubleValue.isFinite }),
              fullRecommendation >= 0, fullRecommendation <= configuration.maxBolus,
              upfrontPercent >= 0, upfrontPercent <= 100,
              bolusAmount >= 0, bolusAmount <= configuration.maxBolus,
              SmartMealWire.roundDown(bolusAmount) == bolusAmount
        else {
            throw SmartMealError.invalidRequest
        }
    }
}

enum SmartMealPhase: String, Codable, Sendable {
    case claimed
    case carbsStored
    case bolusRequested
    case accepted
    case rejected
    case uncertain
    case reconciled
    var needsChecking: Bool { [.claimed, .carbsStored, .bolusRequested, .uncertain].contains(self) }
}

struct SmartMealReceipt: Codable, Equatable, Sendable {
    let request: SmartMealRequest
    var phase: SmartMealPhase
    var updatedAt: TimeInterval
    var message: String
}

struct SmartMealReceiverStatus: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let generatedAt: TimeInterval
    let calculationAt: TimeInterval
    let bundleIdentifier: String
    let enabled: Bool
    let configuration: SmartMealConfiguration
    let receipts: [SmartMealReceipt]
    var allowsLowPredictionReview: Bool? = nil

    func isCurrent(now: Date, calculationDate: Date?, bundleID: String) -> Bool {
        guard let calculationDate else { return false }
        return protocolVersion == 1 && enabled && configuration.valid && bundleIdentifier == bundleID
            && (0 ... 600).contains(now.timeIntervalSince1970 - generatedAt)
            && abs(calculationDate.timeIntervalSince1970 - calculationAt) < 1
            && (0 ... 600).contains(now.timeIntervalSince1970 - calculationAt)
    }
}

/// Matches the native calculator's 54 mg/dL selected-prediction cutoff.
/// The guard forecast is warning context, not a second calculator cutoff.
enum SmartMealForecastPolicy {
    static func requiresReview(minimum: Decimal, guardMinimum: Decimal) -> Bool {
        minimum < 70 || guardMinimum < 70
    }

    static func permits(glucose: Decimal, minimum: Decimal, guardMinimum: Decimal, bolus: Decimal, acknowledged: Bool) -> Bool {
        guard [glucose, minimum, guardMinimum, bolus].allSatisfy({ NSDecimalNumber(decimal: $0).doubleValue.isFinite }),
              glucose > 0, bolus >= 0 else { return false }
        if bolus == 0 { return true }
        guard glucose >= 70, minimum >= 54 else { return false }
        return !requiresReview(minimum: minimum, guardMinimum: guardMinimum) || acknowledged
    }
}

enum SmartMealError: LocalizedError {
    case invalidRequest
    case reusedIdentifier
    case receiverBusy
    case ledgerUnavailable
    case contextChanged
    case storageConflict
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Smart meal rejected: invalid, expired or changed settings/meal values."
        case .reusedIdentifier: return "Smart meal rejected: transaction ID was reused with different values."
        case .receiverBusy: return "A previous smart meal needs checking in Trio before another transaction."
        case .ledgerUnavailable: return "Smart meal held: replay-protection storage is unavailable."
        case .contextChanged: return "Smart meal held: Trio's calculation changed. Review again."
        case .storageConflict: return "Smart meal held: carb-entry identifiers conflict. Check treatments."
        }
    }
}

enum SmartMealWire {
    static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    static func entryID(_ transaction: UUID, suffix: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data((transaction.uuidString + ":" + suffix).utf8)).prefix(16))
        return UUID(uuid: (
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
            bytes[8],
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15]
        ))
    }

    static func roundDown(_ value: Decimal) -> Decimal {
        var steps = value * 20
        var result = Decimal()
        NSDecimalRound(&result, &steps, 0, .down)
        return result / 20
    }
}
