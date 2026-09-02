#!/usr/bin/env python3
"""Build the offline MKT-R02-I01 market-phenomenon vote inventory."""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import math
import os
import shutil
import sqlite3
import tempfile
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable, Sequence

import market_data_pool as pool
import market_snapshot_reuse as reuse


ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af"
RB01 = ROOT / "exports/future-path-study/fwd-v20-rb01-t2s39-20260902"
OUTPUT_ROOT = ROOT / "exports/market-data/taiex/research"
STUDY_ID = "MKT-R02-I01"
TOOL_VERSION = "market-vote-phenomenon-inventory-v1"
EXPECTED_RULE_COMMIT = "48d42e50ada5dcc0ed2e22dffff6871323daf8b7"
WINDOWS = (
    (1, 20170722, 20200722),
    (2, 20200722, 20230722),
    (3, 20230722, 20260722),
)
DECISION_BASES = {
    "A": "a-abcd9-v2-s32-an03-wow-nonbottom-no-ap02-add-penalty-20260901-t2-s39-48d42e50ada5-fixed3y-20260722-v6",
    "B": "b-abcd9-v2-s32-an03-wow-nonbottom-no-ap02-add-penalty-20260901-t2-s39-48d42e50ada5-fixed3y-20260722-v6",
    "C": "c-abcd9-v2-s32-an03-wow-nonbottom-no-ap02-add-penalty-20260901-t2-s39-48d42e50ada5-fixed3y-20260722-v6",
    "D": "d-abcd9-v2-s32-an03-wow-nonbottom-no-ap02-add-penalty-20260901-t2-s39-48d42e50ada5-fixed3y-20260722-v6",
    "E": "e-abcde9-v2-s32-an03-wow-nonbottom-no-ap02-add-penalty-20260901-t2-s39-48d42e50ada5-fixed3y-20260722-v6",
}
PHASES = {1: "H_BUY", 2: "L_BUY", 3: "SELL", 4: "ADD"}
MIN_MARKET_DATES_PER_WINDOW = 30
MIN_PIVOTAL_DATES_PER_WINDOW = 10
QUANTILES = (("q10", 0.10), ("q25", 0.25), ("q50", 0.50), ("q75", 0.75), ("q90", 0.90))
NORMALIZED_UNITS = {"%", "標準分數", "交易日", "無單位"}
EXTREME_SPECS = (
    ("market_high_is_max_9", "high", "market_high_max_9", "high"),
    ("market_low_is_min_9", "low", "market_low_min_9", "low"),
    ("market_kd_k_is_max_9", "market_kd_k", "market_kd_k_max_9", "high"),
    ("market_kd_k_is_min_9", "market_kd_k", "market_kd_k_min_9", "low"),
    ("market_osc_is_max_9", "market_osc", "market_osc_max_9", "high"),
    ("market_osc_is_min_9", "market_osc", "market_osc_min_9", "low"),
    ("market_volume_is_max_9", "volume_lots", "market_volume_max_9", "high"),
    ("market_volume_is_min_9", "volume_lots", "market_volume_min_9", "low"),
    ("market_value_is_max_9", "trade_value", "market_value_max_9", "high"),
    ("market_value_is_min_9", "trade_value", "market_value_min_9", "low"),
    ("market_transaction_is_max_9", "transaction_count", "market_transaction_max_9", "high"),
    ("market_transaction_is_min_9", "transaction_count", "market_transaction_min_9", "low"),
)
STRUCTURAL_PRICE_FIELD_PAIRS = (
    ("market_kd_k", "market_kd_d"),
    ("market_ma_20_diff", "market_ma_60_diff"),
    ("market_ma_20_diff_z_125", "market_ma_60_diff_z_125"),
    ("market_ma_20_diff_z_250", "market_ma_60_diff_z_250"),
    ("market_high_diff_z_125", "market_low_diff_z_125"),
    ("market_high_diff_z_250", "market_low_diff_z_250"),
    ("market_osc_z_125", "market_kd_j_z_125"),
    ("market_osc_z_250", "market_kd_j_z_250"),
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise pool.MarketDataError(message)


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def csv_bytes(rows: Iterable[dict[str, Any]], fields: Sequence[str]) -> bytes:
    buffer = io.StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=fields, extrasaction="ignore", lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return buffer.getvalue().encode()


def json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def percentile(values: Sequence[float], probability: float) -> float:
    require(bool(values), "percentile input is empty")
    ordered = sorted(values)
    position = (len(ordered) - 1) * probability
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1 - fraction) + ordered[upper] * fraction


