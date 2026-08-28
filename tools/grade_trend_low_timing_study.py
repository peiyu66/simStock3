#!/usr/bin/env python3
"""GT-P02-D1: locate the price low before the first fitTrend climb."""

from __future__ import annotations

import argparse
import csv
import html
import json
import math
import sqlite3
import statistics
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path


CORE_DATA_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
MIN_OBSERVATIONS = 125
MIN_PRIMARY_TRADING_DAYS = 4
WORSENING_CONFIRMED = 5


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--sample",
        action="append",
        required=True,
        metavar="ID:DECISIONS_SQLITE:PRICE_STORE",
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--exclude-first-climb-day",
        action="store_true",
        help="Find the price low only through the day before the first fitTrend climb.",
    )
    parser.add_argument(
        "--min-climb-increase",
        type=float,
        default=0.0,
        help="Require fitTrend to exceed its prior-day value by more than this amount.",
    )
    parser.add_argument(
        "--min-climb-from-trough",
        type=float,
        default=None,
        help="Require fitTrend to exceed the running trough since worsening start by more than this amount.",
    )
    return parser.parse_args()


def parse_sample(value: str) -> tuple[str, Path, Path]:
    parts = value.split(":", 2)
    if len(parts) != 3:
        raise ValueError(f"invalid --sample: {value}")
    return parts[0].upper(), Path(parts[1]), Path(parts[2])


def ymd_from_core_data(value: float) -> int:
    return int((CORE_DATA_EPOCH + timedelta(seconds=value)).strftime("%Y%m%d"))


def load_observations(sample: str, database: Path) -> list[dict]:
    connection = sqlite3.connect(database)
    connection.row_factory = sqlite3.Row
    rows = connection.execute(
        """
        SELECT o.window_id, w.start_date, w.end_date, s.stock_id, s.name,
               s.group_name, o.trade_date, o.fit_trend_phase, o.fit_trend,
               o.fit_observation_count, o.is_valid, o.is_finite
        FROM strategy_fit_observations o
        JOIN windows w USING(window_id)
        JOIN stocks s USING(stock_key)
        ORDER BY o.window_id, s.stock_id, o.trade_date
        """
    ).fetchall()
    connection.close()
    return [dict(row) | {"sample": sample} for row in rows]


def load_prices(store: Path) -> dict[str, tuple[list[int], list[float], dict[int, int]]]:
    connection = sqlite3.connect(store)
    rows = connection.execute(
        """
        SELECT s.ZSID, t.ZDATETIME, t.ZPRICECLOSE
        FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK = t.ZSTOCK
        WHERE t.ZPRICECLOSE IS NOT NULL AND t.ZPRICECLOSE > 0
        ORDER BY s.ZSID, t.ZDATETIME
        """
    ).fetchall()
    connection.close()
    grouped: dict[str, list[tuple[int, float]]] = defaultdict(list)
    for stock_id, timestamp, close in rows:
        grouped[str(stock_id)].append((ymd_from_core_data(timestamp), float(close)))
    result = {}
    for stock_id, values in grouped.items():
        dates = [value[0] for value in values]
        closes = [value[1] for value in values]
        result[stock_id] = (dates, closes, {date: index for index, date in enumerate(dates)})
    return result


def valid(row: dict) -> bool:
    return (
        row["is_valid"] == 1
        and row["is_finite"] == 1
        and row["fit_trend"] is not None
        and row["fit_observation_count"] >= MIN_OBSERVATIONS
    )


