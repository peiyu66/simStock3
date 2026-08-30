#!/usr/bin/env python3
"""RCTX-D01: compare full-history and 251-row simulation context seeds."""

from __future__ import annotations

import csv
import json
import math
import sqlite3
from collections import defaultdict, deque
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from statistics import median


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "exports/rolling-context-study/rctx-d01-251-t2s35-20260830"
EXPECTED_COMMIT = "a625837b8d48c2a8b35448dca8237267dc9edb9b"
EXPECTED_DATA_RULE = "T2/S35"
CORE_DATA_EPOCH = 978_307_200
TAIPEI = timezone(timedelta(hours=8))
LOOKBACK_ROWS = 250  # fetchLimit 251 includes the current row.

WARNING_PHASE = 3
CONFIRMED_PHASES = {5, 10, 11}
BOUNDARY_PHASES = {WARNING_PHASE, *CONFIRMED_PHASES}

FIXED_REPORT = {
    sample: ROOT / "exports/backtest-reports" /
    f"baseline-{sample.lower()}-v16-s28-grade-loss-cut-penalty-t2s35-9y-fixed3y-600w-20260830"
    for sample in "ABCD"
}
FULLSTRESS_REPORT = {
    sample: ROOT / "exports/backtest-reports" /
    f"baseline-{sample.lower()}-v16-s28-grade-loss-cut-penalty-t2s35-9y-fullstress-600w-20260830"
    for sample in "AB"
}
DECISION_BASE = {
    sample: ROOT / "exports/backtest-decision-bases" /
    f"{sample.lower()}-abcd9-v2-s28-grade-loss-cut-penalty-20260830-t2-s35-a625837b8d48-fixed3y-20260722-v6"
    for sample in "ABCD"
}


@dataclass(frozen=True)
class Event:
    index: int
    event_date: date
    state: object


def taipei_date(timestamp: float) -> date:
    return datetime.fromtimestamp(timestamp + CORE_DATA_EPOCH, tz=TAIPEI).date()


def compact_day(value: int) -> date:
    return datetime.strptime(str(value), "%Y%m%d").date()


def swift_round_positive(value: float) -> float:
    return math.floor(value + 0.5)


def reconstructed_settlement_roi(row: sqlite3.Row) -> float:
    unit_cost = float(row["unit_cost_before"])
    unit_roi = float(row["unit_roi_before"])
    quantity = float(row["inventory_before"])
    if unit_cost <= 0 or quantity <= 0:
        raise ValueError(f"Invalid sell prestate for event {row['event_id']}")
    price = unit_cost * (1 + unit_roi / 100)
    amount = price * quantity * 1000
    cost = unit_cost * quantity * 1000
    fee = max(20, swift_round_positive(amount * 0.001425))
    tax = swift_round_positive(amount * 0.003)
    return 100 * (amount - cost - fee - tax) / cost


def boundary_name(phase: int | None) -> str:
    if phase is None:
        return "none"
    if phase == WARNING_PHASE:
        return "worsening_warning"
    if phase in CONFIRMED_PHASES:
        return "worsening_confirmed"
    raise ValueError(f"Unexpected boundary phase {phase}")


def l_bonus_eligible(phase: int) -> bool:
    return phase != WARNING_PHASE and phase not in CONFIRMED_PHASES


def verify_report(directory: Path, sample: str) -> dict:
    manifest_path = directory / "manifest.json"
    marker_path = directory / ".complete"
    if not manifest_path.exists() or not marker_path.exists():
        raise FileNotFoundError(f"Incomplete report directory: {directory}")
    manifest = json.loads(manifest_path.read_text())
    expected_run = manifest.get("runID")
    if marker_path.read_text().strip() != expected_run:
        raise ValueError(f"Completion marker mismatch: {directory}")
    if manifest.get("sampleID") != sample:
        raise ValueError(f"Sample mismatch: {directory}")
    if manifest.get("dataRuleVersion") != EXPECTED_DATA_RULE:
        raise ValueError(f"Data rule mismatch: {directory}")
    if manifest.get("ruleCommit") != EXPECTED_COMMIT:
        raise ValueError(f"Rule commit mismatch: {directory}")
    store = directory / "browse.store"
    with sqlite3.connect(store) as connection:
        if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError(f"SQLite integrity failure: {store}")
    return manifest


