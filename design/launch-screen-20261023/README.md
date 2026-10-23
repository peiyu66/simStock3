# simStock 啟動畫面圖稿（v2 已採用）

2026/10/23，依主對話 `01a157c0-b093-70cf-8e24-55c477db90d7` 的使用者要求，先檢視指定原圖，再用內建 imagegen 重製；只調整圖文間距及畫面位置，保留圓形股價圖、配色與兩行文字。原圖 `/Users/peiyu/Downloads/LaunchImage1024.png` 未修改；白底定稿已原樣接入 `simStock3/Assets.xcassets/LaunchArtwork.imageset`，系統 LaunchScreen 與 app 初始畫面共用。

**圖稿已定案：** 使用者於主對話回覆白底預覽附件「這個採用」（來源訊息 `Sentinel_4b1f55e7f9388191ad42da6214c2d36e`）。以 `LaunchImage-v2-white-preview.png` 為採用的視覺基準；Launch Screen 與 app 初始銜接畫面使用相同圖形、文字、配色及版式，不另改樣式。接線只作必要等比尺寸適配，不重繪或重新排版。圖稿採用後，使用者已批准冷啟動計畫；產品接線與 Simulator 視覺驗收進度見改善計畫第 10 節。

| 檔案 | 格式與尺寸 | 用途 |
| --- | --- | --- |
| [LaunchImage-v2.png](LaunchImage-v2.png) | PNG／RGBA，1086×1449，224,339 bytes | 保留的透明參考稿；不是採用基準，不可在未確認視覺一致前替代白底定稿 |
| [LaunchImage-v2-white-preview.png](LaunchImage-v2-white-preview.png) | PNG／RGB，1086×1448，1,049,069 bytes | **使用者已採用的 v2 圖稿**；保留原檔名與內容，非已安裝畫面 |
| [preview.html](preview.html) | 本機檢視頁 | 指向已採用的白底 v2；先前瀏覽器拒絕 file 協定，未完成此頁瀏覽器驗收 |
| [prompt.txt](prompt.txt) | 文字 | 透明候選完整提示詞 |

黑字在工具的黑色透明底顯示不易閱讀，所以另製白底稿；它的「simStock」「小確幸股票模擬機」、整體圖文與無裁切已目視核對，並由使用者採用。兩份圖片由生成模型分別輸出，不能把白底稿當作透明稿逐像素一致的證明；未來接線以已採用白底稿為準，仍需依[改善計畫](../../doc/冷啟動查詢與啟動畫面改善計畫-20261023.md)驗證直橫尺寸及轉場，不改圖稿樣式。工具沒有按提示詞輸出精確的 1024×1366，不把尺寸誤記為原圖尺寸。

白底檢視稿提示詞：

> Create a WHITE-BACKGROUND REVIEW COPY of this existing transparent PNG, for inspecting black lettering. Keep the original artwork, exact text "simStock" and "小確幸股票模擬機", all shapes, sizes, layout and colors unchanged; do not redesign or retouch. Only render the transparency onto a uniform pure white background. This is a separate visual preview; the original transparent production candidate will be retained untouched.

SHA-256：

- 原圖：`89ea8565b7ffc86a1db498f988237ae34cfde39b14cc62e22116213a2b5760d5`
- 透明候選：`e1e9b5627d51d644641cb4b55984fe6a9be2c924c7ebb9674ef9e2b82e1ab984`
- 白底檢視稿：`74c89f28a4699aa206ac156980e976eecea7742444ca1b3aacf4025aca4e6663`

生成原始輸出另保留於專案 `generated_images/exec-4dafdede-ec7e-482d-9e84-3bcc438213fa.png` 及 `exec-81788101-e5b7-4176-bfc9-d8a9e87d688c.png`。本目錄保存圖稿來源；正式 App 使用白底定稿的相同位元組副本。接線驗證只操作隔離 Simulator，未操作實機。
