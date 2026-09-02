#!/usr/bin/env python3
"""Build and qualify the offline MT1 TAIEX market-technical snapshot."""

from __future__ import annotations

import argparse
import csv
import io
import json
import math
import sqlite3
import tempfile
from pathlib import Path
from typing import Any, Iterable

import market_data_pool as pool


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INPUT = (
    ROOT
    / "exports/market-data/taiex/normalized"
    / "market-daily-v1-20260722-f7316dd6c522"
)
DEFAULT_POOL_ROOT = ROOT / "exports/market-data/taiex"
DEFAULT_BASELINE_STORE = (
    ROOT
    / "exports/backtest-reports"
    / "baseline-a-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-t2s39-9y-fixed3y-600w-20260901"
    / "browse.store"
)
VERSION = "MT1"
TOOL_VERSION = "market-technical-v1"
APPLE_REFERENCE_UNIX_OFFSET = 978_307_200


PRICE_FIELDS = [
    "market_high_from_prev_close_pct",
    "market_low_from_prev_close_pct",
    "market_high_diff_125",
    "market_high_diff_250",
    "market_high_diff_z_125",
    "market_high_diff_z_250",
    "market_high_max_9",
    "market_low_diff_125",
    "market_low_diff_250",
    "market_low_diff_z_125",
    "market_low_diff_z_250",
    "market_low_min_9",
    "market_ma_20",
    "market_ma_20_days",
    "market_ma_20_diff",
    "market_ma_20_diff_max_9",
    "market_ma_20_diff_min_9",
    "market_ma_20_diff_z_125",
    "market_ma_20_diff_z_250",
    "market_ma_60",
    "market_ma_60_days",
    "market_ma_60_diff",
    "market_ma_60_diff_max_9",
    "market_ma_60_diff_min_9",
    "market_ma_60_diff_z_125",
    "market_ma_60_diff_z_250",
    "market_z_125",
    "market_z_250",
    "market_kd_k",
    "market_kd_k_max_9",
    "market_kd_k_min_9",
    "market_kd_k_z_125",
    "market_kd_k_z_250",
    "market_kd_d",
    "market_kd_d_z_125",
    "market_kd_d_z_250",
    "market_kd_j",
    "market_kd_j_z_125",
    "market_kd_j_z_250",
    "market_osc",
    "market_osc_ema_12",
    "market_osc_ema_26",
    "market_osc_macd_9",
    "market_osc_max_9",
    "market_osc_min_9",
    "market_osc_z_125",
    "market_osc_z_250",
]

ACTIVITY_SUFFIXES = [
    "ma_20",
    "ma_20_days",
    "ma_20_diff",
    "ma_20_diff_max_9",
    "ma_20_diff_min_9",
    "ma_20_diff_z_125",
    "ma_20_diff_z_250",
    "ma_60",
    "ma_60_days",
    "ma_60_diff",
    "ma_60_diff_max_9",
    "ma_60_diff_min_9",
    "ma_60_diff_z_125",
    "ma_60_diff_z_250",
    "max_9",
    "min_9",
    "z_125",
    "z_250",
]
ACTIVITY_SPECS = (
    ("market_volume", "volume_lots", "張"),
    ("market_value", "trade_value", "元"),
    ("market_transaction", "transaction_count", "筆"),
)
META_FIELDS = [
    "date",
    "price_observation_count",
    "price_mature_125",
    "price_mature_250",
    "market_volume_observation_count",
    "market_volume_mature_125",
    "market_volume_mature_250",
    "market_value_observation_count",
    "market_value_mature_125",
    "market_value_mature_250",
    "market_transaction_observation_count",
    "market_transaction_mature_125",
    "market_transaction_mature_250",
]
TECHNICAL_FIELDS = PRICE_FIELDS + [
    f"{prefix}_{suffix}" for prefix, _, _ in ACTIVITY_SPECS for suffix in ACTIVITY_SUFFIXES
]
OUTPUT_FIELDS = META_FIELDS + TECHNICAL_FIELDS

# Fixed before the prefix checks are run. Every date exists in the P1 input.
CUTOFF_DATES = [
    "2017-01-11",
    "2017-08-24",
    "2018-06-20",
    "2019-04-16",
    "2020-02-11",
    "2020-11-30",
    "2021-09-27",
    "2022-07-22",
    "2023-05-23",
    "2024-03-19",
    "2025-01-09",
    "2025-11-07",
]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise pool.MarketDataError(message)


def add_in_order(values: Iterable[float]) -> float:
    total = 0.0
    for value in values:
        total += value
    return total


def swift_round(value: float) -> float:
    """Swift round(): nearest, with exact ties away from zero."""
    if value >= 0:
        return float(math.floor(value + 0.5))
    return float(math.ceil(value - 0.5))


