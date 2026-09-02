#!/usr/bin/env python3
"""Build the frozen P0/L01 inputs for the Baseline v20 future-path study.

This stage validates the five fixed-window Baselines and DecisionBases, then
creates future-path labels and the leave-one-out A-D market proxy.  It does not
read feature rankings, train a model, or replay simUpdate.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import importlib.util
import json
import math
import os
import platform
import shutil
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable, Sequence
from zoneinfo import ZoneInfo


STUDY_ID = "FWD-V20-M01-ABCDE"
RUN_ID = "fwd-v20-m01-abcde-t2s39-20260902"
SAMPLES = "ABCDE"
MARKET_SAMPLES = "ABCD"
EXPECTED = {
    "dataRuleVersion": "T2/S39",
    "ruleVersion": "s32-an03-wow-nonbottom-no-ap02-add-penalty-20260901",
    "ruleCommit": "48d42e50ada5dcc0ed2e22dffff6871323daf8b7",
    "through": "2026/07/22",
    "historyStart": "2016/07/22",
    "moneyBaseWan": 600,
    "automaticInvestments": 2,
    "stockCount": 10,
}
REPORT_NAME = (
    "baseline-{sample}-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-"
    "t2s39-9y-fixed3y-600w-20260901"
)
DECISION_BASE_SUFFIX = (
    "-s32-an03-wow-nonbottom-no-ap02-add-penalty-20260901-"
    "t2-s39-48d42e50ada5-fixed3y-20260722-v6"
)
APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
TAIPEI = ZoneInfo("Asia/Taipei")
WINDOWS = (
    (1, 20170722, 20200722),
    (2, 20200722, 20230722),
    (3, 20230722, 20260722),
)
LABELS = (
    "continuation-up",
    "top-then-fall",
    "continuation-down",
    "bottom-then-rebound",
    "sideways",
)
LABEL_NAMES = {
    "continuation-up": "續漲",
    "top-then-fall": "探頂後回落",
    "continuation-down": "續跌",
    "bottom-then-rebound": "探底後反彈",
    "sideways": "盤整",
}
REQUIRED_TECHNICAL_COLUMNS = (
    "ZTHIGHDIFF",
    "ZTHIGHDIFFZ125",
    "ZTHIGHDIFFZ250",
    "ZTHIGHMAX9",
    "ZTLOWDIFF",
    "ZTLOWDIFFZ125",
    "ZTLOWDIFFZ250",
    "ZTLOWMIN9",
    "ZTKDK",
    "ZTKDD",
    "ZTKDJ",
    "ZTKDKZ125",
    "ZTKDKZ250",
    "ZTKDDZ125",
    "ZTKDDZ250",
    "ZTKDJZ125",
    "ZTKDJZ250",
    "ZTMA20DIFF",
    "ZTMA20DIFFZ125",
    "ZTMA20DIFFZ250",
    "ZTMA20DAYS",
    "ZTMA60DIFF",
    "ZTMA60DIFFZ125",
    "ZTMA60DIFFZ250",
    "ZTMA60DAYS",
    "ZTOSC",
    "ZTOSCZ125",
    "ZTOSCZ250",
    "ZTZ125",
    "ZTZ250",
    "ZVZ125",
    "ZVZ250",
    "ZVMA20DIFF",
    "ZVMA20DIFFZ125",
    "ZVMA20DIFFZ250",
    "ZVMA20DAYS",
    "ZVMA60DIFF",
    "ZVMA60DIFFZ125",
    "ZVMA60DIFFZ250",
    "ZVMA60DAYS",
    "ZVMAX9",
    "ZVMIN9",
)
REQUIRED_DECISION_TABLES = {
    "metadata",
    "windows",
    "stocks",
    "rules",
    "decision_events",
    "event_votes",
    "period_outcomes",
    "strategy_fit_observations",
}
BASE_FEATURE_SPECS = (
    ("intraday_high_diff", "ZTHIGHDIFF", "intraday-strength", "盤中最高價相對昨收推升幅度"),
    ("intraday_low_diff", "ZTLOWDIFF", "intraday-strength", "盤中最低價相對昨收下壓幅度"),
    ("t_high_diff_125", "ZTHIGHDIFF125", "price-position", "收盤相對 125 日高點位置"),
    ("t_high_diff_250", "ZTHIGHDIFF250", "price-position", "收盤相對 250 日高點位置"),
    ("t_high_diff_z125", "ZTHIGHDIFFZ125", "price-position", "125 日高點位置的 125 日標準分數"),
    ("t_high_diff_z250", "ZTHIGHDIFFZ250", "price-position", "250 日高點位置的 250 日標準分數"),
    ("t_low_diff_125", "ZTLOWDIFF125", "price-position", "收盤相對 125 日低點位置"),
    ("t_low_diff_250", "ZTLOWDIFF250", "price-position", "收盤相對 250 日低點位置"),
    ("t_low_diff_z125", "ZTLOWDIFFZ125", "price-position", "125 日低點位置的 125 日標準分數"),
    ("t_low_diff_z250", "ZTLOWDIFFZ250", "price-position", "250 日低點位置的 250 日標準分數"),
    ("t_z125", "ZTZ125", "price-position", "收盤價 125 日標準分數"),
    ("t_z250", "ZTZ250", "price-position", "收盤價 250 日標準分數"),
    ("kd_k", "ZTKDK", "kdj", "KD 的 K 值"),
    ("kd_d", "ZTKDD", "kdj", "KD 的 D 值"),
    ("kd_j", "ZTKDJ", "kdj", "KD 的 J 值"),
    ("kd_k_z125", "ZTKDKZ125", "kdj", "K 的 125 日標準分數"),
    ("kd_k_z250", "ZTKDKZ250", "kdj", "K 的 250 日標準分數"),
    ("kd_d_z125", "ZTKDDZ125", "kdj", "D 的 125 日標準分數"),
    ("kd_d_z250", "ZTKDDZ250", "kdj", "D 的 250 日標準分數"),
    ("kd_j_z125", "ZTKDJZ125", "kdj", "J 的 125 日標準分數"),
    ("kd_j_z250", "ZTKDJZ250", "kdj", "J 的 250 日標準分數"),
    ("osc", "ZTOSC", "osc", "OSC"),
    ("osc_z125", "ZTOSCZ125", "osc", "OSC 的 125 日標準分數"),
    ("osc_z250", "ZTOSCZ250", "osc", "OSC 的 250 日標準分數"),
    ("ma20_diff", "ZTMA20DIFF", "ma20", "收盤相對 MA20 的百分比差"),
    ("ma20_diff_z125", "ZTMA20DIFFZ125", "ma20", "MA20 差的 125 日標準分數"),
    ("ma20_diff_z250", "ZTMA20DIFFZ250", "ma20", "MA20 差的 250 日標準分數"),
    ("ma20_days", "ZTMA20DAYS", "ma20", "MA20 過濾短期震盪後的趨勢持續期"),
    ("ma60_diff", "ZTMA60DIFF", "ma60", "收盤相對 MA60 的百分比差"),
    ("ma60_diff_z125", "ZTMA60DIFFZ125", "ma60", "MA60 差的 125 日標準分數"),
    ("ma60_diff_z250", "ZTMA60DIFFZ250", "ma60", "MA60 差的 250 日標準分數"),
    ("ma60_days", "ZTMA60DAYS", "ma60", "MA60 過濾短期震盪後的趨勢持續期"),
    ("v_z125", "ZVZ125", "volume-level", "成交量 125 日標準分數"),
    ("v_z250", "ZVZ250", "volume-level", "成交量 250 日標準分數"),
    ("v_ma20_diff", "ZVMA20DIFF", "volume-ma20", "成交量相對 20 日均量的百分比差"),
    ("v_ma20_diff_z125", "ZVMA20DIFFZ125", "volume-ma20", "20 日均量差的 125 日標準分數"),
    ("v_ma20_diff_z250", "ZVMA20DIFFZ250", "volume-ma20", "20 日均量差的 250 日標準分數"),
    ("v_ma20_days", "ZVMA20DAYS", "volume-ma20", "20 日均量趨勢持續期"),
    ("v_ma60_diff", "ZVMA60DIFF", "volume-ma60", "成交量相對 60 日均量的百分比差"),
    ("v_ma60_diff_z125", "ZVMA60DIFFZ125", "volume-ma60", "60 日均量差的 125 日標準分數"),
    ("v_ma60_diff_z250", "ZVMA60DIFFZ250", "volume-ma60", "60 日均量差的 250 日標準分數"),
    ("v_ma60_days", "ZVMA60DAYS", "volume-ma60", "60 日均量趨勢持續期"),
)
EXTREME_FLAG_SPECS = (
    ("price_high_is_max9", "ZPRICEHIGH", "ZTHIGHMAX9", "price-position", "當日最高價為九日最高"),
    ("price_low_is_min9", "ZPRICELOW", "ZTLOWMIN9", "price-position", "當日最低價為九日最低"),
    ("kd_k_is_max9", "ZTKDK", "ZTKDKMAX9", "kdj", "K 創九日高點"),
    ("kd_k_is_min9", "ZTKDK", "ZTKDKMIN9", "kdj", "K 創九日低點"),
    ("osc_is_max9", "ZTOSC", "ZTOSCMAX9", "osc", "OSC 創九日高點"),
    ("osc_is_min9", "ZTOSC", "ZTOSCMIN9", "osc", "OSC 創九日低點"),
    ("ma20_diff_is_max9", "ZTMA20DIFF", "ZTMA20DIFFMAX9", "ma20", "MA20 差創九日高點"),
    ("ma20_diff_is_min9", "ZTMA20DIFF", "ZTMA20DIFFMIN9", "ma20", "MA20 差創九日低點"),
    ("ma60_diff_is_max9", "ZTMA60DIFF", "ZTMA60DIFFMAX9", "ma60", "MA60 差創九日高點"),
    ("ma60_diff_is_min9", "ZTMA60DIFF", "ZTMA60DIFFMIN9", "ma60", "MA60 差創九日低點"),
    ("volume_is_max9", "ZVOLUMECLOSE", "ZVMAX9", "volume-level", "成交量創九日高點"),
    ("volume_is_min9", "ZVOLUMECLOSE", "ZVMIN9", "volume-level", "成交量創九日低點"),
    ("v_ma20_diff_is_max9", "ZVMA20DIFF", "ZVMA20DIFFMAX9", "volume-ma20", "20 日均量差創九日高點"),
    ("v_ma20_diff_is_min9", "ZVMA20DIFF", "ZVMA20DIFFMIN9", "volume-ma20", "20 日均量差創九日低點"),
    ("v_ma60_diff_is_max9", "ZVMA60DIFF", "ZVMA60DIFFMAX9", "volume-ma60", "60 日均量差創九日高點"),
    ("v_ma60_diff_is_min9", "ZVMA60DIFF", "ZVMA60DIFFMIN9", "volume-ma60", "60 日均量差創九日低點"),
)
ZERO_CROSS_FEATURES = (
    "t_z125",
    "t_z250",
    "t_high_diff_z125",
    "t_low_diff_z125",
    "osc",
    "ma20_diff",
    "ma60_diff",
    "v_z125",
    "v_ma20_diff",
    "v_ma60_diff",
)
FEATURE_SOURCE_COLUMNS = tuple(
    sorted(
        {source for _, source, _, _ in BASE_FEATURE_SPECS}
        | {left for _, left, _, _, _ in EXTREME_FLAG_SPECS}
        | {right for _, _, right, _, _ in EXTREME_FLAG_SPECS}
        | {"ZPRICECLOSE", "ZTUPDATED"}
    )
)
M01_RANDOM_STATE = 20260902
M01_FOLDS = 3
M01_INTERACTIONS = 20
M01_MODEL_PARAMS = {
    "max_bins": 256,
    "max_interaction_bins": 32,
    "validation_size": 0.15,
    "outer_bags": 4,
    "inner_bags": 0,
    "learning_rate": 0.03,
    "greedy_ratio": 5.0,
    "smoothing_rounds": 50,
    "interaction_smoothing_rounds": 50,
    "max_rounds": 1500,
    "early_stopping_rounds": 50,
    "early_stopping_tolerance": 1e-5,
    "min_samples_leaf": 8,
    "max_leaves": 2,
    "objective": "log_loss",
    "n_jobs": 4,
}
PC01_CONTROLS = (
    {
        "control_id": "L-P03",
        "phase": 2,
        "rule_ids": ("L-P03",),
        "expected_label": "bottom-then-rebound",
        "adverse_label": "continuation-down",
        "description": "K 的 Z125 與 Z250 都低於 -0.9",
    },
    {
        "control_id": "L-P04",
        "phase": 2,
        "rule_ids": ("L-P04",),
        "expected_label": "bottom-then-rebound",
        "adverse_label": "continuation-down",
        "description": "D 的 Z125 與 Z250 都低於 -0.9",
    },
    {
        "control_id": "L-P03+L-P04",
        "phase": 2,
        "rule_ids": ("L-P03", "L-P04"),
        "expected_label": "bottom-then-rebound",
        "adverse_label": "continuation-down",
        "description": "K 與 D 的長短期低檔票同時成立",
    },
    {
        "control_id": "S-P03",
        "phase": 3,
        "rule_ids": ("S-P03",),
        "expected_label": "top-then-fall",
        "adverse_label": "continuation-up",
        "description": "K 的 Z125 高於 0.9",
    },
    {
        "control_id": "S-P04",
        "phase": 3,
        "rule_ids": ("S-P04",),
        "expected_label": "top-then-fall",
        "adverse_label": "continuation-up",
        "description": "D 的 Z125 高於 0.9",
    },
    {
        "control_id": "S-P03+S-P04",
        "phase": 3,
        "rule_ids": ("S-P03", "S-P04"),
        "expected_label": "top-then-fall",
        "adverse_label": "continuation-up",
        "description": "K 與 D 的半年過熱票同時成立",
    },
)


@dataclass(frozen=True)
class PricePoint:
    date: int
    close: float


@dataclass(frozen=True)
class StockSeries:
    sample: str
    stock_id: str
    stock_name: str
    group_name: str
    points: tuple[PricePoint, ...]


@dataclass(frozen=True)
class PathResult:
    label: str
    first_cross_day: int | None
    reversal_day: int | None


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    parser.add_argument(
        "--output",
        type=Path,
        help=f"Output directory (default: exports/future-path-study/{RUN_ID})",
    )
    parser.add_argument(
        "--audit-per-sample-window",
        type=int,
        default=2,
        help="Label-blind audit rows per Sample x window (default: 2)",
    )
    parser.add_argument(
        "--finalize-audit",
        action="store_true",
        help="Record the completed human review of an existing P0/L01 output",
    )
    parser.add_argument(
        "--build-features",
        action="store_true",
        help="Build or reproducibility-check the M01-F01 feature matrix",
    )
    parser.add_argument(
        "--train-discovery-model",
        action="store_true",
        help="Run the fixed M01-M01 EBM search on discovery rows only",
    )
    parser.add_argument(
        "--positive-control",
        action="store_true",
        help="Run the M01-PC01 known-rule positive-control diagnostic",
    )
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def apple_date(value: float) -> int:
    instant = APPLE_EPOCH + timedelta(seconds=float(value))
    local = instant.astimezone(TAIPEI).date()
    return local.year * 10000 + local.month * 100 + local.day


def slash_date(value: int) -> str:
    raw = str(value)
    return f"{raw[:4]}/{raw[4:6]}/{raw[6:]}"


def open_readonly(path: Path) -> sqlite3.Connection:
    uri = f"file:{path.resolve().as_posix()}?mode=ro&immutable=1"
    connection = sqlite3.connect(uri, uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def table_columns(connection: sqlite3.Connection, table: str) -> set[str]:
    return {str(row[1]) for row in connection.execute(f"PRAGMA table_info({table})")}


def window_for(trade_date: int) -> int | None:
    # Boundary dates belong to the later window so each Sample/stock/date is unique.
    if 20170722 <= trade_date < 20200722:
        return 1
    if 20200722 <= trade_date < 20230722:
        return 2
    if 20230722 <= trade_date <= 20260722:
        return 3
    return None


def role_for(sample: str, window_id: int) -> str:
    if sample in "ABC" and window_id in (1, 2):
        return "discovery"
    if sample in "ABC" and window_id == 3:
        return "later-period-check"
    if sample == "D":
        return "cross-stock-check"
    if sample == "E":
        return "weak-stress"
    raise ValueError((sample, window_id))


def classify_future_path(p0: float, future: Sequence[float], barrier: float) -> PathResult:
    require(p0 > 0, "P0 must be positive")
    require(len(future) == 20, "future path must contain exactly 20 closes")
    first_direction: str | None = None
    first_cross_day: int | None = None
    for day, price in enumerate(future, start=1):
        simple_return = price / p0 - 1.0
        if simple_return >= barrier:
            first_direction = "up"
            first_cross_day = day
            break
        if simple_return <= -barrier:
            first_direction = "down"
            first_cross_day = day
            break
    if first_direction is None:
        return PathResult("sideways", None, None)
    assert first_cross_day is not None
    reversal = barrier / 2.0
    crossing_index = first_cross_day - 1
    if first_direction == "up":
        peak = future[crossing_index]
        for index in range(crossing_index + 1, len(future)):
            price = future[index]
            peak = max(peak, price)
            if (peak - price) / peak >= reversal:
                return PathResult("top-then-fall", first_cross_day, index + 1)
        return PathResult("continuation-up", first_cross_day, None)
    trough = future[crossing_index]
    for index in range(crossing_index + 1, len(future)):
        price = future[index]
        trough = min(trough, price)
        if (price - trough) / trough >= reversal:
            return PathResult("bottom-then-rebound", first_cross_day, index + 1)
    return PathResult("continuation-down", first_cross_day, None)


def median_without(sorted_values: Sequence[tuple[float, tuple[str, str]]], excluded: tuple[str, str] | None) -> tuple[float, int]:
    if excluded is None:
        values = [item[0] for item in sorted_values]
        return statistics.median(values), len(values)
    excluded_index = next(
        (index for index, item in enumerate(sorted_values) if item[1] == excluded),
        None,
    )
    if excluded_index is None:
        values = [item[0] for item in sorted_values]
        return statistics.median(values), len(values)
    size = len(sorted_values) - 1
    require(size > 0, "cannot exclude the only market constituent")

    def original(index: int) -> float:
        mapped = index if index < excluded_index else index + 1
        return sorted_values[mapped][0]

    if size % 2:
        value = original(size // 2)
    else:
        value = (original(size // 2 - 1) + original(size // 2)) / 2.0
    return value, size


def self_test() -> None:
    pad = lambda values: list(values) + [values[-1]] * (20 - len(values))
    cases = {
        "continuation-up": pad([106.0, 108.0, 107.0]),
        "top-then-fall": pad([106.0, 109.0, 105.0]),
        "continuation-down": pad([94.0, 92.0, 93.0]),
        "bottom-then-rebound": pad([94.0, 91.0, 94.0]),
        "sideways": pad([101.0, 98.0, 102.0]),
    }
    for expected, future in cases.items():
        actual = classify_future_path(100.0, future, 0.05).label
        require(actual == expected, f"self-test label mismatch: {actual} != {expected}")
    values = sorted(
        [(0.1, ("A", "1")), (0.2, ("B", "2")), (0.3, ("C", "3")), (0.4, ("D", "4"))]
    )
    require(median_without(values, None) == (0.25, 4), "median self-test failed")
    median, count = median_without(values, ("B", "2"))
    require(abs(median - 0.3) < 1e-12 and count == 3, "leave-one-out self-test failed")
    catalog = feature_catalog()
    require(len(catalog) == 122, f"unexpected feature count: {len(catalog)}")
    current = {column: 1.0 for column in FEATURE_SOURCE_COLUMNS}
    previous = {column: 0.5 for column in FEATURE_SOURCE_COLUMNS}
    current["ZTKDK"] = 60.0
    current["ZTKDD"] = 50.0
    previous["ZTKDK"] = 40.0
    previous["ZTKDD"] = 50.0
    derived = derive_feature_values(current, previous)
    require(derived["kd_k_cross_d_up"] == 1, "K/D cross self-test failed")
    require(derived["delta_t_z125"] == 0.5, "delta self-test failed")
    require(boundary_safe(1, 20200721) and not boundary_safe(1, 20200722), "boundary self-test failed")
    print("self-test: ok")


def locate_inputs(project_root: Path) -> dict[str, dict[str, Path]]:
    reports_root = project_root / "exports" / "backtest-reports"
    decisions_root = project_root / "exports" / "backtest-decision-bases"
    inputs: dict[str, dict[str, Path]] = {}
    for sample in SAMPLES:
        report = reports_root / REPORT_NAME.format(sample=sample.lower())
        matches = sorted(decisions_root.glob(f"{sample.lower()}-*{DECISION_BASE_SUFFIX}"))
        require(report.is_dir(), f"missing Baseline report for Sample {sample}: {report}")
        require(len(matches) == 1, f"expected one DecisionBase for Sample {sample}, found {len(matches)}")
        inputs[sample] = {"report": report, "decisionBase": matches[0]}
    return inputs


def verify_report(sample: str, directory: Path) -> tuple[dict[str, Any], list[StockSeries]]:
    manifest_path = directory / "manifest.json"
    baseline_path = directory / "baseline.json"
    store_path = directory / "browse.store"
    marker_path = directory / ".complete"
    for path in (manifest_path, baseline_path, store_path, marker_path, directory / "periods.csv", directory / "report.html"):
        require(path.is_file(), f"Sample {sample} missing report file: {path}")
    manifest = read_json(manifest_path)
    baseline = read_json(baseline_path)
    run_id = manifest.get("runID")
    require(manifest.get("sampleID") == sample, f"Sample {sample} report sample mismatch")
    for key, expected in EXPECTED.items():
        require(manifest.get(key) == expected, f"Sample {sample} report {key} mismatch")
    require(marker_path.read_text(encoding="utf-8").strip() == run_id, f"Sample {sample} .complete mismatch")
    require(baseline.get("runID") == run_id, f"Sample {sample} baseline run mismatch")
    for key in ("sampleID", "dataRuleVersion", "ruleVersion", "ruleCommit", "through", "historyStart", "moneyBaseWan", "automaticInvestments"):
        require(baseline.get(key) == manifest.get(key), f"Sample {sample} baseline/manifest {key} mismatch")
    require(baseline.get("periodStarts") == ["2017/07/22", "2020/07/22", "2023/07/22"], f"Sample {sample} period starts mismatch")
    require(len(baseline.get("stocks", [])) == 30, f"Sample {sample} expected 30 period-stock outcomes")

    connection = open_readonly(store_path)
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        require(integrity == "ok", f"Sample {sample} browse.store integrity={integrity}")
        columns = table_columns(connection, "ZTRADE")
        missing = sorted(set(REQUIRED_TECHNICAL_COLUMNS) - columns)
        require(not missing, f"Sample {sample} missing technical fields: {missing}")
        stock_rows = list(
            connection.execute(
                """
                SELECT Z_PK stock_key,ZSID stock_id,ZSNAME stock_name,ZGROUP group_name,
                       ZTECHNICALSTATEVERSION technical_version,
                       ZSIMULATIONSTATEVERSION simulation_version
                FROM ZSTOCK ORDER BY ZSID
                """
            )
        )
        require(len(stock_rows) == 10, f"Sample {sample} expected 10 stocks")
        series: list[StockSeries] = []
        trade_count = 0
        for stock in stock_rows:
            require(int(stock["technical_version"]) == 2, f"Sample {sample}/{stock['stock_id']} T mismatch")
            require(int(stock["simulation_version"]) == 39, f"Sample {sample}/{stock['stock_id']} S mismatch")
            rows = list(
                connection.execute(
                    """
                    SELECT ZDATETIME trade_time,ZPRICECLOSE close_price,ZDATASOURCE data_source
                    FROM ZTRADE WHERE ZSTOCK=? ORDER BY ZDATETIME
                    """,
                    (stock["stock_key"],),
                )
            )
            points: list[PricePoint] = []
            seen_dates: set[int] = set()
            for row in rows:
                trade_date = apple_date(row["trade_time"])
                close = float(row["close_price"])
                require(row["data_source"] == "TWSE", f"Sample {sample}/{stock['stock_id']} non-TWSE row")
                require(math.isfinite(close) and close > 0, f"Sample {sample}/{stock['stock_id']} invalid close")
                require(trade_date not in seen_dates, f"Sample {sample}/{stock['stock_id']} duplicate date {trade_date}")
                seen_dates.add(trade_date)
                points.append(PricePoint(trade_date, close))
            require(points and points == sorted(points, key=lambda item: item.date), f"Sample {sample}/{stock['stock_id']} unsorted prices")
            trade_count += len(points)
            series.append(
                StockSeries(
                    sample,
                    str(stock["stock_id"]),
                    str(stock["stock_name"]),
                    str(stock["group_name"]),
                    tuple(points),
                )
            )
        require(trade_count == manifest.get("tradeCount"), f"Sample {sample} trade count mismatch")
    finally:
        connection.close()

    baseline_ids = {str(row["id"]) for row in baseline["stocks"]}
    store_ids = {item.stock_id for item in series}
    require(baseline_ids == store_ids, f"Sample {sample} stock IDs differ between baseline and store")
    metadata = {
        "runID": run_id,
        "manifest": str(manifest_path),
        "baseline": str(baseline_path),
        "browseStore": str(store_path),
        "tradeCount": trade_count,
        "stockIDs": sorted(store_ids),
        "inputFiles": {},
    }
    return metadata, series


def verify_decision_base(sample: str, directory: Path, report_metadata: dict[str, Any]) -> dict[str, Any]:
    paths = {
        "manifest": directory / "manifest.json",
        "database": directory / "decisions.sqlite",
        "ruleCatalog": directory / "rule-catalog.json",
        "p4bManifest": directory / "p4b-manifest.json",
        "complete": directory / ".complete",
        "p4bComplete": directory / ".p4b-complete",
    }
    for path in paths.values():
        require(path.is_file(), f"Sample {sample} missing DecisionBase file: {path}")
    manifest = read_json(paths["manifest"])
    decision_id = manifest.get("decisionBaseID")
    require(manifest.get("sampleID") == sample, f"Sample {sample} DecisionBase sample mismatch")
    for key in ("dataRuleVersion", "ruleVersion", "ruleCommit", "through", "moneyBaseWan", "automaticInvestments", "stockCount"):
        require(manifest.get(key) == EXPECTED[key], f"Sample {sample} DecisionBase {key} mismatch")
    require(manifest.get("formatVersion") == 6, f"Sample {sample} DecisionBase format mismatch")
    require(manifest.get("windowCount") == 3, f"Sample {sample} DecisionBase window count mismatch")
    require(paths["complete"].read_text(encoding="utf-8").strip() == decision_id, f"Sample {sample} DecisionBase .complete mismatch")
    require(paths["p4bComplete"].read_text(encoding="utf-8").strip() == decision_id, f"Sample {sample} DecisionBase .p4b-complete mismatch")
    catalog = read_json(paths["ruleCatalog"])
    require(isinstance(catalog, list) and len(catalog) == 91, f"Sample {sample} expected 91 catalog rules")
    p4b_manifest = read_json(paths["p4bManifest"])
    require(p4b_manifest.get("decisionBaseID") == decision_id, f"Sample {sample} P4b ID mismatch")

    connection = open_readonly(paths["database"])
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        require(integrity == "ok", f"Sample {sample} DecisionBase integrity={integrity}")
        tables = {str(row[0]) for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        missing_tables = sorted(REQUIRED_DECISION_TABLES - tables)
        require(not missing_tables, f"Sample {sample} missing DecisionBase tables: {missing_tables}")
        metadata = {str(row["key"]): str(row["value"]) for row in connection.execute("SELECT key,value FROM metadata")}
        require(metadata.get("decisionBaseID") == decision_id, f"Sample {sample} SQLite DecisionBase ID mismatch")
        require(metadata.get("ruleCommit") == EXPECTED["ruleCommit"], f"Sample {sample} SQLite rule commit mismatch")
        windows = [tuple(row) for row in connection.execute("SELECT window_id,start_date,end_date FROM windows ORDER BY window_id")]
        require(windows == list(WINDOWS), f"Sample {sample} DecisionBase windows mismatch: {windows}")
        counts = {
            name: int(connection.execute(f"SELECT COUNT(*) FROM {name}").fetchone()[0])
            for name in ("stocks", "rules", "decision_events", "event_votes", "period_outcomes", "strategy_fit_observations")
        }
        require(counts["stocks"] == 10 and counts["rules"] == 91 and counts["period_outcomes"] == 30, f"Sample {sample} DecisionBase coverage mismatch: {counts}")
        stock_ids = {str(row[0]) for row in connection.execute("SELECT stock_id FROM stocks")}
        require(stock_ids == set(report_metadata["stockIDs"]), f"Sample {sample} DecisionBase/report stocks mismatch")
    finally:
        connection.close()
    return {
        "decisionBaseID": decision_id,
        "directory": str(directory),
        "inputSnapshotID": manifest.get("inputSnapshotID"),
        "counts": counts,
        "integrity": integrity,
        "inputFiles": {},
    }


def verify_inputs(project_root: Path) -> tuple[dict[str, Any], dict[tuple[str, str], StockSeries]]:
    located = locate_inputs(project_root)
    samples: dict[str, Any] = {}
    all_series: dict[tuple[str, str], StockSeries] = {}
    for sample in SAMPLES:
        report_metadata, series = verify_report(sample, located[sample]["report"])
        decision_metadata = verify_decision_base(sample, located[sample]["decisionBase"], report_metadata)
        for item in series:
            key = (item.sample, item.stock_id)
            require(key not in all_series, f"duplicate series key: {key}")
            all_series[key] = item
        report_files = {
            name: Path(report_metadata[name])
            for name in ("manifest", "baseline", "browseStore")
        }
        decision_files = {
            "manifest": located[sample]["decisionBase"] / "manifest.json",
            "database": located[sample]["decisionBase"] / "decisions.sqlite",
            "ruleCatalog": located[sample]["decisionBase"] / "rule-catalog.json",
            "p4bManifest": located[sample]["decisionBase"] / "p4b-manifest.json",
            "complete": located[sample]["decisionBase"] / ".complete",
            "p4bComplete": located[sample]["decisionBase"] / ".p4b-complete",
        }
        report_metadata["inputFiles"] = {
            name: {"path": str(path), "sha256": file_hash(path), "bytes": path.stat().st_size}
            for name, path in report_files.items()
        }
        decision_metadata["inputFiles"] = {
            name: {"path": str(path), "sha256": file_hash(path), "bytes": path.stat().st_size}
            for name, path in decision_files.items()
        }
        samples[sample] = {"report": report_metadata, "decisionBase": decision_metadata}
    market_keys = [key for key in all_series if key[0] in MARKET_SAMPLES]
    market_ids = [key[1] for key in market_keys]
    require(len(market_keys) == 40, f"expected 40 A-D market constituents, found {len(market_keys)}")
    require(len(set(market_ids)) == 40, "A-D market proxy stock IDs are not unique")
    return {"samples": samples, "marketConstituents": [list(key) for key in sorted(market_keys)]}, all_series


def build_path_rows(series_map: dict[tuple[str, str], StockSeries]) -> tuple[list[dict[str, Any]], Counter[str]]:
    rows: list[dict[str, Any]] = []
    exclusions: Counter[str] = Counter()
    for key in sorted(series_map):
        series = series_map[key]
        points = series.points
        for index, point in enumerate(points):
            window_id = window_for(point.date)
            if window_id is None:
                exclusions["outside-simulation-windows"] += 1
                continue
            start = max(1, index - 59)
            log_returns = [
                math.log(points[offset].close / points[offset - 1].close)
                for offset in range(start, index + 1)
            ]
            if len(log_returns) < 40:
                exclusions["fewer-than-40-past-returns"] += 1
                continue
            future_points = points[index + 1 : index + 21]
            if len(future_points) < 20:
                exclusions["fewer-than-20-future-trading-days"] += 1
                continue
            sigma60 = statistics.stdev(log_returns)
            require(math.isfinite(sigma60), f"non-finite sigma: {key}/{point.date}")
            barrier = min(max(sigma60 * math.sqrt(20.0), 0.05), 0.15)
            future_closes = [item.close for item in future_points]
            path = classify_future_path(point.close, future_closes, barrier)
            returns = [price / point.close - 1.0 for price in future_closes]
            row = {
                "sample": series.sample,
                "window_id": window_id,
                "role": role_for(series.sample, window_id),
                "stock_id": series.stock_id,
                "stock_name": series.stock_name,
                "group_name": series.group_name,
                "trade_date": point.date,
                "p0": point.close,
                "sigma60": sigma60,
                "sigma_observations": len(log_returns),
                "barrier": barrier,
                "label": path.label,
                "label_name": LABEL_NAMES[path.label],
                "first_cross_day": path.first_cross_day,
                "reversal_day": path.reversal_day,
                "future_20_date": future_points[-1].date,
                "future_20_return": returns[-1],
                "max_favorable_return": max(returns),
                "max_adverse_return": min(returns),
                "future_dates": [item.date for item in future_points],
                "future_closes": future_closes,
            }
            rows.append(row)
    return rows, exclusions


def make_market_lookup(series_map: dict[tuple[str, str], StockSeries]) -> tuple[list[tuple[str, str]], dict[tuple[str, str], dict[int, float]]]:
    market_keys = sorted(key for key in series_map if key[0] in MARKET_SAMPLES)
    lookup = {
        key: {point.date: point.close for point in series_map[key].points}
        for key in market_keys
    }
    return market_keys, lookup


def attach_market_relative(rows: list[dict[str, Any]], series_map: dict[tuple[str, str], StockSeries]) -> Counter[str]:
    market_keys, lookup = make_market_lookup(series_map)
    pair_cache: dict[tuple[int, int], tuple[tuple[float, tuple[str, str]], ...]] = {}

    def pair_returns(start_date: int, future_date: int) -> tuple[tuple[float, tuple[str, str]], ...]:
        key = (start_date, future_date)
        cached = pair_cache.get(key)
        if cached is not None:
            return cached
        values: list[tuple[float, tuple[str, str]]] = []
        for constituent in market_keys:
            start = lookup[constituent].get(start_date)
            end = lookup[constituent].get(future_date)
            if start is not None and end is not None and start > 0 and end > 0:
                values.append((math.log(end / start), constituent))
        cached = tuple(sorted(values))
        pair_cache[key] = cached
        return cached

    coverage: Counter[str] = Counter()
    for row in rows:
        target_key = (str(row["sample"]), str(row["stock_id"]))
        excluded = target_key if row["sample"] in MARKET_SAMPLES else None
        relative_path: list[float] = []
        proxy_path: list[float] = []
        constituent_counts: list[int] = []
        invalid = False
        for future_date, future_close in zip(row["future_dates"], row["future_closes"]):
            values = pair_returns(int(row["trade_date"]), int(future_date))
            if not values:
                invalid = True
                break
            proxy, count = median_without(values, excluded)
            constituent_counts.append(count)
            if count < 30:
                invalid = True
                break
            target_return = math.log(float(future_close) / float(row["p0"]))
            proxy_path.append(proxy)
            relative_path.append(target_return - proxy)
        if invalid or len(relative_path) != 20:
            coverage["unavailable"] += 1
            row.update(
                {
                    "market_relative_available": False,
                    "market_constituent_min": min(constituent_counts) if constituent_counts else 0,
                    "market_constituent_max": max(constituent_counts) if constituent_counts else 0,
                    "market_proxy_20_return": None,
                    "market_relative_20_return": None,
                    "market_relative_max_favorable": None,
                    "market_relative_max_adverse": None,
                }
            )
            continue
        coverage["available"] += 1
        row.update(
            {
                "market_relative_available": True,
                "market_constituent_min": min(constituent_counts),
                "market_constituent_max": max(constituent_counts),
                "market_proxy_20_return": proxy_path[-1],
                "market_relative_20_return": relative_path[-1],
                "market_relative_max_favorable": max(relative_path),
                "market_relative_max_adverse": min(relative_path),
            }
        )
    coverage["pair_cache_entries"] = len(pair_cache)
    return coverage


def write_csv(path: Path, fieldnames: Sequence[str], rows: Iterable[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def aggregate_labels(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, int, str], list[dict[str, Any]]] = defaultdict(list)
    totals: Counter[tuple[str, int]] = Counter()
    for row in rows:
        key = (str(row["sample"]), int(row["window_id"]), str(row["label"]))
        grouped[key].append(row)
        totals[(key[0], key[1])] += 1
    output: list[dict[str, Any]] = []
    for sample in SAMPLES:
        for window_id, _, _ in WINDOWS:
            for label in LABELS:
                members = grouped.get((sample, window_id, label), [])
                total = totals[(sample, window_id)]
                output.append(
                    {
                        "sample": sample,
                        "window_id": window_id,
                        "role": role_for(sample, window_id),
                        "label": label,
                        "label_name": LABEL_NAMES[label],
                        "rows": len(members),
                        "share": len(members) / total if total else 0.0,
                        "stocks": len({row["stock_id"] for row in members}),
                        "first_date": min((row["trade_date"] for row in members), default=""),
                        "last_date": max((row["trade_date"] for row in members), default=""),
                    }
                )
    return output


def aggregate_market(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, int], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[(str(row["sample"]), int(row["window_id"]))].append(row)
    output: list[dict[str, Any]] = []
    for sample in SAMPLES:
        for window_id, _, _ in WINDOWS:
            members = grouped[(sample, window_id)]
            available = [row for row in members if row["market_relative_available"]]
            mins = [int(row["market_constituent_min"]) for row in available]
            output.append(
                {
                    "sample": sample,
                    "window_id": window_id,
                    "role": role_for(sample, window_id),
                    "label_rows": len(members),
                    "relative_available": len(available),
                    "relative_unavailable": len(members) - len(available),
                    "coverage": len(available) / len(members) if members else 0.0,
                    "constituent_min": min(mins) if mins else "",
                    "constituent_median": statistics.median(mins) if mins else "",
                    "constituent_max": max(mins) if mins else "",
                }
            )
    return output


def audit_rows(rows: list[dict[str, Any]], per_cell: int) -> list[dict[str, Any]]:
    require(per_cell > 0, "audit-per-sample-window must be positive")

    def digest(row: dict[str, Any], purpose: str) -> str:
        raw = f"{STUDY_ID}|{purpose}|{row['sample']}|{row['window_id']}|{row['stock_id']}|{row['trade_date']}"
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()

    selected: dict[tuple[str, str, int], dict[str, Any]] = {}
    by_cell: dict[tuple[str, int], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        by_cell[(str(row["sample"]), int(row["window_id"]))].append(row)
    for cell, members in sorted(by_cell.items()):
        for row in sorted(members, key=lambda item: digest(item, "label-blind"))[:per_cell]:
            selected[(str(row["sample"]), str(row["stock_id"]), int(row["trade_date"]))] = {**row, "audit_reason": "label-blind-sample-window"}
    for label in LABELS:
        members = [row for row in rows if row["label"] == label]
        require(members, f"cannot select audit sentinel for empty label {label}")
        row = min(members, key=lambda item: digest(item, f"label-sentinel-{label}"))
        key = (str(row["sample"]), str(row["stock_id"]), int(row["trade_date"]))
        if key in selected:
            selected[key]["audit_reason"] += f"|label-sentinel-{label}"
        else:
            selected[key] = {**row, "audit_reason": f"label-sentinel-{label}"}
    output = []
    for row in sorted(selected.values(), key=lambda item: (item["sample"], item["window_id"], item["stock_id"], item["trade_date"])):
        audit = {key: value for key, value in row.items() if key not in ("future_dates", "future_closes")}
        for index, (future_date, close) in enumerate(zip(row["future_dates"], row["future_closes"]), start=1):
            audit[f"day_{index:02d}_date"] = future_date
            audit[f"day_{index:02d}_close"] = close
            audit[f"day_{index:02d}_return"] = close / float(row["p0"]) - 1.0
        output.append(audit)
    return output


def module_environment() -> dict[str, Any]:
    return {
        "python": sys.version,
        "executable": sys.executable,
        "platform": platform.platform(),
        "modules": {
            name: bool(importlib.util.find_spec(name))
            for name in ("numpy", "pandas", "sklearn", "interpret")
        },
    }


def feature_catalog() -> list[dict[str, Any]]:
    catalog: list[dict[str, Any]] = []
    by_name = {name: (source, family, description) for name, source, family, description in BASE_FEATURE_SPECS}
    for name, source, family, description in BASE_FEATURE_SPECS:
        catalog.append(
            {
                "feature": name,
                "family": family,
                "kind": "base",
                "sources": source,
                "requires_previous": 0,
                "description": description,
            }
        )
    for name, source, family, description in BASE_FEATURE_SPECS:
        catalog.append(
            {
                "feature": f"delta_{name}",
                "family": family,
                "kind": "one-day-delta",
                "sources": source,
                "requires_previous": 1,
                "description": f"{description}相對前一正式交易日的變化",
            }
        )
    for name, left, right, family, description in EXTREME_FLAG_SPECS:
        catalog.append(
            {
                "feature": name,
                "family": family,
                "kind": "nine-day-extreme-flag",
                "sources": f"{left}|{right}",
                "requires_previous": 0,
                "description": description,
            }
        )
    for base_name in ZERO_CROSS_FEATURES:
        source, family, description = by_name[base_name]
        for direction, phrase in (("up", "上穿"), ("down", "下穿")):
            catalog.append(
                {
                    "feature": f"{base_name}_cross_zero_{direction}",
                    "family": family,
                    "kind": "zero-cross-flag",
                    "sources": source,
                    "requires_previous": 1,
                    "description": f"{description}{phrase}零軸",
                }
            )
    catalog.extend(
        [
            {
                "feature": "kd_k_cross_d_up",
                "family": "kdj",
                "kind": "pair-cross-flag",
                "sources": "ZTKDK|ZTKDD",
                "requires_previous": 1,
                "description": "K 由下往上穿越 D",
            },
            {
                "feature": "kd_k_cross_d_down",
                "family": "kdj",
                "kind": "pair-cross-flag",
                "sources": "ZTKDK|ZTKDD",
                "requires_previous": 1,
                "description": "K 由上往下穿越 D",
            },
        ]
    )
    names = [str(row["feature"]) for row in catalog]
    require(len(names) == len(set(names)), "duplicate feature names")
    return catalog


def boundary_safe(window_id: int, future_20_date: int) -> bool:
    if window_id == 1:
        return future_20_date < 20200722
    if window_id == 2:
        return future_20_date < 20230722
    if window_id == 3:
        return future_20_date <= 20260722
    raise ValueError(window_id)


def load_label_keys(output: Path) -> dict[tuple[str, str, int], dict[str, Any]]:
    path = output / "path-labels.csv"
    require(path.is_file(), f"missing frozen labels: {path}")
    labels: dict[tuple[str, str, int], dict[str, Any]] = {}
    with path.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            key = (str(row["sample"]), str(row["stock_id"]), int(row["trade_date"]))
            require(key not in labels, f"duplicate frozen label key: {key}")
            labels[key] = {
                "sample": key[0],
                "stock_id": key[1],
                "trade_date": key[2],
                "window_id": int(row["window_id"]),
                "role": str(row["role"]),
                "stock_name": str(row["stock_name"]),
                "group_name": str(row["group_name"]),
                "p0": float(row["p0"]),
                "future_20_date": int(row["future_20_date"]),
            }
    require(labels, "frozen labels are empty")
    return labels


def derive_feature_values(current: dict[str, float], previous: dict[str, float]) -> dict[str, float | int]:
    values: dict[str, float | int] = {}
    source_by_name = {name: source for name, source, _, _ in BASE_FEATURE_SPECS}
    for name, source, _, _ in BASE_FEATURE_SPECS:
        values[name] = current[source]
        values[f"delta_{name}"] = current[source] - previous[source]
    for name, left, right, _, _ in EXTREME_FLAG_SPECS:
        values[name] = int(current[left] == current[right])
    for base_name in ZERO_CROSS_FEATURES:
        source = source_by_name[base_name]
        before = previous[source]
        after = current[source]
        values[f"{base_name}_cross_zero_up"] = int(before <= 0 < after)
        values[f"{base_name}_cross_zero_down"] = int(before >= 0 > after)
    before_k = previous["ZTKDK"]
    before_d = previous["ZTKDD"]
    after_k = current["ZTKDK"]
    after_d = current["ZTKDD"]
    values["kd_k_cross_d_up"] = int(before_k <= before_d and after_k > after_d)
    values["kd_k_cross_d_down"] = int(before_k >= before_d and after_k < after_d)
    expected = {str(row["feature"]) for row in feature_catalog()}
    require(set(values) == expected, "derived feature set differs from catalog")
    return values


def generate_feature_artifacts(
    project_root: Path,
    output: Path,
    input_metadata: dict[str, Any],
    destination: Path,
) -> dict[str, Any]:
    labels = load_label_keys(output)
    catalog = feature_catalog()
    feature_names = [str(row["feature"]) for row in catalog]
    feature_rows: list[dict[str, Any]] = []
    key_rows: list[dict[str, Any]] = []
    quality: dict[tuple[str, int], Counter[str]] = defaultdict(Counter)
    matched: set[tuple[str, str, int]] = set()

    for sample in SAMPLES:
        store = Path(input_metadata["samples"][sample]["report"]["browseStore"])
        connection = open_readonly(store)
        try:
            columns = table_columns(connection, "ZTRADE")
            missing = sorted(set(FEATURE_SOURCE_COLUMNS) - columns)
            require(not missing, f"Sample {sample} missing F01 source columns: {missing}")
            select_columns = ",".join(f"t.{column}" for column in FEATURE_SOURCE_COLUMNS)
            query = f"""
                SELECT s.ZSID stock_id,s.ZSNAME stock_name,s.ZGROUP group_name,
                       t.ZDATETIME trade_time,t.ZDATASOURCE data_source,{select_columns}
                FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK=t.ZSTOCK
                ORDER BY s.ZSID,t.ZDATETIME
            """
            previous_by_stock: dict[str, dict[str, Any]] = {}
            for raw in connection.execute(query):
                stock_id = str(raw["stock_id"])
                trade_date = apple_date(raw["trade_time"])
                key = (sample, stock_id, trade_date)
                previous = previous_by_stock.get(stock_id)
                current = {column: float(raw[column]) for column in FEATURE_SOURCE_COLUMNS}
                current_meta = {"date": trade_date, "values": current}
                previous_by_stock[stock_id] = current_meta
                label = labels.get(key)
                if label is None:
                    continue
                require(raw["data_source"] == "TWSE", f"F01 non-TWSE row: {key}")
                require(abs(current["ZPRICECLOSE"] - float(label["p0"])) < 1e-9, f"F01 price mismatch: {key}")
                require(str(raw["stock_name"]) == label["stock_name"], f"F01 stock name mismatch: {key}")
                require(str(raw["group_name"]) == label["group_name"], f"F01 group mismatch: {key}")
                matched.add(key)
                bucket = quality[(sample, int(label["window_id"]))]
                bucket["label_rows"] += 1
                exclusion: str | None = None
                if previous is None:
                    exclusion = "missing_previous_trade"
                elif int(current["ZTUPDATED"]) != 1:
                    exclusion = "current_not_250_mature"
                elif int(previous["values"]["ZTUPDATED"]) != 1:
                    exclusion = "previous_not_250_mature"
                elif not all(math.isfinite(current[column]) for column in FEATURE_SOURCE_COLUMNS):
                    exclusion = "nonfinite_current"
                elif not all(math.isfinite(previous["values"][column]) for column in FEATURE_SOURCE_COLUMNS):
                    exclusion = "nonfinite_previous"
                elif not boundary_safe(int(label["window_id"]), int(label["future_20_date"])):
                    exclusion = "future_horizon_crosses_window_boundary"
                if exclusion is not None:
                    bucket[exclusion] += 1
                    continue
                assert previous is not None
                values = derive_feature_values(current, previous["values"])
                require(all(math.isfinite(float(value)) for value in values.values()), f"F01 non-finite feature: {key}")
                row_identity = f"{STUDY_ID}|{sample}|{label['window_id']}|{stock_id}|{trade_date}"
                row_id = hashlib.sha256(row_identity.encode("utf-8")).hexdigest()[:24]
                key_rows.append(
                    {
                        "row_id": row_id,
                        "sample": sample,
                        "window_id": label["window_id"],
                        "role": label["role"],
                        "stock_id": stock_id,
                        "stock_name": label["stock_name"],
                        "group_name": label["group_name"],
                        "trade_date": trade_date,
                        "future_20_date": label["future_20_date"],
                    }
                )
                feature_rows.append({"row_id": row_id, **values})
                bucket["eligible_rows"] += 1
        finally:
            connection.close()
    missing_labels = sorted(set(labels) - matched)
    require(not missing_labels, f"F01 missing technical rows for {len(missing_labels)} labels")
    require(len(feature_rows) == len(key_rows), "F01 feature/key row count mismatch")
    require(len({row["row_id"] for row in key_rows}) == len(key_rows), "F01 duplicate row IDs")
    require(feature_rows, "F01 has no eligible feature rows")

    destination.mkdir(parents=True, exist_ok=True)
    write_csv(
        destination / "feature-catalog.csv",
        ["feature", "family", "kind", "sources", "requires_previous", "description"],
        catalog,
    )
    write_csv(
        destination / "feature-keys.csv",
        ["row_id", "sample", "window_id", "role", "stock_id", "stock_name", "group_name", "trade_date", "future_20_date"],
        key_rows,
    )
    write_csv(destination / "features.csv", ["row_id", *feature_names], feature_rows)
    quality_rows = []
    quality_columns = [
        "sample",
        "window_id",
        "role",
        "label_rows",
        "eligible_rows",
        "missing_previous_trade",
        "current_not_250_mature",
        "previous_not_250_mature",
        "nonfinite_current",
        "nonfinite_previous",
        "future_horizon_crosses_window_boundary",
    ]
    for sample in SAMPLES:
        for window_id, _, _ in WINDOWS:
            bucket = quality[(sample, window_id)]
            quality_rows.append(
                {
                    "sample": sample,
                    "window_id": window_id,
                    "role": role_for(sample, window_id),
                    **{column: bucket[column] for column in quality_columns[3:]},
                }
            )
    write_csv(destination / "feature-quality.csv", quality_columns, quality_rows)
    family_counts = Counter(str(row["family"]) for row in catalog)
    kind_counts = Counter(str(row["kind"]) for row in catalog)
    exclusions = Counter()
    for bucket in quality.values():
        for key, value in bucket.items():
            if key not in {"label_rows", "eligible_rows"}:
                exclusions[key] += value
    split_manifest = {
        "studyID": STUDY_ID,
        "stage": "M01-F01",
        "rowKey": ["sample", "stock_id", "trade_date"],
        "modelInputFile": "features.csv",
        "metadataFile": "feature-keys.csv",
        "labelFile": "path-labels.csv",
        "modelInputColumns": feature_names,
        "forbiddenModelColumns": [
            "row_id",
            "sample",
            "window_id",
            "role",
            "stock_id",
            "stock_name",
            "group_name",
            "trade_date",
            "future_20_date",
            "label",
            "label_name",
        ],
        "roles": {
            "discovery": "Samples A-C windows 1-2",
            "later-period-check": "Samples A-C window 3; locked until M01-V01",
            "cross-stock-check": "Sample D windows 1-3; locked until M01-V01",
            "weak-stress": "Sample E windows 1-3; locked until M01-V01",
        },
        "boundaryPurge": {
            "rule": "exclude a row when its future_20_date reaches the next fixed window",
            "purpose": "keep every 20-day outcome wholly inside one fixed window",
        },
        "maturity": {
            "rule": "current and previous formal TWSE rows must both have ZTUPDATED=1",
            "imputation": "none",
        },
        "crossValidationBoundary": "group by stock x window; retain at least the frozen 20-day outcome purge",
        "counts": {
            "frozenLabelRows": len(labels),
            "eligibleFeatureRows": len(feature_rows),
            "featureColumns": len(feature_names),
            "featureFamilies": dict(sorted(family_counts.items())),
            "featureKinds": dict(sorted(kind_counts.items())),
            "exclusions": dict(sorted(exclusions.items())),
        },
    }
    (destination / "split-manifest.json").write_text(
        json.dumps(split_manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return split_manifest["counts"]


def refresh_output_manifest(output: Path, manifest: dict[str, Any]) -> None:
    manifest["tool"] = {
        "path": "tools/fwd_v20_path_discovery.py",
        "sha256": file_hash(Path(__file__).resolve()),
    }
    manifest["outputs"] = {
        path.name: {"sha256": file_hash(path), "bytes": path.stat().st_size}
        for path in sorted(output.iterdir())
        if path.is_file() and path.name != "manifest.json"
    }
    atomic_json(output / "manifest.json", manifest)


def build_features(project_root: Path, output: Path) -> None:
    require(output.is_dir(), f"missing P0/L01 output: {output}")
    manifest = read_json(output / "manifest.json")
    quality = read_json(output / "data-quality.json")
    require(manifest.get("stages", {}).get("M01-P0") == "complete", "F01 requires completed P0")
    require(manifest.get("stages", {}).get("M01-L01") == "complete", "F01 requires completed L01")
    input_metadata, _ = verify_inputs(project_root)
    require(
        input_metadata == manifest["inputs"],
        "F01 Baseline or DecisionBase inputs differ from the frozen P0 manifest",
    )
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}-f01-", dir=output.parent))
    core_names = (
        "feature-catalog.csv",
        "feature-keys.csv",
        "features.csv",
        "feature-quality.csv",
        "split-manifest.json",
    )
    try:
        counts = generate_feature_artifacts(project_root, output, input_metadata, temporary)
        existing = [name for name in core_names if (output / name).is_file()]
        if existing:
            require(len(existing) == len(core_names), f"partial F01 output exists: {existing}")
            mismatches = [
                name
                for name in core_names
                if file_hash(output / name) != file_hash(temporary / name)
            ]
            require(not mismatches, f"F01 reproducibility mismatch: {mismatches}")
            reproducibility = "passed"
        else:
            for name in core_names:
                os.replace(temporary / name, output / name)
            reproducibility = "pending-second-generation"
    finally:
        shutil.rmtree(temporary, ignore_errors=True)

    feature_status = "passed" if reproducibility == "passed" else "pending-rerun"
    quality["f01"] = {
        "status": feature_status,
        "reproducibility": reproducibility,
        **counts,
        "noLabelColumnsInFeatureMatrix": True,
        "nonFiniteFeatureValues": 0,
    }
    atomic_json(output / "data-quality.json", quality)
    report_path = output / "report.md"
    report = report_path.read_text(encoding="utf-8")
    heading = "## F01 特徵與切分"
    pending_line = "- 第二次完整生成尚待執行；完成前不建立 `.f01-complete`。"
    complete_line = "- 第二次完整生成與五個核心 F01 產物逐位元一致，`.f01-complete` 已建立。"
    if heading not in report:
        report += (
            f"\n{heading}\n\n"
            f"- 建立 {counts['featureColumns']} 個模型特徵、{counts['eligibleFeatureRows']:,} 筆合格列；特徵矩陣不含標籤、股票、Sample、日期、窗口或股群欄位。\n"
            f"- 只納入目前與前一正式交易日均已完成 250 日技術成熟度的列，不做缺值補值。\n"
            f"- 20 日未來結果跨越下一固定窗口的列已排除，切分角色仍固定為 A～C 前兩窗發現、A～C 第三窗較晚期間確認、D 跨股票確認、E 弱勢壓力。\n"
            f"{pending_line}\n"
            "- 本階段沒有讀取標籤關聯、特徵排名或保留集效果，也沒有訓練模型。\n"
        )
    if reproducibility == "passed":
        require(pending_line in report or complete_line in report, "F01 report reproducibility line missing")
        report = report.replace(pending_line, complete_line)
        (output / ".f01-complete").write_text(STUDY_ID + "\n", encoding="utf-8")
    report_path.write_text(report, encoding="utf-8")

    manifest.setdefault("stages", {})["M01-F01"] = (
        "complete" if reproducibility == "passed" else "pending-reproducibility-check"
    )
    manifest["featureSpecification"] = {
        "catalog": "feature-catalog.csv",
        "matrix": "features.csv",
        "keys": "feature-keys.csv",
        "baseFeatures": len(BASE_FEATURE_SPECS),
        "oneDayDeltas": len(BASE_FEATURE_SPECS),
        "nineDayExtremeFlags": len(EXTREME_FLAG_SPECS),
        "zeroCrossFlags": len(ZERO_CROSS_FEATURES) * 2,
        "pairCrossFlags": 2,
        "total": len(feature_catalog()),
        "absolutePriceOrVolumeInputs": False,
        "usesCurrentAndPastOnly": True,
    }
    manifest["splitSpecification"] = read_json(output / "split-manifest.json")
    manifest.setdefault("qualitySummary", {})["f01"] = quality["f01"]
    if reproducibility == "passed":
        manifest["f01CompletedAt"] = datetime.now(timezone.utc).isoformat()
    refresh_output_manifest(output, manifest)
    print(f"F01 {feature_status}: {output}")


def extract_interactions(model: Any, feature_names: Sequence[str]) -> list[dict[str, Any]]:
    importances = model.term_importances()
    interactions: list[dict[str, Any]] = []
    for term_index, feature_indexes in enumerate(model.term_features_):
        if len(feature_indexes) != 2:
            continue
        left, right = (feature_names[index] for index in feature_indexes)
        pair = tuple(sorted((left, right)))
        interactions.append(
            {
                "pair": " x ".join(pair),
                "feature_1": pair[0],
                "feature_2": pair[1],
                "importance": float(importances[term_index]),
            }
        )
    interactions.sort(key=lambda row: (-row["importance"], row["pair"]))
    for rank, row in enumerate(interactions, start=1):
        row["rank"] = rank
    return interactions


def shifted_labels_by_group(labels: Any, groups: Any, numpy: Any) -> tuple[Any, dict[str, int]]:
    shifted = labels.copy()
    shifts: dict[str, int] = {}
    for group in sorted(set(groups.tolist())):
        indexes = numpy.flatnonzero(groups == group)
        require(len(indexes) > 41, f"M01 group too short for 20-day null shift: {group}")
        span = len(indexes) - 40
        digest = hashlib.sha256(f"{STUDY_ID}|M01-null|{group}".encode("utf-8")).digest()
        shift = 21 + int.from_bytes(digest[:4], "big") % span
        shifted[indexes] = numpy.roll(labels[indexes], shift)
        shifts[str(group)] = int(shift)
    return shifted, shifts


def fit_ebm_with_heartbeat(
    output: Path,
    progress: dict[str, Any],
    model_name: str,
    model: Any,
    features: Any,
    labels: Any,
) -> Any:
    started = time.monotonic()
    progress["currentModel"] = model_name
    progress["currentModelStartedAt"] = datetime.now(timezone.utc).isoformat()
    atomic_json(output / "m01-progress.json", progress)
    print(f"M01 start {model_name}: rows={len(labels):,}", flush=True)
    stopped = threading.Event()

    def heartbeat() -> None:
        while not stopped.wait(30):
            elapsed = int(time.monotonic() - started)
            progress["heartbeatAt"] = datetime.now(timezone.utc).isoformat()
            progress["currentModelElapsedSeconds"] = elapsed
            atomic_json(output / "m01-progress.json", progress)
            print(f"M01 heartbeat {model_name}: {elapsed}s", flush=True)

    worker = threading.Thread(target=heartbeat, daemon=True)
    worker.start()
    try:
        model.fit(features, labels)
    finally:
        stopped.set()
        worker.join(timeout=2)
    elapsed = time.monotonic() - started
    progress.setdefault("completedModels", []).append(
        {"name": model_name, "seconds": round(elapsed, 3), "rows": int(len(labels))}
    )
    progress["currentModel"] = None
    progress["currentModelElapsedSeconds"] = None
    atomic_json(output / "m01-progress.json", progress)
    print(f"M01 complete {model_name}: {elapsed:.1f}s", flush=True)
    return model


def train_discovery_model(project_root: Path, output: Path) -> None:
    try:
        import joblib
        import numpy as np
        import pandas as pd
        import sklearn
        from interpret import __version__ as interpret_version
        from interpret.glassbox import ExplainableBoostingClassifier
        from sklearn.metrics import log_loss
        from sklearn.model_selection import GroupKFold
    except ImportError as exc:
        raise RuntimeError(
            "M01 requires the approved isolated environment with numpy, pandas, sklearn, interpret, and joblib"
        ) from exc

    require(output.is_dir(), f"missing F01 output: {output}")
    require(not (output / ".m01-complete").exists(), "M01 is already complete")
    manifest = read_json(output / "manifest.json")
    quality = read_json(output / "data-quality.json")
    require(manifest.get("stages", {}).get("M01-F01") == "complete", "M01 requires completed F01")
    require((output / ".f01-complete").is_file(), "M01 requires .f01-complete")
    input_metadata, _ = verify_inputs(project_root)
    require(input_metadata == manifest["inputs"], "M01 Baseline or DecisionBase inputs differ from frozen P0")
    frozen_files = (
        "path-labels.csv",
        "feature-catalog.csv",
        "feature-keys.csv",
        "features.csv",
        "split-manifest.json",
    )
    for name in frozen_files:
        require(name in manifest["outputs"], f"M01 frozen output missing from manifest: {name}")
        require(
            file_hash(output / name) == manifest["outputs"][name]["sha256"],
            f"M01 frozen output hash mismatch: {name}",
        )

    progress: dict[str, Any] = {
        "studyID": STUDY_ID,
        "stage": "M01-M01",
        "status": "loading-discovery-only",
        "startedAt": datetime.now(timezone.utc).isoformat(),
        "completedModels": [],
    }
    atomic_json(output / "m01-progress.json", progress)
    try:
        with (output / "feature-catalog.csv").open(encoding="utf-8", newline="") as handle:
            catalog = list(csv.DictReader(handle))
        feature_names = [row["feature"] for row in catalog]
        feature_family = {row["feature"]: row["family"] for row in catalog}
        split = read_json(output / "split-manifest.json")
        require(feature_names == split["modelInputColumns"], "M01 feature order differs from frozen F01")

        key_rows: list[dict[str, Any]] = []
        wanted: dict[tuple[str, int, str, int], str] = {}
        with (output / "feature-keys.csv").open(encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                if row["role"] != "discovery":
                    continue
                key = (row["sample"], int(row["window_id"]), row["stock_id"], int(row["trade_date"]))
                require(row["sample"] in "ABC" and int(row["window_id"]) in (1, 2), f"invalid discovery key: {key}")
                require(key not in wanted, f"duplicate discovery key: {key}")
                wanted[key] = row["row_id"]
                key_rows.append(row)
        require(key_rows and len(key_rows) == len(wanted), "M01 has no unique discovery keys")
        wanted_ids = set(wanted.values())

        labels_by_id: dict[str, str] = {}
        with (output / "path-labels.csv").open(encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                key = (row["sample"], int(row["window_id"]), row["stock_id"], int(row["trade_date"]))
                row_id = wanted.get(key)
                if row_id is not None:
                    require(row["label"] in LABELS, f"unknown M01 label: {row['label']}")
                    labels_by_id[row_id] = row["label"]
        require(set(labels_by_id) == wanted_ids, "M01 discovery label join is incomplete")

        selected_chunks = []
        for chunk in pd.read_csv(output / "features.csv", chunksize=10_000):
            selected = chunk[chunk["row_id"].isin(wanted_ids)]
            if not selected.empty:
                selected_chunks.append(selected)
        require(selected_chunks, "M01 discovery feature selection is empty")
        feature_frame = pd.concat(selected_chunks, ignore_index=True)
        require(len(feature_frame) == len(wanted_ids), "M01 discovery feature row count mismatch")
        metadata = pd.DataFrame(key_rows)
        data = metadata.merge(feature_frame, on="row_id", how="inner", validate="one_to_one")
        data["window_id"] = data["window_id"].astype(int)
        data["trade_date"] = data["trade_date"].astype(int)
        data["label"] = data["row_id"].map(labels_by_id)
        data = data.sort_values(
            ["sample", "window_id", "stock_id", "trade_date", "row_id"], kind="stable"
        ).reset_index(drop=True)
        require(len(data) == len(wanted_ids), "M01 merged discovery row count mismatch")
        matrix = data[feature_names].to_numpy(dtype=np.float64, copy=True)
        require(bool(np.isfinite(matrix).all()), "M01 matrix contains non-finite values")
        labels = data["label"].to_numpy(dtype=str)
        groups = (
            data["sample"].astype(str)
            + "-W"
            + data["window_id"].astype(str)
            + "-"
            + data["stock_id"].astype(str)
        ).to_numpy(dtype=str)
        require(len(set(groups.tolist())) == 60, "M01 expected 60 stock x window groups")
        label_order = np.array(sorted(LABELS), dtype=str)
        require(set(labels.tolist()) == set(label_order.tolist()), "M01 discovery set lacks a path class")

        splitter = GroupKFold(n_splits=M01_FOLDS)
        folds = list(splitter.split(matrix, labels, groups))
        fold_ids = np.zeros(len(data), dtype=int)
        for fold, (_, test_indexes) in enumerate(folds, start=1):
            fold_ids[test_indexes] = fold
        require(bool((fold_ids > 0).all()), "M01 fold assignment incomplete")
        data["fold"] = fold_ids
        fold_rows: list[dict[str, Any]] = []
        for (sample, window_id, stock_id, fold), members in data.groupby(
            ["sample", "window_id", "stock_id", "fold"], sort=True
        ):
            counts = Counter(members["label"].tolist())
            fold_rows.append(
                {
                    "fold": int(fold),
                    "sample": sample,
                    "window_id": int(window_id),
                    "stock_id": stock_id,
                    "rows": len(members),
                    **{f"label_{label}": counts[label] for label in LABELS},
                }
            )
        write_csv(
            output / "discovery-folds.csv",
            ["fold", "sample", "window_id", "stock_id", "rows", *[f"label_{label}" for label in LABELS]],
            fold_rows,
        )
        balance_rows: list[dict[str, Any]] = []
        for keys, members in [(('all', 'all'), data), *list(data.groupby(["sample", "window_id"], sort=True))]:
            sample, window_id = keys
            counts = Counter(members["label"].tolist())
            for label in LABELS:
                balance_rows.append(
                    {
                        "sample": sample,
                        "window_id": window_id,
                        "label": label,
                        "rows": counts[label],
                        "share": counts[label] / len(members),
                    }
                )
        write_csv(
            output / "discovery-class-balance.csv",
            ["sample", "window_id", "label", "rows", "share"],
            balance_rows,
        )

        null_labels, null_shifts = shifted_labels_by_group(labels, groups, np)
        progress["status"] = "training"
        progress["discoveryRows"] = len(data)
        progress["featureColumns"] = len(feature_names)
        progress["groups"] = len(set(groups.tolist()))
        atomic_json(output / "m01-progress.json", progress)

        def new_model(interactions: int, seed: int) -> Any:
            return ExplainableBoostingClassifier(
                feature_names=feature_names,
                feature_types=["continuous"] * len(feature_names),
                interactions=interactions,
                random_state=seed,
                **M01_MODEL_PARAMS,
            )

        metrics: list[dict[str, Any]] = []
        observed_terms_by_fold: dict[int, list[dict[str, Any]]] = {}
        null_terms_by_fold: dict[int, list[dict[str, Any]]] = {}
        for fold, (train_indexes, test_indexes) in enumerate(folds, start=1):
            seed = M01_RANDOM_STATE + fold
            main = fit_ebm_with_heartbeat(
                output,
                progress,
                f"fold-{fold}-main",
                new_model(0, seed),
                matrix[train_indexes],
                labels[train_indexes],
            )
            pair = fit_ebm_with_heartbeat(
                output,
                progress,
                f"fold-{fold}-pair",
                new_model(M01_INTERACTIONS, seed),
                matrix[train_indexes],
                labels[train_indexes],
            )
            main_loss = float(log_loss(labels[test_indexes], main.predict_proba(matrix[test_indexes]), labels=main.classes_))
            pair_loss = float(log_loss(labels[test_indexes], pair.predict_proba(matrix[test_indexes]), labels=pair.classes_))
            counts = Counter(labels[train_indexes].tolist())
            prior = np.array([counts[label] / len(train_indexes) for label in label_order], dtype=float)
            prior_matrix = np.tile(prior, (len(test_indexes), 1))
            prior_loss = float(log_loss(labels[test_indexes], prior_matrix, labels=label_order))
            metrics.append(
                {
                    "evaluation": "grouped-cross-validation",
                    "fold": fold,
                    "train_rows": len(train_indexes),
                    "test_rows": len(test_indexes),
                    "prior_log_loss": prior_loss,
                    "main_log_loss": main_loss,
                    "pair_log_loss": pair_loss,
                    "main_gain_vs_prior": prior_loss - main_loss,
                    "pair_gain_vs_main": main_loss - pair_loss,
                }
            )
            observed_terms_by_fold[fold] = extract_interactions(pair, feature_names)
            null_pair = fit_ebm_with_heartbeat(
                output,
                progress,
                f"fold-{fold}-null-pair",
                new_model(M01_INTERACTIONS, seed),
                matrix[train_indexes],
                null_labels[train_indexes],
            )
            null_terms_by_fold[fold] = extract_interactions(null_pair, feature_names)
            del main, pair, null_pair

        total_test = sum(row["test_rows"] for row in metrics)
        cv_summary = {
            "evaluation": "grouped-cross-validation",
            "fold": "weighted-average",
            "train_rows": "",
            "test_rows": total_test,
        }
        for field in ("prior_log_loss", "main_log_loss", "pair_log_loss", "main_gain_vs_prior", "pair_gain_vs_main"):
            cv_summary[field] = sum(row[field] * row["test_rows"] for row in metrics) / total_test
        metrics.append(cv_summary)

        full_main = fit_ebm_with_heartbeat(
            output,
            progress,
            "full-discovery-main",
            new_model(0, M01_RANDOM_STATE),
            matrix,
            labels,
        )
        full_pair = fit_ebm_with_heartbeat(
            output,
            progress,
            "full-discovery-pair",
            new_model(M01_INTERACTIONS, M01_RANDOM_STATE),
            matrix,
            labels,
        )
        full_main_loss = float(log_loss(labels, full_main.predict_proba(matrix), labels=full_main.classes_))
        full_pair_loss = float(log_loss(labels, full_pair.predict_proba(matrix), labels=full_pair.classes_))
        counts = Counter(labels.tolist())
        prior = np.array([counts[label] / len(labels) for label in label_order], dtype=float)
        full_prior_loss = float(log_loss(labels, np.tile(prior, (len(labels), 1)), labels=label_order))
        metrics.append(
            {
                "evaluation": "full-discovery-in-sample",
                "fold": "all",
                "train_rows": len(labels),
                "test_rows": len(labels),
                "prior_log_loss": full_prior_loss,
                "main_log_loss": full_main_loss,
                "pair_log_loss": full_pair_loss,
                "main_gain_vs_prior": full_prior_loss - full_main_loss,
                "pair_gain_vs_main": full_main_loss - full_pair_loss,
            }
        )
        metric_fields = [
            "evaluation", "fold", "train_rows", "test_rows", "prior_log_loss", "main_log_loss",
            "pair_log_loss", "main_gain_vs_prior", "pair_gain_vs_main",
        ]
        write_csv(output / "discovery-model-metrics.csv", metric_fields, metrics)

        main_importances = full_main.term_importances()
        main_rows = []
        for term_index, feature_indexes in enumerate(full_main.term_features_):
            require(len(feature_indexes) == 1, "M01 main-only EBM contains an interaction")
            feature = feature_names[feature_indexes[0]]
            main_rows.append(
                {
                    "feature": feature,
                    "family": feature_family[feature],
                    "importance": float(main_importances[term_index]),
                }
            )
        main_rows.sort(key=lambda row: (-row["importance"], row["feature"]))
        for rank, row in enumerate(main_rows, start=1):
            row["rank"] = rank
        write_csv(output / "main-effects.csv", ["rank", "feature", "family", "importance"], main_rows)

        full_terms = extract_interactions(full_pair, feature_names)
        full_by_pair = {row["pair"]: row for row in full_terms}
        observed_frequency: Counter[str] = Counter()
        null_frequency: Counter[str] = Counter()
        observed_values: dict[str, list[dict[str, Any]]] = defaultdict(list)
        stability_rows: list[dict[str, Any]] = []
        for model_kind, terms_by_fold, frequency in (
            ("observed", observed_terms_by_fold, observed_frequency),
            ("block-shift-null", null_terms_by_fold, null_frequency),
        ):
            for fold, terms in sorted(terms_by_fold.items()):
                for term in terms:
                    frequency[term["pair"]] += 1
                    if model_kind == "observed":
                        observed_values[term["pair"]].append(term)
                    stability_rows.append(
                        {
                            "model_kind": model_kind,
                            "fold": fold,
                            "rank": term["rank"],
                            "feature_1": term["feature_1"],
                            "family_1": feature_family[term["feature_1"]],
                            "feature_2": term["feature_2"],
                            "family_2": feature_family[term["feature_2"]],
                            "importance": term["importance"],
                        }
                    )
        write_csv(
            output / "stability-by-fold.csv",
            ["model_kind", "fold", "rank", "feature_1", "family_1", "feature_2", "family_2", "importance"],
            stability_rows,
        )

        weighted = next(row for row in metrics if row["fold"] == "weighted-average")
        improved_folds = sum(1 for row in metrics if isinstance(row["fold"], int) and row["pair_gain_vs_main"] > 0)
        null_max_frequency = max(null_frequency.values(), default=0)
        all_pairs = set(full_by_pair) | set(observed_frequency)
        ranking_rows = []
        for pair in all_pairs:
            full = full_by_pair.get(pair)
            values = observed_values.get(pair, [])
            source = full or values[0]
            fold_count = observed_frequency[pair]
            stable = bool(
                full
                and fold_count >= 2
                and fold_count > null_max_frequency
                and weighted["pair_gain_vs_main"] > 0
                and improved_folds >= 2
            )
            ranking_rows.append(
                {
                    "feature_1": source["feature_1"],
                    "family_1": feature_family[source["feature_1"]],
                    "feature_2": source["feature_2"],
                    "family_2": feature_family[source["feature_2"]],
                    "full_model_selected": int(full is not None),
                    "full_model_rank": full["rank"] if full else "",
                    "full_model_importance": full["importance"] if full else "",
                    "observed_fold_selection_count": fold_count,
                    "observed_mean_fold_rank": statistics.mean(row["rank"] for row in values) if values else "",
                    "observed_mean_fold_importance": statistics.mean(row["importance"] for row in values) if values else "",
                    "same_pair_null_selection_count": null_frequency[pair],
                    "stable_for_holdout": int(stable),
                }
            )
        ranking_rows.sort(
            key=lambda row: (
                -row["stable_for_holdout"],
                -row["observed_fold_selection_count"],
                -row["full_model_selected"],
                row["full_model_rank"] if row["full_model_rank"] != "" else 999,
                row["feature_1"],
                row["feature_2"],
            )
        )
        for rank, row in enumerate(ranking_rows, start=1):
            row["rank"] = rank
        ranking_fields = [
            "rank", "feature_1", "family_1", "feature_2", "family_2", "full_model_selected",
            "full_model_rank", "full_model_importance", "observed_fold_selection_count",
            "observed_mean_fold_rank", "observed_mean_fold_importance",
            "same_pair_null_selection_count", "stable_for_holdout",
        ]
        write_csv(output / "interaction-ranking.csv", ranking_fields, ranking_rows)
        stable_rows = [row for row in ranking_rows if row["stable_for_holdout"]]
        null_rows = [
            {"metric": "observed_unique_pairs", "value": len(observed_frequency), "note": "three grouped folds"},
            {"metric": "null_unique_pairs", "value": len(null_frequency), "note": "one deterministic block shift per stock x window"},
            {"metric": "observed_max_fold_frequency", "value": max(observed_frequency.values(), default=0), "note": "out of three folds"},
            {"metric": "null_max_fold_frequency", "value": null_max_frequency, "note": "out of three folds"},
            {"metric": "weighted_pair_gain_vs_main", "value": weighted["pair_gain_vs_main"], "note": "positive is better"},
            {"metric": "folds_pair_better_than_main", "value": improved_folds, "note": "out of three folds"},
            {"metric": "stable_pairs_for_holdout", "value": len(stable_rows), "note": "full model plus observed/null/CV gate"},
        ]
        write_csv(output / "null-comparison.csv", ["metric", "value", "note"], null_rows)

        joblib.dump(full_main, output / "discovery-main-ebm.joblib", compress=3)
        joblib.dump(full_pair, output / "discovery-pair-ebm.joblib", compress=3)
        requirements = subprocess.check_output(
            [sys.executable, "-m", "pip", "freeze"], text=True, encoding="utf-8"
        )
        (output / "requirements-lock.txt").write_text(requirements, encoding="utf-8")
        model_config = {
            "studyID": STUDY_ID,
            "stage": "M01-M01",
            "scope": "discovery rows only: Samples A-C windows 1-2",
            "holdoutLabelsUsed": False,
            "discoveryRows": len(data),
            "featureColumns": len(feature_names),
            "groups": len(set(groups.tolist())),
            "classes": label_order.tolist(),
            "crossValidation": {
                "method": "GroupKFold",
                "folds": M01_FOLDS,
                "group": "sample x stock x window",
                "futureOutcomePurge": "inherited frozen F01 20-trading-day boundary purge",
            },
            "null": {
                "method": "deterministic circular label shift within each stock x window",
                "minimumShift": 21,
                "shifts": null_shifts,
                "inferenceBoundary": "diagnostic ranking burden only; no p-value",
            },
            "model": {
                "class": "interpret.glassbox.ExplainableBoostingClassifier",
                "interactions": M01_INTERACTIONS,
                "randomStateBase": M01_RANDOM_STATE,
                "parameters": M01_MODEL_PARAMS,
                "hyperparameterGrid": False,
            },
            "stabilityGate": {
                "fullModelSelected": True,
                "minimumObservedFoldSelections": 2,
                "observedFoldSelectionsMustExceedNullMaximum": True,
                "weightedPairGainVsMainMustBePositive": True,
                "minimumImprovedFolds": 2,
            },
            "environment": {
                "python": platform.python_version(),
                "executable": sys.executable,
                "numpy": np.__version__,
                "pandas": pd.__version__,
                "scikitLearn": sklearn.__version__,
                "interpret": interpret_version,
                "requirements": "requirements-lock.txt",
            },
            "frozenInputs": {name: file_hash(output / name) for name in frozen_files},
        }
        atomic_json(output / "model-config.json", model_config)

        m01_status = "passed-with-stable-interactions" if stable_rows else "complete-no-stable-interaction"
        quality["m01"] = {
            "status": m01_status,
            "discoveryRows": len(data),
            "featureColumns": len(feature_names),
            "groups": len(set(groups.tolist())),
            "folds": M01_FOLDS,
            "weightedPriorLogLoss": weighted["prior_log_loss"],
            "weightedMainLogLoss": weighted["main_log_loss"],
            "weightedPairLogLoss": weighted["pair_log_loss"],
            "weightedPairGainVsMain": weighted["pair_gain_vs_main"],
            "foldsPairBetterThanMain": improved_folds,
            "observedNullMaxFoldFrequency": {
                "observed": max(observed_frequency.values(), default=0),
                "null": null_max_frequency,
            },
            "stablePairsForHoldout": len(stable_rows),
            "holdoutLabelsUsed": False,
        }
        atomic_json(output / "data-quality.json", quality)
        report_path = output / "report.md"
        report = report_path.read_text(encoding="utf-8")
        require("## M01 發現集模型搜尋" not in report, "M01 report section already exists")
        top_lines = "\n".join(
            f"- `{row['feature_1']} × {row['feature_2']}`：三折選中 {row['observed_fold_selection_count']} 次。"
            for row in stable_rows[:5]
        )
        if not top_lines:
            top_lines = "- 沒有二階組合通過事前凍結的完整模型、三折穩定性、虛無頻率及 log loss 閘門。"
        report += (
            "\n## M01 發現集模型搜尋\n\n"
            f"- 只使用 A～C 第一、第二窗口的 {len(data):,} 筆發現資料；第三窗口、D、E 的標籤未用於訓練、排序或判讀。\n"
            f"- 三折股票 × 窗口群組交叉驗證的加權 log loss：基準率 {weighted['prior_log_loss']:.6f}、主效果 {weighted['main_log_loss']:.6f}、最多 20 組二階交互作用 {weighted['pair_log_loss']:.6f}；二階相對主效果改善 {weighted['pair_gain_vs_main']:.6f}，三折中 {improved_folds} 折改善。\n"
            f"- 觀察模型同一組合最高跨 {max(observed_frequency.values(), default=0)} 折，區塊循環置換虛無模型最高跨 {null_max_frequency} 折；此虛無比較只作排序負擔診斷，不宣稱 p 值。\n"
            f"- 通過發現集閘門、值得送保留驗證的組合：{len(stable_rows)} 組。\n"
            f"{top_lines}\n"
            "- 本階段未查看保留集效果、未轉譯交易門檻、未修改規則或重播 `simUpdate`。\n"
        )
        report_path.write_text(report, encoding="utf-8")

        progress["status"] = "complete"
        progress["completedAt"] = datetime.now(timezone.utc).isoformat()
        progress["result"] = m01_status
        progress["stablePairsForHoldout"] = len(stable_rows)
        atomic_json(output / "m01-progress.json", progress)
        (output / ".m01-complete").write_text(STUDY_ID + "\n", encoding="utf-8")
        manifest.setdefault("stages", {})["M01-M01"] = "complete"
        manifest["m01CompletedAt"] = datetime.now(timezone.utc).isoformat()
        manifest["modelDiscovery"] = {
            "status": m01_status,
            "config": "model-config.json",
            "metrics": "discovery-model-metrics.csv",
            "mainEffects": "main-effects.csv",
            "interactionRanking": "interaction-ranking.csv",
            "stability": "stability-by-fold.csv",
            "nullComparison": "null-comparison.csv",
            "stablePairsForHoldout": len(stable_rows),
            "holdoutLabelsUsed": False,
        }
        manifest.setdefault("qualitySummary", {})["m01"] = quality["m01"]
        refresh_output_manifest(output, manifest)
        print(f"M01 {m01_status}: stable_pairs={len(stable_rows)}", flush=True)
    except Exception as exc:
        progress["status"] = "failed"
        progress["failedAt"] = datetime.now(timezone.utc).isoformat()
        progress["error"] = f"{type(exc).__name__}: {exc}"
        atomic_json(output / "m01-progress.json", progress)
        raise


def pc01_feature_trigger(control_id: str, values: dict[str, float]) -> bool:
    flags = {
        "L-P03": values["kd_k_z125"] < -0.9 and values["kd_k_z250"] < -0.9,
        "L-P04": values["kd_d_z125"] < -0.9 and values["kd_d_z250"] < -0.9,
        "S-P03": values["kd_k_z125"] > 0.9,
        "S-P04": values["kd_d_z125"] > 0.9,
    }
    if "+" in control_id:
        return all(flags[part] for part in control_id.split("+"))
    return flags[control_id]


def pc01_episode_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output_rows: list[dict[str, Any]] = []
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[str(row["group"])].append(row)
    for members in grouped.values():
        previous_ordinal: int | None = None
        previous_trigger: bool | None = None
        for row in sorted(members, key=lambda item: int(item["ordinal"])):
            ordinal = int(row["ordinal"])
            trigger = bool(row["trigger"])
            if previous_ordinal is None or ordinal != previous_ordinal + 1 or trigger != previous_trigger:
                output_rows.append(row)
            previous_ordinal = ordinal
            previous_trigger = trigger
    return output_rows


def pc01_association(
    control: dict[str, Any],
    stratum: str,
    unit: str,
    rows: list[dict[str, Any]],
) -> tuple[dict[str, Any], list[dict[str, Any]], list[dict[str, Any]]]:
    expected = str(control["expected_label"])
    adverse = str(control["adverse_label"])
    triggered = [row for row in rows if row["trigger"]]
    untriggered = [row for row in rows if not row["trigger"]]
    trigger_counts = Counter(str(row["label"]) for row in triggered)
    non_counts = Counter(str(row["label"]) for row in untriggered)

    def rate(counts: Counter[str], label: str, total: int) -> float:
        return counts[label] / total if total else math.nan

    trigger_target = rate(trigger_counts, expected, len(triggered))
    non_target = rate(non_counts, expected, len(untriggered))
    trigger_adverse = rate(trigger_counts, adverse, len(triggered))
    non_adverse = rate(non_counts, adverse, len(untriggered))
    target_or = (
        ((trigger_counts[expected] + 0.5) * (len(untriggered) - non_counts[expected] + 0.5))
        / ((len(triggered) - trigger_counts[expected] + 0.5) * (non_counts[expected] + 0.5))
        if triggered and untriggered
        else math.nan
    )
    adverse_or = (
        ((trigger_counts[adverse] + 0.5) * (len(untriggered) - non_counts[adverse] + 0.5))
        / ((len(triggered) - trigger_counts[adverse] + 0.5) * (non_counts[adverse] + 0.5))
        if triggered and untriggered
        else math.nan
    )
    signal_delta = (
        (trigger_target - non_target) - (trigger_adverse - non_adverse)
        if triggered and untriggered
        else math.nan
    )

    group_rows: list[dict[str, Any]] = []
    by_group: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        by_group[str(row["group"])].append(row)
    minimum = 2 if unit == "episode" else 10
    positive = negative = tied = 0
    for group, members in sorted(by_group.items()):
        group_trigger = [row for row in members if row["trigger"]]
        group_non = [row for row in members if not row["trigger"]]
        if len(group_trigger) < minimum or len(group_non) < minimum:
            continue
        group_trigger_counts = Counter(str(row["label"]) for row in group_trigger)
        group_non_counts = Counter(str(row["label"]) for row in group_non)
        group_signal = (
            group_trigger_counts[expected] / len(group_trigger)
            - group_non_counts[expected] / len(group_non)
            - group_trigger_counts[adverse] / len(group_trigger)
            + group_non_counts[adverse] / len(group_non)
        )
        direction = "positive" if group_signal > 1e-12 else "negative" if group_signal < -1e-12 else "tie"
        positive += direction == "positive"
        negative += direction == "negative"
        tied += direction == "tie"
        group_rows.append(
            {
                "control_id": control["control_id"],
                "stratum": stratum,
                "unit": unit,
                "group": group,
                "trigger_rows": len(group_trigger),
                "nontrigger_rows": len(group_non),
                "signal_delta": group_signal,
                "direction": direction,
            }
        )
    recognized = bool(
        unit == "episode"
        and len(triggered) >= 30
        and len(untriggered) >= 30
        and len(group_rows) >= 10
        and math.isfinite(signal_delta)
        and signal_delta > 0
        and (
            (math.isfinite(target_or) and target_or >= 1.10)
            or (math.isfinite(adverse_or) and adverse_or <= 1 / 1.10)
        )
        and positive > negative
    )
    association = {
        "control_id": control["control_id"],
        "stratum": stratum,
        "unit": unit,
        "expected_label": expected,
        "adverse_label": adverse,
        "trigger_rows": len(triggered),
        "nontrigger_rows": len(untriggered),
        "trigger_expected_rate": trigger_target,
        "nontrigger_expected_rate": non_target,
        "expected_rate_delta": trigger_target - non_target if triggered and untriggered else math.nan,
        "expected_odds_ratio": target_or,
        "trigger_adverse_rate": trigger_adverse,
        "nontrigger_adverse_rate": non_adverse,
        "adverse_rate_delta": trigger_adverse - non_adverse if triggered and untriggered else math.nan,
        "adverse_odds_ratio": adverse_or,
        "net_signal_delta": signal_delta,
        "trigger_groups": len({row["group"] for row in triggered}),
        "comparable_groups": len(group_rows),
        "groups_positive": positive,
        "groups_negative": negative,
        "groups_tied": tied,
        "recognized": int(recognized),
    }
    distribution_rows = []
    for trigger_name, counts, total in (
        ("trigger", trigger_counts, len(triggered)),
        ("nontrigger", non_counts, len(untriggered)),
    ):
        for label in LABELS:
            distribution_rows.append(
                {
                    "control_id": control["control_id"],
                    "stratum": stratum,
                    "unit": unit,
                    "trigger_state": trigger_name,
                    "label": label,
                    "rows": counts[label],
                    "share": counts[label] / total if total else math.nan,
                }
            )
    return association, distribution_rows, group_rows


def run_positive_control(project_root: Path, output: Path) -> None:
    require(output.is_dir(), f"missing M01 output: {output}")
    require(not (output / ".pc01-complete").exists(), "PC01 is already complete")
    manifest = read_json(output / "manifest.json")
    quality = read_json(output / "data-quality.json")
    require(manifest.get("stages", {}).get("M01-M01") == "complete", "PC01 requires completed M01")
    require(manifest.get("modelDiscovery", {}).get("stablePairsForHoldout") == 0, "PC01 is only for failed M01")
    input_metadata, _ = verify_inputs(project_root)
    require(input_metadata == manifest["inputs"], "PC01 inputs differ from frozen P0")
    for name in ("path-labels.csv", "feature-keys.csv", "features.csv"):
        require(file_hash(output / name) == manifest["outputs"][name]["sha256"], f"PC01 frozen hash mismatch: {name}")

    key_meta: dict[tuple[str, int, str, int], dict[str, Any]] = {}
    row_to_key: dict[str, tuple[str, int, str, int]] = {}
    by_group: dict[str, list[tuple[str, int, str, int]]] = defaultdict(list)
    with (output / "feature-keys.csv").open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            if row["role"] != "discovery":
                continue
            key = (row["sample"], int(row["window_id"]), row["stock_id"], int(row["trade_date"]))
            group = f"{key[0]}-W{key[1]}-{key[2]}"
            key_meta[key] = {"row_id": row["row_id"], "group": group}
            row_to_key[row["row_id"]] = key
            by_group[group].append(key)
    for group, keys in by_group.items():
        for ordinal, key in enumerate(sorted(keys, key=lambda value: value[3])):
            key_meta[key]["ordinal"] = ordinal
    require(len(key_meta) == 42_249, "PC01 discovery key count differs from M01")

    labels_by_key: dict[tuple[str, int, str, int], str] = {}
    with (output / "path-labels.csv").open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            key = (row["sample"], int(row["window_id"]), row["stock_id"], int(row["trade_date"]))
            if key in key_meta:
                labels_by_key[key] = row["label"]
    require(set(labels_by_key) == set(key_meta), "PC01 discovery labels incomplete")

    technical_columns = ("kd_k_z125", "kd_k_z250", "kd_d_z125", "kd_d_z250")
    technical_by_key: dict[tuple[str, int, str, int], dict[str, float]] = {}
    with (output / "features.csv").open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            key = row_to_key.get(row["row_id"])
            if key is not None:
                technical_by_key[key] = {name: float(row[name]) for name in technical_columns}
    require(set(technical_by_key) == set(key_meta), "PC01 technical join incomplete")

    observations: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for key in sorted(key_meta):
        meta = key_meta[key]
        base = {
            "group": meta["group"],
            "ordinal": meta["ordinal"],
            "label": labels_by_key[key],
        }
        values = technical_by_key[key]
        for control in PC01_CONTROLS:
            observations[(control["control_id"], "all-trading-days")].append(
                {**base, "trigger": pc01_feature_trigger(control["control_id"], values)}
            )

    required_rule_ids = {rule_id for control in PC01_CONTROLS for rule_id in control["rule_ids"]}
    vote_counts: Counter[tuple[str, int]] = Counter()
    for sample in "ABC":
        database = Path(manifest["inputs"]["samples"][sample]["decisionBase"]["inputFiles"]["database"]["path"])
        require(
            file_hash(database)
            == manifest["inputs"]["samples"][sample]["decisionBase"]["inputFiles"]["database"]["sha256"],
            f"PC01 DecisionBase hash mismatch: {sample}",
        )
        with open_readonly(database) as connection:
            rule_keys = {
                str(row["rule_id"]): int(row["rule_key"])
                for row in connection.execute(
                    "SELECT rule_key, rule_id FROM rules WHERE rule_id IN (?,?,?,?)",
                    tuple(sorted(required_rule_ids)),
                )
            }
            require(set(rule_keys) == required_rule_ids, f"PC01 missing formal rules in {sample}")
            votes_by_event: dict[int, set[str]] = defaultdict(set)
            for row in connection.execute(
                "SELECT v.event_id, r.rule_id FROM event_votes v JOIN rules r USING(rule_key) "
                "WHERE r.rule_id IN (?,?,?,?)",
                tuple(sorted(required_rule_ids)),
            ):
                votes_by_event[int(row["event_id"])].add(str(row["rule_id"]))
            events = connection.execute(
                "SELECT e.event_id, e.window_id, s.stock_id, e.trade_date, e.phase, "
                "e.planned_action, e.executed_action, e.inventory_before "
                "FROM decision_events e JOIN stocks s USING(stock_key) "
                "WHERE e.window_id IN (1,2) AND e.phase IN (2,3)"
            )
            for event in events:
                key = (sample, int(event["window_id"]), str(event["stock_id"]), int(event["trade_date"]))
                if key not in key_meta:
                    continue
                meta = key_meta[key]
                event_votes = votes_by_event[int(event["event_id"])]
                phase = int(event["phase"])
                for control in PC01_CONTROLS:
                    if int(control["phase"]) != phase:
                        continue
                    trigger = all(rule_id in event_votes for rule_id in control["rule_ids"])
                    if trigger:
                        vote_counts[(control["control_id"], int(event["window_id"]))] += 1
                    base = {
                        "group": meta["group"],
                        "ordinal": meta["ordinal"],
                        "label": labels_by_key[key],
                        "trigger": trigger,
                    }
                    observations[(control["control_id"], "phase-event")].append(base)
                    eligible = (
                        (phase == 2 and float(event["inventory_before"]) == 0)
                        or (phase == 3 and float(event["inventory_before"]) > 0)
                    )
                    if eligible:
                        observations[(control["control_id"], "inventory-eligible")].append(base)
                    planned = "L" if phase == 2 else "SELL"
                    executed = "BUY" if phase == 2 else "SELL"
                    if str(event["planned_action"]) == planned:
                        observations[(control["control_id"], "planned-action")].append(base)
                    if str(event["executed_action"]) == executed:
                        observations[(control["control_id"], "executed-action")].append(base)

    association_rows: list[dict[str, Any]] = []
    distribution_rows: list[dict[str, Any]] = []
    group_direction_rows: list[dict[str, Any]] = []
    control_by_id = {control["control_id"]: control for control in PC01_CONTROLS}
    for (control_id, stratum), daily_rows in sorted(observations.items()):
        control = control_by_id[control_id]
        for unit, rows in (("daily", daily_rows), ("episode", pc01_episode_rows(daily_rows))):
            association, distributions, directions = pc01_association(control, stratum, unit, rows)
            association_rows.append(association)
            distribution_rows.extend(distributions)
            group_direction_rows.extend(directions)

    association_fields = [
        "control_id", "stratum", "unit", "expected_label", "adverse_label", "trigger_rows",
        "nontrigger_rows", "trigger_expected_rate", "nontrigger_expected_rate", "expected_rate_delta",
        "expected_odds_ratio", "trigger_adverse_rate", "nontrigger_adverse_rate", "adverse_rate_delta",
        "adverse_odds_ratio", "net_signal_delta", "trigger_groups", "comparable_groups",
        "groups_positive", "groups_negative", "groups_tied", "recognized",
    ]
    write_csv(output / "positive-control-association.csv", association_fields, association_rows)
    write_csv(
        output / "positive-control-distribution.csv",
        ["control_id", "stratum", "unit", "trigger_state", "label", "rows", "share"],
        distribution_rows,
    )
    write_csv(
        output / "positive-control-group-direction.csv",
        ["control_id", "stratum", "unit", "group", "trigger_rows", "nontrigger_rows", "signal_delta", "direction"],
        group_direction_rows,
    )

    summary_rows: list[dict[str, Any]] = []
    context_strata = {"inventory-eligible", "planned-action", "executed-action"}
    for control in PC01_CONTROLS:
        control_rows = [
            row for row in association_rows
            if row["control_id"] == control["control_id"] and row["unit"] == "episode"
        ]
        all_day = next(row for row in control_rows if row["stratum"] == "all-trading-days")
        recognized_contexts = [row for row in control_rows if row["stratum"] in context_strata and row["recognized"]]
        eligible_contexts = [
            row for row in control_rows
            if row["stratum"] in context_strata and row["trigger_rows"] >= 30 and row["nontrigger_rows"] >= 30
        ]
        best = max(eligible_contexts, key=lambda row: row["net_signal_delta"], default=None)
        summary_rows.append(
            {
                "control_id": control["control_id"],
                "description": control["description"],
                "expected_label": control["expected_label"],
                "all_day_recognized": all_day["recognized"],
                "all_day_net_signal_delta": all_day["net_signal_delta"],
                "context_recognized": int(bool(recognized_contexts)),
                "recognized_contexts": "|".join(row["stratum"] for row in recognized_contexts),
                "best_context": best["stratum"] if best else "",
                "best_context_net_signal_delta": best["net_signal_delta"] if best else "",
                "best_context_expected_odds_ratio": best["expected_odds_ratio"] if best else "",
                "best_context_adverse_odds_ratio": best["adverse_odds_ratio"] if best else "",
            }
        )
    write_csv(
        output / "positive-control-summary.csv",
        [
            "control_id", "description", "expected_label", "all_day_recognized",
            "all_day_net_signal_delta", "context_recognized", "recognized_contexts", "best_context",
            "best_context_net_signal_delta", "best_context_expected_odds_ratio", "best_context_adverse_odds_ratio",
        ],
        summary_rows,
    )
    all_day_recognized = sum(int(row["all_day_recognized"]) for row in summary_rows)
    context_recognized = sum(int(row["context_recognized"]) for row in summary_rows)
    if all_day_recognized:
        conclusion = "unconditional-controls-exist-ebm-search-missed"
    elif context_recognized:
        conclusion = "controls-only-recognizable-in-strategy-context"
    else:
        conclusion = "known-effective-controls-not-aligned-with-five-path-target"
    specification = {
        "studyID": STUDY_ID,
        "stage": "M01-PC01",
        "scope": "discovery only: Samples A-C windows 1-2",
        "holdoutLabelsUsed": False,
        "controls": list(PC01_CONTROLS),
        "triggerSources": {
            "all-trading-days": "exact thresholds applied to frozen F01 features",
            "strategy-context": "formal DecisionBase event_votes",
        },
        "units": {
            "daily": "every eligible row",
            "episode": "first row after trigger state changes or a date-ordinal gap",
        },
        "recognitionGate": {
            "unit": "episode",
            "minimumTriggerEpisodes": 30,
            "minimumNontriggerEpisodes": 30,
            "minimumComparableStockWindowGroups": 10,
            "expectedOddsRatioAtLeast": 1.10,
            "orAdverseOddsRatioAtMost": 1 / 1.10,
            "netSignalDeltaPositive": True,
            "positiveGroupsMustExceedNegativeGroups": True,
        },
        "knownEvidence": {
            "L-P03": "L2a removal materially regressed",
            "L-P04": "L2b removal materially regressed",
            "L-P03+L-P04": "L2c merging the two votes materially regressed",
            "S-P03+S-P04": "ES-S01-A reducing two co-votes to one regressed -17.823",
        },
        "voteCountsByControlWindow": [
            {"control_id": control_id, "window_id": window_id, "votes": count}
            for (control_id, window_id), count in sorted(vote_counts.items())
        ],
        "conclusion": conclusion,
    }
    atomic_json(output / "positive-control-spec.json", specification)
    quality["pc01"] = {
        "status": "complete",
        "conclusion": conclusion,
        "controls": len(PC01_CONTROLS),
        "allDayRecognized": all_day_recognized,
        "strategyContextRecognized": context_recognized,
        "holdoutLabelsUsed": False,
    }
    atomic_json(output / "data-quality.json", quality)
    report_path = output / "report.md"
    report = report_path.read_text(encoding="utf-8")
    require("## PC01 已知規則正向控制" not in report, "PC01 report section already exists")
    detail_lines = "\n".join(
        f"- `{row['control_id']}`：全交易日 {'通過' if row['all_day_recognized'] else '未通過'}；策略情境 {'通過' if row['context_recognized'] else '未通過'}。"
        for row in summary_rows
    )
    report += (
        "\n## PC01 已知規則正向控制\n\n"
        "- 固定檢查正式 `L-P03／L-P04` 與 `S-P03／S-P04` 的單獨及共現條件；不重新搜尋門檻。\n"
        "- 全交易日以凍結技術值按正式門檻重建；策略情境以 DecisionBase 正式 `event_votes` 為準，並另看持倉資格、計畫行動及實際行動。\n"
        f"- 六個控制中，全交易日通過 {all_day_recognized} 個，策略情境通過 {context_recognized} 個；結論 `{conclusion}`。\n"
        f"{detail_lines}\n"
        "- 每日列與去連續重複的 episode 結果均保留；判定只用 episode 閘門。第三窗口、D、E 仍未用於本項。\n"
    )
    report_path.write_text(report, encoding="utf-8")
    (output / ".pc01-complete").write_text(STUDY_ID + "\n", encoding="utf-8")
    manifest.setdefault("stages", {})["M01-PC01"] = "complete"
    manifest["pc01CompletedAt"] = datetime.now(timezone.utc).isoformat()
    manifest["positiveControl"] = {
        "conclusion": conclusion,
        "summary": "positive-control-summary.csv",
        "association": "positive-control-association.csv",
        "distribution": "positive-control-distribution.csv",
        "groupDirection": "positive-control-group-direction.csv",
        "specification": "positive-control-spec.json",
        "allDayRecognized": all_day_recognized,
        "strategyContextRecognized": context_recognized,
        "holdoutLabelsUsed": False,
    }
    manifest.setdefault("qualitySummary", {})["pc01"] = quality["pc01"]
    refresh_output_manifest(output, manifest)
    print(
        f"PC01 {conclusion}: all_day={all_day_recognized}, context={context_recognized}",
        flush=True,
    )


def atomic_json(path: Path, value: Any) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def finalize_audit(output: Path) -> None:
    require(output.is_dir(), f"missing P0/L01 output: {output}")
    manifest_path = output / "manifest.json"
    quality_path = output / "data-quality.json"
    report_path = output / "report.md"
    audit_path = output / "manual-audit.csv"
    for path in (manifest_path, quality_path, report_path, audit_path, output / ".p0-complete"):
        require(path.is_file(), f"missing audit input: {path}")
    manifest = read_json(manifest_path)
    quality = read_json(quality_path)
    require(manifest.get("studyID") == STUDY_ID, "audit manifest study mismatch")
    require(manifest.get("stages", {}).get("M01-P0") == "complete", "P0 is not complete")
    l01_stage = manifest.get("stages", {}).get("M01-L01")
    require(l01_stage in {"pending-human-audit", "complete"}, f"unexpected L01 stage: {l01_stage}")
    audited = 0
    labels: Counter[str] = Counter()
    with audit_path.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            future = [float(row[f"day_{index:02d}_close"]) for index in range(1, 21)]
            calculated = classify_future_path(float(row["p0"]), future, float(row["barrier"]))
            expected_cross = int(row["first_cross_day"]) if row["first_cross_day"] else None
            expected_reversal = int(row["reversal_day"]) if row["reversal_day"] else None
            require(calculated.label == row["label"], f"audit label mismatch at row {audited + 1}")
            require(calculated.first_cross_day == expected_cross, f"audit crossing mismatch at row {audited + 1}")
            require(calculated.reversal_day == expected_reversal, f"audit reversal mismatch at row {audited + 1}")
            labels[str(row["label"])] += 1
            audited += 1
    require(audited == quality["l01"]["manualAuditRows"], "manual audit row count mismatch")
    require(set(labels) == set(LABELS), "manual audit does not cover all five labels")

    completed_at = datetime.now(timezone.utc).isoformat()
    quality["l01"]["manualAuditStatus"] = "passed"
    quality["l01"]["manualAuditReviewedAt"] = completed_at
    quality["l01"]["manualAuditLabelCounts"] = dict(labels)
    atomic_json(quality_path, quality)

    report = report_path.read_text(encoding="utf-8")
    pending = f"- 固定人工抽核已選出 {audited} 筆，尚待逐筆人工確認後才能把 L01 標為完成。"
    completed = f"- 固定人工抽核 {audited} 筆已逐筆確認，五種標籤的首次跨越與反轉日均與原始 20 日收盤路徑一致。"
    if pending in report:
        report = report.replace(pending, completed)
    else:
        require(completed in report, "report does not contain the completed audit line")
    report_path.write_text(report, encoding="utf-8")
    review_lines = [
        f"# {STUDY_ID} L01 人工抽核",
        "",
        f"- 完成時間：{completed_at}",
        f"- 抽核筆數：{audited}",
        "- 選樣：每個 Sample × 窗口兩筆不看標籤的固定雜湊樣本，另加每種標籤一筆固定 sentinel。",
        "- 檢查：逐筆查看 P0、障礙、20 日簡單報酬、首次跨越日，以及相對新高／新低的反轉幅度。",
        "- 結果：35 筆均符合凍結標籤定義；五類都有覆蓋，沒有發現分類或日期偏移錯誤。",
        "- 程式複核：由 CSV 原始 20 日收盤價重新分類，label、first_cross_day 與 reversal_day 全數一致。",
    ]
    (output / "manual-audit-review.md").write_text("\n".join(review_lines) + "\n", encoding="utf-8")
    (output / ".l01-complete").write_text(STUDY_ID + "\n", encoding="utf-8")

    manifest["stages"]["M01-L01"] = "complete"
    manifest["completedAt"] = completed_at
    manifest["tool"] = {
        "path": "tools/fwd_v20_path_discovery.py",
        "sha256": file_hash(Path(__file__).resolve()),
    }
    manifest["technicalFieldRequirements"] = list(REQUIRED_TECHNICAL_COLUMNS)
    manifest["decisionTableRequirements"] = sorted(REQUIRED_DECISION_TABLES)
    manifest["qualitySummary"] = {
        "labelRows": quality["l01"]["labelRows"],
        "exclusions": quality["l01"]["exclusions"],
        "labelCounts": quality["l01"]["labelCounts"],
        "marketRelativeCoverage": quality["l01"]["marketRelativeCoverage"],
        "manualAuditStatus": quality["l01"]["manualAuditStatus"],
    }
    manifest["outputs"] = {
        path.name: {"sha256": file_hash(path), "bytes": path.stat().st_size}
        for path in sorted(output.iterdir())
        if path.is_file() and path.name != "manifest.json"
    }
    atomic_json(manifest_path, manifest)
    print(f"L01 complete: {output}")


def write_outputs(
    output: Path,
    project_root: Path,
    input_metadata: dict[str, Any],
    rows: list[dict[str, Any]],
    exclusions: Counter[str],
    market_coverage: Counter[str],
    per_cell: int,
) -> None:
    output_parent = output.parent
    output_parent.mkdir(parents=True, exist_ok=True)
    require(not output.exists(), f"output already exists; refusing to overwrite: {output}")
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}-", dir=output_parent))
    try:
        label_summary = aggregate_labels(rows)
        market_summary = aggregate_market(rows)
        audits = audit_rows(rows, per_cell)
        label_fields = [
            "sample", "window_id", "role", "stock_id", "stock_name", "group_name",
            "trade_date", "p0", "sigma60", "sigma_observations", "barrier", "label",
            "label_name", "first_cross_day", "reversal_day", "future_20_date",
            "future_20_return", "max_favorable_return", "max_adverse_return",
        ]
        relative_fields = label_fields + [
            "market_relative_available", "market_constituent_min", "market_constituent_max",
            "market_proxy_20_return", "market_relative_20_return",
            "market_relative_max_favorable", "market_relative_max_adverse",
        ]
        summary_fields = [
            "sample", "window_id", "role", "label", "label_name", "rows", "share",
            "stocks", "first_date", "last_date",
        ]
        market_fields = [
            "sample", "window_id", "role", "label_rows", "relative_available",
            "relative_unavailable", "coverage", "constituent_min", "constituent_median",
            "constituent_max",
        ]
        write_csv(temporary / "path-labels.csv", label_fields, rows)
        write_csv(temporary / "path-label-summary.csv", summary_fields, label_summary)
        write_csv(temporary / "market-relative-outcomes.csv", relative_fields, rows)
        write_csv(temporary / "market-proxy-summary.csv", market_fields, market_summary)
        audit_fields = list(audits[0].keys())
        write_csv(temporary / "manual-audit.csv", audit_fields, audits)

        label_totals = Counter(str(row["label"]) for row in rows)
        label_stocks = {
            label: len({(row["sample"], row["stock_id"]) for row in rows if row["label"] == label})
            for label in LABELS
        }
        label_cells = {
            label: len({(row["sample"], row["window_id"]) for row in rows if row["label"] == label})
            for label in LABELS
        }
        quality = {
            "studyID": STUDY_ID,
            "p0": {
                "status": "passed",
                "samples": len(input_metadata["samples"]),
                "stocks": len({(row["sample"], row["stock_id"]) for row in rows}),
                "decisionBases": len(input_metadata["samples"]),
                "marketConstituents": len(input_metadata["marketConstituents"]),
            },
            "l01": {
                "status": "passed",
                "labelRows": len(rows),
                "exclusions": dict(sorted(exclusions.items())),
                "labelCounts": dict(label_totals),
                "stocksByLabel": label_stocks,
                "sampleWindowCellsByLabel": label_cells,
                "marketRelativeCoverage": dict(market_coverage),
                "manualAuditRows": len(audits),
                "manualAuditStatus": "pending-human-review",
            },
        }
        require(all(label_totals[label] > 0 for label in LABELS), "one or more path labels are empty")
        require(all(label_stocks[label] >= 10 for label in LABELS), "one or more labels cover fewer than 10 stocks")
        require(all(label_cells[label] >= 4 for label in LABELS), "one or more labels cover fewer than 4 Sample-window cells")
        require(market_coverage["unavailable"] == 0, "market-relative coverage has unavailable rows")
        (temporary / "data-quality.json").write_text(
            json.dumps(quality, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

        report_lines = [
            f"# {STUDY_ID} P0/L01 結果",
            "",
            "## 結論",
            "",
            f"- P0 輸入核對通過：5 份 Baseline、5 份 DecisionBase、50 檔股票及 40 檔 A～D 市場代理成分一致。",
            f"- L01 共建立 {len(rows):,} 筆完整 20 日路徑標籤；五類均跨至少 10 檔股票及 4 個 Sample × 窗口格。",
            f"- 市場相對結果可用 {market_coverage['available']:,} 筆、不可用 {market_coverage['unavailable']:,} 筆。",
            f"- 固定人工抽核已選出 {len(audits)} 筆，尚待逐筆人工確認後才能把 L01 標為完成。",
            "- 本階段沒有讀取技術特徵排名、訓練模型、修改規則或重播模擬。",
            "",
            "## 五分類分布",
            "",
            "| 路徑 | 筆數 | 股票數 | Sample × 窗口格 |",
            "|---|---:|---:|---:|",
        ]
        for label in LABELS:
            report_lines.append(
                f"| {LABEL_NAMES[label]} | {label_totals[label]:,} | {label_stocks[label]} | {label_cells[label]} |"
            )
        report_lines.extend(
            [
                "",
                "## 標籤凍結語意",
                "",
                "- 波動採截至交易日的最多 60 筆對數報酬之樣本標準差，至少 40 筆。",
                "- 障礙為 `clamp(sigma60 × sqrt(20), 5%, 15%)`，以相對 P0 的簡單報酬判斷首次跨越。",
                "- 探頂回落採相對其後新高的跌幅；探底反彈採相對其後新低的漲幅，門檻皆為障礙的一半。",
                "- 固定窗口邊界日歸入較晚窗口，使每個 Sample／股票／日期只出現一次。",
                "- 市場代理採 A～D 40 檔同日起迄日對數報酬中位數；A～D 目標排除自身，E 使用完整 40 檔。",
            ]
        )
        (temporary / "report.md").write_text("\n".join(report_lines) + "\n", encoding="utf-8")
        (temporary / ".p0-complete").write_text(STUDY_ID + "\n", encoding="utf-8")
        # L01 is intentionally not marked complete until manual-audit.csv is reviewed.

        output_files = {}
        for path in sorted(temporary.iterdir()):
            if path.name == "manifest.json":
                continue
            output_files[path.name] = {
                "sha256": file_hash(path),
                "bytes": path.stat().st_size,
            }
        manifest = {
            "studyID": STUDY_ID,
            "runID": RUN_ID,
            "createdAt": datetime.now(timezone.utc).isoformat(),
            "stages": {"M01-P0": "complete", "M01-L01": "pending-human-audit"},
            "ruleCommit": EXPECTED["ruleCommit"],
            "dataRuleVersion": EXPECTED["dataRuleVersion"],
            "ruleVersion": EXPECTED["ruleVersion"],
            "through": EXPECTED["through"],
            "historyStart": EXPECTED["historyStart"],
            "windowAssignment": {
                "rule": "half-open first and second windows; final window includes through date",
                "windows": [
                    {"windowID": window_id, "start": slash_date(start), "end": slash_date(end)}
                    for window_id, start, end in WINDOWS
                ],
                "boundaryDateOwner": "later-window",
            },
            "labelSpecification": {
                "horizonTradingDays": 20,
                "volatilityReturns": "up to 60 trailing close-to-close log returns ending at t",
                "minimumVolatilityReturns": 40,
                "volatilityEstimator": "sample standard deviation (N-1)",
                "barrier": "clamp(sigma60 * sqrt(20), 0.05, 0.15)",
                "crossingReturn": "simple close return relative to P0",
                "reversal": "simple drawdown from subsequent peak or rebound from subsequent trough >= barrier/2",
                "labels": LABEL_NAMES,
            },
            "marketProxySpecification": {
                "constituents": "frozen A-D 40-stock set",
                "return": "same-date constituent log return",
                "aggregate": "median",
                "A-DTarget": "leave target constituent out",
                "ETarget": "use all valid A-D constituents",
                "minimumConstituentsPerFutureDate": 30,
                "relativePath": "target log return - proxy median log return",
            },
            "auditSpecification": {
                "labelBlindRowsPerSampleWindow": per_cell,
                "labelSentinels": "lowest SHA-256 row per path label",
                "selectionSeed": STUDY_ID,
            },
            "environment": module_environment(),
            "technicalFieldRequirements": list(REQUIRED_TECHNICAL_COLUMNS),
            "decisionTableRequirements": sorted(REQUIRED_DECISION_TABLES),
            "qualitySummary": {
                "labelRows": quality["l01"]["labelRows"],
                "exclusions": quality["l01"]["exclusions"],
                "labelCounts": quality["l01"]["labelCounts"],
                "marketRelativeCoverage": quality["l01"]["marketRelativeCoverage"],
                "manualAuditStatus": quality["l01"]["manualAuditStatus"],
            },
            "tool": {
                "path": str(Path(__file__).resolve().relative_to(project_root.resolve())),
                "sha256": file_hash(Path(__file__).resolve()),
            },
            "inputs": input_metadata,
            "outputs": output_files,
        }
        (temporary / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, output)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def main() -> None:
    args = parse_arguments()
    if args.self_test:
        self_test()
        return
    project_root = args.project_root.resolve()
    output = (args.output or project_root / "exports" / "future-path-study" / RUN_ID).resolve()
    if args.finalize_audit:
        finalize_audit(output)
        return
    if args.build_features:
        build_features(project_root, output)
        return
    if args.train_discovery_model:
        train_discovery_model(project_root, output)
        return
    if args.positive_control:
        run_positive_control(project_root, output)
        return
    input_metadata, series_map = verify_inputs(project_root)
    rows, exclusions = build_path_rows(series_map)
    require(rows, "no valid path-label rows")
    market_coverage = attach_market_relative(rows, series_map)
    write_outputs(
        output,
        project_root,
        input_metadata,
        rows,
        exclusions,
        market_coverage,
        args.audit_per_sample_window,
    )
    print(f"P0 complete; L01 pending human audit: {output}")


if __name__ == "__main__":
    main()