def verify_decision_base(directory: Path) -> Path:
    database = directory / "decisions.sqlite"
    marker = directory / ".complete"
    p4b = directory / ".p4b-complete"
    if not database.exists() or not marker.exists() or not p4b.exists():
        raise FileNotFoundError(f"Incomplete DecisionBase: {directory}")
    with sqlite3.connect(database) as connection:
        if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError(f"SQLite integrity failure: {database}")
        metadata = dict(connection.execute("SELECT key, value FROM metadata"))
    if metadata.get("dataRuleVersion") != EXPECTED_DATA_RULE:
        raise ValueError(f"DecisionBase data rule mismatch: {directory}")
    if metadata.get("ruleCommit") != EXPECTED_COMMIT:
        raise ValueError(f"DecisionBase rule commit mismatch: {directory}")
    return database


def analyze_sequence(
    *,
    source: str,
    sample: str,
    path_label: str,
    stock_id: str,
    stock_name: str,
    rows: list[dict],
    g_mismatches: list[dict],
    l_mismatches: list[dict],
    summary: dict,
    exact_preview: bool,
) -> None:
    recent_sells: deque[Event] = deque()
    recent_boundaries: deque[Event] = deque()
    full_sell: Event | None = None
    full_boundary: Event | None = None
    last_index = len(rows) - 1

    for index, row in enumerate(rows):
        current_date = row["trade_date"]
        cutoff = index - LOOKBACK_ROWS
        while recent_sells and recent_sells[0].index < cutoff:
            recent_sells.popleft()
        while recent_boundaries and recent_boundaries[0].index < cutoff:
            recent_boundaries.popleft()

        summary["evaluated_dates"] += 1
        truncated_sell = recent_sells[-1] if recent_sells else None
        full_g = int(full_sell.state) if full_sell else 0
        truncated_g = int(truncated_sell.state) if truncated_sell else 0
        if full_g != truncated_g:
            summary["g_state_mismatch_dates"] += 1
            summary["g_stocks"].add(stock_id)
            age = index - full_sell.index if full_sell else None
            if age is not None:
                summary["g_event_ages"].append(age)
            g_mismatches.append({
                "source": source,
                "sample": sample,
                "path": path_label,
                "stock_id": stock_id,
                "stock_name": stock_name,
                "trade_date": current_date.isoformat(),
                "full_state": full_g,
                "rows251_state": truncated_g,
                "full_event_date": full_sell.event_date.isoformat() if full_sell else "",
                "event_age_rows": age,
                "is_path_last_date": int(index == last_index),
            })
            if index == last_index:
                summary["g_last_date_mismatches"] += 1

        if "saved_phase" in row:
            summary["l_evaluated_dates"] += 1
            truncated_boundary = recent_boundaries[-1] if recent_boundaries else None
            full_phase = int(full_boundary.state) if full_boundary else None
            truncated_phase = int(truncated_boundary.state) if truncated_boundary else None
            if full_phase != truncated_phase:
                summary["l_boundary_mismatch_dates"] += 1
                summary["l_stocks"].add(stock_id)
                age = index - full_boundary.index if full_boundary else None
                if age is not None:
                    summary["l_event_ages"].append(age)
                current_phase = int(row.get("preview_phase", row["saved_phase"]))
                phase_is_exact = exact_preview or bool(row.get("saved_phase_is_exact_preview", False))
                eligible = l_bonus_eligible(current_phase)
                full_bonus = int(eligible and full_phase in CONFIRMED_PHASES)
                truncated_bonus = int(eligible and truncated_phase in CONFIRMED_PHASES)
                input_mismatch = full_bonus != truncated_bonus
                if input_mismatch:
                    summary["l_bonus_mismatch_dates"] += 1
                    if phase_is_exact:
                        summary["l_exact_bonus_mismatch_dates"] += 1
                    else:
                        summary["l_indicative_bonus_mismatch_dates"] += 1
                l_mismatches.append({
                    "source": source,
                    "sample": sample,
                    "path": path_label,
                    "stock_id": stock_id,
                    "stock_name": stock_name,
                    "trade_date": current_date.isoformat(),
                    "full_boundary": boundary_name(full_phase),
                    "rows251_boundary": boundary_name(truncated_phase),
                    "full_event_date": full_boundary.event_date.isoformat() if full_boundary else "",
                    "event_age_rows": age,
                    "current_phase": current_phase,
                    "phase_source": "decision_preview" if exact_preview else (
                        "saved_phase_exact_no_action" if phase_is_exact else "saved_phase_indicator"
                    ),
                    "full_bonus": full_bonus,
                    "rows251_bonus": truncated_bonus,
                    "bonus_input_mismatch": int(input_mismatch),
                    "is_path_last_date": int(index == last_index),
                })
                if index == last_index:
                    summary["l_last_date_boundary_mismatches"] += 1

        sell_state = row.get("sell_state")
        if sell_state is not None:
            event = Event(index, current_date, int(sell_state))
            full_sell = event
            recent_sells.append(event)
        phase = row.get("saved_phase")
        if phase in BOUNDARY_PHASES:
            event = Event(index, current_date, int(phase))
            full_boundary = event
            recent_boundaries.append(event)


