import Foundation
import SwiftData

/// Completion evidence, not another source of T/S truth. The store's persistent
/// journal invalidates affected evidence before it may be reused. No Trade scan
/// is needed to establish that nothing has changed, including after reopening.
@MainActor
final class UpdateWorkLedger {
    private static let instances = NSMapTable<ModelContext, UpdateWorkLedger>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    static func shared(in context: ModelContext) -> UpdateWorkLedger {
        if let value = instances.object(forKey: context) { return value }
        let value = UpdateWorkLedger(context: context)
        instances.setObject(value, forKey: context)
        return value
    }

    struct StockProof: Codable {
        var sourceKey: Data
        var latestOfficial: Date?
        var completeThrough: Date?
        var window: CalculationWindow
        var workKey: Data?
    }
    struct MarketProof: Codable {
        var floor: Date
        var cutoff: Date
        var first: Date
        var last: Date
    }
    struct ListingProof: Codable {
        var listing: Date
        var hasEarlierOfficialPrice: Bool
    }
    private struct Record: Codable {
        var format = 1
        var rules = "\(Technical.dataRuleVersion)/M\(MarketDataStore.technicalStateVersion)"
        var fileIdentity: String
        var token: DefaultHistoryToken?
        var stocks: [String: StockProof] = [:]
        var market: MarketProof?
        // Optional so the existing journal sidecar remains readable. This is
        // source evidence, not a persisted calculation-window summary.
        var listings: [String: ListingProof]?
        var p10Keys: [String: Data] = [:]
        var generations: [String: Int] = [:]
        var marketGeneration = 0
    }
    private weak var context: ModelContext?
    private let file: URL?
    private var lastPersistedData: Data?
    private var needsTokenValidation = false
    private var record: Record
    private(set) var journalReads = 0
    private(set) var changedTransactions = 0
    private(set) var stockInvalidations: Set<String> = []
    private(set) var marketInvalidated = false
    private var allStocksInvalidated = false
    private(set) var isReliable = false
    private(set) var listingEvidenceReads = 0

