import Foundation
import XCTest
@testable import simStock3

final class BoundedMarketTechnicalTests: XCTestCase {
    private typealias Point = BoundedMarketTechnicalContext.Point
    private typealias Value = BoundedMarketTechnicalContext.Value

    func testFirstPointRetainsDirectHighDistanceButSeedsDerivedValuesLocally() throws {
        let first = point(0, open: 100, high: 110, low: 90, close: 104)
        var context = BoundedMarketTechnicalContext()
        let value = try XCTUnwrap(context.update(first))
        XCTAssertEqual(value.observationCount, 1)
        XCTAssertEqual(value.highMax9, 110)
        XCTAssertEqual(value.lowMin9, 90)
        XCTAssertEqual(value.highDiff250, 100 * (104.0 - 110) / 110)
        XCTAssertEqual(value.ema12, 102)
        XCTAssertEqual(value.ema26, 102)
        XCTAssertEqual(value.macd9, 0)
        XCTAssertEqual(value.kdK, 50)
        XCTAssertEqual(value.kdD, 50)
        XCTAssertEqual(value.kdJZ250, 0)
        XCTAssertEqual(value.highDiffZ125, 0)
        XCTAssertEqual(value.lowDiffZ125, 0)
        XCTAssertEqual(value.oscZ125, 0)
        XCTAssertEqual(value.ma20DiffMax9, 0)
        XCTAssertNil(value.pricePath)
        assertValue(value, equals: oracle([first]))
    }

    func testSecondPointUsesExistingKDAndDemandEMACoefficients() throws {
        let prices = [point(0), point(1, open: 105, high: 120, low: 100, close: 110)]
        var context = BoundedMarketTechnicalContext(priorPoints: [prices[0]])
        let value = try XCTUnwrap(context.update(prices[1]))
        let rsv = 100 * (110.0 - 99) / (120 - 99)
        let k = 2 * 50.0 / 3 + rsv / 3
        XCTAssertEqual(value.kdK, k)
        XCTAssertEqual(value.kdD, 2 * 50.0 / 3 + k / 3)
        XCTAssertEqual(value.ema12, (11 * 100.0 + 2 * 110) / 13)
        XCTAssertEqual(value.ema26, (25 * 100.0 + 2 * 110) / 27)
        XCTAssertEqual(value.macd9, (8 * 0 + 2 * (value.ema12 - value.ema26)) / 10)
        XCTAssertEqual(value.highDiffZ125, -1, accuracy: 1e-12)
        XCTAssertEqual(value.lowDiffZ125, 1, accuracy: 1e-12)
        XCTAssertEqual(value.oscZ125, 1, accuracy: 1e-12)
        XCTAssertEqual(value.kdJZ250, 1, accuracy: 1e-12)
        XCTAssertEqual(value.ma20DiffMax9, 4.55)
        assertValue(value, equals: oracle(prices))
    }

    func testEveryColumnMatchesIndependentFormulaOracleAtEveryTarget() {
        let prices = variedPoints(count: 430)
        var context = BoundedMarketTechnicalContext()
        for index in prices.indices {
            assertValue(context.update(prices[index]), equals: oracle(Array(prices[...index])),
                        message: "index \(index)")
        }
    }

    func test249250251BoundaryNeverReportsPrematureMaturity() throws {
        XCTAssertEqual(BoundedMarketTechnicalContext.maximumObservationCount, 250)
        let prices = variedPoints(count: 251)
        for count in [249, 250, 251] {
            var context = BoundedMarketTechnicalContext(priorPoints: Array(prices.prefix(count - 1)))
            let value = try XCTUnwrap(context.update(prices[count - 1]))
            XCTAssertEqual(value.observationCount, min(count, 250))
            XCTAssertEqual(value.observationCount >= 250, count >= 250)
            assertValue(value, equals: oracle(Array(prices.prefix(count))), message: "count \(count)")
        }
    }

