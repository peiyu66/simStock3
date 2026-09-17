# 文件圖例

這裡的 PNG 供[選股評等](../選股評等.md)、[真年報酬率警示](../真年報酬率警示.md)及[圖示說明文稿](../圖示說明文稿.md)表格直接顯示。返回[完整文件索引](../README.md)。

圖樣由 SwiftUI 的同名 SF Symbols 輸出，並沿用 App 的顏色與前期透明度；不是另畫的近似符號，也不是 Simulator 畫面截圖。每張 120 × 120 像素，文件以 28 × 28 顯示。白底固定為淺色圖例，實際 iPad 外觀仍可能隨系統符號版本、字級、粗體、深淺色模式與所在畫面而不同；操作圖示用單色示意，不代表所有狀態的實際顏色。

## 定義來源

- 評等：[dataModel.swift](../../simStock3/dataModel.swift) 的 `gradeIcon`。
- 趨勢形狀：[StrategyFit.swift](../../simStock3/StrategyFit.swift) 的 `displayIconSystemName`。
- 趨勢色彩：[GradeTrendIcons.swift](../../simStock3/GradeTrendIcons.swift)；價格前期 58% 透明度見 [RollingPricePath.swift](../../simStock3/RollingPricePath.swift)。
- 警示：[TrueAnnualReturnWarningView.swift](../../simStock3/TrueAnnualReturnWarningView.swift)。
- 操作與行情：[viewPage.swift](../../simStock3/viewPage.swift)、[viewList.swift](../../simStock3/viewList.swift)。

圖例只保存不同外觀，共用外觀不重複輸出：例如價格拉回後期與評等改善拉回共用紅色空心右下箭頭，歷史待補齊與恢復觀察共用橙色時鐘，解讀仍由所在欄位與文字區分。沒有箭頭的狀態不另造圖示；進度動畫及依交易狀態變化的加碼文字保留文字說明。

## 重建

在專案根目錄、具備 macOS SwiftUI 的環境執行：

```sh
swift -module-cache-path /tmp/simstock-doc-icons-cache scripts/export-documentation-icons.swift
```

[輸出腳本](../../scripts/export-documentation-icons.swift)只產生本目錄圖檔，不建置或執行 App，不存取 Simulator／行情資料。App 圖示定義變更時，先核對上列來源、更新腳本對照，再重建並目視檢查相關文件。
