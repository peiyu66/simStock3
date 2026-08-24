# Grade 趨勢預警狀態持久化計畫

## 目標

Grade 趨勢圖示分成預警與確認。預警只描述趨勢由中性區往確認門檻前進，不在確認後退回相同數值區間時再次出現。這是 `simUpdate` 產生的每日滾動狀態；S22 建立時只供 UI 與研究旁錄，後續 S23～S27 已由正式 H-N11、S-P07、L-P10 與 H-N01a 讀取決策前階段，因此不再只是顯示資料。

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

`simUpdate` 在買賣判斷前固定以前一交易日的 EMA／階段，加上今日價格與買賣前庫存，建立只存在記憶體的決策前趨勢；S23 起正式規則可讀取這份決策前狀態。買賣完成後，既有 `updateStrategyFitState` 仍從同一份前日狀態及買賣後資料重算並保存當日最終趨勢，供 UI 與次一交易日使用。兩次計算彼此不串接，決策前暫算不寫入 SwiftData，也不增加 observation；同一交易日 Yahoo 重算仍只使用前一交易日狀態與目前價格。

## S22 與儲存資料

`S22` 新增持久趨勢階段，但不改變現行策略結果。各類資料依下列方式處理：

| 儲存資料 | 處理方式 |
|---|---|
| 正式 App `default.store` | S22 首次發布後依資料規則持續遷移；S27 發布時須完整重播 `simUpdate`，沿用人工反轉與加碼保存／重新驗證流程。 |
| 集中資料池 `pool.store` | schema 與產生程式支援新欄位；目前不開啟、不重算、不標示為 S22。重組樣本前才以當時最新 S 完整重播。 |
| A／B／C／D Baseline 輸入 | 已維持相同股票、T2、日期、窗口、資金與加碼設定重播；現行正式版本為 ABCD v9、`T2/S27`。 |
| A／B／C／D 固定三年 Baseline | S22 零策略差異驗證完成；後續已推進至現行 S27 Baseline v9。 |
| A／B／C／D DecisionBase | v5 已隨各版固定三年 Baseline 重建；現行四組為 S27，均完成 P4b。 |
| 全期間壓力測試 | S22 正式切換時已完成；現行 S27 A／B／C／D 全期間報告也已完成。 |
| `browse.store`、`period-*.store` | 不遷移舊檔；現行 S27 Baseline 已自然產生新副本。 |
| 舊 Baseline、報告與 Candidate Delta | 永久保留原 T／S 語意，不改 schema、不覆寫。 |
| 舊 TechnicalBase、Sample C 評估與暫存 store | 保留或按既有週期清除；未來若仍要使用，從最新來源重新產生，不批次改寫舊證據。 |
| 13 吋文件展示資料 | 實際 store 仍為 S0 且缺少新欄位；只有其獨立副本完成 schema 與八檔 S22 驗證。下次文件工作須重新建制，不得把現有展示 store 視為已遷移。 |
| 13 吋固定瀏覽、10 吋確認機與實體機 | 13 吋固定瀏覽已更新至 S27 Baseline v9；10 吋一般確認資料與實體機待需要時以最新 App 遷移。 |

集中資料池只保存可共用行情與 T 作為主要來源。即使其 schema 已支援 `simFitTrendPhaseRaw`，未完整執行 S22 前不得提高 Stock 的 simulation state version；建立新 Baseline 時也必須重置衍生模擬狀態並從窗口起點完整重播，不能把資料池的預設 raw value 當成有效階段。

## DecisionBase 時序

SwiftData Trade 保存當日 `simUpdate` 完成後的階段。DecisionBase 的決策事件發生在當日模擬完成前，因此 v5 `strategy_fit_observations.fit_trend_phase` 保存的是決策前已完成階段，與既有 Grade decision-time 旁錄原則一致。當日完成後的階段仍可由 S22 `browse.store` 的 Trade 取得；兩者不得混稱。

## 任務與狀態

