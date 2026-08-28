#!/usr/bin/env python3
"""GT-P02: worsening-confirmed-to-trough study without signal look-ahead."""

from __future__ import annotations

import argparse
import csv
import html
import json
import math
import random
import sqlite3
import statistics
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path


HORIZONS = (1, 3, 5, 10, 20)
RECOVERY_THRESHOLD = 0.611888
# One episode is one uninterrupted run of worseningConfirmed. A later return to
# phase 5 is a new episode, even if no neutral phase occurred between them.
WORSENING_PHASES = {5}
CORE_DATA_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--sample",
        action="append",
        required=True,
        metavar="ID:DECISIONS_SQLITE:PRICE_STORE",
    )
    parser.add_argument("--output", type=Path, required=True)
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
               o.fit_observation_count, o.grade_name, o.is_valid, o.is_finite
        FROM strategy_fit_observations o
        JOIN windows w USING(window_id)
        JOIN stocks s USING(stock_key)
        ORDER BY o.window_id, s.stock_id, o.trade_date
        """
    ).fetchall()
    connection.close()
    return [dict(row) | {"sample": sample} for row in rows]


def load_prices(store: Path) -> dict[str, list[tuple[int, float]]]:
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
    result: dict[str, list[tuple[int, float]]] = defaultdict(list)
    for stock_id, timestamp, close in rows:
        result[str(stock_id)].append((ymd_from_core_data(timestamp), float(close)))
    return result


def price_context(prices: dict[str, list[tuple[int, float]]]) -> dict[str, tuple[list[int], list[float], dict[int, int]]]:
    result = {}
    for stock_id, rows in prices.items():
        dates = [row[0] for row in rows]
        closes = [row[1] for row in rows]
        result[stock_id] = (dates, closes, {date: index for index, date in enumerate(dates)})
    return result


def attach_price_outcomes(row: dict, contexts: dict, date_field: str) -> None:
    stock_id = row["stock_id"]
    date = row.get(date_field)
    context = contexts.get(stock_id)
    if context is None or date not in context[2]:
        row["close"] = None
        for horizon in HORIZONS:
            row[f"return_{horizon}d"] = None
        return
    dates, closes, indexes = context
    index = indexes[date]
    base = closes[index]
    row["close"] = base
    for horizon in HORIZONS:
        future_index = index + horizon
        if future_index >= len(dates) or dates[future_index] > row["end_date"]:
            row[f"return_{horizon}d"] = None
        else:
            row[f"return_{horizon}d"] = (closes[future_index] / base - 1.0) * 100.0


def exact_close(contexts: dict, stock_id: str, date: int) -> float | None:
    context = contexts.get(stock_id)
    if context is None or date not in context[2]:
        return None
    return context[1][context[2][date]]


def study_sample(sample: str, observations: list[dict], contexts: dict) -> tuple[list[dict], list[dict], list[dict]]:
    groups: dict[tuple, list[dict]] = defaultdict(list)
    for row in observations:
        groups[(row["window_id"], row["stock_id"])].append(row)

    episodes: list[dict] = []
    events: list[dict] = []
    controls: list[dict] = []
    episode_number = 0

    for (window_id, stock_id), rows in groups.items():
        active = None
        for row in rows:
            valid = (
                row["is_valid"] == 1
                and row["is_finite"] == 1
                and row["fit_trend"] is not None
                and row["fit_observation_count"] >= 125
            )
            phase = row["fit_trend_phase"]

            if active is not None and (not valid or phase not in WORSENING_PHASES):
                active["end_date"] = active["last_date"]
                active["end_trend"] = active["last_trend"]
                active["is_censored"] = not valid
                episodes.append(active)
                active = None

            if not valid:
                continue

            if active is None and phase == 5:
                episode_number += 1
                active = {
                    "sample": sample,
                    "episode_id": f"{sample}-{window_id}-{stock_id}-{episode_number}",
                    "window_id": window_id,
                    "start_date": row["start_date"],
                    "end_date_limit": row["end_date"],
                    "stock_id": stock_id,
                    "stock_name": row["name"],
                    "group_name": row["group_name"],
                    "confirmation_date": row["trade_date"],
                    "confirmation_trend": row["fit_trend"],
                    "minimum_date": row["trade_date"],
                    "minimum_trend": row["fit_trend"],
                    "minimum_observation_index": 0,
                    "recovery_date": None,
                    "recovery_trend": None,
                    "recovery_rebound": None,
                    "recovery_grade": None,
                    "recovery_phase": None,
                    "observations_to_recovery": None,
                    "observation_count": 0,
                    "recovery_failed_new_low": False,
                    "failure_date": None,
                    "failure_trend": None,
                    "last_date": row["trade_date"],
                    "last_trend": row["fit_trend"],
                }

            if active is None:
                continue

            active["observation_count"] += 1
            active["last_date"] = row["trade_date"]
            active["last_trend"] = row["fit_trend"]

            if active["recovery_date"] is None:
                if row["fit_trend"] < active["minimum_trend"]:
                    active["minimum_trend"] = row["fit_trend"]
                    active["minimum_date"] = row["trade_date"]
                    active["minimum_observation_index"] = active["observation_count"] - 1
                rebound = row["fit_trend"] - active["minimum_trend"]
                if rebound >= RECOVERY_THRESHOLD and row["trade_date"] > active["minimum_date"]:
                    active["recovery_date"] = row["trade_date"]
                    active["recovery_trend"] = row["fit_trend"]
                    active["recovery_rebound"] = rebound
                    active["recovery_grade"] = row["grade_name"]
                    active["recovery_phase"] = phase
                    active["observations_to_recovery"] = active["observation_count"] - 1
                    event = {
                        key: active[key]
                        for key in (
                            "sample", "episode_id", "window_id", "start_date", "end_date_limit",
                            "stock_id", "stock_name", "group_name", "confirmation_date",
                            "confirmation_trend", "minimum_date", "minimum_trend", "recovery_date",
                            "recovery_trend", "recovery_rebound", "recovery_grade", "recovery_phase",
                            "observations_to_recovery",
                        )
                    }
                    event["end_date"] = row["end_date"]
                    events.append(event)
                else:
                    controls.append({
                        "sample": sample,
                        "episode_id": active["episode_id"],
                        "window_id": window_id,
                        "stock_id": stock_id,
                        "stock_name": row["name"],
                        "group_name": row["group_name"],
                        "control_date": row["trade_date"],
                        "control_trend": row["fit_trend"],
                        "control_grade": row["grade_name"],
                        "control_phase": phase,
                        "end_date": row["end_date"],
                    })
            elif row["fit_trend"] < active["minimum_trend"]:
                if not active["recovery_failed_new_low"]:
                    active["recovery_failed_new_low"] = True
                    active["failure_date"] = row["trade_date"]
                    active["failure_trend"] = row["fit_trend"]
                active["minimum_trend"] = row["fit_trend"]
                active["minimum_date"] = row["trade_date"]
                active["minimum_observation_index"] = active["observation_count"] - 1

        if active is not None:
            active["end_date"] = active["last_date"]
            active["end_trend"] = active["last_trend"]
            active["is_censored"] = True
            episodes.append(active)

    episode_by_id = {row["episode_id"]: row for row in episodes}
    for episode in episodes:
        episode["observations_to_trough"] = episode["minimum_observation_index"]
        episode["confirmation_close"] = exact_close(contexts, episode["stock_id"], episode["confirmation_date"])
        episode["trough_close"] = exact_close(contexts, episode["stock_id"], episode["minimum_date"])
        episode["confirmation_to_trough_return"] = (
            None if episode["confirmation_close"] is None or episode["trough_close"] is None
            else (episode["trough_close"] / episode["confirmation_close"] - 1.0) * 100.0
        )
        episode["trough_price_is_lower"] = (
            None if episode["confirmation_close"] is None or episode["trough_close"] is None
            else episode["trough_close"] < episode["confirmation_close"]
        )
    for event in events:
        episode = episode_by_id[event["episode_id"]]
        event["recovery_failed_new_low"] = episode["recovery_failed_new_low"]
        event["failure_date"] = episode["failure_date"]
        event["failure_trend"] = episode["failure_trend"]
        attach_price_outcomes(event, contexts, "recovery_date")
        confirmation = {**event, "end_date": event["end_date"]}
        attach_price_outcomes(confirmation, contexts, "confirmation_date")
        event["confirmation_close"] = confirmation["close"]
        event["confirmation_to_recovery_return"] = (
            None if event["close"] is None or confirmation["close"] is None
            else (event["close"] / confirmation["close"] - 1.0) * 100.0
        )
    for control in controls:
        attach_price_outcomes(control, contexts, "control_date")
    return episodes, events, controls


def match_controls(events: list[dict], controls: list[dict]) -> None:
    candidates: dict[tuple, list[dict]] = defaultdict(list)
    for control in controls:
        key = (control["sample"], control["window_id"], control["stock_id"], control["control_grade"])
        candidates[key].append(control)
    used: set[tuple] = set()
    for event in events:
        key = (event["sample"], event["window_id"], event["stock_id"], event["recovery_grade"])
        pool = [
            row for row in candidates.get(key, [])
            if (row["sample"], row["window_id"], row["stock_id"], row["control_date"]) not in used
        ]
        different_episode = [row for row in pool if row["episode_id"] != event["episode_id"]]
        if different_episode:
            pool = different_episode
        if not pool:
            event["control_date"] = None
            event["control_same_episode"] = None
            for horizon in HORIZONS:
                event[f"control_return_{horizon}d"] = None
            continue
        chosen = min(pool, key=lambda row: abs(row["control_date"] - event["recovery_date"]))
        used.add((chosen["sample"], chosen["window_id"], chosen["stock_id"], chosen["control_date"]))
        event["control_date"] = chosen["control_date"]
        event["control_same_episode"] = chosen["episode_id"] == event["episode_id"]
        for horizon in HORIZONS:
            event[f"control_return_{horizon}d"] = chosen[f"return_{horizon}d"]


def wilson(successes: int, count: int) -> tuple[float | None, float | None]:
    if count == 0:
        return None, None
    z = 1.959963984540054
    p = successes / count
    denominator = 1 + z * z / count
    center = (p + z * z / (2 * count)) / denominator
    spread = z * math.sqrt(p * (1 - p) / count + z * z / (4 * count * count)) / denominator
    return (center - spread) * 100, (center + spread) * 100


def bootstrap_paired_ci(rows: list[dict], horizon: int) -> tuple[float | None, float | None]:
    paired = [
        row for row in rows
        if row.get(f"return_{horizon}d") is not None and row.get(f"control_return_{horizon}d") is not None
    ]
    clusters: dict[tuple, list[float]] = defaultdict(list)
    for row in paired:
        clusters[(row["sample"], row["window_id"], row["stock_id"])].append(
            row[f"return_{horizon}d"] - row[f"control_return_{horizon}d"]
        )
    keys = list(clusters)
    if not keys:
        return None, None
    rng = random.Random(20260827 + horizon)
    estimates = []
    for _ in range(5000):
        values = []
        for _ in keys:
            values.extend(clusters[rng.choice(keys)])
        estimates.append(statistics.fmean(values))
    estimates.sort()
    return estimates[int(len(estimates) * 0.025)], estimates[int(len(estimates) * 0.975)]


def aggregate_rows(events: list[dict]) -> list[dict]:
    output = []
    scopes = [("ALL", events)] + [
        (sample, [row for row in events if row["sample"] == sample])
        for sample in sorted({row["sample"] for row in events})
    ]
    for scope, rows in scopes:
        for horizon in HORIZONS:
            values = [row[f"return_{horizon}d"] for row in rows if row.get(f"return_{horizon}d") is not None]
            controls = [row[f"control_return_{horizon}d"] for row in rows if row.get(f"control_return_{horizon}d") is not None]
            paired = [
                row[f"return_{horizon}d"] - row[f"control_return_{horizon}d"]
                for row in rows
                if row.get(f"return_{horizon}d") is not None and row.get(f"control_return_{horizon}d") is not None
            ]
            successes = sum(value > 0 for value in values)
            low, high = wilson(successes, len(values))
            ci_low, ci_high = bootstrap_paired_ci(rows, horizon)
            output.append({
                "scope": scope,
                "horizon_days": horizon,
                "event_count": len(values),
                "mean_return_pct": statistics.fmean(values) if values else None,
                "median_return_pct": statistics.median(values) if values else None,
                "up_count": successes,
                "up_rate_pct": successes / len(values) * 100 if values else None,
                "up_rate_ci95_low_pct": low,
                "up_rate_ci95_high_pct": high,
                "control_count": len(controls),
                "control_mean_return_pct": statistics.fmean(controls) if controls else None,
                "paired_count": len(paired),
                "paired_mean_edge_pct": statistics.fmean(paired) if paired else None,
                "paired_edge_ci95_low_pct": ci_low,
                "paired_edge_ci95_high_pct": ci_high,
            })
    return output


def aggregate_trough_rows(episodes: list[dict]) -> list[dict]:
    output = []
    scopes = [("ALL", episodes)] + [
        (sample, [row for row in episodes if row["sample"] == sample])
        for sample in sorted({row["sample"] for row in episodes})
    ]
    for scope, scoped in scopes:
        complete = [row for row in scoped if not row["is_censored"]]
        usable = [row for row in complete if row["confirmation_to_trough_return"] is not None]
        returns = [row["confirmation_to_trough_return"] for row in usable]
        lower_count = sum(bool(row["trough_price_is_lower"]) for row in usable)
        low, high = wilson(lower_count, len(usable))
        durations = [row["observations_to_trough"] for row in usable]
        output.append({
            "scope": scope,
            "episode_count": len(scoped),
            "censored_count": len(scoped) - len(complete),
            "usable_complete_count": len(usable),
            "lower_price_count": lower_count,
            "lower_price_rate_pct": lower_count / len(usable) * 100 if usable else None,
            "lower_price_rate_ci95_low_pct": low,
            "lower_price_rate_ci95_high_pct": high,
            "mean_confirmation_to_trough_return_pct": statistics.fmean(returns) if returns else None,
            "median_confirmation_to_trough_return_pct": statistics.median(returns) if returns else None,
            "mean_observations_to_trough": statistics.fmean(durations) if durations else None,
            "median_observations_to_trough": statistics.median(durations) if durations else None,
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


def render_report(summary: dict, trough_aggregates: list[dict], recovery_aggregates: list[dict]) -> str:
    def fmt(value):
        if value is None:
            return "-"
        if isinstance(value, float):
            return f"{value:.3f}"
        return str(value)

    trough_rows = []
    for row in trough_aggregates:
        trough_rows.append("<tr>" + "".join(
            f"<td>{html.escape(fmt(row[key]))}</td>" for key in (
                "scope", "episode_count", "censored_count", "usable_complete_count",
                "lower_price_count", "lower_price_rate_pct", "lower_price_rate_ci95_low_pct",
                "lower_price_rate_ci95_high_pct", "mean_confirmation_to_trough_return_pct",
                "median_confirmation_to_trough_return_pct", "median_observations_to_trough",
            )
        ) + "</tr>")
    recovery_rows = []
    for row in recovery_aggregates:
        recovery_rows.append("<tr>" + "".join(
            f"<td>{html.escape(fmt(row[key]))}</td>" for key in (
                "scope", "horizon_days", "event_count", "mean_return_pct", "median_return_pct",
                "up_rate_pct", "up_rate_ci95_low_pct", "up_rate_ci95_high_pct",
                "control_mean_return_pct", "paired_mean_edge_pct",
                "paired_edge_ci95_low_pct", "paired_edge_ci95_high_pct",
            )
        ) + "</tr>")
    return f"""<!doctype html><html lang="zh-Hant"><meta charset="utf-8">
