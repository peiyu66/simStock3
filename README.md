# simStock 小確幸股票模擬機

「小確幸股票模擬機」，個股即時回測：查詢下載台灣上市股票的歷史股價，計算、分析技術數值，自動模擬買賣、評估報酬率。

## 最近發佈的版本
* v1.1：[[點這裡]](itms-services://?action=download-manifest&url=https://github.com/peiyu66/simStock21/releases/download/latest/manifest.plist)，就會出現確認安裝的對話方塊。
    * 曾向作者登記為[開發機](doc/加入小確幸.md)，iOS14以上的iPhone或iPad才能安裝。
    * 上列[[點這裡]](itms-services://?action=download-manifest&url=https://github.com/peiyu66/simStock21/releases/download/latest/manifest.plist)的連結要在iOS設備連上[github-pages](https://peiyu66.github.io/simStock21/)，才能點出確認安裝的對話方塊。

## 策略要求
   既定的規則，純技術面的短期投機買賣：
1. 低買高賣賺取價差，不考慮股息股利。
1. 致力縮短買賣[週期](doc/週期.md)，但也與提升[報酬率](doc/報酬率.md)取平衡。
1. 保本小賺維持現金流，不追求偶爾大賺。
1. 要簡單、容易實現、容易評估。

「短期」是指買賣週期。資金的投入則應持續兩年，才能陸續地得到小確幸。

## 買賣規則
1. 每次買進只使用現金的三分之一，即「起始本金」及兩次加碼備用金。
1. 每次買進時一次買足「起始本金」可買到的數量。
1. 賣時一次全部賣出結清。
1. 必要時2次加碼。

## 選股原則
1. 熱門股優於傳統股。
1. 近3年的模擬，平均[實年報酬率](doc/報酬率.md)在20%以上，平均週期在65天以內者（標示為[紅星股](doc/選股評等.md)）。

## Q&A
### 誰適合使用小確幸？
小確幸的主人是：
* 認同策略規則。
* 幾乎每天看盤，幾乎每月、甚至每週執行買賣。
* 有閒錢兩年內不虞急用，能忍受「未實現損益」總是負損。
  * 「未實現損益」總是負損，若當下全部變現了而與「已實現損益」合計，很可能是小賺的。
  * 閒錢越多越穩。雖然以小資本投入小確幸、依照同樣的邏輯徹底執行，也可得到大約相同的報酬率，但收益額度太小則無感，不成確幸。

✐✐✐ [小確幸適性評估](https://docs.google.com/forms/d/e/1FAIpQLSdzNyfMl5NP1sCSHSxoSCWqqdeAPSQbw4kAiwlCv0pzJkjgrg/viewform?usp=sf_link) ✐✐✐


### 小確幸沒有在App Store上架？
* App Store自2017年已不允許「個人」開發者上架含有「模擬賭博」內容的App。

### 如何安裝小確幸？
* 若有加入Apple Developer，就自己在Xcode直接建造、安裝到iOS設備。
* 不然只好向作者登記iPhone或iPad的序號作為開發機，再從[[github-pages]](https://peiyu66.github.io/simStock21/)下載及安裝(ipa)。
* 細節請參閱[加入小確幸](doc/加入小確幸.md)。

### 有些股票找不到？
* 只有上市股票才能被搜尋到，小確幸不模擬上櫃股票。
* 如果股票已經在股群之內，就不會重複列在搜尋結果。

### 如何買賣？
小確幸不是即時的程式交易，只能即時模擬買賣。

小確幸根據模擬規則自動提示買賣建議，你參考模擬建議的買賣時機，決定是否下單執行買賣。或使用日期左側的圓形按鈕、右側的加碼建議，變更模擬買賣的時機以觀察其後果。

`小確幸不保證提供的資訊「正確」、「即時」，亦不對你的投資決策負責。`

### 不是很準確？
小確幸的任務不是實現神諭般的預測，而只是賺小錢。雖然不總是買在最低、賣在最高，卻總是可以持續賺錢、持續形成小確幸，則任務達成。

## 其他說明
- [界限](doc/界限.md)
- [選股評等](doc/選股評等.md)
- [報酬率](doc/報酬率.md)
- [週期](doc/週期.md)
- [加入小確幸](doc/加入小確幸.md)
- [畫面諸元](doc/畫面諸元.md)
- [實戰指要](doc/實戰指要.md)
- [五檔及內外盤](doc/五檔及內外盤.md)
- [捷徑Shortcuts](doc/捷徑Shortcuts.md)

## 截圖
截自XCode simulator 2021/08/30 v1.1(1)。

### iPad Pro 12.9吋 5代
<br>

#### list: 直向時
<a href="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPad%20Pro%20(12.9-inch)%20(5th%20generation)%20-%202021-08-30%20at%2019.02.37.png"><img src="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPad%20Pro%20(12.9-inch)%20(5th%20generation)%20-%202021-08-30%20at%2019.02.37.png" width="45%"></a>

#### page: 直向時
<a href="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPad%20Pro%20(12.9-inch)%20(5th%20generation)%20-%202021-08-30%20at%2019.03.06.png"><img src="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPad%20Pro%20(12.9-inch)%20(5th%20generation)%20-%202021-08-30%20at%2019.03.06.png" width="45%"></a><br>

#### column: 橫置時
<a href="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPad%20Pro%20(12.9-inch)%20(5th%20generation)%20-%202021-08-30%20at%2019.02.57.png"><img src="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPad%20Pro%20(12.9-inch)%20(5th%20generation)%20-%202021-08-30%20at%2019.02.57.png" width="90%"></a>
<br>

### iPhone SE 2代
<br>

#### list: 直向、橫置
<a href="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPhone%20SE%20(2nd%20generation)%20-%202021-08-30%20at%2018.57.56.png"><img src="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPhone%20SE%20(2nd%20generation)%20-%202021-08-30%20at%2018.57.56.png" width="30%"></a> 
<a href="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPhone%20SE%20(2nd%20generation)%20-%202021-08-30%20at%2018.58.06.png"><img src="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPhone%20SE%20(2nd%20generation)%20-%202021-08-30%20at%2018.58.06.png" width="60%"></a>
<br><br>

#### page: 首筆未展開
<a href="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/20180830/Simulator%20Screen%20Shot%20-%20iPhone%20SE%20(2nd%20generation)%20-%202021-08-30%20at%2018.58.15.png"><img src="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPhone%20SE%20(2nd%20generation)%20-%202021-08-30%20at%2018.58.15.png" width="30%"></a> 
<a href="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPhone%20SE%20(2nd%20generation)%20-%202021-08-30%20at%2018.58.21.png"><img src="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPhone%20SE%20(2nd%20generation)%20-%202021-08-30%20at%2018.58.21.png" width="60%"></a>
<br><br>

#### page: 首筆展開
<a href="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPhone%20SE%20(2nd%20generation)%20-%202021-08-30%20at%2019.14.42.png"><img src="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPhone%20SE%20(2nd%20generation)%20-%202021-08-30%20at%2019.14.42.png" width="30%"></a>
<a href="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPhone%20SE%20(2nd%20generation)%20-%202021-08-30%20at%2019.15.38.png"><img src="https://github.com/peiyu66/simStock21/raw/main/doc/20180830/Simulator%20Screen%20Shot%20-%20iPhone%20SE%20(2nd%20generation)%20-%202021-08-30%20at%2019.15.38.png" width="60%"></a>
<br><br>
