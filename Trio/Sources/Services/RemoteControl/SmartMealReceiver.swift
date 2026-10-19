import Darwin
import Foundation

/// Durable claim-before-effects ledger. Replays never repeat storage or a bolus.
/// Interrupted/ambiguous attempts require explicit reconciliation; there is no automatic retry.
actor SmartMealReceiver {
    static let shared: SmartMealReceiver? = {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return try? SmartMealReceiver(file: root.appendingPathComponent("SmartMeal/transactions.json"))
    }()
    private let file: URL
    private var records: [SmartMealReceipt]
    private var active: UUID?

    init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            records = try JSONDecoder().decode([SmartMealReceipt].self, from: Data(contentsOf: file))
            guard records.count <= 5000,
                  Set(records.map(\.request.id)).count == records.count else { throw SmartMealError.ledgerUnavailable }
            for index in records.indices where records[index].phase.needsChecking {
                records[index].phase = .uncertain
                records[index]
                    .message =
                    "Trio restarted during an unfinished transaction. Check both carb entries and actual insulin; do not retry."
            }
            try Self.write(records, to: file)
        } else { records = [] }
    }

    private static func write(_ records: [SmartMealReceipt], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
            try JSONEncoder().encode(records)
                .write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try JSONEncoder().encode(records).write(to: file, options: .atomic)
        #endif
        // Flush the claim before allowing any treatment side effect.
        let handle = try FileHandle(forWritingTo: file)
        do { try handle.synchronize()
            try handle.close() } catch { try? handle.close()
            throw error }
        let directoryDescriptor = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY)
        guard directoryDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var location = file.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try location.setResourceValues(values)
    }

    private func save(_ receipt: SmartMealReceipt) throws {
        var next = records.filter { $0.request.id != receipt.request.id }
        next.append(receipt)
        try Self.write(next, to: file)
        records = next
    }

    func recent() -> [SmartMealReceipt] { Array(records.sorted { $0.updatedAt > $1.updatedAt }.prefix(8)) }

    /// Only invoked by an explicit on-device "I checked treatments" action.
    func reconcileUncertain() throws {
        guard active == nil else { throw SmartMealError.receiverBusy }
        var next = records
        for index in next.indices where next[index].phase.needsChecking {
            next[index].phase = .reconciled
            next[index].updatedAt = Date().timeIntervalSince1970
            next[index].message = "Caregiver acknowledged checking treatments; no command was retried."
        }
        try Self.write(next, to: file)
        records = next
    }

    func execute(
        _ request: SmartMealRequest,
        now: Date,
        validate: () async throws -> Void,
        store: () async throws -> Void,
        bolus: () async throws -> Bool
    ) async throws -> SmartMealReceipt {
        if let prior = records.first(where: { $0.request.id == request.id }) {
            guard prior.request == request else { throw SmartMealError.reusedIdentifier }
            return prior
        }
        guard active == nil, !records.contains(where: { $0.phase.needsChecking }) else { throw SmartMealError.receiverBusy }
        guard records.count < 5000 else { throw SmartMealError.ledgerUnavailable }
        var receipt = SmartMealReceipt(
            request: request,
            phase: .claimed,
            updatedAt: now.timeIntervalSince1970,
            message: "Checking transaction; nothing confirmed yet."
        )
        try save(receipt) // A durable ID must exist before any async side effect.
        active = request.id
        defer { active = nil }
        do {
            do { try await validate() }
            catch {
                receipt.phase = .rejected
                receipt.updatedAt = Date().timeIntervalSince1970
                receipt.message = error.localizedDescription + " No meal was stored or bolus requested."
                try save(receipt)
                return receipt
            }
            try await store() // Both dated carb entries saved in one Core Data transaction.
            receipt.phase = .carbsStored
            receipt.message = "Carb entries stored; no later insulin bolus is scheduled."
            receipt.updatedAt = Date().timeIntervalSince1970
            try save(receipt)
            if request.bolusAmount > 0 {
                receipt.phase = .bolusRequested
                receipt.message = "Carbs stored. Upfront bolus requested; outcome not yet confirmed."
                try save(receipt) // Never retry after this boundary, even if the app terminates.
                guard try await bolus() else { throw SmartMealError.contextChanged }
            }
            receipt.phase = .accepted
            receipt.updatedAt = Date().timeIntervalSince1970
            receipt.message = request.bolusAmount > 0
                ? "Carb entries stored; upfront bolus initiation reported successful. Verify actual delivery in treatments."
                : "Carb entries stored. No insulin bolus requested."
            try save(receipt)
            return receipt
        } catch {
            receipt.phase = .uncertain
            receipt.updatedAt = Date().timeIntervalSince1970
            receipt.message = "Transaction outcome needs checking: " + error.localizedDescription + " No automatic retry."
            // If this write also fails, the earlier durable claim still prevents replay.
            try? save(receipt)
            return receipt
        }
    }
}
