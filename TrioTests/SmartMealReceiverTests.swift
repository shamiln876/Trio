// swiftformat:disable redundantParens
import Foundation
import Testing
@testable import Trio

@Suite struct SmartMealReceiverTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var configuration: SmartMealConfiguration {
        .init(
            percentage: 90,
            maxIOB: 10,
            maxCOB: 125,
            maxBolus: 9,
            maxCarbs: 150,
            maxFat: 100,
            maxProtein: 100,
            bolusIncrement: Decimal(string: "0.05")!
        )
    }

    private func request(
        bolus: Decimal = 4.35,
        later: Int = 20,
        delay: Int = 1800,
        id: UUID = UUID(),
        age: Double = 0,
        fat: Int = 0,
        include: Bool = false
    ) -> SmartMealRequest {
        .init(
            id: id,
            confirmedAt: now.timeIntervalSince1970 - age,
            calculationAt: now.addingTimeInterval(-60).timeIntervalSince1970,
            configurationID: configuration.identifier,
            immediateCarbs: 60,
            delayedCarbs: later,
            delaySeconds: delay,
            fullRecommendation: 5.8,
            upfrontPercent: 75,
            bolusAmount: bolus,
            includeFatProtein: include,
            protein: 0,
            fat: fat
        )
    }

    private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("ledger.json") }

    private actor Counts {
        var stores = 0
        var boluses = 0
        func store() { stores += 1 }
        func bolus() -> Bool { boluses += 1
            return true }
        func values() -> [Int] { [stores, boluses] }
    }

    private actor Gate {
        private var open = false
        private var continuation: CheckedContinuation<Void, Never>?
        var entered = false
        func pause() async {
            entered = true
            if open { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { open = true
            continuation?.resume()
            continuation = nil }
    }

    @Test func lowForecastAcknowledgementIsRequiredBeforeAnyEffectsAndReplayStaysIdempotent() async throws {
        for acknowledged in [false, true] {
            let location = file()
            defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
            let receiver = try SmartMealReceiver(file: location)
            let counts = Counts()
            var meal = request(bolus: 0.65)
            meal.lowPredictionAcknowledged = acknowledged ? true : nil
            let submitted = meal
            let receipt = try await receiver.execute(submitted, now: now, validate: {
                try submitted.validate(configuration: configuration, now: now)
                guard SmartMealForecastPolicy.permits(glucose: 117, minimum: 65, guardMinimum: 29,
                                                     bolus: submitted.bolusAmount, acknowledged: submitted.lowPredictionAcknowledged == true)
                else { throw SmartMealError.contextChanged }
            }, store: { await counts.store() }, bolus: { await counts.bolus() })
            #expect(receipt.phase == (acknowledged ? .accepted : .rejected))
            #expect(await counts.values() == (acknowledged ? [1, 1] : [0, 0]))
            _ = try await receiver.execute(submitted, now: now, validate: {}, store: { await counts.store() }, bolus: { await counts.bolus() })
            #expect(await counts.values() == (acknowledged ? [1, 1] : [0, 0]))
        }
    }

    @Test func optionalForecastFieldsKeepLegacyWireCompatibleAndBindAcknowledgementToRequest() throws {
        let original = request()
        let oldWire = try JSONEncoder().encode(original)
        #expect(!String(decoding: oldWire, as: UTF8.self).contains("lowPredictionAcknowledged"))
        #expect(try JSONDecoder().decode(SmartMealRequest.self, from: oldWire).lowPredictionAcknowledged == nil)
        var reviewed = original
        reviewed.lowPredictionAcknowledged = true
        #expect(reviewed.digest != original.digest)
        #expect(try JSONDecoder().decode(SmartMealRequest.self, from: JSONEncoder().encode(reviewed)) == reviewed)
        #expect(!SmartMealForecastPolicy.permits(glucose: 117, minimum: 53, guardMinimum: 29, bolus: reviewed.bolusAmount, acknowledged: true))
    }

    @Test func concurrentDuplicateCannotRepeatEffectsOrStartAnotherMeal() async throws {
        let location = file()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let receiver = try SmartMealReceiver(file: location)
        let gate = Gate()
        let counts = Counts()
        let meal = request()
        let task = Task { try await receiver.execute(
            meal,
            now: now,
            validate: { await gate.pause() },
            store: { await counts.store() },
            bolus: { await counts.bolus() }
        ) }
        var entered = false
        for _ in 0 ..< 500 {
            if await gate.entered { entered = true
                break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if entered {
            let duplicate = try await receiver.execute(
                meal,
                now: now,
                validate: {},
                store: { await counts.store() },
                bolus: { await counts.bolus() }
            )
            #expect(duplicate.phase == .claimed)
            await #expect(throws: (any Error).self) {
                _ = try await receiver.execute(request(), now: now, validate: {}, store: {}, bolus: { true }) }
            #expect(await counts.values() == [0, 0])
        }
        await gate.release()
        let receipt = try await task.value
        #expect(entered && receipt.phase == .accepted)
        #expect(await counts.values() == [1, 1])
    }

    @Test func oneTransactionBothEntriesReplayAndRestart() async throws {
        let location = file()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let receiver = try SmartMealReceiver(file: location)
        let counts = Counts()
        let meal = request()
        let first = try await receiver.execute(
            meal,
            now: now,
            validate: { try meal.validate(configuration: configuration, now: now) },
            store: { await counts.store() },
            bolus: { await counts.bolus() }
        )
        #expect(first.phase == .accepted)
        #expect(first.request.totalCarbs == 80)
        #expect(first.request.delayedAt == now.addingTimeInterval(1800).timeIntervalSince1970)
        #expect(meal.nowEntryID != meal.laterEntryID)
        _ = try await receiver.execute(
            meal,
            now: now,
            validate: { throw SmartMealError.invalidRequest },
            store: { await counts.store() },
            bolus: { await counts.bolus() }
        )
        let reloaded = try SmartMealReceiver(file: location)
        _ = try await reloaded.execute(
            meal,
            now: now,
            validate: {},
            store: { await counts.store() },
            bolus: { await counts.bolus() }
        )
        #expect(await counts.values() == [1, 1])
    }

    @Test func validationRejectionHasNoEffectsAndDoesNotRetry() async throws {
        let location = file()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let receiver = try SmartMealReceiver(file: location)
        let counts = Counts()
        let meal = request()
        let receipt = try await receiver.execute(
            meal,
            now: now,
            validate: { throw SmartMealError.contextChanged },
            store: { await counts.store() },
            bolus: { await counts.bolus() }
        )
        #expect(receipt.phase == .rejected)
        _ = try await receiver.execute(
            meal,
            now: now,
            validate: {},
            store: { await counts.store() },
            bolus: { await counts.bolus() }
        )
        #expect(await counts.values() == [0, 0])
    }

    @Test func failedCarbCommitNeverCallsBolusAndBlocksNewTransaction() async throws {
        let location = file()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let receiver = try SmartMealReceiver(file: location)
        let counts = Counts()
        let meal = request()
        let receipt = try await receiver.execute(
            meal,
            now: now,
            validate: {},
            store: { throw SmartMealError.storageConflict },
            bolus: { await counts.bolus() }
        )
        #expect(receipt.phase == .uncertain)
        #expect(await counts.values() == [0, 0])
        await #expect(throws: (any Error).self) {
            _ = try await receiver.execute(request(), now: now, validate: {}, store: {}, bolus: { true }) }
        try await receiver.reconcileUncertain()
        let next = try await receiver.execute(
            request(bolus: 0),
            now: now,
            validate: {},
            store: { await counts.store() },
            bolus: { await counts.bolus() }
        )
        #expect(next.phase == .accepted)
        #expect(await counts.values() == [1, 0])
    }

    @Test func changedContextAfterCarbsNeverCallsPumpOrRetries() async throws {
        let location = file()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let receiver = try SmartMealReceiver(file: location)
        let counts = Counts()
        let meal = request()
        let receipt = try await receiver.execute(meal, now: now, validate: {}, store: {
            await counts.store()
        }, bolus: { throw SmartMealError.contextChanged })
        #expect(receipt.phase == .uncertain)
        #expect(await counts.values() == [1, 0])
        let restarted = try SmartMealReceiver(file: location)
        _ = try await restarted.execute(meal, now: now, validate: {}, store: {
            await counts.store()
        }, bolus: { await counts.bolus() })
        #expect(await counts.values() == [1, 0])
    }

    @Test func uncertainBolusNeverRetriesAcrossRestart() async throws {
        let location = file()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let receiver = try SmartMealReceiver(file: location)
        let counts = Counts()
        let meal = request()
        let receipt = try await receiver.execute(
            meal,
            now: now,
            validate: {},
            store: { await counts.store() },
            bolus: { _ = await counts.bolus()
                return false }
        )
        #expect(receipt.phase == .uncertain)
        let reloaded = try SmartMealReceiver(file: location)
        _ = try await reloaded.execute(
            meal,
            now: now,
            validate: {},
            store: { await counts.store() },
            bolus: { await counts.bolus() }
        )
        #expect(await counts.values() == [1, 1])
    }

    @Test func interruptedClaimRequiresExplicitReconciliation() async throws {
        let location = file()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        let meal = request()
        let interrupted = SmartMealReceipt(
            request: meal,
            phase: .bolusRequested,
            updatedAt: now.timeIntervalSince1970,
            message: "interrupted"
        )
        try JSONEncoder().encode([interrupted]).write(to: location)
        let receiver = try SmartMealReceiver(file: location)
        #expect(await receiver.recent().first?.phase == .uncertain)
        let counts = Counts()
        _ = try await receiver.execute(
            meal,
            now: now,
            validate: {},
            store: { await counts.store() },
            bolus: { await counts.bolus() }
        )
        #expect(await counts.values() == [0, 0])
    }

    @Test func missingOrCorruptLedgerCannotAuthorizeEffects() async throws {
        let root = file()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // file is a directory
        #expect(throws: (any Error).self) { _ = try SmartMealReceiver(file: root) }
        let impossible = root.appendingPathComponent("a/b.json")
        let receiver = try SmartMealReceiver(file: impossible)
        try FileManager.default.removeItem(at: root)
        try Data("not a directory".utf8).write(to: root)
        let counts = Counts()
        await #expect(throws: (any Error).self) { _ = try await receiver.execute(
            request(),
            now: now,
            validate: {},
            store: { await counts.store() },
            bolus: { await counts.bolus() }
        ) }
        #expect(await counts.values() == [0, 0])
    }

    @Test func changedBodyUnderSameIDIsRejected() async throws {
        let location = file()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let receiver = try SmartMealReceiver(file: location)
        let id = UUID()
        _ = try await receiver.execute(request(id: id), now: now, validate: {}, store: {}, bolus: { true })
        await #expect(throws: (any Error).self) {
            _ = try await receiver.execute(request(bolus: 4, id: id), now: now, validate: {}, store: {}, bolus: { true }) }
    }

    @Test func staleSettingsDosingStepsAndUnselectedMacrosAreRejected() throws {
        try request().validate(configuration: configuration, now: now)
        #expect(throws: (any Error).self) { try request(age: 121).validate(configuration: configuration, now: now) }
        #expect(throws: (any Error).self) { try request(bolus: 4.36).validate(configuration: configuration, now: now) }
        #expect(throws: (any Error).self) { try request(later: 20, delay: 0).validate(configuration: configuration, now: now) }
        #expect(throws: (any Error).self) { try request(fat: 10).validate(configuration: configuration, now: now) }
        try request(fat: 10, include: true).validate(configuration: configuration, now: now)
        #expect(SmartMealWire.roundDown(Decimal(string: "5.8")! * 75 / 100) == Decimal(string: "4.35")!)
        #expect(configuration.identifier.count == 64)
    }

    @Test func receiptAndCapabilityRoundTripDoNotInventDelivery() throws {
        let meal = request()
        let receipt = SmartMealReceipt(
            request: meal,
            phase: .bolusRequested,
            updatedAt: now.timeIntervalSince1970,
            message: "Not confirmed"
        )
        let status = SmartMealReceiverStatus(
            protocolVersion: 1,
            generatedAt: now.timeIntervalSince1970,
            calculationAt: meal.calculationAt,
            bundleIdentifier: "test.trio",
            enabled: true,
            configuration: configuration,
            receipts: [receipt]
        )
        let decoded = try JSONDecoder().decode(SmartMealReceiverStatus.self, from: JSONEncoder().encode(status))
        #expect(decoded == status)
        #expect(
            decoded
                .isCurrent(now: now, calculationDate: Date(timeIntervalSince1970: meal.calculationAt), bundleID: "test.trio")
        )
        #expect(!decoded.isCurrent(now: now, calculationDate: now, bundleID: "test.trio"))
        #expect(
            !decoded
                .isCurrent(now: now, calculationDate: Date(timeIntervalSince1970: meal.calculationAt), bundleID: "different")
        )
        #expect(decoded.receipts.first?.phase.needsChecking == true)
    }
}
