import CoreData
import Foundation

extension TrioRemoteControl {
    func smartMealConfiguration() async -> SmartMealConfiguration {
        let aps = await TrioApp.resolver.resolve(APSManager.self)
        let pump = aps?.pumpManager
        let isDash = pump?.pluginIdentifier == "Omni" && (pump?.rawState["podType"] as? NSNumber)?.intValue == 4
        return SmartMealConfiguration(
            percentage: settings.settings.overrideFactor * 100,
            maxIOB: settings.preferences.maxIOB,
            maxCOB: settings.preferences.maxCOB,
            maxBolus: settings.pumpSettings.maxBolus,
            maxCarbs: settings.settings.maxCarbs,
            maxFat: settings.settings.maxFat,
            maxProtein: settings.settings.maxProtein,
            bolusIncrement: isDash ? settings.preferences.bolusIncrement : 0
        )
    }

    func smartMealStatus(calculationDate: Date?) async -> SmartMealReceiverStatus? {
        guard let calculationDate, let receiver = SmartMealReceiver.shared else { return nil }
        return SmartMealReceiverStatus(
            protocolVersion: 1,
            generatedAt: Date().timeIntervalSince1970,
            calculationAt: calculationDate.timeIntervalSince1970,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            enabled: UserDefaults.standard.bool(forKey: "isTrioRemoteControlEnabled"),
            configuration: await smartMealConfiguration(),
            receipts: await receiver.recent()
        )
    }

    func handleSmartMealCommand(_ payload: CommandPayload) async throws {
        guard let request = payload.smartMeal, payload.bolusAmount == nil, payload.carbs == nil,
              payload.protein == nil, payload.fat == nil, payload.scheduledTime == nil,
              abs(payload.timestamp - request.confirmedAt) < 1,
              let receiver = SmartMealReceiver.shared
        else {
            await logError(SmartMealError.invalidRequest.localizedDescription, payload: payload)
            return
        }
        do {
            let receipt = try await receiver.execute(request, now: Date(), validate: {
                try request.validate(configuration: await self.smartMealConfiguration(), now: Date())
                try await self.validateSmartMealContext(request)
                if request.bolusAmount > 0 {
                    guard try await self.bolusSafetyValidator
                        .fetchTotalRecentBolusAmount(since: Date(timeIntervalSince1970: request.calculationAt)) == 0
                    else {
                        throw SmartMealError.contextChanged
                    }
                    guard case .allowed = try await self.bolusSafetyValidator.validate(
                        bolusAmount: request.bolusAmount, lookbackStart: Date(timeIntervalSince1970: request.calculationAt)
                    ) else { throw SmartMealError.contextChanged }
                }
            }, store: {
                // Recheck after async safety calculation, immediately before committing the batch.
                try request.validate(configuration: await self.smartMealConfiguration(), now: Date())
                try await self.carbsStorage.storeSmartMeal(request)
            }, bolus: {
                // Storage/safety awaits must not permit a changed cycle or setting
                // to authorize an old dose. A hold here leaves an explicit partial result.
                try request.validate(configuration: await self.smartMealConfiguration(), now: Date())
                try await self.validateSmartMealContext(request)
                guard let aps = await TrioApp.resolver.resolve(APSManager.self) else { throw SmartMealError.contextChanged }
                guard try await self.bolusSafetyValidator
                    .fetchTotalRecentBolusAmount(since: Date(timeIntervalSince1970: request.calculationAt)) == 0
                else {
                    throw SmartMealError.contextChanged
                }
                guard case .allowed = try await self.bolusSafetyValidator.validate(
                    bolusAmount: request.bolusAmount, lookbackStart: Date(timeIntervalSince1970: request.calculationAt)
                ) else { throw SmartMealError.contextChanged }
                return await withCheckedContinuation { continuation in
                    Task {
                        await aps
                            .enactBolus(
                                amount: NSDecimalNumber(decimal: request.bolusAmount).doubleValue,
                                isSMB: false
                            ) { success, _ in
                                continuation.resume(returning: success)
                            }
                    }
                }
            })
            nightscoutManager.requestSmartMealStatusUpload()
            let message = "Smart meal \(request.id.uuidString): \(receipt.message)"
            if receipt.phase == .accepted {
                await logSuccess(message, payload: payload, customNotificationMessage: message)
            } else {
                await logError(message, payload: payload)
            }
        } catch { await logError(error.localizedDescription, payload: payload) }
    }

    private func validateSmartMealContext(_ request: SmartMealRequest) async throws {
        guard let aps = await TrioApp.resolver.resolve(APSManager.self),
              let calculator = await TrioApp.resolver.resolve(BolusCalculationManager.self)
        else { throw SmartMealError.contextChanged }
        let context = CoreDataStack.shared.newTaskContext()
        let values: (Date, Decimal, Decimal, Date, Int) = try await context.perform {
            let fetch = OrefDetermination.fetchRequest()
            fetch.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: false)]
            fetch.fetchLimit = 1
            guard let latest = try context.fetch(fetch).first, let date = latest.deliverAt,
                  let prediction = latest.minPredBGFromReason,
                  let reason = latest.reason,
                  let range = reason.range(of: "minGuardBG:?\\s+(-?[0-9]+(?:\\.[0-9]+)?)", options: .regularExpression),
                  let guardBG = Decimal(
                      string: reason[range].split(whereSeparator: { $0 == " " || $0 == ":" }).last
                          .map(String.init) ?? ""
                  )
            else {
                throw SmartMealError.contextChanged
            }
            let glucose = GlucoseStored.fetchRequest()
            glucose.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            glucose.fetchLimit = 1
            guard let bg = try context.fetch(glucose).first, let bgDate = bg.date else { throw SmartMealError.contextChanged }
            return (date, prediction, guardBG, bgDate, Int(bg.glucose))
        }
        let now = Date()
        guard abs(values.0.timeIntervalSince1970 - request.calculationAt) < 1,
              (0 ... 600).contains(now.timeIntervalSince(values.0)),
              (0 ... 600).contains(now.timeIntervalSince(values.3)),
              values.1 >= 70, values.2 >= 70, values.4 >= 70 else { throw SmartMealError.contextChanged }
        let result = await calculator.handleBolusCalculation(
            carbs: Decimal(request.totalCarbs),
            useFattyMealCorrection: false,
            useSuperBolus: false,
            lastLoopDate: aps.lastLoopDate,
            minPredBG: values.1,
            simulatedCOB: nil,
            isBackdated: false
        )
        guard abs(result.insulinCalculated - request.fullRecommendation) < Decimal(string: "0.00001")! else {
            throw SmartMealError.contextChanged
        }
    }
}
