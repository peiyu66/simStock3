import Foundation
import Observation
import SwiftData

/// Transient, per-stock input notification. Reading a date summary must not
/// materialize every retained Trade merely to subscribe to future corrections.
@Observable
final class TradeInputChanges {
    private(set) var revision = 0
    func changed() { revision &+= 1 }
}

// Static dispatch through PersistentModel preserves SwiftData's public setter
// implementation. Do not write backingData directly or call the concrete
// overload again (which would recurse).
private enum PersistentValueWriter {
    static func set<Model: PersistentModel, Value: Encodable>(
        _ model: Model, key: KeyPath<Model, Value>, value: Value
    ) {
        model.setValue(forKey: key, to: value)
    }

    static func setRelationship<Model: PersistentModel, Value: PersistentModel>(
        _ model: Model, key: KeyPath<Model, Value>, value: Value
    ) {
        model.setValue(forKey: key, to: value)
    }
}

extension Trade {
    /// @Model generated scalar accessors call setValue; stored-property didSet
    /// and a custom withMutation method are not called by those accessors.
    /// Keep this overload covered by real SwiftData setter/save/reopen tests.
    func setValue<Value: Encodable>(forKey key: KeyPath<Trade, Value>, to value: Value) {
        PersistentValueWriter.set(self, key: key, value: value)
        if key == \Trade.dateTime || key == \Trade.priceClose || key == \Trade.dataSource {
            // The normal initializer is not yet a usable persisted row.
            // Materialized rows have a context and an initialized relationship.
            if rawInputTrackingReady || modelContext != nil {
                stock.invalidateCalculationWindow()
                if let context = modelContext {
                    MainActor.assumeIsolated {
                        UpdateWorkLedger.shared(in: context).invalidateListingEvidence(for: stock)
                    }
                }
            }
        }
    }

    func setValue<Value: PersistentModel>(forKey key: KeyPath<Trade, Value>, to value: Value) {
        let previous = (rawInputTrackingReady || modelContext != nil) && key == \Trade.stock ? stock : nil
        PersistentValueWriter.setRelationship(self, key: key, value: value)
        if key == \Trade.stock {
            previous?.invalidateCalculationWindow()
            (value as? Stock)?.invalidateCalculationWindow()
            if let context = modelContext {
                MainActor.assumeIsolated {
                    let ledger = UpdateWorkLedger.shared(in: context)
                    if let previous { ledger.invalidateListingEvidence(for: previous) }
                    if let next = value as? Stock { ledger.invalidateListingEvidence(for: next) }
                }
            }
        }
    }
}