def rounded_percent_difference(value: float, average: float) -> float:
    if value == 0:
        return 0.0
    return swift_round(10000.0 * (value - average) / value) / 100.0


def population_z(values: list[float], *, current: float | None = None) -> float:
    require(bool(values), "z-score requires at least one observation")
    average = add_in_order(values) / float(len(values))
    variance_sum = 0.0
    for value in values:
        variance_sum += math.pow(value - average, 2)
    standard_deviation = math.sqrt(variance_sum / float(len(values)))
    endpoint = values[-1] if current is None else current
    return 0.0 if standard_deviation == 0 else (endpoint - average) / standard_deviation


def window_start(index: int, count: int) -> int:
    return index - count + 1 if index >= count else 0


def price_trend_days(
    rows: list[dict[str, float]],
    index: int,
    value_key: str,
    days_key: str,
    *,
    positive_lookup_allows_equal: bool,
) -> float:
    previous = rows[index - 1]
    previous_days = previous[days_key]
    days_before = 0.0
    if previous_days < 0 and previous_days > -5:
        lookup = index - int(-previous_days + 1)
        if lookup >= 0:
            days_before = rows[lookup][days_key]
    elif previous_days > 0 and previous_days < 5:
        required = int(previous_days + 1)
        allowed = index >= required if positive_lookup_allows_equal else index > required
        if allowed:
            days_before = rows[index - required][days_key]

    current_value = rows[index][value_key]
    previous_value = previous[value_key]
    if current_value > previous_value:
        if previous_days < 0:
            return days_before + 1 if previous_days > -5 and days_before > 0 else 1.0
        return previous_days + 1
    if current_value < previous_value:
        if previous_days > 0:
            return days_before - 1 if previous_days < 5 and days_before < 0 else -1.0
        return previous_days - 1
    if previous_days > 0:
        return previous_days + 1
    if previous_days < 0:
        return previous_days - 1
    return 0.0


def calculate_price(source_rows: list[dict[str, Any]]) -> list[dict[str, float]]:
    results: list[dict[str, float]] = []
    for index, source in enumerate(source_rows):
        open_value = float(source["open"])
        high = max(float(source["high"]), float(source["close"]))
        low = min(float(source["low"]), float(source["close"]))
        close = float(source["close"])
        demand_index = (high + low + 2.0 * close) / 4.0
        result = {field: 0.0 for field in PRICE_FIELDS}
        result.update({"open": open_value, "high": high, "low": low, "close": close})

        if index == 0:
            result["market_kd_k"] = 50.0
            result["market_kd_d"] = 50.0
            result["market_kd_j"] = 50.0
            result["market_osc_ema_12"] = demand_index
            result["market_osc_ema_26"] = demand_index
            results.append(result)
            continue

        previous = results[index - 1]
        start9 = window_start(index, 9)
        start20 = window_start(index, 20)
        start60 = window_start(index, 60)
        start125 = window_start(index, 125)
        start250 = window_start(index, 250)

        result["market_high_max_9"] = max(
            [row["high"] for row in results[start9:]] + [high]
        )
        result["market_low_min_9"] = min(
            [row["low"] for row in results[start9:]] + [low]
        )
        result["market_high_from_prev_close_pct"] = (
            100.0 * (high - previous["close"]) / previous["close"]
        )
        result["market_low_from_prev_close_pct"] = (
            100.0 * (previous["close"] - low) / previous["close"]
        )

        close60 = [row["close"] for row in results[start60:]] + [close]
        close20 = [row["close"] for row in results[start20:]] + [close]
        result["market_ma_60"] = add_in_order(close60) / float(len(close60))
        result["market_ma_20"] = add_in_order(close20) / float(len(close20))
        result["market_ma_60_diff"] = rounded_percent_difference(close, result["market_ma_60"])
        result["market_ma_20_diff"] = rounded_percent_difference(close, result["market_ma_20"])

        rsv = 50.0
        if result["market_high_max_9"] != result["market_low_min_9"]:
            rsv = 100.0 * (close - result["market_low_min_9"]) / (
                result["market_high_max_9"] - result["market_low_min_9"]
            )
        result["market_kd_k"] = 2.0 * previous["market_kd_k"] / 3.0 + rsv / 3.0
        result["market_kd_d"] = (
            2.0 * previous["market_kd_d"] / 3.0 + result["market_kd_k"] / 3.0
        )
        result["market_kd_j"] = 3.0 * result["market_kd_k"] - 2.0 * result["market_kd_d"]

        double_demand = 2.0 * demand_index
        result["market_osc_ema_12"] = (
            11.0 * previous["market_osc_ema_12"] + double_demand
        ) / 13.0
        result["market_osc_ema_26"] = (
            25.0 * previous["market_osc_ema_26"] + double_demand
        ) / 27.0
        dif = result["market_osc_ema_12"] - result["market_osc_ema_26"]
        result["market_osc_macd_9"] = (8.0 * previous["market_osc_macd_9"] + 2.0 * dif) / 10.0
        result["market_osc"] = dif - result["market_osc_macd_9"]

        # The current row must participate in every trailing window.
        results.append(result)
        recent9 = results[start9 : index + 1]
        for source_key, max_key, min_key in (
            ("market_ma_20_diff", "market_ma_20_diff_max_9", "market_ma_20_diff_min_9"),
            ("market_ma_60_diff", "market_ma_60_diff_max_9", "market_ma_60_diff_min_9"),
            ("market_osc", "market_osc_max_9", "market_osc_min_9"),
            ("market_kd_k", "market_kd_k_max_9", "market_kd_k_min_9"),
        ):
            result[max_key] = max(row[source_key] for row in recent9)
            result[min_key] = min(row[source_key] for row in recent9)

        for count, start in ((125, start125), (250, start250)):
            window = results[start : index + 1]
            high_price = max(row["high"] for row in window)
            low_price = min(row["low"] for row in window)
            result[f"market_high_diff_{count}"] = 100.0 * (close - high_price) / high_price
            result[f"market_low_diff_{count}"] = 100.0 * (close - low_price) / low_price

        for count, start in ((125, start125), (250, start250)):
            window = results[start : index + 1]
            result[f"market_kd_k_z_{count}"] = population_z(
                [row["market_kd_k"] for row in window]
            )
            result[f"market_kd_d_z_{count}"] = population_z(
                [row["market_kd_d"] for row in window]
            )
            result[f"market_kd_j_z_{count}"] = population_z(
                [row["market_kd_j"] for row in window]
            )
            result[f"market_osc_z_{count}"] = population_z(
                [row["market_osc"] for row in window]
            )
            result[f"market_ma_20_diff_z_{count}"] = population_z(
                [row["market_ma_20_diff"] for row in window]
            )
            result[f"market_ma_60_diff_z_{count}"] = population_z(
                [row["market_ma_60_diff"] for row in window]
            )
            result[f"market_z_{count}"] = population_z([row["close"] for row in window])
            result[f"market_high_diff_z_{count}"] = population_z(
                [row[f"market_high_diff_{count}"] for row in window]
            )
            result[f"market_low_diff_z_{count}"] = population_z(
                [row[f"market_low_diff_{count}"] for row in window]
            )

        result["market_ma_20_days"] = price_trend_days(
            results,
            index,
            "market_ma_20",
            "market_ma_20_days",
            positive_lookup_allows_equal=False,
        )
        result["market_ma_60_days"] = price_trend_days(
            results,
            index,
            "market_ma_60",
            "market_ma_60_days",
            positive_lookup_allows_equal=True,
        )
    return results


