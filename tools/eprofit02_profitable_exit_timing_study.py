#!/usr/bin/env python3
"""E-PROFIT02-D0-ABCDE: diagnose whether formal profitable exits are too early."""

from __future__ import annotations

import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path

from ecap03_long_negative_holding_study import (
    HORIZONS,
    apple_date,
    connect_readonly,
    fixed_data,
    fmt,
    hypothetical_realized_roi,
    parse_yyyymmdd,
    read_json,
    round_score,
    split_cycles,
    write_csv,
    yyyymmdd,
)
from eprofit01_long_positive_holding_study import grade_score_band


STUDY_ID = "E-PROFIT02-D0-ABCDE"
EXPECTED_SAMPLES = {"A", "B", "C", "D", "E"}
EXPECTED_COMMON = {
    "dataRuleVersion": "T2/S38",
    "ruleVersion": "s31-st02h-efficiency-loss-cut-20260831",
    "ruleCommit": "e4e41e1f1dfecb2fd320d347023a2095366ee0ec",
    "through": "2026/07/22",
    "moneyBaseWan": 600,
    "automaticInvestments": 2,
}


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--decision-base",
        action="append",
        required=True,
        metavar="SAMPLE=DIR",
        help="Repeat once for each Sample A, B, C, D, and E.",
    )
    parser.add_argument(
        "--fixed-report",
        action="append",
        required=True,
        metavar="SAMPLE=DIR",
        help="Repeat once for each matching Baseline v19 fixed-window report.",
    )
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def sample_specs(values: list[str], label: str) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        if "=" not in value:
            raise ValueError(f"invalid {label} value: {value!r}")
        sample, raw_path = value.split("=", 1)
        sample = sample.upper()
        if sample not in EXPECTED_SAMPLES or sample in result:
            raise ValueError(f"invalid or duplicate {label} sample: {sample!r}")
        result[sample] = Path(raw_path)
    if set(result) != EXPECTED_SAMPLES:
        raise ValueError(f"{label} expected A/B/C/D/E, received {sorted(result)}")
    return result


def verify_identity(
    decision_specs: dict[str, Path], report_specs: dict[str, Path]
) -> dict[str, dict]:
    identities: dict[str, dict] = {}
    for sample in sorted(EXPECTED_SAMPLES):
        decision_directory = decision_specs[sample]
        report_directory = report_specs[sample]
        decision = read_json(decision_directory / "manifest.json")
        report = read_json(report_directory / "manifest.json")
        decision_base_id = decision["decisionBaseID"]
        run_id = report["runID"]
        if (decision_directory / ".complete").read_text(
            encoding="utf-8"
        ).strip() != decision_base_id:
            raise ValueError(f"{sample} DecisionBase .complete mismatch")
        if (decision_directory / ".p4b-complete").read_text(
            encoding="utf-8"
        ).strip() != decision_base_id:
            raise ValueError(f"{sample} DecisionBase .p4b-complete mismatch")
        if (report_directory / ".complete").read_text(
            encoding="utf-8"
        ).strip() != run_id:
            raise ValueError(f"{sample} fixed report .complete mismatch")
        for manifest in (decision, report):
            if manifest.get("sampleID") != sample:
                raise ValueError(f"{sample} manifest sample mismatch")
            for key, expected in EXPECTED_COMMON.items():
                if manifest.get(key) != expected:
                    raise ValueError(
                        f"{sample} manifest mismatch {key}: {manifest.get(key)!r}"
                    )
        if report.get("periodStarts") != [
            "2017/07/22",
            "2020/07/22",
            "2023/07/22",
        ]:
            raise ValueError(f"{sample} fixed-window period mismatch")
        browse_name = report.get("browseStore")
        if not browse_name:
            raise ValueError(f"{sample} fixed report has no browseStore")
        database_path = decision_directory / "decisions.sqlite"
        browse_path = report_directory / str(browse_name)
        for path in (database_path, browse_path):
            connection = connect_readonly(path)
            integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
            connection.close()
            if integrity != "ok":
                raise ValueError(f"{sample} SQLite integrity failure: {path}")
        connection = connect_readonly(database_path)
        window_count = connection.execute("SELECT COUNT(*) FROM windows").fetchone()[0]
        stock_count = connection.execute("SELECT COUNT(*) FROM stocks").fetchone()[0]
        connection.close()
        connection = connect_readonly(browse_path)
        browse_stock_count = connection.execute("SELECT COUNT(*) FROM ZSTOCK").fetchone()[0]
        max_raw = connection.execute("SELECT MAX(ZDATETIME) FROM ZTRADE").fetchone()[0]
        connection.close()
        max_date = yyyymmdd(apple_date(float(max_raw)))
        through = parse_yyyymmdd(report["through"])
        if parse_yyyymmdd(max_date) > through or (
            through - parse_yyyymmdd(max_date)
        ).days > 7:
            raise ValueError(
                f"{sample} browse.store cutoff mismatch: {max_date} versus {report['through']}"
            )
        if window_count != 3 or stock_count != 10 or browse_stock_count != 10:
            raise ValueError(
                f"{sample} coverage mismatch: windows={window_count}, "
                f"DecisionBase stocks={stock_count}, browse stocks={browse_stock_count}"
            )
        identities[sample] = {
            "decisionBaseID": decision_base_id,
            "fixedRunID": run_id,
            "database": str(database_path),
            "browseStore": str(browse_path),
            "browseStoreMaxTradeDate": max_date,
            "windows": window_count,
            "stocks": stock_count,
        }
    return identities


