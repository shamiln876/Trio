// swiftformat:disable redundantParens
import CoreData
import Foundation
import Testing
@testable import Trio

@Suite struct SmartMealCarbBatchTests {
    private func close(_ container: NSPersistentContainer) {
        container.persistentStoreCoordinator.performAndWait {
            for store in container.persistentStoreCoordinator.persistentStores {
                try? container.persistentStoreCoordinator.remove(store)
            }
        }
    }

    private func container(file: URL, carbLimit: Double? = nil) throws -> NSPersistentContainer {
        let entity = NSEntityDescription()
        entity.name = "CarbEntryStored"
        entity.managedObjectClassName = "NSManagedObject"
        let fields: [(String, NSAttributeType)] = [
            ("id", .UUIDAttributeType),
            ("date", .dateAttributeType),
            ("carbs", .doubleAttributeType),
            ("fat", .doubleAttributeType),
            ("protein", .doubleAttributeType),
            ("note", .stringAttributeType),
            ("isFPU", .booleanAttributeType),
            ("fpuID", .UUIDAttributeType),
            ("isUploadedToNS", .booleanAttributeType),
            ("isUploadedToHealth", .booleanAttributeType),
            ("isUploadedToTidepool", .booleanAttributeType)
        ]
        entity.properties = fields.map { name, type in let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = true
            return a }
        if let carbLimit, let carbs = entity.attributesByName["carbs"] {
            carbs.setValidationPredicates(
                [NSPredicate(format: "SELF <= %@", NSNumber(value: carbLimit))],
                withValidationWarnings: ["Injected validation limit"]
            )
        }
        let model = NSManagedObjectModel()
        model.entities = [entity]
        let container = NSPersistentContainer(name: "SmartMealTest", managedObjectModel: model)
        let store = NSPersistentStoreDescription(url: file)
        store.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [store]
        var failure: Error?
        container.loadPersistentStores { _, error in failure = error }
        if let failure { throw failure }
        return container
    }

    @Test func bothRowsPersistAndOnlyDueCarbsEnterCurrentQuery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try container(file: root.appendingPathComponent("store.sqlite"))
        defer { close(container) }
        let context = container.newBackgroundContext()
        let now = Date()
        let id = UUID()
        let rows = [
            SmartMealCarbRow(
                id: SmartMealWire.entryID(id, suffix: "now"),
                date: now,
                carbs: 60,
                fat: 0,
                protein: 0,
                note: "now",
                isFPU: false,
                fpuID: nil
            ),
            SmartMealCarbRow(
                id: SmartMealWire.entryID(id, suffix: "later"),
                date: now.addingTimeInterval(1800),
                carbs: 20,
                fat: 0,
                protein: 0,
                note: "later",
                isFPU: false,
                fpuID: nil
            )
        ]
        try await SmartMealCarbBatch.commit(rows, in: context)
        let fresh = container.newBackgroundContext()
        try await fresh.perform {
            let all = NSFetchRequest<NSManagedObject>(entityName: "CarbEntryStored")
            let count = try fresh.count(for: all)
            #expect(count == 2)
            all.predicate = NSPredicate(format: "date <= %@", now as NSDate)
            let current = try fresh.fetch(all).reduce(0.0) { $0 + ($1.value(forKey: "carbs") as! Double) }
            #expect(current == 60)
            all.predicate = NSPredicate(format: "date <= %@", now.addingTimeInterval(1800) as NSDate)
            let total = try fresh.fetch(all).reduce(0.0) { $0 + ($1.value(forKey: "carbs") as! Double) }
            #expect(total == 80)
        }
        await #expect(throws: (any Error).self) { try await SmartMealCarbBatch.commit(rows, in: context) }
        try await fresh.perform {
            let count = try fresh.count(for: NSFetchRequest<NSManagedObject>(entityName: "CarbEntryStored"))
            #expect(count == 2)
        }
    }

    @Test func saveValidationFailureRollsBackBothInsertedRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try container(file: root.appendingPathComponent("store.sqlite"), carbLimit: 80)
        defer { close(container) }
        let context = container.newBackgroundContext()
        let rows = [
            SmartMealCarbRow(id: UUID(), date: Date(), carbs: 60, fat: 0, protein: 0, note: nil, isFPU: false, fpuID: nil),
            SmartMealCarbRow(
                id: UUID(),
                date: Date().addingTimeInterval(1800),
                carbs: 100,
                fat: 0,
                protein: 0,
                note: nil,
                isFPU: false,
                fpuID: nil
            )
        ]
        await #expect(throws: (any Error).self) { try await SmartMealCarbBatch.commit(rows, in: context) }
        try await context.perform {
            let count = try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "CarbEntryStored"))
            #expect(count == 0)
        }
    }

    @Test func invalidLaterRowLeavesNoPartialMeal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try container(file: root.appendingPathComponent("store.sqlite"))
        defer { close(container) }
        let context = container.newBackgroundContext()
        let rows = [
            SmartMealCarbRow(id: UUID(), date: Date(), carbs: 60, fat: 0, protein: 0, note: nil, isFPU: false, fpuID: nil),
            SmartMealCarbRow(id: UUID(), date: Date(), carbs: .nan, fat: 0, protein: 0, note: nil, isFPU: false, fpuID: nil)
        ]
        await #expect(throws: (any Error).self) { try await SmartMealCarbBatch.commit(rows, in: context) }
        try await context.perform {
            let count = try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "CarbEntryStored"))
            #expect(count == 0)
        }
    }
}
