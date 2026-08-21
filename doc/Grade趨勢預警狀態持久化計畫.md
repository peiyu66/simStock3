# Grade 趨勢預警狀態持久化計畫

## 目標

Grade 趨勢圖示分成預警與確認。預警只描述趨勢由中性區往確認門檻前進，不在確認後退回相同數值區間時再次出現。這是 `simUpdate` 產生的每日滾動狀態；目前只供 UI 顯示與研究旁錄，不改動任何買賣規則。

## 固定定義

- 預警門檻：`±0.3`，依 PW1 的 A／B／C／D 狀態轉換統計採用。
- 確認門檻：`±0.611888`，沿用 `FT3-Q75-v1`。
- 改善預警：橙色。
- 惡化預警：草黃色 `#9AAA32`。
- 改善確認：紅色。
- 惡化確認：綠色。
- 未滿 125 個有效 observation 時不顯示，但內部階段仍從第一筆有效 `simFitTrend` 開始滾動。

SwiftData 以 `Trade.simFitTrendPhaseRaw` 保存穩定整數值：

| Raw value | 階段 | UI |
|---:|---|---|
| 0 | 不可用 | 隱藏 |
| 1 | 中性／重置 | 隱藏 |
| 2 | 改善預警 | 橙色上箭頭 |
| 3 | 惡化預警 | 草黃色下箭頭 |
| 4 | 改善確認 | 紅色上箭頭 |
| 5 | 惡化確認 | 綠色下箭頭 |
| 6 | 改善確認後退回 | 隱藏 |
| 7 | 惡化確認後退回 | 隱藏 |

## 滾動與即時更新

每筆 Trade 只讀取前一交易日保存的階段及目前 `simFitTrend`，不向前搜尋。前一筆階段缺失時，視為狀態序列第一筆，直接依當日數值初始化；完整重播後若中途仍意外缺值，視為程式錯誤。

同一交易日 Yahoo 多次更新時，不保存盤中曾經經過的路徑。每次都以「前一交易日階段＋目前盤中數值」覆寫同一筆 Trade，避免結果受查詢次數影響，並與每日歷史資料及 Baseline 保持一致。當日欄位描述目前 `simUpdate` 完成後的狀態；收盤資料到達後成為當日最終狀態。

目前買賣規則不讀取這個階段。未來若實驗要讓當日規則引用，必須另行定義規則判斷前的計算順序，不能用買賣完成後才形成的狀態反推同一次決策。

## S22 與儲存資料

`S22` 新增持久趨勢階段，但不改變現行策略結果。各類資料依下列方式處理：

| 儲存資料 | 處理方式 |
|---|---|
| 正式 App `default.store` | 發布時由 S21 完整重播至 S22，沿用人工反轉與加碼保存／重新驗證流程。 |
| 集中資料池 `pool.store` | schema 與產生程式支援新欄位；目前不開啟、不重算、不標示為 S22。重組樣本前才以當時最新 S 完整重播。 |
| A／B／C／D Baseline 輸入 | 後續從資料池重新產生，保持相同股票、T2、日期、窗口、資金與加碼設定，再完整執行 S22。 |
| A／B／C／D 固定三年 Baseline | 後續重建為規則檢驗基準；先以 Sample A 確認與 S21 零策略差異，再推進 B／C／D。 |
| A／B／C／D DecisionBase | 隨 S22 固定三年 Baseline 重建為 v5，旁錄決策前已完成的趨勢階段。 |
| 全期間壓力測試 | 目前擱置；S22 正式成為新 Baseline 時再產生。 |
| `browse.store`、`period-*.store` | 不遷移舊檔；新 Baseline 執行時自然產生新副本。 |
| 舊 Baseline、報告與 Candidate Delta | 永久保留原 T／S 語意，不改 schema、不覆寫。 |
| 舊 TechnicalBase、Sample C 評估與暫存 store | 保留或按既有週期清除；未來若仍要使用，從最新來源重新產生，不批次改寫舊證據。 |
| 13 吋文件展示資料 | 實際 store 仍為 S0 且缺少新欄位；只有其獨立副本完成 schema 與八檔 S22 驗證。下次文件工作須重新建制，不得把現有展示 store 視為已遷移。 |
| 13 吋固定瀏覽、10 吋確認機與實體機 | 目前擱置；需要時以當時最新 App 重新建制或遷移。 |

集中資料池只保存可共用行情與 T 作為主要來源。即使其 schema 已支援 `simFitTrendPhaseRaw`，未完整執行 S22 前不得提高 Stock 的 simulation state version；建立新 Baseline 時也必須重置衍生模擬狀態並從窗口起點完整重播，不能把資料池的預設 raw value 當成有效階段。

## DecisionBase 時序

SwiftData Trade 保存當日 `simUpdate` 完成後的階段。DecisionBase 的決策事件發生在當日模擬完成前，因此 v5 `strategy_fit_observations.fit_trend_phase` 保存的是決策前已完成階段，與既有 Grade decision-time 旁錄原則一致。當日完成後的階段仍可由 S22 `browse.store` 的 Trade 取得；兩者不得混稱。

## 任務與狀態