def empty_summary(source: str, sample: str, path_label: str, exact_preview: bool) -> dict:
    return {
        "source": source,
        "sample": sample,
        "path": path_label,
        "phase_input": "decision_preview" if exact_preview else "saved_phase_with_no_action_exact_subset",
        "stocks": 0,
        "evaluated_dates": 0,
        "g_state_mismatch_dates": 0,
        "g_last_date_mismatches": 0,
        "g_stocks": set(),
        "g_event_ages": [],
        "l_evaluated_dates": 0,
        "l_boundary_mismatch_dates": 0,
        "l_bonus_mismatch_dates": 0,
        "l_exact_bonus_mismatch_dates": 0,
        "l_indicative_bonus_mismatch_dates": 0,
        "l_last_date_boundary_mismatches": 0,
        "l_stocks": set(),
        "l_event_ages": [],
    }


def finalize_summary(value: dict) -> dict:
    result = dict(value)
    for prefix in ("g", "l"):
        stocks = result.pop(f"{prefix}_stocks")
        ages = result.pop(f"{prefix}_event_ages")
        result[f"{prefix}_affected_stocks"] = len(stocks)
        result[f"{prefix}_affected_stock_ids"] = sorted(stocks)
        result[f"{prefix}_event_age_rows_median"] = median(ages) if ages else None
        result[f"{prefix}_event_age_rows_max"] = max(ages) if ages else None
    return result


def load_preview_phases(database: Path, window_id: int = 1) -> dict[tuple[str, date], int]:
    with sqlite3.connect(database) as connection:
        connection.row_factory = sqlite3.Row
        rows = connection.execute(
            """
            SELECT d.stock_id, d.trade_date, o.fit_trend_phase
            FROM decision_event_lookup d
            JOIN event_strategy_fit_observations e USING(event_id)
            JOIN strategy_fit_observations o USING(observation_id)
            WHERE d.window_id = ? AND d.phase = 0
            """,
            (window_id,),
        )
        return {
            (str(row["stock_id"]), compact_day(int(row["trade_date"]))): int(row["fit_trend_phase"])
            for row in rows
        }