def activity_trend_days(
    current: float, previous: float, previous_days: float, prior_results: list[dict[str, float]], key: str
) -> float:
    days_before = 0.0
    run_length = int(abs(previous_days))
    if 0 < run_length < 5 and len(prior_results) >= run_length + 1:
        days_before = prior_results[-run_length - 1][key]
    if current > previous:
        if previous_days < 0:
            return days_before + 1 if previous_days > -5 and days_before > 0 else 1.0
        return previous_days + 1
    if current < previous:
        if previous_days > 0:
            return days_before - 1 if previous_days < 5 and days_before < 0 else -1.0
        return previous_days - 1
    if previous_days > 0:
        return previous_days + 1
    if previous_days < 0:
        return previous_days - 1
    return 0.0


def calculate_activity(values: list[float]) -> list[dict[str, float]]:
    results: list[dict[str, float]] = []
    for index, value in enumerate(values):
        result = {suffix: 0.0 for suffix in ACTIVITY_SUFFIXES}
        newest = list(reversed(values[max(0, index - 249) : index + 1]))
        recent20 = newest[:20]
        recent60 = newest[:60]
        result["ma_20"] = add_in_order(recent20) / float(len(recent20))
        result["ma_60"] = add_in_order(recent60) / float(len(recent60))
        result["ma_20_diff"] = rounded_percent_difference(value, result["ma_20"])
        result["ma_60_diff"] = rounded_percent_difference(value, result["ma_60"])
        result["z_125"] = population_z(newest[:125], current=value)
        result["z_250"] = population_z(newest[:250], current=value)

        if index > 0:
            previous = results[index - 1]
            result["ma_20_days"] = activity_trend_days(
                result["ma_20"], previous["ma_20"], previous["ma_20_days"], results, "ma_20_days"
            )
            result["ma_60_days"] = activity_trend_days(
                result["ma_60"], previous["ma_60"], previous["ma_60_days"], results, "ma_60_days"
            )

        recent_result9 = (results + [result])[-9:]
        raw9 = values[max(0, index - 8) : index + 1]
        result["max_9"] = max(raw9)
        result["min_9"] = min(raw9)
        result["ma_20_diff_max_9"] = max(row["ma_20_diff"] for row in recent_result9)
        result["ma_20_diff_min_9"] = min(row["ma_20_diff"] for row in recent_result9)
        result["ma_60_diff_max_9"] = max(row["ma_60_diff"] for row in recent_result9)
        result["ma_60_diff_min_9"] = min(row["ma_60_diff"] for row in recent_result9)

        newest_results = list(reversed(results + [result]))[:250]
        result["ma_20_diff_z_125"] = population_z(
            [row["ma_20_diff"] for row in newest_results[:125]], current=result["ma_20_diff"]
        )
        result["ma_20_diff_z_250"] = population_z(
            [row["ma_20_diff"] for row in newest_results[:250]], current=result["ma_20_diff"]
        )
        result["ma_60_diff_z_125"] = population_z(
            [row["ma_60_diff"] for row in newest_results[:125]], current=result["ma_60_diff"]
        )
        result["ma_60_diff_z_250"] = population_z(
            [row["ma_60_diff"] for row in newest_results[:250]], current=result["ma_60_diff"]
        )
        results.append(result)
    return results