| 任務代號 | 內容 | 狀態 |
|---|---|---|
| PW-S22-1 | 新增 SwiftData raw 欄位、階段 enum、逐日滾動與缺值初始化。 | 完成，狀態測試通過 |
| PW-S22-2 | 讓 Grade 趨勢 UI 改讀持久階段，確認後退回時隱藏。 | 完成，待正式展示資料人工確認 |
| PW-S22-3 | 推進 S22，保留 T2 與現行買賣規則。 | 完成，受控零策略差異測試通過 |
| PW-S22-4 | DecisionBase 增加階段欄位並推進格式 v5。 | 程式完成，尚未重建正式 DecisionBase |
| PW-S22-5 | 以 expendable store 驗證 SwiftData schema 遷移與狀態轉換。 | 完成；展示 store 不是合格 S21 對照 |
| PW-S22-6 | 遷移集中資料池 schema，不執行資料池 S22。 | 擱置，未執行 |
| PW-S22-7 | 重建 A／B／C／D 固定三年 S22 Baseline 與 DecisionBase。 | 擱置，未執行 |
| PW-S22-8 | 更新 13 吋、10 吋、文件展示及實體機。 | 文件用 13 吋已安裝；其餘擱置 |
| PW-S22-9 | 產生 S22 全期間壓力測試並正式更新 Baseline 歷史。 | 擱置，未執行 |

本輪已完成程式、文件、建置及 PW-S22-5 最小驗證。文件用 13 吋 Simulator 曾覆蓋安裝新版 App，但其實際 store 並未完成 schema 遷移；只有複製到獨立測試機的八檔副本完成 S22。尚未處理資料池、Baseline 或正式 DecisionBase，也尚未發布。

## 重大 schema 遷移風險備忘

以下檢查適用於本專案未來任何資料重建、匯入、還原、測試或發布工作。看到舊 `.store` 時，必須先記得 S22 已改變 SwiftData schema，不能只看檔名或 App 畫面判斷版本。

- 正式 SwiftData store 位於 App container 的 `Library/Application Support/default.store`；`Documents/default.store` 或 `Documents/DocumentationScreenshotSeed/` 只是匯入／種子來源。放錯位置時 App 仍可能正常啟動並另外建立空 store，造成假成功。
- schema 欄位存在只證明結構可開啟；`simFitTrendPhaseRaw == 0` 可能是合法不可用狀態，也可能只是尚未重播。必須另外核對目標 Stock 的 `simulationStateVersion == 22`、重播完成訊息及狀態分布。
- 遷移以股票為單位進行，中斷時同一 store 可能同時存在 S22 與舊版本。只核對一檔、只看最大版本或固定等待數十秒都不夠；應限定目標股群逐檔確認，讓工作自然完成。
- App 啟動時可能補入未選取的股票目錄，這些 Stock 可維持版本 `0`。核對展示、Baseline 或正式股群時應依原始股票代號／主鍵限定範圍，不得要求整張 `ZSTOCK` 都是 S22。
- S21／S22 零策略差異只能使用有可信版本標記、相同輸入與完整 S21 結果的受控副本。S0、來源不明、未完成模擬或只供截圖的 store 即使畫面有交易，也不能冒充 S21 對照。
- 複製 WAL 模式 SQLite 時要使用一致的 SQLite backup，或在確認 `-wal` 已清空後連同必要 sidecar 處理；單獨複製主檔可能遺漏最後交易或 metadata。唯讀診斷需要避免建立 sidecar 時，可使用 SQLite immutable URI。
- S22 store 不提供舊 App 向下相容保證。不得用 S21 或更舊 App 覆蓋安裝後直接開啟已遷移的正式 store；需要回退程式時仍須保留 S22 schema 相容性或先使用獨立備份演練。
- 集中資料池目前只完成程式與 schema 支援，未執行 S22；A／B／C／D Baseline、DecisionBase v5、`browse.store`、`period-*.store`、固定瀏覽副本、10 吋及實體機也尚未全面處理。任何後續任務引用它們前都要先回到本表確認狀態。
- DecisionBase v5 增加 `fit_trend_phase`；舊分析器、SQL、匯出器或 fixture 若仍假設 v4 欄位數，必須先更新或明確拒絕 v5，不能靜默錯欄。
- 從備份還原、換機或重新匯入舊 store 後，即使同一 App 曾完成過 S22，也要依還原進來的 Stock 版本重新觸發遷移，不得信任裝置層級的既往完成狀態。

## PW-S22-5 最小驗證結果（2026-08-21）

- `StrategyFitTests` 已通過預警、確認、冷卻、重置、暖機隱藏與初始狀態測試。
- `RecalculationTests` 已通過 `S13 → S22`、`T1/S9 → T2/S22` 完整重播及人工反轉／加碼重驗。
- DecisionBase v5 旁錄開關前後的模擬輸出一致，確認新增趨勢狀態不介入買賣規則。
- 以 13 吋文件展示資料庫的副本在獨立測試機驗證：SwiftData 可原位增加 `simFitTrendPhaseRaw`，原始 8 檔皆完成 `S22`，19,519 筆 Trade 中有 17,497 筆寫入非初始狀態。
- 該展示資料庫原版本標記為 `S0`，不是合格的 `S21` 策略對照；完整重播造成既有模擬欄位大量變動，因此不拿它判斷 `S21／S22` 策略差異。策略零差異結論以受控測試為準。
- 本次未重建集中資料池、A／B／C／D Baseline，也未更新 10 吋或實體機。