def price_data(path: Path) -> dict[str, list[tuple[int, float]]]:
    connection = connect_readonly(path)
    output: dict[str, list[tuple[int, float]]] = defaultdict(list)
    for row in connection.execute(
        """
        SELECT s.ZSID stock_id,t.ZDATETIME trade_raw,t.ZPRICECLOSE close
        FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK=t.ZSTOCK
        WHERE t.ZPRICECLOSE>0
        ORDER BY s.ZSID,t.ZDATETIME
        """
    ):
        output[str(row["stock_id"])].append(
            (yyyymmdd(apple_date(float(row["trade_raw"]))), float(row["close"]))
        )
    connection.close()
    return output


def reentry_dates(path: Path) -> dict[tuple[int, int], list[int]]:
    connection = connect_readonly(path)
    output: dict[tuple[int, int], list[int]] = defaultdict(list)
    for row in connection.execute(
        """
        SELECT window_id,stock_key,trade_date
        FROM decision_events
        WHERE phase IN (1,2) AND executed_action='BUY'
        ORDER BY window_id,stock_key,trade_date
        """
    ):
        output[(int(row["window_id"]), int(row["stock_key"]))].append(
            int(row["trade_date"])
        )
    connection.close()
    return output


def sell_gate_map(path: Path) -> dict[int, list[str]]:
    connection = connect_readonly(path)
    output: dict[int, list[str]] = defaultdict(list)
    for row in connection.execute(
        """
        SELECT e.event_id,r.rule_id
        FROM decision_events e
        JOIN event_gates g USING(event_id)
        JOIN rules r USING(rule_key)
        WHERE e.phase=3 AND e.executed_action='SELL' AND r.kind=2
        ORDER BY e.event_id,r.rule_id
        """
    ):
        output[int(row["event_id"])].append(str(row["rule_id"]))
    connection.close()
    return output


