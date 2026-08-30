# NR13 剩餘長期套牢研究工具封存

本目錄封存 `NR13-D0-CD` 的描述性研究工具。它不是日常回測 runner，也不代表仍有排隊中的候選；保留目的只是重現 `S-T02g` 與 `G-M02` 採用後，Sample C／D 剩餘長期套牢的 Grade、ROI、等待日數、後續加碼及最終賣出結果。

- `nr13_remaining_long_holding_study.py`：從 Baseline v16、`T2/S35` 的 Sample C／D DecisionBase v6 建立 120／240／360 日檢查點，並以獨立持股週期避免重複計數。
- 原始研究輸出：`exports/holding-waiting-value-study/nr13-d0-cd-remaining-long-holding-t2s35-20260830/`。

分類條件只使用檢查日以前資料，但最終 ROI、實際賣出、等待日數與後續加碼都是事後結果，只能形成候選假設，不能直接當成可交易訊號或候選分數。研究結果未找到 C／D 共同支持較早認賠的連續 Grade 邊界，因此已結案且沒有建立候選。

工具內的 DecisionBase 路徑與資料表假設固定於 Baseline v16／S28／T2-S35；日後若要重用，必須先確認 schema、規則版本與研究目的。正式判讀記錄在 [`doc/回測規則驗證.md`](../../../doc/回測規則驗證.md#nr13)。