def make_events(
    sample: str,
    observations: list[dict],
    prices: dict,
    exclude_first_climb_day: bool,
    min_climb_increase: float,
    min_climb_from_trough: float | None,
) -> tuple[list[dict], int]:
    grouped: dict[tuple[int, str], list[dict]] = defaultdict(list)
    for row in observations:
        grouped[(row["window_id"], row["stock_id"])].append(row)

    events = []
    censored = 0
    sequence = 0
    for (window_id, stock_id), rows in grouped.items():
        active = None
        waiting_for_exit = False
        previous_phase = None
        for row in rows:
            if not valid(row):
                if active is not None:
                    censored += 1
                    active = None
                waiting_for_exit = False
                previous_phase = None
                continue

            phase = row["fit_trend_phase"]
            if waiting_for_exit:
                if phase != WORSENING_CONFIRMED:
                    waiting_for_exit = False
                previous_phase = phase
                continue

            if active is None:
                if phase == WORSENING_CONFIRMED and previous_phase != WORSENING_CONFIRMED:
                    sequence += 1
                    active = {
                        "study_id": "GT-P02-D1",
                        "sample": sample,
                        "event_id": f"{sample}-{window_id}-{stock_id}-{sequence}",
                        "window_id": window_id,
                        "window_start": row["start_date"],
                        "window_end": row["end_date"],
                        "stock_id": stock_id,
                        "stock_name": row["name"],
                        "group_name": row["group_name"],
                        "worsening_start_date": row["trade_date"],
                        "worsening_start_trend": row["fit_trend"],
                        "previous_date": row["trade_date"],
                        "previous_trend": row["fit_trend"],
                        "running_trough_date": row["trade_date"],
                        "running_trough_trend": row["fit_trend"],
                    }
                previous_phase = phase
                continue

            if row["fit_trend"] < active["running_trough_trend"]:
                active["running_trough_date"] = row["trade_date"]
                active["running_trough_trend"] = row["fit_trend"]
            climb_increase = (
                row["fit_trend"] - active["running_trough_trend"]
                if min_climb_from_trough is not None
                else row["fit_trend"] - active["previous_trend"]
            )
            climb_threshold = min_climb_from_trough if min_climb_from_trough is not None else min_climb_increase
            if climb_increase > climb_threshold:
                active["first_climb_date"] = row["trade_date"]
                active["first_climb_trend"] = row["fit_trend"]
                active["first_climb_increase"] = climb_increase
                active["trend_trough_date"] = active["running_trough_date"]
                active["trend_trough_value"] = active["running_trough_trend"]
                active["prior_day_date"] = active["previous_date"]
                active["prior_day_trend"] = active["previous_trend"]
                event = attach_low_position(active, prices.get(stock_id), exclude_first_climb_day)
                if event is not None:
                    events.append(event)
                active = None
                waiting_for_exit = phase == WORSENING_CONFIRMED
            else:
                active["previous_date"] = row["trade_date"]
                active["previous_trend"] = row["fit_trend"]
            previous_phase = phase

        if active is not None:
            censored += 1
    return events, censored


def attach_low_position(event: dict, context, exclude_first_climb_day: bool) -> dict | None:
    if context is None:
        return None
    dates, closes, indexes = context
    start_date = event["worsening_start_date"]
    end_date = event["first_climb_date"]
    if start_date not in indexes or end_date not in indexes:
        return None
    start_index = indexes[start_date]
    end_index = indexes[end_date]
    if end_index <= start_index:
        return None

    price_end_index = end_index - 1 if exclude_first_climb_day else end_index
    interval_closes = closes[start_index : price_end_index + 1]
    minimum_close = min(interval_closes)
    tied_offsets = [index for index, close in enumerate(interval_closes) if close == minimum_close]
    first_offset = tied_offsets[0]
    last_offset = tied_offsets[-1]
    duration = price_end_index - start_index
    position_denominator = max(duration, 1)
    start_close = closes[start_index]
    climb_close = closes[end_index]
    event |= {
        "trading_day_count": duration + 1,
        "is_primary_duration": duration + 1 >= MIN_PRIMARY_TRADING_DAYS,
        "price_interval_end_date": dates[price_end_index],
        "excluded_first_climb_day": exclude_first_climb_day,
        "worsening_start_close": start_close,
        "first_climb_close": climb_close,
        "minimum_close": minimum_close,
        "minimum_first_date": dates[start_index + first_offset],
        "minimum_last_date": dates[start_index + last_offset],
        "minimum_tie_day_count": len(tied_offsets),
        "minimum_first_position": first_offset / position_denominator,
        "minimum_last_position": last_offset / position_denominator,
        "minimum_return_from_start_pct": (minimum_close / start_close - 1.0) * 100.0,
        "climb_return_from_start_pct": (climb_close / start_close - 1.0) * 100.0,
        "first_low_in_latter_half": first_offset / position_denominator >= 0.5,
        "first_low_in_last_quarter": first_offset / position_denominator >= 0.75,
        "last_low_in_latter_half": last_offset / position_denominator >= 0.5,
        "last_low_in_last_quarter": last_offset / position_denominator >= 0.75,
    }
    event.pop("previous_date", None)
    event.pop("previous_trend", None)
    return event


def wilson(successes: int, count: int) -> tuple[float | None, float | None]:
    if count == 0:
        return None, None
    z = 1.959963984540054
    proportion = successes / count
    denominator = 1 + z * z / count
    center = (proportion + z * z / (2 * count)) / denominator
    spread = z * math.sqrt(
        proportion * (1 - proportion) / count + z * z / (4 * count * count)
    ) / denominator
    return (center - spread) * 100.0, (center + spread) * 100.0