def future_metrics(
    sale: dict,
    prices: list[tuple[int, float]],
    reentries: list[int],
) -> dict:
    sale_date = int(sale["trade_date"])
    window_end = int(sale["end_date"])
    future = [(date, close) for date, close in prices if sale_date < date <= window_end]
    formal_roi = hypothetical_realized_roi(
        float(sale["unit_cost_before"]),
        float(sale["unit_roi_before"]),
        float(sale["inventory_before"]),
    )
    formal_days = float(sale["holding_days_before"])
    formal_score = round_score(formal_roi, formal_days)
    result: dict[str, object] = {
        "formal_realized_roi": formal_roi,
        "formal_round_score": formal_score,
    }
    first_reentry = next((date for date in reentries if date > sale_date), None)
    result["first_reentry_date"] = first_reentry
    for horizon in HORIZONS:
        if len(future) < horizon:
            result.update(
                {
                    f"complete_{horizon}": 0,
                    f"endpoint_date_{horizon}": None,
                    f"hypothetical_roi_{horizon}": None,
                    f"roi_delta_{horizon}": None,
                    f"hypothetical_days_{horizon}": None,
                    f"hypothetical_score_{horizon}": None,
                    f"score_delta_{horizon}": None,
                    f"score_improved_{horizon}": None,
                    f"reentry_within_{horizon}": None,
                    f"reentry_trading_day_{horizon}": None,
                }
            )
            continue
        endpoint_date, endpoint_close = future[horizon - 1]
        market_roi = 100.0 * (
            endpoint_close / float(sale["unit_cost_before"]) - 1.0
        )
        hypothetical_roi = hypothetical_realized_roi(
            float(sale["unit_cost_before"]),
            market_roi,
            float(sale["inventory_before"]),
        )
        calendar_days = (
            parse_yyyymmdd(endpoint_date) - parse_yyyymmdd(sale_date)
        ).days
        hypothetical_days = formal_days + calendar_days
        hypothetical_score = round_score(hypothetical_roi, hypothetical_days)
        reentry_offset = next(
            (
                index
                for index, (date, _) in enumerate(future[:horizon], 1)
                if date == first_reentry
            ),
            None,
        )
        result.update(
            {
                f"complete_{horizon}": 1,
                f"endpoint_date_{horizon}": endpoint_date,
                f"hypothetical_roi_{horizon}": hypothetical_roi,
                f"roi_delta_{horizon}": hypothetical_roi - formal_roi,
                f"hypothetical_days_{horizon}": hypothetical_days,
                f"hypothetical_score_{horizon}": hypothetical_score,
                f"score_delta_{horizon}": hypothetical_score - formal_score,
                f"score_improved_{horizon}": int(hypothetical_score > formal_score),
                f"reentry_within_{horizon}": int(reentry_offset is not None),
                f"reentry_trading_day_{horizon}": reentry_offset,
            }
        )
    return result


def build_events(decision_path: Path, browse_path: Path) -> list[dict]:
    rows, _, _ = fixed_data(decision_path)
    prices_by_stock = price_data(browse_path)
    reentries_by_path = reentry_dates(decision_path)
    gates_by_event = sell_gate_map(decision_path)
    records: list[dict] = []
    for path_key, cycle_number, cycle in split_cycles(rows, "inventory", "sold"):
        if not cycle or not cycle[-1]["sold"]:
            continue
        sale = cycle[-1]
        formal_roi = hypothetical_realized_roi(
            float(sale["unit_cost_before"]),
            float(sale["unit_roi_before"]),
            float(sale["inventory_before"]),
        )
        if formal_roi <= 0:
            continue
        gates = gates_by_event.get(int(sale["event_id"]), [])
        if not gates:
            raise ValueError(f"positive formal sale has no S-T exit gate: {sale}")
        stock_prices = prices_by_stock[str(sale["stock_id"])]
        current_price = next(
            (close for date, close in stock_prices if date == int(sale["trade_date"])),
            None,
        )
        if current_price is None:
            raise ValueError(f"sale date price missing: {sale}")
        implied_price = float(sale["unit_cost_before"]) * (
            1.0 + float(sale["unit_roi_before"]) / 100.0
        )
        if abs(current_price - implied_price) > 0.000001:
            raise ValueError(
                f"sale price mismatch: store={current_price}, implied={implied_price}, "
                f"event={sale['event_id']}"
            )
        gate_combination = "+".join(gates)
        sole_gate = gates[0] if len(gates) == 1 else None
        grade_score = float(sale["grade_efficiency_score"])
        records.append(
            {
                "window_start": int(sale["start_date"]),
                "window_end": int(sale["end_date"]),
                "stock_id": sale["stock_id"],
                "stock_name": sale["stock_name"],
                "group": sale["group_name"],
                "cycle_number": cycle_number,
                "trade_date": int(sale["trade_date"]),
                "holding_days": float(sale["holding_days_before"]),
                "inventory": float(sale["inventory_before"]),
                "unit_cost": float(sale["unit_cost_before"]),
                "sale_close": current_price,
                "market_roi": float(sale["unit_roi_before"]),
                "decision_grade": sale["grade_name"],
                "decision_grade_raw": int(sale["grade"]),
                "grade_efficiency_score": grade_score,
                "grade_score_band": grade_score_band(grade_score),
                "sell_score": float(sale["decision_score"]),
                "exit_gate_count": len(gates),
                "exit_gates": "|".join(gates),
                "gate_combination": gate_combination,
                "sole_exit_gate": sole_gate,
            }
            | future_metrics(
                sale,
                stock_prices,
                reentries_by_path.get(path_key, []),
            )
        )
    return records