<title>GT-P02 適配趨勢谷底恢復研究</title>
<style>body{{font:15px/1.55 -apple-system,sans-serif;margin:32px;color:#222}}table{{border-collapse:collapse;width:100%}}th,td{{border:1px solid #ccc;padding:6px;text-align:right}}th:first-child,td:first-child{{text-align:left}}code{{background:#eee;padding:2px 4px}}</style>
<h1>GT-P02 適配趨勢谷底恢復研究</h1>
<p>主要假設：首次進入惡化確認是預測點；連續惡化確認區段內的最低 fitTrend 日是事後結果點。第一次離開惡化確認即結束該段，日後重新進入則另算新段。檢驗谷底日股價是否低於惡化確認日，谷底不參與訊號形成。</p>
<ul><li>惡化區段：{summary['episode_count']}</li><li>完整可評估區段：{summary['usable_complete_episode_count']}</li><li>右截尾區段：{summary['censored_episode_count']}</li><li>谷底日價格較低：{summary['lower_price_count']}（{fmt(summary['lower_price_rate_pct'])}%）</li></ul>
<h2>主要結果：惡化確認價至 fitTrend 谷底價</h2>
<table><thead><tr><th>範圍</th><th>區段</th><th>截尾</th><th>可評估</th><th>較低數</th><th>較低率%</th><th>CI低</th><th>CI高</th><th>平均報酬%</th><th>中位報酬%</th><th>到谷底觀察日中位</th></tr></thead><tbody>{''.join(trough_rows)}</tbody></table>
<h2>附錄：谷底反彈後的未來報酬（不同研究問題）</h2>
<p>此表不作為惡化確認是否預告較低谷底的判定。</p>
<table><thead><tr><th>範圍</th><th>日數</th><th>事件</th><th>平均報酬%</th><th>中位報酬%</th><th>上漲率%</th><th>上漲CI低</th><th>上漲CI高</th><th>對照平均%</th><th>配對差%</th><th>差CI低</th><th>差CI高</th></tr></thead><tbody>{''.join(recovery_rows)}</tbody></table>
</html>"""


def main() -> None:
    args = parse_args()
    specs = [parse_sample(value) for value in args.sample]
    args.output.mkdir(parents=True, exist_ok=True)
    all_episodes = []
    all_events = []
    sources = []
    for sample, database, store in specs:
        observations = load_observations(sample, database)
        contexts = price_context(load_prices(store))
        episodes, events, controls = study_sample(sample, observations, contexts)
        all_episodes.extend(episodes)
        all_events.extend(events)
        sources.append({"sample": sample, "decision_base": str(database), "price_store": str(store)})
        match_controls(events, controls)

    recovery_aggregates = aggregate_rows(all_events)
    trough_aggregates = aggregate_trough_rows(all_episodes)
    overall_trough = trough_aggregates[0]
    failed = sum(bool(row["recovery_failed_new_low"]) for row in all_events)
    summary = {
        "study_id": "GT-P02",
        "baseline": "Baseline v12 / T2/S30 / S26",
        "hypothesis": "Worsening confirmation predicts a lower price at the eventual fitTrend trough of the same worsening episode",
        "signal_definition": "First valid worseningConfirmed day; no future observation participates",
        "outcome_definition": "Price on the retrospectively labelled final fitTrend trough day within the same completed worsening episode",
        "lookahead_policy": "The worsening-confirmation signal uses current-and-prior observations only; the later trough labels outcome only",
        "episode_count": len(all_episodes),
        "censored_episode_count": overall_trough["censored_count"],
        "usable_complete_episode_count": overall_trough["usable_complete_count"],
        "lower_price_count": overall_trough["lower_price_count"],
        "lower_price_rate_pct": overall_trough["lower_price_rate_pct"],
        "mean_confirmation_to_trough_return_pct": overall_trough["mean_confirmation_to_trough_return_pct"],
        "median_confirmation_to_trough_return_pct": overall_trough["median_confirmation_to_trough_return_pct"],
        "event_count": len(all_events),
        "no_recovery_episode_count": sum(row["recovery_date"] is None for row in all_episodes),
        "failed_new_low_count": failed,
        "failed_new_low_rate_pct": failed / len(all_events) * 100 if all_events else None,
        "samples": {
            sample: {
                "episodes": sum(row["sample"] == sample for row in all_episodes),
                "events": sum(row["sample"] == sample for row in all_events),
            }
            for sample, _, _ in specs
        },
    }
    manifest = {
        "study_id": "GT-P02",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "recovery_threshold": RECOVERY_THRESHOLD,
        "horizons": list(HORIZONS),
        "sources": sources,
        "primary_method": {
            "episode_start": "first valid worseningConfirmed day with observation_count >= 125",
            "episode_continuation_phases": sorted(WORSENING_PHASES),
            "episode_end": "first valid day whose phase is no longer worseningConfirmed; a later phase-5 run is a new episode",
            "outcome": "compare confirmation-day close with close on the final fitTrend minimum day of the same episode",
            "censoring": "exclude episodes still active at the fixed-window boundary from the primary result",
            "future_data": "used only to label the episode trough and its price after the confirmation signal is frozen",
        },
        "recovery_appendix_threshold": RECOVERY_THRESHOLD,
    }
    write_csv(args.output / "episodes.csv", all_episodes)
    write_csv(args.output / "events.csv", all_events)
    write_csv(args.output / "aggregate.csv", trough_aggregates)
    write_csv(args.output / "recovery-appendix.csv", recovery_aggregates)
    (args.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (args.output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (args.output / "report.html").write_text(render_report(summary, trough_aggregates, recovery_aggregates), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(json.dumps(trough_aggregates, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
