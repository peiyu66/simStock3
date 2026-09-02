#!/usr/bin/env python3
"""Compare the frozen 40-stock market proxy with the qualified TAIEX history."""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import math
import os
import shutil
import statistics
import tempfile
from pathlib import Path
from typing import Any, Iterable, Sequence

import fwd_v20_path_discovery as fwd
import market_data_pool as pool
import market_snapshot_reuse as reuse


ROOT = Path(__file__).resolve().parents[1]
SOURCE_STUDY = ROOT / "exports/future-path-study/fwd-v20-m01-abcde-t2s39-20260902"
TAIEX_SNAPSHOT = (
    ROOT / "exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af"
)
OUTPUT_ROOT = ROOT / "exports/market-data/taiex/research"
STUDY_ID = "MKT-D01-R1"
TOOL_VERSION = "market-proxy-taiex-comparison-v1"
MATERIAL_RELATIVE_RETURN = 0.01
COMPARISON_FIELDS = [
    "sample", "window_id", "role", "stock_id", "stock_name", "group_name",
    "trade_date", "p0", "sigma60", "sigma_observations", "barrier", "label",
    "label_name", "first_cross_day", "reversal_day", "future_20_date",
    "future_20_return", "max_favorable_return", "max_adverse_return",
    "market_relative_available", "market_constituent_min", "market_constituent_max",
    "market_proxy_20_return", "market_relative_20_return",
    "market_relative_max_favorable", "market_relative_max_adverse",
]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise pool.MarketDataError(message)


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def encoded_value(value: Any) -> str:
    return "" if value is None else str(value)


def reproduce_proxy(
    rows: list[dict[str, Any]],
    series_map: dict[tuple[str, str], fwd.StockSeries],
    source_csv: Path,
) -> dict[str, Any]:
    coverage = fwd.attach_market_relative(rows, series_map)
    expected = read_csv(source_csv)
    require(len(rows) == len(expected),
            f"proxy positive-control row count mismatch: {len(rows)} != {len(expected)}")
    mismatches: list[dict[str, Any]] = []
    comparisons = 0
    for index, (actual, frozen) in enumerate(zip(rows, expected)):
        for field in COMPARISON_FIELDS:
            comparisons += 1
            actual_text = encoded_value(actual.get(field))
            expected_text = frozen[field]
            if actual_text != expected_text:
                mismatches.append({
                    "row": index + 1,
                    "field": field,
                    "expected": expected_text,
                    "actual": actual_text,
                })
                if len(mismatches) >= 10:
                    break
        if len(mismatches) >= 10:
            break
    require(not mismatches, f"frozen proxy positive control failed: {mismatches[:3]}")
    return {
        "rows": len(rows),
        "fields": len(COMPARISON_FIELDS),
        "comparisons": comparisons,
        "mismatch_count": 0,
        "available": int(coverage["available"]),
        "unavailable": int(coverage["unavailable"]),
        "pair_cache_entries": int(coverage["pair_cache_entries"]),
        "passed": True,
    }


def taiex_close_lookup(snapshot: Path) -> tuple[dict[int, float], dict[str, Any]]:
    manifest = reuse.verify_mt_snapshot(snapshot)
    rows = read_csv(snapshot / "market-daily.csv")
    lookup = {int(row["date"].replace("-", "")): float(row["close"]) for row in rows}
    require(len(lookup) == len(rows), "TAIEX snapshot has duplicate dates")
    require(all(math.isfinite(value) and value > 0 for value in lookup.values()),
            "TAIEX snapshot has invalid closes")
    return lookup, manifest


def sign(value: float) -> int:
    if value > 0:
        return 1
    if value < 0:
        return -1
    return 0


def average_ranks(values: Sequence[float]) -> list[float]:
    order = sorted(range(len(values)), key=lambda index: values[index])
    result = [0.0] * len(values)
    index = 0
    while index < len(order):
        end = index + 1
        while end < len(order) and values[order[end]] == values[order[index]]:
            end += 1
        rank = (index + 1 + end) / 2.0
        for offset in range(index, end):
            result[order[offset]] = rank
        index = end
    return result