def window_for(date: int) -> int | None:
    if WINDOWS[0][1] <= date < WINDOWS[0][2]:
        return 1
    if WINDOWS[1][1] <= date < WINDOWS[1][2]:
        return 2
    if WINDOWS[2][1] <= date <= WINDOWS[2][2]:
        return 3
    return None


def fixed_anchors(field: str, unit: str) -> list[tuple[str, float]]:
    anchors: list[tuple[str, float]] = []
    if unit in {"%", "標準分數", "交易日"}:
        anchors.append(("zero", 0.0))
    if field in {"market_kd_k", "market_kd_d", "market_kd_j"}:
        anchors.extend((f"fixed-{value}", float(value)) for value in (20, 50, 80))
    return anchors


def is_companion_field(field: str) -> bool:
    return field.endswith("_max_9") or field.endswith("_min_9")


def classify_field(row: dict[str, str]) -> dict[str, Any]:
    field = row["field"]
    companion = is_companion_field(field)
    level_allowed = row["unit"] in NORMALIZED_UNITS and not companion
    change_allowed = not companion
    if companion:
        role = "extreme-comparison-only"
        reason = "九日極值伴隨欄只用來和當日值比較，不直接對其水準或變化設規則"
    elif level_allowed:
        role = "level-and-change"
        reason = "尺度可跨窗口解讀；允許 W1 分位水準與一日方向"
    else:
        role = "change-only"
        reason = "絕對指數點或市場活動規模會隨年代漂移；只允許上升／下降方向"
    return {
        **row,
        "candidate_role": role,
        "level_allowed": level_allowed,
        "change_allowed": change_allowed,
        "standalone_allowed": row["category"] == "price",
        "pair_role": "price-state" if row["category"] == "price" else "activity-qualifier",
        "reason": reason,
    }


def load_market(snapshot: Path) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    manifest = reuse.verify_mt_snapshot(snapshot)
    catalog = [classify_field(row) for row in read_csv(snapshot / "field-catalog.csv")]
    daily = {row["date"]: row for row in read_csv(snapshot / "market-daily.csv")}
    technical = read_csv(snapshot / "market-technical.csv")
    require(len(catalog) == 101, f"expected 101 MT1 fields, got {len(catalog)}")
    rows: list[dict[str, Any]] = []
    for technical_row in technical:
        date_text = technical_row["date"]
        date = int(date_text.replace("-", ""))
        window = window_for(date)
        if window is None:
            continue
        require(date_text in daily, f"market daily row missing for {date_text}")
        combined: dict[str, Any] = {"date": date, "window_id": window}
        for key, value in technical_row.items():
            if key == "date":
                continue
            if value in {"true", "false"}:
                combined[key] = value == "true"
            else:
                combined[key] = float(value)
        for key in ("high", "low", "volume_lots", "trade_value", "transaction_count"):
            combined[key] = float(daily[date_text][key])
        rows.append(combined)
    require(rows and len({row["date"] for row in rows}) == len(rows), "market dates are empty or duplicated")
    return rows, catalog, manifest


def trigger_mask(dates: Sequence[int], predicate: Any) -> int:
    mask = 0
    for index, date in enumerate(dates):
        if predicate(index):
            mask |= 1 << index
    return mask