def analyze_browse_store(
    *,
    source: str,
    sample: str,
    path_label: str,
    store: Path,
    end_date: date,
    preview_phases: dict[tuple[str, date], int] | None,
    g_mismatches: list[dict],
    l_mismatches: list[dict],
) -> dict:
    exact_preview = preview_phases is not None
    result = empty_summary(source, sample, path_label, exact_preview)
    grouped: dict[tuple[str, str, date], list[dict]] = defaultdict(list)
    with sqlite3.connect(store) as connection:
        connection.row_factory = sqlite3.Row
        rows = connection.execute(
            """
            SELECT s.ZSID AS stock_id, s.ZSNAME AS stock_name, s.ZDATESTART AS date_start,
                   t.ZDATETIME AS trade_time, t.ZSIMQTYSELL AS qty_sell,
                   t.ZSIMAMTROI AS amount_roi, t.ZSIMREVERSED AS reversed,
                   t.ZSIMQTYBUY AS qty_buy, t.ZSIMINVESTADDED AS invest_added,
                   t.ZSIMINVESTBYUSER AS invest_by_user,
                   t.ZSIMFITTRENDPHASERAW AS saved_phase
            FROM ZTRADE t
            JOIN ZSTOCK s ON s.Z_PK = t.ZSTOCK
            ORDER BY s.ZSID, t.ZDATETIME
            """
        )
        for row in rows:
            stock_id = str(row["stock_id"])
            stock_name = str(row["stock_name"])
            start_date = taipei_date(float(row["date_start"]))
            trade_date = taipei_date(float(row["trade_time"]))
            if trade_date < start_date or trade_date > end_date:
                continue
            sell_state = None
            if float(row["qty_sell"] or 0) > 0 and str(row["reversed"] or "") == "":
                roi = float(row["amount_roi"] or 0)
                if roi < 0:
                    sell_state = 1
                elif roi > 0:
                    sell_state = 0
            item = {
                "trade_date": trade_date,
                "sell_state": sell_state,
                "saved_phase": int(row["saved_phase"] or 0),
                # With no buy, sell, or investment, preview and persisted trend
                # update consume the same current efficiency inputs.
                "saved_phase_is_exact_preview": (
                    float(row["qty_buy"] or 0) == 0
                    and float(row["qty_sell"] or 0) == 0
                    and float(row["invest_added"] or 0) + float(row["invest_by_user"] or 0) == 0
                ),
            }
            if preview_phases is not None:
                key = (stock_id, trade_date)
                if key not in preview_phases:
                    # Fixed windows use a half-open end date. The browse store
                    # retains the following market row, while DecisionBase has
                    # no decision event for it; it is outside this path.
                    continue
                item["preview_phase"] = preview_phases[key]
            grouped[(stock_id, stock_name, start_date)].append(item)

    result["stocks"] = len(grouped)
    for (stock_id, stock_name, _), rows in grouped.items():
        analyze_sequence(
            source=source,
            sample=sample,
            path_label=path_label,
            stock_id=stock_id,
            stock_name=stock_name,
            rows=rows,
            g_mismatches=g_mismatches,
            l_mismatches=l_mismatches,
            summary=result,
            exact_preview=exact_preview,
        )
    return finalize_summary(result)


def load_browse_sell_roi(store: Path, end_date: date) -> dict[tuple[str, date], float]:
    result = {}
    with sqlite3.connect(store) as connection:
        connection.row_factory = sqlite3.Row
        rows = connection.execute(
            """
            SELECT s.ZSID AS stock_id, t.ZDATETIME AS trade_time, t.ZSIMAMTROI AS amount_roi
            FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK = t.ZSTOCK
            WHERE t.ZSIMQTYSELL > 0 AND coalesce(t.ZSIMREVERSED, '') = ''
            """
        )
        for row in rows:
            trade_date = taipei_date(float(row["trade_time"]))
            if trade_date <= end_date:
                result[(str(row["stock_id"]), trade_date)] = float(row["amount_roi"])
    return result