def median(rows: list[dict], key: str) -> float | None:
    values = [float(row[key]) for row in rows if row.get(key) is not None]
    return statistics.median(values) if values else None


def rate(rows: list[dict], key: str) -> float | None:
    values = [float(row[key]) for row in rows if row.get(key) is not None]
    return sum(values) / len(values) if values else None


def summary(rows: list[dict], label: str) -> dict:
    result: dict[str, object] = {
        "label": label,
        "events": len(rows),
        "samples": len({row["sample"] for row in rows}),
        "sampleIDs": sorted({row["sample"] for row in rows}),
        "stocks": len({row["stock_id"] for row in rows}),
        "windows": len({row["window_start"] for row in rows}),
        "medianFormalROI": median(rows, "formal_realized_roi"),
        "medianFormalScore": median(rows, "formal_round_score"),
    }
    for horizon in HORIZONS:
        complete = [row for row in rows if row[f"complete_{horizon}"] == 1]
        no_reentry = [
            row for row in complete if row[f"reentry_within_{horizon}"] == 0
        ]
        result[f"h{horizon}"] = {
            "complete": len(complete),
            "scoreImprovedRate": rate(complete, f"score_improved_{horizon}"),
            "medianROIDelta": median(complete, f"roi_delta_{horizon}"),
            "medianScoreDelta": median(complete, f"score_delta_{horizon}"),
            "reentryRate": rate(complete, f"reentry_within_{horizon}"),
            "noReentry": {
                "events": len(no_reentry),
                "samples": len({row["sample"] for row in no_reentry}),
                "sampleIDs": sorted({row["sample"] for row in no_reentry}),
                "stocks": len({row["stock_id"] for row in no_reentry}),
                "windows": len({row["window_start"] for row in no_reentry}),
                "scoreImprovedRate": rate(
                    no_reentry, f"score_improved_{horizon}"
                ),
                "medianROIDelta": median(no_reentry, f"roi_delta_{horizon}"),
                "medianScoreDelta": median(
                    no_reentry, f"score_delta_{horizon}"
                ),
            },
        }
    return result


def flat_summary(item: dict, label_key: str) -> dict:
    output = {
        label_key: item["label"],
        "samples": item["samples"],
        "sample_ids": "|".join(item["sampleIDs"]),
        "events": item["events"],
        "stocks": item["stocks"],
        "windows": item["windows"],
        "median_formal_roi": item["medianFormalROI"],
        "median_formal_score": item["medianFormalScore"],
    }
    for horizon in HORIZONS:
        value = item[f"h{horizon}"]
        no_reentry = value["noReentry"]
        output.update(
            {
                f"h{horizon}_complete": value["complete"],
                f"h{horizon}_score_improved_rate": value["scoreImprovedRate"],
                f"h{horizon}_median_roi_delta": value["medianROIDelta"],
                f"h{horizon}_median_score_delta": value["medianScoreDelta"],
                f"h{horizon}_reentry_rate": value["reentryRate"],
                f"h{horizon}_no_reentry_events": no_reentry["events"],
                f"h{horizon}_no_reentry_samples": no_reentry["samples"],
                f"h{horizon}_no_reentry_stocks": no_reentry["stocks"],
                f"h{horizon}_no_reentry_windows": no_reentry["windows"],
                f"h{horizon}_no_reentry_improved_rate": no_reentry[
                    "scoreImprovedRate"
                ],
                f"h{horizon}_no_reentry_median_score_delta": no_reentry[
                    "medianScoreDelta"
                ],
            }
        )
    return output


