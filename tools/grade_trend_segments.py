#!/usr/bin/env python3
"""Build the read-only GT-SEG-P1 Grade trend ten-segment artifact."""

from __future__ import annotations

import argparse
import csv
import io
import json
import sqlite3
from pathlib import Path
from typing import Any

import market_data_pool as pool
import market_snapshot_reuse as reuse


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DECISION_ROOT = ROOT / "exports/backtest-decision-bases"
DEFAULT_OUTPUT_ROOT = ROOT / "exports/grade-trend-study"
TOOL_VERSION = "grade-trend-segments-v1"
DISPLAY_THRESHOLD = 0.611888
CONFIRMED_TURN_THRESHOLD = 0.3
CONFIRMED_LATE_THRESHOLD = DISPLAY_THRESHOLD + CONFIRMED_TURN_THRESHOLD

RAW_PHASES = {
    0: "unavailable",
    1: "neutral",
    2: "improving_warning",
    3: "worsening_warning",
    4: "legacy_improving_confirmed",
    5: "legacy_worsening_confirmed",
    6: "improving_cooldown",
    7: "worsening_cooldown",
    8: "improving_seeking_peak",
    9: "improving_pulling_back",
    10: "worsening_seeking_bottom",
    11: "worsening_rebounding",
}

SEGMENTS = {
    "unavailable": ("資料不足", False),
    "neutral": ("中性", False),
    "improving_warning": ("改善預警", True),
    "improving_seeking_peak_early": ("改善探頂前期", True),
    "improving_seeking_peak_late": ("改善探頂後期", True),
    "improving_pulling_back": ("改善拉回", True),
    "improving_cooldown": ("改善冷卻", True),
    "worsening_warning": ("惡化預警", True),
    "worsening_seeking_bottom_early": ("惡化探底前期", True),
    "worsening_seeking_bottom_late": ("惡化探底後期", True),
    "worsening_rebounding": ("惡化反彈", True),
    "worsening_cooldown": ("惡化冷卻", True),
}

SEGMENT_ORDER = list(SEGMENTS)
COLLAPSED_RAW = {
    "unavailable": 0,
    "neutral": 1,
    "improving_warning": 2,
    "improving_seeking_peak_early": 8,
    "improving_seeking_peak_late": 8,
    "improving_pulling_back": 9,
    "improving_cooldown": 6,
    "worsening_warning": 3,
    "worsening_seeking_bottom_early": 10,
    "worsening_seeking_bottom_late": 10,
    "worsening_rebounding": 11,
    "worsening_cooldown": 7,
}

ROW_FIELDS = [
    "sample_id", "decision_base_id", "window_start", "window_end", "stock_id",
    "trade_date", "fit_trend", "fit_trend_phase_raw", "fit_trend_phase_extreme",
    "segment_id", "segment_name", "is_directional_segment",
]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise pool.MarketDataError(message)


def derive_segment(phase_raw: int, extreme: float | None) -> str:
    require(phase_raw in RAW_PHASES, f"unknown Grade trend phase raw value: {phase_raw}")
    if phase_raw == 4 or phase_raw == 5:
        raise pool.MarketDataError(f"legacy unsplit confirmation phase is not derivable: {phase_raw}")
    if phase_raw == 8:
        require(extreme is not None, "improving seeking-peak phase has no running extreme")
        return (
            "improving_seeking_peak_late"
            if extreme >= CONFIRMED_LATE_THRESHOLD
            else "improving_seeking_peak_early"
        )
    if phase_raw == 10:
        require(extreme is not None, "worsening seeking-bottom phase has no running extreme")
        return (
            "worsening_seeking_bottom_late"
            if extreme <= -CONFIRMED_LATE_THRESHOLD
            else "worsening_seeking_bottom_early"
        )
    direct = {
        0: "unavailable",
        1: "neutral",
        2: "improving_warning",
        3: "worsening_warning",
        6: "improving_cooldown",
        7: "worsening_cooldown",
        9: "improving_pulling_back",
        11: "worsening_rebounding",
    }
    return direct[phase_raw]


def yyyymmdd(value: int) -> str:
    text = f"{int(value):08d}"
    require(len(text) == 8, f"invalid YYYYMMDD value: {value}")
    return f"{text[:4]}-{text[4:6]}-{text[6:]}"


