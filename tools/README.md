# 研究工具保存索引

2026/10/07 整理既有 31 支未追蹤工具；原檔及路徑不變。這些是已完成研究的分析／驗收來源，不代表新的研究排程。完整原始 SHA256 與逐檔相依清單保存在本機 `exports/release-closeout-maintenance-20261007/classified-worktree.json`。

部分工具會在匯入或測試時寫入既有 exports，不能為保存而直接批次執行。這次只做 AST 語法與相依核對；未重跑研究。VCX 另透過 AST 讀取 LC／H 買函式，不能單獨刪除 LC 工具。

| 工具 | 家族 | 本機工具相依 |
| --- | --- | --- |
| [add_delay_p01.py](add_delay_p01.py) | AD | Python 標準函式庫／外部輸入 |
| [add_delay_p01_audit.py](add_delay_p01_audit.py) | AD | `add_delay_p01.py` |
| [add_delay_p01_slope.py](add_delay_p01_slope.py) | AD | `add_delay_p01.py` |
| [add_delay_p02.py](add_delay_p02.py) | AD | `add_delay_p01.py`、`h_entry_composite.py`、`h_entry_composite_p02.py`、`h_entry_composite_search.py`、`l_entry_delay_features.py`、`l_entry_delay_p02.py` |
| [add_delay_p02_audit.py](add_delay_p02_audit.py) | AD | `add_delay_p01.py` |
| [add_delay_p03.py](add_delay_p03.py) | AD | `h_entry_composite_search.py` |
| [add_delay_p03_audit.py](add_delay_p03_audit.py) | AD | `add_delay_p03.py` |
| [add_delay_p03_candidates.py](add_delay_p03_candidates.py) | AD | `add_delay_p03.py`、`add_delay_p03_audit.py` |
| [add_delay_p03_candidates_v2.py](add_delay_p03_candidates_v2.py) | AD | `add_delay_p03.py`、`add_delay_p03_audit.py`、`add_delay_p03_gate_contract.py` |
| [add_delay_p03_gate_contract.py](add_delay_p03_gate_contract.py) | AD | `add_delay_p03.py`、`add_delay_p03_audit.py` |
| [add_delay_p03_raw_check.py](add_delay_p03_raw_check.py) | AD | `add_delay_p01.py`、`add_delay_p03.py` |
| [l_entry_delay_features.py](l_entry_delay_features.py) | LD | `h_entry_composite.py`、`h_entry_composite_p02.py` |
| [l_entry_delay_p01.py](l_entry_delay_p01.py) | LD | Python 標準函式庫／外部輸入 |
| [l_entry_delay_p01_audit.py](l_entry_delay_p01_audit.py) | LD | `l_entry_delay_p01.py` |
| [l_entry_delay_p02.py](l_entry_delay_p02.py) | LD | `h_entry_composite.py`、`h_entry_composite_p02.py`、`h_entry_composite_search.py`、`l_entry_delay_features.py`、`l_entry_delay_p01.py`、`market_technical.py` |
| [l_entry_delay_p02_audit.py](l_entry_delay_p02_audit.py) | LD | `l_entry_delay_p02.py` |
| [l_entry_delay_p03.py](l_entry_delay_p03.py) | LD | `h_entry_composite_search.py` |
| [l_entry_delay_p03_check.py](l_entry_delay_p03_check.py) | LD | `l_entry_delay_p03.py` |
| [l_entry_delay_p04.py](l_entry_delay_p04.py) | LD | `l_entry_delay_p03.py`、`l_entry_delay_p03_check.py` |
| [loss_exit_cases.py](loss_exit_cases.py) | LC | `loss_exit_p01.py` |
| [loss_exit_cases_audit.py](loss_exit_cases_audit.py) | LC | `loss_exit_cases.py` |
| [loss_exit_p01.py](loss_exit_p01.py) | LC | `h_entry_composite.py`、`h_entry_composite_p02.py`、`h_entry_composite_search.py`、`l_entry_delay_features.py` |
| [loss_exit_p01_audit.py](loss_exit_p01_audit.py) | LC | `loss_exit_p01.py` |
| [sell_delay_f05_refresh.py](sell_delay_f05_refresh.py) | F05 | Python 標準函式庫／外部輸入 |
| [test_add_delay_p03.py](test_add_delay_p03.py) | AD | `add_delay_p03.py` |
| [test_l_entry_delay_p02.py](test_l_entry_delay_p02.py) | LD | `l_entry_delay_p02.py`、`test_h_entry_composite_search.py` |
| [test_l_entry_delay_p03.py](test_l_entry_delay_p03.py) | LD | `l_entry_delay_p03.py` |
| [test_l_entry_delay_p04.py](test_l_entry_delay_p04.py) | LD | `l_entry_delay_p04.py` |
| [volume_composite.py](volume_composite.py) | VCX | `h_entry_composite_p02.py`、`loss_exit_p01.py` |
| [volume_composite_analysis.py](volume_composite_analysis.py) | VCX | `volume_composite.py` |
| [volume_composite_audit.py](volume_composite_audit.py) | VCX | `volume_composite.py`、`volume_composite_analysis.py` |

結案來源：[AD](../doc/補買延遲複合規則研究計畫-20261002.md)、[LD](../doc/承低延遲買入複合規則研究計畫-20261001.md)、[LC](../doc/認賠賣提前與延後複合規則研究計畫-20261002.md)、[F05](../doc/延遲賣出複合規則研究計畫-20260930.md)、[VCX](../doc/回測規則驗證.md)。

發布一致性使用 [check_release_closeout.py](check_release_closeout.py) 與 [獨立合成測試](test_release_closeout.py)，操作見[發布流程](../doc/發布流程.md)。