def pearson(left: Sequence[float], right: Sequence[float]) -> float:
    require(len(left) == len(right) and len(left) >= 2, "correlation requires paired values")
    left_mean = statistics.fmean(left)
    right_mean = statistics.fmean(right)
    numerator = 0.0
    left_sum = 0.0
    right_sum = 0.0
    for lhs, rhs in zip(left, right):
        left_delta = lhs - left_mean
        right_delta = rhs - right_mean
        numerator += left_delta * right_delta
        left_sum += left_delta * left_delta
        right_sum += right_delta * right_delta
    denominator = math.sqrt(left_sum * right_sum)
    return 0.0 if denominator == 0 else numerator / denominator


def spearman(left: Sequence[float], right: Sequence[float]) -> float:
    return pearson(average_ranks(left), average_ranks(right))


def percentile(values: Sequence[float], probability: float) -> float:
    require(bool(values) and 0 <= probability <= 1, "invalid percentile input")
    ordered = sorted(values)
    position = (len(ordered) - 1) * probability
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def comparison_metrics(rows: Sequence[dict[str, Any]]) -> dict[str, Any]:
    require(bool(rows), "comparison summary has no rows")
    proxy = [float(row["proxy_return"]) for row in rows]
    taiex = [float(row["taiex_return"]) for row in rows]
    differences = [lhs - rhs for lhs, rhs in zip(proxy, taiex)]
    absolute = [abs(value) for value in differences]
    return {
        "rows": len(rows),
        "pearson": pearson(proxy, taiex),
        "spearman": spearman(proxy, taiex),
        "direction_agreement_count": sum(sign(lhs) == sign(rhs) for lhs, rhs in zip(proxy, taiex)),
        "direction_agreement_rate": sum(sign(lhs) == sign(rhs) for lhs, rhs in zip(proxy, taiex)) / len(rows),
        "proxy_minus_taiex_mean": statistics.fmean(differences),
        "proxy_minus_taiex_median": statistics.median(differences),
        "mean_absolute_difference": statistics.fmean(absolute),
        "median_absolute_difference": statistics.median(absolute),
        "p90_absolute_difference": percentile(absolute, 0.90),
        "p95_absolute_difference": percentile(absolute, 0.95),
        "root_mean_squared_difference": math.sqrt(statistics.fmean(value * value for value in differences)),
    }


