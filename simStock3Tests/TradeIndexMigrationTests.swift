import CryptoKit
import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import simStock3

/// Run on the isolated Simulator only. No production path is accepted and no
/// direct SQLite writes/DDL are used. The old-store test is opt-in: stage a
/// checkpointed disposable copy at /tmp/simstock-trade-index-input.store.
/// Enable -com.apple.CoreData.SQLDebug 1 on the test host when collecting the
/// actual SQL between TRADE_INDEX_FETCH markers. EXPLAIN below is explicitly
/// representative SQL, not a claim about a captured SwiftData statement.
@MainActor
final class TradeIndexMigrationTests: XCTestCase {
    private let schema = Schema([Stock.self, Trade.self, MarketDay.self])

    func testNewStoreCreatesRelationshipDateIndexAndMaintainsItAcrossWrites() throws {
        let directory = try newRunDirectory()
        let output = directory.appendingPathComponent("fresh.store")
        let container = try open(output)
        let context = container.mainContext
        let start = twDateTime.dateFromString("2024/01/01")!
        let next = twDateTime.dateFromString("2024/01/02")!
        let later = twDateTime.dateFromString("2024/01/03")!
        let first = Stock(sId: "INDEX-A", sName: "Index A", group: "test",
                          dateFirst: start, dateStart: start)
        let second = Stock(sId: "INDEX-B", sName: "Index B", group: "",
                           dateFirst: start, dateStart: start)
        context.insert(first); context.insert(second)
        let older = Trade(stock: first, dateTime: start)
        let latest = Trade(stock: first, dateTime: next)
        let unrelated = Trade(stock: second, dateTime: later)
        for row in [older, latest, unrelated] {
            row.priceClose = 100; context.insert(row)
        }
        var writeSeconds: [String: Double] = [:]
        var writeStart = ProcessInfo.processInfo.systemUptime
        try context.save()
        writeSeconds["initialSave"] = ProcessInfo.processInfo.systemUptime - writeStart
        XCTAssertEqual(try dates(in: context, stock: first, from: next), [next])
        latest.dateTime = later
        writeStart = ProcessInfo.processInfo.systemUptime
        try context.save()
        writeSeconds["indexedDateChangeSave"] = ProcessInfo.processInfo.systemUptime - writeStart
        XCTAssertEqual(try dates(in: context, stock: first, from: next), [later])
        context.delete(older)
        writeStart = ProcessInfo.processInfo.systemUptime
        try context.save()
        writeSeconds["deleteSave"] = ProcessInfo.processInfo.systemUptime - writeStart
        XCTAssertEqual(try dates(in: context, stock: first, from: start), [later])
        var evidence = try indexEvidence(at: output)
        evidence["writeSeconds"] = writeSeconds
        evidence["writeTimingScope"] = "Indexed-store smoke timings only; not a before/after write-overhead benchmark"
        try writeEvidence(evidence, in: directory)
        withExtendedLifetime(container) {}
    }

