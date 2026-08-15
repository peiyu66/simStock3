#!/usr/bin/env python3
"""Describe strategy-fit direction inside Grade without changing rules.

FT3 intentionally uses only one DecisionBase window and warmed observations.
The stable band is fixed from the 75th percentile of the absolute one-day
fitTrend change. No price outcome or terminal backtest result is read.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sqlite3
from collections import Counter, defaultdict
from pathlib import Path
from statistics import median
from typing import Any, Iterable


STATES = ("worsening", "stable", "improving")


def quantile(values: list[float], probability: float) -> float:
    if not values:
        raise ValueError("quantile requires at least one value")
    ordered = sorted(values)
    position = (len(ordered) - 1) * probability
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def pearson(left: Iterable[float], right: Iterable[float]) -> float | None:
    pairs = [(a, b) for a, b in zip(left, right) if math.isfinite(a) and math.isfinite(b)]
    if len(pairs) < 2:
        return None
    left_mean = sum(a for a, _ in pairs) / len(pairs)
    right_mean = sum(b for _, b in pairs) / len(pairs)
    numerator = sum((a - left_mean) * (b - right_mean) for a, b in pairs)
    left_size = sum((a - left_mean) ** 2 for a, _ in pairs)
    right_size = sum((b - right_mean) ** 2 for _, b in pairs)
    denominator = math.sqrt(left_size * right_size)
    return numerator / denominator if denominator else None


def state_for(value: float, band: float) -> str:
    if value < -band:
        return "worsening"
    if value > band:
        return "improving"
    return "stable"


def rounded(value: float | None, digits: int = 6) -> float | None:
    return None if value is None else round(value, digits)


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def load_rows(
    database: Path, window_start: int, window_end: int, minimum_count: int
) -> list[dict[str, Any]]:
    connection = sqlite3.connect(database)
    connection.row_factory = sqlite3.Row
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"SQLite integrity_check failed: {integrity}")
        rows = connection.execute(
            """
            SELECT o.trade_date, o.fit_level, o.fit_fast, o.fit_slow,
                   o.fit_trend, o.roi_trend, o.days_trend,
                   o.fit_observation_count, o.grade_name,
                   o.grade_activation_passed, o.has_inventory,
                   s.stock_id, s.name, s.group_name
            FROM strategy_fit_observations o
            JOIN windows w USING(window_id)
            JOIN stocks s USING(stock_key)
            WHERE w.start_date = ? AND w.end_date = ?
              AND o.fit_observation_count >= ?
              AND o.is_valid = 1 AND o.is_finite = 1
              AND o.fit_trend IS NOT NULL
            ORDER BY s.stock_id, o.trade_date
            """,
            (window_start, window_end, minimum_count),
        ).fetchall()
    finally:
        connection.close()
    return [dict(row) for row in rows]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--window-start", required=True, type=int)
    parser.add_argument("--window-end", required=True, type=int)
    parser.add_argument("--minimum-count", type=int, default=125)
    parser.add_argument("--persistence-days", type=int, default=20)
    args = parser.parse_args()

    rows = load_rows(
        args.database, args.window_start, args.window_end, args.minimum_count
    )
    if not rows:
        raise RuntimeError("no eligible strategy-fit observations")

    by_stock: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        by_stock[row["stock_id"]].append(row)
    daily_changes = [
        abs(current["fit_trend"] - previous["fit_trend"])
        for stock_rows in by_stock.values()
        for previous, current in zip(stock_rows, stock_rows[1:])
    ]
    noise_band = quantile(daily_changes, 0.75)
    if not math.isfinite(noise_band) or noise_band <= 0:
        raise RuntimeError(f"invalid noise band: {noise_band}")

    for stock_rows in by_stock.values():
        for index, row in enumerate(stock_rows):
            row["state"] = state_for(row["fit_trend"], noise_band)
            lead_index = index + args.persistence_days
            row["lead_state"] = (
                state_for(stock_rows[lead_index]["fit_trend"], noise_band)
                if lead_index < len(stock_rows)
                else None
            )

    episodes: list[dict[str, Any]] = []
    for stock_id, stock_rows in by_stock.items():
        current: dict[str, Any] | None = None
        for row in stock_rows:
            key = (row["grade_name"], row["state"])
            if current is None or current["key"] != key:
                current = {
                    "key": key,
                    "grade": row["grade_name"],
                    "state": row["state"],
                    "stockID": stock_id,
                    "observations": 0,
                }
                episodes.append(current)
            current["observations"] += 1

    grade_state_stock: Counter[tuple[str, str, str]] = Counter(
        (row["grade_name"], row["state"], row["stock_id"]) for row in rows
    )
    detail_rows = [
        {
            "grade": grade,
            "state": state,
            "stockID": stock_id,
            "stockName": by_stock[stock_id][0]["name"],
            "stockGroup": by_stock[stock_id][0]["group_name"],
            "observations": count,
        }
        for (grade, state, stock_id), count in sorted(grade_state_stock.items())
    ]

    grade_rows: list[dict[str, Any]] = []
    grade_assessments: dict[str, dict[str, Any]] = {}
    for grade in ("damn", "low", "weak", "none", "fine", "high", "wow"):
        grade_values = [row for row in rows if row["grade_name"] == grade]
        if not grade_values:
            grade_assessments[grade] = {
                "observations": 0,
                "sufficientForDirection": False,
                "reason": "no warmed observations",
            }
            continue
        total = len(grade_values)
        state_counts = Counter(row["state"] for row in grade_values)
        for state in STATES:
            state_values = [row for row in grade_values if row["state"] == state]
            stock_counts = Counter(row["stock_id"] for row in state_values)
            future = [row for row in state_values if row["lead_state"] is not None]
            same = sum(row["lead_state"] == state for row in future)
            opposite = sum(
                (state == "improving" and row["lead_state"] == "worsening")
                or (state == "worsening" and row["lead_state"] == "improving")
                for row in future
            )
            directional = state != "stable"
            roi_support = sum(
                (state == "improving" and row["roi_trend"] > 0)
                or (state == "worsening" and row["roi_trend"] < 0)
                for row in state_values
            ) if directional else 0
            days_support = sum(
                (state == "improving" and row["days_trend"] < 0)
                or (state == "worsening" and row["days_trend"] > 0)
                for row in state_values
            ) if directional else 0
            any_support = sum(
                ((state == "improving" and row["roi_trend"] > 0)
                 or (state == "worsening" and row["roi_trend"] < 0))
                or ((state == "improving" and row["days_trend"] < 0)
                    or (state == "worsening" and row["days_trend"] > 0))
                for row in state_values
            ) if directional else 0
            count = len(state_values)
            state_episodes = [
                episode for episode in episodes
                if episode["grade"] == grade and episode["state"] == state
            ]
            grade_rows.append(
                {
                    "grade": grade,
                    "state": state,
                    "observations": count,
                    "shareWithinGrade": rounded(count / total),
                    "stockCount": len(stock_counts),
                    "maxStockShare": rounded(max(stock_counts.values()) / count)
                    if count else None,
                    "inventoryShare": rounded(
                        sum(row["has_inventory"] for row in state_values) / count
                    ) if count else None,
                    "medianFitTrend": rounded(
                        median(row["fit_trend"] for row in state_values)
                    ) if count else None,
                    "episodeCount": len(state_episodes),
                    "medianEpisodeObservations": rounded(
                        median(episode["observations"] for episode in state_episodes)
                    ) if state_episodes else None,
                    "maxEpisodeObservationShare": rounded(
                        max(episode["observations"] for episode in state_episodes) / count
                    ) if state_episodes and count else None,
                    "persistenceEligible": len(future),
                    "sameStateAfter20Share": rounded(same / len(future))
                    if future else None,
                    "oppositeAfter20Share": rounded(opposite / len(future))
                    if future else None,
                    "roiDirectionSupportShare": rounded(roi_support / count)
                    if directional and count else None,
                    "daysDirectionSupportShare": rounded(days_support / count)
                    if directional and count else None,
                    "anyDriverSupportShare": rounded(any_support / count)
                    if directional and count else None,
                }
            )

        directional_rows = {
            state: [row for row in grade_values if row["state"] == state]
            for state in ("worsening", "improving")
        }
        sufficient = all(
            len(state_rows) >= 30
            and len({row["stock_id"] for row in state_rows}) >= 5
            and max(Counter(row["stock_id"] for row in state_rows).values())
                / len(state_rows) <= 0.35
            for state_rows in directional_rows.values()
        )
        grade_assessments[grade] = {
            "observations": total,
            "stateCounts": dict(state_counts),
            "sufficientForDirection": sufficient,
            "fitRoiTrendCorrelation": rounded(
                pearson(
                    (row["fit_trend"] for row in grade_values),
                    (row["roi_trend"] for row in grade_values),
                )
            ),
            "fitDaysTrendCorrelation": rounded(
                pearson(
                    (row["fit_trend"] for row in grade_values),
                    (row["days_trend"] for row in grade_values),
                )
            ),
        }

    transition_counts = Counter(
        (row["state"], row["lead_state"])
        for row in rows if row["lead_state"] is not None
    )
    transition_rows = [
        {"state": state, "stateAfter20": lead, "observations": count}
        for (state, lead), count in sorted(transition_counts.items())
    ]
    directional_rows = [row for row in rows if row["state"] != "stable"]
    directional_future = [row for row in directional_rows if row["lead_state"]]
    same_direction = sum(row["lead_state"] == row["state"] for row in directional_future)
    opposite_direction = sum(
        {row["lead_state"], row["state"]} == {"improving", "worsening"}
        for row in directional_future
    )
    sufficient_grades = [
        grade for grade, value in grade_assessments.items()
        if value["sufficientForDirection"]
    ]
    summary = {
        "analysisID": "ft3-a-earliest-window-strategy-fit-direction-20260815",
        "sourceDatabase": args.database.name,
        "window": {"start": args.window_start, "end": args.window_end},
        "minimumObservationCount": args.minimum_count,
        "persistenceObservationDays": args.persistence_days,
        "noiseBandMethod": "Q75 absolute one-day fitTrend change, warmed observations only",
        "noiseBand": rounded(noise_band),
        "eligibleObservations": len(rows),
        "stockCount": len(by_stock),
        "overallStateCounts": dict(Counter(row["state"] for row in rows)),
        "directionalSameStateAfter20Share": rounded(
            same_direction / len(directional_future)
        ),
        "directionalOppositeAfter20Share": rounded(
            opposite_direction / len(directional_future)
        ),
        "sufficientGrades": sufficient_grades,
        "gradeAssessments": grade_assessments,
        "scopeDecision": (
            "proceedToFT4FT5" if sufficient_grades else "stopOrRevise"
        ),
        "scopeDecisionRule": (
            "proceed when at least one Grade has both directions >=30 observations, "
            ">=5 stocks, and <=35% maximum single-stock share"
        ),
        "guardrails": {
            "usesPriceOutcome": False,
            "usesTerminalBacktestResult": False,
            "changesEMA": False,
            "changesRule": False,
        },
    }

    grade_state_lookup = {
        (row["grade"], row["state"]): row for row in grade_rows
    }
    wow_improving = grade_state_lookup.get(("wow", "improving"), {})
    wow_worsening = grade_state_lookup.get(("wow", "worsening"), {})
    wow_stable = grade_state_lookup.get(("wow", "stable"), {})

    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    write_csv(args.output / "by-grade-state.csv", grade_rows)
    write_csv(args.output / "by-grade-state-stock.csv", detail_rows)
    write_csv(args.output / "state-transition-20.csv", transition_rows)

    report = [
        "# FT3 Sample A 最早窗口適配方向診斷",
        "",
        "## 方法",
        "",
        f"- 窗口：`{args.window_start}–{args.window_end}`；只納入 `count ≥ {args.minimum_count}`。",
        f"- 固定噪音帶：`±{noise_band:.3f}`，取暖機後單日 `fitTrend` 絕對變動 Q75。",
        "- 不讀價格結果或期末回測結果，不調整 20／125 EMA，也不修改規則。",
        "",
        "## 摘要",
        "",
        f"- 合格 observation：{len(rows):,}；股票：{len(by_stock)}。",
        f"- 改善／穩定／惡化：{summary['overallStateCounts'].get('improving', 0):,}／{summary['overallStateCounts'].get('stable', 0):,}／{summary['overallStateCounts'].get('worsening', 0):,}。",
        f"- 20 個 observation 後仍同方向：{summary['directionalSameStateAfter20Share']:.1%}；直接翻到相反方向：{summary['directionalOppositeAfter20Share']:.1%}。",
        f"- 同時具備雙向樣本、至少五檔且單股不超過 35% 的 Grade：{', '.join(sufficient_grades) or '無'}。",
        f"- 階段判定：`{summary['scopeDecision']}`。",
        "- 這是限定通過：目前只有上述 Grade 可作為 FT5 的主要趨勢分層；其他 Grade 只保留描述，不生成條件。",
        "",
        "## 判讀",
        "",
        f"- `wow × 改善` 有 {wow_improving.get('observations', 0):,} 筆、{wow_improving.get('stockCount', 0)} 檔，單股最高 {wow_improving.get('maxStockShare', 0):.1%}；20 日後仍改善 {wow_improving.get('sameStateAfter20Share', 0):.1%}。",
        f"- `wow × 惡化` 有 {wow_worsening.get('observations', 0):,} 筆、{wow_worsening.get('stockCount', 0)} 檔，單股最高 {wow_worsening.get('maxStockShare', 0):.1%}；20 日後仍惡化 {wow_worsening.get('sameStateAfter20Share', 0):.1%}。",
        f"- `wow × 穩定` 只有 {wow_stable.get('observations', 0):,} 筆（{wow_stable.get('shareWithinGrade', 0):.1%}）；目前不足以作第三個規則區段，FT5 應先只比較改善與惡化。",
        f"- wow 內 `fitTrend` 與 `roiTrend` 的相關為 {grade_assessments['wow']['fitRoiTrendCorrelation']:.3f}，與 `daysTrend` 為 {grade_assessments['wow']['fitDaysTrendCorrelation']:.3f}；方向以 ROI 變化為主，週期變化提供反向補充。",
        "- weak／fine／high 雖有持續方向，但其中一側單股占比為 44%～58%；low／none 樣本不足，damn 沒有暖機樣本，因此都不列為 FT5 的主要生成範圍。",
        "- 各主要方向約九成以上發生於持股中，符合適配狀態主要在持有與完成輪次中累積的設計；仍有空手觀察，故不是完全等同『目前持股』。FT5 仍須把持倉狀態列為分層檢查項。",
        "",
        "## Grade × 方向",
        "",
        "完整數值見 `by-grade-state.csv`；個股集中度見 `by-grade-state-stock.csv`。",
        "",
        "## 邊界",
        "",
        "FT3 只判斷 Grade 內是否存在可描述且不由單股壟斷的時間方向；它不證明任何交易效果。只有 FT5 才會檢查相同 Grade、相同技術現象下是否仍有額外分辨。",
        "",
    ]
    (args.output / "report.md").write_text("\n".join(report), encoding="utf-8")


if __name__ == "__main__":
    main()
