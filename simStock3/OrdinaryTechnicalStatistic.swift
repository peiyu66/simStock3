import Foundation

/// Finite statistics of already stored observations. Replaying these fields
/// never reseeds K/D, EMA/OSC, MA, or trend-day continuation beyond the ordinary
/// maturity boundary. That separate preservation contract remains unchanged.
enum OrdinaryTechnicalStatistic: String, CaseIterable, Codable {
    case tMa20DiffMax9
    case tMa20DiffMin9
    case tMa60DiffMax9
    case tMa60DiffMin9
    case tOscMax9
    case tOscMin9
    case tKdKMax9
    case tKdKMin9
    case tKdKZ125
    case tKdKZ250
    case tKdDZ125
    case tKdDZ250
    case tKdJZ125
    case tKdJZ250
    case tOscZ125
    case tOscZ250
    case tMa20DiffZ125
    case tMa20DiffZ250
    case tMa60DiffZ125
    case tMa60DiffZ250
    case tZ125
    case tHighDiffZ125
    case tLowDiffZ125
    case tZ250
    case tHighDiffZ250
    case tLowDiffZ250
    case vMa20DiffMax9
    case vMa20DiffMin9
    case vMa20DiffZ125
    case vMa20DiffZ250
    case vMa60DiffMax9
    case vMa60DiffMin9
    case vMa60DiffZ125
    case vMa60DiffZ250
    case vMax9
    case vMin9
    case vZ125
    case vZ250

    enum Operation { case maximum, minimum, z }
    struct Definition {
        let input: KeyPath<Trade, Double>
        let output: ReferenceWritableKeyPath<Trade, Double>
        let count: Int
        let operation: Operation
        let volume: Bool
        let derivedInput: Bool
    }

