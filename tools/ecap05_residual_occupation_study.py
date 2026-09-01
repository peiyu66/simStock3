#!/usr/bin/env python3
"""E-CAP05-D0: diagnose residual long negative holdings after S-T02h."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

from ecap03_long_negative_holding_study import (
    HORIZONS,
    build_full,
    connect_readonly,
    fixed_data,
    fmt,
    horizon_summary,
    horizon_values,
    parse_yyyymmdd,
    read_json,
    split_cycles,
    write_csv,
    yyyymmdd,
    apple_date,
)


STUDY_ID = "E-CAP05-D0-E"
EXPECTED = {
    "sampleID": "E",
    "dataRuleVersion": "T2/S38",
    "ruleVersion": "s31-st02h-efficiency-loss-cut-20260831",
    "ruleCommit": "e4e41e1f1dfecb2fd320d347023a2095366ee0ec",
}


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--decision-db", type=Path, required=True)
    parser.add_argument("--decision-manifest", type=Path, required=True)
    parser.add_argument("--fixed-manifest", type=Path, required=True)
    parser.add_argument("--fixed-store", type=Path, required=True)
    parser.add_argument("--full-manifest", type=Path, required=True)
    parser.add_argument("--full-store", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def verify_identity(args: argparse.Namespace) -> dict:
    decision = read_json(args.decision_manifest)
    fixed = read_json(args.fixed_manifest)
    full = read_json(args.full_manifest)
    decision_id = decision["decisionBaseID"]
    identity = {
        "decisionBaseID": decision_id,
        "decisionComplete": args.decision_manifest.parent.joinpath(".complete").read_text(encoding="utf-8").strip(),
        "p4bComplete": args.decision_manifest.parent.joinpath(".p4b-complete").read_text(encoding="utf-8").strip(),
        "fixedRunID": fixed["runID"],
        "fixedComplete": args.fixed_manifest.parent.joinpath(".complete").read_text(encoding="utf-8").strip(),
        "fullRunID": full["runID"],
        "fullComplete": args.full_manifest.parent.joinpath(".complete").read_text(encoding="utf-8").strip(),
    }
    if identity["decisionComplete"] != decision_id or identity["p4bComplete"] != decision_id:
        raise ValueError("DecisionBase completion marker mismatch")
    if identity["fixedComplete"] != fixed["runID"] or identity["fullComplete"] != full["runID"]:
        raise ValueError("report completion marker mismatch")
    for manifest in (decision, fixed, full):
        for key, expected in EXPECTED.items():
            if manifest.get(key) != expected:
                raise ValueError(f"manifest mismatch {key}: {manifest.get(key)!r}")
    if fixed["periodStarts"] != ["2017/07/22", "2020/07/22", "2023/07/22"]:
        raise ValueError("fixed-window manifest periods mismatch")
    if full["periodStarts"] != ["2017/07/22"]:
        raise ValueError("full-period manifest periods mismatch")
    if fixed["through"] != full["through"] or fixed["through"] != decision["through"]:
        raise ValueError("through date mismatch")
    for path in (args.decision_db, args.fixed_store, args.full_store):
        connection = connect_readonly(path)
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        connection.close()
        if integrity != "ok":
            raise ValueError(f"SQLite integrity failure: {path}")
    connection = connect_readonly(args.full_store)
    max_raw = connection.execute("SELECT MAX(ZDATETIME) FROM ZTRADE").fetchone()[0]
    connection.close()
    max_date = yyyymmdd(apple_date(float(max_raw)))
    through_date = parse_yyyymmdd(full["through"])
    if parse_yyyymmdd(max_date) > through_date or (through_date - parse_yyyymmdd(max_date)).days > 7:
        raise ValueError(f"full-period store cutoff mismatch: {max_date} versus {full['through']}")
    identity.update(EXPECTED)
    identity.update({"through": fixed["through"], "fullStoreMaxTradeDate": max_date})
    return identity


def st02h_blockers(row: dict, recent_add: bool) -> tuple[list[str], dict]:
    grade = int(row["grade"])
    days = float(row["holding_days_before"])
    roi = float(row["unit_roi_before"])
    fit_score = float(row["grade_efficiency_score"])
    sell_score = float(row["decision_score"])
    score_threshold = 1.0 if grade >= 0 and days < 400 else 2.0
    score_gate = sell_score >= score_threshold
    blockers: list[str] = []
    if roi <= -25:
        blockers.append("roi_at_or_below_m25")
    if fit_score >= -10:
        blockers.append("efficiency_not_below_m10")
    if not score_gate:
        blockers.append("sell_votes_insufficient")
    if recent_add:
        blockers.append("recent_add_60")
    if not blockers:
        raise ValueError(f"S-T02h-qualified event unexpectedly held: {row}")
    return blockers, {
        "sell_score_threshold": score_threshold,
        "sell_score_gap": sell_score - score_threshold,
        "score_gate_passed": int(score_gate),
        "roi_gate_passed": int(roi > -25),
        "efficiency_gate_passed": int(fit_score < -10),
        "cooldown_gate_passed": int(not recent_add),
    }


def build_fixed(path: Path) -> list[dict]:
    rows, dates, adds = fixed_data(path)
    records: list[dict] = []
    for path_key, cycle_number, cycle in split_cycles(rows, "inventory", "sold"):
        checkpoint_index = next(
            (
                index
                for index, row in enumerate(cycle)
                if float(row["holding_days_before"]) > 120
                and float(row["unit_roi_before"]) < 0
                and not row["sold"]
            ),
            None,
        )
        if checkpoint_index is None:
            continue
        row = cycle[checkpoint_index]
        all_dates = dates[path_key]
        date_index = {value: index for index, value in enumerate(all_dates)}
        prior_adds = [value for value in adds.get(path_key, []) if value < int(row["trade_date"])]
        last_add = prior_adds[-1] if prior_adds else None
        since_add = date_index[int(row["trade_date"])] - date_index[last_add] if last_add is not None else None
        recent_add = since_add is not None and since_add <= 60
        blockers, gate_details = st02h_blockers(row, recent_add)
        for item in cycle:
            item["added"] = int(item["trade_date"]) in adds.get(path_key, [])
        records.append(
            {
                "source": "fixed",
                "window_start": int(row["start_date"]),
                "window_end": int(row["end_date"]),
                "stock_id": row["stock_id"],
                "stock_name": row["stock_name"],
                "group": row["group_name"],
                "cycle_number": cycle_number,
                "trade_date": int(row["trade_date"]),
                "holding_days": float(row["holding_days_before"]),
                "market_roi": float(row["unit_roi_before"]),
                "decision_grade": row["grade_name"],
                "decision_grade_raw": int(row["grade"]),
                "grade_efficiency_score": float(row["grade_efficiency_score"]),
                "sell_score": float(row["decision_score"]),
                "last_add_date": last_add,
                "trading_days_since_add": since_add,
                "recent_add_60": int(recent_add),
                "blocker_count": len(blockers),
                "blocker_combination": "+".join(blockers),
                "blockers": "|".join(blockers),
            }
            | gate_details
            | horizon_values(cycle, checkpoint_index, "fixed")
        )
    return records


def flattened_summary(item: dict, label_key: str = "blocker") -> dict:
    row = {
        label_key: item["label"],
        "events": item["events"],
        "stocks": item["stocks"],
        "windows": item["windows"],
        "outcome_score_improved_rate": item["outcomeScoreImprovedRate"],
        "outcome_median_roi_delta": item["outcomeMedianROIDelta"],
        "outcome_median_score_delta": item["outcomeMedianScoreDelta"],
        "outcome_median_trading_days": item["outcomeMedianTradingDays"],
        "outcome_median_capital_trading_day_wan": item["outcomeMedianCapitalTradingDayWan"],
    }
    for horizon in HORIZONS:
        row.update(
            {
                f"h{horizon}_complete": item[f"h{horizon}"]["complete"],
                f"h{horizon}_score_improved_rate": item[f"h{horizon}"]["scoreImprovedRate"],
                f"h{horizon}_median_roi_delta": item[f"h{horizon}"]["medianROIDelta"],
                f"h{horizon}_median_score_delta": item[f"h{horizon}"]["medianScoreDelta"],
                f"h{horizon}_median_capital_trading_day_wan": item[f"h{horizon}"]["medianCapitalTradingDayWan"],
            }
        )
    return row


def candidate_worthy(item: dict) -> bool:
    return (
        item["events"] >= 3
        and item["stocks"] >= 2
        and item["windows"] >= 2
        and all(
            item[f"h{horizon}"]["complete"] >= 3
            and (item[f"h{horizon}"]["medianScoreDelta"] or 0) < 0
            and (item[f"h{horizon}"]["scoreImprovedRate"] or 0) < 0.5
            for horizon in (60, 120)
        )
        and (item["outcomeMedianScoreDelta"] or 0) < 0
    )


def main() -> None:
    args = arguments()
    args.output.mkdir(parents=True, exist_ok=True)
    identity = verify_identity(args)
    fixed = build_fixed(args.decision_db)
    full = build_full(args.full_store, identity["through"])
    write_csv(args.output / "fixed-events.csv", fixed)
    write_csv(args.output / "full-events.csv", full)

    individual_groups: dict[str, list[dict]] = defaultdict(list)
    combination_groups: dict[str, list[dict]] = defaultdict(list)
    sole_groups: dict[str, list[dict]] = defaultdict(list)
    for row in fixed:
        blockers = str(row["blockers"]).split("|")
        combination_groups[str(row["blocker_combination"])].append(row)
        for blocker in blockers:
            individual_groups[blocker].append(row)
        if len(blockers) == 1:
            sole_groups[blockers[0]].append(row)

    individual = [horizon_summary(rows, key) for key, rows in sorted(individual_groups.items())]
    combinations = [horizon_summary(rows, key) for key, rows in sorted(combination_groups.items())]
    sole = [horizon_summary(rows, key) for key, rows in sorted(sole_groups.items())]
    write_csv(args.output / "blocker-summary.csv", [flattened_summary(item) for item in individual])
    write_csv(args.output / "combination-summary.csv", [flattened_summary(item, "combination") for item in combinations])
    write_csv(args.output / "sole-blocker-summary.csv", [flattened_summary(item) for item in sole])

    fixed_summary = horizon_summary(fixed, "fixed")
    full_summary = horizon_summary(full, "full")
    candidate_signals = [item["label"] for item in sole if candidate_worthy(item)]
    cooldown45_rows = [
        row
        for row in fixed
        if row["blocker_count"] == 1
        and row["blocker_combination"] == "recent_add_60"
        and row["trading_days_since_add"] is not None
        and float(row["trading_days_since_add"]) > 45
    ]
    cooldown45_summary = horizon_summary(cooldown45_rows, "recent_add_46_to_60")
    recommend_cooldown45 = (
        cooldown45_summary["events"] >= 2
        and cooldown45_summary["stocks"] >= 2
        and cooldown45_summary["windows"] >= 2
        and cooldown45_summary["outcomeScoreImprovedRate"] == 0
        and (cooldown45_summary["outcomeMedianScoreDelta"] or 0) < 0
    )
    summary = {
        "studyID": STUDY_ID,
        "identity": identity,
        "definition": "first held sell decision after 120 days with negative current ROI in each holding cycle",
        "fixed": fixed_summary,
        "full": full_summary,
        "byBlocker": individual,
        "byCombination": combinations,
        "soleBlockers": sole,
        "candidateSignals": candidate_signals,
        "cooldown45Signal": cooldown45_summary,
        "recommendedNext": "E-CAP05-S1-E" if recommend_cooldown45 else None,
    }
    (args.output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    lines = [
        "# E-CAP05-D0-E Baseline v19 剩餘長期資金占用診斷",
        "",
        f"- DecisionBase：`{identity['decisionBaseID']}`。",
        f"- 固定／全期間：`{identity['fixedRunID']}`／`{identity['fullRunID']}`。",
        f"- Sample／資料／策略：`{identity['sampleID']}`／`{identity['dataRuleVersion']}`／`{identity['ruleVersion']}`。",
        f"- 截止日：`{identity['through']}`（store 最後交易日 `{identity['fullStoreMaxTradeDate']}`）；固定窗口案例 {len(fixed)}，全期間案例 {len(full)}。",
        "",
        "## 各項 S-T02h 阻擋原因（可重疊）",
        "",
    ]
    for item in individual:
        lines.append(
            f"- `{item['label']}`：{item['events']} 件、{item['stocks']} 檔、{item['windows']} 窗口；"
            f"20／60／120 日分數變化中位 "
            f"{fmt(item['h20']['medianScoreDelta'])}／{fmt(item['h60']['medianScoreDelta'])}／{fmt(item['h120']['medianScoreDelta'])}；"
            f"實際結案或期末分數變化中位 {fmt(item['outcomeMedianScoreDelta'])}。"
        )
    lines.extend(["", "## 單一阻擋原因", ""])
    for item in sole:
        lines.append(
            f"- `{item['label']}`：{item['events']} 件、{item['stocks']} 檔、{item['windows']} 窗口；"
            f"60／120 日改善率 {fmt(item['h60']['scoreImprovedRate'])}／{fmt(item['h120']['scoreImprovedRate'])}；"
            f"60／120 日資金占用中位 {fmt(item['h60']['medianCapitalTradingDayWan'])}／"
            f"{fmt(item['h120']['medianCapitalTradingDayWan'])} 萬元·交易日。"
        )
    lines.extend(["", "## 整體等待結果", ""])
    for item in (fixed_summary, full_summary):
        lines.append(
            f"- `{item['label']}`：{item['events']} 件、{item['stocks']} 檔、{item['windows']} 窗口；"
            f"20／60／120 日 ROI 變化中位 "
            f"{fmt(item['h20']['medianROIDelta'])}／{fmt(item['h60']['medianROIDelta'])}／{fmt(item['h120']['medianROIDelta'])}；"
            f"分數變化中位 {fmt(item['h20']['medianScoreDelta'])}／"
            f"{fmt(item['h60']['medianScoreDelta'])}／{fmt(item['h120']['medianScoreDelta'])}。"
        )
    lines.extend(
        [
            "",
            "## 候選訊號與停止條件",
            "",
            f"- 只有移除該一項就能立即符合 S-T02h 的單一阻擋群，且跨至少 2 檔、2 窗口並在 60／120 日及期末持續惡化者：{', '.join(candidate_signals) or '無'}。",
            f"- 若把冷卻從 60 日縮至 45 日，正式路徑上會先解鎖 {cooldown45_summary['events']} 件、"
            f"{cooldown45_summary['stocks']} 檔、{cooldown45_summary['windows']} 窗口；"
            f"其實際結案分數改善率 {fmt(cooldown45_summary['outcomeScoreImprovedRate'])}，"
            f"分數變化中位 {fmt(cooldown45_summary['outcomeMedianScoreDelta'])}。",
            f"- 建議下一候選：{'E-CAP05-S1-E，S-T02h 冷卻 60 → 45 個交易日' if recommend_cooldown45 else '無'}。",
            "- 後續 ROI、分數與資金占用只作候選生成證據；沒有完整反事實重播，不等同候選績效。",
        ]
    )
    (args.output / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
