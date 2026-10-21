import Foundation

/// Market raw windows contain the target and up to 249 prior official rows.
/// Yahoo targets never become another target's formal checkpoint.
@MainActor
enum MarketTechnicalCoverage {
    static func affected(targetDates: [Date], officialDates: [Date], changedDates: [Date]) -> Set<Date> {
        let official = officialDates.map { twDateTime.startOfDay($0) }.sorted()
        let changes = Set(changedDates.map { twDateTime.startOfDay($0) })
        func bound(_ date: Date, after: Bool) -> Int {
            var low = 0, high = official.count
            while low < high {
                let middle = low + (high - low) / 2
                if official[middle] < date || (after && official[middle] == date) { low = middle + 1 }
                else { high = middle }
            }
            return low
        }
        return Set(targetDates.filter { target in
            let day = twDateTime.startOfDay(target)
            let beforeTarget = bound(day, after: false)
            return changes.contains { change in
                change <= day && beforeTarget - bound(change, after: true) < 249
            }
        })
    }
}

extension MarketDay {
    var hasUsableRawValues: Bool {
        [indexOpen, indexHigh, indexLow, indexClose].allSatisfy { $0.isFinite && $0 > 0 }
            && indexHigh >= max(indexOpen, indexClose) && indexLow <= min(indexOpen, indexClose)
    }

    var boundedRawPoint: BoundedMarketTechnicalContext.Point {
        .init(date: dateTime, open: indexOpen, high: indexHigh, low: indexLow, close: indexClose)
    }

    func applyBoundedTechnicalValue(_ value: BoundedMarketTechnicalContext.Value) {
        indexHighMax9 = value.highMax9; indexLowMin9 = value.lowMin9
        indexHighDiff250 = value.highDiff250
        indexHighDiffZ125 = value.highDiffZ125
        // The former 250 x 250 feature has a different meaning. Keep its schema
        // slot for old stores, but never label the new feature with its name.
        indexHighDiffZ250 = nil
        oscZ125 = value.oscZ125
        oscEMA12 = value.ema12; oscEMA26 = value.ema26; oscMACD9 = value.macd9
        kdK = value.kdK; kdD = value.kdD; kdJZ250 = value.kdJZ250
        indexLowDiffZ125 = value.lowDiffZ125; ma20DiffMax9 = value.ma20DiffMax9
        priceObservationCount = value.observationCount
        applyPricePathState(value.pricePath)
    }
}