def grouped_summaries(groups: dict[str, list[dict]]) -> list[dict]:
    return [summary(rows, label) for label, rows in sorted(groups.items())]


def by_sample_summaries(
    groups: dict[tuple[str, str], list[dict]], label_key: str
) -> list[dict]:
    output: list[dict] = []
    for (label, sample), rows in sorted(groups.items()):
        value = flat_summary(summary(rows, label), label_key)
        value["sample"] = sample
        output.append(value)
    return output


def consistently_improves(item: dict) -> bool:
    return all(
        item[f"h{horizon}"]["complete"] >= 1
        and (item[f"h{horizon}"]["medianScoreDelta"] or 0) > 0
        and (item[f"h{horizon}"]["scoreImprovedRate"] or 0) > 0.5
        for horizon in HORIZONS
    )


def candidate_signal(
    pooled: dict,
    per_sample: dict[str, dict],
) -> tuple[bool, list[str], list[str]]:
    improving_samples = sorted(
        sample for sample, item in per_sample.items() if consistently_improves(item)
    )
    idle20_samples = sorted(
        sample
        for sample, item in per_sample.items()
        if item["h20"]["noReentry"]["events"] >= 1
        and (item["h20"]["noReentry"]["medianScoreDelta"] or 0) > 0
    )
    idle20 = pooled["h20"]["noReentry"]
    pooled_improves = (
        pooled["samples"] >= 2
        and pooled["stocks"] >= 2
        and pooled["windows"] >= 2
        and all(
            pooled[f"h{horizon}"]["complete"] >= 2
            and (pooled[f"h{horizon}"]["medianScoreDelta"] or 0) > 0
            and (pooled[f"h{horizon}"]["scoreImprovedRate"] or 0) > 0.5
            for horizon in HORIZONS
        )
        and idle20["events"] >= 2
        and idle20["samples"] >= 2
        and idle20["stocks"] >= 2
        and idle20["windows"] >= 2
        and (idle20["medianScoreDelta"] or 0) > 0
        and (idle20["scoreImprovedRate"] or 0) > 0.5
    )
    return (
        pooled_improves
        and len(improving_samples) >= 2
        and len(idle20_samples) >= 2,
        improving_samples,
        idle20_samples,
    )