def decision_base_directories(root: Path) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for directory in root.glob("?-*-t3-s39-*-v7"):
        manifest_path = directory / "manifest.json"
        if not manifest_path.is_file():
            continue
        manifest = json.loads(manifest_path.read_text())
        sample = str(manifest.get("sampleID", ""))
        if sample in "ABCDE" and len(sample) == 1:
            require(sample not in result, f"multiple v21 DecisionBases for Sample {sample}")
            result[sample] = directory
    require(set(result) == set("ABCDE"), f"expected v21 DecisionBase A-E, got {sorted(result)}")
    return dict(sorted(result.items()))


def verify_decision_base(directory: Path, sample: str) -> dict[str, Any]:
    manifest_path = directory / "manifest.json"
    database_path = directory / "decisions.sqlite"
    manifest = json.loads(manifest_path.read_text())
    decision_base_id = str(manifest.get("decisionBaseID", ""))
    require(decision_base_id == directory.name, f"DecisionBase ID mismatch: {directory}")
    require(manifest.get("sampleID") == sample, f"DecisionBase Sample mismatch: {directory}")
    require(manifest.get("dataRuleVersion") == "T3/S39", f"DecisionBase data rule mismatch: {directory}")
    require(manifest.get("windowCount") == 3, f"DecisionBase window count mismatch: {directory}")
    require(manifest.get("stockCount") == 10, f"DecisionBase stock count mismatch: {directory}")
    require((directory / ".complete").read_text().strip() == decision_base_id,
            f"DecisionBase completion marker mismatch: {directory}")
    require((directory / ".p4b-complete").read_text().strip() == decision_base_id,
            f"DecisionBase P4b marker mismatch: {directory}")
    connection = sqlite3.connect(f"file:{database_path.resolve()}?mode=ro", uri=True)
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    finally:
        connection.close()
    require(integrity == "ok", f"DecisionBase integrity failed: {directory}")
    return {
        "manifest": manifest,
        "manifest_sha256": pool.sha256(manifest_path.read_bytes()),
        "database_sha256": pool.sha256(database_path.read_bytes()),
        "integrity_check": integrity,
    }


def load_rows(directory: Path, sample: str) -> list[dict[str, Any]]:
    database_path = directory / "decisions.sqlite"
    connection = sqlite3.connect(f"file:{database_path.resolve()}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        source = connection.execute(
            f"""
            SELECT s.stock_id,
                   w.start_date,
                   w.end_date,
                   o.trade_date,
                   o.fit_trend,
                   o.fit_trend_phase,
                   o.fit_trend_phase_extreme
              FROM strategy_fit_observations o
              JOIN stocks s ON s.stock_key = o.stock_key
              JOIN windows w ON w.window_id = o.window_id
             ORDER BY w.start_date, s.stock_id, o.trade_date
            """
        ).fetchall()
    finally:
        connection.close()
    rows: list[dict[str, Any]] = []
    for row in source:
        phase_raw = int(row["fit_trend_phase"])
        extreme = (
            float(row["fit_trend_phase_extreme"])
            if row["fit_trend_phase_extreme"] is not None else None
        )
        segment_id = derive_segment(phase_raw, extreme)
        segment_name, directional = SEGMENTS[segment_id]
        rows.append({
            "sample_id": sample,
            "decision_base_id": directory.name,
            "window_start": yyyymmdd(row["start_date"]),
            "window_end": yyyymmdd(row["end_date"]),
            "stock_id": row["stock_id"],
            "trade_date": yyyymmdd(row["trade_date"]),
            "fit_trend": float(row["fit_trend"]) if row["fit_trend"] is not None else None,
            "fit_trend_phase_raw": phase_raw,
            "fit_trend_phase_extreme": extreme,
            "segment_id": segment_id,
            "segment_name": segment_name,
            "is_directional_segment": directional,
        })
    return rows


def encode_csv(rows: list[dict[str, Any]], fields: list[str]) -> bytes:
    buffer = io.StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=fields, lineterminator="\n")
    writer.writeheader()
    for row in rows:
        encoded = {}
        for field in fields:
            value = row[field]
            if value is None:
                encoded[field] = ""
            elif isinstance(value, bool):
                encoded[field] = "true" if value else "false"
            elif isinstance(value, float):
                encoded[field] = repr(value)
            else:
                encoded[field] = value
        writer.writerow(encoded)
    return buffer.getvalue().encode("utf-8")