def aggregate_scope(scope: str, rows: list[dict]) -> dict:
    primary = [row for row in rows if row["is_primary_duration"]]
    first_half_count = sum(row["first_low_in_latter_half"] for row in primary)
    first_quarter_count = sum(row["first_low_in_last_quarter"] for row in primary)
    last_half_count = sum(row["last_low_in_latter_half"] for row in primary)
    last_quarter_count = sum(row["last_low_in_last_quarter"] for row in primary)
    first_half_ci = wilson(first_half_count, len(primary))
    first_quarter_ci = wilson(first_quarter_count, len(primary))
    return {
        "scope": scope,
        "event_count": len(rows),
        "short_event_count": len(rows) - len(primary),
        "primary_event_count": len(primary),
        "median_trading_day_count": statistics.median(row["trading_day_count"] for row in primary) if primary else None,
        "median_first_low_position": statistics.median(row["minimum_first_position"] for row in primary) if primary else None,
        "median_last_low_position": statistics.median(row["minimum_last_position"] for row in primary) if primary else None,
        "first_low_latter_half_count": first_half_count,
        "first_low_latter_half_rate_pct": first_half_count / len(primary) * 100.0 if primary else None,
        "first_low_latter_half_ci95_low_pct": first_half_ci[0],
        "first_low_latter_half_ci95_high_pct": first_half_ci[1],
        "first_low_last_quarter_count": first_quarter_count,
        "first_low_last_quarter_rate_pct": first_quarter_count / len(primary) * 100.0 if primary else None,
        "first_low_last_quarter_ci95_low_pct": first_quarter_ci[0],
        "first_low_last_quarter_ci95_high_pct": first_quarter_ci[1],
        "last_low_latter_half_rate_pct": last_half_count / len(primary) * 100.0 if primary else None,
        "last_low_last_quarter_rate_pct": last_quarter_count / len(primary) * 100.0 if primary else None,
        "mean_minimum_return_from_start_pct": statistics.fmean(row["minimum_return_from_start_pct"] for row in primary) if primary else None,
        "median_minimum_return_from_start_pct": statistics.median(row["minimum_return_from_start_pct"] for row in primary) if primary else None,
        "mean_climb_return_from_start_pct": statistics.fmean(row["climb_return_from_start_pct"] for row in primary) if primary else None,
        "median_climb_return_from_start_pct": statistics.median(row["climb_return_from_start_pct"] for row in primary) if primary else None,
    }


def aggregate(events: list[dict]) -> list[dict]:
    output = [aggregate_scope("ALL", events)]
    for sample in sorted({row["sample"] for row in events}):
        output.append(aggregate_scope(sample, [row for row in events if row["sample"] == sample]))
    return output


def bucket_distribution(events: list[dict]) -> list[dict]:
    buckets = (("Q1", 0.0, 0.25), ("Q2", 0.25, 0.5), ("Q3", 0.5, 0.75), ("Q4", 0.75, 1.0000001))
    output = []
    scopes = [("ALL", events)] + [
        (sample, [row for row in events if row["sample"] == sample])
        for sample in sorted({row["sample"] for row in events})
    ]
    for scope, scoped in scopes:
        primary = [row for row in scoped if row["is_primary_duration"]]
        for name, low, high in buckets:
            count = sum(low <= row["minimum_first_position"] < high for row in primary)
            output.append({
                "scope": scope,
                "bucket": name,
                "position_start_inclusive": low,
                "position_end_exclusive": high,
                "count": count,
                "rate_pct": count / len(primary) * 100.0 if primary else None,
            })
    return output


def csv_value(value):
    if isinstance(value, float):
        return f"{value:.6f}"
    if value is None:
        return ""
    return value


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    fields = list(rows[0])
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: csv_value(row.get(field)) for field in fields})


