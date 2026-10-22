# TWSE 正常無 OHLC 月回應

2026-10-22 核對的官方公開 STOCK_DAY 回應，作為解析回歸 fixture；不含使用者資料庫、持股或裝置資料。共 99 列有效價格，另五列四個 OHLC 全為 `--`。量額統計與 OHLC 的口徑不同，不把零股成交價改作普通 OHLC。

| 檔案 | 官方月回應 | 無 OHLC 日期／已核對原因 |
|---|---|---|
| 2201-202003.json | [TWSE](https://www.twse.com.tw/exchangeReport/STOCK_DAY?date=20200301&stockNo=2201) | 2020/03/30 暫停交易 |
| 2317-202507.json | [TWSE](https://www.twse.com.tw/exchangeReport/STOCK_DAY?date=20250701&stockNo=2317) | 2025/07/30 暫停交易 |
| 2449-202404.json | [TWSE](https://www.twse.com.tw/exchangeReport/STOCK_DAY?date=20240401&stockNo=2449) | 2024/04/26 暫停交易 |
| 8467-202302.json | [TWSE](https://www.twse.com.tw/exchangeReport/STOCK_DAY?date=20230201&stockNo=8467) | 2023/02/17 零成交；不推測停牌 |
| 8467-202606.json | [TWSE](https://www.twse.com.tw/exchangeReport/STOCK_DAY?date=20260601&stockNo=8467) | 2026/06/12 只有零股：盤中39股／7筆／5070元、盤後100股／1筆／12500元 |

原因另以 TWSE 暫停交易名單（TWTAWU）、每日收盤（MI_INDEX）、盤中零股（TWTC7U）及盤後零股（TWT53U）交叉核對。詳[修復說明](../../../doc/TWSE無價格列解析修復-20261022.md)及[官方制度](https://www.twse.com.tw/zh/products/system/trading.html)。測試只讀保存檔案，不重新下載。
