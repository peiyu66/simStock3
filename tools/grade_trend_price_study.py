#!/usr/bin/env python3
"""Study whether visible Grade trend phases lead subsequent stock returns."""

from __future__ import annotations

import argparse
import csv
import html
import json
import math
import random
import sqlite3
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from statistics import mean, median
from typing import Any, Iterable
from zoneinfo import ZoneInfo


APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
TAIPEI = ZoneInfo("Asia/Taipei")
MINIMUM_OBSERVATIONS = 125
HORIZONS = (1, 3, 5, 10, 20)
PHASES = {
    2: ("改善預警", 1),
    3: ("惡化預警", -1),
    4: ("改善確認", 1),
    5: ("惡化確認", -1),
}
PHASE_COLORS = {
    2: "#f59e0b",
    3: "#a3a61b",
    4: "#e53935",
    5: "#16a34a",
}


@dataclass(frozen=True)
class PriceRow:
    trade_date: int
    close: float


@dataclass
class Observation:
    sample: str
    window_id: int
    window_start: int
    window_end: int
    stock_id: str
    stock_name: str
    group_name: str
    trade_date: int
    phase: int
    visible_phase: int
    fit_trend: float | None
    observation_count: int
    grade_name: str
    valid: bool


def yyyymmdd(value: date) -> int:
    return value.year * 10000 + value.month * 100 + value.day


def apple_date(value: float) -> int:
    instant = APPLE_EPOCH + timedelta(seconds=float(value))
    return yyyymmdd(instant.astimezone(TAIPEI).date())


def open_readonly(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def load_prices(path: Path) -> tuple[dict[str, list[PriceRow]], dict[str, str]]:
    connection = open_readonly(path)
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"price store integrity failed: {path}: {integrity}")
        query = """
            SELECT s.ZSID stock_id, s.ZSNAME stock_name,
                   t.ZDATETIME trade_time, t.ZPRICECLOSE close_price
            FROM ZTRADE t
            JOIN ZSTOCK s ON s.Z_PK = t.ZSTOCK
            WHERE t.ZPRICECLOSE > 0
            ORDER BY s.ZSID, t.ZDATETIME
        """
        prices: dict[str, list[PriceRow]] = defaultdict(list)
        names: dict[str, str] = {}
        seen: set[tuple[str, int]] = set()
        for raw in connection.execute(query):
            stock_id = str(raw["stock_id"])
            trade_date = apple_date(raw["trade_time"])
            key = (stock_id, trade_date)
            if key in seen:
                continue
            seen.add(key)
            names[stock_id] = str(raw["stock_name"])
            prices[stock_id].append(PriceRow(trade_date, float(raw["close_price"])))
        return dict(prices), names
    finally:
        connection.close()


def load_observations(path: Path, sample: str) -> tuple[list[Observation], dict[str, Any]]:
    connection = open_readonly(path)
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"DecisionBase integrity failed: {path}: {integrity}")
        metadata = {
            row["key"]: row["value"]
            for row in connection.execute("SELECT key, value FROM metadata")
        }
        query = """
            SELECT o.window_id, w.start_date, w.end_date,
                   s.stock_id, s.name, s.group_name,
                   o.trade_date, o.fit_trend_phase, o.fit_trend,
                   o.fit_observation_count, o.grade_name,
                   o.is_valid, o.is_finite
            FROM strategy_fit_observations o
            JOIN windows w USING(window_id)
            JOIN stocks s USING(stock_key)
            ORDER BY o.window_id, s.stock_id, o.trade_date
        """
        rows: list[Observation] = []
        for raw in connection.execute(query):
            phase = int(raw["fit_trend_phase"])
            count = int(raw["fit_observation_count"])
            valid = bool(raw["is_valid"] and raw["is_finite"])
            visible = phase if valid and count >= MINIMUM_OBSERVATIONS and phase in PHASES else 0
            rows.append(
                Observation(
                    sample=sample,
                    window_id=int(raw["window_id"]),
                    window_start=int(raw["start_date"]),
                    window_end=int(raw["end_date"]),
                    stock_id=str(raw["stock_id"]),
                    stock_name=str(raw["name"]),
                    group_name=str(raw["group_name"]),
                    trade_date=int(raw["trade_date"]),
                    phase=phase,
                    visible_phase=visible,
                    fit_trend=float(raw["fit_trend"]) if raw["fit_trend"] is not None else None,
                    observation_count=count,
                    grade_name=str(raw["grade_name"]),
                    valid=valid,
                )
            )
        return rows, metadata
    finally:
        connection.close()