    func testFrozenOldStoreGainsIndexAndReopensWithoutChangingAnyStoredValues() throws {
        let input = URL(fileURLWithPath: "/tmp/simstock-trade-index-input.store")
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw XCTSkip("Stage a checkpointed, isolated old-schema copy at \(input.path)")
        }
        // Immutable inspection is safe only for a frozen, checkpointed input.
        for suffix in ["-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: input.path + suffix),
                           "Stage a closed/checkpointed source, never a live SQLite store")
            guard !FileManager.default.fileExists(atPath: input.path + suffix) else { return }
        }
        let inputHash = try fileHash(input)
        let before = try tableSnapshots(at: input, immutable: true)
        let beforeIdentity = try schemaIdentity(at: input, immutable: true)
        XCTAssertGreaterThan(before["ZTRADE"]?.rows ?? 0, 0)
        XCTAssertTrue(try compositeIndexes(at: input, immutable: true).isEmpty,
                      "The migration fixture must precede the new compound index")
        let directory = try newRunDirectory()
        let output = directory.appendingPathComponent("migrated.store")
        try FileManager.default.copyItem(at: input, to: output)
        var report: [String: Any] = ["inputSHA256": inputHash,
                                     "inputBytes": try fileSize(input),
                                     "sourceSchemaIdentity": beforeIdentity]
        let firstOpenStart = ProcessInfo.processInfo.systemUptime
        try autoreleasepool {
            let container = try open(output)
            report["firstOpenSeconds"] = ProcessInfo.processInfo.systemUptime - firstOpenStart
            let context = container.mainContext
            var stockDescriptor = FetchDescriptor<Stock>(
                predicate: #Predicate { !$0.group.isEmpty }, sortBy: [SortDescriptor(\.sId)])
            stockDescriptor.fetchLimit = 1
            let stock = try XCTUnwrap(context.fetch(stockDescriptor).first)
            print("TRADE_INDEX_FETCH_BEGIN migration \(stock.sId)")
            _ = try dates(in: context, stock: stock, from: stock.dateRequestStart)
            print("TRADE_INDEX_FETCH_END migration")
            withExtendedLifetime(container) {}
        }
        XCTAssertEqual(try tableSnapshots(at: output), before,
                       "Index adoption must preserve every Stock, Trade and MarketDay column, including manual and T/S state")
        let afterIdentity = try schemaIdentity(at: output)
        XCTAssertNotEqual(beforeIdentity["TradeVersionHash"] as? String,
                          afterIdentity["TradeVersionHash"] as? String,
                          "The hash modifier must make the index-only schema migration detectable")
        report["migratedSchemaIdentity"] = afterIdentity
        report.merge(try indexEvidence(at: output)) { _, new in new }
        let reopenStart = ProcessInfo.processInfo.systemUptime
        try autoreleasepool {
            let reopened = try open(output)
            report["reopenSeconds"] = ProcessInfo.processInfo.systemUptime - reopenStart
            XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<Trade>()), before["ZTRADE"]?.rows)
            withExtendedLifetime(reopened) {}
        }
        XCTAssertEqual(try tableSnapshots(at: output), before)
        XCTAssertEqual(try fileHash(input), inputHash, "Never mutate the staged source")
        report["sourceUnchanged"] = try fileHash(input) == inputHash
        report["storedValuesUnchanged"] = try tableSnapshots(at: output) == before
        report["reopenedSuccessfully"] = true
        report["outputBytesIncludingWAL"] = try storeSize(output)
        report["tables"] = before.mapValues { ["rows": $0.rows, "sha256": $0.hash] as [String: Any] }
        try writeEvidence(report, in: directory)
    }

    private func open(_ url: URL) throws -> ModelContainer {
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, url: url))
        container.mainContext.autosaveEnabled = false
        return container
    }

    private func dates(in context: ModelContext, stock: Stock, from lower: Date) throws -> [Date] {
        let id = stock.persistentModelID
        var descriptor = FetchDescriptor<Trade>(
            predicate: #Predicate { $0.stock.persistentModelID == id && $0.dateTime >= lower },
            sortBy: [SortDescriptor(\.dateTime, order: .reverse)])
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = false
        return try context.fetch(descriptor).map(\.dateTime)
    }

    private func newRunDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("simstock-trade-index-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func fileHash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
    }

    private func storeSize(_ url: URL) throws -> Int64 {
        try ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let file = URL(fileURLWithPath: url.path + suffix)
            return total + (FileManager.default.fileExists(atPath: file.path) ? try fileSize(file) : 0)
        }
    }

    private func writeEvidence(_ report: [String: Any], in directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("index-evidence.json"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Trade index evidence"; attachment.lifetime = .keepAlways
        add(attachment)
        print("TRADE_INDEX_EVIDENCE \(directory.path)")
    }

    private struct TableSnapshot: Equatable {
        let columns: [String]
        let rows: Int
        let hash: String
    }

    private func schemaIdentity(at url: URL, immutable: Bool = false) throws -> [String: Any] {
        let db = try ReadOnlySQLite(url, immutable: immutable)
        var bytes: Data?
        try db.each("SELECT Z_PLIST FROM Z_METADATA LIMIT 1") { statement in
            if let pointer = sqlite3_column_blob(statement, 0) {
                bytes = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
            }
        }
        let metadata = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: XCTUnwrap(bytes), options: [], format: nil) as? [String: Any])
        let hashes = try XCTUnwrap(metadata["NSStoreModelVersionHashes"] as? [String: Data])
        let tradeHash = try XCTUnwrap(hashes["Trade"])
        return ["TradeVersionHash": tradeHash.map { String(format: "%02x", $0) }.joined(),
                "modelChecksum": metadata["NSStoreModelVersionChecksumKey"] as? String ?? "",
                "versionIdentifiers": metadata["NSStoreModelVersionIdentifiers"] as? [String] ?? []]
    }

    private func tableSnapshots(at url: URL, immutable: Bool = false) throws -> [String: TableSnapshot] {
        let db = try ReadOnlySQLite(url, immutable: immutable)
        var result: [String: TableSnapshot] = [:]
        for table in ["ZSTOCK", "ZTRADE", "ZMARKETDAY"] {
            let columns = try db.rows("PRAGMA table_info(\(table))").map { $0[1] }
            var hash = SHA256()
            var count = 0
            try db.each("SELECT * FROM \(table) ORDER BY Z_PK") { statement in
                for index in 0..<sqlite3_column_count(statement) {
                    // Include the SQLite storage type and byte length to avoid
                    // ambiguous concatenation, including NULL versus empty data.
                    var type = sqlite3_column_type(statement, index).littleEndian
                    withUnsafeBytes(of: &type) { hash.update(data: Data($0)) }
                    let bytes: Data
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_INTEGER:
                        var value = sqlite3_column_int64(statement, index).littleEndian
                        bytes = withUnsafeBytes(of: &value) { Data($0) }
                    case SQLITE_FLOAT:
                        var value = sqlite3_column_double(statement, index).bitPattern.littleEndian
                        bytes = withUnsafeBytes(of: &value) { Data($0) }
                    case SQLITE_TEXT, SQLITE_BLOB:
                        let length = Int(sqlite3_column_bytes(statement, index))
                        bytes = sqlite3_column_blob(statement, index).map { Data(bytes: $0, count: length) } ?? Data()
                    default: bytes = Data()
                    }
                    var length = UInt64(bytes.count).littleEndian
                    withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
                    hash.update(data: bytes)
                }
                count += 1
            }
            result[table] = TableSnapshot(columns: columns, rows: count,
                hash: hash.finalize().map { String(format: "%02x", $0) }.joined())
        }
        return result
    }

    private func compositeIndexes(at url: URL, immutable: Bool = false) throws -> [String] {
        let db = try ReadOnlySQLite(url, immutable: immutable)
        return try db.rows("PRAGMA index_list(ZTRADE)").compactMap { row in
            let name = row[1]
            let quoted = name.replacingOccurrences(of: "'", with: "''")
            let columns = try db.rows("PRAGMA index_info('\(quoted)')").map { $0[2].uppercased() }
            return columns == ["ZSTOCK", "ZDATETIME"] ? name : nil
        }
    }

    private func indexEvidence(at url: URL) throws -> [String: Any] {
        let db = try ReadOnlySQLite(url)
        let indexes = try compositeIndexes(at: url)
        XCTAssertEqual(indexes.count, 1, "SwiftData must create exactly one stock/date compound index")
        let sample = try XCTUnwrap(db.rows("SELECT ZSTOCK, MIN(ZDATETIME) FROM ZTRADE GROUP BY ZSTOCK LIMIT 1").first)
        let stock = try XCTUnwrap(Int64(sample[0]))
        let lower = try XCTUnwrap(Double(sample[1]))
        var plans: [String: Any] = [:]
        for direction in ["ASC", "DESC"] {
            let sql = "SELECT * FROM ZTRADE WHERE ZSTOCK=\(stock) AND ZDATETIME>=\(lower) ORDER BY ZDATETIME \(direction) LIMIT 1"
            let plan = try db.rows("EXPLAIN QUERY PLAN " + sql).map { $0[3] }
            XCTAssertTrue(plan.contains { detail in indexes.contains { detail.contains($0) } })
            XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") }, "Range endpoints must not sort all historical rows")
            plans[direction] = ["sql": sql, "plan": plan]
        }
        return ["compoundIndexes": indexes,
                "indexSQL": try db.rows("SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name='ZTRADE' ORDER BY name"),
                "representativeEndpointPlans": plans,
                "queryPlanEvidenceScope": "Representative SQL on the actual SwiftData-created store; separately capture CoreData.SQLDebug for actual fetch SQL"]
    }
}

/// Inspection only; the framework alone is responsible for schema mutations.
private final class ReadOnlySQLite {
    private var database: OpaquePointer?

    init(_ url: URL, immutable: Bool) throws {
        let source = immutable ? url.absoluteString + "?immutable=1" : url.path
        let status = sqlite3_open_v2(source, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard status == SQLITE_OK else { throw error() }
    }

    convenience init(_ url: URL) throws { try self.init(url, immutable: false) }
    deinit { sqlite3_close(database) }

    func rows(_ sql: String) throws -> [[String]] {
        var result: [[String]] = []
        try each(sql) { statement in
            result.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
            })
        }
        return result
    }

    func each(_ sql: String, _ body: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw error() }
        defer { sqlite3_finalize(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            body(statement)
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw error() }
    }

    private func error() -> NSError {
        NSError(domain: "TradeIndexReadOnlySQLite", code: Int(sqlite3_errcode(database)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
    }
}