    func testHigh125Z125DoesNotChangeHE02Direct250HighDistance() throws {
        let prices = variedPoints(count: 250)
        var withOldSpike = prices
        let first = prices[0]
        withOldSpike[0] = Point(date: first.date, open: first.open, high: 100_000,
                                low: first.low, close: first.close)
        let normal = try XCTUnwrap(replay(prices).last ?? nil)
        let changed = try XCTUnwrap(replay(withOldSpike).last ?? nil)
        XCTAssertNotEqual(changed.highDiff250, normal.highDiff250)
        XCTAssertEqual(changed.highDiff250, 100 * (prices[249].close - 100_000) / 100_000)
        // The oldest of 250 raw rows is outside high125 + Z125's 249-row
        // dependency, while remaining inside H-E02's direct 250-high window.
        XCTAssertEqual(changed.highDiffZ125, normal.highDiffZ125)
        let tail249 = try XCTUnwrap(BoundedMarketTechnicalContext.referenceValue(points: Array(withOldSpike.suffix(249))))
        XCTAssertEqual(changed.highDiffZ125, tail249.highDiffZ125)
        XCTAssertEqual(changed.lowDiffZ125, tail249.lowDiffZ125)
        XCTAssertEqual(tail249.observationCount, 249)
        assertValue(changed, equals: oracle(withOldSpike))
    }

    func testEarliestOf249CanAffectHighDistanceDistribution() throws {
        let prices = variedPoints(count: 249)
        var altered = prices
        let first = prices[0]
        altered[0] = Point(date: first.date, open: first.open, high: 100_000,
                           low: first.low, close: first.close)
        let normal = try XCTUnwrap(BoundedMarketTechnicalContext.referenceValue(points: prices))
        let changed = try XCTUnwrap(BoundedMarketTechnicalContext.referenceValue(points: altered))
        XCTAssertNotEqual(changed.highDiffZ125, normal.highDiffZ125)
        assertValue(changed, equals: oracle(altered))
    }

    func testChangingAllEarlierHistoryCannotChangeTheSameLast250Inputs() {
        let prices = variedPoints(count: 510)
        var altered = prices
        for index in 0..<(prices.count - 250) {
            let multiplier = index.isMultiple(of: 2) ? 100.0 : 0.01
            altered[index] = scaled(prices[index], by: multiplier)
        }
        let original = replay(prices).last ?? nil
        let changed = replay(altered).last ?? nil
        XCTAssertNotNil(original)
        assertValue(changed, equals: original)
        assertValue(changed, equals: oracle(prices))
    }

    func testBatchSeedsAndColdRestartsMatchEveryColumn() {
        let prices = variedPoints(count: 330)
        let uninterrupted = replay(prices)
        for batchSize in [1, 41, 125, 249, 250, 251] {
            var context = BoundedMarketTechnicalContext()
            for index in prices.indices {
                if index.isMultiple(of: batchSize) {
                    context = BoundedMarketTechnicalContext(priorPoints: Array(prices[..<index]))
                }
                assertValue(context.update(prices[index]), equals: uninterrupted[index],
                            message: "batch \(batchSize), index \(index)")
            }
        }
    }

    func testFlatOHLCProducesZeroPopulationZAndFiniteLocalState() throws {
        let prices = (0..<280).map { point($0, open: 100, high: 100, low: 100, close: 100) }
        let values = replay(prices)
        for index in prices.indices {
            let value = try XCTUnwrap(values[index])
            XCTAssertEqual(value.highDiff250, 0)
            XCTAssertEqual(value.highDiffZ125, 0)
            XCTAssertEqual(value.lowDiffZ125, 0)
            XCTAssertEqual(value.oscZ125, 0)
            XCTAssertEqual(value.kdJZ250, 0)
            XCTAssertEqual(value.ma20DiffMax9, 0)
            XCTAssertEqual(value.kdK, 50)
            XCTAssertEqual(value.kdD, 50)
            XCTAssertEqual(value.ema12, 100)
            XCTAssertEqual(value.ema26, 100)
            XCTAssertEqual(value.macd9, 0)
            XCTAssertEqual(value.pricePath?.phase, index >= 40 ? .sideways : nil)
            assertValue(value, equals: oracle(Array(prices[...index])))
        }
    }