    @MainActor var definition: Definition {
        switch self {
        case .tMa20DiffMax9: return .init(input: \.tMa20Diff, output: \.tMa20DiffMax9, count: 9, operation: .maximum, volume: false, derivedInput: true)
        case .tMa20DiffMin9: return .init(input: \.tMa20Diff, output: \.tMa20DiffMin9, count: 9, operation: .minimum, volume: false, derivedInput: true)
        case .tMa60DiffMax9: return .init(input: \.tMa60Diff, output: \.tMa60DiffMax9, count: 9, operation: .maximum, volume: false, derivedInput: true)
        case .tMa60DiffMin9: return .init(input: \.tMa60Diff, output: \.tMa60DiffMin9, count: 9, operation: .minimum, volume: false, derivedInput: true)
        case .tOscMax9: return .init(input: \.tOsc, output: \.tOscMax9, count: 9, operation: .maximum, volume: false, derivedInput: true)
        case .tOscMin9: return .init(input: \.tOsc, output: \.tOscMin9, count: 9, operation: .minimum, volume: false, derivedInput: true)
        case .tKdKMax9: return .init(input: \.tKdK, output: \.tKdKMax9, count: 9, operation: .maximum, volume: false, derivedInput: true)
        case .tKdKMin9: return .init(input: \.tKdK, output: \.tKdKMin9, count: 9, operation: .minimum, volume: false, derivedInput: true)
        case .tKdKZ125: return .init(input: \.tKdK, output: \.tKdKZ125, count: 125, operation: .z, volume: false, derivedInput: true)
        case .tKdKZ250: return .init(input: \.tKdK, output: \.tKdKZ250, count: 250, operation: .z, volume: false, derivedInput: true)
        case .tKdDZ125: return .init(input: \.tKdD, output: \.tKdDZ125, count: 125, operation: .z, volume: false, derivedInput: true)
        case .tKdDZ250: return .init(input: \.tKdD, output: \.tKdDZ250, count: 250, operation: .z, volume: false, derivedInput: true)
        case .tKdJZ125: return .init(input: \.tKdJ, output: \.tKdJZ125, count: 125, operation: .z, volume: false, derivedInput: true)
        case .tKdJZ250: return .init(input: \.tKdJ, output: \.tKdJZ250, count: 250, operation: .z, volume: false, derivedInput: true)
        case .tOscZ125: return .init(input: \.tOsc, output: \.tOscZ125, count: 125, operation: .z, volume: false, derivedInput: true)
        case .tOscZ250: return .init(input: \.tOsc, output: \.tOscZ250, count: 250, operation: .z, volume: false, derivedInput: true)
        case .tMa20DiffZ125: return .init(input: \.tMa20Diff, output: \.tMa20DiffZ125, count: 125, operation: .z, volume: false, derivedInput: true)
        case .tMa20DiffZ250: return .init(input: \.tMa20Diff, output: \.tMa20DiffZ250, count: 250, operation: .z, volume: false, derivedInput: true)
        case .tMa60DiffZ125: return .init(input: \.tMa60Diff, output: \.tMa60DiffZ125, count: 125, operation: .z, volume: false, derivedInput: true)
        case .tMa60DiffZ250: return .init(input: \.tMa60Diff, output: \.tMa60DiffZ250, count: 250, operation: .z, volume: false, derivedInput: true)
        case .tZ125: return .init(input: \.priceClose, output: \.tZ125, count: 125, operation: .z, volume: false, derivedInput: false)
        case .tHighDiffZ125: return .init(input: \.tHighDiff125, output: \.tHighDiffZ125, count: 125, operation: .z, volume: false, derivedInput: true)
        case .tLowDiffZ125: return .init(input: \.tLowDiff125, output: \.tLowDiffZ125, count: 125, operation: .z, volume: false, derivedInput: true)
        case .tZ250: return .init(input: \.priceClose, output: \.tZ250, count: 250, operation: .z, volume: false, derivedInput: false)
        case .tHighDiffZ250: return .init(input: \.tHighDiff250, output: \.tHighDiffZ250, count: 250, operation: .z, volume: false, derivedInput: true)
        case .tLowDiffZ250: return .init(input: \.tLowDiff250, output: \.tLowDiffZ250, count: 250, operation: .z, volume: false, derivedInput: true)
        case .vMa20DiffMax9: return .init(input: \.vMa20Diff, output: \.vMa20DiffMax9, count: 9, operation: .maximum, volume: true, derivedInput: true)
        case .vMa20DiffMin9: return .init(input: \.vMa20Diff, output: \.vMa20DiffMin9, count: 9, operation: .minimum, volume: true, derivedInput: true)
        case .vMa20DiffZ125: return .init(input: \.vMa20Diff, output: \.vMa20DiffZ125, count: 125, operation: .z, volume: true, derivedInput: true)
        case .vMa20DiffZ250: return .init(input: \.vMa20Diff, output: \.vMa20DiffZ250, count: 250, operation: .z, volume: true, derivedInput: true)
        case .vMa60DiffMax9: return .init(input: \.vMa60Diff, output: \.vMa60DiffMax9, count: 9, operation: .maximum, volume: true, derivedInput: true)
        case .vMa60DiffMin9: return .init(input: \.vMa60Diff, output: \.vMa60DiffMin9, count: 9, operation: .minimum, volume: true, derivedInput: true)
        case .vMa60DiffZ125: return .init(input: \.vMa60Diff, output: \.vMa60DiffZ125, count: 125, operation: .z, volume: true, derivedInput: true)
        case .vMa60DiffZ250: return .init(input: \.vMa60Diff, output: \.vMa60DiffZ250, count: 250, operation: .z, volume: true, derivedInput: true)
        case .vMax9: return .init(input: \.volumeClose, output: \.vMax9, count: 9, operation: .maximum, volume: true, derivedInput: false)
        case .vMin9: return .init(input: \.volumeClose, output: \.vMin9, count: 9, operation: .minimum, volume: true, derivedInput: false)
        case .vZ125: return .init(input: \.volumeClose, output: \.vZ125, count: 125, operation: .z, volume: true, derivedInput: false)
        case .vZ250: return .init(input: \.volumeClose, output: \.vZ250, count: 250, operation: .z, volume: true, derivedInput: false)
        }
    }