def distribution_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    scopes: list[tuple[str, list[dict[str, Any]]]] = [("ALL", rows)]
    for sample in "ABCDE":
        scopes.append((f"Sample {sample}", [row for row in rows if row["sample_id"] == sample]))
    for window_start in sorted({row["window_start"] for row in rows}):
        scopes.append((window_start, [row for row in rows if row["window_start"] == window_start]))
    result: list[dict[str, Any]] = []
    for scope, selected in scopes:
        directional_total = sum(bool(row["is_directional_segment"]) for row in selected)
        for segment_id in SEGMENT_ORDER:
            count = sum(row["segment_id"] == segment_id for row in selected)
            directional = SEGMENTS[segment_id][1]
            denominator = directional_total if directional else len(selected)
            result.append({
                "scope": scope,
                "observation_count": len(selected),
                "directional_observation_count": directional_total,
                "segment_id": segment_id,
                "segment_name": SEGMENTS[segment_id][0],
                "is_directional_segment": directional,
                "count": count,
                "share": count / denominator if denominator else 0.0,
            })
    return result


def late_to_early_count(rows: list[dict[str, Any]]) -> int:
    count = 0
    previous: dict[tuple[str, str, str], dict[str, Any]] = {}
    for row in rows:
        key = (row["sample_id"], row["window_start"], row["stock_id"])
        prior = previous.get(key)
        if prior is not None:
            pairs = {
                ("improving_seeking_peak_late", "improving_seeking_peak_early"),
                ("worsening_seeking_bottom_late", "worsening_seeking_bottom_early"),
            }
            if (prior["segment_id"], row["segment_id"]) in pairs:
                count += 1
        previous[key] = row
    return count


def report_text(artifact_id: str, quality: dict[str, Any], distribution: list[dict[str, Any]]) -> str:
    all_rows = {row["segment_id"]: row for row in distribution if row["scope"] == "ALL"}
    window_scopes = ["2017-07-22", "2020-07-22", "2023-07-22"]
    lookup = {(row["scope"], row["segment_id"]): row for row in distribution}
    lines = [
        "# GT-SEG-P1 Grade 趨勢十段衍生驗證",
        "",
        f"- 產物：`{artifact_id}`",
        "- 定義：預警與冷卻不變；改善探頂及惡化探底依運行極值切前／後期，拉回與反彈保留。",
        f"- 後期門檻：`0.611888 + 0.3 = {CONFIRMED_LATE_THRESHOLD:.6f}`；只讀既有 `fitTrendPhaseExtreme`，不使用未來資料。",
        "- 邊界：不修改既有 raw phase、App schema、T/S、Baseline 或正式規則。",
        "",
        "## 三窗口分布（A～E 合計）",
        "",
        "| 階段 | 2017 | 2020 | 2023 | 全部 |",
        "|---|---:|---:|---:|---:|",
    ]
    for segment_id in SEGMENT_ORDER:
        if not SEGMENTS[segment_id][1]:
            continue
        values = [lookup[(scope, segment_id)] for scope in window_scopes]
        total = all_rows[segment_id]
        lines.append(
            f"| {SEGMENTS[segment_id][0]} | "
            + " | ".join(str(row["count"]) for row in values)
            + f" | {total['count']}（{total['share']:.1%}） |"
        )
    lines += [
        "",
        "## 驗證",
        "",
        f"- A～E 共 {quality['observation_count']:,} 筆逐股／逐窗口 Grade 趨勢觀察。",
        f"- 原 phase 聯集還原差異：{quality['collapsed_phase_mismatch_count']}；後期倒退前期：{quality['late_to_early_count']}；舊未分段確認值：{quality['legacy_confirmation_count']}。",
        f"- 十個方向階段在三個固定窗口是否全部有覆蓋：`{quality['all_ten_directional_segments_present_in_each_window']}`。",
        "",
        "這只確認十段可以由現有持久值因果、穩定地導出；不代表任何前／後期應成為買賣規則。",
        "",
    ]
    return "\n".join(lines)