| 任務代號 | 內容 | 狀態 |
|---|---|---|
| PW-S22-1 | 新增 SwiftData raw 欄位、階段 enum、逐日滾動與缺值初始化。 | 完成，狀態測試通過 |
| PW-S22-2 | 讓 Grade 趨勢 UI 改讀持久階段，確認後退回時隱藏。 | 完成，已由 Simulator 與實體機使用確認 |
| PW-S22-3 | 推進 S22，保留 T2 與現行買賣規則。 | 完成，受控零策略差異測試通過 |
| PW-S22-4 | DecisionBase 增加階段欄位並推進格式 v5。 | 完成；現行 S27 四組 DecisionBase 與 P4b 已重建 |
| PW-S22-5 | 以 expendable store 驗證 SwiftData schema 遷移與狀態轉換。 | 完成；展示 store 不是合格 S21 對照 |
| PW-S22-6 | 遷移集中資料池 schema，不執行資料池 S22。 | 依設計延後；下次重組樣本前以當時最新 S 處理 |
| PW-S22-7 | 重建 A／B／C／D 固定三年 S22 Baseline 與 DecisionBase。 | A／B／C／D 全部完成 |
| PW-S22-8 | 更新 13 吋、10 吋、文件展示及實體機。 | 13 吋固定瀏覽已更新至 S27；文件展示、10 吋一般資料與實體機按需重建或遷移 |
| PW-S22-9 | 產生 S22 全期間壓力測試並正式更新 Baseline 歷史。 | 完成 |

S22 原始工作已完成程式、文件、最小 schema 驗證、A／B／C／D Baseline、全期間與 DecisionBase v5；其後正式規則持續推進，目前為 S27 Baseline v9。集中資料池仍依設計延後到下次重組樣本前更新；文件展示、10 吋一般資料與實體機不因 Baseline 更新而自動視為已遷移，仍須按各自用途確認。

## 重大 schema 遷移風險備忘

以下檢查適用於本專案未來任何資料重建、匯入、還原、測試或發布工作。看到舊 `.store` 時，必須先記得 S22 已改變 SwiftData schema，不能只看檔名或 App 畫面判斷版本。

- 正式 SwiftData store 位於 App container 的 `Library/Application Support/default.store`；`Documents/default.store` 或 `Documents/DocumentationScreenshotSeed/` 只是匯入／種子來源。放錯位置時 App 仍可能正常啟動並另外建立空 store，造成假成功。
- schema 欄位存在只證明結構可開啟；`simFitTrendPhaseRaw == 0` 可能是合法不可用狀態，也可能只是尚未重播。必須另外核對目標 Stock 已完成當時要求的 simulation state version（目前正式 App 為 S27）、重播完成訊息及狀態分布。
- 遷移以股票為單位進行，中斷時同一 store 可能同時存在 S22 與舊版本。只核對一檔、只看最大版本或固定等待數十秒都不夠；應限定目標股群逐檔確認，讓工作自然完成。
- App 啟動時可能補入未選取的股票目錄，這些 Stock 可維持版本 `0`。核對展示、Baseline 或正式股群時應依原始股票代號／主鍵限定範圍，不得要求整張 `ZSTOCK` 都是 S22。
- S21／S22 零策略差異只能使用有可信版本標記、相同輸入與完整 S21 結果的受控副本。S0、來源不明、未完成模擬或只供截圖的 store 即使畫面有交易，也不能冒充 S21 對照。
- 複製 WAL 模式 SQLite 時要使用一致的 SQLite backup，或在確認 `-wal` 已清空後連同必要 sidecar 處理；單獨複製主檔可能遺漏最後交易或 metadata。唯讀診斷需要避免建立 sidecar 時，可使用 SQLite immutable URI。
- S22 store 不提供舊 App 向下相容保證。不得用 S21 或更舊 App 覆蓋安裝後直接開啟已遷移的正式 store；需要回退程式時仍須保留 S22 schema 相容性或先使用獨立備份演練。
- 集中資料池目前只完成程式與 schema 支援，尚未完整重播最新 S；A／B／C／D Baseline、DecisionBase v5、`browse.store`、`period-*.store` 與 13 吋固定瀏覽已更新至 S27。文件展示、10 吋一般資料與實體機仍須在使用前確認或遷移。
- DecisionBase v5 增加 `fit_trend_phase`；舊分析器、SQL、匯出器或 fixture 若仍假設 v4 欄位數，必須先更新或明確拒絕 v5，不能靜默錯欄。
- 從備份還原、換機或重新匯入舊 store 後，即使同一 App 曾完成過 S22，也要依還原進來的 Stock 版本重新觸發遷移，不得信任裝置層級的既往完成狀態。