def build_atoms(market_rows: list[dict[str, Any]], catalog: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], dict[int, int]]:
    dates = [row["date"] for row in market_rows]
    date_index = {date: index for index, date in enumerate(dates)}
    window_masks = {
        window: sum(1 << index for index, row in enumerate(market_rows) if row["window_id"] == window)
        for window in (1, 2, 3)
    }
    first_window = [row for row in market_rows if row["window_id"] == 1]
    atoms: list[dict[str, Any]] = []

    def add_atom(atom_id: str, field: str, category: str, kind: str, orientation: str,
                 condition: str, mask: int, threshold_source: str = "", threshold: float | None = None) -> None:
        counts = {window: (mask & window_masks[window]).bit_count() for window in (1, 2, 3)}
        atoms.append({
            "atom_id": atom_id,
            "source_field": field,
            "category": category,
            "kind": kind,
            "orientation": orientation,
            "condition": condition,
            "threshold_source": threshold_source,
            "threshold": "" if threshold is None else repr(float(threshold)),
            "dates_w1": counts[1],
            "dates_w2": counts[2],
            "dates_w3": counts[3],
            "market_coverage_passed": all(value >= MIN_MARKET_DATES_PER_WINDOW for value in counts.values()),
            "mask": mask,
        })

    for field_row in catalog:
        field = field_row["field"]
        category = field_row["category"]
        if field_row["level_allowed"]:
            source_values = [float(row[field]) for row in first_window]
            thresholds: list[tuple[str, float]] = fixed_anchors(field, field_row["unit"])
            thresholds.extend((name, percentile(source_values, probability)) for name, probability in QUANTILES)
            seen: set[tuple[str, float]] = set()
            for source, threshold in thresholds:
                for operator, orientation in (("le", "low"), ("ge", "high")):
                    key = (operator, round(threshold, 12))
                    if key in seen:
                        continue
                    seen.add(key)
                    if operator == "le":
                        mask = trigger_mask(dates, lambda index, f=field, t=threshold: float(market_rows[index][f]) <= t)
                        symbol = "<="
                    else:
                        mask = trigger_mask(dates, lambda index, f=field, t=threshold: float(market_rows[index][f]) >= t)
                        symbol = ">="
                    add_atom(f"level:{field}:{source}:{operator}", field, category, "level", orientation,
                             f"{field} {symbol} {threshold:.12g}", mask, source, threshold)
            for source, threshold in fixed_anchors(field, field_row["unit"]):
                up_mask = trigger_mask(
                    dates,
                    lambda index, f=field, t=threshold: index > 0
                    and float(market_rows[index - 1][f]) <= t < float(market_rows[index][f]),
                )
                down_mask = trigger_mask(
                    dates,
                    lambda index, f=field, t=threshold: index > 0
                    and float(market_rows[index - 1][f]) >= t > float(market_rows[index][f]),
                )
                add_atom(f"cross:{field}:{source}:up", field, category, "cross", "up",
                         f"{field} crosses upward through {threshold:.12g}", up_mask, source, threshold)
                add_atom(f"cross:{field}:{source}:down", field, category, "cross", "down",
                         f"{field} crosses downward through {threshold:.12g}", down_mask, source, threshold)
        if field_row["change_allowed"]:
            up_mask = trigger_mask(
                dates,
                lambda index, f=field: index > 0 and float(market_rows[index][f]) > float(market_rows[index - 1][f]),
            )
            down_mask = trigger_mask(
                dates,
                lambda index, f=field: index > 0 and float(market_rows[index][f]) < float(market_rows[index - 1][f]),
            )
            add_atom(f"change:{field}:up", field, category, "one-day-change", "up",
                     f"{field}(t) > {field}(t-1)", up_mask)
            add_atom(f"change:{field}:down", field, category, "one-day-change", "down",
                     f"{field}(t) < {field}(t-1)", down_mask)

    catalog_by_field = {row["field"]: row for row in catalog}
    for atom_id, current_field, companion_field, orientation in EXTREME_SPECS:
        category = "price" if companion_field.startswith(("market_high", "market_low", "market_kd", "market_osc")) else "market_activity"
        require(companion_field in catalog_by_field, f"missing extreme companion {companion_field}")
        mask = trigger_mask(
            dates,
            lambda index, current=current_field, companion=companion_field:
            float(market_rows[index][current]) == float(market_rows[index][companion]),
        )
        add_atom(f"extreme:{atom_id}", companion_field, category, "nine-day-extreme", orientation,
                 f"{current_field} == {companion_field}", mask)

    signatures: dict[int, str] = {}
    for atom in sorted(atoms, key=lambda item: item["atom_id"]):
        mask = int(atom["mask"])
        canonical = signatures.setdefault(mask, atom["atom_id"])
        atom["canonical_atom_id"] = canonical
        atom["is_canonical"] = canonical == atom["atom_id"]
    return atoms, date_index