def read_market_daily(path: Path) -> tuple[list[dict[str, Any]], bytes]:
    data = path.read_bytes()
    rows = list(csv.DictReader(io.StringIO(data.decode("utf-8"))))
    require(bool(rows), f"no market rows: {path}")
    require(all(rows[index]["date"] < rows[index + 1]["date"] for index in range(len(rows) - 1)),
            "market dates are not strictly increasing")
    return rows, data


def calculate_market(source_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    price = calculate_price(source_rows)
    activities = {
        prefix: calculate_activity([float(row[source]) for row in source_rows])
        for prefix, source, _ in ACTIVITY_SPECS
    }
    output: list[dict[str, Any]] = []
    for index, source in enumerate(source_rows):
        count = index + 1
        row: dict[str, Any] = {
            "date": source["date"],
            "price_observation_count": count,
            "price_mature_125": count >= 125,
            "price_mature_250": count >= 250,
        }
        row.update({field: price[index][field] for field in PRICE_FIELDS})
        for prefix, _, _ in ACTIVITY_SPECS:
            row[f"{prefix}_observation_count"] = count
            row[f"{prefix}_mature_125"] = count >= 125
            row[f"{prefix}_mature_250"] = count >= 250
            row.update({f"{prefix}_{suffix}": activities[prefix][index][suffix]
                        for suffix in ACTIVITY_SUFFIXES})
        output.append(row)
    return output


def encode_csv(rows: list[dict[str, Any]], fields: list[str]) -> bytes:
    buffer = io.StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=fields, lineterminator="\n")
    writer.writeheader()
    for row in rows:
        encoded: dict[str, Any] = {}
        for field in fields:
            value = row[field]
            if isinstance(value, bool):
                encoded[field] = "true" if value else "false"
            elif isinstance(value, float):
                require(math.isfinite(value), f"non-finite output {field}")
                encoded[field] = repr(value)
            else:
                encoded[field] = value
        writer.writerow(encoded)
    return buffer.getvalue().encode("utf-8")