def main() -> None:
    args = arguments()
    decision_specs = sample_specs(args.decision_base, "--decision-base")
    report_specs = sample_specs(args.fixed_report, "--fixed-report")
    identities = verify_identity(decision_specs, report_specs)

    events: list[dict] = []
    for sample in sorted(EXPECTED_SAMPLES):
        events.extend(
            {"sample": sample} | row
            for row in build_events(
                decision_specs[sample] / "decisions.sqlite",
                report_specs[sample] / "browse.store",
            )
        )

    gate_groups: dict[str, list[dict]] = defaultdict(list)
    gate_sample_groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    sole_groups: dict[str, list[dict]] = defaultdict(list)
    sole_sample_groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    combination_groups: dict[str, list[dict]] = defaultdict(list)
    grade_score_groups: dict[str, list[dict]] = defaultdict(list)
    grade_score_sample_groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    sole_grade_groups: dict[str, list[dict]] = defaultdict(list)
    sole_grade_sample_groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    sell_score_groups: dict[str, list[dict]] = defaultdict(list)
    sample_groups: dict[str, list[dict]] = defaultdict(list)
    for row in events:
        sample = str(row["sample"])
        sample_groups[sample].append(row)
        gates = str(row["exit_gates"]).split("|")
        combination_groups[str(row["gate_combination"])].append(row)
        for gate in gates:
            gate_groups[gate].append(row)
            gate_sample_groups[(gate, sample)].append(row)
        if row["sole_exit_gate"] is not None:
            sole = str(row["sole_exit_gate"])
            sole_groups[sole].append(row)
            sole_sample_groups[(sole, sample)].append(row)
            cross = f"{sole}__{row['grade_score_band']}"
            sole_grade_groups[cross].append(row)
            sole_grade_sample_groups[(cross, sample)].append(row)
        grade_label = str(row["grade_score_band"])
        grade_score_groups[grade_label].append(row)
        grade_score_sample_groups[(grade_label, sample)].append(row)
        sell_score_groups[f"sell_score_{float(row['sell_score']):g}"].append(row)

    overall = summary(events, "A-E fixed")
    overall_by_sample = grouped_summaries(sample_groups)
    by_gate = grouped_summaries(gate_groups)
    sole = grouped_summaries(sole_groups)
    by_combination = grouped_summaries(combination_groups)
    by_grade_score = grouped_summaries(grade_score_groups)
    by_sole_grade = grouped_summaries(sole_grade_groups)
    by_sell_score = grouped_summaries(sell_score_groups)
    sole_by_sample = {
        label: {
            sample: summary(rows, label)
            for (group_label, sample), rows in sorted(sole_sample_groups.items())
            if group_label == label
        }
        for label in sole_groups
    }
    sole_grade_by_sample = {
        label: {
            sample: summary(rows, label)
            for (group_label, sample), rows in sorted(
                sole_grade_sample_groups.items()
            )
            if group_label == label
        }
        for label in sole_grade_groups
    }

    signals: list[dict] = []
    for kind, pooled_items, sample_items in (
        ("sole_exit_gate", sole, sole_by_sample),
        ("sole_exit_gate_grade_score_band", by_sole_grade, sole_grade_by_sample),
    ):
        for item in pooled_items:
            qualifies, improving_samples, idle20_samples = candidate_signal(
                item, sample_items[item["label"]]
            )
            if qualifies:
                signals.append(
                    {
                        "kind": kind,
                        "condition": item["label"],
                        "improvingSamples": improving_samples,
                        "idle20ImprovingSamples": idle20_samples,
                    }
                )

    result = {
        "studyID": STUDY_ID,
        "identity": identities,
        "commonIdentity": EXPECTED_COMMON,
        "definition": (
            "formal completed sales with positive realized ROI; compare the formal "
            "sale with holding the same lot for 20/60/120 trading days"
        ),
        "overall": overall,
        "overallBySample": overall_by_sample,
        "byExitGate": by_gate,
        "soleExitGates": sole,
        "soleExitGatesBySample": sole_by_sample,
        "byGateCombination": by_combination,
        "byGradeScoreBand": by_grade_score,
        "bySoleExitGateGradeScoreBand": by_sole_grade,
        "bySoleExitGateGradeScoreBandSample": sole_grade_by_sample,
        "bySellScore": by_sell_score,
        "candidateSignals": signals,
        "recommendedNext": None,
    }

    args.output.mkdir(parents=True, exist_ok=False)
    write_csv(args.output / "events.csv", events)
    write_csv(
        args.output / "overall-by-sample.csv",
        [flat_summary(item, "sample") for item in overall_by_sample],
    )
    write_csv(
        args.output / "exit-gate-summary.csv",
        [flat_summary(item, "exit_gate") for item in by_gate],
    )
    write_csv(
        args.output / "exit-gate-by-sample.csv",
        by_sample_summaries(gate_sample_groups, "exit_gate"),
    )
    write_csv(
        args.output / "sole-exit-gate-summary.csv",
        [flat_summary(item, "sole_exit_gate") for item in sole],
    )
    write_csv(
        args.output / "sole-exit-gate-by-sample.csv",
        by_sample_summaries(sole_sample_groups, "sole_exit_gate"),
    )
    write_csv(
        args.output / "gate-combination-summary.csv",
        [flat_summary(item, "gate_combination") for item in by_combination],
    )
    write_csv(
        args.output / "grade-score-band-summary.csv",
        [flat_summary(item, "grade_score_band") for item in by_grade_score],
    )
    write_csv(
        args.output / "grade-score-band-by-sample.csv",
        by_sample_summaries(grade_score_sample_groups, "grade_score_band"),
    )
    write_csv(
        args.output / "sole-gate-grade-score-band-summary.csv",
        [
            flat_summary(item, "sole_gate_grade_score_band")
            for item in by_sole_grade
        ],
    )
    write_csv(
        args.output / "sole-gate-grade-score-band-by-sample.csv",
        by_sample_summaries(
            sole_grade_sample_groups, "sole_gate_grade_score_band"
        ),
    )
    write_csv(
        args.output / "sell-score-summary.csv",
        [flat_summary(item, "sell_score") for item in by_sell_score],
    )
    (args.output / "summary.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    lines = [
        "# E-PROFIT02-D0-ABCDE Baseline v19 正 ROI 正式賣出時機診斷",
        "",
        "- 樣本：A／B／C／D／E，各 10 檔、3 個固定三年窗口。",
        f"- 資料／策略／截止日：`{EXPECTED_COMMON['dataRuleVersion']}`／"
        f"`{EXPECTED_COMMON['ruleVersion']}`／`{EXPECTED_COMMON['through']}`。",
        "- 案例定義：正式路徑以正實現 ROI 完整賣出的持股輪；"
        f"共 {len(events)} 件。",
        "- 分數變化以正式賣出為基準；正值表示保留同一批持股到觀察日較好，負值表示正式賣出較好。",
        "- 重新進場只作資金釋放價值標記；本診斷不把假設持有與正式後續新持股相加為反事實績效。",
        "",
        "## 整體",
        "",
    ]
    for horizon in HORIZONS:
        item = overall[f"h{horizon}"]
        idle = item["noReentry"]
        lines.append(
            f"- {horizon} 日：{item['complete']} 件；分數變化中位 "
            f"{fmt(item['medianScoreDelta'])}、改善率 "
            f"{fmt(item['scoreImprovedRate'])}、正式路徑重新進場率 "
            f"{fmt(item['reentryRate'])}；未重新進場 {idle['events']} 件的中位 "
            f"{fmt(idle['medianScoreDelta'])}。"
        )
    lines.extend(["", "## 逐樣本", ""])
    for item in overall_by_sample:
        lines.append(
            f"- Sample {item['label']}：{item['events']} 件；20／60／120 日分數變化中位 "
            f"{fmt(item['h20']['medianScoreDelta'])}／"
            f"{fmt(item['h60']['medianScoreDelta'])}／"
            f"{fmt(item['h120']['medianScoreDelta'])}；20 日未重新進場 "
            f"{item['h20']['noReentry']['events']} 件、中位 "
            f"{fmt(item['h20']['noReentry']['medianScoreDelta'])}。"
        )
    lines.extend(["", "## 唯一正式出口", ""])
    for item in sole:
        lines.append(
            f"- `{item['label']}`：{item['events']} 件、{item['samples']} 樣本、"
            f"{item['stocks']} 檔、{item['windows']} 窗口；20／60／120 日分數變化中位 "
            f"{fmt(item['h20']['medianScoreDelta'])}／"
            f"{fmt(item['h60']['medianScoreDelta'])}／"
            f"{fmt(item['h120']['medianScoreDelta'])}；20 日未重新進場 "
            f"{item['h20']['noReentry']['events']} 件、中位 "
            f"{fmt(item['h20']['noReentry']['medianScoreDelta'])}。"
        )
    lines.extend(["", "## 候選訊號與停止條件", ""])
    lines.extend(
        [
            "- 同一唯一出口或其固定 Grade 連續分數區間，需 pooled 與至少 2 個樣本的 20／60／120 日分數中位皆改善、改善率過半，合計跨至少 2 檔與 2 窗口；20 日未重新進場子群還須跨至少 2 樣本、2 檔與 2 窗口同向，才列為候選訊號。",
            f"- 符合者：{', '.join(item['condition'] for item in signals) or '無'}。",
            "- 本診斷不計入延後賣出對後續買賣路徑的完整影響；任何候選仍須獨立完整重播。",
        ]
    )
    (args.output / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
