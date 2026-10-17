import CoreData
import Foundation

struct SmartMealCarbRow: Sendable {
    let id: UUID
    let date: Date
    let carbs: Double
    let fat: Double
    let protein: Double
    let note: String?
    let isFPU: Bool
    let fpuID: UUID?
}

enum SmartMealCarbBatch {
    /// This helper is shared by the production adapter and SQLite tests.
    /// A failed validation/save rolls back the entire batch, never just the later row.
    static func commit(_ rows: [SmartMealCarbRow], in context: NSManagedObjectContext) async throws {
        try await context.perform {
            guard !context.hasChanges else { throw SmartMealError.storageConflict }
            do {
                guard (1 ... 8).contains(rows.count), Set(rows.map(\.id)).count == rows.count,
                      rows.allSatisfy({ row in
                          row.date.timeIntervalSince1970.isFinite && [row.carbs, row.fat, row.protein]
                              .allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1000 }
                      }) else { throw SmartMealError.invalidRequest }
                let fetch = NSFetchRequest<NSManagedObject>(entityName: "CarbEntryStored")
                fetch.predicate = NSPredicate(format: "id IN %@", rows.map(\.id))
                guard try context.count(for: fetch) == 0 else { throw SmartMealError.storageConflict }
                for row in rows {
                    let item = NSEntityDescription.insertNewObject(forEntityName: "CarbEntryStored", into: context)
                    item.setValue(row.id, forKey: "id")
                    item.setValue(row.date, forKey: "date")
                    item.setValue(row.carbs, forKey: "carbs")
                    item.setValue(row.fat, forKey: "fat")
                    item.setValue(row.protein, forKey: "protein")
                    item.setValue(row.note, forKey: "note")
                    item.setValue(row.isFPU, forKey: "isFPU")
                    item.setValue(row.fpuID, forKey: "fpuID")
                    item.setValue(false, forKey: "isUploadedToNS")
                    item.setValue(false, forKey: "isUploadedToHealth")
                    item.setValue(false, forKey: "isUploadedToTidepool")
                }
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
    }
}