def verify_decision_bases() -> tuple[list[dict[str, Any]], dict[tuple[str, str, int], int], dict[str, Any]]:
    coverage: list[dict[str, Any]] = []
    pivot_dates: dict[tuple[str, str, int], set[int]] = defaultdict(set)
    manifests: dict[str, Any] = {}
    rule_hashes: set[str] = set()
    all_market_dates: set[int] = set()
    for sample, base_id in DECISION_BASES.items():
        directory = ROOT / "exports/backtest-decision-bases" / base_id
        manifest_bytes = (directory / "manifest.json").read_bytes()
        manifest = json.loads(manifest_bytes)
        require(manifest["decisionBaseID"] == base_id, f"decision base id mismatch for {sample}")
        require(manifest["ruleCommit"] == EXPECTED_RULE_COMMIT, f"rule commit mismatch for {sample}")
        require((directory / ".complete").read_text().strip() == base_id, f"completion marker mismatch for {sample}")
        require((directory / ".p4b-complete").read_text().strip() == base_id, f"P4b marker mismatch for {sample}")
        rule_hash = pool.sha256((directory / "rule-catalog.json").read_bytes())
        rule_hashes.add(rule_hash)
        database = directory / "decisions.sqlite"
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        connection.row_factory = sqlite3.Row
        try:
            require(connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok", f"SQLite integrity failed for {sample}")
            for window in (1, 2, 3):
                for phase_number, phase in PHASES.items():
                    rows = connection.execute(
                        """SELECT trade_date, decision_score, decision_threshold,
                                  planned_action, executed_action, stock_key
                           FROM decision_events
                           WHERE window_id = ? AND phase = ?""",
                        (window, phase_number),
                    ).fetchall()
                    dates = {int(row["trade_date"]) for row in rows}
                    all_market_dates.update(dates)
                    planned = sum(row["planned_action"] not in ("NONE", "HOLD") for row in rows)
                    executed = sum(row["executed_action"] not in ("NONE", "HOLD") for row in rows)
                    support_events = 0
                    oppose_events = 0
                    support_dates: set[int] = set()
                    oppose_dates: set[int] = set()
                    exact_supported = phase_number in (1, 2)
                    if exact_supported:
                        action = "H" if phase_number == 1 else "L"
                        for row in rows:
                            score = float(row["decision_score"])
                            threshold = float(row["decision_threshold"])
                            if math.isclose(score, threshold - 1) and row["planned_action"] != action:
                                support_events += 1
                                support_dates.add(int(row["trade_date"]))
                            if math.isclose(score, threshold) and row["planned_action"] == action:
                                oppose_events += 1
                                oppose_dates.add(int(row["trade_date"]))
                        pivot_dates[(phase, "support", window)].update(support_dates)
                        pivot_dates[(phase, "oppose", window)].update(oppose_dates)
                    coverage.append({
                        "sample": sample,
                        "window_id": window,
                        "phase": phase,
                        "events": len(rows),
                        "unique_market_dates": len(dates),
                        "stock_count": len({int(row["stock_key"]) for row in rows}),
                        "planned_action_events": planned,
                        "executed_action_events": executed,
                        "exact_one_vote_pivotal_supported": exact_supported,
                        "support_pivotal_events": support_events if exact_supported else "",
                        "support_pivotal_dates": len(support_dates) if exact_supported else "",
                        "oppose_pivotal_events": oppose_events if exact_supported else "",
                        "oppose_pivotal_dates": len(oppose_dates) if exact_supported else "",
                    })
        finally:
            connection.close()
        manifests[sample] = {
            "decision_base_id": base_id,
            "manifest_sha256": pool.sha256(manifest_bytes),
            "decisions_sqlite_sha256": pool.sha256(database.read_bytes()),
            "rule_catalog_sha256": rule_hash,
        }
    require(len(rule_hashes) == 1, "current rule catalogs differ across samples")
    masks: dict[tuple[str, str, int], int] = {}
    sorted_dates = sorted(all_market_dates)
    date_to_bit = {date: index for index, date in enumerate(sorted_dates)}
    for key, dates in pivot_dates.items():
        masks[key] = sum(1 << date_to_bit[date] for date in dates)
    return coverage, masks, {"inputs": manifests, "all_event_dates": sorted_dates}


def reindex_mask(mask: int, source_dates: Sequence[int], target_dates: Sequence[int]) -> int:
    target_index = {date: index for index, date in enumerate(target_dates)}
    output = 0
    for source_index, date in enumerate(source_dates):
        destination = target_index.get(date)
        if destination is not None and mask & (1 << source_index):
            output |= 1 << destination
    return output


def summarize_candidates(
    atoms: list[dict[str, Any]],
    market_rows: list[dict[str, Any]],
    decision_pivot_masks: dict[tuple[str, str, int], int],
    decision_metadata: dict[str, Any],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    market_dates = [row["date"] for row in market_rows]
    decision_dates = decision_metadata["all_event_dates"]
    market_window_masks = {
        window: sum(1 << index for index, row in enumerate(market_rows) if row["window_id"] == window)
        for window in (1, 2, 3)
    }
    pivot_market_masks: dict[tuple[str, str, int], int] = {}
    for key, decision_mask in decision_pivot_masks.items():
        window = key[2]
        pivot_market_masks[key] = (
            reindex_mask(decision_mask, decision_dates, market_dates) & market_window_masks[window]
        )
    eligible_atoms = [
        atom for atom in atoms
        if atom["is_canonical"] and atom["market_coverage_passed"]
    ]
    action_rows: list[dict[str, Any]] = []
    action_ready_counts: dict[tuple[str, str], int] = defaultdict(int)
    for atom in eligible_atoms:
        if atom["category"] != "price":
            continue
        for phase in ("H_BUY", "L_BUY"):
            for direction in ("support", "oppose"):
                counts = []
                for window in (1, 2, 3):
                    pivot = pivot_market_masks.get((phase, direction, window), 0)
                    counts.append((int(atom["mask"]) & pivot).bit_count())
                passed = all(count >= MIN_PIVOTAL_DATES_PER_WINDOW for count in counts)
                if passed:
                    action_ready_counts[(phase, direction)] += 1
                action_rows.append({
                    "atom_id": atom["atom_id"],
                    "phase": phase,
                    "vote": "+1" if direction == "support" else "-1",
                    "direction": direction,
                    "pivotal_dates_w1": counts[0],
                    "pivotal_dates_w2": counts[1],
                    "pivotal_dates_w3": counts[2],
                    "action_coverage_passed": passed,
                })

    price_atoms = [atom for atom in eligible_atoms if atom["category"] == "price"]
    activity_atoms = [atom for atom in eligible_atoms if atom["category"] == "market_activity"]
    def qualified_pair_masks(pairs: Iterable[tuple[dict[str, Any], dict[str, Any]]]) -> set[int]:
        signatures: set[int] = set()
        for left, right in pairs:
            mask = int(left["mask"]) & int(right["mask"])
            if all((mask & market_window_masks[window]).bit_count() >= MIN_MARKET_DATES_PER_WINDOW for window in (1, 2, 3)):
                signatures.add(mask)
        return signatures

    price_activity_masks = qualified_pair_masks(
        (price, activity) for price in price_atoms for activity in activity_atoms
    )
    by_field: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for atom in price_atoms:
        by_field[str(atom["source_field"])].append(atom)
    structural_masks = qualified_pair_masks(
        (left, right)
        for left_field, right_field in STRUCTURAL_PRICE_FIELD_PAIRS
        for left in by_field.get(left_field, [])
        for right in by_field.get(right_field, [])
    )
    pair_sets = {
        "price-plus-activity": price_activity_masks,
        "structural-price-pair": structural_masks,
    }
    pair_rows: list[dict[str, Any]] = []
    pair_action_counts: dict[tuple[str, str], int] = defaultdict(int)
    for pair_kind, masks in pair_sets.items():
        pair_rows.append({
            "pair_kind": pair_kind,
            "phase": "CONDITION",
            "direction": "market-coverage",
            "condition_count": len(masks),
            "action_ready_count": "",
            "status": "two-atom trigger signatures with at least 30 market dates in every window",
        })
        for phase in ("H_BUY", "L_BUY"):
            for direction in ("support", "oppose"):
                ready = 0
                for market_mask in masks:
                    if all(
                        (market_mask & pivot_market_masks.get((phase, direction, window), 0)).bit_count()
                        >= MIN_PIVOTAL_DATES_PER_WINDOW
                        for window in (1, 2, 3)
                    ):
                        ready += 1
                pair_action_counts[(phase, direction)] += ready
                pair_rows.append({
                    "pair_kind": pair_kind,
                    "phase": phase,
                    "direction": direction,
                    "condition_count": len(masks),
                    "action_ready_count": ready,
                    "status": "coverage-only; no outcome or score ranking",
                })

    summary = {
        "atom_rows": len(atoms),
        "canonical_atom_rows": sum(bool(atom["is_canonical"]) for atom in atoms),
        "market_qualified_canonical_atoms": len(eligible_atoms),
        "standalone_price_atoms": len(price_atoms),
        "activity_qualifier_atoms": len(activity_atoms),
        "single_action_ready": {
            f"{phase}:{direction}": count for (phase, direction), count in sorted(action_ready_counts.items())
        },
        "pair_market_qualified_conditions": {key: len(value) for key, value in pair_sets.items()},
        "pair_action_ready": {
            f"{phase}:{direction}": count for (phase, direction), count in sorted(pair_action_counts.items())
        },
        "sell_add_single_upper_bound_each_direction": len(price_atoms),
        "sell_add_pair_upper_bound_each_direction": sum(len(value) for value in pair_sets.values()),
        "full_replay_not_authorized": True,
    }
    return action_rows, pair_rows, summary


def control_rows() -> tuple[list[dict[str, Any]], dict[str, Any]]:
    source = RB01 / "control-map.csv"
    controls = [row for row in read_csv(source) if row["classification"] == "G1"]
    require(len(controls) == 15, f"expected 15 frozen G1 controls, got {len(controls)}")
    rows = [
        {
            "control_id": "ZERO-FALSE",
            "kind": "zero-control",
            "phase": "ALL",
            "rule_id": "",
            "condition": "always false",
            "required_result": "0 changed votes, actions and period outcomes",
            "qualification_stage": "Q0",
        },
        {
            "control_id": "ZERO-IDENTITY",
            "kind": "zero-control",
            "phase": "ALL",
            "rule_id": "",
            "condition": "candidate path disabled",
            "required_result": "periods.csv bit-identical to Baseline v20",
            "qualification_stage": "Q0",
        },
    ]
    for control in controls:
        rows.append({
            "control_id": f"G1-{control['rule_id']}",
            "kind": "known-effective-rule-control",
            "phase": control["catalog_phase"],
            "rule_id": control["rule_id"],
            "condition": control["formal_condition"],
            "required_result": "generic strategy-efficiency method must recover condition shape and vote direction",
            "qualification_stage": "Q1",
        })
    return rows, {
        "source_sha256": pool.sha256(source.read_bytes()),
        "g1_count": len(controls),
        "q1_minimum_recovery": 10,
        "q1_phase_requirement": "each phase with at least 3 controls recovers at least 2 and at least half",
        "q1_pair_requirement": "at least 5 of 7 two-value G1 controls",
    }


def render_report(summary: dict[str, Any], decision_rows: list[dict[str, Any]], controls: dict[str, Any]) -> bytes:
    total_events = sum(int(row["events"]) for row in decision_rows)
    single = summary["single_action_ready"]
    pairs = summary["pair_action_ready"]
    pair_conditions = sum(summary["pair_market_qualified_conditions"].values())
    lines = [
        "# MKT-R02-I01 市場現象與投票候選目錄",
        "",
        "## 結論",
        "",
        f"- MT1 的 101 個欄位全部納入盤點；產生 {summary['atom_rows']:,} 個描述性原子，去除完全相同觸發後有 {summary['canonical_atom_rows']:,} 個，通過每個窗口至少 {MIN_MARKET_DATES_PER_WINDOW} 個不同市場日者有 {summary['market_qualified_canonical_atoms']:,} 個。",
        f"- 其中 {summary['standalone_price_atoms']:,} 個價格現象可單獨形成投票條件，{summary['activity_qualifier_atoms']:,} 個成交量／金額／筆數現象只作第二條確認條件，不單獨決定買賣。",
        f"- 五份 DecisionBase 共讀取 {total_events:,} 個 H／L／S／A 決策事件。H買與 L買有明確分數門檻，可精確辨識加減一票的局部動作翻轉；賣出與加碼受多個 gate 影響，DecisionBase 不能只靠分數安全推算，必須由 runner 實際重播。",
        f"- 單一現象通過每窗口至少 {MIN_PIVOTAL_DATES_PER_WINDOW} 個不同臨界市場日的 H買支持／反對候選為 {single.get('H_BUY:support', 0):,}／{single.get('H_BUY:oppose', 0):,}，L買為 {single.get('L_BUY:support', 0):,}／{single.get('L_BUY:oppose', 0):,}。",
        f"- 二現象語法限制為價格＋市場活動，或 8 組事前指定的同義技術結構；市場覆蓋合格且去除完全相同觸發後共有 {pair_conditions:,} 組。其 H買支持／反對候選為 {pairs.get('H_BUY:support', 0):,}／{pairs.get('H_BUY:oppose', 0):,}，L買為 {pairs.get('L_BUY:support', 0):,}／{pairs.get('L_BUY:oppose', 0):,}。",
        "- 即使只跑 H／L，直接把全部覆蓋合格組合逐一完整回測也不是合理的最低成本方案；I01 因此只凍結候選語法與容量，不依未來漲跌或 Baseline 分數排名，也不生成正式候選。",
        "",
        "## 凍結語法",
        "",
        "- 規則只使用決策當日及以前資料，形式固定為 `一個市場現象 [AND 第二個市場現象] → 指定 phase +1 或 -1`。",
        "- 正規化百分比、Z、趨勢日數及 K／D／J 可用 W1 的 10／25／50／75／90 分位水準；具自然中心者另保留 0，K／D／J 另保留 20／50／80。W2、W3 不重估門檻。",
        "- 所有非九日伴隨欄可描述一日上升／下降；自然中心可描述向上／向下穿越；當日值與九日 max／min 可形成極值事件。",
        "- 絕對指數點與成交規模不設跨年代固定水準；只取方向。成交量、成交金額及成交筆數的現象只能和價格現象組成第二條確認條件。",
        "- 同一日 50 檔股票仍只算一個市場日；最低市場覆蓋為每窗口 30 日，H／L 局部翻轉覆蓋為每窗口 10 個不同市場日。",
        "- DecisionBase 原始覆蓋表保留正式 W1／W2 都含 2020/07/22 的事實；候選資格依研究窗口把共同邊界日只歸入較晚的 W2，不重複計為兩份市場證據。",
        "",
        "## 下一階段資格",
        "",
        f"- Q0 先跑兩個零控制，必須 0 票數／動作／期末差異及 `periods.csv` 位元一致。Q1 再使用凍結的 {controls['g1_count']} 條 G1 正向控制，但把規則名稱與門檻藏起來，改以完整策略效率辨識；至少找回 {controls['q1_minimum_recovery']} 條、phase 與二數值門檻同時達標，才准搜尋未知大盤條件。",
        "- Q0/Q1 必須先實測一個 Sample 的 runner 時間與產物大小。現有 manifest 沒有可靠 elapsed 欄位，I01 不用交談印象捏造分鐘數。",
        "- Q1 失敗即停止，不用大盤未知結果補答案；Q1 通過後也先只開單一價格現象，二現象、S／A 與任何完整 Baseline 候選都要分段另行核准。",
        "",
        "本段沒有讀取未來價格、交易結果或效率分數，沒有下載、模型、候選回測、tUpdate／simUpdate 或 App／Baseline 變更。",
    ]
    return ("\n".join(lines) + "\n").encode()


def publish(output: Path, files: dict[str, bytes]) -> None:
    if output.exists():
        existing = {path.name: path.read_bytes() for path in output.iterdir() if path.is_file()}
        require(existing == files, f"existing immutable I01 output differs: {output}")
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}-", dir=output.parent))
    try:
        for name, data in files.items():
            pool.atomic_write(temporary / name, data)
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def build_offline(args: argparse.Namespace) -> Path:
    market_rows, catalog, snapshot_manifest = load_market(args.snapshot.resolve())
    atoms, _ = build_atoms(market_rows, catalog)
    decision_rows, pivot_masks, decision_metadata = verify_decision_bases()
    market_dates = {row["date"] for row in market_rows}
    missing_event_dates = sorted(set(decision_metadata["all_event_dates"]) - market_dates)
    require(not missing_event_dates, f"DecisionBase dates missing from TAIEX: {missing_event_dates[:5]}")
    action_rows, pair_rows, candidate_summary = summarize_candidates(
        atoms, market_rows, pivot_masks, decision_metadata
    )
    controls_rows, controls_summary = control_rows()

    field_fields = [
        "field", "category", "source", "formula_family", "unit", "warmup", "precision",
        "current_reference", "candidate_role",
        "level_allowed", "change_allowed", "standalone_allowed", "pair_role", "reason",
    ]
    atom_fields = [
        "atom_id", "source_field", "category", "kind", "orientation", "condition",
        "threshold_source", "threshold", "dates_w1", "dates_w2", "dates_w3",
        "market_coverage_passed", "canonical_atom_id", "is_canonical",
    ]
    decision_fields = [
        "sample", "window_id", "phase", "events", "unique_market_dates", "stock_count",
        "planned_action_events", "executed_action_events", "exact_one_vote_pivotal_supported",
        "support_pivotal_events", "support_pivotal_dates", "oppose_pivotal_events",
        "oppose_pivotal_dates",
    ]
    action_fields = [
        "atom_id", "phase", "vote", "direction", "pivotal_dates_w1",
        "pivotal_dates_w2", "pivotal_dates_w3", "action_coverage_passed",
    ]
    pair_fields = ["pair_kind", "phase", "direction", "condition_count", "action_ready_count", "status"]
    control_fields = [
        "control_id", "kind", "phase", "rule_id", "condition", "required_result", "qualification_stage",
    ]
    outputs = {
        "field-eligibility.csv": csv_bytes(catalog, field_fields),
        "phenomenon-atoms.csv": csv_bytes(atoms, atom_fields),
        "decision-coverage.csv": csv_bytes(decision_rows, decision_fields),
        "single-action-coverage.csv": csv_bytes(action_rows, action_fields),
        "pair-candidate-summary.csv": csv_bytes(pair_rows, pair_fields),
        "control-plan.csv": csv_bytes(controls_rows, control_fields),
    }
    quality = {
        "study_id": STUDY_ID,
        "status": "complete-inventory-no-rule-candidates",
        "market_snapshot_id": snapshot_manifest["snapshot_id"],
        "candidate_summary": candidate_summary,
        "controls": controls_summary,
        "minimum_market_dates_per_window": MIN_MARKET_DATES_PER_WINDOW,
        "minimum_pivotal_dates_per_window": MIN_PIVOTAL_DATES_PER_WINDOW,
        "decision_event_count": sum(int(row["events"]) for row in decision_rows),
        "missing_market_dates": 0,
        "network_access_guarded": True,
        "network_request_count": 0,
        "future_price_fields_read": False,
        "outcome_fields_read": False,
        "model_trained": False,
        "rule_candidates_generated": 0,
        "simupdate_run_count": 0,
        "passed": True,
    }
    outputs["quality-report.json"] = json_bytes(quality)
    outputs["report.md"] = render_report(candidate_summary, decision_rows, controls_summary)
    identity = hashlib.sha256(
        TOOL_VERSION.encode()
        + pool.sha256((args.snapshot.resolve() / "manifest.json").read_bytes()).encode()
        + b"".join(pool.sha256(data).encode() for _, data in sorted(outputs.items()))
    ).hexdigest()
    run_id = f"mkt-r02-i01-market-votes-20260902-{identity[:12]}"
    manifest = {
        "study_id": STUDY_ID,
        "run_id": run_id,
        "tool": "tools/market_vote_phenomenon_inventory.py",
        "tool_version": TOOL_VERSION,
        "market_snapshot": {
            "snapshot_id": snapshot_manifest["snapshot_id"],
            "manifest_sha256": pool.sha256((args.snapshot.resolve() / "manifest.json").read_bytes()),
        },
        "decision_bases": decision_metadata["inputs"],
        "positive_control_source": {
            "path": "exports/future-path-study/fwd-v20-rb01-t2s39-20260902/control-map.csv",
            **controls_summary,
        },
        "window_assignment": "W1/W2 half-open and boundary owned by later window; W3 inclusive through date",
        "outputs": {name: {"sha256": pool.sha256(data), "bytes": len(data)} for name, data in sorted(outputs.items())},
        "qualification_passed": True,
        "unknown_market_search_authorized": False,
    }
    outputs["manifest.json"] = json_bytes(manifest)
    outputs[".complete"] = (run_id + "\n").encode()
    output = args.output_root.resolve() / run_id
    publish(output, outputs)
    return output


def build(args: argparse.Namespace) -> Path:
    with reuse.forbid_network() as network:
        output = build_offline(args)
    require(network["count"] == 0, "I01 attempted an unexpected network request")
    return output


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, default=SNAPSHOT)
    parser.add_argument("--output-root", type=Path, default=OUTPUT_ROOT)
    return parser.parse_args()


def main() -> int:
    try:
        print(build(arguments()))
        return 0
    except (OSError, KeyError, ValueError, json.JSONDecodeError, sqlite3.Error, pool.MarketDataError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