def analyze_decision_base_g(
    *,
    sample: str,
    database: Path,
    validation_sell_roi: dict[tuple[str, date], float],
    g_mismatches: list[dict],
) -> tuple[list[dict], dict]:
    summaries = []
    validation_count = 0
    validation_sign_mismatches = 0
    validation_deltas = []
    with sqlite3.connect(database) as connection:
        connection.row_factory = sqlite3.Row
        stock_names = {
            int(row["stock_key"]): (str(row["stock_id"]), str(row["name"]))
            for row in connection.execute("SELECT stock_key, stock_id, name FROM stocks")
        }
        grade_rows: dict[tuple[int, int], list[dict]] = defaultdict(list)
        for row in connection.execute(
            "SELECT window_id, stock_key, trade_date FROM decision_events WHERE phase = 0 ORDER BY window_id, stock_key, trade_date"
        ):
            grade_rows[(int(row["window_id"]), int(row["stock_key"]))].append({
                "trade_date": compact_day(int(row["trade_date"])),
                "sell_state": None,
            })
        date_positions = {
            key: {row["trade_date"]: index for index, row in enumerate(rows)}
            for key, rows in grade_rows.items()
        }
        for row in connection.execute(
            """
            SELECT event_id, window_id, stock_key, trade_date,
                   inventory_before, unit_cost_before, unit_roi_before
            FROM decision_events
            WHERE phase = 3 AND planned_action = 'SELL' AND executed_action = 'SELL'
            ORDER BY window_id, stock_key, trade_date
            """
        ):
            key = (int(row["window_id"]), int(row["stock_key"]))
            trade_date = compact_day(int(row["trade_date"]))
            position = date_positions[key][trade_date]
            roi = reconstructed_settlement_roi(row)
            if roi < 0:
                grade_rows[key][position]["sell_state"] = 1
            elif roi > 0:
                grade_rows[key][position]["sell_state"] = 0
            if int(row["window_id"]) == 1:
                stock_id, _ = stock_names[int(row["stock_key"])]
                stored = validation_sell_roi.get((stock_id, trade_date))
                if stored is None:
                    raise ValueError(f"Missing browse sell validation {sample} {stock_id} {trade_date}")
                validation_count += 1
                validation_deltas.append(abs(roi - stored))
                if (roi < 0) != (stored < 0) or (roi > 0) != (stored > 0):
                    validation_sign_mismatches += 1

        by_window: dict[int, dict] = {}
        for (window_id, stock_key), rows in grade_rows.items():
            stock_id, stock_name = stock_names[stock_key]
            if window_id not in by_window:
                by_window[window_id] = empty_summary(
                    "decision_base", sample, f"fixed-W{window_id}", False
                )
            by_window[window_id]["stocks"] += 1
            analyze_sequence(
                source="decision_base",
                sample=sample,
                path_label=f"fixed-W{window_id}",
                stock_id=stock_id,
                stock_name=stock_name,
                rows=rows,
                g_mismatches=g_mismatches,
                l_mismatches=[],
                summary=by_window[window_id],
                exact_preview=False,
            )
        summaries = [finalize_summary(by_window[key]) for key in sorted(by_window)]

    validation = {
        "sample": sample,
        "window": 1,
        "compared_sells": validation_count,
        "sign_mismatches": validation_sign_mismatches,
        "max_abs_roi_delta": max(validation_deltas) if validation_deltas else None,
        "median_abs_roi_delta": median(validation_deltas) if validation_deltas else None,
    }
    if validation_sign_mismatches:
        raise ValueError(f"Settlement ROI sign validation failed for Sample {sample}")
    return summaries, validation


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        path.write_text("")
        return
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def percentage(part: int, total: int) -> str:
    return "-" if total == 0 else f"{100 * part / total:.3f}%"