## PW-S22-5 最小驗證結果（2026-08-21）

- `StrategyFitTests` 已通過預警、確認、冷卻、重置、暖機隱藏與初始狀態測試。
- `RecalculationTests` 已通過 `S13 → S22`、`T1/S9 → T2/S22` 完整重播及人工反轉／加碼重驗。
- DecisionBase v5 旁錄開關前後的模擬輸出一致，確認新增趨勢狀態不介入買賣規則。
- 以 13 吋文件展示資料庫的副本在獨立測試機驗證：SwiftData 可原位增加 `simFitTrendPhaseRaw`，原始 8 檔皆完成 `S22`，19,519 筆 Trade 中有 17,497 筆寫入非初始狀態。
- 該展示資料庫原版本標記為 `S0`，不是合格的 `S21` 策略對照；完整重播造成既有模擬欄位大量變動，因此不拿它判斷 `S21／S22` 策略差異。策略零差異結論以受控測試為準。
- 本次未重建集中資料池、A／B／C／D Baseline，也未更新 10 吋或實體機。

## PW-S22-7A Sample A 結果（2026-08-21）

- 固定三年 run ID：`baseline-a-v4-s18-ln02-low-prior-trend-t2s22-9y-fixed3y-600w-20260821`。
- DecisionBase ID：`a-abcd9-v2-s18-ln02-low-prior-trend-20260821-t2-s22-a835c66d9dc1-fixed3y-20260722-v5`。
- 規則 commit：`a835c66d9dc15932d52da6e42d484a65951b76cd`；策略仍為 `s18-ln02-low-prior-trend-20260821`，唯一資料變動是 `T2/S21 → T2/S22`。
- 原 v2 input 已不在工作區或現存 Simulator；本次使用正式 S21 Sample A 報告的第一窗口 `browse.store` 作 T2 技術基底，預先建立 T2 complete marker，未重算 `tUpdate`。其中既有 S21 模擬欄位在每個窗口起點全部重置，再由 S22 完整重播，不直接沿用。
- S22 與 S21 的 `periods.csv` 位元級一致；較強股群 `73.355241`、較弱股群 `6.074071`、合計 `79.429311`，10 股、三窗口、24,350 筆 Trade、0 無效值、0 無成交排除。
- DecisionBase v5 的 94,653 個事件、156,589 張非零票、50,356 個 gate 與 30 筆期末結果，和 S21 v4 雙向逐列零差異；SQLite `integrity_check` 為 `ok`、外鍵錯誤 0，P4b 完成。
- v5 保存 21,902 筆適配趨勢 observation；階段 raw 0～7 的筆數依序為 `68／1167／217／258／10506／9302／209／175`。Sample A 證明 S22 新欄位有實際內容且不介入買賣決策。
- 本節只完成 Sample A 確認節點；在 B／C／D 完成前，現行 A／B／C／D 正式 Baseline 仍以 T2/S21 v3 為準，不提前改寫現行清單或 Baseline 歷史。

## PW-S22-7B Sample B 結果（2026-08-21）