def build(decision_root: Path, output_root: Path) -> Path:
    directories = decision_base_directories(decision_root)
    sources = {sample: verify_decision_base(directory, sample)
               for sample, directory in directories.items()}
    rows = [row for sample, directory in directories.items() for row in load_rows(directory, sample)]
    require(bool(rows), "GT-SEG-P1 has no source rows")
    distribution = distribution_rows(rows)
    collapsed_mismatch = sum(
        COLLAPSED_RAW[row["segment_id"]] != row["fit_trend_phase_raw"] for row in rows
    )
    legacy_count = sum(row["fit_trend_phase_raw"] in (4, 5) for row in rows)
    late_regression_count = late_to_early_count(rows)
    window_presence = {
        scope: sorted(
            row["segment_id"] for row in distribution
            if row["scope"] == scope and row["is_directional_segment"] and row["count"] > 0
        )
        for scope in ("2017-07-22", "2020-07-22", "2023-07-22")
    }
    directional_segments = sorted(
        segment_id for segment_id, (_, directional) in SEGMENTS.items() if directional
    )
    quality = {
        "task_id": "GT-SEG-P1",
        "tool_version": TOOL_VERSION,
        "display_threshold": DISPLAY_THRESHOLD,
        "confirmed_turn_threshold": CONFIRMED_TURN_THRESHOLD,
        "confirmed_late_threshold": CONFIRMED_LATE_THRESHOLD,
        "decision_base_count": len(directories),
        "observation_count": len(rows),
        "collapsed_phase_mismatch_count": collapsed_mismatch,
        "late_to_early_count": late_regression_count,
        "legacy_confirmation_count": legacy_count,
        "window_directional_segment_presence": window_presence,
        "all_ten_directional_segments_present_in_each_window": all(
            values == directional_segments for values in window_presence.values()
        ),
        "source_integrity_checks": {
            sample: value["integrity_check"] for sample, value in sources.items()
        },
    }
    quality["passed"] = (
        quality["decision_base_count"] == 5
        and quality["collapsed_phase_mismatch_count"] == 0
        and quality["late_to_early_count"] == 0
        and quality["legacy_confirmation_count"] == 0
        and quality["all_ten_directional_segments_present_in_each_window"]
        and all(value == "ok" for value in quality["source_integrity_checks"].values())
    )
    require(bool(quality["passed"]), "GT-SEG-P1 quality gate failed")

    row_data = encode_csv(rows, ROW_FIELDS)
    distribution_fields = [
        "scope", "observation_count", "directional_observation_count", "segment_id",
        "segment_name", "is_directional_segment", "count", "share",
    ]
    distribution_data = encode_csv(distribution, distribution_fields)
    identity = pool.sha256((TOOL_VERSION + "\n").encode() + row_data)
    artifact_id = f"gt-seg-p1-grade-trend-ten-segments-{identity[:12]}"
    quality["artifact_id"] = artifact_id
    quality_data = pool.json_bytes(quality)
    report_data = report_text(artifact_id, quality, distribution).encode("utf-8")
    file_data = {
        "grade-trend-segments.csv": row_data,
        "segment-distribution.csv": distribution_data,
        "quality-report.json": quality_data,
        "report.md": report_data,
    }
    manifest = {
        "artifact_id": artifact_id,
        "task_id": "GT-SEG-P1",
        "tool": "tools/grade_trend_segments.py",
        "tool_version": TOOL_VERSION,
        "definition": {
            "display_threshold": DISPLAY_THRESHOLD,
            "confirmed_turn_threshold": CONFIRMED_TURN_THRESHOLD,
            "confirmed_late_threshold": CONFIRMED_LATE_THRESHOLD,
            "early_color_opacity": 0.58,
            "late_color_opacity": 1.0,
        },
        "sources": {
            sample: {
                "decision_base_id": directories[sample].name,
                "manifest_sha256": sources[sample]["manifest_sha256"],
                "database_sha256": sources[sample]["database_sha256"],
            }
            for sample in "ABCDE"
        },
        "observation_count": len(rows),
        "files": {name: pool.sha256(data) for name, data in file_data.items()},
        "qualification_passed": True,
        "formal_effect": "none",
    }
    files = {
        **file_data,
        "manifest.json": pool.json_bytes(manifest),
        ".complete": (artifact_id + "\n").encode(),
    }
    output = output_root / artifact_id
    reuse.publish_tree(output, files)
    reuse.verify_hashed_bundle(output, id_key="artifact_id", file_hashes_key="files")
    return output


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--decision-root", type=Path, default=DEFAULT_DECISION_ROOT)
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    return parser.parse_args()


def main() -> int:
    args = arguments()
    try:
        print(build(args.decision_root.resolve(), args.output_root.resolve()))
        return 0
    except (OSError, ValueError, json.JSONDecodeError, sqlite3.Error, pool.MarketDataError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