def grouped_observations(rows: Iterable[Observation]) -> dict[tuple[str, int, str], list[Observation]]:
    grouped: dict[tuple[str, int, str], list[Observation]] = defaultdict(list)
    for row in rows:
        grouped[(row.sample, row.window_id, row.stock_id)].append(row)
    return grouped


def build_events(rows: list[Observation]) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for key, series in grouped_observations(rows).items():
        previous_visible = 0
        for index, row in enumerate(series):
            if row.visible_phase and row.visible_phase != previous_visible:
                label, direction = PHASES[row.visible_phase]
                warning_outcome = ""
                confirmation_days: int | None = None
                if row.visible_phase in (2, 3):
                    confirm_phase = 4 if row.visible_phase == 2 else 5
                    opposite = {2, 4} if row.visible_phase == 3 else {3, 5}
                    warning_outcome = "未完成"
                    for offset, following in enumerate(series[index + 1 :], start=1):
                        if following.phase == confirm_phase and following.observation_count >= MINIMUM_OBSERVATIONS:
                            warning_outcome = "同向確認"
                            confirmation_days = offset
                            break
                        if following.visible_phase in opposite:
                            warning_outcome = "反向"
                            break
                        if following.phase in (0, 1, 6, 7):
                            warning_outcome = "解除未確認"
                            break
                events.append(
                    {
                        "sample": row.sample,
                        "window_id": row.window_id,
                        "window_start": row.window_start,
                        "window_end": row.window_end,
                        "stock_id": row.stock_id,
                        "stock_name": row.stock_name,
                        "group_name": row.group_name,
                        "trade_date": row.trade_date,
                        "phase": row.visible_phase,
                        "phase_name": label,
                        "direction": direction,
                        "fit_trend": row.fit_trend,
                        "observation_count": row.observation_count,
                        "grade_name": row.grade_name,
                        "warning_outcome": warning_outcome,
                        "confirmation_days": confirmation_days,
                    }
                )
            previous_visible = row.visible_phase
    return events


def attach_returns(
    events: list[dict[str, Any]],
    prices: dict[str, dict[str, list[PriceRow]]],
) -> None:
    indexes: dict[tuple[str, str], dict[int, int]] = {}
    for sample, stocks in prices.items():
        for stock_id, series in stocks.items():
            indexes[(sample, stock_id)] = {item.trade_date: i for i, item in enumerate(series)}
    for event in events:
        sample = event["sample"]
        stock_id = event["stock_id"]
        series = prices[sample][stock_id]
        index = indexes[(sample, stock_id)].get(event["trade_date"])
        if index is None:
            raise RuntimeError(f"missing price: {sample} {stock_id} {event['trade_date']}")
        start = series[index].close
        event["close"] = start
        for horizon in HORIZONS:
            target_index = index + horizon
            raw_return: float | None = None
            if target_index < len(series) and series[target_index].trade_date <= event["window_end"]:
                raw_return = 100 * (series[target_index].close / start - 1)
            event[f"return_{horizon}"] = raw_return
            event[f"aligned_{horizon}"] = (
                raw_return * event["direction"] if raw_return is not None else None
            )
        path_end = min(index + 20, len(series) - 1)
        path = [100 * (series[i].close / start - 1) for i in range(index + 1, path_end + 1)]
        event["favorable_20"] = max((value * event["direction"] for value in path), default=None)
        event["adverse_20"] = min((value * event["direction"] for value in path), default=None)


