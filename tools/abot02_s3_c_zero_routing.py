#!/usr/bin/env python3

from __future__ import annotations

import csv
import json
import sqlite3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RULE_COMMIT = "e4e41e1f1dfecb2fd320d347023a2095366ee0ec"
C_BASE_ID = "c-abcd9-v2-s31-st02h-efficiency-loss-cut-20260831-t2-s38-e4e41e1f1dfe-fixed3y-20260722-v6"
C_RUN_ID = "abot02-s3-c-score-gt200-nonbottom-add-m1-t2s38-9y-fixed3y-600w-20260901"
C_DELTA_DIR = (
    ROOT / "exports/backtest-decision-deltas" / C_BASE_ID / "A-BOT02-S3"
)
C_RUN_DIR = ROOT / "exports/backtest-candidate-runs" / C_RUN_ID
OUTPUT_DIR = (
    ROOT / "exports/add-bottoming-study/abot02-s3-c-zero-routing-t2s38-20260901"
)
ROUTING_BASES = {
    "D": "d-abcd9-v2-s31-st02h-efficiency-loss-cut-20260831-t2-s38-e4e41e1f1dfe-fixed3y-20260722-v6",
    "E": "e-abcde9-v2-s31-st02h-efficiency-loss-cut-20260831-t2-s38-e4e41e1f1dfe-fixed3y-20260722-v6",
}


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sqlite_ok(path: Path) -> None:
    with sqlite3.connect(path) as connection:
        result = connection.execute("PRAGMA integrity_check").fetchone()[0]
    require(result == "ok", f"SQLite integrity failed: {path}: {result}")