def render_report(summary: dict, aggregates: list[dict], buckets: list[dict]) -> str:
    def fmt(value):
        if value is None:
            return "-"
        if isinstance(value, float):
            return f"{value:.3f}"
        return str(value)

    aggregate_rows = "".join(
        "<tr>" + "".join(
            f"<td>{html.escape(fmt(row[key]))}</td>" for key in (
                "scope", "primary_event_count", "median_trading_day_count",
                "median_first_low_position", "first_low_latter_half_rate_pct",
                "first_low_latter_half_ci95_low_pct", "first_low_latter_half_ci95_high_pct",
                "first_low_last_quarter_rate_pct", "median_last_low_position",
                "last_low_latter_half_rate_pct", "mean_minimum_return_from_start_pct",
            )
        ) + "</tr>"
        for row in aggregates
    )
    bucket_rows = "".join(
        "<tr>" + "".join(
            f"<td>{html.escape(fmt(row[key]))}</td>" for key in ("scope", "bucket", "count", "rate_pct")
        ) + "</tr>"
        for row in buckets
    )
    position_end_label = "首次爬升前一日" if summary["excluded_first_climb_day"] else "首次爬升日"
    return f"""<!doctype html><html lang="zh-Hant"><meta charset="utf-8">
<title>GT-P02-D1 最低價時間位置研究</title>
<style>body{{font:15px/1.55 -apple-system,sans-serif;margin:32px;color:#222}}table{{border-collapse:collapse;width:100%;margin-bottom:28px}}th,td{{border:1px solid #ccc;padding:6px;text-align:right}}th:first-child,td:first-child{{text-align:left}}code{{background:#eee;padding:2px 4px}}</style>
<h1>GT-P02-D1 最低價時間位置研究</h1>
<p><code>0</code> 代表惡化確認起始日，<code>1</code> 代表{position_end_label}。{html.escape(summary['climb_definition'])}。主要結果只納入至少 {MIN_PRIMARY_TRADING_DAYS} 個交易日的區段；最低價平手時以首次位置為主、末次位置為敏感度分析。</p>
<ul><li>可計算事件：{summary['event_count']}</li><li>主要事件：{summary['primary_event_count']}</li><li>短區段：{summary['short_event_count']}</li><li>無首次爬升而截尾：{summary['censored_event_count']}</li></ul>
<h2>主要統計</h2><table><thead><tr><th>範圍</th><th>事件</th><th>日數中位</th><th>首次最低位置中位</th><th>後半比例%</th><th>後半CI低</th><th>後半CI高</th><th>末季比例%</th><th>末次最低位置中位</th><th>末次在後半%</th><th>最低價平均變化%</th></tr></thead><tbody>{aggregate_rows}</tbody></table>
<h2>首次最低價四分位分布</h2><table><thead><tr><th>範圍</th><th>區段</th><th>事件</th><th>比例%</th></tr></thead><tbody>{bucket_rows}</tbody></table>
</html>"""


def main() -> None:
    args = parse_args()
    specs = [parse_sample(value) for value in args.sample]
    args.output.mkdir(parents=True, exist_ok=True)
    events = []
    censored_total = 0
    sources = []
    for sample, database, store in specs:
        sample_events, censored = make_events(
            sample,
            load_observations(sample, database),
            load_prices(store),
            args.exclude_first_climb_day,
            args.min_climb_increase,
            args.min_climb_from_trough,
        )
        events.extend(sample_events)
        censored_total += censored
        sources.append({"sample": sample, "decision_base": str(database), "price_store": str(store)})
    aggregates = aggregate(events)
    buckets = bucket_distribution(events)
    overall = aggregates[0]
    climb_definition = (
        f"fitTrend must exceed the running trough since worsening start by > {args.min_climb_from_trough}"
        if args.min_climb_from_trough is not None
        else f"fitTrend must increase from its prior-day value by > {args.min_climb_increase}"
    )
    summary = {
        "study_id": "GT-P02-D1",
        "baseline": "Baseline v12 / T2/S30 / S26",
        "event_definition": f"first worseningConfirmed day through the first later day satisfying: {climb_definition}",
        "climb_definition": climb_definition,
        "lookahead_policy": "all interval prices and fitTrend values are already known on the first-climb day; no later data is used",
        "minimum_tie_primary": "first occurrence",
        "minimum_tie_sensitivity": "last occurrence",
        "minimum_primary_trading_days": MIN_PRIMARY_TRADING_DAYS,
        "excluded_first_climb_day": args.exclude_first_climb_day,
        "min_climb_increase": args.min_climb_increase,
        "min_climb_from_trough": args.min_climb_from_trough,
        "event_count": len(events),
        "primary_event_count": overall["primary_event_count"],
        "short_event_count": overall["short_event_count"],
        "censored_event_count": censored_total,
        "median_first_low_position": overall["median_first_low_position"],
        "first_low_latter_half_rate_pct": overall["first_low_latter_half_rate_pct"],
        "first_low_last_quarter_rate_pct": overall["first_low_last_quarter_rate_pct"],
    }
    manifest = {
        "study_id": "GT-P02-D1",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "sources": sources,
        "method": {
            "start": "first valid entry into fitTrend phase 5 with observation_count >= 125",
            "end": f"first later valid day satisfying: {climb_definition}",
            "price_interval": (
                "inclusive from worsening start through the day before first climb"
                if args.exclude_first_climb_day
                else "inclusive from worsening start through first climb"
            ),
            "position": "trading-day offset of interval minimum divided by interval duration",
            "primary_duration": f"at least {MIN_PRIMARY_TRADING_DAYS} trading days",
            "future_data": "none after the first-climb date",
        },
    }
    write_csv(args.output / "events.csv", events)
    write_csv(args.output / "aggregate.csv", aggregates)
    write_csv(args.output / "bucket-distribution.csv", buckets)
    (args.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (args.output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (args.output / "report.html").write_text(render_report(summary, aggregates, buckets), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(json.dumps(aggregates, ensure_ascii=False, indent=2))
    print(json.dumps([row for row in buckets if row["scope"] == "ALL"], ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