def match_controls(
    events: list[dict[str, Any]],
    rows: list[Observation],
    prices: dict[str, dict[str, list[PriceRow]]],
) -> None:
    price_indexes = {
        (sample, stock_id): {item.trade_date: i for i, item in enumerate(series)}
        for sample, stocks in prices.items()
        for stock_id, series in stocks.items()
    }
    candidates: dict[tuple[str, int, str, str], list[Observation]] = defaultdict(list)
    for row in rows:
        if row.valid and row.observation_count >= MINIMUM_OBSERVATIONS and row.visible_phase == 0:
            candidates[(row.sample, row.window_id, row.stock_id, row.grade_name)].append(row)
    used: dict[int, set[tuple[str, int, str, int]]] = defaultdict(set)
    for event in sorted(events, key=lambda item: (item["phase"], item["sample"], item["trade_date"])):
        key = (event["sample"], event["window_id"], event["stock_id"], event["grade_name"])
        event_index = price_indexes[(event["sample"], event["stock_id"])][event["trade_date"]]
        ranked = sorted(
            candidates.get(key, []),
            key=lambda row: abs(price_indexes[(row.sample, row.stock_id)].get(row.trade_date, -100000) - event_index),
        )
        selected: Observation | None = None
        for row in ranked:
            control_key = (row.sample, row.window_id, row.stock_id, row.trade_date)
            if control_key in used[event["phase"]] or row.trade_date == event["trade_date"]:
                continue
            selected = row
            used[event["phase"]].add(control_key)
            break
        event["control_date"] = selected.trade_date if selected else None
        for horizon in HORIZONS:
            event[f"control_return_{horizon}"] = None
            event[f"control_aligned_{horizon}"] = None
        if selected is None:
            continue
        sample = selected.sample
        stock_id = selected.stock_id
        series = prices[sample][stock_id]
        index = price_indexes[(sample, stock_id)].get(selected.trade_date)
        if index is None:
            continue
        start = series[index].close
        for horizon in HORIZONS:
            target = index + horizon
            if target >= len(series) or series[target].trade_date > selected.window_end:
                continue
            value = 100 * (series[target].close / start - 1)
            event[f"control_return_{horizon}"] = value
            event[f"control_aligned_{horizon}"] = value * event["direction"]


def percentile(values: list[float], proportion: float) -> float:
    if not values:
        return math.nan
    ordered = sorted(values)
    position = (len(ordered) - 1) * proportion
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def cluster_bootstrap_ci(items: list[tuple[str, float]], seed: int) -> tuple[float, float]:
    clusters: dict[str, list[float]] = defaultdict(list)
    for key, value in items:
        clusters[key].append(value)
    keys = sorted(clusters)
    if len(keys) < 2:
        value = mean(value for _, value in items) if items else math.nan
        return value, value
    rng = random.Random(seed)
    estimates: list[float] = []
    for _ in range(1000):
        selected = [rng.choice(keys) for _ in keys]
        values = [value for key in selected for value in clusters[key]]
        estimates.append(mean(values))
    return percentile(estimates, 0.025), percentile(estimates, 0.975)


def wilson(successes: int, total: int) -> tuple[float, float]:
    if total == 0:
        return math.nan, math.nan
    z = 1.959963984540054
    p = successes / total
    denominator = 1 + z * z / total
    center = (p + z * z / (2 * total)) / denominator
    radius = z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total)) / denominator
    return 100 * (center - radius), 100 * (center + radius)