    private func encoded<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)) ?? Data()
    }
    func takeInvalidations() -> (stocks: Set<String>, market: Bool, allStocks: Bool) {
        defer { stockInvalidations.removeAll(); marketInvalidated = false; allStocksInvalidated = false }
        return (stockInvalidations, marketInvalidated, allStocksInvalidated)
    }

    init(context: ModelContext) {
        self.context = context
        let config = context.container.configurations.first
        file = config.flatMap { $0.isStoredInMemoryOnly ? nil : $0.url.appendingPathExtension("update-check.json") }
        let identity = config.map { configuration in
            let attributes = try? FileManager.default.attributesOfItem(atPath: configuration.url.path)
            return "\(configuration.url.standardizedFileURL.path)|\(attributes?[.systemFileNumber] ?? "memory")|\(attributes?[.creationDate] ?? "memory")"
        } ?? "memory"
        let empty = Record(fileIdentity: identity)
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(Record.self, from: data),
           saved.format == empty.format, saved.rules == empty.rules, saved.fileIdentity == identity {
            record = saved
            lastPersistedData = data
            needsTokenValidation = true
        } else { record = empty }
    }

    /// Consume committed events only. Unsaved model edits cannot acquire a
    /// completion certificate; they are classified conservatively by owner.
    func refresh() {
        guard let context else { return }
        do {
            if needsTokenValidation, let saved = record.token {
                // A restore can retain the path/inode while rolling the store
                // back. Validate its journal identity once on reopening too.
                var latest = HistoryDescriptor<DefaultHistoryTransaction>(sortBy: [SortDescriptor(\.transactionIdentifier, order: .reverse)])
                latest.fetchLimit = 1
                journalReads += 1
                let current = try context.fetchHistory(latest).first?.token.tokenValue
                if current == nil || saved.tokenValue?.allSatisfy({ key, value in
                    current?[key].map { $0 >= value } == true
                }) != true {
                    invalidateAll()
                    record.token = nil
                }
            }
            needsTokenValidation = false
            var descriptor: HistoryDescriptor<DefaultHistoryTransaction>
            if let token = record.token {
                descriptor = HistoryDescriptor(predicate: #Predicate { $0.token > token })
            } else {
                descriptor = HistoryDescriptor(sortBy: [SortDescriptor(\.transactionIdentifier, order: .reverse)])
                descriptor.fetchLimit = 1
            }
            journalReads += 1
            let transactions = try context.fetchHistory(descriptor)
            changedTransactions += transactions.count
            if record.token != nil { consume(transactions.flatMap(\.changes), in: context) }
            if let last = transactions.max(by: { $0.transactionIdentifier < $1.transactionIdentifier }) {
                record.token = last.token
            }
            isReliable = true
            if context.hasChanges {
                for model in context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray {
                    if let row = model as? Trade { invalidate(row.stock, source: true) }
                    else if let stock = model as? Stock { invalidate(stock, source: true) }
                    else if model is MarketDay { invalidateMarket() }
                }
            }
        } catch {
            // Invalid/expired tokens, unsupported stores and replacement never
            // turn a missing journal into proof that old results remain valid.
            invalidateAll()
            record.token = nil
            isReliable = false
        }
    }

    private func consume(_ changes: [HistoryChange], in context: ModelContext) {
        let deleted = Set(changes.compactMap { change -> PersistentIdentifier? in
            if case .delete(let value) = change { return value.changedPersistentIdentifier }
            return nil
        })
        var hasUnownedDeletion = false
        var relationshipOwners: Set<String> = []
        for change in changes {
            switch change {
            case .insert(let value):
                guard !deleted.contains(value.changedPersistentIdentifier) else { continue }
                invalidateModel(context.model(for: value.changedPersistentIdentifier), source: true)
            case .update(let value):
                guard !deleted.contains(value.changedPersistentIdentifier) else { continue }
                if let update = value as? DefaultHistoryUpdate<Stock>,
                   let stock = context.model(for: value.changedPersistentIdentifier) as? Stock {
                    let fields = update.updatedAttributes
                    if fields.contains(\Stock.trades) { relationshipOwners.insert(stock.sId) }
                    let sourceFields: [PartialKeyPath<Stock>] = [\Stock.trades, \Stock.sId, \Stock.group,
                        \Stock.dateStart, \Stock.dateFirst, \Stock.twseHistoryCoverage, \Stock.twseListingDate]
                    let ignored: [PartialKeyPath<Stock>] = [\Stock.sName, \Stock.proport, \Stock.isListed,
                        \Stock.yahooCheckedAt, \Stock.p10Action, \Stock.p10Date, \Stock.p10L, \Stock.p10H, \Stock.p10Rule]
                    if fields.contains(where: { sourceFields.contains($0) }) { invalidate(stock, source: true) }
                    else if fields.contains(where: { !ignored.contains($0) }) { invalidate(stock, source: false) }
                } else if let update = value as? DefaultHistoryUpdate<Trade>,
                          let trade = context.model(for: value.changedPersistentIdentifier) as? Trade {
                    let raw: [PartialKeyPath<Trade>] = [\Trade.stock, \Trade.dateTime, \Trade.dataSource,
                        \Trade.priceClose, \Trade.priceOpen, \Trade.priceHigh, \Trade.priceLow, \Trade.volumeClose]
                    invalidate(trade.stock, source: update.updatedAttributes.contains { raw.contains($0) })
                } else if value is DefaultHistoryUpdate<MarketDay> { invalidateMarket() }
                else { invalidateAll() }
            case .delete(let value):
                if value is DefaultHistoryDelete<MarketDay> { invalidateMarket() }
                else if value is DefaultHistoryDelete<Trade> { hasUnownedDeletion = true }
                else if value is DefaultHistoryDelete<Stock> { hasUnownedDeletion = true }
                else { invalidateAll() }
            @unknown default: invalidateAll()
            }
        }
        // Ordinary Trade deletion records its inverse Stock.trades update.
        // A bulk/foreign deletion without an owner has no safe narrow scope.
        if hasUnownedDeletion && relationshipOwners.isEmpty { invalidateAll() }
    }

    private func invalidateModel(_ model: any PersistentModel, source: Bool) {
        if let row = model as? Trade { invalidate(row.stock, source: source) }
        else if let stock = model as? Stock { invalidate(stock, source: source) }
        else if model is MarketDay { invalidateMarket() }
        else { invalidateAll() }
    }

    func invalidate(_ stock: Stock, source: Bool) {
        if source {
            record.stocks[stock.sId] = nil
            record.listings?[stock.sId] = nil
            stock.invalidateCalculationWindow()
            stockInvalidations.insert(stock.sId)
        }
        else { record.stocks[stock.sId]?.workKey = nil }
        record.generations[stock.sId, default: 0] += 1
        record.p10Keys[stock.sId] = nil
    }
    func invalidateMarket() {
        record.market = nil
        marketInvalidated = true
        record.marketGeneration += 1
        record.p10Keys.removeAll()
        for id in record.stocks.keys { record.stocks[id]?.workKey = nil }
    }
    private func invalidateAll() {
        allStocksInvalidated = true
        record.stocks.removeAll()
        record.listings = nil
        invalidateMarket()
        record.p10Keys.removeAll()
    }

    private func sourceKey(_ stock: Stock) -> Data {
        // No relationship traversal. Raw edits are covered by journal events.
        struct Key: Codable { let id: String; let group: String; let start: Date; let first: Date; let coverage: Data?; let listing: Date? }
        return encoded(Key(id: stock.sId, group: stock.group, start: stock.dateStart,
            first: stock.dateFirst, coverage: stock.twseHistoryCoverage, listing: stock.twseListingDate))
    }
    private func workKey(_ stock: Stock) -> Data {
        struct Key: Codable {
            let source: Data; let t: Int; let s: Int; let td: Date?; let sd: Date?
            let pending: Data?; let origin: Data?; let money: Double; let invest: Double
        }
        return encoded(Key(source: sourceKey(stock), t: stock.technicalStateVersion,
            s: stock.simulationStateVersion, td: stock.technicalDirtyFrom, sd: stock.simulationDirtyFrom,
            pending: stock.technicalPendingWork, origin: stock.technicalRollingOrigin,
            money: stock.simMoneyBase, invest: stock.simInvestAuto))
    }
    func proof(for stock: Stock) -> StockProof? {
        guard isReliable, context?.hasChanges == false, let proof = record.stocks[stock.sId],
              proof.sourceKey == sourceKey(stock) else { return nil }
        return proof
    }
    func hasCompletedWork(_ stock: Stock) -> Bool { proof(for: stock)?.workKey == workKey(stock) }
    /// Synchronous raw-input hooks only invalidate the listing exception.
    /// Source/work proofs retain their existing journal-based invalidation;
    /// temporary P10 prices must not broadly discard completed work here.
    func invalidateListingEvidence(for stock: Stock) {
        record.listings?[stock.sId] = nil
    }
    func listingProof(for stock: Stock) -> ListingProof? {
        guard isReliable, context?.hasChanges == false,
              let proof = record.listings?[stock.sId], proof.listing == stock.twseListingDate else { return nil }
        return proof
    }

    /// Explicit source-maintenance work. UI reads may consume the result but
    /// must never start a retained-history query themselves. Unknown remains
    /// unknown until the store is saved and its journal is trustworthy.
    func confirmListingEvidence(for stock: Stock) throws {
        refresh()
        try confirmListingEvidenceAfterJournalRefresh(for: stock)
    }

    /// Batch/session entry: its owner has already consumed the journal at the
    /// read boundary and must refresh again after a save before calling this.
    /// Keep the standalone entry above safe for callers without a session.
    func confirmListingEvidenceAfterJournalRefresh(for stock: Stock) throws {
        guard let context, let listing = stock.twseListingDate,
              !stock.group.isEmpty else { return }
        guard isReliable, !context.hasChanges, listingProof(for: stock) == nil else { return }
        let owner = stock.persistentModelID
        let maximum = Double.greatestFiniteMagnitude
        var descriptor = FetchDescriptor<Trade>(predicate: #Predicate {
            $0.stock.persistentModelID == owner && $0.dateTime < listing
                && $0.dataSource == "TWSE" && $0.priceClose > 0 && $0.priceClose <= maximum
        })
        descriptor.fetchLimit = 1
        listingEvidenceReads += 1
        let earlier = !(try context.fetch(descriptor)).isEmpty
        if record.listings == nil { record.listings = [:] }
        record.listings?[stock.sId] = ListingProof(listing: listing, hasEarlierOfficialPrice: earlier)
    }
    func sourceIsComplete(_ stock: Stock, through cutoff: Date?) -> Bool {
        guard let cutoff, let proof = proof(for: stock), let complete = proof.completeThrough else { return false }
        return complete >= twDateTime.startOfDay(cutoff)
    }
    func rememberSource(_ stock: Stock, trades: [Trade], through cutoff: Date?) {
        guard isReliable, context?.hasChanges == false else { return }
        let latest = trades.last(where: \.hasUsableOfficialPrice)?.dateTime
        let complete = cutoff.flatMap { date in
            latest.map { twDateTime.startOfDay($0) >= twDateTime.startOfDay(date) } == true
                && stock.unconfirmedHistoryMonths(through: latest ?? date).isEmpty
                ? twDateTime.startOfDay(date) : nil
        }
        record.stocks[stock.sId] = StockProof(sourceKey: sourceKey(stock), latestOfficial: latest,
            completeThrough: complete, window: stock.calculationWindow, workKey: nil)
    }
    func rememberCompletedWork(_ stock: Stock) {
        guard isReliable, context?.hasChanges == false, record.stocks[stock.sId] != nil else { return }
        record.stocks[stock.sId]?.workKey = workKey(stock)
    }
    func marketProof(floor: Date, cutoff: Date) -> MarketProof? {
        guard isReliable, context?.hasChanges == false, let proof = record.market,
              floor >= proof.floor, cutoff <= proof.cutoff else { return nil }
        return proof
    }
    func rememberMarket(floor: Date, cutoff: Date, first: Date, last: Date) {
        guard isReliable, context?.hasChanges == false else { return }
        record.market = MarketProof(floor: floor, cutoff: cutoff, first: first, last: last)
    }
    func persist() throws {
        guard isReliable, context?.hasChanges == false, let file else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(record)
        guard data != lastPersistedData else { return }
        try data.write(to: file, options: .atomic)
        lastPersistedData = data
    }

    func p10Key(for stock: Stock, quote: Trade) -> Data {
        struct Key: Codable {
            let work: Data; let revision: Int; let market: Int; let time: Date
            let open: Double; let high: Double; let low: Double; let close: Double; let volume: Double
            let reversed: String; let investment: Double
        }
        return encoded(Key(work: workKey(stock), revision: record.generations[stock.sId, default: 0],
            market: record.marketGeneration, time: quote.dateTime, open: quote.priceOpen, high: quote.priceHigh,
            low: quote.priceLow, close: quote.priceClose, volume: quote.volumeClose,
            reversed: quote.simReversed, investment: quote.simInvestByUser))
    }
    func hasP10(_ stock: Stock, quote: Trade) -> Bool {
        isReliable && context?.hasChanges == false && record.p10Keys[stock.sId] == p10Key(for: stock, quote: quote)
    }
    func rememberP10(_ stock: Stock, quote: Trade) {
        guard isReliable, context?.hasChanges == false else { return }
        record.p10Keys[stock.sId] = p10Key(for: stock, quote: quote)
    }
}