def validate_c() -> tuple[dict, list[dict]]:
    summary = load_json(C_DELTA_DIR / "decision-summary.json")
    manifest = load_json(C_RUN_DIR / "manifest.json")
    require((C_DELTA_DIR / ".complete").is_file(), "C DecisionDelta marker missing")
    require((C_DELTA_DIR / ".analysis-complete").is_file(), "C analysis marker missing")
    require((C_RUN_DIR / ".complete").read_text().strip() == C_RUN_ID, "C run marker mismatch")
    require(summary["candidateID"] == "aBot02S3", "C candidate mismatch")
    require(summary["candidateRunID"] == C_RUN_ID, "C run ID mismatch")
    require(summary["baselineDecisionBaseID"] == C_BASE_ID, "C DecisionBase mismatch")
    require(summary["sampleID"] == "C", "C sample mismatch")
    require(summary["prestateMismatchCount"] == 0, "C pre-state mismatch")
    require(summary["changedGateCount"] == 0, "C changed a gate")
    require(summary["outcomeDifferenceCount"] == 0, "C changed an outcome")
    require(summary["addedEventCount"] == 0 and summary["removedEventCount"] == 0, "C changed event set")
    require(manifest["dataRuleVersion"] == "T2/S38", "C data rule mismatch")
    require(manifest["ruleCommit"] == RULE_COMMIT, "C rule commit mismatch")
    sqlite_ok(C_DELTA_DIR / "decision-delta.sqlite")
    with (C_DELTA_DIR / "first-divergence.csv").open(encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    require(len(rows) == 8, "Unexpected C first-divergence count")
    require(
        all(
            row["baselineAction"] == "NONE"
            and row["candidateAction"] == "NONE"
            and float(row["baselineScore"]) == -1
            and float(row["candidateScore"]) == -2
            for row in rows
        ),
        "C contains a decision-critical divergence",
    )
    return summary, rows


def routing_events() -> list[dict]:
    rows = []
    query = """
        SELECT w.start_date, s.stock_id, s.name, s.group_name, e.trade_date,
               o.grade_name, o.fit_level, o.fit_trend_phase,
               e.decision_score, e.executed_action
        FROM decision_events AS e
        JOIN windows AS w ON w.window_id = e.window_id
        JOIN stocks AS s ON s.stock_key = e.stock_key
        JOIN event_strategy_fit_observations AS link ON link.event_id = e.event_id
        JOIN strategy_fit_observations AS o ON o.observation_id = link.observation_id
        WHERE e.phase = 4
          AND e.executed_action = 'ADD'
          AND e.decision_score = 3
          AND o.fit_level > 200
          AND o.fit_observation_count >= 125
          AND o.fit_trend_phase != 10
        ORDER BY w.start_date, s.stock_id, e.trade_date
    """
    for sample, base_id in ROUTING_BASES.items():
        base_dir = ROOT / "exports/backtest-decision-bases" / base_id
        manifest = load_json(base_dir / "manifest.json")
        require((base_dir / ".complete").is_file(), f"{sample} DecisionBase marker missing")
        require((base_dir / ".p4b-complete").is_file(), f"{sample} P4b marker missing")
        require(manifest["sampleID"] == sample, f"{sample} manifest mismatch")
        require(manifest["dataRuleVersion"] == "T2/S38", f"{sample} data rule mismatch")
        require(manifest["ruleCommit"] == RULE_COMMIT, f"{sample} rule commit mismatch")
        database = base_dir / "decisions.sqlite"
        sqlite_ok(database)
        with sqlite3.connect(database) as connection:
            connection.row_factory = sqlite3.Row
            for raw in connection.execute(query):
                row = dict(raw)
                row["sample"] = sample
                rows.append(row)
    return rows


def main() -> None:
    summary, divergences = validate_c()
    routing = routing_events()
    require(not any(row["sample"] == "D" for row in routing), "D unexpectedly has a critical event")
    require(len([row for row in routing if row["sample"] == "E"]) == 1, "E critical-event count mismatch")
    target = next(row for row in routing if row["sample"] == "E")
    require(target["stock_id"] == "4562", "E target is not 穎漢")
    require(target["trade_date"] == 20240729, "E target date mismatch")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    with (OUTPUT_DIR / "c-first-divergences.csv").open(
        "w", newline="", encoding="utf-8"
    ) as handle:
        writer = csv.DictWriter(handle, fieldnames=list(divergences[0].keys()))
        writer.writeheader()
        writer.writerows(divergences)
    fields = [
        "sample",
        "start_date",
        "stock_id",
        "name",
        "group_name",
        "trade_date",
        "grade_name",
        "fit_level",
        "fit_trend_phase",
        "decision_score",
        "executed_action",
    ]
    with (OUTPUT_DIR / "de-routing-events.csv").open(
        "w", newline="", encoding="utf-8"
    ) as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(routing)

    report = f"""# A-BOT02-S3-C 零差異與 D／E 路由診斷

Sample C 固定三年主分 113.724 → 113.724（{summary['combinedMainScoreDelta']:+.3f}）。兩股群與六個窗口／股群全部精確零差異，0 pre-state mismatch、0 gate change、0 action change、0 outcome difference、0 無效值及 0 無交易排除。

8 個第一次分歧全部只把 ADD 票數從 -1 降至 -2；正式與候選動作均為 NONE。67 個 changed events 全是 S3 票數欄位差異，其中 66 個隨下一事件重合，沒有任何正式 ADD 被擋，也沒有決策關鍵案例。因此 C 只能判定「沒有覆蓋」，不能支持或反駁 S3。

為避免形式性重播，另以 Baseline v19 D／E DecisionBase 篩選交易當日連續效率分數 >200、趨勢至少 125 筆、非惡化確認探底，且正式 ADD 剛好 aWant 3 的案例。D 為 0 件；E 為 1 件：穎漢 2023 窗口，2024/07/29，exact wow，連續效率分數 {target['fit_level']:.3f}，改善拉回，正式 aWant 3 並實際加碼。

因此下一個有判別力的樣本是 E，不應先跑必然沒有直接加碼差異的 D。E 若改善且機制一致，便提供第一份未參與 200 分界形成的獨立正向證據；E 若退步即停止，零差異則表示目標加碼最後重合，再據路徑判斷是否仍有研究價值。

執行註記：C 首次重播在建立部分 period store 後因 Simulator 進入 Shutting Down，被 runner 正確中止；第一次安全重試卡在 simctl launch，人工中斷後只重啟 Simulator、不刪 App 或資料，第二次原參數重試完成。runner 隨後補上 get_app_container 與 launch 的 120 秒上限，避免相同卡死進入無界等待。
"""
    (OUTPUT_DIR / "report.md").write_text(report, encoding="utf-8")
    manifest = {
        "studyID": "A-BOT02-S3-C-ZERO-ROUTING",
        "sampleID": "C",
        "baseline": "v19",
        "dataRuleVersion": "T2/S38",
        "ruleCommit": RULE_COMMIT,
        "candidateID": "aBot02S3",
        "candidateRunID": C_RUN_ID,
        "candidateDecisionBaseID": C_BASE_ID,
        "routingDecisionBaseIDs": ROUTING_BASES,
        "files": [
            "manifest.json",
            "report.md",
            "c-first-divergences.csv",
            "de-routing-events.csv",
        ],
    }
    (OUTPUT_DIR / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(OUTPUT_DIR)


if __name__ == "__main__":
    main()