def aggregate(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    scopes: list[tuple[str, list[dict[str, Any]]]] = [("全部", events)]
    scopes += [(sample, [item for item in events if item["sample"] == sample]) for sample in "ABCD"]
    for scope, scoped in scopes:
        for phase in PHASES:
            phase_rows = [item for item in scoped if item["phase"] == phase]
            for horizon in HORIZONS:
                rows = [item for item in phase_rows if item[f"aligned_{horizon}"] is not None]
                values = [float(item[f"aligned_{horizon}"]) for item in rows]
                paired = [
                    item for item in rows if item[f"control_aligned_{horizon}"] is not None
                ]
                controls = [float(item[f"control_aligned_{horizon}"]) for item in paired]
                differences = [
                    float(item[f"aligned_{horizon}"]) - float(item[f"control_aligned_{horizon}"])
                    for item in paired
                ]
                clusters = [
                    (f"{item['sample']}-{item['window_id']}-{item['stock_id']}", float(item[f"aligned_{horizon}"]))
                    for item in rows
                ]
                difference_clusters = [
                    (
                        f"{item['sample']}-{item['window_id']}-{item['stock_id']}",
                        float(item[f"aligned_{horizon}"]) - float(item[f"control_aligned_{horizon}"]),
                    )
                    for item in paired
                ]
                ci_low, ci_high = cluster_bootstrap_ci(clusters, phase * 100 + horizon)
                edge_low, edge_high = cluster_bootstrap_ci(
                    difference_clusters, phase * 1000 + horizon
                )
                hits = sum(value > 0 for value in values)
                hit_low, hit_high = wilson(hits, len(values))
                output.append(
                    {
                        "scope": scope,
                        "phase": PHASES[phase][0],
                        "horizon": horizon,
                        "events": len(values),
                        "matched_controls": len(paired),
                        "mean_aligned_return": mean(values) if values else None,
                        "median_aligned_return": median(values) if values else None,
                        "mean_ci_low": ci_low if values else None,
                        "mean_ci_high": ci_high if values else None,
                        "hit_rate": 100 * hits / len(values) if values else None,
                        "hit_ci_low": hit_low if values else None,
                        "hit_ci_high": hit_high if values else None,
                        "control_mean_aligned_return": mean(controls) if controls else None,
                        "paired_mean_edge": mean(differences) if differences else None,
                        "edge_ci_low": edge_low if differences else None,
                        "edge_ci_high": edge_high if differences else None,
                    }
                )
    return output


def select_stocks(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    counts: Counter[tuple[str, str, str, str]] = Counter()
    for item in events:
        counts[(item["sample"], item["group_name"], item["stock_id"], item["stock_name"])] += 1
    selected: list[dict[str, Any]] = []
    for sample in "ABCD":
        for group in ("較強股群", "較弱股群"):
            choices = [
                (count, stock_id, stock_name)
                for (item_sample, item_group, stock_id, stock_name), count in counts.items()
                if item_sample == sample and item_group == group
            ]
            count, stock_id, stock_name = sorted(choices, key=lambda item: (-item[0], item[1]))[0]
            selected.append(
                {
                    "sample": sample,
                    "group_name": group,
                    "stock_id": stock_id,
                    "stock_name": stock_name,
                    "event_count": count,
                }
            )
    return selected


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def svg_chart(
    output: Path,
    stock: dict[str, Any],
    prices: dict[str, dict[str, list[PriceRow]]],
    events: list[dict[str, Any]],
) -> str:
    sample = stock["sample"]
    stock_id = stock["stock_id"]
    series = [item for item in prices[sample][stock_id] if 20170722 <= item.trade_date <= 20260722]
    event_rows = [
        item for item in events if item["sample"] == sample and item["stock_id"] == stock_id
    ]
    width, height = 960, 320
    left, right, top, bottom = 58, 18, 28, 38
    x_values = [item.trade_date for item in series]
    y_values = [math.log(item.close) for item in series]
    x_min, x_max = min(x_values), max(x_values)
    y_min, y_max = min(y_values), max(y_values)
    def x(value: int) -> float:
        raw = datetime.strptime(str(value), "%Y%m%d").date().toordinal()
        minimum = datetime.strptime(str(x_min), "%Y%m%d").date().toordinal()
        maximum = datetime.strptime(str(x_max), "%Y%m%d").date().toordinal()
        return left + (raw - minimum) / max(maximum - minimum, 1) * (width - left - right)
    def y(value: float) -> float:
        return top + (y_max - value) / max(y_max - y_min, 1e-9) * (height - top - bottom)
    points = " ".join(f"{x(item.trade_date):.2f},{y(math.log(item.close)):.2f}" for item in series)
    price_by_date = {item.trade_date: item.close for item in series}
    markers: list[str] = []
    for item in event_rows:
        price = price_by_date.get(item["trade_date"])
        if price is None:
            continue
        markers.append(
            f'<circle cx="{x(item["trade_date"]):.2f}" cy="{y(math.log(price)):.2f}" '
            f'r="3.2" fill="{PHASE_COLORS[item["phase"]]}" opacity="0.82" />'
        )
    ticks = []
    for year in range(2018, 2027, 2):
        value = year * 10000 + 101
        ticks.append(
            f'<line x1="{x(value):.2f}" x2="{x(value):.2f}" y1="{top}" y2="{height-bottom}" stroke="#e5e7eb" />'
            f'<text x="{x(value):.2f}" y="{height-14}" text-anchor="middle" font-size="12" fill="#64748b">{year}</text>'
        )
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" role="img">
<rect width="100%" height="100%" fill="#fffdf7" rx="12"/>
<text x="{left}" y="19" font-size="15" font-weight="700" fill="#1f2937">Sample {sample} · {stock_id} {html.escape(stock['stock_name'])} · {html.escape(stock['group_name'])}</text>
{''.join(ticks)}
<polyline points="{points}" fill="none" stroke="#334155" stroke-width="1.8"/>
{''.join(markers)}
</svg>'''
    filename = f"{sample.lower()}-{stock_id}.svg"
    (output / filename).write_text(svg, encoding="utf-8")
    return filename


def format_number(value: Any, digits: int = 3) -> str:
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return "-"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def table(rows: list[dict[str, Any]], columns: list[tuple[str, str]]) -> str:
    head = "".join(f"<th>{html.escape(label)}</th>" for _, label in columns)
    body = []
    for row in rows:
        body.append(
            "<tr>" + "".join(f"<td>{html.escape(format_number(row.get(key)))}</td>" for key, _ in columns) + "</tr>"
        )
    return f"<table><thead><tr>{head}</tr></thead><tbody>{''.join(body)}</tbody></table>"


def build_report(
    output: Path,
    aggregate_rows: list[dict[str, Any]],
    events: list[dict[str, Any]],
    selected: list[dict[str, Any]],
    chart_files: dict[tuple[str, str], str],
    metadata: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    overall = [row for row in aggregate_rows if row["scope"] == "全部"]
    headline_rows = [row for row in overall if row["horizon"] in (1, 5, 20)]
    warning_counts = Counter(
        (item["phase_name"], item["warning_outcome"])
        for item in events
        if item["phase"] in (2, 3)
    )
    warning_rows = [
        {"phase": phase, "outcome": outcome, "events": count}
        for (phase, outcome), count in sorted(warning_counts.items())
    ]
    sample_consistency: list[dict[str, Any]] = []
    for phase in PHASES:
        for horizon in HORIZONS:
            rows = [
                row for row in aggregate_rows
                if row["scope"] in "ABCD" and row["phase"] == PHASES[phase][0] and row["horizon"] == horizon
            ]
            positive_samples = sum(
                row["paired_mean_edge"] is not None and row["paired_mean_edge"] > 0 for row in rows
            )
            sample_consistency.append(
                {
                    "phase": PHASES[phase][0],
                    "horizon": horizon,
                    "positive_samples": positive_samples,
                    "available_samples": sum(row["paired_mean_edge"] is not None for row in rows),
                }
            )
    selected_html = table(
        selected,
        [("sample", "Sample"), ("group_name", "股群"), ("stock_id", "代號"), ("stock_name", "股票"), ("event_count", "事件數")],
    )
    charts = "".join(
        f'<section class="chart"><img src="{chart_files[(row["sample"], row["stock_id"])]}" alt="{html.escape(row["stock_name"])}趨勢事件圖"></section>'
        for row in selected
    )
    css = """
    :root { --ink:#24303a; --paper:#fffdf7; --line:#d9d6ca; --accent:#c65d35; }
    body { margin:0; background:#ece8dd; color:var(--ink); font-family:-apple-system,BlinkMacSystemFont,"PingFang TC",sans-serif; }
    main { max-width:1180px; margin:24px auto; background:var(--paper); padding:30px 36px 50px; box-shadow:0 8px 30px #7773; }
    h1 { font-family:"Iowan Old Style","Noto Serif TC",serif; font-size:34px; margin-bottom:8px; }
    h2 { margin-top:34px; border-bottom:2px solid var(--accent); padding-bottom:6px; }
    .lead { font-size:18px; line-height:1.65; }
    .note { background:#f4ecda; border-left:5px solid #d29032; padding:12px 16px; line-height:1.6; }
    table { border-collapse:collapse; width:100%; margin:14px 0 24px; font-size:13px; }
    th,td { border:1px solid var(--line); padding:7px 8px; text-align:right; }
    th { background:#eee8d9; }
    th:first-child,td:first-child,th:nth-child(2),td:nth-child(2) { text-align:left; }
    .legend span { margin-right:15px; white-space:nowrap; }
    .dot { display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:4px; }
    .chart { margin:16px 0; border:1px solid var(--line); border-radius:12px; overflow:hidden; }
    .chart img { width:100%; display:block; }
    code { background:#eee9de; padding:2px 5px; }
    """
    document = f'''<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>GT-P01 Grade 趨勢與後續股價</title><style>{css}</style></head><body><main>
<h1>GT-P01 Grade 趨勢與後續股價</h1>
<p class="lead">使用 Baseline v10 A／B／C／D、正式 <code>T2/S28</code> 趨勢階段，檢查可顯示的預警與確認訊號之後，股價是否沿同方向移動。</p>
<div class="note"><strong>重要限制：</strong>訊號當日股價參與 Grade 趨勢計算，因此本研究完全排除訊號形成前與當日漲跌，只計算訊號收盤至未來第 1／3／5／10／20 個交易日。這是歷史關聯研究，不是交易規則回測。</div>
<h2>全樣本主要結果</h2>
{table(headline_rows, [("phase","訊號"),("horizon","未來交易日"),("events","事件數"),("matched_controls","配對數"),("mean_aligned_return","同向平均報酬%"),("median_aligned_return","同向中位數%"),("hit_rate","方向命中率%"),("paired_mean_edge","相對無訊號日差%"),("edge_ci_low","差異95%下界"),("edge_ci_high","差異95%上界")])}
<h2>A／B／C／D 方向一致性</h2>
{table(sample_consistency, [("phase","訊號"),("horizon","未來交易日"),("positive_samples","優於配對日的Sample數"),("available_samples","可比較Sample數")])}
<h2>預警後的狀態去向</h2>
{table(warning_rows, [("phase","預警"),("outcome","後續狀態"),("events","事件數")])}
<h2>圖表個股</h2>
<p>每個 Sample 固定選擇事件數最多的較強股與較弱股各一檔；名稱不是依漲跌結果挑選。價格線採對數尺度。</p>
{selected_html}
<p class="legend"><span><i class="dot" style="background:#f59e0b"></i>改善預警</span><span><i class="dot" style="background:#a3a61b"></i>惡化預警</span><span><i class="dot" style="background:#e53935"></i>改善確認</span><span><i class="dot" style="background:#16a34a"></i>惡化確認</span></p>
{charts}
<h2>方法</h2>
<p>每段可見狀態只取進入該狀態的第一天，觀察數須至少 {MINIMUM_OBSERVATIONS}。無訊號比較日限定相同 Sample、股票、三年窗口與交易當時 Grade，取時間最近且未顯示圖示的一天；同一訊號類型不重複使用控制日。信賴區間以股票×窗口為群集進行 1,000 次 bootstrap。</p>
<p>DecisionBase：{html.escape(', '.join(metadata[s]['decisionBaseID'] for s in 'ABCD'))}</p>
</main></body></html>'''
    (output / "report.html").write_text(document, encoding="utf-8")
    return {
        "warningOutcomeCounts": warning_rows,
        "sampleConsistency": sample_consistency,
        "headline": headline_rows,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--price-root", type=Path, required=True)
    parser.add_argument("--decision-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    prices: dict[str, dict[str, list[PriceRow]]] = {}
    observations: list[Observation] = []
    metadata: dict[str, dict[str, Any]] = {}
    sources: dict[str, dict[str, str]] = {}
    for sample in "ABCD":
        price_path = args.price_root / f"{sample.lower()}.store"
        matches = sorted(
            args.decision_root.glob(
                f"{sample.lower()}-abcd9-v2-s24-sn05-wow-worsening-20260824-t2-s28-73003cf8f39c-fixed3y-20260722-v5/decisions.sqlite"
            )
        )
        if len(matches) != 1:
            raise RuntimeError(f"expected one DecisionBase for Sample {sample}, found {len(matches)}")
        prices[sample], _ = load_prices(price_path)
        rows, sample_metadata = load_observations(matches[0], sample)
        observations.extend(rows)
        metadata[sample] = sample_metadata
        sources[sample] = {"priceStore": str(price_path), "decisionBase": str(matches[0])}

    events = build_events(observations)
    attach_returns(events, prices)
    match_controls(events, observations, prices)
    aggregate_rows = aggregate(events)
    selected = select_stocks(events)
    chart_files = {
        (stock["sample"], stock["stock_id"]): svg_chart(args.output, stock, prices, events)
        for stock in selected
    }

    event_columns = [
        "sample", "window_id", "window_start", "window_end", "stock_id", "stock_name",
        "group_name", "trade_date", "phase", "phase_name", "direction", "fit_trend",
        "observation_count", "grade_name", "warning_outcome", "confirmation_days", "close",
    ]
    for horizon in HORIZONS:
        event_columns += [
            f"return_{horizon}", f"aligned_{horizon}", f"control_return_{horizon}",
            f"control_aligned_{horizon}",
        ]
    event_columns += ["control_date", "favorable_20", "adverse_20"]
    write_csv(args.output / "events.csv", [{key: item.get(key) for key in event_columns} for item in events])
    write_csv(args.output / "aggregate.csv", aggregate_rows)
    write_csv(args.output / "selected-stocks.csv", selected)
    summary = build_report(args.output, aggregate_rows, events, selected, chart_files, metadata)
    manifest = {
        "runID": "gt-p01-baseline-v10-t2s28-20260825",
        "createdAt": datetime.now().astimezone().isoformat(),
        "dataRuleVersion": "T2/S28",
        "strategyRuleVersion": "S24",
        "ruleCommit": "73003cf8f39cbf3a673792957324f508261bd731",
        "minimumObservationCount": MINIMUM_OBSERVATIONS,
        "horizons": HORIZONS,
        "eventCount": len(events),
        "selectedStocks": selected,
        "sources": sources,
        "limitations": [
            "Signal-day price movement is excluded; returns begin after the signal close.",
            "This is an observational event study, not a counterfactual strategy replay.",
            "Matched controls use the same stock, window, and exact transaction-time Grade.",
        ],
    }
    (args.output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps({"manifest": manifest, "summary": summary}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