    func testPricePathWarmupUsesFortyReturnsInsideTheSameRawWindow() throws {
        let prices = variedPoints(count: 61)
        let values = replay(prices)
        for index in 0..<40 { XCTAssertNil(values[index]?.pricePath) }
        XCTAssertEqual(values[40]?.pricePath?.phase, .sideways)
        for count in [1, 39, 40, 41, 60, 61] {
            let value = try XCTUnwrap(values[count - 1])
            XCTAssertEqual(value.observationCount, count)
            assertValue(value, equals: oracle(Array(prices.prefix(count))))
        }
    }

    func testExtremaUseOHLCAndIncludeOnlyNineObservations() throws {
        var prices = (0..<11).map { point($0, open: 100, high: 120, low: 80, close: 100) }
        prices[0] = point(0, open: 100, high: 300, low: 50, close: 100)
        let values = replay(prices)
        XCTAssertEqual(try XCTUnwrap(values[8]).highMax9, 300)
        XCTAssertEqual(try XCTUnwrap(values[8]).lowMin9, 50)
        XCTAssertEqual(try XCTUnwrap(values[9]).highMax9, 120)
        XCTAssertEqual(try XCTUnwrap(values[9]).lowMin9, 80)
        XCTAssertEqual(try XCTUnwrap(values[9]).highDiff250, 100 * (100.0 - 300) / 300)
        for index in prices.indices { assertValue(values[index], equals: oracle(Array(prices[...index]))) }
    }

    func testMA20DeviationRoundingAndNineObservationMaximum() throws {
        var prices = (0..<30).map { point($0) }
        prices[20] = point(20, open: 120, high: 121, low: 119, close: 120)
        let values = replay(prices)
        XCTAssertEqual(try XCTUnwrap(values[28]).ma20DiffMax9, 15.83)
        XCTAssertEqual(try XCTUnwrap(values[29]).ma20DiffMax9, -1)
        assertValue(values[28], equals: oracle(Array(prices.prefix(29))))
        assertValue(values[29], equals: oracle(prices))
    }

    func testFutureOHLCDoesNotRelabelEarlierTargets() {
        let prefix = variedPoints(count: 280)
        let future = (280..<330).map { index in scaled(point(index), by: index.isMultiple(of: 2) ? 50 : 0.02) }
        let original = replay(prefix)
        let extended = replay(prefix + future)
        for index in prefix.indices {
            assertValue(extended[index], equals: original[index], message: "index \(index)")
        }
    }

    func testYahooStyleTrialCopiesUseOneFormalRawSeed() {
        let prices = variedPoints(count: 400)
        let seed = BoundedMarketTechnicalContext(priorPoints: Array(prices.dropLast()))
        for multiplier in [1.04, 0.92, 1.01, 1.0] {
            var trial = seed
            let quote = scaled(prices[399], by: multiplier)
            assertValue(trial.update(quote), equals: oracle(Array(prices.dropLast()) + [quote]))
        }
        var formal = seed
        assertValue(formal.update(prices[399]), equals: oracle(prices))
    }

    func testInvalidOHLCNeitherAdvancesNorBreaksTheValidSequence() {
        let prices = variedPoints(count: 320)
        var context = BoundedMarketTechnicalContext(priorPoints: Array(prices.prefix(300)))
        let original = context
        let invalid = [
            point(300, open: 0), point(300, high: .infinity), point(300, low: .nan),
            point(300, close: 0), point(300, close: -1), point(300, high: 99),
            point(300, low: 101), point(300, open: 102), point(300, low: 0)
        ]
        for quote in invalid {
            XCTAssertNil(context.update(quote))
            XCTAssertEqual(context, original)
        }
        assertValue(context.update(prices[300]), equals: oracle(Array(prices.prefix(301))))

        var seed: [Point] = []
        for value in prices.dropLast() {
            seed.append(value)
            seed.append(Point(date: value.date.addingTimeInterval(1), open: value.open,
                              high: value.high, low: .nan, close: value.close))
        }
        var seeded = BoundedMarketTechnicalContext(priorPoints: seed)
        assertValue(seeded.update(prices[319]), equals: oracle(prices))
    }

    func testDuplicateAndDecreasingDatesRestartAllLocalStates() throws {
        let prices = variedPoints(count: 300)
        for targetIndex in [100, 299] {
            var context = BoundedMarketTechnicalContext(priorPoints: prices)
            let target = prices[targetIndex]
            let restarted = try XCTUnwrap(context.update(target))
            XCTAssertEqual(restarted.observationCount, 1)
            XCTAssertNil(restarted.pricePath)
            XCTAssertEqual(restarted.kdK, 50)
            XCTAssertEqual(restarted.kdD, 50)
            XCTAssertEqual(restarted.macd9, 0)
            assertValue(restarted, equals: oracle([target]))
        }
    }

    func testBatchReferenceHasNoValueWithoutAValidTarget() {
        XCTAssertNil(BoundedMarketTechnicalContext.referenceValue(points: []))
        let prices = variedPoints(count: 300)
        for count in [1, 40, 41, 125, 249, 250, 251, 300] {
            let prefix = Array(prices.prefix(count))
            assertValue(BoundedMarketTechnicalContext.referenceValue(points: prefix), equals: oracle(prefix))
        }
        XCTAssertNil(BoundedMarketTechnicalContext.referenceValue(points: prices + [point(300, close: 0)]))
    }

    /// Independent formula oracle. No bounded helper or market rolling helper
    /// calculates expected KD, distances, EMA, OSC, or MA statistics here.
    /// Price path alone calls the existing state machine from an empty state.
    private func oracle(_ input: [Point]) -> Value? {
        func valid(_ p: Point) -> Bool {
            p.open.isFinite && p.high.isFinite && p.low.isFinite && p.close.isFinite
                && p.open > 0 && p.close > 0 && p.low > 0
                && p.high >= p.open && p.high >= p.close && p.low <= p.open && p.low <= p.close
        }
        guard let target = input.last, valid(target) else { return nil }
        var segment: [Point] = []
        for p in input where valid(p) {
            if let previous = segment.last, p.date <= previous.date { segment = [] }
            segment.append(p)
        }
        let raw = Array(segment.suffix(250))
        var k = 50.0, d = 50.0, ema12 = 0.0, ema26 = 0.0, macd9 = 0.0
        var js: [Double] = [], oscillators: [Double] = []
        var highDistances: [Double] = [], lowDistances: [Double] = [], maDifferences: [Double] = []
        var path = PricePathRollingContext()
        var pricePath: PricePathStoredState?
        for index in raw.indices {
            let p = raw[index]
            let recent9 = raw[max(0, index - 8)...index]
            let recent125 = raw[max(0, index - 124)...index]
            let recent20 = raw[max(0, index - 19)...index]
            let high9 = recent9.map(\.high).max()!
            let low9 = recent9.map(\.low).min()!
            let demand = (p.high + p.low + 2 * p.close) / 4
            if index == 0 {
                ema12 = demand; ema26 = demand
                highDistances.append(0); lowDistances.append(0); maDifferences.append(0)
            } else {
                let rsv = high9 == low9 ? 50 : 100 * (p.close - low9) / (high9 - low9)
                k = 2 * k / 3 + rsv / 3
                d = 2 * d / 3 + k / 3
                ema12 = (11 * ema12 + 2 * demand) / 13
                ema26 = (25 * ema26 + 2 * demand) / 27
                macd9 = (8 * macd9 + 2 * (ema12 - ema26)) / 10
                let high = recent125.map(\.high).max()!
                let low = recent125.map(\.low).min()!
                highDistances.append(100 * (p.close - high) / high)
                lowDistances.append(100 * (p.close - low) / low)
                let meanClose = recent20.map(\.close).reduce(0, +) / Double(recent20.count)
                maDifferences.append((10000 * (p.close - meanClose) / p.close).rounded() / 100)
            }
            js.append(3 * k - 2 * d)
            oscillators.append(ema12 - ema26 - macd9)
            pricePath = path.update(date: p.date, close: p.close)
        }
        func z(_ values: [Double]) -> Double {
            let average = values.reduce(0, +) / Double(values.count)
            let squares = values.map { ($0 - average) * ($0 - average) }
            let sigma = sqrt(squares.reduce(0, +) / Double(values.count))
            return sigma == 0 ? 0 : (values.last! - average) / sigma
        }
        let high250 = raw.map(\.high).max()!
        return Value(pricePath: pricePath,
            highMax9: raw.suffix(9).map(\.high).max()!, lowMin9: raw.suffix(9).map(\.low).min()!,
            highDiff250: 100 * (target.close - high250) / high250,
            highDiffZ125: z(Array(highDistances.suffix(125))), oscZ125: z(Array(oscillators.suffix(125))),
            ema12: ema12, ema26: ema26, macd9: macd9, kdK: k, kdD: d, kdJZ250: z(js),
            lowDiffZ125: z(Array(lowDistances.suffix(125))), ma20DiffMax9: maDifferences.suffix(9).max()!,
            observationCount: raw.count)
    }

    private func replay(_ points: [Point]) -> [Value?] {
        var context = BoundedMarketTechnicalContext()
        return points.map { context.update($0) }
    }

    private func assertValue(_ actual: Value?, equals expected: Value?, message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, message, file: file, line: line)
        let columns: [(String, KeyPath<Value, Double>)] = [
            ("highMax9", \.highMax9), ("lowMin9", \.lowMin9), ("highDiff250", \.highDiff250),
            ("highDiffZ125", \.highDiffZ125), ("oscZ125", \.oscZ125), ("ema12", \.ema12),
            ("ema26", \.ema26), ("macd9", \.macd9), ("kdK", \.kdK), ("kdD", \.kdD),
            ("kdJZ250", \.kdJZ250), ("lowDiffZ125", \.lowDiffZ125), ("ma20DiffMax9", \.ma20DiffMax9)
        ]
        for (name, key) in columns {
            XCTAssertEqual(actual.map { $0[keyPath: key] }, expected.map { $0[keyPath: key] },
                           "\(name): \(message)", file: file, line: line)
        }
        XCTAssertEqual(actual?.pricePath, expected?.pricePath, message, file: file, line: line)
        XCTAssertEqual(actual?.observationCount, expected?.observationCount, message, file: file, line: line)
    }

    private func variedPoints(count: Int) -> [Point] {
        (0..<count).map { index in
            let close = 100 + 12 * sin(Double(index) / 17) + 7 * cos(Double(index) / 9) + Double(index) / 30
            return point(index, open: close - 0.4, high: close + 1 + Double(index % 5) / 10,
                         low: close - 1.5 - Double(index % 7) / 10, close: close)
        }
    }

    private func point(_ index: Int, open: Double = 100, high: Double = 101,
                       low: Double = 99, close: Double = 100) -> Point {
        Point(date: Date(timeIntervalSinceReferenceDate: Double(index) * 86_400),
              open: open, high: high, low: low, close: close)
    }

    private func scaled(_ value: Point, by multiplier: Double) -> Point {
        Point(date: value.date, open: value.open * multiplier, high: value.high * multiplier,
              low: value.low * multiplier, close: value.close * multiplier)
    }
}
