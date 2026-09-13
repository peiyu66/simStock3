import Foundation

nonisolated struct TWSEBatchProgress: Identifiable, Equatable {
    let id = UUID()
    let stockHistoryMonths: Int
    let stockRecentMonths: Int
    let marketMonths: Int

    var remainingMonths: Int { stockHistoryMonths + stockRecentMonths + marketMonths }
    var nextBatchMonths: Int { min(6, remainingMonths) }
    static let monthChoices = Array(1...6)

    var message: String {
        "個股尚待補近期 \(stockRecentMonths)、歷史 \(stockHistoryMonths) 個月份；"
            + "大盤尚待補 \(marketMonths) 個月份，合計 \(remainingMonths) 個月份。\n\n"
            + "繼續後，各檔及大盤再下載最多 \(nextBatchMonths) 個月，不足則補到完成。"
            + "取消會保留已下載資料，之後可再按更新股價接續。"
    }

    static func make(
        stockHistoryMonths: Int,
        stockRecentMonths: Int,
        marketMonths: Int,
        requestedMonths: Int,
        failedMonths: Int,
        reachedBatchLimit: Bool
    ) -> Self? {
        guard reachedBatchLimit, requestedMonths > 0, failedMonths == 0,
              stockHistoryMonths + stockRecentMonths + marketMonths > 0 else { return nil }
        return Self(stockHistoryMonths: stockHistoryMonths,
                    stockRecentMonths: stockRecentMonths, marketMonths: marketMonths)
    }
}
