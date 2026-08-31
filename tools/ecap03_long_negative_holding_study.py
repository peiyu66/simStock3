#!/usr/bin/env python3
"""E-CAP03-D0-E: diagnose score and capital cost of long negative holdings."""

from __future__ import annotations

import argparse
import csv
import json
import math
import sqlite3
import statistics
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path


HORIZONS = (20, 60, 120)
APPLE_EPOCH = datetime(2001, 1, 1)


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


def connect_readonly(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def parse_yyyymmdd(value: int | str) -> date:
    digits = str(value).replace("/", "").replace("-", "")
    return datetime.strptime(digits, "%Y%m%d").date()


def apple_date(value: float) -> date:
    return (APPLE_EPOCH + timedelta(seconds=value)).date()


def yyyymmdd(value: date) -> int:
    return value.year * 10000 + value.month * 100 + value.day


def round_currency(value: float) -> float:
    return math.floor(value + 0.5)


def hypothetical_realized_roi(unit_cost: float, market_roi: float, quantity: float) -> float:
    if unit_cost <= 0 or quantity <= 0:
        raise ValueError("invalid cost or quantity for hypothetical liquidation")
    close = unit_cost * (1.0 + market_roi / 100.0)
    proceeds = close * quantity * 1000.0
    fee = max(20.0, round_currency(proceeds * 0.001425))
    tax = round_currency(proceeds * 0.003)
    cost = unit_cost * quantity * 1000.0
    return 100.0 * (proceeds - cost - fee - tax) / cost


def round_score(roi: float, holding_days: float) -> float:
    if holding_days <= 0:
        raise ValueError("holding days must be positive")
    return roi * 100.0 / holding_days if roi >= 0 else roi * holding_days / 100.0


def median(rows: list[dict], key: str) -> float | None:
    values = [float(row[key]) for row in rows if row.get(key) is not None]
    return statistics.median(values) if values else None


def rate(rows: list[dict], key: str) -> float | None:
    values = [float(row[key]) for row in rows if row.get(key) is not None]
    return sum(values) / len(values) if values else None


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        return
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


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
        expected = {
            "sampleID": "E",
            "dataRuleVersion": "T2/S37",
            "ruleVersion": "s30-hn12-damn-loss-reentry-hbuy-20260831",
            "ruleCommit": "3996af3798a52bd488b6aaf2619c5ada70c951b9",
        }
        for key, value in expected.items():
            if manifest.get(key) != value:
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
    full_store_max_raw = connection.execute("SELECT MAX(ZDATETIME) FROM ZTRADE").fetchone()[0]
    connection.close()
    full_store_max_date = yyyymmdd(apple_date(float(full_store_max_raw)))
    through_date = parse_yyyymmdd(full["through"])
    if full_store_max_date > yyyymmdd(through_date) or (through_date - parse_yyyymmdd(full_store_max_date)).days > 7:
        raise ValueError(f"full-period store cutoff mismatch: {full_store_max_date} versus {full['through']}")
    identity.update(
        {
            "sampleID": fixed["sampleID"],
            "dataRuleVersion": fixed["dataRuleVersion"],
            "ruleVersion": fixed["ruleVersion"],
            "ruleCommit": fixed["ruleCommit"],
            "through": fixed["through"],
            "fullStoreMaxTradeDate": full_store_max_date,
        }
    )
    return identity


def split_cycles(rows: list[dict], inventory_key: str, sold_key: str) -> list[tuple[tuple, int, list[dict]]]:
    grouped: dict[tuple, list[dict]] = defaultdict(list)
    for row in rows:
        grouped[row["path_key"]].append(row)
    cycles: list[tuple[tuple, int, list[dict]]] = []
    for path_key, path_rows in grouped.items():
        current: list[dict] = []
        cycle_number = 0
        for row in path_rows:
            if float(row[inventory_key]) <= 0 and not row[sold_key]:
                if current:
                    cycle_number += 1
                    cycles.append((path_key, cycle_number, current))
                    current = []
                continue
            current.append(row)
            if row[sold_key]:
                cycle_number += 1
                cycles.append((path_key, cycle_number, current))
                current = []
        if current:
            cycle_number += 1
            cycles.append((path_key, cycle_number, current))
    return cycles


def fixed_data(path: Path) -> tuple[list[dict], dict[tuple, list[int]], dict[tuple, list[int]]]:
    connection = connect_readonly(path)
    rows = []
    for row in connection.execute(
        """
        SELECT d.*,w.start_date,w.end_date,g.decision_score grade_efficiency_score,
               GROUP_CONCAT(DISTINCT x.rule_id) passed_gates
        FROM decision_event_lookup d
        JOIN windows w USING(window_id)
        LEFT JOIN decision_events g ON g.window_id=d.window_id AND g.stock_key=d.stock_key
            AND g.trade_date=d.trade_date AND g.phase=0
        LEFT JOIN event_gate_lookup x ON x.event_id=d.event_id
        WHERE d.phase=3
        GROUP BY d.event_id
        ORDER BY d.window_id,d.stock_key,d.trade_date
        """
    ):
        value = dict(row)
        value["path_key"] = (int(row["window_id"]), int(row["stock_key"]))
        value["sold"] = row["executed_action"] == "SELL"
        value["inventory"] = float(row["inventory_before"])
        rows.append(value)
    dates: dict[tuple, list[int]] = defaultdict(list)
    for row in connection.execute(
        "SELECT DISTINCT window_id,stock_key,trade_date FROM decision_events ORDER BY window_id,stock_key,trade_date"
    ):
        dates[(int(row["window_id"]), int(row["stock_key"]))].append(int(row["trade_date"]))
    adds: dict[tuple, list[int]] = defaultdict(list)
    for row in connection.execute(
        "SELECT window_id,stock_key,trade_date FROM decision_events WHERE phase=4 AND executed_action='ADD' ORDER BY window_id,stock_key,trade_date"
    ):
        adds[(int(row["window_id"]), int(row["stock_key"]))].append(int(row["trade_date"]))
    connection.close()
    return rows, dates, adds


def fixed_reason(row: dict, recent_add: bool) -> tuple[str, dict]:
    grade = int(row["grade"])
    days = float(row["holding_days_before"])
    roi = float(row["unit_roi_before"])
    want_s = float(row["decision_score"])
    score_threshold = 1.0 if grade >= 0 and days < 400 else 2.0
    score_gate = want_s >= score_threshold
    roi_threshold = -20.0 if grade in (-1, 1) else -17.5
    gates = {value for value in str(row.get("passed_gates") or "").split(",") if value}
    st02e = grade != 0 and days > 90 and roi > roi_threshold and score_gate
    st02g = grade >= 2 and days > 120 and roi <= roi_threshold and score_gate
    if st02g or "S-T02g" in gates:
        raise ValueError(f"S-T02g-qualified event unexpectedly held: {row}")
    if not score_gate:
        reason = "sell_votes_insufficient"
    elif ("S-T02" in gates or "S-T02e" in gates or st02e) and recent_add:
        reason = "recent_add_cooldown"
    elif grade == 0:
        reason = "grade_none"
    elif roi <= roi_threshold and grade < 2:
        reason = "deep_loss_grade_below_high"
    elif st02e or "S-T02" in gates or "S-T02e" in gates:
        raise ValueError(
            f"qualified non-cooldown event unexpectedly held: recent_add={recent_add}, row={row}"
        )
    else:
        reason = "other_exit_qualification"
    return reason, {
        "sell_score_threshold": score_threshold,
        "sell_score_gap": want_s - score_threshold,
        "st02e_roi_threshold": roi_threshold,
        "score_gate_passed": int(score_gate),
        "st02e_qualified": int(st02e),
        "passed_gates": "|".join(sorted(gates)),
    }


def liquidation_metrics(row: dict, source: str) -> tuple[float, float, float]:
    if source == "fixed":
        quantity = float(row["inventory_before"])
        cost = float(row["unit_cost_before"])
        roi = hypothetical_realized_roi(cost, float(row["unit_roi_before"]), quantity)
        invested_wan = cost * quantity * 1000.0 / 10000.0
        days = float(row["holding_days_before"])
    else:
        quantity = float(row["quantity"])
        cost = float(row["unit_cost"])
        roi = float(row["actual_roi"]) if row["sold"] else hypothetical_realized_roi(cost, float(row["market_roi"]), quantity)
        invested_wan = float(row["invested_cost"]) / 10000.0
        days = float(row["holding_days"])
    return roi, round_score(roi, days), invested_wan


def horizon_values(cycle: list[dict], checkpoint_index: int, source: str) -> dict:
    checkpoint = cycle[checkpoint_index]
    checkpoint_roi, checkpoint_score, checkpoint_invested = liquidation_metrics(checkpoint, source)
    result: dict[str, object] = {
        "checkpoint_realized_roi": checkpoint_roi,
        "checkpoint_round_score": checkpoint_score,
        "checkpoint_invested_wan": checkpoint_invested,
    }
    future = cycle[checkpoint_index + 1 :]
    exit_offset = next((offset for offset, row in enumerate(future, 1) if row["sold"]), None)
    for horizon in HORIZONS:
        if exit_offset is not None and exit_offset <= horizon:
            offset = exit_offset
            endpoint = future[offset - 1]
            complete = True
            exited = True
        elif len(future) >= horizon:
            offset = horizon
            endpoint = future[offset - 1]
            complete = True
            exited = False
        else:
            result.update(
                {
                    f"complete_{horizon}": 0,
                    f"exit_within_{horizon}": None,
                    f"roi_{horizon}": None,
                    f"roi_delta_{horizon}": None,
                    f"round_score_{horizon}": None,
                    f"score_delta_{horizon}": None,
                    f"score_improved_{horizon}": None,
                    f"future_add_{horizon}": None,
                    f"peak_invested_wan_{horizon}": None,
                    f"capital_trading_day_wan_{horizon}": None,
                }
            )
            continue
        selected = future[:offset]
        roi, score_value, _ = liquidation_metrics(endpoint, source)
        invested = [liquidation_metrics(row, source)[2] for row in selected if not row["sold"]]
        future_add = any(row.get("added", False) for row in selected)
        result.update(
            {
                f"complete_{horizon}": 1,
                f"exit_within_{horizon}": int(exited),
                f"roi_{horizon}": roi,
                f"roi_delta_{horizon}": roi - checkpoint_roi,
                f"round_score_{horizon}": score_value,
                f"score_delta_{horizon}": score_value - checkpoint_score,
                f"score_improved_{horizon}": int(score_value > checkpoint_score),
                f"future_add_{horizon}": int(future_add),
                f"peak_invested_wan_{horizon}": max(invested, default=0.0),
                f"capital_trading_day_wan_{horizon}": sum(invested),
            }
        )
    if exit_offset is not None:
        endpoint = future[exit_offset - 1]
        actual_roi, actual_score, _ = liquidation_metrics(endpoint, source)
        selected = future[:exit_offset]
        actual_exit = 1
    else:
        endpoint = cycle[-1]
        actual_roi, actual_score, _ = liquidation_metrics(endpoint, source)
        selected = cycle[checkpoint_index + 1 :]
        actual_exit = 0
    invested = [liquidation_metrics(row, source)[2] for row in selected if not row["sold"]]
    result.update(
        {
            "actual_exit": actual_exit,
            "outcome_date": endpoint["trade_date"],
            "trading_days_to_outcome": exit_offset if exit_offset is not None else len(selected),
            "outcome_realized_roi": actual_roi,
            "outcome_round_score": actual_score,
            "outcome_roi_delta": actual_roi - checkpoint_roi,
            "outcome_score_delta": actual_score - checkpoint_score,
            "outcome_score_improved": int(actual_score > checkpoint_score),
            "outcome_future_add": int(any(row.get("added", False) for row in selected)),
            "outcome_peak_invested_wan": max(invested, default=0.0),
            "outcome_capital_trading_day_wan": sum(invested),
        }
    )
    return result


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
        # `hasNoInvestment(inPreviousTradingDays: 60)` still includes the
        # investment exactly 60 trading-date steps earlier; eligibility opens
        # on the following trading day.
        recent_add = since_add is not None and since_add <= 60
        reason, reason_details = fixed_reason(row, recent_add)
        for item in cycle:
            item["added"] = int(item["trade_date"]) in adds.get(path_key, [])
        record = {
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
            "blocker": reason,
        } | reason_details | horizon_values(cycle, checkpoint_index, "fixed")
        records.append(record)
    return records


def grade_efficiency_from_store(row: dict) -> float:
    current = parse_yyyymmdd(row["trade_date"])
    start = parse_yyyymmdd(row["start_date"])
    years = max((current - start).days / 365.0, 1.0)
    roi = float(row["roll_roi"]) / years
    rounds = float(row["roll_rounds"])
    roll_days = float(row["roll_days"])
    holding_days = float(row["holding_days"])
    inventory = float(row["quantity"])
    if rounds <= 1:
        days = roll_days
    else:
        previous_rounds = rounds - (1 if inventory > 0 else 0)
        previous_days = (roll_days - (holding_days if inventory > 0 else 0)) / previous_rounds
        days = roll_days / rounds if holding_days > previous_days else previous_days
    if days <= 0:
        return 0.0
    return roi * 100.0 / days if roi >= 0 else roi * days / 100.0


def full_rows(path: Path, through: str) -> list[dict]:
    connection = connect_readonly(path)
    store_max_raw = connection.execute("SELECT MAX(ZDATETIME) FROM ZTRADE").fetchone()[0]
    store_max_date = yyyymmdd(apple_date(float(store_max_raw)))
    through_date = parse_yyyymmdd(through)
    if parse_yyyymmdd(store_max_date) > through_date or (through_date - parse_yyyymmdd(store_max_date)).days > 7:
        connection.close()
        raise ValueError(f"full-period store cutoff mismatch: {store_max_date} versus {through}")
    rows: list[dict] = []
    for row in connection.execute(
        """
        SELECT s.ZSID stock_id,s.ZSNAME stock_name,s.ZDATESTART start_raw,
               t.ZDATETIME trade_raw,t.ZSIMQTYINVENTORY quantity,t.ZSIMQTYSELL sold_quantity,
               t.ZSIMUNITCOST unit_cost,t.ZSIMUNITROI market_roi,t.ZSIMDAYS holding_days,
               t.ZSIMAMTCOST invested_cost,t.ZSIMAMTROI actual_roi,
               t.ZSIMINVESTADDED added_count,t.ZROLLAMTROI roll_roi,
               t.ZROLLDAYS roll_days,t.ZROLLROUNDS roll_rounds
        FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK=t.ZSTOCK
        WHERE t.ZSIMQTYINVENTORY>0 OR t.ZSIMQTYSELL>0
        ORDER BY s.ZSID,t.ZDATETIME
        """
    ):
        trade_date = yyyymmdd(apple_date(float(row["trade_raw"])))
        if parse_yyyymmdd(trade_date) > parse_yyyymmdd(through):
            continue
        value = dict(row)
        value.update(
            {
                "path_key": (row["stock_id"],),
                "trade_date": trade_date,
                "start_date": yyyymmdd(apple_date(float(row["start_raw"]))),
                "sold": float(row["sold_quantity"]) > 0,
                "inventory": float(row["quantity"]),
                "quantity": float(row["sold_quantity"]) if float(row["sold_quantity"]) > 0 else float(row["quantity"]),
                "added": float(row["added_count"]) > 0,
            }
        )
        rows.append(value)
    connection.close()
    return rows


def build_full(path: Path, through: str) -> list[dict]:
    rows = full_rows(path, through)
    records: list[dict] = []
    for _, cycle_number, cycle in split_cycles(rows, "inventory", "sold"):
        checkpoint_index = next(
            (
                index
                for index, row in enumerate(cycle)
                if float(row["holding_days"]) > 120 and float(row["market_roi"]) < 0 and not row["sold"]
            ),
            None,
        )
        if checkpoint_index is None:
            continue
        row = cycle[checkpoint_index]
        records.append(
            {
                "source": "full",
                "window_start": 20170722,
                "window_end": 20260722,
                "stock_id": row["stock_id"],
                "stock_name": row["stock_name"],
                "cycle_number": cycle_number,
                "trade_date": row["trade_date"],
                "holding_days": float(row["holding_days"]),
                "market_roi": float(row["market_roi"]),
                "grade_efficiency_score": grade_efficiency_from_store(row),
            }
            | horizon_values(cycle, checkpoint_index, "full")
        )
    return records


def horizon_summary(rows: list[dict], label: str) -> dict:
    result: dict[str, object] = {
        "label": label,
        "events": len(rows),
        "stocks": len({row["stock_id"] for row in rows}),
        "windows": len({row["window_start"] for row in rows}),
        "actualExitRate": rate(rows, "actual_exit"),
        "outcomeScoreImprovedRate": rate(rows, "outcome_score_improved"),
        "outcomeMedianROIDelta": median(rows, "outcome_roi_delta"),
        "outcomeMedianScoreDelta": median(rows, "outcome_score_delta"),
        "outcomeMedianTradingDays": median(rows, "trading_days_to_outcome"),
        "outcomeMedianCapitalTradingDayWan": median(rows, "outcome_capital_trading_day_wan"),
    }
    for horizon in HORIZONS:
        complete = [row for row in rows if row.get(f"complete_{horizon}") == 1]
        result[f"h{horizon}"] = {
            "complete": len(complete),
            "scoreImprovedRate": rate(complete, f"score_improved_{horizon}"),
            "medianROIDelta": median(complete, f"roi_delta_{horizon}"),
            "medianScoreDelta": median(complete, f"score_delta_{horizon}"),
            "exitRate": rate(complete, f"exit_within_{horizon}"),
            "futureAddRate": rate(complete, f"future_add_{horizon}"),
            "medianCapitalTradingDayWan": median(complete, f"capital_trading_day_wan_{horizon}"),
        }
    return result


def fmt(value: float | None, digits: int = 3) -> str:
    return "—" if value is None else f"{value:.{digits}f}"


def main() -> None:
    args = arguments()
    args.output.mkdir(parents=True, exist_ok=True)
    identity = verify_identity(args)
    fixed = build_fixed(args.decision_db)
    full = build_full(args.full_store, identity["through"])
    write_csv(args.output / "fixed-events.csv", fixed)
    write_csv(args.output / "full-events.csv", full)

    reason_groups: dict[str, list[dict]] = defaultdict(list)
    for row in fixed:
        reason_groups[row["blocker"]].append(row)
    reason_summaries = [horizon_summary(rows, reason) for reason, rows in sorted(reason_groups.items())]
    write_csv(
        args.output / "reason-summary.csv",
        [
            {
                "blocker": item["label"], "events": item["events"], "stocks": item["stocks"],
                "windows": item["windows"], "outcome_score_improved_rate": item["outcomeScoreImprovedRate"],
                "outcome_median_roi_delta": item["outcomeMedianROIDelta"],
                "outcome_median_score_delta": item["outcomeMedianScoreDelta"],
                **{
                    f"h{horizon}_complete": item[f"h{horizon}"]["complete"]
                    for horizon in HORIZONS
                },
                **{
                    f"h{horizon}_score_improved_rate": item[f"h{horizon}"]["scoreImprovedRate"]
                    for horizon in HORIZONS
                },
                **{
                    f"h{horizon}_median_score_delta": item[f"h{horizon}"]["medianScoreDelta"]
                    for horizon in HORIZONS
                },
            }
            for item in reason_summaries
        ],
    )
    fixed_summary = horizon_summary(fixed, "fixed")
    full_summary = horizon_summary(full, "full")
    # `.none` is only a diagnostic blocker, never a proposed strategy trigger.
    # The reusable signal is the continuous efficiency score that exists before
    # categorical Grade activation, together with the ordinary sell-vote gate
    # and the existing investment cooldown.
    score_fallback = [
        row for row in fixed
        if row["blocker"] == "grade_none"
        and float(row["grade_efficiency_score"]) < -10
        and row["score_gate_passed"] == 1
        and row["recent_add_60"] == 0
    ]
    score_fallback_summary = horizon_summary(score_fallback, "continuous_score_lt_m10")
    repeated_blockers = [item for item in reason_summaries if item["stocks"] >= 2 and item["windows"] >= 2]
    candidate_signals = []
    if (
        score_fallback_summary["events"] >= 3
        and score_fallback_summary["stocks"] >= 2
        and score_fallback_summary["windows"] >= 2
        and all(
            score_fallback_summary[f"h{horizon}"]["complete"] >= 3
            and (score_fallback_summary[f"h{horizon}"]["medianScoreDelta"] or 0) < 0
            and (score_fallback_summary[f"h{horizon}"]["scoreImprovedRate"] or 0) < 0.5
            for horizon in (60, 120)
        )
    ):
        candidate_signals.append("continuous_score_lt_m10_with_sell_votes_and_cooldown")
    summary = {
        "studyID": "E-CAP03-D0-E",
        "identity": identity,
        "definition": "first held SELL decision after 120 days with negative current ROI in each holding cycle",
        "fixed": fixed_summary,
        "full": full_summary,
        "byBlocker": reason_summaries,
        "continuousScoreFallback": score_fallback_summary,
        "repeatedBlockers": [item["label"] for item in repeated_blockers],
        "candidateSignals": candidate_signals,
    }
    (args.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    lines = [
        "# E-CAP03-D0-E 長期負分持股與資金占用診斷", "",
        f"- DecisionBase：`{identity['decisionBaseID']}`。",
        f"- 固定／全期間：`{identity['fixedRunID']}`／`{identity['fullRunID']}`。",
        f"- Sample／資料／策略：`{identity['sampleID']}`／`{identity['dataRuleVersion']}`／`{identity['ruleVersion']}`。",
        f"- 截止日：`{identity['through']}`（store 最後交易日 `{identity['fullStoreMaxTradeDate']}`）；固定窗口案例 {len(fixed)}，全期間案例 {len(full)}。", "",
        "## 固定窗口阻礙", "",
    ]
    for item in reason_summaries:
        lines.append(
            f"- `{item['label']}`：{item['events']} 件、{item['stocks']} 檔、{item['windows']} 窗口；"
            f"20／60／120 日分數改善率 "
            f"{fmt(item['h20']['scoreImprovedRate'])}／{fmt(item['h60']['scoreImprovedRate'])}／{fmt(item['h120']['scoreImprovedRate'])}；"
            f"期末分數變化中位 {fmt(item['outcomeMedianScoreDelta'])}。"
        )
    lines.extend(["", "## 整體等待結果", ""])
    for item in (fixed_summary, full_summary):
        lines.append(
            f"- `{item['label']}`：{item['events']} 件、{item['stocks']} 檔、{item['windows']} 窗口；"
            f"20／60／120 日 ROI 變化中位 "
            f"{fmt(item['h20']['medianROIDelta'])}／{fmt(item['h60']['medianROIDelta'])}／{fmt(item['h120']['medianROIDelta'])}；"
            f"分數變化中位 {fmt(item['h20']['medianScoreDelta'])}／{fmt(item['h60']['medianScoreDelta'])}／{fmt(item['h120']['medianScoreDelta'])}；"
            f"期末分數改善率 {fmt(item['outcomeScoreImprovedRate'])}。"
        )
    lines.extend(
        [
            "", "## 連續效率分數分支", "",
            f"- `.none` 只作阻礙診斷，不作候選條件。既有賣出票已足、沒有最近 60 個交易日加碼，"
            f"且連續效率分數 `< -10` 的子群共有 {score_fallback_summary['events']} 件、"
            f"{score_fallback_summary['stocks']} 檔、{score_fallback_summary['windows']} 窗口。",
            f"- 20／60／120 日分數變化中位為 "
            f"{fmt(score_fallback_summary['h20']['medianScoreDelta'])}／"
            f"{fmt(score_fallback_summary['h60']['medianScoreDelta'])}／"
            f"{fmt(score_fallback_summary['h120']['medianScoreDelta'])}；"
            f"60／120 日分數改善率均為 "
            f"{fmt(score_fallback_summary['h60']['scoreImprovedRate'])}／"
            f"{fmt(score_fallback_summary['h120']['scoreImprovedRate'])}。",
            f"- 20／60／120 日資金占用中位為 "
            f"{fmt(score_fallback_summary['h20']['medianCapitalTradingDayWan'])}／"
            f"{fmt(score_fallback_summary['h60']['medianCapitalTradingDayWan'])}／"
            f"{fmt(score_fallback_summary['h120']['medianCapitalTradingDayWan'])} 萬元·交易日。",
        ]
    )
    lines.extend(
        [
            "", "## 停止條件", "",
            f"- 跨至少 2 檔、2 窗口的重複阻礙：{', '.join(summary['repeatedBlockers']) or '無'}。",
            f"- 同時呈現多個等待區間分數惡化的候選訊號：{', '.join(candidate_signals) or '無'}。",
            "- 後續 ROI 與分數只作候選生成證據；沒有完整反事實重播，不等同候選績效。",
        ]
    )
    (args.output / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
