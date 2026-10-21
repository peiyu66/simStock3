#if DEBUG
import Foundation
import CryptoKit

struct UpdateCycleDiagnosticIdentity: Codable, Equatable {
    let formatVersion: Int
    let sample: String
    let profile: String
    let ruleCommit: String
    let inputSHA256: String
    let technicalVersion: String
    let marketVersion: Int

    enum IdentityError: LocalizedError {
        case invalidCommit, invalidRunID, incompatibleArguments
        var errorDescription: String? {
            switch self {
            case .invalidCommit: return "更新週期診斷須提供完整 40 碼規則 commit。"
            case .invalidRunID: return "診斷 id 僅允許 1–80 碼英數、底線或連字號，且須以英數開頭。"
            case .incompatibleArguments: return "更新週期診斷不得混用正式 Baseline、其他候選、DecisionBase 或 decision delta 旗標。"
            }
        }
    }

    init(sample: String, profile: String, ruleCommit: String, inputSHA256: String,
         technicalVersion: String, marketVersion: Int) throws {
        guard Self.validCommit(ruleCommit) else { throw IdentityError.invalidCommit }
        self.formatVersion = 1
        self.sample = sample
        self.profile = profile
        self.ruleCommit = ruleCommit.lowercased()
        self.inputSHA256 = inputSHA256
        self.technicalVersion = technicalVersion
        self.marketVersion = marketVersion
    }

    var cacheName: String {
        "update-cycle-\(sample.lowercased())-\(profile)-\(technicalVersion)-m\(marketVersion)-\(ruleCommit)-\(inputSHA256)"
    }

    func matches(marker: Data) -> Bool {
        (try? JSONDecoder().decode(Self.self, from: marker)) == self
    }

    static func validate(arguments: [String], ruleCommit: String?) throws {
        guard let ruleCommit, validCommit(ruleCommit) else { throw IdentityError.invalidCommit }
        guard !arguments.contains(where: {
            $0.hasPrefix("--formal-") || $0.hasPrefix("--candidate-")
                || $0.hasPrefix("--record-decision") || $0.hasPrefix("--counterfactual")
        }) else { throw IdentityError.incompatibleArguments }
    }

    static func runID(sample: String, fullWindow: Bool, ruleCommit: String?, requestedID: String?,
                      nonce: UUID = UUID()) throws -> String {
        guard let ruleCommit, validCommit(ruleCommit) else { throw IdentityError.invalidCommit }
        let id = requestedID ?? nonce.uuidString.lowercased()
        guard id.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$", options: .regularExpression) != nil else {
            throw IdentityError.invalidRunID
        }
        return "update-cycle-\(id)-\(sample.lowercased())-\(fullWindow ? "full" : "fixed3y")-\(ruleCommit.prefix(12))"
    }

    private static func validCommit(_ value: String) -> Bool {
        value.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil
    }

    /// Hash the actual copied SQLite input, including a live WAL. SHM is an
    /// index/cache, not input content. No store is opened or modified here.
    static func inputDigest(storeURL: URL) throws -> String {
        var hasher = SHA256()
        for suffix in ["", "-wal"] {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            hasher.update(data: Data((suffix.isEmpty ? "store" : suffix).utf8))
            guard FileManager.default.fileExists(atPath: url.path) else {
                hasher.update(data: Data("absent".utf8)); continue
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif
