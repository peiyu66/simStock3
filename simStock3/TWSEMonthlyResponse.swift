import Foundation

/// STOCK_DAY totals include odd-lot trading, whose prices are not ordinary
/// OHLC. A fully absent OHLC row is source evidence, never a synthetic Trade.
nonisolated struct TWSEMonthlyResponse {
    struct Price {
        let date: Date
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        let volume: Double
    }

    let prices: [Price]
    let noPriceDays: [TWSEHistoryCoverage.NoPriceDay]
    let lastDate: Date

    enum ParseError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String {
            switch self { case .invalid(let reason): return "月行情解析失敗：\(reason)，保留未確認狀態" }
        }
    }

    init(rows: [[String]], month: Date) throws {
        guard !rows.isEmpty else { throw ParseError.invalid("空白回應") }
        var prices: [Price] = []
        var absent: [TWSEHistoryCoverage.NoPriceDay] = []
        var dates: Set<Date> = []
        let expectedMonth = twDateTime.startOfMonth(month)
        func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        func integer(_ value: String) -> Int64? {
            let text = clean(value)
            guard text.range(of: #"^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)$"#, options: .regularExpression) != nil else { return nil }
            return Int64(text.replacingOccurrences(of: ",", with: ""))
        }
        func price(_ value: String) -> Double? {
            let text = clean(value)
            guard text.range(of: #"^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                  let number = Double(text.replacingOccurrences(of: ",", with: "")),
                  number.isFinite, number > 0 else { return nil }
            return number
        }
        for (index, row) in rows.enumerated() {
            func invalid(_ reason: String) -> ParseError { .invalid("第\(index + 1)列\(reason)") }
            guard row.count >= 9 else { throw invalid("欄位不足") }
            guard let date = twDateTime.dateFromROCString(clean(row[0])),
                  twDateTime.startOfMonth(date) == expectedMonth,
                  dates.insert(date).inserted else { throw invalid("日期無效、跨月或重複") }
            guard let shares = integer(row[1]), let amount = integer(row[2]),
                  let transactions = integer(row[8]) else { throw invalid("成交統計無效") }
            let ohlc = Array(row[3...6]).map(clean)
            if ohlc.allSatisfy({ $0 == "--" }) {
                absent.append(.init(date: date, shares: shares, amount: amount, transactions: transactions))
            } else {
                guard let open = price(ohlc[0]), let high = price(ohlc[1]),
                      let low = price(ohlc[2]), let close = price(ohlc[3]),
                      low <= min(open, close), high >= max(open, close) else {
                    throw invalid("價格部分缺值或無效")
                }
                prices.append(Price(date: date, open: open, high: high, low: low,
                                    close: close, volume: Double(shares) / 1000))
            }
        }
        self.prices = prices.sorted { $0.date < $1.date }
        self.noPriceDays = absent.sorted { $0.date < $1.date }
        self.lastDate = dates.max()!
    }
}