def make_report(summary: dict) -> str:
    lines = [
        "# RCTX-D01：完整歷史與最近 251 筆前態一致性",
        "",
        "## 方法",
        "",
        "固定使用 Baseline v16、T2/S35、規則 commit " + f"`{EXPECTED_COMMIT}`。",
        "不修改規則或重播。每個日期都視為可能的 Yahoo／P10 起點，比較完整歷史與現行 `fetchLimit: 251`（當日加前 250 筆）可重建的前態。",
        "",
        "G-M02 使用 A／B／C／D 三個固定窗口 DecisionBase；結案 ROI 依正式手續費與交易稅公式還原，並以第一窗口 browse store 驗證正負號。",
        "L-P10 必須使用前日完成後保存的 Grade 趨勢 phase，不能用決策預覽代替；因此採 A／B／C／D 第一窗口 browse store，以及 A／B 九年全期間 browse store。第一窗口以 DecisionBase 當日預覽 phase 精確判斷 L-P10 是否可用；九年全期間中，當日沒有買賣或加碼時，預覽與保存更新使用相同效率輸入，可精確判斷，其餘日期只列保存 phase 指標。",
        "",
        "## G-M02 固定窗口",
        "",
        "| Sample／窗口 | 日期數 | 狀態不同 | 比例 | 影響股票 | 路徑末日不同 | 事件距離中位／最大 |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for row in summary["decision_base_g"]:
        lines.append(
            f"| {row['sample']}／{row['path']} | {row['evaluated_dates']} | "
            f"{row['g_state_mismatch_dates']} | {percentage(row['g_state_mismatch_dates'], row['evaluated_dates'])} | "
            f"{row['g_affected_stocks']} | {row['g_last_date_mismatches']} | "
            f"{row['g_event_age_rows_median'] or '-'}／{row['g_event_age_rows_max'] or '-'} |"
        )
    lines += [
        "",
        "## browse 路徑",
        "",
        "| Sample／路徑 | 日期數 | G 狀態不同 | L 界線不同 | L 輸入不同 | Phase 判定 | 路徑末日 G／L 不同 |",
        "|---|---:|---:|---:|---:|---|---:|",
    ]
    for row in summary["browse_paths"]:
        lines.append(
            f"| {row['sample']}／{row['path']} | {row['evaluated_dates']} | "
            f"{row['g_state_mismatch_dates']} | {row['l_boundary_mismatch_dates']} | "
            f"{row['l_bonus_mismatch_dates']} | {row['phase_input']} | "
            f"{row['g_last_date_mismatches']}／{row['l_last_date_boundary_mismatches']} |"
        )
    lines += [
        "",
        "## ROI 還原驗證",
        "",
        "| Sample | 賣出件數 | 正負號差異 | ROI 最大絕對差 |",
        "|---|---:|---:|---:|",
    ]
    for row in summary["settlement_roi_validation"]:
        lines.append(
            f"| {row['sample']} | {row['compared_sells']} | {row['sign_mismatches']} | "
            f"{row['max_abs_roi_delta']:.9f} |"
        )
    lines += [
        "",
        "## 判讀",
        "",
        summary["conclusion"],
        "",
        "本診斷只回答 Context 起點是否能由 251 筆正確重建，不衡量重構後的執行速度，也不授權 `RCTX-S01`。",
        "",
    ]
    return "\n".join(lines)


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    g_mismatches: list[dict] = []
    l_mismatches: list[dict] = []
    browse_summaries = []
    decision_summaries = []
    validations = []

    manifests = {}
    for sample, directory in FIXED_REPORT.items():
        manifests[f"fixed-{sample}"] = verify_report(directory, sample)
    for sample, directory in FULLSTRESS_REPORT.items():
        manifests[f"fullstress-{sample}"] = verify_report(directory, sample)

    decision_databases = {
        sample: verify_decision_base(directory)
        for sample, directory in DECISION_BASE.items()
    }

    for sample in "ABCD":
        preview = load_preview_phases(decision_databases[sample], window_id=1)
        browse_summaries.append(analyze_browse_store(
            source="browse_store",
            sample=sample,
            path_label="fixed-W1",
            store=FIXED_REPORT[sample] / "browse.store",
            end_date=date(2020, 7, 22),
            preview_phases=preview,
            g_mismatches=g_mismatches,
            l_mismatches=l_mismatches,
        ))

    for sample in "AB":
        through = compact_day(int(manifests[f"fullstress-{sample}"]["through"].replace("/", "")))
        browse_summaries.append(analyze_browse_store(
            source="browse_store",
            sample=sample,
            path_label="fullstress-9y",
            store=FULLSTRESS_REPORT[sample] / "browse.store",
            end_date=through,
            preview_phases=None,
            g_mismatches=g_mismatches,
            l_mismatches=l_mismatches,
        ))

    for sample in "ABCD":
        stored_sells = load_browse_sell_roi(
            FIXED_REPORT[sample] / "browse.store", date(2020, 7, 22)
        )
        summaries, validation = analyze_decision_base_g(
            sample=sample,
            database=decision_databases[sample],
            validation_sell_roi=stored_sells,
            g_mismatches=g_mismatches,
        )
        decision_summaries.extend(summaries)
        validations.append(validation)

    decision_g_mismatch = sum(row["g_state_mismatch_dates"] for row in decision_summaries)
    browse_l_mismatch = sum(row["l_boundary_mismatch_dates"] for row in browse_summaries)
    exact_l_input_mismatch = sum(row["l_exact_bonus_mismatch_dates"] for row in browse_summaries)
    if decision_g_mismatch or browse_l_mismatch:
        conclusion = (
            "最近 251 筆不足以作為所有模擬前態的權威來源。"
            f"固定窗口 G-M02 有 {decision_g_mismatch} 個日期重建出不同狀態；"
            f"具完成後 phase 的 browse 路徑有 {browse_l_mismatch} 個日期重建出不同 L-P10 界線，"
            f"其中 {exact_l_input_mismatch} 個日期可由決策預覽或無行動同態精確確認會改變 L-P10 輸入。"
            "RCTX-S01 必須讓模擬 Context 以限定歷史查詢或等價摘要分別初始化，"
            "不能直接沿用技術窗口的 251 筆陣列。"
        )
    else:
        conclusion = (
            "目前資料沒有發現 251 筆前態差異；RCTX-S01 仍應保留獨立初始化介面，"
            "不得把本次樣本零差異寫成永久的 251 筆語意。"
        )

    summary = {
        "experiment_id": "RCTX-D01",
        "baseline": "Baseline v16 / S28 / T2-S35",
        "rule_commit": EXPECTED_COMMIT,
        "lookback_fetch_limit": 251,
        "lookback_prior_rows": LOOKBACK_ROWS,
        "classification_uses_future": False,
        "replay_performed": False,
        "decision_base_g": decision_summaries,
        "browse_paths": browse_summaries,
        "settlement_roi_validation": validations,
        "g_mismatch_rows": len(g_mismatches),
        "l_mismatch_rows": len(l_mismatches),
        "conclusion": conclusion,
        "coverage_limit": (
            "G-M02 covers A-D fixed windows. L-P10 covers A-D fixed W1 and A-B fullstress; "
            "fixed W2/W3 period stores were not retained, and decision preview phase is not a substitute "
            "for the completed persisted phase scanned by the production rule."
        ),
    }

    write_csv(OUTPUT / "g-state-mismatches.csv", g_mismatches)
    write_csv(OUTPUT / "l-boundary-mismatches.csv", l_mismatches)
    (OUTPUT / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    (OUTPUT / "report.md").write_text(make_report(summary))
    (OUTPUT / ".complete").write_text("RCTX-D01\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