def build_comparisons(
    rows: list[dict[str, Any]],
    series_map: dict[tuple[str, str], fwd.StockSeries],
    taiex: dict[int, float],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    market_keys, stock_lookup = fwd.make_market_lookup(series_map)
    pair_values: dict[tuple[int, int], tuple[tuple[float, tuple[str, str]], ...]] = {}
    pair_records: dict[tuple[int, int], dict[str, Any]] = {}
    impact_rows: list[dict[str, Any]] = []
    missing_taiex_dates: set[int] = set()

    def constituents(start: int, future: int) -> tuple[tuple[float, tuple[str, str]], ...]:
        key = (start, future)
        if key not in pair_values:
            values = []
            for constituent in market_keys:
                start_close = stock_lookup[constituent].get(start)
                future_close = stock_lookup[constituent].get(future)
                if start_close is not None and future_close is not None and start_close > 0 and future_close > 0:
                    values.append((math.log(future_close / start_close), constituent))
            pair_values[key] = tuple(sorted(values))
        return pair_values[key]

    for row in rows:
        start_date = int(row["trade_date"])
        target_key = (str(row["sample"]), str(row["stock_id"]))
        excluded = target_key if row["sample"] in fwd.MARKET_SAMPLES else None
        taiex_start = taiex.get(start_date)
        if taiex_start is None:
            missing_taiex_dates.add(start_date)
            continue
        proxy_path: list[float] = []
        full_proxy_path: list[float] = []
        taiex_path: list[float] = []
        target_path: list[float] = []
        counts: list[int] = []
        for horizon, (future_date, future_close) in enumerate(
            zip(row["future_dates"], row["future_closes"]), start=1
        ):
            future_date = int(future_date)
            taiex_future = taiex.get(future_date)
            if taiex_future is None:
                missing_taiex_dates.add(future_date)
                continue
            values = constituents(start_date, future_date)
            leave_one_out, count = fwd.median_without(values, excluded)
            full_proxy, full_count = fwd.median_without(values, None)
            require(count >= 30 and full_count >= 30, "reconstructed proxy has too few constituents")
            taiex_return = math.log(taiex_future / taiex_start)
            target_return = math.log(float(future_close) / float(row["p0"]))
            proxy_path.append(leave_one_out)
            full_proxy_path.append(full_proxy)
            taiex_path.append(taiex_return)
            target_path.append(target_return)
            counts.append(count)
            key = (start_date, future_date)
            existing = pair_records.get(key)
            record = {
                "start_date": start_date,
                "future_date": future_date,
                "window_id": fwd.window_for(start_date),
                "start_year": start_date // 10000,
                "constituent_count": full_count,
                "proxy_return": full_proxy,
                "taiex_return": taiex_return,
                "proxy_minus_taiex": full_proxy - taiex_return,
                "absolute_difference": abs(full_proxy - taiex_return),
                "direction_agrees": sign(full_proxy) == sign(taiex_return),
                "horizon_min": horizon,
                "horizon_max": horizon,
            }
            if existing is None:
                pair_records[key] = record
            else:
                for field in ("constituent_count", "proxy_return", "taiex_return"):
                    require(existing[field] == record[field], f"pair value changed for {key}/{field}")
                existing["horizon_min"] = min(existing["horizon_min"], horizon)
                existing["horizon_max"] = max(existing["horizon_max"], horizon)

        if len(taiex_path) != 20:
            continue
        require(len(proxy_path) == len(full_proxy_path) == len(target_path) == 20,
                "comparison path width mismatch")
        require(proxy_path[-1] == float(row["market_proxy_20_return"]),
                f"leave-one-out endpoint mismatch: {row['sample']}/{row['stock_id']}/{start_date}")
        old_relative = target_path[-1] - proxy_path[-1]
        require(old_relative == float(row["market_relative_20_return"]),
                f"relative endpoint mismatch: {row['sample']}/{row['stock_id']}/{start_date}")
        taiex_relative = target_path[-1] - taiex_path[-1]
        relative_flip = sign(old_relative) != sign(taiex_relative)
        material_flip = relative_flip and abs(old_relative) >= MATERIAL_RELATIVE_RETURN and abs(taiex_relative) >= MATERIAL_RELATIVE_RETURN
        path_differences = [proxy - index for proxy, index in zip(proxy_path, taiex_path)]
        impact_rows.append({
            "sample": row["sample"],
            "window_id": row["window_id"],
            "role": row["role"],
            "stock_id": row["stock_id"],
            "label": row["label"],
            "label_name": row["label_name"],
            "trade_date": start_date,
            "future_20_date": row["future_20_date"],
            "market_constituent_min": min(counts),
            "market_constituent_max": max(counts),
            "proxy_return": proxy_path[-1],
            "full_40_proxy_return": full_proxy_path[-1],
            "taiex_return": taiex_path[-1],
            "proxy_minus_taiex": proxy_path[-1] - taiex_path[-1],
            "leave_one_out_minus_full_40": proxy_path[-1] - full_proxy_path[-1],
            "proxy_taiex_direction_agrees": sign(proxy_path[-1]) == sign(taiex_path[-1]),
            "path_direction_agreement_rate": sum(
                sign(proxy) == sign(index) for proxy, index in zip(proxy_path, taiex_path)
            ) / 20.0,
            "path_mean_absolute_difference": statistics.fmean(abs(value) for value in path_differences),
            "path_max_absolute_difference": max(abs(value) for value in path_differences),
            "stock_log_return": target_path[-1],
            "proxy_relative_return": old_relative,
            "taiex_relative_return": taiex_relative,
            "relative_sign_flipped": relative_flip,
            "material_relative_sign_flipped": material_flip,
        })

    require(not missing_taiex_dates,
            f"TAIEX is missing {len(missing_taiex_dates)} required dates: {sorted(missing_taiex_dates)[:5]}")
    require(len(impact_rows) == len(rows),
            f"TAIEX impact coverage mismatch: {len(impact_rows)} != {len(rows)}")
    pair_rows = [pair_records[key] for key in sorted(pair_records)]
    require(len(pair_rows) == len(pair_values), "unique pair record/cache count mismatch")
    return pair_rows, impact_rows, {
        "required_path_rows": len(rows),
        "available_path_rows": len(impact_rows),
        "unavailable_path_rows": 0,
        "unique_date_pairs": len(pair_rows),
        "missing_taiex_date_count": 0,
        "passed": True,
    }


def summarize_pairs(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: list[tuple[str, str, list[dict[str, Any]]]] = [("all", "all", rows)]
    for window in (1, 2, 3):
        groups.append(("window", str(window), [row for row in rows if row["window_id"] == window]))
    for year in sorted({row["start_year"] for row in rows}):
        groups.append(("year", str(year), [row for row in rows if row["start_year"] == year]))
    output = []
    for kind, key, members in groups:
        output.append({"slice_kind": kind, "slice": key, **comparison_metrics(members)})
    return output


def impact_metrics(rows: Sequence[dict[str, Any]]) -> dict[str, Any]:
    require(bool(rows), "impact summary has no rows")
    endpoint_abs = [abs(float(row["proxy_minus_taiex"])) for row in rows]
    loo_abs = [abs(float(row["leave_one_out_minus_full_40"])) for row in rows]
    path_mae = [float(row["path_mean_absolute_difference"]) for row in rows]
    return {
        "rows": len(rows),
        "endpoint_direction_agreement_rate": sum(bool(row["proxy_taiex_direction_agrees"]) for row in rows) / len(rows),
        "endpoint_median_absolute_difference": statistics.median(endpoint_abs),
        "endpoint_p95_absolute_difference": percentile(endpoint_abs, 0.95),
        "mean_path_direction_agreement_rate": statistics.fmean(float(row["path_direction_agreement_rate"]) for row in rows),
        "median_path_mean_absolute_difference": statistics.median(path_mae),
        "relative_sign_flip_count": sum(bool(row["relative_sign_flipped"]) for row in rows),
        "relative_sign_flip_rate": sum(bool(row["relative_sign_flipped"]) for row in rows) / len(rows),
        "material_relative_sign_flip_count": sum(bool(row["material_relative_sign_flipped"]) for row in rows),
        "material_relative_sign_flip_rate": sum(bool(row["material_relative_sign_flipped"]) for row in rows) / len(rows),
        "leave_one_out_median_absolute_effect": statistics.median(loo_abs),
        "leave_one_out_p95_absolute_effect": percentile(loo_abs, 0.95),
    }


def summarize_impacts(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: list[tuple[str, str, list[dict[str, Any]]]] = [("all", "all", rows)]
    for sample in fwd.SAMPLES:
        groups.append(("sample", sample, [row for row in rows if row["sample"] == sample]))
    for sample in fwd.SAMPLES:
        for window in (1, 2, 3):
            groups.append(("sample_window", f"{sample}-W{window}", [
                row for row in rows if row["sample"] == sample and int(row["window_id"]) == window
            ]))
    for label in fwd.LABELS:
        groups.append(("path_label", label, [row for row in rows if row["label"] == label]))
    return [
        {"slice_kind": kind, "slice": key, **impact_metrics(members)}
        for kind, key, members in groups
    ]


PAIR_FIELDS = [
    "start_date", "future_date", "window_id", "start_year", "horizon_min", "horizon_max",
    "constituent_count", "proxy_return", "taiex_return", "proxy_minus_taiex",
    "absolute_difference", "direction_agrees",
]
IMPACT_FIELDS = [
    "sample", "window_id", "role", "stock_id", "label", "label_name", "trade_date",
    "future_20_date", "market_constituent_min", "market_constituent_max", "proxy_return",
    "full_40_proxy_return", "taiex_return", "proxy_minus_taiex",
    "leave_one_out_minus_full_40", "proxy_taiex_direction_agrees",
    "path_direction_agreement_rate", "path_mean_absolute_difference",
    "path_max_absolute_difference", "stock_log_return", "proxy_relative_return",
    "taiex_relative_return", "relative_sign_flipped", "material_relative_sign_flipped",
]


def csv_data(rows: Iterable[dict[str, Any]], fields: Sequence[str]) -> bytes:
    buffer = io.StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=fields, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return buffer.getvalue().encode()


def json_data(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def report_data(
    pair_summary: list[dict[str, Any]],
    impact_summary: list[dict[str, Any]],
    positive: dict[str, Any],
    coverage: dict[str, Any],
) -> bytes:
    overall_pair = next(row for row in pair_summary if row["slice_kind"] == "all")
    overall_impact = next(row for row in impact_summary if row["slice_kind"] == "all")
    lines = [
        "# MKT-D01-R1 真實 TAIEX 與 40 檔市場代理比較",
        "",
        "## 結論",
        "",
        f"- 舊市場代理正向控制重現 {positive['rows']:,} 筆、{positive['comparisons']:,} 個欄位值，錯配 0。",
        f"- 真實 TAIEX 完整涵蓋 {coverage['available_path_rows']:,} 筆 20 日路徑與 {coverage['unique_date_pairs']:,} 組不同起訖日期，缺日 0。",
        f"- 40 檔完整中位數代理與 TAIEX 在日期配對層的 Pearson 為 {overall_pair['pearson']:.6f}、Spearman 為 {overall_pair['spearman']:.6f}、方向一致率為 {overall_pair['direction_agreement_rate']:.2%}。",
        f"- 日期配對的報酬絕對差中位為 {overall_pair['median_absolute_difference']:.4%}，第 95 百分位為 {overall_pair['p95_absolute_difference']:.4%}。",
        f"- 換成 TAIEX 後，個股市場相對報酬正負號翻轉 {overall_impact['relative_sign_flip_count']:,} 筆（{overall_impact['relative_sign_flip_rate']:.2%}）；兩側絕對值皆至少 1% 的實質翻轉 {overall_impact['material_relative_sign_flip_count']:,} 筆（{overall_impact['material_relative_sign_flip_rate']:.2%}）。",
        "- 本研究只描述市場控制差異，沒有讀取 MT1 技術條件、訓練模型、產生交易候選或執行 simUpdate。",
        "",
        "## 判讀界線",
        "",
        "- 40 檔代理是特選股票的等權中位數；TAIEX 是正式指數。相關與方向一致不會把代理變成正式指數。",
        "- 主要相似度以不同起訖日期為單位，不把同日多檔股票當成獨立市場證據。108,274 筆股票列只用來量測更換控制值後的影響。",
        "- 本計畫沒有事後設定單一合格門檻；完整數值按窗口、年份、Sample 與路徑類型保留，供決定未來採 TAIEX 主控制或保留代理作敏感度檢查。",
        "- 五分類仍是個股絕對價格路徑，沒有因市場控制更換而重標。",
        "",
        "## 分窗口日期配對比較",
        "",
        "| 窗口 | 配對 | Pearson | Spearman | 方向一致 | 絕對差中位 | 絕對差 P95 |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for row in pair_summary:
        if row["slice_kind"] != "window":
            continue
        lines.append(
            f"| W{row['slice']} | {row['rows']:,} | {row['pearson']:.4f} | {row['spearman']:.4f} | "
            f"{row['direction_agreement_rate']:.2%} | {row['median_absolute_difference']:.3%} | "
            f"{row['p95_absolute_difference']:.3%} |"
        )
    lines.extend([
        "",
        "完整逐配對、逐股票影響、分年與分群摘要見同目錄 CSV；manifest 保存輸入及輸出 SHA-256。",
    ])
    return ("\n".join(lines) + "\n").encode()


def publish(output: Path, files: dict[str, bytes]) -> None:
    if output.exists():
        existing = {
            path.name: path.read_bytes() for path in output.iterdir() if path.is_file()
        }
        require(existing == files, f"existing immutable R1 output differs: {output}")
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
    source_study = args.source_study.resolve()
    taiex_snapshot = args.taiex_snapshot.resolve()
    source_manifest = json.loads((source_study / "manifest.json").read_text())
    source_relative = source_study / "market-relative-outcomes.csv"
    expected_hash = source_manifest["outputs"]["market-relative-outcomes.csv"]["sha256"]
    require(pool.sha256(source_relative.read_bytes()) == expected_hash,
            "frozen market-relative input hash mismatch")

    input_metadata, series_map = fwd.verify_inputs(ROOT)
    rows, exclusions = fwd.build_path_rows(series_map)
    require(len(rows) == source_manifest["qualitySummary"]["labelRows"],
            "reconstructed path-label row count mismatch")
    positive = reproduce_proxy(rows, series_map, source_relative)
    taiex, taiex_manifest = taiex_close_lookup(taiex_snapshot)
    pair_rows, impact_rows, coverage = build_comparisons(rows, series_map, taiex)
    pair_summary = summarize_pairs(pair_rows)
    impact_summary = summarize_impacts(impact_rows)

    pair_bytes = csv_data(pair_rows, PAIR_FIELDS)
    impact_bytes = csv_data(impact_rows, IMPACT_FIELDS)
    pair_summary_fields = ["slice_kind", "slice", *comparison_metrics(pair_rows).keys()]
    impact_summary_fields = ["slice_kind", "slice", *impact_metrics(impact_rows).keys()]
    pair_summary_bytes = csv_data(pair_summary, pair_summary_fields)
    impact_summary_bytes = csv_data(impact_summary, impact_summary_fields)
    quality = {
        "study_id": STUDY_ID,
        "status": "complete-descriptive-market-control-comparison",
        "source_study_run_id": source_manifest["runID"],
        "taiex_snapshot_id": taiex_manifest["snapshot_id"],
        "proxy_positive_control": positive,
        "taiex_coverage": coverage,
        "path_exclusions_reproduced": dict(sorted(exclusions.items())),
        "unique_pair_overall": next(row for row in pair_summary if row["slice_kind"] == "all"),
        "stock_row_impact_overall": next(row for row in impact_summary if row["slice_kind"] == "all"),
        "material_relative_return_threshold": MATERIAL_RELATIVE_RETURN,
        "market_similarity_adoption_threshold": None,
        "network_access_guarded": True,
        "network_request_count": 0,
        "mt1_features_read": False,
        "model_trained": False,
        "rule_candidates_generated": 0,
        "simupdate_run_count": 0,
        "passed": True,
    }
    quality_bytes = json_data(quality)
    report_bytes = report_data(pair_summary, impact_summary, positive, coverage)
    identity = hashlib.sha256(
        TOOL_VERSION.encode()
        + expected_hash.encode()
        + taiex_manifest["snapshot_id"].encode()
        + pair_bytes
        + impact_bytes
    ).hexdigest()
    run_id = f"mkt-d01-r1-taiex-vs-proxy-20260902-{identity[:12]}"
    output_files = {
        "pair-comparison.csv": pair_bytes,
        "stock-row-impact.csv": impact_bytes,
        "pair-summary.csv": pair_summary_bytes,
        "impact-summary.csv": impact_summary_bytes,
        "quality-report.json": quality_bytes,
        "report.md": report_bytes,
    }
    manifest = {
        "study_id": STUDY_ID,
        "run_id": run_id,
        "tool": "tools/market_proxy_taiex_comparison.py",
        "tool_version": TOOL_VERSION,
        "source_study": {
            "run_id": source_manifest["runID"],
            "manifest_sha256": pool.sha256((source_study / "manifest.json").read_bytes()),
            "market_relative_outcomes_sha256": expected_hash,
        },
        "taiex_snapshot": {
            "snapshot_id": taiex_manifest["snapshot_id"],
            "manifest_sha256": pool.sha256((taiex_snapshot / "manifest.json").read_bytes()),
        },
        "baseline_inputs": {
            sample: {
                "run_id": input_metadata["samples"][sample]["report"]["runID"],
                "manifest_sha256": input_metadata["samples"][sample]["report"]["inputFiles"]["manifest"]["sha256"],
            }
            for sample in fwd.SAMPLES
        },
        "row_key": ["sample", "stock_id", "trade_date"],
        "primary_market_unit": ["start_date", "future_date"],
        "window_assignment": source_manifest["windowAssignment"],
        "market_proxy_specification": source_manifest["marketProxySpecification"],
        "taiex_return": "log(TAIEX future close / TAIEX start close) on the exact frozen target dates",
        "outputs": {
            name: {"sha256": pool.sha256(data), "bytes": len(data)}
            for name, data in sorted(output_files.items())
        },
        "qualification_passed": True,
    }
    output_files["manifest.json"] = json_data(manifest)
    output_files[".complete"] = (run_id + "\n").encode()
    output = args.output_root.resolve() / run_id
    publish(output, output_files)
    return output


def build(args: argparse.Namespace) -> Path:
    with reuse.forbid_network() as network:
        output = build_offline(args)
    require(network["count"] == 0, "R1 attempted an unexpected network request")
    return output


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-study", type=Path, default=SOURCE_STUDY)
    parser.add_argument("--taiex-snapshot", type=Path, default=TAIEX_SNAPSHOT)
    parser.add_argument("--output-root", type=Path, default=OUTPUT_ROOT)
    return parser.parse_args()


def main() -> int:
    args = arguments()
    try:
        output = build(args)
        print(output)
        return 0
    except (OSError, KeyError, ValueError, json.JSONDecodeError, pool.MarketDataError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
