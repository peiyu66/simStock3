#!/usr/bin/env python3
"""Validate MKT-R02-Q0 market-vote socket controls and emit immutable evidence."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import shutil
import sqlite3
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any


STUDY_ID = "MKT-R02-Q0"
SNAPSHOT_ID = "taiex-market-mt1-20260722-a00beac8d4af"
MARKET_SHA256 = "a00beac8d4af55668f977a4aca74b3e6c71e60bee6e456544a5a833d4ee95084"
DECISION_BASE_ID = (
    "a-abcd9-v2-s32-an03-wow-nonbottom-no-ap02-add-penalty-20260901-"
    "t2-s39-48d42e50ada5-fixed3y-20260722-v6"
)
FORMAL_RULE_COMMIT = "48d42e50ada5dcc0ed2e22dffff6871323daf8b7"
BASELINE_RUN_ID = (
    "baseline-a-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-"
    "t2s39-9y-fixed3y-600w-20260901"
)
PHASES = {"pulse-h": 1, "pulse-l": 2, "pulse-s": 3, "pulse-a": 4}
RUN_IDS = {
    "disabled": BASELINE_RUN_ID,
    "never": "mkt-r02-q0-never-a-v20-t2s39-fixed3y-600w-20260902",
    **{
        name: f"mkt-r02-q0-{name}-a-v20-t2s39-fixed3y-600w-20260902"
        for name in PHASES
    },
}
CANDIDATE_IDS = {
    "disabled": "p3-z-baseline-control",
    "never": "mkt-r02-q0-never",
    **{name: f"mkt-r02-q0-{name}" for name in PHASES},
}
RULE_ID = "MKT-Q0-PULSE"
SOURCE_FIELD = "market_high_from_prev_close_pct"
THRESHOLD = -0.30616316995948056


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    require(path.is_file(), f"missing JSON: {path}")
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    require(isinstance(value, dict), f"JSON root is not an object: {path}")
    return value


def directory_bytes(path: Path) -> int:
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def qualifying_dates(path: Path) -> set[int]:
    require(sha256(path) == MARKET_SHA256, "frozen MT1 market-technical.csv hash mismatch")
    dates: set[int] = set()
    rows = 0
    last_date = ""
    with path.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            rows += 1
            date = row["date"]
            require(date > last_date, f"market dates are not strictly increasing: {date}")
            last_date = date
            value = float(row[SOURCE_FIELD])
            require(value == value and abs(value) != float("inf"), f"non-finite market value: {date}")
            if value <= THRESHOLD:
                dates.add(int(date.replace("-", "")))
    require(rows == 2_569 and last_date == "2026-07-22", "MT1 row count or cutoff mismatch")
    require(dates, "diagnostic phenomenon has no qualifying dates")
    return dates


def latest_runner_start(log_root: Path, candidate_id: str, completed_at: float) -> datetime:
    matches: list[tuple[datetime, Path]] = []
    for path in log_root.glob(f"*-{candidate_id}-a-build.log"):
        prefix = path.name[:15]
        try:
            stamp = datetime.strptime(prefix, "%Y%m%d-%H%M%S")
        except ValueError:
            continue
        if stamp.timestamp() <= completed_at:
            matches.append((stamp, path))
    require(bool(matches), f"runner build log missing for {candidate_id}")
    return max(matches)[0]


def validate_run_manifest(manifest: dict[str, Any], run_id: str) -> None:
    require(manifest.get("runID") == run_id, f"run ID mismatch: {run_id}")
    require(manifest.get("sampleID") == "A", f"sample mismatch: {run_id}")
    require(manifest.get("dataRuleVersion") == "T2/S39", f"T/S mismatch: {run_id}")
    require(manifest.get("ruleCommit") == FORMAL_RULE_COMMIT, f"rule commit mismatch: {run_id}")
    require(float(manifest.get("moneyBaseWan")) == 600, f"money mismatch: {run_id}")
    require(float(manifest.get("automaticInvestments")) == 2, f"add count mismatch: {run_id}")
    require(manifest.get("through") == "2026/07/22", f"cutoff mismatch: {run_id}")


def validate_zero_control(
    name: str,
    summary: dict[str, Any],
    diagnostics: dict[str, Any],
) -> None:
    for key in (
        "changedEventCount", "changedVoteCount", "changedGateCount",
        "firstDivergenceCount", "prestateMismatchCount", "outcomeDifferenceCount",
        "groupOutcomeDifferenceCount", "addedEventCount", "removedEventCount",
    ):
        require(int(summary[key]) == 0, f"{name} is not zero: {key}={summary[key]}")
    require(summary["isZeroDecisionDelta"] is True, f"{name} decision delta is not zero")
    require(summary["isZeroOutcomeDelta"] is True, f"{name} outcome delta is not zero")
    require(all(int(value) == 0 for value in diagnostics["contributionsByPhase"].values()),
            f"{name} emitted a market vote")
    if name == "disabled":
        require(diagnostics["mode"] == "disabled", "disabled mode mismatch")
        require(int(diagnostics["sourceRowCount"]) == 0, "disabled mode loaded MT1")
        require(all(int(value) == 0 for value in diagnostics["evaluationsByPhase"].values()),
                "disabled mode evaluated a phase")
    else:
        require(diagnostics["mode"] == "never", "never mode mismatch")
        require(int(diagnostics["sourceRowCount"]) == 2_569, "never mode did not load MT1")
        for phase in ("H_BUY", "L_BUY", "SELL", "ADD"):
            require(int(diagnostics["evaluationsByPhase"][phase]) > 0,
                    f"never mode did not traverse {phase}")


def validate_pulse(
    name: str,
    phase: int,
    delta_db: Path,
    base_db: Path,
    summary: dict[str, Any],
    diagnostics: dict[str, Any],
    market_dates: set[int],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    require(summary["prestateMismatchCount"] == 0, f"{name} has pre-state mismatches")
    require(summary["firstDivergenceCount"] > 0, f"{name} has no first divergence")
    require(diagnostics["snapshotID"] == SNAPSHOT_ID, f"{name} snapshot mismatch")
    require(diagnostics["phenomenonID"] == "level:market_high_from_prev_close_pct:q10:le",
            f"{name} phenomenon mismatch")
    require(int(diagnostics["sourceRowCount"]) == 2_569, f"{name} source rows mismatch")

    target_code = {1: "H_BUY", 2: "L_BUY", 3: "SELL", 4: "ADD"}[phase]
    contribution_counts = diagnostics["contributionsByPhase"]
    require(int(contribution_counts[target_code]) > 0, f"{name} emitted no pulse")
    require(all(int(value) == 0 for key, value in contribution_counts.items() if key != target_code),
            f"{name} leaked into another phase")

    connection = sqlite3.connect(delta_db)
    connection.row_factory = sqlite3.Row
    try:
        require(connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok",
                f"{name} delta SQLite integrity failed")
        connection.execute("ATTACH DATABASE ? AS baseline", (str(base_db.resolve()),))
        vote_rows = connection.execute(
            """
            SELECT e.delta_id,e.window_start,e.window_end,e.stock_id,e.trade_date,e.phase,
                   e.baseline_event_id,COALESCE(e.candidate_score,b.decision_score) AS candidate_score,
                   COALESCE(e.candidate_planned_action,b.planned_action) AS candidate_planned_action,
                   COALESCE(e.candidate_executed_action,b.executed_action) AS candidate_executed_action,
                   e.candidate_state_fingerprint,
                   v.baseline_contribution,v.candidate_contribution,
                   b.decision_score AS baseline_score,
                   b.planned_action AS baseline_planned_action,
                   b.executed_action AS baseline_executed_action
            FROM vote_deltas v
            JOIN event_deltas e USING(delta_id)
            LEFT JOIN baseline.decision_events b ON b.event_id=e.baseline_event_id
            WHERE v.rule_id=?
            ORDER BY e.window_start,e.stock_id,e.trade_date,e.phase
            """,
            (RULE_ID,),
        ).fetchall()
        require(len(vote_rows) == int(contribution_counts[target_code]),
                f"{name} diagnostics/SQLite pulse count mismatch")
        require(all(row["phase"] == phase for row in vote_rows), f"{name} wrong-phase vote")
        require(all(row["trade_date"] in market_dates for row in vote_rows), f"{name} wrong-date vote")
        require(all(row["baseline_contribution"] is None and row["candidate_contribution"] == 1
                    for row in vote_rows), f"{name} contribution is not exact +1")
        pulse_delta_ids = {int(row["delta_id"]) for row in vote_rows}
        placeholders = ",".join("?" for _ in market_dates)
        expected_rows = connection.execute(
            f"""
            SELECT delta_id FROM event_deltas
            WHERE phase=? AND trade_date IN ({placeholders}) AND kind != 3
            """,
            (phase, *sorted(market_dates)),
        ).fetchall()
        expected_delta_ids = {int(row[0]) for row in expected_rows}
        require(pulse_delta_ids == expected_delta_ids, f"{name} has a missing or extra pulse event")

        first = connection.execute(
            """
            SELECT f.* FROM first_divergences f
            JOIN vote_deltas v ON v.delta_id=f.delta_id
            WHERE v.rule_id=?
            """,
            (RULE_ID,),
        ).fetchall()
        require(len(first) == int(summary["firstDivergenceCount"]),
                f"{name} first divergence did not originate at pulse")
        require(all(row["same_prestate"] == 1 and row["phase"] == phase
                    and abs(row["candidate_score"] - row["baseline_score"] - 1) < 1e-9
                    for row in first), f"{name} first divergence is not exact +1 on same pre-state")

        isolated_delta_ids = {
            int(row[0]) for row in connection.execute(
                """
                SELECT delta_id FROM vote_deltas GROUP BY delta_id
                HAVING COUNT(*)=1 AND MAX(rule_id)=?
                """,
                (RULE_ID,),
            )
        }
        direct = [row for row in vote_rows
                  if row["delta_id"] in isolated_delta_ids
                  and row["baseline_event_id"] is not None
                  and row["candidate_state_fingerprint"] is None]
        require(direct, f"{name} has no same-state pulse comparisons")
        require(all(abs(row["candidate_score"] - row["baseline_score"] - 1) < 1e-9
                    for row in direct), f"{name} same-state score delta is not exact +1")
        planned_changes = sum(
            row["candidate_planned_action"] != row["baseline_planned_action"] for row in direct
        )
        executed_changes = sum(
            row["candidate_executed_action"] != row["baseline_executed_action"] for row in direct
        )
        require(planned_changes > 0 and executed_changes > 0,
                f"{name} did not reach the formal phase action path")

        event_log = [
            {
                "candidate_id": CANDIDATE_IDS[name],
                "window_start": row["window_start"],
                "window_end": row["window_end"],
                "stock_id": row["stock_id"],
                "trade_date": row["trade_date"],
                "phase": target_code,
                "baseline_score": row["baseline_score"],
                "candidate_score": row["candidate_score"],
                "baseline_planned_action": row["baseline_planned_action"],
                "candidate_planned_action": row["candidate_planned_action"],
                "baseline_executed_action": row["baseline_executed_action"],
                "candidate_executed_action": row["candidate_executed_action"],
                "same_state": row["candidate_state_fingerprint"] is None,
                "contribution": row["candidate_contribution"],
            }
            for row in vote_rows
        ]
        return ({
            "phase": target_code,
            "pulseVoteCount": len(vote_rows),
            "distinctMarketDateCount": len({row["trade_date"] for row in vote_rows}),
            "sameStateExactScoreCount": len(direct),
            "directPlannedActionChangeCount": planned_changes,
            "directExecutedActionChangeCount": executed_changes,
            "firstDivergenceCount": len(first),
            "changedEventCount": int(summary["changedEventCount"]),
            "outcomeDifferenceCount": int(summary["outcomeDifferenceCount"]),
        }, event_log)
    finally:
        connection.close()


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    require(bool(rows), f"cannot write empty CSV: {path.name}")
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--market-csv", type=Path, required=True)
    parser.add_argument("--baseline-run-dir", type=Path, required=True)
    parser.add_argument("--decision-base-dir", type=Path, required=True)
    parser.add_argument("--candidate-runs-root", type=Path, required=True)
    parser.add_argument("--decision-deltas-root", type=Path, required=True)
    parser.add_argument("--build-logs-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()

    require(args.decision_base_dir.name == DECISION_BASE_ID, "DecisionBase ID mismatch")
    base_db = args.decision_base_dir / "decisions.sqlite"
    require(base_db.is_file(), "DecisionBase SQLite missing")
    market_dates = qualifying_dates(args.market_csv)
    baseline_periods = args.baseline_run_dir / "periods.csv"
    require(baseline_periods.is_file(), "formal Baseline periods.csv missing")

    identity_files = [args.market_csv, base_db, baseline_periods]
    run_data: dict[str, dict[str, Any]] = {}
    delta_data: dict[str, dict[str, Any]] = {}
    run_metrics: list[dict[str, Any]] = []
    all_events: list[dict[str, Any]] = []
    pulse_results: dict[str, Any] = {}

    for name in RUN_IDS:
        run_id = RUN_IDS[name]
        candidate_id = CANDIDATE_IDS[name]
        run_dir = args.candidate_runs_root / run_id
        delta_dir = args.decision_deltas_root / candidate_id
        require((run_dir / ".complete").read_text().strip() == run_id,
                f"run completion marker mismatch: {name}")
        require((delta_dir / ".complete").read_text().strip() == candidate_id,
                f"delta completion marker mismatch: {name}")
        require((delta_dir / ".analysis-complete").read_text().strip() == candidate_id,
                f"analysis completion marker mismatch: {name}")
        manifest = load_json(run_dir / "manifest.json")
        summary = load_json(delta_dir / "decision-summary.json")
        diagnostics = load_json(run_dir / "market-vote-diagnostics.json")
        validate_run_manifest(manifest, run_id)
        require(summary["candidateID"] == candidate_id, f"candidate mismatch: {name}")
        require(summary["candidateRunID"] == run_id, f"candidate run mismatch: {name}")
        require(summary["baselineDecisionBaseID"] == DECISION_BASE_ID,
                f"DecisionBase mismatch: {name}")
        require(diagnostics["studyID"] == STUDY_ID, f"diagnostic study mismatch: {name}")
        run_data[name] = manifest
        delta_data[name] = summary
        identity_files += [run_dir / "manifest.json", run_dir / "market-vote-diagnostics.json",
                           delta_dir / "decision-summary.json"]
        if (delta_dir / "decision-delta.sqlite").is_file():
            identity_files.append(delta_dir / "decision-delta.sqlite")

        complete_time = (run_dir / ".complete").stat().st_mtime
        runner_start = latest_runner_start(args.build_logs_root, candidate_id, complete_time)
        elapsed = int(round(complete_time - runner_start.timestamp()))
        require(elapsed > 0, f"invalid runner elapsed time: {name}")
        run_metrics.append({
            "control": name,
            "candidate_id": candidate_id,
            "run_id": run_id,
            "elapsed_seconds": elapsed,
            "run_artifact_bytes": directory_bytes(run_dir),
            "delta_artifact_bytes": directory_bytes(delta_dir),
        })

        if name in ("disabled", "never"):
            validate_zero_control(name, summary, diagnostics)
            require((run_dir / "periods.csv").read_bytes() == baseline_periods.read_bytes(),
                    f"{name} periods.csv is not byte-identical to formal Baseline")
        else:
            result, event_log = validate_pulse(
                name, PHASES[name], delta_dir / "decision-delta.sqlite", base_db,
                summary, diagnostics, market_dates,
            )
            pulse_results[name] = result
            all_events.extend(event_log)

    identity = {
        "studyID": STUDY_ID,
        "snapshotID": SNAPSHOT_ID,
        "marketSHA256": MARKET_SHA256,
        "decisionBaseID": DECISION_BASE_ID,
        "formalRuleCommit": FORMAL_RULE_COMMIT,
        "inputHashes": {str(path): sha256(path) for path in identity_files},
    }
    run_hash = hashlib.sha256(
        json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()[:12]
    run_id = f"mkt-r02-q0-market-vote-socket-20260902-{run_hash}"
    output_dir = args.output_root / run_id
    if output_dir.exists():
        require((output_dir / ".complete").read_text().strip() == run_id,
                f"existing output is incomplete: {output_dir}")
        print(output_dir)
        return

    args.output_root.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{run_id}.", dir=args.output_root))
    try:
        write_csv(temporary / "market-vote-events.csv", all_events)
        write_csv(temporary / "runner-metrics.csv", run_metrics)
        quality = {
            "studyID": STUDY_ID,
            "status": "complete-qualified-research-socket",
            "passed": True,
            "sampleID": "A",
            "dataRuleVersion": "T2/S39",
            "formalRuleCommit": FORMAL_RULE_COMMIT,
            "decisionBaseID": DECISION_BASE_ID,
            "snapshotID": SNAPSHOT_ID,
            "marketRowCount": 2_569,
            "diagnosticPhenomenonID": "level:market_high_from_prev_close_pct:q10:le",
            "qualifyingMarketDateCount": len(market_dates),
            "disabledControlZeroDifference": True,
            "neverControlZeroDifference": True,
            "neverControlTraversedAllPhases": True,
            "pulseResults": pulse_results,
            "totalRunnerElapsedSeconds": sum(row["elapsed_seconds"] for row in run_metrics),
            "maximumRunnerElapsedSeconds": max(row["elapsed_seconds"] for row in run_metrics),
            "totalRetainedArtifactBytes": sum(
                row["run_artifact_bytes"] + row["delta_artifact_bytes"] for row in run_metrics
            ),
            "performanceInterpreted": False,
            "ruleCandidatesGenerated": 0,
            "formalAppSchemaChanged": False,
            "dataRuleVersionChanged": False,
            "baselineChanged": False,
        }
        (temporary / "quality-report.json").write_text(
            json.dumps(quality, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        report_lines = [
            "# MKT-R02-Q0 市場票接線驗證", "",
            "- 結論：通過。研究用市場票可在固定 MT1 與正式 `simUpdate` 中，分別接入 H買、L買、賣出及加碼。",
            "- 停用與永假控制皆為 0 票、0 事件、0 動作、0 結果差異，`periods.csv` 與 Baseline 位元級一致。",
            "- 四個診斷脈衝的每張票皆為指定市場日、指定 phase、精確 `+1`；四個 phase 都出現由正式決策路徑記錄的直接動作變化。",
            "- 診斷脈衝造成的效率分數與期末差異不得用來判斷該現象有效；本段產生 0 條規則候選。", "",
            "## 接線摘要", "",
            "| phase | 市場票事件 | 市場日期 | 同前態精確 +1 | 計畫動作改變 | 實際動作改變 |",
            "|---|---:|---:|---:|---:|---:|",
        ]
        for name in PHASES:
            value = pulse_results[name]
            report_lines.append(
                f"| {value['phase']} | {value['pulseVoteCount']} | "
                f"{value['distinctMarketDateCount']} | {value['sameStateExactScoreCount']} | "
                f"{value['directPlannedActionChangeCount']} | "
                f"{value['directExecutedActionChangeCount']} |"
            )
        report_lines += ["", "## 成本", "",
                         f"- 六次 runner 合計 {quality['totalRunnerElapsedSeconds']} 秒；單次最長 {quality['maximumRunnerElapsedSeconds']} 秒。",
                         f"- 保留的 run 與 DecisionDelta 產物合計 {quality['totalRetainedArtifactBytes']} bytes。", ""]
        (temporary / "report.md").write_text("\n".join(report_lines), encoding="utf-8")

        files = ["market-vote-events.csv", "runner-metrics.csv", "quality-report.json", "report.md"]
        manifest = {
            **identity,
            "runID": run_id,
            "status": "complete-qualified-research-socket",
            "files": {name: sha256(temporary / name) for name in files},
            "controls": {name: {"candidateID": CANDIDATE_IDS[name], "runID": RUN_IDS[name]}
                         for name in RUN_IDS},
        }
        (temporary / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        (temporary / ".complete").write_text(run_id + "\n", encoding="utf-8")
        os.replace(temporary, output_dir)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    print(output_dir)


if __name__ == "__main__":
    main()