def synthetic_qualification() -> dict[str, Any]:
    length = 300
    price_sequences = {
        "flat": [100.0] * length,
        "increasing": [100.0 + index * 0.1 for index in range(length)],
        "decreasing": [140.0 - index * 0.1 for index in range(length)],
        "v_reversal": [100.0 + abs(index - 150) * 0.1 for index in range(length)],
        "single_high_low_spike": [100.0] * length,
    }
    price_checks: dict[str, Any] = {}
    price_results: dict[str, list[dict[str, float]]] = {}
    for name, closes in price_sequences.items():
        rows = []
        for index, close in enumerate(closes):
            high = close + 1.0
            low = close - 1.0
            if name == "single_high_low_spike" and index == 150:
                high, low = 160.0, 40.0
            rows.append({"open": close, "high": high, "low": low, "close": close})
        calculated = calculate_price(rows)
        price_results[name] = calculated
        require(all(math.isfinite(row[field]) for row in calculated for field in PRICE_FIELDS),
                f"synthetic price {name} produced non-finite value")
        price_checks[name] = {"rows": length, "passed": True}
    require(price_results["flat"][-1]["market_z_250"] == 0,
            "flat price z-score is not zero")
    require(price_results["increasing"][-1]["market_ma_20_diff"] > 0,
            "increasing price MA direction failed")
    require(price_results["decreasing"][-1]["market_ma_20_diff"] < 0,
            "decreasing price MA direction failed")
    require(price_results["v_reversal"][140]["market_ma_20_diff"] < 0
            and price_results["v_reversal"][170]["market_ma_20_diff"] > 0,
            "V-reversal direction change failed")
    require(price_results["single_high_low_spike"][150]["market_high_max_9"] == 160
            and price_results["single_high_low_spike"][150]["market_low_min_9"] == 40
            and price_results["single_high_low_spike"][159]["market_high_max_9"] == 101
            and price_results["single_high_low_spike"][159]["market_low_min_9"] == 99,
            "price spike rolling extrema failed")

    activity_sequences = {
        "fixed": [1000.0] * length,
        "increasing": [1000.0 + index for index in range(length)],
        "decreasing": [1400.0 - index for index in range(length)],
        "single_expansion": [4000.0 if index == 150 else 1000.0 for index in range(length)],
        "single_contraction": [0.0 if index == 150 else 1000.0 for index in range(length)],
        "legal_zero": [0.0] * length,
    }
    activity_checks: dict[str, Any] = {}
    activity_results: dict[str, list[dict[str, float]]] = {}
    for name, values in activity_sequences.items():
        calculated = calculate_activity(values)
        activity_results[name] = calculated
        require(all(math.isfinite(row[field]) for row in calculated for field in ACTIVITY_SUFFIXES),
                f"synthetic activity {name} produced non-finite value")
        activity_checks[name] = {"rows": length, "passed": True}
    require(activity_results["fixed"][-1]["z_250"] == 0,
            "fixed activity z-score is not zero")
    require(activity_results["legal_zero"][-1]["ma_20_diff"] == 0,
            "zero activity denominator handling failed")
    require(activity_results["increasing"][-1]["ma_20_diff"] > 0,
            "increasing activity direction failed")
    require(activity_results["decreasing"][-1]["ma_20_diff"] < 0,
            "decreasing activity direction failed")
    require(activity_results["single_expansion"][150]["max_9"] == 4000
            and activity_results["single_expansion"][150]["ma_20_diff"] > 0
            and activity_results["single_expansion"][159]["max_9"] == 1000,
            "activity expansion rolling extrema failed")
    require(activity_results["single_contraction"][150]["min_9"] == 0
            and activity_results["single_contraction"][150]["ma_20_diff"] == 0
            and activity_results["single_contraction"][159]["min_9"] == 1000,
            "activity contraction or zero denominator handling failed")
    return {"price": price_checks, "activity": activity_checks, "passed": True}


PRICE_CONTROL_MAP = {
    "market_high_diff_125": "ZTHIGHDIFF125",
    "market_high_diff_250": "ZTHIGHDIFF250",
    "market_high_diff_z_125": "ZTHIGHDIFFZ125",
    "market_high_diff_z_250": "ZTHIGHDIFFZ250",
    "market_high_max_9": "ZTHIGHMAX9",
    "market_low_diff_125": "ZTLOWDIFF125",
    "market_low_diff_250": "ZTLOWDIFF250",
    "market_low_diff_z_125": "ZTLOWDIFFZ125",
    "market_low_diff_z_250": "ZTLOWDIFFZ250",
    "market_low_min_9": "ZTLOWMIN9",
    "market_ma_20": "ZTMA20",
    "market_ma_20_days": "ZTMA20DAYS",
    "market_ma_20_diff": "ZTMA20DIFF",
    "market_ma_20_diff_max_9": "ZTMA20DIFFMAX9",
    "market_ma_20_diff_min_9": "ZTMA20DIFFMIN9",
    "market_ma_20_diff_z_125": "ZTMA20DIFFZ125",
    "market_ma_20_diff_z_250": "ZTMA20DIFFZ250",
    "market_ma_60": "ZTMA60",
    "market_ma_60_days": "ZTMA60DAYS",
    "market_ma_60_diff": "ZTMA60DIFF",
    "market_ma_60_diff_max_9": "ZTMA60DIFFMAX9",
    "market_ma_60_diff_min_9": "ZTMA60DIFFMIN9",
    "market_ma_60_diff_z_125": "ZTMA60DIFFZ125",
    "market_ma_60_diff_z_250": "ZTMA60DIFFZ250",
    "market_z_125": "ZTZ125",
    "market_z_250": "ZTZ250",
    "market_kd_k": "ZTKDK",
    "market_kd_k_max_9": "ZTKDKMAX9",
    "market_kd_k_min_9": "ZTKDKMIN9",
    "market_kd_k_z_125": "ZTKDKZ125",
    "market_kd_k_z_250": "ZTKDKZ250",
    "market_kd_d": "ZTKDD",
    "market_kd_d_z_125": "ZTKDDZ125",
    "market_kd_d_z_250": "ZTKDDZ250",
    "market_kd_j": "ZTKDJ",
    "market_kd_j_z_125": "ZTKDJZ125",
    "market_kd_j_z_250": "ZTKDJZ250",
    "market_osc": "ZTOSC",
    "market_osc_ema_12": "ZTOSCEMA12",
    "market_osc_ema_26": "ZTOSCEMA26",
    "market_osc_macd_9": "ZTOSCMACD9",
    "market_osc_max_9": "ZTOSCMAX9",
    "market_osc_min_9": "ZTOSCMIN9",
    "market_osc_z_125": "ZTOSCZ125",
    "market_osc_z_250": "ZTOSCZ250",
}
ACTIVITY_CONTROL_MAP = {
    "ma_20": "ZVMA20",
    "ma_20_days": "ZVMA20DAYS",
    "ma_20_diff": "ZVMA20DIFF",
    "ma_20_diff_max_9": "ZVMA20DIFFMAX9",
    "ma_20_diff_min_9": "ZVMA20DIFFMIN9",
    "ma_20_diff_z_125": "ZVMA20DIFFZ125",
    "ma_20_diff_z_250": "ZVMA20DIFFZ250",
    "ma_60": "ZVMA60",
    "ma_60_days": "ZVMA60DAYS",
    "ma_60_diff": "ZVMA60DIFF",
    "ma_60_diff_max_9": "ZVMA60DIFFMAX9",
    "ma_60_diff_min_9": "ZVMA60DIFFMIN9",
    "ma_60_diff_z_125": "ZVMA60DIFFZ125",
    "ma_60_diff_z_250": "ZVMA60DIFFZ250",
    "max_9": "ZVMAX9",
    "min_9": "ZVMIN9",
    "z_125": "ZVZ125",
    "z_250": "ZVZ250",
}
EXACT_CONTROL_FIELDS = {
    "market_ma_20_diff", "market_ma_60_diff",
    "market_ma_20_diff_max_9", "market_ma_20_diff_min_9",
    "market_ma_60_diff_max_9", "market_ma_60_diff_min_9",
    "market_ma_20_days", "market_ma_60_days",
    *(f"market_volume_{suffix}" for suffix in (
        "ma_20_diff", "ma_60_diff", "ma_20_diff_max_9", "ma_20_diff_min_9",
        "ma_60_diff_max_9", "ma_60_diff_min_9", "ma_20_days", "ma_60_days"
    )),
}