    @MainActor static var priceFields: Set<Self> { Set(allCases.filter { !$0.definition.volume }) }
    @MainActor static var volumeFields: Set<Self> { Set(allCases.filter { $0.definition.volume }) }
    @MainActor static var derivedFields: Set<Self> { Set(allCases.filter { $0.definition.derivedInput }) }

    /// Same input order, population variance, zero-variance rule, and endpoint
    /// initialization as tUpdateOrdinary/vUpdate. Only selected outputs are set.
    @MainActor static func update(_ fields: Set<Self>, trades: [Trade], index: Int) {
        guard !fields.isEmpty else { return }
        let target = trades[index]
        let volume = fields.contains { $0.definition.volume }
            ? Array((0...index).reversed().lazy.filter { OrdinaryTechnicalPreservation.eligibleVolume(trades[$0]) }.prefix(250)) : []
        for field in allCases where fields.contains(field) {
            let d = field.definition
            if d.volume && volume.first != index {
                target[keyPath: d.output] = index > 0 ? trades[index - 1][keyPath: d.output] : 0
                continue
            }
            // The ordinary initializer leaves first-price statistics at zero.
            if !d.volume && index == 0 { target[keyPath: d.output] = 0; continue }
            let indices = d.volume ? Array(volume.prefix(d.count)) : Array(max(0, index - d.count + 1)...index)
            guard !indices.isEmpty else { target[keyPath: d.output] = 0; continue }
            let current = target[keyPath: d.input]
            var result = current
            switch d.operation {
            case .maximum:
                for i in indices { let v = trades[i][keyPath: d.input]; if v > result { result = v } }
            case .minimum:
                for i in indices { let v = trades[i][keyPath: d.input]; if v < result { result = v } }
            case .z:
                var sum = 0.0
                for i in indices { sum += trades[i][keyPath: d.input] }
                let average = sum / Double(indices.count)
                var variance = 0.0
                for i in indices { variance += pow(trades[i][keyPath: d.input] - average, 2) }
                let deviation = sqrt(variance / Double(indices.count))
                result = deviation == 0 ? 0 : (current - average) / deviation
            }
            target[keyPath: d.output] = result
        }
    }

    /// Expand actual ordinary writes, not reads and not previous expansions.
    /// Qualified volume observations have their own ordinal sequence; Yahoo
    /// carries the preceding qualified statistics without advancing a window.
    @MainActor static func dependentWrites(ordinary: [Date], trades: [Trade]) -> [Self: [Date]] {
        let written = Set(ordinary.map { twDateTime.startOfDay($0) })
        guard !written.isEmpty else { return [:] }
        var result: [Self: [Date]] = [:]
        var lastPriceWrite: Int?
        var volumeOrdinal = -1
        var lastVolumeWrite: Int?
        for (index, trade) in trades.enumerated() {
            let isWritten = written.contains(twDateTime.startOfDay(trade.dateTime))
            if isWritten { lastPriceWrite = index }
            if OrdinaryTechnicalPreservation.eligibleVolume(trade) {
                volumeOrdinal += 1
                if isWritten { lastVolumeWrite = volumeOrdinal }
            }
            guard !isWritten else { continue } // already calculated by the full ordinary pass
            for field in allCases {
                let d = field.definition
                guard d.derivedInput else { continue }
                let endpoint = d.volume ? volumeOrdinal : index
                let lastWrite = d.volume ? lastVolumeWrite : lastPriceWrite
                if let lastWrite, lastWrite >= endpoint - d.count + 1 {
                    result[field, default: []].append(trade.dateTime)
                }
            }
        }
        return result
    }
}