- 固定三年 run ID：`baseline-b-v4-s18-ln02-low-prior-trend-t2s22-9y-fixed3y-600w-20260821`。
- DecisionBase ID：`b-abcd9-v2-s18-ln02-low-prior-trend-20260821-t2-s22-a835c66d9dc1-fixed3y-20260722-v5`。
- 使用與 A 相同的受控方式：正式 S21 Sample B 第一窗口 `browse.store` 只作固定 T2 技術基底，預先建立 T2 complete marker，不重算 `tUpdate`；每個窗口完整重置並重播 S22。
- S22 與 S21 的 `periods.csv` 位元級一致；較強股群 `70.601961`、較弱股群 `7.845028`、合計 `78.446988`，10 股、三窗口、24,350 筆 Trade、0 無效值、0 無成交排除。
- DecisionBase v5 的 94,350 個事件、155,585 張非零票、52,894 個 gate 與 30 筆期末結果，和 S21 v4 雙向逐列零差異；SQLite `integrity_check` 為 `ok`、外鍵錯誤 0，P4b 完成。
- v5 保存 21,900 筆適配趨勢 observation；階段 raw 0～7 的筆數依序為 `83／921／189／202／9627／10566／154／158`。Sample B 再次確認 S22 只有新增持久顯示狀態，沒有改變策略路徑。
- 目前只有 A／B 完成；C／D 尚未重建，因此現行正式 Baseline 仍維持 T2/S21 v3。

## PW-S22-7C／7D 結果（2026-08-21）

- Sample C run ID：`baseline-c-v4-s18-ln02-low-prior-trend-t2s22-9y-fixed3y-600w-20260821`；DecisionBase ID：`c-abcd9-v2-s18-ln02-low-prior-trend-20260821-t2-s22-a835c66d9dc1-fixed3y-20260722-v5`。
- Sample C 較強／較弱／合計主分為 `74.793911／6.428611／81.222522`；94,180 個事件、153,627 張非零票、50,361 個 gate、30 筆期末結果都與 S21 v4 雙向逐列零差異。21,797 筆趨勢 observation 的 raw 0～7 分布為 `82／1066／180／257／9723／10143／186／160`。
- Sample D run ID：`baseline-d-v4-s18-ln02-low-prior-trend-t2s22-9y-fixed3y-600w-20260821`；DecisionBase ID：`d-abcd9-v2-s18-ln02-low-prior-trend-20260821-t2-s22-a835c66d9dc1-fixed3y-20260722-v5`。
- Sample D 較強／較弱／合計主分為 `75.221292／5.758477／80.979769`；95,197 個事件、155,689 張非零票、50,155 個 gate、30 筆期末結果都與 S21 v4 雙向逐列零差異。21,878 筆趨勢 observation 的 raw 0～7 分布為 `51／1038／164／287／10242／9687／207／202`。
- C／D 均使用正式 S21 第一窗口 `browse.store` 作固定 T2 技術基底、未重算 `tUpdate`；每個窗口重置模擬後完整重播 S22。兩組 `periods.csv` 都與 S21 位元級一致，SQLite `integrity_check`、外鍵與 P4b 完成檢查全部通過。

## PW-S22-7 四樣本結論

- A／B／C／D 的 40 檔、12 個固定三年窗口已全部完成 T2/S22 重播與 DecisionBase v5。
- 四組合計 378,380 個決策事件、621,490 張非零票、203,766 個 gate、120 筆期末結果，和 S21 v4 全部雙向逐列零差異；87,477 筆趨勢 observation 已具備持久階段。
- 這足以確認 S22 schema 與趨勢階段只增加 UI／研究狀態，不改變正式 S18 買賣策略；Sample A 的確認節點已成功外推至 B／C／D。
- 固定三年 v4 與 DecisionBase v5 產物已保存在本機 `exports`。集中資料池仍維持原狀，只有在未來重組樣本前才執行當時最新 S。

## PW-S22-9 全期間與正式切換（2026-08-21）

- A／B／C／D 全期間 S22 主分依序為 `70.333264／70.220659／78.691260／77.500357`，全部與 S21 v3 相同；四份 `periods.csv` 均位元級一致，0 無效值、0 無成交排除。
- 固定三年與全期間證據都確認策略零差異後，正式 Baseline 切換為 ABCD v4、`T2/S22`、策略 `s18-ln02-low-prior-trend-20260821`、規則 commit `a835c66d9dc15932d52da6e42d484a65951b76cd`。
- `doc/現行回測規則.md` 與 `doc/Baseline歷史.md` 已改指向 v4 固定三年及全期間報告；v3 永久保留 S18 採用時的原始策略證據，不覆寫或改稱 S22。
- 集中資料池、10 吋、實體機與其他固定瀏覽副本不因 Baseline 正式切換而自動視為 S22；仍依各自任務狀態處理。