def baseline_positive_control(store: Path, stock_id: str) -> dict[str, Any]:
    require(store.exists(), f"positive-control store missing: {store}")
    control_columns = list(PRICE_CONTROL_MAP.values()) + list(ACTIVITY_CONTROL_MAP.values())
    query = f"""
        SELECT date(t.ZDATETIME + {APPLE_REFERENCE_UNIX_OFFSET}, 'unixepoch') AS date,
               t.ZPRICEOPEN, t.ZPRICEHIGH, t.ZPRICELOW, t.ZPRICECLOSE, t.ZVOLUMECLOSE,
               {', '.join('t.' + column for column in control_columns)}
          FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK = t.ZSTOCK
         WHERE s.ZSID = ? AND t.ZDATASOURCE = 'TWSE'
         ORDER BY t.ZDATETIME
    """
    connection = sqlite3.connect(f"file:{store}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        stored = [dict(row) for row in connection.execute(query, (stock_id,))]
    finally:
        connection.close()
    require(bool(stored), f"positive-control stock not found: {stock_id}")
    source = [
        {"open": row["ZPRICEOPEN"], "high": row["ZPRICEHIGH"], "low": row["ZPRICELOW"],
         "close": row["ZPRICECLOSE"]}
        for row in stored
    ]
    price = calculate_price(source)
    volume = calculate_activity([float(row["ZVOLUMECLOSE"]) for row in stored])
    max_error = 0.0
    comparisons = 0
    exact_comparisons = 0
    mismatches: list[dict[str, Any]] = []
    for index, stored_row in enumerate(stored):
        for output_field, column in PRICE_CONTROL_MAP.items():
            expected = float(stored_row[column])
            actual = price[index][output_field]
            error = abs(actual - expected)
            max_error = max(max_error, error)
            comparisons += 1
            exact = output_field in EXACT_CONTROL_FIELDS
            exact_comparisons += int(exact)
            if (actual != expected) if exact else (error > 1e-9):
                mismatches.append({"date": stored_row["date"], "field": output_field,
                                   "expected": expected, "actual": actual, "absolute_error": error})
        for suffix, column in ACTIVITY_CONTROL_MAP.items():
            output_field = f"market_volume_{suffix}"
            expected = float(stored_row[column])
            actual = volume[index][suffix]
            error = abs(actual - expected)
            max_error = max(max_error, error)
            comparisons += 1
            exact = output_field in EXACT_CONTROL_FIELDS
            exact_comparisons += int(exact)
            if (actual != expected) if exact else (error > 1e-9):
                mismatches.append({"date": stored_row["date"], "field": output_field,
                                   "expected": expected, "actual": actual, "absolute_error": error})
    require(not mismatches, f"T2 positive control mismatch: {mismatches[:3]}")
    return {
        "baseline_store": str(store.relative_to(ROOT)),
        "stock_id": stock_id,
        "date_start": stored[0]["date"],
        "date_end": stored[-1]["date"],
        "rows": len(stored),
        "price_fields": len(PRICE_CONTROL_MAP),
        "volume_fields": len(ACTIVITY_CONTROL_MAP),
        "comparisons": comparisons,
        "exact_comparisons": exact_comparisons,
        "tolerance_comparisons": comparisons - exact_comparisons,
        "tolerance": 1e-9,
        "mismatch_count": 0,
        "maximum_absolute_error": max_error,
        "passed": True,
    }


def prefix_qualification(source_rows: list[dict[str, Any]], full: list[dict[str, Any]]) -> dict[str, Any]:
    by_date = {row["date"]: index for index, row in enumerate(source_rows)}
    checks = []
    for cutoff in CUTOFF_DATES:
        require(cutoff in by_date, f"fixed cutoff date absent: {cutoff}")
        end = by_date[cutoff] + 1
        prefix = calculate_market(source_rows[:end])
        mismatches = 0
        for index, prefix_row in enumerate(prefix):
            for field in OUTPUT_FIELDS:
                if prefix_row[field] != full[index][field]:
                    mismatches += 1
        require(mismatches == 0, f"future leakage at cutoff {cutoff}: {mismatches} values")
        checks.append({"cutoff": cutoff, "rows": end, "mismatch_count": mismatches, "passed": True})
    return {"cutoff_count": len(checks), "checks": checks, "passed": True}


def catalog_rows() -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    price_units = {
        "market_high_max_9": "指數點", "market_low_min_9": "指數點",
        "market_ma_20": "指數點", "market_ma_60": "指數點",
        "market_osc": "指數點", "market_osc_ema_12": "指數點",
        "market_osc_ema_26": "指數點", "market_osc_macd_9": "指數點",
        "market_osc_max_9": "指數點", "market_osc_min_9": "指數點",
    }
    for field in PRICE_FIELDS:
        if "_days" in field:
            unit, precision, family = "交易日", "整數值以 Double 保存", "MA 趨勢延續"
        elif "_z_" in field or field.endswith(("z_125", "z_250")):
            unit, precision, family = "標準分數", "Double", "母體標準差分"
        elif field in price_units:
            unit, precision, family = price_units[field], "Double", "價格或指標水準"
        elif field.startswith("market_kd_"):
            unit, precision, family = "無單位", "Double", "KD"
        else:
            unit, precision, family = "%", "MA Diff 為 0.01%，其餘 Double", "價格相對位置"
        warmup = "包含當日，最多 250 筆；成熟旗標另列" if "250" in field else (
            "包含當日，最多 125 筆；成熟旗標另列" if "125" in field else "自首筆遞增暖機"
        )
        rows.append({"field": field, "category": "price", "source": "TAIEX OHLC",
                     "formula_family": family, "unit": unit, "warmup": warmup,
                     "precision": precision, "current_reference": "technical.swift tUpdate"})
    for prefix, source, unit in ACTIVITY_SPECS:
        for suffix in ACTIVITY_SUFFIXES:
            output_unit = "交易日" if suffix.endswith("days") else (
                "%" if "diff" in suffix and "_z_" not in suffix else (
                    "標準分數" if suffix.startswith("z_") or "_z_" in suffix else unit
                )
            )
            rows.append({"field": f"{prefix}_{suffix}", "category": "market_activity",
                         "source": source, "formula_family": "通用 vUpdate 同族統計",
                         "unit": output_unit, "warmup": "合格日包含當日，最多 250 筆",
                         "precision": "Diff 為 0.01%，其餘 Double",
                         "current_reference": "technical.swift vUpdate"})
    require(len(rows) == 101, f"field catalog expected 101 technical fields, got {len(rows)}")
    return rows


def maturity_qualification(rows: list[dict[str, Any]], earliest_decision: str = "2017-07-22") -> dict[str, Any]:
    before = [row for row in rows if row["date"] < earliest_decision]
    require(bool(before), "no market observations before earliest decision")
    last = before[-1]
    counts = {field: last[field] for field in META_FIELDS if field.endswith("observation_count")}
    require(all(value >= 250 for value in counts.values()), f"immature at earliest decision: {counts}")
    require(all(
        row["price_observation_count"] == index + 1
        and row["market_volume_observation_count"] == index + 1
        and row["market_value_observation_count"] == index + 1
        and row["market_transaction_observation_count"] == index + 1
        for index, row in enumerate(rows)
    ), "observation count discontinuity")
    return {"earliest_baseline_decision_date": earliest_decision,
            "latest_observation_before_decision": last["date"], "counts": counts,
            "all_series_at_least_250": True, "passed": True}


def build(args: argparse.Namespace) -> Path:
    input_dir = args.input_dir.resolve()
    daily_path = input_dir / "market-daily.csv"
    complete_path = input_dir / ".complete"
    require(daily_path.exists() and complete_path.exists(), f"incomplete P1 input: {input_dir}")
    source_rows, daily_data = read_market_daily(daily_path)
    technical_rows = calculate_market(source_rows)
    technical_data = encode_csv(technical_rows, OUTPUT_FIELDS)
    catalog = catalog_rows()
    catalog_fields = ["field", "category", "source", "formula_family", "unit", "warmup",
                      "precision", "current_reference"]
    catalog_data = encode_csv(catalog, catalog_fields)

    synthetic = synthetic_qualification()
    positive = baseline_positive_control(args.baseline_store.resolve(), args.positive_control_stock)
    prefix = prefix_qualification(source_rows, technical_rows)
    maturity = maturity_qualification(technical_rows)
    second = encode_csv(calculate_market(source_rows), OUTPUT_FIELDS)
    require(technical_data == second, "two MT1 calculations were not deterministic")

    nonfinite = sum(
        1 for row in technical_rows for field in TECHNICAL_FIELDS
        if not math.isfinite(float(row[field]))
    )
    require(nonfinite == 0, f"non-finite technical values: {nonfinite}")
    technical_digest = pool.sha256(technical_data)
    snapshot_id = f"taiex-market-mt1-{source_rows[-1]['date'].replace('-', '')}-{technical_digest[:12]}"
    quality = {
        "snapshot_id": snapshot_id,
        "market_technical_version": VERSION,
        "source_dataset_id": complete_path.read_text().strip(),
        "date_start": source_rows[0]["date"],
        "date_end": source_rows[-1]["date"],
        "row_count": len(source_rows),
        "price_field_count": len(PRICE_FIELDS),
        "activity_series_count": len(ACTIVITY_SPECS),
        "activity_fields_per_series": len(ACTIVITY_SUFFIXES),
        "technical_field_count": len(TECHNICAL_FIELDS),
        "nonfinite_value_count": nonfinite,
        "synthetic_qualification": synthetic,
        "t2_positive_control": positive,
        "prefix_no_future_leakage": prefix,
        "maturity_qualification": maturity,
        "deterministic_rebuild_verified": True,
        "passed": True,
    }
    quality_data = pool.json_bytes(quality)
    manifest = {
        "snapshot_id": snapshot_id,
        "market_technical_version": VERSION,
        "tool": "tools/market_technical.py",
        "tool_version": TOOL_VERSION,
        "source_dataset_id": quality["source_dataset_id"],
        "source_dataset_path": str(input_dir.relative_to(ROOT)),
        "cutoff_date": source_rows[-1]["date"],
        "timezone": "+08:00",
        "row_count": len(source_rows),
        "technical_field_count": len(TECHNICAL_FIELDS),
        "files": {
            "market-daily.csv": pool.sha256(daily_data),
            "market-technical.csv": technical_digest,
            "field-catalog.csv": pool.sha256(catalog_data),
            "quality-report.json": pool.sha256(quality_data),
        },
        "qualification_passed": True,
        "deterministic_rebuild_verified": True,
        "rebuild_command": (
            "python3 tools/market_technical.py build "
            f"--input-dir {input_dir.relative_to(ROOT)} "
            f"--baseline-store {args.baseline_store.resolve().relative_to(ROOT)} "
            f"--positive-control-stock {args.positive_control_stock}"
        ),
    }
    manifest_data = pool.json_bytes(manifest)
    output_dir = args.pool_root.resolve() / "snapshots" / snapshot_id
    files = {
        "market-daily.csv": daily_data,
        "market-technical.csv": technical_data,
        "field-catalog.csv": catalog_data,
        "quality-report.json": quality_data,
        "manifest.json": manifest_data,
        ".complete": (snapshot_id + "\n").encode("utf-8"),
    }
    if output_dir.exists():
        for name, data in files.items():
            require((output_dir / name).exists() and (output_dir / name).read_bytes() == data,
                    f"existing snapshot differs: {output_dir / name}")
    else:
        output_dir.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=output_dir.parent) as temporary:
            staging = Path(temporary) / snapshot_id
            staging.mkdir()
            for name, data in files.items():
                pool.atomic_write(staging / name, data)
            staging.rename(output_dir)
    return output_dir


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    command = subparsers.add_parser("build", help="calculate and qualify immutable MT1 snapshot")
    command.add_argument("--input-dir", type=Path, default=DEFAULT_INPUT)
    command.add_argument("--pool-root", type=Path, default=DEFAULT_POOL_ROOT)
    command.add_argument("--baseline-store", type=Path, default=DEFAULT_BASELINE_STORE)
    command.add_argument("--positive-control-stock", default="2308")
    return parser.parse_args()


def main() -> int:
    args = arguments()
    try:
        if args.command == "build":
            output = build(args)
            print(output)
            return 0
    except (OSError, sqlite3.Error, pool.MarketDataError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
