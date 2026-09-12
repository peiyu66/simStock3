# Baseline 歷史

> **2026/09/12 L-P12正式採用完成：T3/S51／策略S44／Baseline v32／DecisionBase v18。** 本機v3.4.5（72）與10.86吋十檔重算／九筆人工操作全保留；未push／發布。[採用紀錄](L-P12反彈後期採用紀錄-20260912.md)。下方較早「現行／已發布」為歷史，以[現行規則](現行回測規則.md#版本與重算)為準。

> **2026/09/11 已發布 v3.4.5（70）／T3/S50。** 65 項發布測試、Archive／Export、IPA 簽章、Git push 及 GitHub latest IPA／manifest 雜湊核對通過，遠端兩份資產實際下載也一致。從 S49 升級只重播 simUpdate、不重算 tUpdate，人工反轉／加碼保留並重驗；已完成 S50 者不因本次發布重播。10.2 吋正常資料 24,730 筆／110 欄及七筆人工操作未變。發布 commit `70026f59e8881bf574c236c5ae6ee67d68666053`；[發布證據](../exports/s50-publish-20260911/release-verification.json)。 Baseline v31／DecisionBase v17 與規則 commit 維持採用時身分；下方各版的發布敘述保留當時狀態。

本文件是 simStock3 正式回測對照基準的集中索引。現行規則與最新精確設定以[現行回測規則](現行回測規則.md)為準；候選的驗證過程、採用理由與風險見[回測規則驗證](回測規則驗證.md)。

## 閱讀方式

- 主表依正式產生時間排序，只列曾實際成為後續實驗對照的固定三年 Baseline；暫時候選不列入。
- A／B 分數是各自固定股票樣本的固定三年主分；括號內是相較前一個**同樣本** Baseline 的差異。A／B 絕對分數不能直接解讀為規則改善或退步。
- 固定三年是採用的主要依據；「全期」連結是從各版記錄的模擬起點連續跑到截止日的壓力測試。
- `T2` 重建改變固定技術輸入，並非只有一條策略規則變更，因此不把 A5d→T2 的分數差寫成單一規則效果。
- `—` 表示當時尚未建立該樣本、尚未分記 T／S，或沒有對應的標準化報告。

## 固定三年 Baseline 主脈絡

| 策略版本 | 日期 | 本版規則變更 | 資料規則／commit | Sample A 固定三年 | Sample B 固定三年 | 完整報告 |
|---|---|---|---|---:|---:|---|
| H-final | 2026/07/26 | H-P04 只保留成交量條件；移除兩條低可信度的極端均線加分 H-R01／02 | 尚未分記 | 100.600（起點） | — | [A 固定](../exports/backtest-reports/baseline-h-final-fixed3y-600w-20260726/report.html) |
| L-interim | 2026/07/26 | 合併早期 L1～L6b：限制 J／K 重複加分、移除無效分支，L-P06 只保留成交量 | 尚未分記 | 101.175（+0.575） | — | [A 固定](../exports/backtest-reports/baseline-l-interim-fixed3y-600w-20260726/report.html) · [A 全期](../exports/backtest-reports/baseline-l-interim-fullstress-600w-20260726/report.html) |
| L6-combined | 2026/07/26 | L-P08 只保留高價位置、L-N01 門檻改為 -20，並移除會錯過反彈的 L-R02 | 尚未分記 | 104.893（+3.719） | — | [A 固定](../exports/backtest-reports/baseline-l6-combined-fixed3y-600w-20260726/report.html) · [A 全期](../exports/backtest-reports/baseline-l6-combined-fullstress-600w-20260726/report.html) |
| H7b | 2026/07/26 | 移除原 H-N04 均線半年極端扣分，退出為 H-R03 | 尚未分記 | 106.670（+1.777） | — | [A 固定](../exports/backtest-reports/baseline-h7b-fixed3y-600w-20260726/report.html) · [A 全期](../exports/backtest-reports/baseline-h7b-fullstress-600w-20260726/report.html) |
| S1a/S3d/S4c | 2026/07/27 | 移除重複惜賣 S-R01；K／D 過熱只看 125 日 Z；九日低點惜賣只保留 MA20／MA60 | 尚未分記 | 107.203（+0.533） | — | [A 固定](../exports/backtest-reports/baseline-s1a-s3d-s4c-fixed3y-600w-20260727/report.html) · [A 全期](../exports/backtest-reports/baseline-s1a-s3d-s4c-fullstress-600w-20260727/report.html) |
| S6a | 2026/07/27 | 移除均線偏強時額外提高三層獲利出口 ROI 門檻的 S-R02 | 尚未分記 | 112.062（+4.859） | — | [A 固定](../exports/backtest-reports/baseline-s6a-fixed3y-600w-20260727/report.html) · [A 全期](../exports/backtest-reports/baseline-s6a-fullstress-600w-20260727/report.html) |
| S2c | 2026/07/27 | 高評等 S-N02 改以收盤相對昨收漲幅判斷；一般評等 S-N03 不變 | 尚未分記 | 113.950（+1.888） | — | [A 固定](../exports/backtest-reports/baseline-s2c-fixed3y-600w-20260727/report.html) · [A 全期](../exports/backtest-reports/baseline-s2c-fullstress-600w-20260727/report.html) |
| A5d | 2026/07/28 | 限制 L 深度虧損重複加分，並移除長期 L 的 -15% 寬鬆加碼資格 | 尚未分記 | 117.179（+3.229） | — | [A 固定](../exports/backtest-reports/baseline-a5d-fixed3y-600w-20260728/report.html) · [A 全期](../exports/backtest-reports/baseline-a5d-fullstress-600w-20260728/report.html) |
| T2／S3 | 2026/07/29 | 重建成交量技術基底：`v` 欄位統一採包含當日且僅限正式 TWSE 日的合格序列；策略沿用 A5d | T2/S3 | 112.469（不可作單一規則差異） | — | [A 固定](../exports/backtest-reports/baseline-t2-volume-fixed3y-600w-20260729/report.html) · [A 全期](../exports/backtest-reports/baseline-t2-volume-fullstress-600w-20260729/report.html) |
| S4 | 2026/07/29 | H-P04 改看前一完整 TWSE 日的爆量，由當日整體 H 條件確認買入 | T2/S4 | 114.044（+1.575） | — | [A 固定](../exports/backtest-reports/baseline-s4-volume-confirm-fixed3y-600w-20260729/report.html) · [A 全期](../exports/backtest-reports/baseline-s4-volume-confirm-fullstress-600w-20260729/report.html) |
| S5 | 2026/07/30 | 新增 S-N05：fine 以上遇 `vZ125 > 1` 時惜賣一分 | T2/S5 | 114.970（+0.926） | — | [A 固定](../exports/backtest-reports/baseline-s5-volume-hold-fixed3y-600w-20260730/report.html) · [A 全期](../exports/backtest-reports/baseline-s5-volume-hold-fullstress-600w-20260730/report.html) |
| S6 | 2026/07/30 | 新增 H-N10：當日為九日最低量時 H買扣一分 | T2/S6 · [`ae5c1f3`](https://github.com/peiyu66/simStock3/commit/ae5c1f327da27daae3b1d6b7136b9c24a0e4cf81) | 115.747（+0.778） | 41.321（B 起點） | [A 固定](../exports/backtest-reports/baseline-s6-volume-low-veto-fixed3y-600w-20260730/report.html) · [A 全期](../exports/backtest-reports/baseline-s6-volume-low-veto-fullstress-600w-20260730/report.html) · [B 固定](../exports/backtest-reports/baseline-b-s6-volume-low-veto-fixed3y-600w-20260802/report.html) · [B 全期](../exports/backtest-reports/baseline-b-s6-volume-low-veto-fullstress-600w-20260802/report.html) |
| S7 | 2026/08/02 | Grade 改採與回測一致的效率分數，並校準七級分界 | T2/S7 · [`8a47068`](https://github.com/peiyu66/simStock3/commit/8a47068590effb1dee5cbf347b9085e0bf4c3a55) | 114.031（-1.716） | 41.207（-0.114） | [A 固定](../exports/backtest-reports/baseline-s7-score-grade-fixed3y-600w-20260802/report.html) · [A 全期](../exports/backtest-reports/baseline-s7-score-grade-fullstress-600w-20260802/report.html) · [B 固定](../exports/backtest-reports/baseline-b-s7-score-grade-fixed3y-600w-20260802/report.html) · [B 全期](../exports/backtest-reports/baseline-b-s7-score-grade-fullstress-600w-20260802/report.html) |
| S8 | 2026/08/03 | S-N05 放量惜賣由 fine 以上收窄為 high／wow | T2/S8 · [`54d4167`](https://github.com/peiyu66/simStock3/commit/54d41671dfad273e2f11381d04e679917a7621bd) | 114.463（+0.432） | 41.967（+0.760） | [A 固定](../exports/backtest-reports/baseline-s8-sn05-high-grade-fixed3y-600w-20260803/report.html) · [A 全期](../exports/backtest-reports/baseline-s8-sn05-high-grade-fullstress-600w-20260803/report.html) · [B 固定](../exports/backtest-reports/baseline-b-s8-sn05-high-grade-fixed3y-600w-20260803/report.html) · [B 全期](../exports/backtest-reports/baseline-b-s8-sn05-high-grade-fullstress-600w-20260803/report.html) |
| S9 | 2026/08/09 | A-N01 對 none 以上的加碼扣分由 -2 放寬為 -1 | T2/S9 · [`01333b2`](https://github.com/peiyu66/simStock3/commit/01333b21032ac743a0dbe48eb89caad8fe43de1b) | 116.476（+2.013） | 43.146（+1.179） | [A 固定](../exports/backtest-reports/baseline-s9-an01-penalty-m1-fixed3y-600w-20260809/report.html) · [A 全期](../exports/backtest-reports/baseline-s9-an01-penalty-m1-fullstress-600w-20260809/report.html) · [B 固定](../exports/backtest-reports/baseline-b-s9-an01-penalty-m1-fixed3y-600w-20260809/report.html) · [B 全期](../exports/backtest-reports/baseline-b-s9-an01-penalty-m1-fullstress-600w-20260809/report.html) |
| S10 | 2026/08/10 | S-T01c 賣出分數門檻由至少 5 分放寬為至少 4 分 | T2/S11 · [`aa396a9`](https://github.com/peiyu66/simStock3/commit/aa396a941a878f0a2d5e9483d088dbb046f4c50d) | 123.489（+7.013） | 48.879（+5.733） | [A 固定](../exports/backtest-reports/baseline-s10-st01c-score4-fixed3y-600w-20260810/report.html) · [A 全期](../exports/backtest-reports/baseline-s10-st01c-score4-fullstress-600w-20260810/report.html) · [B 固定](../exports/backtest-reports/baseline-b-s10-st01c-score4-fixed3y-600w-20260810/report.html) · [B 全期](../exports/backtest-reports/baseline-b-s10-st01c-score4-fullstress-600w-20260810/report.html) |
| S11 | 2026/08/11 | S-T01c ROI 門檻依動態 Grade 路由：wow 2.25%、none～high 2.0%、weak 以下 1.5% | T2/S12 · [`5af886a`](https://github.com/peiyu66/simStock3/commit/5af886af33f88e8f8feffda5dfcd28a2c77eb4ab) | 126.953（+3.464） | 50.873（+1.993） | [A 固定](../exports/backtest-reports/baseline-s11-st01c-grade-roi-fixed3y-600w-20260811/report.html) · [A 全期](../exports/backtest-reports/baseline-s11-st01c-grade-roi-fullstress-600w-20260811/report.html) · [B 固定](../exports/backtest-reports/baseline-b-s11-st01c-grade-roi-fixed3y-600w-20260811/report.html) · [B 全期](../exports/backtest-reports/baseline-b-s11-st01c-grade-roi-fullstress-600w-20260811/report.html) |
| S12 | 2026/08/12 | S-T01e 長期小幅獲利退出由 75 日提前至 68 日 | T2/S13 · [`e20ea0c`](https://github.com/peiyu66/simStock3/commit/e20ea0cfe1bac7d864f7d157dd9c37b3857e0dac) | 129.187（+2.234） | 51.441（+0.568） | [A 固定](../exports/backtest-reports/baseline-s12-st01e-days68-fixed3y-600w-20260812/report.html) · [A 全期](../exports/backtest-reports/baseline-s12-st01e-days68-fullstress-600w-20260812/report.html) · [B 固定](../exports/backtest-reports/baseline-b-s12-st01e-days68-fixed3y-600w-20260812/report.html) · [B 全期](../exports/backtest-reports/baseline-b-s12-st01e-days68-fullstress-600w-20260812/report.html) |
| S13 | 2026/08/13 | A-E01 一般加碼冷卻由 45 日縮短為 38 日 | T2/S14 · [`35e95fd`](https://github.com/peiyu66/simStock3/commit/35e95fd05a577db7cc1ec3bad7be808bae486e52) | 132.955（+3.768） | 52.004（+0.564） | [A 固定](../exports/backtest-reports/baseline-s13-ae01-days38-fixed3y-600w-20260813/report.html) · [A 全期](../exports/backtest-reports/baseline-s13-ae01-days38-fullstress-600w-20260813/report.html) · [B 固定](../exports/backtest-reports/baseline-b-s13-ae01-days38-fixed3y-600w-20260813/report.html) · [B 全期](../exports/backtest-reports/baseline-b-s13-ae01-days38-fullstress-600w-20260813/report.html) |
| S14 | 2026/08/13 | A-P01b 無條件加碼分由 weak 以下收窄為 low 以下 | T2/S15 · [`a21b386`](https://github.com/peiyu66/simStock3/commit/a21b386888ef6807ccdca12e0b2ee99ff650a791) | 132.955（+0.000） | 52.578（+0.574） | [A 固定](../exports/backtest-reports/baseline-s14-ap01b-low-fixed3y-600w-20260813/report.html) · [A 全期](../exports/backtest-reports/baseline-s14-ap01b-low-fullstress-600w-20260813/report.html) · [B 固定](../exports/backtest-reports/baseline-b-s14-ap01b-low-fixed3y-600w-20260813/report.html) · [B 全期](../exports/backtest-reports/baseline-b-s14-ap01b-low-fullstress-600w-20260813/report.html) |
| S15 | 2026/08/13 | A-T01 深虧門檻依動態 Grade 路由：none 以上 -32.5%，weak 以下維持 -30% | T2/S16 · [`6f8ca49`](https://github.com/peiyu66/simStock3/commit/6f8ca490e00473b1b34e4c0d741cf9e95cc493ad) | 133.447（+0.491） | 52.784（+0.205） | [A 固定](../exports/backtest-reports/baseline-s15-at01-grade-roi-fixed3y-600w-20260813/report.html) · [A 全期](../exports/backtest-reports/baseline-s15-at01-grade-roi-fullstress-600w-20260813/report.html) · [B 固定](../exports/backtest-reports/baseline-b-s15-at01-grade-roi-fixed3y-600w-20260813/report.html) · [B 全期](../exports/backtest-reports/baseline-b-s15-at01-grade-roi-fullstress-600w-20260813/report.html) |
| S16 | 2026/08/14 | H-T01 只在交易當時 Grade 恰為 low 時由 `wantH >= 0` 收緊為 `>= 1` | T2/S17 · [`fba2e08`](https://github.com/peiyu66/simStock3/commit/fba2e0822bdbc208f32b6042985d470c8bed1dc2) | 133.721（+0.274） | 52.955（+0.172） | [A 固定](../exports/backtest-reports/baseline-s16-ht01-low-only-fixed3y-600w-20260814/report.html) · [A 全期](../exports/backtest-reports/baseline-s16-ht01-low-only-fullstress-600w-20260814/report.html) · [B 固定](../exports/backtest-reports/baseline-b-s16-ht01-low-only-fixed3y-600w-20260814/report.html) · [B 全期](../exports/backtest-reports/baseline-b-s16-ht01-low-only-fullstress-600w-20260814/report.html) |
| S17 | 2026/08/14 | A-P08 在 wow、平均週期未滿 38 日且同日 `wantL < 6` 時取消深跌加碼票 | T2/S18 · [`188a64d`](https://github.com/peiyu66/simStock3/commit/188a64de252f8b4a9c578e3b8d31e69ffc9eb1fc) | 134.718（+0.996） | 52.955（+0.000） | [A 固定](../exports/backtest-reports/baseline-s17-ap08-wow-early-boundary-fixed3y-600w-20260814/report.html) · [A 全期](../exports/backtest-reports/baseline-s17-ap08-wow-early-boundary-fullstress-600w-20260814/report.html) · [B 固定](../exports/backtest-reports/baseline-b-s17-ap08-wow-early-boundary-fixed3y-600w-20260814/report.html) · [B 全期](../exports/backtest-reports/baseline-b-s17-ap08-wow-early-boundary-fullstress-600w-20260814/report.html) |

## 九年 A／B／C／D 重組 Baseline

2026/08/20 沿用正式 S17 策略，不改買賣規則；把 50 檔集中資料池重組為四個 10 檔樣本，技術準備期自 2016/07/22、模擬自 2017/07/22，建立三個完整三年窗口及九年全期間壓力測試。這是樣本、窗口與輸入架構重建，不能把分數差異歸因於策略改善。

| 策略版本 | 日期 | 資料規則／commit | A 固定／全期 | B 固定／全期 | C 固定／全期 | D 固定／全期 | 完整報告 |
|---|---|---|---:|---:|---:|---:|---|
| S17／ABCD v2 | 2026/08/20 | T2/S20 · `188a64de252f8b4a9c578e3b8d31e69ffc9eb1fc` | 78.108／70.333 | 78.702／70.381 | 81.346／78.864 | 80.782／77.571 | [A 固定](../exports/backtest-reports/baseline-a-v2-s17-ap08-wow-early-boundary-t2s20-9y-fixed3y-600w-20260820/report.html) · [A 全期](../exports/backtest-reports/baseline-a-v2-s17-ap08-wow-early-boundary-t2s20-9y-fullstress-600w-20260820/report.html) · [B 固定](../exports/backtest-reports/baseline-b-v2-s17-ap08-wow-early-boundary-t2s20-9y-fixed3y-600w-20260820/report.html) · [B 全期](../exports/backtest-reports/baseline-b-v2-s17-ap08-wow-early-boundary-t2s20-9y-fullstress-600w-20260820/report.html) · [C 固定](../exports/backtest-reports/baseline-c-v2-s17-ap08-wow-early-boundary-t2s20-9y-fixed3y-600w-20260820/report.html) · [C 全期](../exports/backtest-reports/baseline-c-v2-s17-ap08-wow-early-boundary-t2s20-9y-fullstress-600w-20260820/report.html) · [D 固定](../exports/backtest-reports/baseline-d-v2-s17-ap08-wow-early-boundary-t2s20-9y-fixed3y-600w-20260820/report.html) · [D 全期](../exports/backtest-reports/baseline-d-v2-s17-ap08-wow-early-boundary-t2s20-9y-fullstress-600w-20260820/report.html) |
| S18／ABCD v3 | 2026/08/21 | T2/S21 · `635ad8a3f039756bad65d33d9fff2c849bf8765f` | 79.429／70.333（固定 +1.322） | 78.447／70.221（固定 -0.255） | 81.223／78.691（固定 -0.124） | 80.980／77.500（固定 +0.198） | [A 固定](../exports/backtest-reports/baseline-a-v3-s18-ln02-low-prior-trend-t2s21-9y-fixed3y-600w-20260821/report.html) · [A 全期](../exports/backtest-reports/baseline-a-v3-s18-ln02-low-prior-trend-t2s21-9y-fullstress-600w-20260821/report.html) · [B 固定](../exports/backtest-reports/baseline-b-v3-s18-ln02-low-prior-trend-t2s21-9y-fixed3y-600w-20260821/report.html) · [B 全期](../exports/backtest-reports/baseline-b-v3-s18-ln02-low-prior-trend-t2s21-9y-fullstress-600w-20260821/report.html) · [C 固定](../exports/backtest-reports/baseline-c-v3-s18-ln02-low-prior-trend-t2s21-9y-fixed3y-600w-20260821/report.html) · [C 全期](../exports/backtest-reports/baseline-c-v3-s18-ln02-low-prior-trend-t2s21-9y-fullstress-600w-20260821/report.html) · [D 固定](../exports/backtest-reports/baseline-d-v3-s18-ln02-low-prior-trend-t2s21-9y-fixed3y-600w-20260821/report.html) · [D 全期](../exports/backtest-reports/baseline-d-v3-s18-ln02-low-prior-trend-t2s21-9y-fullstress-600w-20260821/report.html) |
| S18／ABCD v4 | 2026/08/21 | T2/S22 · `a835c66d9dc15932d52da6e42d484a65951b76cd` | 79.429／70.333（固定 +0.000） | 78.447／70.221（固定 +0.000） | 81.223／78.691（固定 +0.000） | 80.980／77.500（固定 +0.000） | [A 固定](../exports/backtest-reports/baseline-a-v4-s18-ln02-low-prior-trend-t2s22-9y-fixed3y-600w-20260821/report.html) · [A 全期](../exports/backtest-reports/baseline-a-v4-s18-ln02-low-prior-trend-t2s22-9y-fullstress-600w-20260821/report.html) · [B 固定](../exports/backtest-reports/baseline-b-v4-s18-ln02-low-prior-trend-t2s22-9y-fixed3y-600w-20260821/report.html) · [B 全期](../exports/backtest-reports/baseline-b-v4-s18-ln02-low-prior-trend-t2s22-9y-fullstress-600w-20260821/report.html) · [C 固定](../exports/backtest-reports/baseline-c-v4-s18-ln02-low-prior-trend-t2s22-9y-fixed3y-600w-20260821/report.html) · [C 全期](../exports/backtest-reports/baseline-c-v4-s18-ln02-low-prior-trend-t2s22-9y-fullstress-600w-20260821/report.html) · [D 固定](../exports/backtest-reports/baseline-d-v4-s18-ln02-low-prior-trend-t2s22-9y-fixed3y-600w-20260821/report.html) · [D 全期](../exports/backtest-reports/baseline-d-v4-s18-ln02-low-prior-trend-t2s22-9y-fullstress-600w-20260821/report.html) |
| S19／ABCD v5 | 2026/08/22 | T2/S23 · `2405a352a0f65aab87d665401b00d0a34c6ee348` | 80.001／67.919（固定 +0.571） | 79.612／70.888（固定 +1.165） | 81.466／77.982（固定 +0.244） | 80.645／77.721（固定 -0.334） | [A 固定](../exports/backtest-reports/baseline-a-v5-s19-hn11-fit-trend-worsening-t2s23-9y-fixed3y-600w-20260822/report.html) · [A 全期](../exports/backtest-reports/baseline-a-v5-s19-hn11-fit-trend-worsening-t2s23-9y-fullstress-600w-20260822/report.html) · [B 固定](../exports/backtest-reports/baseline-b-v5-s19-hn11-fit-trend-worsening-t2s23-9y-fixed3y-600w-20260822/report.html) · [B 全期](../exports/backtest-reports/baseline-b-v5-s19-hn11-fit-trend-worsening-t2s23-9y-fullstress-600w-20260822/report.html) · [C 固定](../exports/backtest-reports/baseline-c-v5-s19-hn11-fit-trend-worsening-t2s23-9y-fixed3y-600w-20260822/report.html) · [C 全期](../exports/backtest-reports/baseline-c-v5-s19-hn11-fit-trend-worsening-t2s23-9y-fullstress-600w-20260822/report.html) · [D 固定](../exports/backtest-reports/baseline-d-v5-s19-hn11-fit-trend-worsening-t2s23-9y-fixed3y-600w-20260822/report.html) · [D 全期](../exports/backtest-reports/baseline-d-v5-s19-hn11-fit-trend-worsening-t2s23-9y-fullstress-600w-20260822/report.html) |
| S20／ABCD v6 | 2026/08/23 | `T2/S24` · `cd1c4da53fde094169c09ba4b7014b9935b13d87` | 80.567／68.948（固定 `+0.566`） | 80.961／70.352（固定 `+1.349`） | 83.196／80.416（固定 `+1.730`） | 80.732／77.543（固定 `+0.087`） | [A 固定三年](../exports/backtest-reports/baseline-a-v6-s20-lp10-fit-trend-recovery-t2s24-9y-fixed3y-600w-20260823/report.html)／[A 全期間](../exports/backtest-reports/baseline-a-v6-s20-lp10-fit-trend-recovery-t2s24-9y-fullstress-600w-20260823/report.html)；[B 固定三年](../exports/backtest-reports/baseline-b-v6-s20-lp10-fit-trend-recovery-t2s24-9y-fixed3y-600w-20260823/report.html)／[B 全期間](../exports/backtest-reports/baseline-b-v6-s20-lp10-fit-trend-recovery-t2s24-9y-fullstress-600w-20260823/report.html)；[C 固定三年](../exports/backtest-reports/baseline-c-v6-s20-lp10-fit-trend-recovery-t2s24-9y-fixed3y-600w-20260823/report.html)／[C 全期間](../exports/backtest-reports/baseline-c-v6-s20-lp10-fit-trend-recovery-t2s24-9y-fullstress-600w-20260823/report.html)；[D 固定三年](../exports/backtest-reports/baseline-d-v6-s20-lp10-fit-trend-recovery-t2s24-9y-fixed3y-600w-20260823/report.html)／[D 全期間](../exports/backtest-reports/baseline-d-v6-s20-lp10-fit-trend-recovery-t2s24-9y-fullstress-600w-20260823/report.html) |
| S21／ABCD v7 | 2026/08/23 | `T2/S25` · `718330a58209ec6f8ede0f8acde586b82fa93134` | 81.762／74.335（固定 `+1.195`） | 81.863／69.172（固定 `+0.902`） | 83.737／82.117（固定 `+0.541`） | 80.893／80.723（固定 `+0.160`） | [A 固定三年](../exports/backtest-reports/baseline-a-v7-s21-sp07-fit-trend-worsening-sell-t2s25-9y-fixed3y-600w-20260823/report.html)／[A 全期間](../exports/backtest-reports/baseline-a-v7-s21-sp07-fit-trend-worsening-sell-t2s25-9y-fullstress-600w-20260823/report.html)；[B 固定三年](../exports/backtest-reports/baseline-b-v7-s21-sp07-fit-trend-worsening-sell-t2s25-9y-fixed3y-600w-20260823/report.html)／[B 全期間](../exports/backtest-reports/baseline-b-v7-s21-sp07-fit-trend-worsening-sell-t2s25-9y-fullstress-600w-20260823/report.html)；[C 固定三年](../exports/backtest-reports/baseline-c-v7-s21-sp07-fit-trend-worsening-sell-t2s25-9y-fixed3y-600w-20260823/report.html)／[C 全期間](../exports/backtest-reports/baseline-c-v7-s21-sp07-fit-trend-worsening-sell-t2s25-9y-fullstress-600w-20260823/report.html)；[D 固定三年](../exports/backtest-reports/baseline-d-v7-s21-sp07-fit-trend-worsening-sell-t2s25-9y-fixed3y-600w-20260823/report.html)／[D 全期間](../exports/backtest-reports/baseline-d-v7-s21-sp07-fit-trend-worsening-sell-t2s25-9y-fullstress-600w-20260823/report.html) |
| S22／ABCD v8 | 2026/08/24 | `T2/S26` · `d1825d5d295e78d600a9cf90e793d418ea357533` | 81.901／74.450（固定 `+0.139`） | 81.863／69.172（固定 `+0.000`） | 83.762／82.117（固定 `+0.025`） | 80.893／80.723（固定 `+0.000`） | [A 固定三年](../exports/backtest-reports/baseline-a-v8-s22-lp10-weak-or-fine-t2s26-9y-fixed3y-600w-20260824/report.html)／[A 全期間](../exports/backtest-reports/baseline-a-v8-s22-lp10-weak-or-fine-t2s26-9y-fullstress-600w-20260824/report.html)；[B 固定三年](../exports/backtest-reports/baseline-b-v8-s22-lp10-weak-or-fine-t2s26-9y-fixed3y-600w-20260824/report.html)／[B 全期間](../exports/backtest-reports/baseline-b-v8-s22-lp10-weak-or-fine-t2s26-9y-fullstress-600w-20260824/report.html)；[C 固定三年](../exports/backtest-reports/baseline-c-v8-s22-lp10-weak-or-fine-t2s26-9y-fixed3y-600w-20260824/report.html)／[C 全期間](../exports/backtest-reports/baseline-c-v8-s22-lp10-weak-or-fine-t2s26-9y-fullstress-600w-20260824/report.html)；[D 固定三年](../exports/backtest-reports/baseline-d-v8-s22-lp10-weak-or-fine-t2s26-9y-fixed3y-600w-20260824/report.html)／[D 全期間](../exports/backtest-reports/baseline-d-v8-s22-lp10-weak-or-fine-t2s26-9y-fullstress-600w-20260824/report.html) |
| S23／ABCD v9 | 2026/08/24 | `T2/S27` · `49e2ca26ed68d106c83efab6db796fa977d15e2f` | 82.920／74.450（固定 `+1.020`） | 81.863／69.172（固定 `+0.000`） | 83.762／82.117（固定 `+0.000`） | 80.893／80.723（固定 `+0.000`） | [A 固定三年](../exports/backtest-reports/baseline-a-v9-s23-hn01a-high-worsening-t2s27-9y-fixed3y-600w-20260824/report.html)／[A 全期間](../exports/backtest-reports/baseline-a-v9-s23-hn01a-high-worsening-t2s27-9y-fullstress-600w-20260824/report.html)；[B 固定三年](../exports/backtest-reports/baseline-b-v9-s23-hn01a-high-worsening-t2s27-9y-fixed3y-600w-20260824/report.html)／[B 全期間](../exports/backtest-reports/baseline-b-v9-s23-hn01a-high-worsening-t2s27-9y-fullstress-600w-20260824/report.html)；[C 固定三年](../exports/backtest-reports/baseline-c-v9-s23-hn01a-high-worsening-t2s27-9y-fixed3y-600w-20260824/report.html)／[C 全期間](../exports/backtest-reports/baseline-c-v9-s23-hn01a-high-worsening-t2s27-9y-fullstress-600w-20260824/report.html)；[D 固定三年](../exports/backtest-reports/baseline-d-v9-s23-hn01a-high-worsening-t2s27-9y-fixed3y-600w-20260824/report.html)／[D 全期間](../exports/backtest-reports/baseline-d-v9-s23-hn01a-high-worsening-t2s27-9y-fullstress-600w-20260824/report.html) |
| S24／ABCD v10 | 2026/08/24 | `T2/S28` · `73003cf8f39cbf3a673792957324f508261bd731` | 83.447／74.660（固定 `+0.526`） | 82.331／68.807（固定 `+0.468`） | 83.043／81.836（固定 `-0.718`） | 83.254／79.370（固定 `+2.361`） | [A 固定三年](../exports/backtest-reports/baseline-a-v10-s24-sn05-wow-worsening-t2s28-9y-fixed3y-600w-20260824/report.html)／[A 全期間](../exports/backtest-reports/baseline-a-v10-s24-sn05-wow-worsening-t2s28-9y-fullstress-600w-20260824/report.html)；[B 固定三年](../exports/backtest-reports/baseline-b-v10-s24-sn05-wow-worsening-t2s28-9y-fixed3y-600w-20260824/report.html)／[B 全期間](../exports/backtest-reports/baseline-b-v10-s24-sn05-wow-worsening-t2s28-9y-fullstress-600w-20260824/report.html)；[C 固定三年](../exports/backtest-reports/baseline-c-v10-s24-sn05-wow-worsening-t2s28-9y-fixed3y-600w-20260824/report.html)／[C 全期間](../exports/backtest-reports/baseline-c-v10-s24-sn05-wow-worsening-t2s28-9y-fullstress-600w-20260824/report.html)；[D 固定三年](../exports/backtest-reports/baseline-d-v10-s24-sn05-wow-worsening-t2s28-9y-fixed3y-600w-20260824/report.html)／[D 全期間](../exports/backtest-reports/baseline-d-v10-s24-sn05-wow-worsening-t2s28-9y-fullstress-600w-20260824/report.html) |
| S25／ABCD v11 | 2026/08/26 | `T2/S29` · `9ef0064259a3f11d3b6e3f94269480667c082a22` | 104.573／101.019（固定 `+21.127`） | 101.252／85.930（固定 `+18.921`） | 105.145／105.071（固定 `+22.102`） | 90.955／84.563（固定 `+7.701`） | [A 固定三年](../exports/backtest-reports/baseline-a-v11-s25-st02e-grade-band-t2s29-9y-fixed3y-600w-20260826/report.html)／[A 全期間](../exports/backtest-reports/baseline-a-v11-s25-st02e-grade-band-t2s29-9y-fullstress-600w-20260826/report.html)；[B 固定三年](../exports/backtest-reports/baseline-b-v11-s25-st02e-grade-band-t2s29-9y-fixed3y-600w-20260826/report.html)／[B 全期間](../exports/backtest-reports/baseline-b-v11-s25-st02e-grade-band-t2s29-9y-fullstress-600w-20260826/report.html)；[C 固定三年](../exports/backtest-reports/baseline-c-v11-s25-st02e-grade-band-t2s29-9y-fixed3y-600w-20260826/report.html)／[C 全期間](../exports/backtest-reports/baseline-c-v11-s25-st02e-grade-band-t2s29-9y-fullstress-600w-20260826/report.html)；[D 固定三年](../exports/backtest-reports/baseline-d-v11-s25-st02e-grade-band-t2s29-9y-fixed3y-600w-20260826/report.html)／[D 全期間](../exports/backtest-reports/baseline-d-v11-s25-st02e-grade-band-t2s29-9y-fullstress-600w-20260826/report.html) |
| S26／ABCD v12 | 2026/08/27 | `T2/S30` · `1cc3bd4714207468b5a4842d03e46ef92ec63bb8` | 105.205／100.852（固定 `+0.632`） | 103.555／89.698（固定 `+2.302`） | 112.609／105.536（固定 `+7.464`） | 91.141／85.415（固定 `+0.187`） | [A 固定三年](../exports/backtest-reports/baseline-a-v12-s26-ap05-wow-exclude-worsening-t2s30-9y-fixed3y-600w-20260827/report.html)／[A 全期間](../exports/backtest-reports/baseline-a-v12-s26-ap05-wow-exclude-worsening-t2s30-9y-fullstress-600w-20260827/report.html)；[B 固定三年](../exports/backtest-reports/baseline-b-v12-s26-ap05-wow-exclude-worsening-t2s30-9y-fixed3y-600w-20260827/report.html)／[B 全期間](../exports/backtest-reports/baseline-b-v12-s26-ap05-wow-exclude-worsening-t2s30-9y-fullstress-600w-20260827/report.html)；[C 固定三年](../exports/backtest-reports/baseline-c-v12-s26-ap05-wow-exclude-worsening-t2s30-9y-fixed3y-600w-20260827/report.html)／[C 全期間](../exports/backtest-reports/baseline-c-v12-s26-ap05-wow-exclude-worsening-t2s30-9y-fullstress-600w-20260827/report.html)；[D 固定三年](../exports/backtest-reports/baseline-d-v12-s26-ap05-wow-exclude-worsening-t2s30-9y-fixed3y-600w-20260827/report.html)／[D 全期間](../exports/backtest-reports/baseline-d-v12-s26-ap05-wow-exclude-worsening-t2s30-9y-fullstress-600w-20260827/report.html) |
| S26／AB v13 | 2026/08/27 | `T2/S31` · `126da5fe2c93af67b67ba597d20a8f199f81781f` | 105.205／100.852 | 103.555／89.698 | — | — | [A 固定三年](../exports/backtest-reports/baseline-a-v13-s26-fit-trend-phase-split-t2s31-9y-fixed3y-600w-20260827/report.html)／[A 全期間](../exports/backtest-reports/baseline-a-v13-s26-fit-trend-phase-split-t2s31-9y-fullstress-600w-20260827/report.html)；[B 固定三年](../exports/backtest-reports/baseline-b-v13-s26-fit-trend-phase-split-t2s31-9y-fixed3y-600w-20260827/report.html)／[B 全期間](../exports/backtest-reports/baseline-b-v13-s26-fit-trend-phase-split-t2s31-9y-fullstress-600w-20260827/report.html) |
| S26／AB v14 | 2026/08/28 | `T2/S33` · `126da5fe2c93af67b67ba597d20a8f199f81781f` | 105.205／100.852 | 103.555／89.698 | — | — | [A 固定三年](../exports/backtest-reports/baseline-a-v14-s26-fit-trend-turn-threshold-t2s33-9y-fixed3y-600w-20260828/report.html)／[A 全期間](../exports/backtest-reports/baseline-a-v14-s26-fit-trend-turn-threshold-t2s33-9y-fullstress-600w-20260828/report.html)；[B 固定三年](../exports/backtest-reports/baseline-b-v14-s26-fit-trend-turn-threshold-t2s33-9y-fixed3y-600w-20260828/report.html)／[B 全期間](../exports/backtest-reports/baseline-b-v14-s26-fit-trend-turn-threshold-t2s33-9y-fullstress-600w-20260828/report.html) |
| S27／ABCD v15 | 2026/08/29 | `T2/S34` · `5f26225ab7d77494131889cc09147aa4efd1efa7` | 107.103／106.699（固定 `+1.897`） | 109.184／96.736（固定 `+5.629`） | 112.330／—（固定 `-0.279`） | 92.130／—（固定 `+0.989`） | [A 固定三年](../exports/backtest-reports/baseline-a-v15-s27-st02g-high-grade-long-loss120-t2s34-9y-fixed3y-600w-20260829/report.html)／[A 全期間](../exports/backtest-reports/baseline-a-v15-s27-st02g-high-grade-long-loss120-t2s34-9y-fullstress-600w-20260829/report.html)；[B 固定三年](../exports/backtest-reports/baseline-b-v15-s27-st02g-high-grade-long-loss120-t2s34-9y-fixed3y-600w-20260829/report.html)／[B 全期間](../exports/backtest-reports/baseline-b-v15-s27-st02g-high-grade-long-loss120-t2s34-9y-fullstress-600w-20260829/report.html)；[C 固定三年](../exports/backtest-reports/baseline-c-v15-s27-st02g-high-grade-long-loss120-t2s34-9y-fixed3y-600w-20260829/report.html)；[D 固定三年](../exports/backtest-reports/baseline-d-v15-s27-st02g-high-grade-long-loss120-t2s34-9y-fixed3y-600w-20260829/report.html) |
| S28／ABCD v16 | 2026/08/30 | `T2/S35` · `a625837b8d48c2a8b35448dca8237267dc9edb9b` | 108.108／105.987（固定 `+1.006`） | 111.207／102.591（固定 `+2.024`） | 112.614／—（固定 `+0.284`） | 91.894／—（固定 `-0.237`） | [A 固定三年](../exports/backtest-reports/baseline-a-v16-s28-grade-loss-cut-penalty-t2s35-9y-fixed3y-600w-20260830/report.html)／[A 全期間](../exports/backtest-reports/baseline-a-v16-s28-grade-loss-cut-penalty-t2s35-9y-fullstress-600w-20260830/report.html)；[B 固定三年](../exports/backtest-reports/baseline-b-v16-s28-grade-loss-cut-penalty-t2s35-9y-fixed3y-600w-20260830/report.html)／[B 全期間](../exports/backtest-reports/baseline-b-v16-s28-grade-loss-cut-penalty-t2s35-9y-fullstress-600w-20260830/report.html)；[C 固定三年](../exports/backtest-reports/baseline-c-v16-s28-grade-loss-cut-penalty-t2s35-9y-fixed3y-600w-20260830/report.html)；[D 固定三年](../exports/backtest-reports/baseline-d-v16-s28-grade-loss-cut-penalty-t2s35-9y-fixed3y-600w-20260830/report.html) |
### A～E 同版 Baseline 檢索表

本區自 Sample E 建立後開始維護。分數與報告以固定三年、全期間分列，避免依賴表格內 HTML 折行；`—` 保留當時未產生的歷史事實，不以後來版本倒填。

#### 分數與報告

| Baseline 版本 | 報告類型 | A | B | C | D | E |
|---|---|---|---|---|---|---|
| S29／v17 | 固定三年 | `108.408` · [報告](../exports/backtest-reports/baseline-a-v17-s29-lp11-wow-worsening-rebound-lbuy-t2s36-9y-fixed3y-600w-20260830/report.html) | `113.000` · [報告](../exports/backtest-reports/baseline-b-v17-s29-lp11-wow-worsening-rebound-lbuy-t2s36-9y-fixed3y-600w-20260830/report.html) | `112.614` · [報告](../exports/backtest-reports/baseline-c-v17-s29-lp11-wow-worsening-rebound-lbuy-t2s36-9y-fixed3y-600w-20260830/report.html) | `92.047` · [報告](../exports/backtest-reports/baseline-d-v17-s29-lp11-wow-worsening-rebound-lbuy-t2s36-9y-fixed3y-600w-20260830/report.html) | `1.868` · [報告](../exports/backtest-reports/baseline-e-v17-s29-lp11-wow-worsening-rebound-lbuy-t2s36-9y-fixed3y-600w-20260830/report.html) |
| S29／v17 | 全期間 | `105.168` · [報告](../exports/backtest-reports/baseline-a-v17-s29-lp11-wow-worsening-rebound-lbuy-t2s36-9y-fullstress-600w-20260830/report.html) | `102.434` · [報告](../exports/backtest-reports/baseline-b-v17-s29-lp11-wow-worsening-rebound-lbuy-t2s36-9y-fullstress-600w-20260830/report.html) | `—` | `—` | `0.015` · [報告](../exports/backtest-reports/baseline-e-v17-s29-lp11-wow-worsening-rebound-lbuy-t2s36-9y-fullstress-600w-20260830/report.html) |
| S30／v18 | 固定三年 | `108.367` · [報告](../exports/backtest-reports/baseline-a-v18-s30-hn12-damn-loss-reentry-hbuy-t2s37-9y-fixed3y-600w-20260831/report.html) | `113.000` · [報告](../exports/backtest-reports/baseline-b-v18-s30-hn12-damn-loss-reentry-hbuy-t2s37-9y-fixed3y-600w-20260831/report.html) | `112.601` · [報告](../exports/backtest-reports/baseline-c-v18-s30-hn12-damn-loss-reentry-hbuy-t2s37-9y-fixed3y-600w-20260831/report.html) | `92.197` · [報告](../exports/backtest-reports/baseline-d-v18-s30-hn12-damn-loss-reentry-hbuy-t2s37-9y-fixed3y-600w-20260831/report.html) | `2.103` · [報告](../exports/backtest-reports/baseline-e-v18-s30-hn12-damn-loss-reentry-hbuy-t2s37-9y-fixed3y-600w-20260831/report.html) |
| S30／v18 | 全期間 | `105.168` · [報告](../exports/backtest-reports/baseline-a-v18-s30-hn12-damn-loss-reentry-hbuy-t2s37-9y-fullstress-600w-20260831/report.html) | `102.434` · [報告](../exports/backtest-reports/baseline-b-v18-s30-hn12-damn-loss-reentry-hbuy-t2s37-9y-fullstress-600w-20260831/report.html) | `106.445` · [報告](../exports/backtest-reports/baseline-c-v18-s30-hn12-damn-loss-reentry-hbuy-t2s37-9y-fullstress-600w-20260831/report.html) | `81.221` · [報告](../exports/backtest-reports/baseline-d-v18-s30-hn12-damn-loss-reentry-hbuy-t2s37-9y-fullstress-600w-20260831/report.html) | `0.450` · [報告](../exports/backtest-reports/baseline-e-v18-s30-hn12-damn-loss-reentry-hbuy-t2s37-9y-fullstress-600w-20260831/report.html) |
| S31／v19 | 固定三年 | `115.619` · [報告](../exports/backtest-reports/baseline-a-v19-s31-st02h-efficiency-loss-cut-t2s38-9y-fixed3y-600w-20260831/report.html) | `114.081` · [報告](../exports/backtest-reports/baseline-b-v19-s31-st02h-efficiency-loss-cut-t2s38-9y-fixed3y-600w-20260831/report.html) | `113.724` · [報告](../exports/backtest-reports/baseline-c-v19-s31-st02h-efficiency-loss-cut-t2s38-9y-fixed3y-600w-20260831/report.html) | `93.988` · [報告](../exports/backtest-reports/baseline-d-v19-s31-st02h-efficiency-loss-cut-t2s38-9y-fixed3y-600w-20260831/report.html) | `0.442` · [報告](../exports/backtest-reports/baseline-e-v19-s31-st02h-efficiency-loss-cut-t2s38-9y-fixed3y-600w-20260831/report.html) |
| S31／v19 | 全期間 | `111.477` · [報告](../exports/backtest-reports/baseline-a-v19-s31-st02h-efficiency-loss-cut-t2s38-9y-fullstress-600w-20260831/report.html) | `103.727` · [報告](../exports/backtest-reports/baseline-b-v19-s31-st02h-efficiency-loss-cut-t2s38-9y-fullstress-600w-20260831/report.html) | `110.600` · [報告](../exports/backtest-reports/baseline-c-v19-s31-st02h-efficiency-loss-cut-t2s38-9y-fullstress-600w-20260831/report.html) | `82.239` · [報告](../exports/backtest-reports/baseline-d-v19-s31-st02h-efficiency-loss-cut-t2s38-9y-fullstress-600w-20260831/report.html) | `0.797` · [報告](../exports/backtest-reports/baseline-e-v19-s31-st02h-efficiency-loss-cut-t2s38-9y-fullstress-600w-20260831/report.html) |
| S32／v20 | 固定三年 | `115.619` · [報告](../exports/backtest-reports/baseline-a-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-t2s39-9y-fixed3y-600w-20260901/report.html) | `114.081` · [報告](../exports/backtest-reports/baseline-b-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-t2s39-9y-fixed3y-600w-20260901/report.html) | `115.772` · [報告](../exports/backtest-reports/baseline-c-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-t2s39-9y-fixed3y-600w-20260901/report.html) | `93.988` · [報告](../exports/backtest-reports/baseline-d-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-t2s39-9y-fixed3y-600w-20260901/report.html) | `0.517` · [報告](../exports/backtest-reports/baseline-e-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-t2s39-9y-fixed3y-600w-20260901/report.html) |
| S32／v20 | 全期間 | `111.477` · [報告](../exports/backtest-reports/baseline-a-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-t2s39-9y-fullstress-600w-20260901/report.html) | `103.727` · [報告](../exports/backtest-reports/baseline-b-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-t2s39-9y-fullstress-600w-20260901/report.html) | `113.048` · [報告](../exports/backtest-reports/baseline-c-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-t2s39-9y-fullstress-600w-20260901/report.html) | `82.239` · [報告](../exports/backtest-reports/baseline-d-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-t2s39-9y-fullstress-600w-20260901/report.html) | `0.797` · [報告](../exports/backtest-reports/baseline-e-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-t2s39-9y-fullstress-600w-20260901/report.html) |
| S32／v21 | 固定三年 | `115.619` · [報告](../exports/backtest-reports/baseline-a-v21-s32-an03-wow-nonbottom-no-ap02-add-penalty-t3s39-9y-fixed3y-600w-20260903/report.html) | `114.081` · [報告](../exports/backtest-reports/baseline-b-v21-s32-an03-wow-nonbottom-no-ap02-add-penalty-t3s39-9y-fixed3y-600w-20260903/report.html) | `115.772` · [報告](../exports/backtest-reports/baseline-c-v21-s32-an03-wow-nonbottom-no-ap02-add-penalty-t3s39-9y-fixed3y-600w-20260903/report.html) | `93.988` · [報告](../exports/backtest-reports/baseline-d-v21-s32-an03-wow-nonbottom-no-ap02-add-penalty-t3s39-9y-fixed3y-600w-20260903/report.html) | `0.517` · [報告](../exports/backtest-reports/baseline-e-v21-s32-an03-wow-nonbottom-no-ap02-add-penalty-t3s39-9y-fixed3y-600w-20260903/report.html) |
| S32／v21 | 全期間 | `111.477` · [報告](../exports/backtest-reports/baseline-a-v21-s32-an03-wow-nonbottom-no-ap02-add-penalty-t3s39-9y-fullstress-600w-20260903/report.html) | `103.727` · [報告](../exports/backtest-reports/baseline-b-v21-s32-an03-wow-nonbottom-no-ap02-add-penalty-t3s39-9y-fullstress-600w-20260903/report.html) | `113.048` · [報告](../exports/backtest-reports/baseline-c-v21-s32-an03-wow-nonbottom-no-ap02-add-penalty-t3s39-9y-fullstress-600w-20260903/report.html) | `82.239` · [報告](../exports/backtest-reports/baseline-d-v21-s32-an03-wow-nonbottom-no-ap02-add-penalty-t3s39-9y-fullstress-600w-20260903/report.html) | `0.797` · [報告](../exports/backtest-reports/baseline-e-v21-s32-an03-wow-nonbottom-no-ap02-add-penalty-t3s39-9y-fullstress-600w-20260903/report.html) |
| S33／v22 | 固定三年 | `122.742` · [報告](../exports/backtest-reports/baseline-a-v22-s33-sp08-market-stock-peak-late-high-sell-t3s40-9y-fixed3y-600w-20260904/report.html) | `118.468` · [報告](../exports/backtest-reports/baseline-b-v22-s33-sp08-market-stock-peak-late-high-sell-t3s40-9y-fixed3y-600w-20260904/report.html) | `121.759` · [報告](../exports/backtest-reports/baseline-c-v22-s33-sp08-market-stock-peak-late-high-sell-t3s40-9y-fixed3y-600w-20260904/report.html) | `95.507` · [報告](../exports/backtest-reports/baseline-d-v22-s33-sp08-market-stock-peak-late-high-sell-t3s40-9y-fixed3y-600w-20260904/report.html) | `0.368` · [報告](../exports/backtest-reports/baseline-e-v22-s33-sp08-market-stock-peak-late-high-sell-t3s40-9y-fixed3y-600w-20260904/report.html) |
| S33／v22 | 全期間 | `111.276` · [報告](../exports/backtest-reports/baseline-a-v22-s33-sp08-market-stock-peak-late-high-sell-t3s40-9y-fullstress-600w-20260904/report.html) | `105.633` · [報告](../exports/backtest-reports/baseline-b-v22-s33-sp08-market-stock-peak-late-high-sell-t3s40-9y-fullstress-600w-20260904/report.html) | `117.827` · [報告](../exports/backtest-reports/baseline-c-v22-s33-sp08-market-stock-peak-late-high-sell-t3s40-9y-fullstress-600w-20260904/report.html) | `82.569` · [報告](../exports/backtest-reports/baseline-d-v22-s33-sp08-market-stock-peak-late-high-sell-t3s40-9y-fullstress-600w-20260904/report.html) | `0.697` · [報告](../exports/backtest-reports/baseline-e-v22-s33-sp08-market-stock-peak-late-high-sell-t3s40-9y-fullstress-600w-20260904/report.html) |
| S34／v23 | 固定三年 | `124.115` · [報告](../exports/backtest-reports/baseline-a-v23-s34-sp09-price-bottom-early-sell-t3s41-9y-fixed3y-600w-20260905/report.html) | `121.294` · [報告](../exports/backtest-reports/baseline-b-v23-s34-sp09-price-bottom-early-sell-t3s41-9y-fixed3y-600w-20260905/report.html) | `122.485` · [報告](../exports/backtest-reports/baseline-c-v23-s34-sp09-price-bottom-early-sell-t3s41-9y-fixed3y-600w-20260905/report.html) | `96.213` · [報告](../exports/backtest-reports/baseline-d-v23-s34-sp09-price-bottom-early-sell-t3s41-9y-fixed3y-600w-20260905/report.html) | `0.176` · [報告](../exports/backtest-reports/baseline-e-v23-s34-sp09-price-bottom-early-sell-t3s41-9y-fixed3y-600w-20260905/report.html) |
| S34／v23 | 全期間 | `113.068` · [報告](../exports/backtest-reports/baseline-a-v23-s34-sp09-price-bottom-early-sell-t3s41-9y-fullstress-600w-20260905/report.html) | `106.769` · [報告](../exports/backtest-reports/baseline-b-v23-s34-sp09-price-bottom-early-sell-t3s41-9y-fullstress-600w-20260905/report.html) | `123.231` · [報告](../exports/backtest-reports/baseline-c-v23-s34-sp09-price-bottom-early-sell-t3s41-9y-fullstress-600w-20260905/report.html) | `84.406` · [報告](../exports/backtest-reports/baseline-d-v23-s34-sp09-price-bottom-early-sell-t3s41-9y-fullstress-600w-20260905/report.html) | `0.918` · [報告](../exports/backtest-reports/baseline-e-v23-s34-sp09-price-bottom-early-sell-t3s41-9y-fullstress-600w-20260905/report.html) |
| S35／v24 | 固定三年 | `124.546` · [報告](../exports/backtest-reports/baseline-a-v24-s35-sn01c-market-low9-sell-t3s42-9y-fixed3y-600w-20260907/report.html) | `122.605` · [報告](../exports/backtest-reports/baseline-b-v24-s35-sn01c-market-low9-sell-t3s42-9y-fixed3y-600w-20260907/report.html) | `123.489` · [報告](../exports/backtest-reports/baseline-c-v24-s35-sn01c-market-low9-sell-t3s42-9y-fixed3y-600w-20260907/report.html) | `96.388` · [報告](../exports/backtest-reports/baseline-d-v24-s35-sn01c-market-low9-sell-t3s42-9y-fixed3y-600w-20260907/report.html) | `1.184` · [報告](../exports/backtest-reports/baseline-e-v24-s35-sn01c-market-low9-sell-t3s42-9y-fixed3y-600w-20260907/report.html) |
| S35／v24 | 全期間 | `114.705` · [報告](../exports/backtest-reports/baseline-a-v24-s35-sn01c-market-low9-sell-t3s42-9y-fullstress-600w-20260907/report.html) | `108.200` · [報告](../exports/backtest-reports/baseline-b-v24-s35-sn01c-market-low9-sell-t3s42-9y-fullstress-600w-20260907/report.html) | `122.471` · [報告](../exports/backtest-reports/baseline-c-v24-s35-sn01c-market-low9-sell-t3s42-9y-fullstress-600w-20260907/report.html) | `84.422` · [報告](../exports/backtest-reports/baseline-d-v24-s35-sn01c-market-low9-sell-t3s42-9y-fullstress-600w-20260907/report.html) | `1.762` · [報告](../exports/backtest-reports/baseline-e-v24-s35-sn01c-market-low9-sell-t3s42-9y-fullstress-600w-20260907/report.html) |
| S36／v25 | 固定三年 | `125.438` · [報告](../exports/backtest-reports/baseline-a-v25-s36-hp04-market-high9-t3s43-9y-fixed3y-600w-20260907/report.html) | `123.201` · [報告](../exports/backtest-reports/baseline-b-v25-s36-hp04-market-high9-t3s43-9y-fixed3y-600w-20260907/report.html) | `123.489` · [報告](../exports/backtest-reports/baseline-c-v25-s36-hp04-market-high9-t3s43-9y-fixed3y-600w-20260907/report.html) | `96.650` · [報告](../exports/backtest-reports/baseline-d-v25-s36-hp04-market-high9-t3s43-9y-fixed3y-600w-20260907/report.html) | `1.184` · [報告](../exports/backtest-reports/baseline-e-v25-s36-hp04-market-high9-t3s43-9y-fixed3y-600w-20260907/report.html) |
| S36／v25 | 全期間 | `114.475` · [報告](../exports/backtest-reports/baseline-a-v25-s36-hp04-market-high9-t3s43-9y-fullstress-600w-20260907/report.html) | `110.275` · [報告](../exports/backtest-reports/baseline-b-v25-s36-hp04-market-high9-t3s43-9y-fullstress-600w-20260907/report.html) | `122.489` · [報告](../exports/backtest-reports/baseline-c-v25-s36-hp04-market-high9-t3s43-9y-fullstress-600w-20260907/report.html) | `85.332` · [報告](../exports/backtest-reports/baseline-d-v25-s36-hp04-market-high9-t3s43-9y-fullstress-600w-20260907/report.html) | `1.762` · [報告](../exports/backtest-reports/baseline-e-v25-s36-hp04-market-high9-t3s43-9y-fullstress-600w-20260907/report.html) |
| S37／v26 | 固定三年 | `127.013` · [報告](../exports/backtest-reports/baseline-a-v26-s37-lp03-flat-low-t3s44-9y-fixed3y-600w-20260908/report.html) | `124.937` · [報告](../exports/backtest-reports/baseline-b-v26-s37-lp03-flat-low-t3s44-9y-fixed3y-600w-20260908/report.html) | `123.491` · [報告](../exports/backtest-reports/baseline-c-v26-s37-lp03-flat-low-t3s44-9y-fixed3y-600w-20260908/report.html) | `96.958` · [報告](../exports/backtest-reports/baseline-d-v26-s37-lp03-flat-low-t3s44-9y-fixed3y-600w-20260908/report.html) | `1.185` · [報告](../exports/backtest-reports/baseline-e-v26-s37-lp03-flat-low-t3s44-9y-fixed3y-600w-20260908/report.html) |
| S37／v26 | 全期間 | `115.536` · [報告](../exports/backtest-reports/baseline-a-v26-s37-lp03-flat-low-t3s44-9y-fullstress-600w-20260908/report.html) | `112.685` · [報告](../exports/backtest-reports/baseline-b-v26-s37-lp03-flat-low-t3s44-9y-fullstress-600w-20260908/report.html) | `122.501` · [報告](../exports/backtest-reports/baseline-c-v26-s37-lp03-flat-low-t3s44-9y-fullstress-600w-20260908/report.html) | `85.328` · [報告](../exports/backtest-reports/baseline-d-v26-s37-lp03-flat-low-t3s44-9y-fullstress-600w-20260908/report.html) | `1.750` · [報告](../exports/backtest-reports/baseline-e-v26-s37-lp03-flat-low-t3s44-9y-fullstress-600w-20260908/report.html) |
| S38／v27 | 固定三年 | `127.013` · [報告](../exports/backtest-reports/baseline-a-v27-s38-lp10-held-nonflat-high9-t3s45-9y-fixed3y-600w-20260908/report.html) | `124.937` · [報告](../exports/backtest-reports/baseline-b-v27-s38-lp10-held-nonflat-high9-t3s45-9y-fixed3y-600w-20260908/report.html) | `123.356` · [報告](../exports/backtest-reports/baseline-c-v27-s38-lp10-held-nonflat-high9-t3s45-9y-fixed3y-600w-20260908/report.html) | `99.047` · [報告](../exports/backtest-reports/baseline-d-v27-s38-lp10-held-nonflat-high9-t3s45-9y-fixed3y-600w-20260908/report.html) | `1.867` · [報告](../exports/backtest-reports/baseline-e-v27-s38-lp10-held-nonflat-high9-t3s45-9y-fixed3y-600w-20260908/report.html) |
| S38／v27 | 全期間 | `115.536` · [報告](../exports/backtest-reports/baseline-a-v27-s38-lp10-held-nonflat-high9-t3s45-9y-fullstress-600w-20260908/report.html) | `112.685` · [報告](../exports/backtest-reports/baseline-b-v27-s38-lp10-held-nonflat-high9-t3s45-9y-fullstress-600w-20260908/report.html) | `122.501` · [報告](../exports/backtest-reports/baseline-c-v27-s38-lp10-held-nonflat-high9-t3s45-9y-fullstress-600w-20260908/report.html) | `86.592` · [報告](../exports/backtest-reports/baseline-d-v27-s38-lp10-held-nonflat-high9-t3s45-9y-fullstress-600w-20260908/report.html) | `1.750` · [報告](../exports/backtest-reports/baseline-e-v27-s38-lp10-held-nonflat-high9-t3s45-9y-fullstress-600w-20260908/report.html) |
| S39／v28 | 固定三年 | `128.455` · [報告](../exports/backtest-reports/baseline-a-v28-s39-hp02-flat-hp01-t3s46-9y-fixed3y-600w-20260909/report.html) | `125.928` · [報告](../exports/backtest-reports/baseline-b-v28-s39-hp02-flat-hp01-t3s46-9y-fixed3y-600w-20260909/report.html) | `126.704` · [報告](../exports/backtest-reports/baseline-c-v28-s39-hp02-flat-hp01-t3s46-9y-fixed3y-600w-20260909/report.html) | `98.908` · [報告](../exports/backtest-reports/baseline-d-v28-s39-hp02-flat-hp01-t3s46-9y-fixed3y-600w-20260909/report.html) | `2.648` · [報告](../exports/backtest-reports/baseline-e-v28-s39-hp02-flat-hp01-t3s46-9y-fixed3y-600w-20260909/report.html) |
| S39／v28 | 全期間 | `117.704` · [報告](../exports/backtest-reports/baseline-a-v28-s39-hp02-flat-hp01-t3s46-9y-fullstress-600w-20260909/report.html) | `113.937` · [報告](../exports/backtest-reports/baseline-b-v28-s39-hp02-flat-hp01-t3s46-9y-fullstress-600w-20260909/report.html) | `123.179` · [報告](../exports/backtest-reports/baseline-c-v28-s39-hp02-flat-hp01-t3s46-9y-fullstress-600w-20260909/report.html) | `85.747` · [報告](../exports/backtest-reports/baseline-d-v28-s39-hp02-flat-hp01-t3s46-9y-fullstress-600w-20260909/report.html) | `0.658` · [報告](../exports/backtest-reports/baseline-e-v28-s39-hp02-flat-hp01-t3s46-9y-fullstress-600w-20260909/report.html) |
| S41／v29 | 固定三年 | `128.121` · [報告](../exports/backtest-reports/baseline-a-v29-s41-hp03a-pullback-market-t3s48-9y-fixed3y-600w-20260910/report.html) | `127.396` · [報告](../exports/backtest-reports/baseline-b-v29-s41-hp03a-pullback-market-t3s48-9y-fixed3y-600w-20260910/report.html) | `126.783` · [報告](../exports/backtest-reports/baseline-c-v29-s41-hp03a-pullback-market-t3s48-9y-fixed3y-600w-20260910/report.html) | `99.386` · [報告](../exports/backtest-reports/baseline-d-v29-s41-hp03a-pullback-market-t3s48-9y-fixed3y-600w-20260910/report.html) | `2.881` · [報告](../exports/backtest-reports/baseline-e-v29-s41-hp03a-pullback-market-t3s48-9y-fixed3y-600w-20260910/report.html) |
| S41／v29 | 全期間 | `117.533` · [報告](../exports/backtest-reports/baseline-a-v29-s41-hp03a-pullback-market-t3s48-9y-fullstress-600w-20260910/report.html) | `115.349` · [報告](../exports/backtest-reports/baseline-b-v29-s41-hp03a-pullback-market-t3s48-9y-fullstress-600w-20260910/report.html) | `123.298` · [報告](../exports/backtest-reports/baseline-c-v29-s41-hp03a-pullback-market-t3s48-9y-fullstress-600w-20260910/report.html) | `84.936` · [報告](../exports/backtest-reports/baseline-d-v29-s41-hp03a-pullback-market-t3s48-9y-fullstress-600w-20260910/report.html) | `0.971` · [報告](../exports/backtest-reports/baseline-e-v29-s41-hp03a-pullback-market-t3s48-9y-fullstress-600w-20260910/report.html) |
| S42／v30 | 固定三年 | `128.121` · [報告](../exports/backtest-reports/baseline-a-v30-s42-hn13-kj-hot-t3s49-9y-fixed3y-600w-20260911/report.html) | `127.396` · [報告](../exports/backtest-reports/baseline-b-v30-s42-hn13-kj-hot-t3s49-9y-fixed3y-600w-20260911/report.html) | `126.895` · [報告](../exports/backtest-reports/baseline-c-v30-s42-hn13-kj-hot-t3s49-9y-fixed3y-600w-20260911/report.html) | `100.940` · [報告](../exports/backtest-reports/baseline-d-v30-s42-hn13-kj-hot-t3s49-9y-fixed3y-600w-20260911/report.html) | `2.938` · [報告](../exports/backtest-reports/baseline-e-v30-s42-hn13-kj-hot-t3s49-9y-fixed3y-600w-20260911/report.html) |
| S42／v30 | 全期間 | `117.533` · [報告](../exports/backtest-reports/baseline-a-v30-s42-hn13-kj-hot-t3s49-9y-fullstress-600w-20260911/report.html) | `115.349` · [報告](../exports/backtest-reports/baseline-b-v30-s42-hn13-kj-hot-t3s49-9y-fullstress-600w-20260911/report.html) | `123.298` · [報告](../exports/backtest-reports/baseline-c-v30-s42-hn13-kj-hot-t3s49-9y-fullstress-600w-20260911/report.html) | `84.936` · [報告](../exports/backtest-reports/baseline-d-v30-s42-hn13-kj-hot-t3s49-9y-fullstress-600w-20260911/report.html) | `0.971` · [報告](../exports/backtest-reports/baseline-e-v30-s42-hn13-kj-hot-t3s49-9y-fullstress-600w-20260911/report.html) |
| S43／v31 | 固定三年 | `129.509` · [報告](../exports/backtest-reports/baseline-a-v31-s43-st01c-pullback-profit-t3s50-9y-fixed3y-600w-20260911/report.html) | `127.644` · [報告](../exports/backtest-reports/baseline-b-v31-s43-st01c-pullback-profit-t3s50-9y-fixed3y-600w-20260911/report.html) | `126.895` · [報告](../exports/backtest-reports/baseline-c-v31-s43-st01c-pullback-profit-t3s50-9y-fixed3y-600w-20260911/report.html) | `101.251` · [報告](../exports/backtest-reports/baseline-d-v31-s43-st01c-pullback-profit-t3s50-9y-fixed3y-600w-20260911/report.html) | `2.936` · [報告](../exports/backtest-reports/baseline-e-v31-s43-st01c-pullback-profit-t3s50-9y-fixed3y-600w-20260911/report.html) |
| S43／v31 | 全期間 | `117.751` · [報告](../exports/backtest-reports/baseline-a-v31-s43-st01c-pullback-profit-t3s50-9y-fullstress-600w-20260911/report.html) | `115.628` · [報告](../exports/backtest-reports/baseline-b-v31-s43-st01c-pullback-profit-t3s50-9y-fullstress-600w-20260911/report.html) | `123.481` · [報告](../exports/backtest-reports/baseline-c-v31-s43-st01c-pullback-profit-t3s50-9y-fullstress-600w-20260911/report.html) | `85.280` · [報告](../exports/backtest-reports/baseline-d-v31-s43-st01c-pullback-profit-t3s50-9y-fullstress-600w-20260911/report.html) | `0.971` · [報告](../exports/backtest-reports/baseline-e-v31-s43-st01c-pullback-profit-t3s50-9y-fullstress-600w-20260911/report.html) |
| S44／v32 | 固定三年 | `129.604` · [報告](../exports/backtest-reports/baseline-a-v32-s44-lp12-late-rebound-t3s51-9y-fixed3y-600w-20260912/report.html) | `127.587` · [報告](../exports/backtest-reports/baseline-b-v32-s44-lp12-late-rebound-t3s51-9y-fixed3y-600w-20260912/report.html) | `126.895` · [報告](../exports/backtest-reports/baseline-c-v32-s44-lp12-late-rebound-t3s51-9y-fixed3y-600w-20260912/report.html) | `101.933` · [報告](../exports/backtest-reports/baseline-d-v32-s44-lp12-late-rebound-t3s51-9y-fixed3y-600w-20260912/report.html) | `3.045` · [報告](../exports/backtest-reports/baseline-e-v32-s44-lp12-late-rebound-t3s51-9y-fixed3y-600w-20260912/report.html) |
| S44／v32 | 全期間 | `118.912` · [報告](../exports/backtest-reports/baseline-a-v32-s44-lp12-late-rebound-t3s51-9y-fullstress-600w-20260912/report.html) | `115.628` · [報告](../exports/backtest-reports/baseline-b-v32-s44-lp12-late-rebound-t3s51-9y-fullstress-600w-20260912/report.html) | `123.481` · [報告](../exports/backtest-reports/baseline-c-v32-s44-lp12-late-rebound-t3s51-9y-fullstress-600w-20260912/report.html) | `86.012` · [報告](../exports/backtest-reports/baseline-d-v32-s44-lp12-late-rebound-t3s51-9y-fullstress-600w-20260912/report.html) | `1.364` · [報告](../exports/backtest-reports/baseline-e-v32-s44-lp12-late-rebound-t3s51-9y-fullstress-600w-20260912/report.html) |

#### 版本與 DecisionBase 關聯

DecisionBase 只對固定窗口建立。v17～v20 的 A～D 使用 `abcd9-v2`、E 使用 `abcde9-v2`；v21～v31 分別使用 `abcd9-v3` 與 `abcde9-v3`。ID key 可連回完整目錄名稱。

| Baseline 版本 | 資料規則 | 規則 commit | DecisionBase 版本 | 規則數與 ID key |
|---|---|---|---|---|
| S29／v17 | `T2/S36` | `91e9e84509806cd4c60d83ec7d8abb1847061ab8` | v6 | 88 條；`s29…t2-s36-91e9e8450980` |
| S30／v18 | `T2/S37` | `3996af3798a52bd488b6aaf2619c5ada70c951b9` | v6 | 89 條；`s30…t2-s37-3996af3798a5` |
| S31／v19 | `T2/S38` | `e4e41e1f1dfecb2fd320d347023a2095366ee0ec` | v6 | 90 條；`s31…t2-s38-e4e41e1f1dfe` |
| S32／v20 | `T2/S39` | `48d42e50ada5dcc0ed2e22dffff6871323daf8b7` | v6 | 91 條；`s32…t2-s39-48d42e50ada5` |
| S32／v21 | `T3/S39` | `d1a5a81aa2736e1f90830bf7ecd25882e19ffb56` | v7 | 91 條；`s32…t3-s39-d1a5a81aa273` |
| S33／v22 | `T3/S40` | `ead1b082576a52143ca567aff1219dc4bf2a12d9` | v8 | 92 條；`s33…t3-s40-ead1b082576a` |
| S34／v23 | `T3/S41` | `a3cc2c6930805d493fad176c4d67998bdc095280` | v9（結構格式 6） | 93 條；`s34…t3-s41-a3cc2c693080` |
| S35／v24 | `T3/S42` | `23cecb8cb84cba356d480292641814065ebda958` | v10（結構格式 6） | 94 條；`s35…t3-s42-23cecb8cb84c` |
| S36／v25 | `T3/S43` | `1d497e717411b195daaf4c18f7575720fb2fc83d` | v11（結構格式 6） | 94 條；`s36…t3-s43-1d497e717411` |
| S37／v26 | `T3/S44` | `ca7e7d13d880c881e534772ae9a74f4aa0a6a2b5` | v12（結構格式 6） | 94 條；`s37…t3-s44-ca7e7d13d880` |
| S38／v27 | `T3/S45` | `6c7d52b167a360efd9b85d9e86c7ae3b79608183` | v13（結構格式 6） | 94 條；`s38…t3-s45-6c7d52b167a3` |
| S39／v28 | `T3/S46` | `2b7484b0eadb06e09378371e44887327b78276c6` | v14（結構格式 6） | 94 條；`s39…t3-s46-2b7484b0eadb` |
| S41／v29 | `T3/S48` | `937221c36d1706cc4fa6d160c8d0c4f9e821cb0b` | v15（結構格式 6） | 94 條；`s41…t3-s48-937221c36d17` |
| S42／v30 | `T3/S49` | `790d9666e9b54a410a6f521c9ee2aea96426c1ef` | v16（結構格式 6） | 95 條；`s42…t3-s49-790d9666e9b5` |
| S43／v31 | `T3/S50` | `4994974ad6a322983ef356b71a231d0e01d84054` | v17（結構格式 6） | 95 條；`s43…t3-s50-4994974ad6a3` |
| S44／v32 | `T3/S51` | `98e049c48e383e898575eee573ddb7caaa6f8bf7` | v18（結構格式 6） | 96條；`s44…t3-s51-98e049c48e38` |

#### S32／v20 股票樣本（50 檔）

本表由 v20 的 A／B／C／D／E 五份固定三年 `baseline.json` 核對：每個樣本各 10 檔，合計 50 個不重複股票代號。它保存 v20 的歷史樣本身分；目前生效的樣本定義仍以[現行回測股票樣本（v2）](現行回測規則.md#現行回測股票樣本v2)為準。

| 樣本 | 群組 1 | 群組 2 |
|---|---|---|
| A | 較強股群：2368 金像電、3533 嘉澤、8046 南電、2308 台達電、3231 緯創 | 較弱股群：9910 豐泰、2882 國泰金、2634 漢翔、8454 富邦媒、1101 台泥 |
| B | 較強股群：3653 健策、1519 華城、3037 欣興、2454 聯發科、2303 聯電 | 較弱股群：1477 聚陽、2317 鴻海、1907 永豐餘、2912 統一超、2642 宅配通 |
| C | 較強股群：3017 奇鋐、3661 世芯-KY、8210 勤誠、2330 台積電 | 較弱股群：2382 廣達、8499 鼎炫-KY、2816 旺旺保、1216 統一、2911 麗嬰房、2002 中鋼 |
| D | 較強股群：2345 智邦、8996 高力、2449 京元電子、1590 亞德客-KY | 較弱股群：6142 友勁、3593 力銘、2028 威致、2201 裕隆、3045 台灣大、1201 味全 |
| E | 弱勢壓力甲組：8473 山林水、4562 穎漢、2462 良得電、2601 益航、2913 農林 | 弱勢壓力乙組：8213 志超、8422 可寧衛*、2354 鴻準、9904 寶成、1301 台塑 |

2026/08/31 另以原候補 10 檔建立 Sample E 全弱勢壓力基準；它沿用同一中央資料池行情與 T2，不重新下載，並以 S29／`T2/S36` 從窗口起點完整重播。固定窗口甲／乙／合計為 `3.312／-1.445／1.868`，全期間為 `3.131／-3.116／0.015`；[E 固定三年](../exports/backtest-reports/baseline-e-v17-s29-lp11-wow-worsening-rebound-lbuy-t2s36-9y-fixed3y-600w-20260830/report.html)／[E 全期間](../exports/backtest-reports/baseline-e-v17-s29-lp11-wow-worsening-rebound-lbuy-t2s36-9y-fullstress-600w-20260830/report.html)。E 的兩組都屬弱勢，不能與 A／B／C／D 的較強／較弱分層混讀；E DecisionBase v6 為 30 個股票窗口、88 條規則並完成 P4b。固定窗口無資金不足；全期間鴻準曾本金不足，列為後續認賠與資金占用研究的壓力證據。

v18 將 E 一併納入正式 Baseline 索引。E 固定窗口為 `2.103`，相對 v17 `+0.235`；全期間為 `0.450`，相對 v17 `+0.435`，且原本唯一發生於鴻準的本金不足已解除。五份固定窗口 DecisionBase 都是 30 個股票窗口、89 條規則並完成 P4b；A～E 固定窗口與全期間均無本金不足。

v19 正式採用 `S-T02h`。固定窗口 A／B／C／D／E 相對 v18 為 `+7.252／+1.081／+1.123／+1.791／-1.661`，A～D 合計 `+11.247`；全期間五樣本依序 `+6.309／+1.294／+4.155／+1.018／+0.347`。五份固定窗口 DecisionBase 都是 30 個股票窗口、90 條規則並完成 P4b；A～E 固定窗口與全期間均無本金不足。

v20 正式採用 `A-N03`。固定窗口 A／B／C／D／E 相對 v19 為 `0／0／+2.048／0／+0.075`；全期間依序為 `0／0／+2.448／0／0`，沒有反轉。C／E 固定窗口 `periods.csv` 與採用候選逐位一致；五份 DecisionBase 都是 30 個股票窗口、91 條規則並完成 P4b，A～E 固定窗口與全期間均無本金不足。

v21 不改策略，只把價格路徑滾動狀態持久化至 T3。原 `T2/S20` 集中資料池保留不覆寫，另由同一批 50 檔行情完整重播建立 `T3/S39` 資料池與 A～E v3 固定輸入分片；十份固定窗口／全期間 `periods.csv` 均和 v20 位元一致，所以各樣本 Delta 都是 `0.000`。五份 DecisionBase v7 各為 30 個股票窗口、91 條規則，完成 `.complete`、`.p4b-complete`、P4b 與 SQLite 完整性核對；A～E 固定窗口與全期間仍均無本金不足。

v22 正式採用 `S-P08`：Grade 為 high／wow、個股價格路徑與決策日前最近完成大盤交易日同為探頂後期時，賣出總分加 1。固定窗口 A／B／C／D／E 相對 v21 為 `+7.123／+4.387／+5.987／+1.518／-0.149`，全期間為 `-0.201／+1.906／+4.779／+0.330／-0.100`。十份 `periods.csv` 均與採用候選逐位一致，並為 0 無效值、0 無成交排除、0 資金不足；十份 `browse.store` SQLite 完整性皆為 `ok`。五份 DecisionBase v8 各為 30 個股票窗口、92 條規則，完成 `.complete`、`.p4b-complete`、P4b、metadata 與 SQLite 完整性核對。A 全期間與 E 固定／全期間的反向幅度很小，保留為外推限制；固定窗口 A～D 全部改善，仍是採用的主要證據。

四組固定窗口與全期間皆為 0 無效值、0 無成交排除。S18 的唯一策略變更是 L-N02 擴充 low＋前日適配趨勢明確分支；固定窗口四樣本合計 +1.140，較強／較弱股群合計 +1.489／-0.349。全期間四樣本合計 -0.404，屬小幅長期壓力風險；改善集中緯創，因此標記待未來新樣本重驗。現行精確股票、窗口、股群與設定見[現行回測規則](現行回測規則.md#現行回測股票樣本v2)。

ABCD v4 不改策略，僅把資料規則推進至 S22，持久保存 Grade 趨勢預警／確認／確認後退回階段。四組固定三年與全期間 `periods.csv` 均和 v3 位元級一致；四份 DecisionBase v5 的核心事件、票、gate 與期末結果也逐列零差異，因此 v4 正式取代 v3 作為後續實驗基準。集中資料池尚未執行 S22，仍只在未來重組樣本前更新。

ABCD v5 正式採用 H-N11：`none` 或 `weak` 以下且決策前 Grade 適配趨勢處於惡化預警／確認時，H買扣 1 分。固定窗口 A／B／C 改善、D 小幅退步，四樣本合計 `+1.645`；全期間四樣本合計 `-2.235`。依 App 以較短週期反覆買賣為主要用途、固定三年窗口為採納主證據的原則，九年單一路徑反證保留為風險揭露而不否決採用。H-N11 會改變 `simUpdate` 決策，因此資料規則由 S22 推進至 S23，T2 不重算；S19 DecisionBase 已以 T2/S23 重建為 83 條規則並完成 P4b。

## 標準化前的舊報告

以下報告早於固定三年與現行分析摘要格式，保留作追溯，不與主表分數直接比較：

- [2026/07/23 初始 600 萬 Baseline](../exports/backtest-reports/baseline-600w-20260723/report.html)
- [2026/07/26 舊窗口 Baseline](../exports/backtest-reports/baseline-600w-20260726/report.html)
- [2026/07/26 H-final 舊窗口報告](../exports/backtest-reports/baseline-h-final-600w-20260726/report.html)

## 後續維護標準

正式採用新版 Baseline 時，同步完成以下紀錄：

1. 在本表追加一列，明寫唯一規則變更、`Tn/Sn`、精確規則 commit，以及 A／B 同樣本前版差異。
2. 連結 A／B 的固定三年與全期間 `report.html`；尚未建立的樣本明寫 `—`。
3. 每份新 HTML 報告的「本版規則變更」必須用完整句子說明舊值、新值及未變部分，不只顯示規則代號。
4. 若重建股票樣本、窗口或技術輸入，明寫不可直接歸因於單一策略規則，避免誤讀分數差異。

### S20／ABCD v6 判讀

v6 新增 `L-P10`，資料規則推進為 `T2/S24`。A／B／C／D 固定三年全部改善，合計 `+3.733`；全期間合計 `+2.749`，其中 B、D 小幅退步，保留為長期路徑風險。四組 DecisionBase 均重建為 84 條正式規則並完成 P4b；資料池未因本次 Baseline 重播而更新 S。

### S21／ABCD v7 判讀

v7 新增 `S-P07`：決策前 Grade 適配趨勢處於惡化預警或惡化確認時，賣出分數加 `1`，不限制交易當時 Grade；資料規則推進為 `T2/S25`。A／B／C／D 固定三年全部改善，合計 `+2.799`；全期間依序 `+5.387／-1.180／+1.701／+3.180`，B 的反向保留為長期路徑風險。八份重播均無異常與本金不足；四組 DecisionBase 重建為 85 條正式規則並完成 P4b。資料池未因本次 Baseline 重播而更新 S25。


### S22／ABCD v8 判讀

v8 把 `L-P10` 的 Grade 條件由 exact `.weak` 擴充為 exact `.weak` 或 `.fine`，仍排除 `.none`；資料規則推進為 `T2/S26`。A／B／C／D 固定三年依序 `+0.139／0／+0.025／0`，全期間依序 `+0.115／0／0／0`，沒有負向窗口或資金代價。改善只來自最近窗口的緯創與世芯-KY，屬有限採用並保留待新樣本重驗。八份重播均無異常、零成交排除與本金不足；四組 DecisionBase 維持 85 條正式規則並完成 P4b。資料池未因本次 Baseline 重播而更新 S26。

### S23／ABCD v9 判讀

v9 擴充 `H-N01a`：`.high／.wow` 在決策前 Grade 適配趨勢有至少 125 筆觀察且處於惡化預警／確認時，也套用 OSC 與 J 同時過熱扣 `1` 分；其他 Grade 與非惡化期間不變。資料規則推進為 `T2/S27`。A 固定三年 `+1.020`，B／C／D 固定三年與四組全期間均為 `0`；改善只來自 A 的金像電 2020/07/22 窗口，屬局部採用，其他樣本有決策差異但期末全數收斂。八份重播均無異常、零成交排除與本金不足；四組 DecisionBase 維持 85 條正式規則，SQLite 完整性與 P4b 均完成。資料池未因本次 Baseline 重播而更新 S27。

### S24／ABCD v10 判讀

v10 調整 `S-N05`：Grade 恰為 `.wow` 且決策前適配趨勢觀察數足夠、處於惡化預警或惡化確認時，不再因 `vZ125 > 1` 扣惜賣一分；`.high`、非惡化期間與其他規則維持不變。資料規則推進為 `T2/S28`。A／B／C／D 固定三年依序 `+0.526／+0.468／-0.718／+2.361`，合計 `+2.637`；全期間依序 `+0.210／-0.365／-0.281／-1.352`。固定窗口 A、B、D 的改善支持 `.wow` 惡化時提高退出敏感度，C 退步集中奇鋐兩個較早窗口；D 較弱股群另有 `-0.045` 小幅代價。依固定三年為主要證據的原則採用，九年反向保留為長路徑風險。八份重播均無異常、零成交排除與本金不足；四組 DecisionBase 維持 85 條正式規則，SQLite 完整性與 P4b 均完成。資料池未因本次 Baseline 重播而更新 S28。

### S25／ABCD v11 判讀

新增 `S-T02e`，以交易當時有效 Grade 分流 90 日提前認賠資格；不自行增加賣出票，仍須通過既有 `S-T02a` 票數與 `S-T02d` 冷卻。A／B／C／D 固定三年相對 v10 分別 `+21.127／+18.921／+22.102／+7.701`，全期間亦皆為正；八份重播均無資料異常、無零成交排除、無資金不足。這只能稱為目前選定樣本內同向，不代表新樣本仍會穩定成立。

### S26／ABCD v12 判讀

v12 調整 `A-P05`：MA20 或 MA60 差低於 `-20` 的原加碼票維持，但交易當日 Grade 恰為 `.wow` 且適配趨勢處於惡化預警或惡化確認時不加分；其他 Grade、趨勢階段與加碼規則不變。A／B／C／D 固定三年相對 v11 為 `+0.632／+2.302／+7.464／+0.187`，全期間為 `-0.167／+3.768／+0.465／+0.852`。A 全期間小幅退步與 Sample C 世芯-KY 2023 集中改善均保留為風險；八份重播無異常、零成交排除與資金不足，四份 DecisionBase維持 86條正式規則並完成 P4b。T2未重算，集中資料池未因本次 Baseline重播而更新 S30。

### S26／AB v13～v14 判讀

v13 把 Grade 改善／惡化確認拆成探頂／拉回及探底／反彈，v14 再把兩方向起轉門檻統一為 `0.3`；既有策略都使用分段聯集，因此 A／B 固定窗口與全期間分數相對 v12 精確不變。兩版只重播 A／B，C／D 未建立 v13／v14 正式報告；先前歷史表漏列這兩版，本次補回以免誤判版本跳躍。

### S27／ABCD v15 判讀

v15 新增 `S-T02g`：已有 `S-T02a` 所需賣出票、交易當日 Grade 為 high／wow、持股超過 120 日且 ROI 仍低於或等於 -17.5% 時獨立認賠，不受 `S-T02d` 最近 60 日無加碼限制。A／B／C／D 固定窗口相對 v14／同策略歷史基準依序 `+1.897／+5.629／-0.279／+0.989`，四組合計 `+8.236`；A／B 全期間 `+5.847／+7.037`。C 的反向只集中世芯-KY 2020 窗口，ROI 減少 `2.074` 個百分點但平均週期縮短 `0.847` 日；依既定效率分數判讀，不另以主觀 ROI／週期權重重算。六份正式重播均無異常、零成交排除與本金不足；四份 DecisionBase 含 87 條正式規則，SQLite 完整性與 P4b 均完成。C／D 全期間未重跑，不以舊版結果冒充 v15。

曾以 commit `e3a923400a52756d8eab3c7a441ae10aae6f7769` 產生同分的 v15／`T2/S33` 過渡產物，但新增正式賣出規則時漏推進 simUpdate 狀態版號，因此不構成正式 Baseline。修正 commit `5f26225ab7d77494131889cc09147aa4efd1efa7` 將狀態推進至 S34，並以 `T2/S34` 完整重播；新舊 `periods.csv` 逐位一致，確認修正只補正版本與遷移語意，沒有改變策略結果。

### S28／ABCD v16 判讀

v16 新增 `G-M02`：前次自動完整賣出以負損結案後啟用認賠降級，以正報酬結案後解除；只在惡化確認探底期把 H／L／S／A 共用的決策 Grade 降一級，`.fine` 直接降為 `.weak`，最低停在 `.low`。自然 Grade 與持久 schema 不變。A／B／C／D 固定窗口相對 v15 為 `+1.006／+2.024／+0.284／-0.237`，合計 `+3.077`；A／B 全期間為 `-0.712／+5.855`。A 的較弱股群與台泥長期退步、B 的聯電與聚陽集中改善都保留為路徑風險，不以九年單一起始路徑取代固定窗口主證據。

正式採用會改變逐日 `simUpdate` 結果，因此資料規則推進為 `T2/S35`，但不新增 schema 欄位。完整重播以滾動狀態更新；Yahoo 當日只回找一次前態，P10 十個價格情境共用同一正式前態。六份正式報告均無異常、零成交排除與本金不足，且 `periods.csv` 與候選逐位一致；四份 DecisionBase 含 87 條正式投票規則，SQLite 完整性與 P4b 均完成。C／D 全期間未重跑，不以舊版結果冒充 v16。

### S29／ABCD v17 判讀

v17 新增 `L-P11`：決策 Grade 達 `.wow`、適配趨勢觀察已暖機且處於惡化反彈時，L買加 `1` 分；它只提供一票，不單獨形成買進。A／B／C／D 固定窗口相對 v16 為 `+0.300／+1.793／+0.000／+0.153`，合計 `+2.246`；較強／較弱股群合計 `+2.326／-0.080`。正向結果涵蓋 A 南電、B 聯電／欣興／華城與 D 裕隆，B 的欣興仍是最大單一來源。

A／B 全期間相對 v16 為 `-0.819／-0.157`，描述性合計 `-0.976`，列為九年單一路徑風險，不取代四組固定窗口主證據。正式 App 因新增逐日買入規則推進為 `T2/S36`，不增加 schema 欄位且不重算 T2；六份正式報告均無異常、零成交排除與本金不足。四份 DecisionBase 各含 88 條正式規則，`.complete`、`.p4b-complete` 與 SQLite 完整性均通過；集中資料池未因本次 Baseline 重播而更新 S36。

Sample E 是 v17 採用完成後新增的壓力基準，不倒推為 L-P11 的第五組採用證據。E 固定窗口與全期間分數為 `1.868／0.015`；固定窗口 30 個股票窗口皆正常，全期間鴻準曾本金不足。E DecisionBase ID 為 `e-abcde9-v2-s29-lp11-wow-worsening-rebound-lbuy-20260830-t2-s36-91e9e8450980-fixed3y-20260722-v6`，含 95,608 個決策事件、88 條規則，完成標記、P4b 與 SQLite 完整性均通過。

<a id="s30abcde-v18-判讀"></a>
### S30／ABCDE v18 判讀

v18 新增 `H-N12`：最近一次有效自動完整結案為虧損、目前空手且交易當日決策 Grade exact `.damn` 時，H買扣 `1` 分；後續有效獲利完整結案會解除認賠狀態。它只降低這個局部情境的追高意願，不修改自然 Grade，也不改 L買、賣出或加碼。正式規則 commit 為 `3996af3798a52bd488b6aaf2619c5ada70c951b9`，策略推進為 S30，資料規則推進為 `T2/S37`；S37 不增加 schema 欄位、不重算 T2，並沿用既有人工操作重播語意。

A／B／C／D／E 固定窗口相對 v17 為 `-0.042／+0.000／-0.013／+0.150／+0.235`；A～D 合計 `+0.096`，五組合計 `+0.331`。A～D 的差異只出現在較弱股群，較強股群零差異。正向涵蓋鴻準、台塑與裕隆，反向包含益航、富邦媒與鼎炫-KY；這表示規則只在弱勢認賠後重進場情境形成小幅淨改善，不代表可外推至所有股票。

A／B 全期間逐位不變；E 全期間由 `0.015` 提高至 `0.450`，差異只在原本唯一發生本金不足的鴻準：ROI `-8.222% → -6.830%`、平均週期 `83.43 → 56.24` 日、完成輪次 `21 → 52`，本金不足解除。C／D 全期間分別為 `106.445／81.221`，較強／較弱股群分別為 `98.662／7.783`、`74.432／6.789`，未發現資金失控或資料異常。十份正式報告都為 0 無效值、0 無成交排除、0 本金不足；固定 A～E 與候選 S1 的 `periods.csv` 逐位一致，A／B 全期間與 v17 逐位一致，E 全期間與 S1 壓力候選逐位一致。五份 DecisionBase 各含 89 條正式規則，完成標記、P4b 與 SQLite 完整性均通過。

<a id="s31abcde-v19-判讀"></a>
### S31／ABCDE v19 判讀

v19 新增獨立認賠資格 `S-T02h`：持股超過 120 日、`-25% < ROI < 0%`、已有 `S-T02a` 所需賣出票、Grade 連續效率分數 `< -10`，且最近 60 個交易日沒有加碼時允許賣出；它不取代 `S-T02e／S-T02g`。正式規則 commit 為 `e4e41e1f1dfecb2fd320d347023a2095366ee0ec`，策略推進為 S31，資料規則推進為 `T2/S38`。S38 不增加 schema 欄位、不重算 T2，正式 App 須從最早受影響日重播 `simUpdate`，並沿用既有人工反轉與手動加碼的保留、冗餘清除及無效清除語意。

2026/09/01 修正 v19 的規則 commit metadata：原先誤寫為不存在但同具 `e4e41e1` 前綴的 `e4e41e1c4e834d8ee3a2f00a7a9ae156fbb65a92`，實際正式 commit 為 `e4e41e1f1dfecb2fd320d347023a2095366ee0ec`。本次只更正十份報告、五份 DecisionBase、完成標記與文件中的 commit／DecisionBase 身分；`periods.csv`、`browse.store`、DecisionBase 非 metadata 內容及所有分數均未重算且修正前後 checksum 相同。

A／B／C／D／E 固定窗口相對 v18 為 `+7.252／+1.081／+1.123／+1.791／-1.661`；A～D 合計 `+11.247`，若只作描述性相加，五組合計 `+9.586`。15 個樣本窗口有 10 個正向、5 個反向。較強／較弱股群 Delta 分別為 A `+8.295／-1.043`、B `+1.200／-0.120`、C `+0.546／+0.577`、D `+1.498／+0.293`；E 弱勢壓力甲／乙為 `-1.694／+0.033`。因此採用證據以 A～D 固定窗口總體改善為主，但仍保留 A／B 較弱股群小退與 E 固定窗口反證，不宣稱普遍有效。

A／B／C／D／E 全期間相對 v18 為 `+6.309／+1.294／+4.155／+1.018／+0.347`，五組皆正向；股群 Delta 依序為 A `+6.309／0`、B `+1.294／0`、C `+1.897／+2.258`、D `0／+1.018`、E `+0.096／+0.251`。全期間只作路徑與資金風險確認，不取代固定窗口證據。十份正式報告均為 0 無效值、0 無交易排除、0 本金不足；五份 DecisionBase 各含 30 個股票窗口與 90 條正式規則，完成標記、P4b 及 SQLite 完整性均通過。D 固定窗口與全期間 `periods.csv` 也分別和已核准的 S2 候選逐位一致。

先前只依 A／B／C／E 的第一個候選分歧都高於 `-25%`，暫時推論 S2 全程會沿用 S1 分數；v19 的正式完整重播證明這不能當成整條後續路徑的等價證據。A 與 C 的精確 S2 Delta 應以 v19 的 `+7.252／+1.123` 為準，不再沿用 S1 的 `+7.283／+1.385`；B、D、E 則分別為 `+1.081／+1.791／-1.661`。

<a id="s32abcde-v20-判讀"></a>
### S32／ABCDE v20 判讀

v20 新增 `A-N03`：交易當日 Grade exact `.wow`、適配趨勢已暖機、階段不是惡化確認探底，且 `A-P02` 多項九日低點票未成立時，對整體 `aWant` 獨立扣 `1` 分。它不移除 `A-P02`，也不修改其他加碼票；作用是讓尚無低點證據、剛好位於加碼門檻的局部事件延後或取消。正式規則 commit 為 `48d42e50ada5dcc0ed2e22dffff6871323daf8b7`，策略推進為 S32，資料規則推進為 `T2/S39`。S39 不增加 schema 欄位、不重算 T2；正式 App 須從最早受影響日重播 `simUpdate`，並沿用人工反轉與手動加碼的既有保留、冗餘清除及無效清除語意。

A／B／C／D／E 固定窗口相對 v19 為 `0／0／+2.048／0／+0.075`。C 的改善只在 2017 較強股群，世芯-KY 延後兩次加碼至 `A-P02` 已成立且價格更低，經較佳成本、動態 Grade 與既有 `S-T02g` 提前釋放資金；E 的改善只在 2020 弱勢壓力甲組，益航把加碼延後 21 個日曆日至 `A-P02` 已成立。其餘樣本、股群與窗口零退步，C／E 的正式 `periods.csv` 與候選逐位一致。

全期間 A／B／C／D／E 相對 v19 為 `0／0／+2.448／0／0`；C 仍同向改善，沒有長路徑反轉。十份正式報告都是 0 無效值、0 無交易排除、0 本金不足，所有股票狀態正常。五份固定窗口 DecisionBase 各含 30 個股票窗口與 91 條正式規則，`.complete`、`.p4b-complete`、manifest 身分、規則 commit 及 SQLite 完整性均通過。

正式化驗證另完成 43 項 `RecalculationTests`、0 失敗，以及 13 吋 Simulator Debug build。測試涵蓋 S32→S39 與舊版→`T2/S39` 重播、人工操作保留及 Yahoo／P10 遷移閘門。建立 Sample E 固定窗口前曾遇 Simulator 啟動服務的 Mach `-308` 中止；當次沒有產物，取消 pending launch 並乾淨重啟同一裝置後，原參數重播完成，未重跑已完成的 A～D，也未刪除 App 或資料。

<a id="s32abcde-v21-判讀"></a>
### S32／ABCDE v21 判讀

v21 不改策略，將 20 日價格路徑的九階段、凍結門檻、錨點、運行極值及未創新極值日數持久化，資料規則由 `T2/S39` 推進為 `T3/S39`。正式 App 實作 commit 為 `d1a5a81aa2736e1f90830bf7ecd25882e19ffb56`；正式 H買、L買、賣出、加碼及 Grade 規則都不讀取新增欄位。

原 50 檔 T2 集中資料池保留不覆寫，另以相同行情完整重播建立 T3/S39 資料池及 A～E v3 固定輸入分片。十份正式 Baseline v21 的固定窗口／全期間 `periods.csv` 全部和 v20 位元一致，A～E 分數與 v20 的 Delta 均為 `0.000`；0 無效值、0 無成交排除、0 本金不足。五份 DecisionBase v7 各含 30 個股票窗口與 91 條正式規則，完成標記、P4b、manifest 身分及 SQLite 完整性均通過。v21 因此正式取代 v20 作為後續比較基準，但不構成新的策略採用。


<a id="s34abcde-v23-判讀"></a>
### S34／ABCDE v23 判讀

v23 採用原始 RP-S03 為 `S-P09`：決策當日個股價格路徑為探底前期，賣出總分獨立加 1；不限定 Grade、大盤、MA60 或持股 ROI，不納入後期。既有 S-P08 與其他規則不變。策略 S34、資料 `T3/S41`，不新增 schema、不重算 tUpdate；模擬與人工操作沿用既有遷移、保留及重驗語意。

正式規則 commit：`a3cc2c6930805d493fad176c4d67998bdc095280`。A／B／C／D／E 固定三年相對 v22 為 `+1.373／+2.826／+0.727／+0.706／-0.192`；全期間為 `+1.791／+1.136／+5.404／+1.836／+0.220`。固定三年是主證據；A～D 合計 `+5.631`、較強股群 `+5.569`，但 E 固定窗口微退、B／C 較弱股群全期間及個股反向仍保留為限制，不宣稱普遍有效。

十份正式報告的 periods.csv 全部與原始 RP-S03 候選逐位一致；0 無效值、0 無成交排除、0 本金不足，所有股票狀態正常。十份 browse.store 均為 T3/S41 且 SQLite 完整。五份 DecisionBase v9 各含 30 個股票窗口與 93 條正式規則；完成標記、P4b、manifest、metadata、規則 commit、事件數與 S-P09 逐筆範圍／票數都通過。資料世代 v9 不表示 SQLite 格式有變更，其 formatVersion 仍為 6。

66 項聚焦測試已通過（50 項重算、16 項價格路徑）：第一次只因一處舊測試仍期待 S40 而失敗，改為 S41 後重跑整組價格路徑全部通過；S40→S41 測試確認不重算技術值並重驗人工操作。完整核對見[本機驗證結果](../exports/baseline-v23-verification.json)，重現腳本為 `exports/verify-baseline-v23.py`。建立 Baseline 時尚未 push／發布；發布另依[發布流程](發布流程.md)執行，集中資料池及固定輸入分片未覆寫。

<a id="s35abcde-v24-判讀"></a>
### S35／ABCDE v24 判讀

2026/09/07 正式採用 SN01-L9-S5 為 `S-N01c`，不是未限制價格階段的 S4。原 a／b 均不成立，前一完整市場日最低指數等於含該日的九日最低、決策 Grade 有效且低於 wow，並排除「個股價格探頂後期且 Grade ≥ fine」時，賣出減 1；a／b／c 合計最多減 1。原 a／b、S-P08／S-P09 及其他條件不變。策略 S35、資料 T3/S42；規則 commit 為 `23cecb8cb84cba356d480292641814065ebda958`。

固定三年 A／B／C／D／E 相對 v23 為 `+0.431／+1.311／+1.003／+0.176／+1.008`；均衡樣本 A～D 合計 `+2.921`，E 另作弱勢壓力證據。這項交互排除恢復 D 亞德客與高力的兩個最早窗口，但 B／D 較強股群仍各退步 -0.422／-0.294；E 穎漢中間窗口相較正式 ROI 降至 2.307%、週期由 57.222 延至 65.133 日，代價未被消除。所有樣本都曾用於假說形成，因此只作特選樣本內有限採用，不稱未見樣本驗證或普遍有效。

全期間 A／B／C／D／E 為 `114.705／108.200／122.471／84.422／1.762`，對 v23 差額 `+1.638／+1.432／-0.761／+0.016／+0.845`。C 合計退步主要來自奇鋐週期 29.853→31.408 日、較強股群 -1.708；D 較強股群 -0.505，合計僅微增。E 甲組 +0.872 主要集中良得電，乙組 -0.027，兩組週期都有延長。中鋼、台灣大等個股亦有較長資金占用；這些反證保留，但沒有資料錯誤、資金失控或跨樣本重大退步，不提高全期間權重來否決固定三年主證據。

十份完成標記、manifest／baseline 的完整規則 commit、同一輸入截止／資金／窗口、SQLite、股票 T3/S42 與空 dirty 標記均通過。全部價量與持久技術值和 v23 逐值相同，無效值、無成交排除、本金不足及非正常股票狀態都是 0。五份固定 `periods.csv` 與 S5 位元一致；五份 DecisionBase v10 共 467,148 個決策與各票，對 S5 完整串流逐筆相同，只把候選 ID 轉為 S-N01c。每份各 94 條規則、30 個股票窗口，P4b 與 SQLite metadata 均核對；結構格式仍為 6。

94 項相關測試覆蓋市場值、價格路徑、Grade 趨勢、完整／局部重算及人工操作。初次只有舊版號斷言仍期待 S41；改為 S42 後，29 項市場與價格路徑測試整組重驗通過，其餘 65 項已通過。明細見[完整核對](../exports/baseline-v24-verification.json)與[測試重驗](../exports/baseline-v24-test-recheck.json)，重現為 `python3 exports/audit-baseline-v24.py`。正式 runner 為 [run-formal-market-low9-baseline-v24.sh](../scripts/run-formal-market-low9-baseline-v24.sh)。

本次不新增 schema，不重算個股 T3；市場版本維持 2，先完成正式輸入及必要市場補算，再重播 S42 並重驗人工反轉與加碼。集中資料池、固定輸入分片及歷史候選均不覆寫。規則與文件已分階段提交，不 push／發布；App 安裝版本以裝置與 latest 為準。

<a id="s36abcde-v25-判讀"></a>
### S36／ABCDE v25 判讀

2026/09/07 正式採用 HP04-H9-S4，納入原 H-P04 而非新增獨立負票。原爆量條件成立時，決策 Grade ≥ fine、前一完整市場日最高等於含該日九日最高且非探頂前期、當次 Grade 趨勢預覽非中性，原 +1 改為 0。市場資料不足保留原票，其他規則不變。策略 S36、資料 T3/S43，規則 commit `1d497e717411b195daaf4c18f7575720fb2fc83d`。

固定三年 A／B／C／D／E 相對 v24 為 **+0.892／+0.596／0／+0.261／0**；七個正向股票窗口保留，E 的 S3 負例恢復。不是每組都有收益，也不是未參與條件形成的全面驗證；A／B／E 的結果曾用於縮限條件，效果仍稀疏。採用依據為有限但可解釋的改善與其他樣本未見新增代價，不再為追求普遍性疊條件。

全期間差額為 **-0.231／+2.075／+0.018／+0.910／0**。A 主要受緯創 ROI -0.951 個百分點、平均週期 +0.383 日影響；豐泰 ROI 微減但週期縮短，富邦媒改善。B 改善主要來自聯電；C 僅世芯-KY 微幅變更。D 改善集中裕隆，力銘 ROI -0.147 個百分點、週期 +1.068 日，弱群平均週期 +0.187 日。E 完全相同。這些集中度與負向結果保留，沒有資金失控、資料錯誤或跨樣本普遍重大退步需要暫停採用。

十份報告的完成標記、manifest／baseline、精確 commit、同源市場輸入、窗口、資金及加碼設定全部核對。五份固定 `periods.csv` 與 S4 逐位元一致，五份 DecisionBase v11 共 **467,136 個決策**及票數與 S4 完整串流逐筆一致；每份 94 條規則、30 個股票窗口，P4b、SQLite metadata 與完整性通過，結構格式仍為 6。全部價量及持久技術值與 v24 逐值一致，股票 T3/S43、dirty 標記為空；無效值、無成交排除、資金不足與異常狀態皆為 0。D／E 全期間也與先前 S4 壓力產物逐位一致。

核對結果分樣本保存：[A](../exports/baseline-v25-verification-A.json)、[B](../exports/baseline-v25-verification-B.json)、[C](../exports/baseline-v25-verification-C.json)、[D](../exports/baseline-v25-verification-D.json)、[E](../exports/baseline-v25-verification-E.json)；重現為 `python3 exports/audit-baseline-v25.py`，正式 runner 為 [run-formal-high9-baseline-v25.sh](../scripts/run-formal-high9-baseline-v25.sh)。34 項市場／價格路徑與 2 項遷移／盤中閘門測試通過；正式比較另驗證所有決策及票數。

App v3.4.3（61）／T3/S43 的正式 Release 已覆蓋安裝至既有九年資料的 10.2 吋模擬裝置，以一般互動模式完成 10 檔重算，6 筆人工操作全部保留、清除 0。交易資料前後均 24,690 筆，原資料已備份、未以 Baseline 替換，裝置保持開機；[安裝核對](../exports/s43-ipad10-install-verification.json)。本次不新增 schema、不重算個股 tUpdate，只重播 simUpdate；市場技術版本維持 2。尚未 push／發布，集中資料池及固定輸入未覆寫。

<a id="s37abcde-v26-判讀"></a>
### S37／ABCDE v26 判讀

2026/09/08 正式採用 LP03-FLAT-GT-S5，納入 L-P03 原票數而非另設負票。空手、價格盤整，且「已暖機決策 Grade 惡化探底後期 OR Grade <= low」時取消原 +1，其他條件不變。規則身分及版本見上表；[發現與驗證過程](回測規則驗證.md#lp03-flat-gt-s5-adoption)保留 S2～S5 的取捨，不恢復 S4 拉回後期或為單股加例外。

固定三年相對 v25，A～E 為 +1.575／+1.736／+0.003／+0.308／+0.001；主要改善在 A／B，C／E 接近持平，不能稱普遍有效。中鋼、味全、穎漢等局部負向與台達電 ROI 微降仍保留。全期間差額 +1.061／+2.410／+0.012／-0.004／-0.013，D／E 小退，未見資料錯誤、資金失控或跨樣本重大退步，不推翻固定窗口主要證據。

十份固定／全期間 periods.csv 均與 S5 逐位元一致；五份 DecisionBase v12 共 467,002 個決策及全部票數，與原 v25 加 S5 Delta 還原的完整串流逐筆一致。每份 94 條規則、30 個股票窗口，P4b、完成標記、SQLite 完整性與 metadata、完整規則 commit、T3/S44、策略 S37、截止日、資金及凍結市場輸入均通過。全部價量與持久技術值和 v25 逐值一致，股票版本完成且 dirty 為空；無效值、無成交排除、資金不足及異常狀態皆為 0。

核對結果：[A](../exports/baseline-v26-verification-A.json)、[B](../exports/baseline-v26-verification-B.json)、[C](../exports/baseline-v26-verification-C.json)、[D](../exports/baseline-v26-verification-D.json)、[E](../exports/baseline-v26-verification-E.json)；重現為 `python3 exports/audit-baseline-v26.py`。正式 runner 為 [run-formal-flat-low-baseline-v26.sh](../scripts/run-formal-flat-low-baseline-v26.sh)。72 項規則邊界、價格路徑、重算與人工操作等測試通過。

10.2 吋既有九年裝置已安裝 v3.4.3（61）／T3/S44 正式 Release，一般模式完成 10 檔重算、7 筆人工操作全數保留，原資料庫已備份，交易資料前後皆 24,700 筆；[安裝核對](../exports/s44-device-verification/verification.json)。只重播 simUpdate，不重算個股 tUpdate，不新增 schema；市場版本維持 2。13 吋同步本版正式瀏覽副本，兩裝置保持開機。App／Build 暫維持，S44 尚未 push／發布；集中資料池、固定輸入與工作交接未改。

<a id="s38abcde-v27-判讀"></a>
### S38／ABCDE v27 判讀

2026/09/08 正式採用 LP10-HELD-NONFLAT-H9-S5，擴充 L-P10：原 weak／fine 恢復票不變，新增持股 exact low、個股價格非盤整且前一完整市場日最高＝九日最高的分支，仍須既有恢復條件成立，L買加一票。不是交易禁令或直接加碼；其他規則及本金收回語意不變。[驗證與採用](回測規則驗證.md#lp10-held-nonflat-h9-s5-adoption)保留 S1～S5、Grade 歷史分析與資金反證，不宣稱專對長期弱勢有效。

固定三年相對 v26，A～E 為 0／0／-0.135229／+2.089561／+0.681953；全期間為 0／0／0／+1.263893／0。正向集中固定 D／E，C 小幅代價與 E 最新可寧衛、農林的反向仍須接受；尤其可寧衛 ROI +2.359160%→-15.977460%，不因九年零差異而抹除。九年保留京元改善，S4 鴻準負結餘停滯未重現；這是局部有效的採用，不是全面普遍性結論。

十份 periods.csv 均與凍結 S5 逐位元一致，十份 browse.store 的模擬／滾動持久欄位也逐日相同；五份 DecisionBase v13 共 466,818 個決策及全部票數，與 v26 加 S5 Delta 還原的串流逐筆一致。每份 94 條規則、30 個股票窗口；P4b、完成標記、SQLite／metadata、精確 commit、T3/S45、策略 S38、截止日、資金及凍結市場身分均通過。價量與持久技術值相對 v26 零差異，目標股票均完成 T3/S45 且無 dirty；無效值、無成交排除、負結餘、資金不足旗標及異常狀態均為零。

核對結果：[A～C](../exports/baseline-v27-verification-ABC.json)、[D](../exports/baseline-v27-verification-D.json)、[E](../exports/baseline-v27-verification-E.json)；重現為 `python3 exports/audit-baseline-v27.py`。正式 runner 為 [run-formal-recovery-low-baseline-v27.sh](../scripts/run-formal-recovery-low-baseline-v27.sh)。74 項規則邊界、價格路徑及重算／人工操作測試、2 項負結餘摘要測試通過，Release 建置成功。B 報告已核對載入同版 A，不沿用舊版交叉樣本參照。

10.2 吋已覆蓋安裝 v3.4.3（62）／T3/S45 正式 Release，以一般可操作模式完成 10 檔重算，7 筆人工操作全數保留、清除 0；原庫已備份，前後 24,700 筆交易及技術值完全一致，[安裝核對](../exports/s45-device-verification/verification.json)。只重播 simUpdate，不重算 tUpdate、不新增 schema；13 吋保留最新正式 A 全期間瀏覽副本，兩裝置保持開機。尚未 push／發布；集中資料池、固定輸入與其他交談的工作交接未改。

<a id="s39abcde-v28-判讀"></a>
### S39／ABCDE v28 判讀

規則 commit：`2b7484b0eadb06e09378371e44887327b78276c6`；正式採用 H-P02／S4，T3/S46。固定三年仍為主要採用證據，九年作單一路徑風險觀察。

相對 v27，固定三年 A～E 差分為 +1.442398／+0.990944／+3.348396／-0.138592／+0.781682；九年為 +2.167893／+1.251980／+0.677713／-0.844592／-1.092050。

十份 periods.csv 與凍結 HP02-FLAT-S4 逐位元一致，十庫模擬／滾動持久值逐日相同，價量與技術值和 v27 零差異；五份 DecisionBase v14 共 466,779 個決策及全部票數與 v27 加 S4 Delta 還原結果逐筆一致。每份含 94 條規則、30 個股票窗口，結構格式 6；完成標記、P4b、SQLite、完整 commit、T3/S46、策略 S39、截止日及資金設定均核對通過。十庫無負結餘、無效值、無成交排除或異常狀態旗標；不將無負結餘解讀成無資金占用代價。

D 固定巨大負分已縮小，原南電、友勁／台灣大等改善消失與 E 寶成中間窗代價仍保留。益航九年最高投入 4→6 倍（2,400→3,600 萬）、深虧例外 1→3 次、同輪持股 609→1,833 日及平均週期 59.52→109.03 日，已由使用者確認接受；不以全期總分或正結餘抹除該代價。完整選擇與反證見[採用紀錄](回測規則驗證.md#hp02-flat-s4-adoption)。

驗證：[A](../exports/baseline-v28-verification-A.json)、[B](../exports/baseline-v28-verification-B.json)、[C](../exports/baseline-v28-verification-C.json)、[D](../exports/baseline-v28-verification-D.json)、[E](../exports/baseline-v28-verification-E.json)；重現為 `python3 exports/audit-baseline-v28.py A`（依序至 E）。正式 runner 為 [run-formal-flat-high-baseline-v28.sh](../scripts/run-formal-flat-high-baseline-v28.sh)，須指定上述完整規則 commit，不覆寫既有產物。B 固定與全期報告均載入同版 A 作樣本敏感度比較。

10.2 吋已在採用時完成正式 Release v3.4.3（64）／T3/S46 重算，10 檔升版、7 筆人工操作全數保留，24,700 筆交易及技術值一致；本次測試後已恢復同版 Release；原 24,700 筆交易逐欄未變，正常啟動後新增當日 10 筆 Yahoo 盤中行情，7 筆人工操作仍保留。13 吋已更新為 v28 A 全期間瀏覽副本，兩台保持開機。未 push／發布。

本次新產生的十份 HTML 另修正樣板殘留的「初始基準／不與舊窗口比較」三處文字，數值不變；原 HTML 保存在 `exports/baseline-v28-original-html/`，修正前後雜湊及腳本見 `exports/baseline-v28-rendering-verification.json`。此顯示修正與後續文件提交不改變上述實際計算的規則 commit；歷史 v27 報告未動。


<a id="s41abcde-v29-判讀"></a>
### S41／ABCDE v29 判讀

規則 commit：`937221c36d1706cc4fa6d160c8d0c4f9e821cb0b`；正式採用 H-P03a／S3，T3/S48／策略 S41。S47／S2 的採用後續曾暫停，未建立 Baseline；v29 直接以 S48 與 v28 比較，不補造 S47 Baseline。

相對 v28，固定三年 A～E 差分為 -0.334228／+1.467600／+0.078946／+0.477569／+0.232047；九年為 -0.170591／+1.412008／+0.119283／-0.811311／+0.313737。固定三年仍為主要採用證據，九年作單一路徑風險觀察。

十份 periods.csv 與凍結 HP03A-PULLBACK-MKT-S3 逐位元一致，十庫模擬／滾動持久值逐日相同，價量與技術值和 v28 零差異；五份 DecisionBase v15 共 466,881 個決策及全部票數與 v28 加 S3 Delta 還原結果逐筆一致。每份含 94 條規則、30 個股票窗口，結構格式 6；完成標記、P4b、SQLite、完整 commit、T3/S48、策略 S41、截止日及資金設定均核對通過。十庫無負結餘、無效值、無成交排除或異常狀態旗標；不把無負結餘解讀成無資金占用代價。

固定 D 轉正、A 負向縮小、B／C 正向保留，E 台塑報酬代價縮小但週期仍較長。九年高力回正式，最長持股 154 日及加碼 20 次不再增加；D 京元仍負，且其報酬低於 S2。A／台塑負例、B 與最近窗集中度保留，不因建立 Baseline 重寫結論。九年 50 檔加碼／最高投入／超次／最長與期末持股皆與 v28 一致，華城與鼎炫中途最長空手為 17／37 交易日；益航等既有資金／週期例外仍在。完整判讀見 [S3 九年與採用](回測規則驗證.md#hp03a-pullback-mkt-s3-full)。

驗證：[A](../exports/baseline-v29-verification-A.json)、[B](../exports/baseline-v29-verification-B.json)、[C](../exports/baseline-v29-verification-C.json)、[D](../exports/baseline-v29-verification-D.json)、[E](../exports/baseline-v29-verification-E.json)；重現為 `python3 exports/audit-baseline-v29.py A`（依序至 E）。正式 runner 為 [run-formal-pullback-market-baseline-v29.sh](../scripts/run-formal-pullback-market-baseline-v29.sh)，須指定上述完整規則 commit，不覆寫既有產物。各 HTML 分別記錄 T/S 與策略版本及完整 commit；B 固定／全期間均載入同版 A 作樣本敏感度比較。

10.2 吋採用時已完成 Release v3.4.4（67）／T3/S48 重算；本次測試後恢復同版正常模式，24,710 筆／110 欄與七筆人工操作均未變。13 吋已更新為 v29 A 九年瀏覽副本，兩台保持開機。規則及完成文件依核准流程提交；未 push／發布，GitHub latest 仍為 v3.4.4（65）／T3/S46（沿用上次已驗證發布紀錄，本輪未重新查詢遠端）。


<a id="s42abcde-v30-判讀"></a>
### S42／ABCDE v30 判讀

精確規則 commit `790d9666e9b54a410a6f521c9ee2aea96426c1ef`；H-N13／R2-H01-KJ 已正式採用，T3/S49／策略 S42。

| 樣本 | 固定三年 v29 → v30 | 分差 | 九年全期間 v29 → v30 | 分差 |
| --- | ---: | ---: | ---: | ---: |
| A | 128.120899 → [128.120899](../exports/backtest-reports/baseline-a-v30-s42-hn13-kj-hot-t3s49-9y-fixed3y-600w-20260911/report.html) | +0.000000 | 117.533184 → [117.533184](../exports/backtest-reports/baseline-a-v30-s42-hn13-kj-hot-t3s49-9y-fullstress-600w-20260911/report.html) | +0.000000 |
| B | 127.395661 → [127.395661](../exports/backtest-reports/baseline-b-v30-s42-hn13-kj-hot-t3s49-9y-fixed3y-600w-20260911/report.html) | +0.000000 | 115.349012 → [115.349012](../exports/backtest-reports/baseline-b-v30-s42-hn13-kj-hot-t3s49-9y-fullstress-600w-20260911/report.html) | +0.000000 |
| C | 126.783280 → [126.895359](../exports/backtest-reports/baseline-c-v30-s42-hn13-kj-hot-t3s49-9y-fixed3y-600w-20260911/report.html) | +0.112079 | 123.298292 → [123.298292](../exports/backtest-reports/baseline-c-v30-s42-hn13-kj-hot-t3s49-9y-fullstress-600w-20260911/report.html) | +0.000000 |
| D | 99.386056 → [100.940042](../exports/backtest-reports/baseline-d-v30-s42-hn13-kj-hot-t3s49-9y-fixed3y-600w-20260911/report.html) | +1.553986 | 84.935709 → [84.935709](../exports/backtest-reports/baseline-d-v30-s42-hn13-kj-hot-t3s49-9y-fullstress-600w-20260911/report.html) | +0.000000 |
| E | 2.880546 → [2.937705](../exports/backtest-reports/baseline-e-v30-s42-hn13-kj-hot-t3s49-9y-fixed3y-600w-20260911/report.html) | +0.057160 | 0.971340 → [0.971340](../exports/backtest-reports/baseline-e-v30-s42-hn13-kj-hot-t3s49-9y-fullstress-600w-20260911/report.html) | +0.000000 |

固定三年 150 股票窗口 4 正／146 不變；改善主要集中友勁、C／E 小幅。九年交易、持股與資金均不變，不視為新增改善；既有力銘／益航超額加碼及益航長輪保留。固定窗口為主要採用證據，不把九年零差異當成否決或獨立勝出。

十份 periods 與凍結候選一致；二十庫逐日資料核對、五份 DecisionBase 466,798 決策及票數等價、74 項必要測試通過。10.2 吋正式 Release 十檔遷移與七筆人工操作保留、13 吋 v30 A 九年瀏覽核對完成；[完整採用紀錄與限制](H-N13採用紀錄-20260911.md)、[總稽核](../exports/baseline-v30-verification-all.json)。本次包含必要提交，未 push／發布。


<a id="s43abcde-v31-判讀"></a>
### S43／ABCDE v31 判讀

精確規則 commit `4994974ad6a322983ef356b71a231d0e01d84054`；EXIT-PATH-M3 已正式納入 S-T01c，T3/S50／策略 S43。

| 樣本 | 固定三年 v30 → v31 | 分差 | 九年全期間 v30 → v31 | 分差 |
| --- | ---: | ---: | ---: | ---: |
| A | 128.120899 → [129.509200](../exports/backtest-reports/baseline-a-v31-s43-st01c-pullback-profit-t3s50-9y-fixed3y-600w-20260911/report.html) | +1.388301 | 117.533184 → [117.750787](../exports/backtest-reports/baseline-a-v31-s43-st01c-pullback-profit-t3s50-9y-fullstress-600w-20260911/report.html) | +0.217603 |
| B | 127.395661 → [127.644065](../exports/backtest-reports/baseline-b-v31-s43-st01c-pullback-profit-t3s50-9y-fixed3y-600w-20260911/report.html) | +0.248404 | 115.349012 → [115.627849](../exports/backtest-reports/baseline-b-v31-s43-st01c-pullback-profit-t3s50-9y-fullstress-600w-20260911/report.html) | +0.278837 |
| C | 126.895359 → [126.895359](../exports/backtest-reports/baseline-c-v31-s43-st01c-pullback-profit-t3s50-9y-fixed3y-600w-20260911/report.html) | +0.000000 | 123.298292 → [123.481369](../exports/backtest-reports/baseline-c-v31-s43-st01c-pullback-profit-t3s50-9y-fullstress-600w-20260911/report.html) | +0.183078 |
| D | 100.940042 → [101.250867](../exports/backtest-reports/baseline-d-v31-s43-st01c-pullback-profit-t3s50-9y-fixed3y-600w-20260911/report.html) | +0.310825 | 84.935709 → [85.279923](../exports/backtest-reports/baseline-d-v31-s43-st01c-pullback-profit-t3s50-9y-fullstress-600w-20260911/report.html) | +0.344214 |
| E | 2.937705 → [2.935826](../exports/backtest-reports/baseline-e-v31-s43-st01c-pullback-profit-t3s50-9y-fixed3y-600w-20260911/report.html) | -0.001879 | 0.971340 → [0.971340](../exports/backtest-reports/baseline-e-v31-s43-st01c-pullback-profit-t3s50-9y-fullstress-600w-20260911/report.html) | +0.000000 |

固定 150 股票窗口 4 進／1 退／145 不變，九年 50 股 5 進／1 退／44 逐日不變。固定寶成最長 204→206 日、最低現金約 8,640→2,254；九年永豐餘最長 121→209 日、加碼 3→4 次，使用者已接受。無新增資金不足、超額投入或跨樣本重大退步；既有益航與力銘風險保留。

十份 periods.csv 與凍結 M3 逐位元相同；固定各三庫加全期間共二十庫的逐日模擬／滾動持久值（含 simUpdated）、價量與技術值皆與候選一致。股票全為 T3/S50、dirty 為空，無負結餘、無效值、無成交排除、moneyLacked 或異常狀態。五份 DecisionBase 共 **466,736 個決策**，每份 30 股票窗口／95 條規則，全部決策欄位、票數與出口 gate 和 v30 加凍結 M3 Delta 還原的串流逐筆一致；完成標記、P4b、SQLite 完整性、metadata、輸入與完整規則 commit 皆通過。[總稽核](../exports/baseline-v31-verification-all.json)、[正式 runner](../scripts/run-formal-pullback-profit-baseline-v31.sh)、[稽核工具](../tools/audit_baseline_v31.py)。

84 項規則邊界、Grade 趨勢、完整／局部重算、人工操作與市場相依測試全數通過，Debug 與 Release 建置成功。正式十次重播沒有變更候選條件；逐日與 DecisionBase 對照用既有凍結產物，沒有為取得一致結果新增調參或回測。

10.2 吋既有九年資料已覆蓋安裝正式 Release **v3.4.5（70）／T3/S50**，正常模式完成十檔 simUpdate 遷移，不新增 schema、不重算 tUpdate。24,720 筆既有資料的 76 個價量／技術欄位未變；遷移後共 24,730 筆（正常啟動後 Yahoo 新增當日十筆），七筆人工操作全部保留、冗餘／失效清除皆零，[資料與執行檔核對](../exports/s50-adoption-20260911/ten/verification.json)、[介面確認](../exports/s50-adoption-20260911/ten/ui-verification.json)。13 吋已切至 v31 A 九年瀏覽副本，24,350 筆／110 欄逐值一致；原歷史 T3/S40 主資料庫逐表未變，[核對證據](../exports/s50-adoption-20260911/thirteen/verification.json)。兩台保持開機。

[採用理由、反證與研究補救](EXIT-PATH-M3採用紀錄-20260911.md)。必要規則／文件已提交，未 push／發布。


<a id="s44abcde-v32-判讀"></a>
### S44／ABCDE v32 判讀

精確規則commit `98e049c48e383e898575eee573ddb7caaa6f8bf7`；L-P12原後期版正式採用，T3/S51／策略S44。

| 樣本 | 固定三年 v31 → v32 | 分差 | 九年 v31 → v32 | 分差 |
| --- | ---: | ---: | ---: | ---: |
| A | 129.509200 → [129.603864](../exports/backtest-reports/baseline-a-v32-s44-lp12-late-rebound-t3s51-9y-fixed3y-600w-20260912/report.html) | +0.094665 | 117.750787 → [118.912198](../exports/backtest-reports/baseline-a-v32-s44-lp12-late-rebound-t3s51-9y-fullstress-600w-20260912/report.html) | +1.161411 |
| B | 127.644065 → [127.586753](../exports/backtest-reports/baseline-b-v32-s44-lp12-late-rebound-t3s51-9y-fixed3y-600w-20260912/report.html) | -0.057312 | 115.627849 → [115.627849](../exports/backtest-reports/baseline-b-v32-s44-lp12-late-rebound-t3s51-9y-fullstress-600w-20260912/report.html) | +0.000000 |
| C | 126.895359 → [126.895359](../exports/backtest-reports/baseline-c-v32-s44-lp12-late-rebound-t3s51-9y-fixed3y-600w-20260912/report.html) | +0.000000 | 123.481369 → [123.481369](../exports/backtest-reports/baseline-c-v32-s44-lp12-late-rebound-t3s51-9y-fullstress-600w-20260912/report.html) | +0.000000 |
| D | 101.250867 → [101.933087](../exports/backtest-reports/baseline-d-v32-s44-lp12-late-rebound-t3s51-9y-fixed3y-600w-20260912/report.html) | +0.682221 | 85.279923 → [86.011593](../exports/backtest-reports/baseline-d-v32-s44-lp12-late-rebound-t3s51-9y-fullstress-600w-20260912/report.html) | +0.731671 |
| E | 2.935826 → [3.044757](../exports/backtest-reports/baseline-e-v32-s44-lp12-late-rebound-t3s51-9y-fixed3y-600w-20260912/report.html) | +0.108931 | 0.971340 → [1.363782](../exports/backtest-reports/baseline-e-v32-s44-lp12-late-rebound-t3s51-9y-fullstress-600w-20260912/report.html) | +0.392442 |

固定150股窗為3進／1退／146不變；九年50條股票路徑為3進／0退／47不變。固定鴻海提前買貴、首輪多持有兩天且少賺60,431元的反例保留；豐泰、友勁、山林水正例與D／E同為2020/03/20的集中性一併接受。最近固定窗口沒有改善，九年不增加新的獨立行情。

九年豐泰已實現淨利少419,278元，但期末估算損失由1,946,346降至178,569元；平均週期與累計資金占用稍增。友勁最高成本多1,953元、最高投入仍3份，平均週期縮短；山林水加碼7→4次、平均週期多0.050847天。沒有新增最高投入份數、超額／本金不足旗標、最長持有天數或180／360天長輪數。原力銘5份／超額2次、益航6份／超額3次及1,833天長輪完整不變，不宣稱原策略沒有風險。[逐輪與資金取捨](../exports/l-rebound-late-p1-full-20260912/README.md)。

十份報告與五份DecisionBase、86項測試及10.86吋正常重算完成；[完整採用證據](L-P12反彈後期採用紀錄-20260912.md)。必要本機提交完成，未push／發布。
