import Foundation
import SwiftData

/// On iOS, rollback can clear pending state while existing model instances
/// still expose their edited values until a fetch refreshes them. Refresh only
/// the persisted IDs involved in this transaction, never a stock's history.
/// The first read after a rejected save can still return pre-rollback values
/// on the supported iOS runtime. Read bounded identifiers first, then reload
/// their persisted models with pending-change merging disabled. Keep this
/// workaround covered by actual failed-save and original-instance assertions.
@MainActor
enum ModelRollback {
    static func restore(in context: ModelContext) throws {
        let inserted = Set(context.insertedModelsArray.map(ObjectIdentifier.init))
        let changed = (context.changedModelsArray + context.deletedModelsArray).filter {
            !inserted.contains(ObjectIdentifier($0)) && $0.persistentModelID.storeIdentifier != nil
        }
        let allPending = changed + context.insertedModelsArray
        var owners = allPending.compactMap { ($0 as? Trade)?.stock }
            + allPending.compactMap { $0 as? Stock }
        defer {
            var seen = Set<ObjectIdentifier>()
            for stock in owners where seen.insert(ObjectIdentifier(stock)).inserted {
                stock.invalidateCalculationWindow()
            }
        }
        let tradeIDs = Array(Set(changed.compactMap { ($0 as? Trade)?.persistentModelID }))
        let stockIDs = Array(Set(changed.compactMap { ($0 as? Stock)?.persistentModelID }))
        let marketIDs = Array(Set(changed.compactMap { ($0 as? MarketDay)?.persistentModelID }))
        context.rollback()
        // Do not use the first identifier result to narrow the second query:
        // every persisted ID involved in the transaction must be refreshed.
        if !tradeIDs.isEmpty {
            var descriptor = FetchDescriptor<Trade>(predicate: #Predicate { tradeIDs.contains($0.persistentModelID) })
            descriptor.includePendingChanges = false
            _ = try context.fetchIdentifiers(descriptor)
            let rows = try context.fetch(descriptor)
            owners += rows.map(\.stock)
        }
        if !stockIDs.isEmpty {
            var descriptor = FetchDescriptor<Stock>(predicate: #Predicate { stockIDs.contains($0.persistentModelID) })
            descriptor.includePendingChanges = false
            _ = try context.fetchIdentifiers(descriptor)
            owners += try context.fetch(descriptor)
        }
        if !marketIDs.isEmpty {
            var descriptor = FetchDescriptor<MarketDay>(predicate: #Predicate { marketIDs.contains($0.persistentModelID) })
            descriptor.includePendingChanges = false
            _ = try context.fetchIdentifiers(descriptor)
            _ = try context.fetch(descriptor)
        }
    }
}
