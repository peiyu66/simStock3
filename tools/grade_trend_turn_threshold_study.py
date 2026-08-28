#!/usr/bin/env python3
"""Calibrate Grade-trend turn thresholds from completed S32 browse stores."""

from __future__ import annotations

import argparse
import csv
import json
import math
import sqlite3
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from statistics import median


APPLE_EPOCH_UNIX = 978307200.0
GRADE_ORDER = ["damn", "low", "weak", "none", "fine", "high", "wow"]


@dataclass(frozen=True)
class Row:
    sample: str
    stock_id: str
    stock_name: str
    timestamp: float
    trend: float
    phase: int
    grade: str


@dataclass(frozen=True)
class Segment:
    key: str
    sample: str
    stock_id: str
    direction: str
    rows: tuple[Row, ...]


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def fmt(value: float | None, digits: int = 3) -> str:
    return "-" if value is None else f"{value:.{digits}f}"


def grade_for(values: sqlite3.Row, date_start: float) -> str:
    rounds = float(values["roll_rounds"] or 0)
    roll_days = float(values["roll_days"] or 0)
    sim_days = float(values["sim_days"] or 0)
    has_inventory = float(values["inventory"] or 0) > 0
    if rounds <= 1:
        days = roll_days
    else:
        previous_rounds = rounds - (1 if has_inventory else 0)
        if previous_rounds <= 0:
            days = roll_days / rounds
        else:
            previous_days = (roll_days - (sim_days if has_inventory else 0)) / previous_rounds
            days = roll_days / rounds if sim_days > previous_days else previous_days

    years = max((float(values["timestamp"]) - date_start) / 86400.0 / 365.0, 1.0)
    roi = float(values["roll_roi"] or 0) / years
    activated = rounds > 2 or days > 360
    if not activated:
        return "none"
    score = 0.0 if days <= 0 else (roi * 100 / days if roi >= 0 else roi * days / 100)
    if score > 46:
        return "wow"
    if score > 39:
        return "high"
    if score > 23:
        return "fine"
    if score >= -5:
        return "weak"
    if score >= -23:
        return "low"
    return "damn"


def load_segments(sample: str, store: Path) -> tuple[list[Segment], int]:
    connection = sqlite3.connect(f"file:{store}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        raise RuntimeError(f"{sample} integrity_check={integrity}")
    versions = connection.execute(
        "SELECT MIN(ZSIMULATIONSTATEVERSION), MAX(ZSIMULATIONSTATEVERSION) FROM ZSTOCK"
    ).fetchone()
    if tuple(versions) != (32, 32):
        raise RuntimeError(f"{sample} is not fully S32: {tuple(versions)}")

    query = """
        SELECT s.ZSID AS stock_id, s.ZSNAME AS stock_name,
               s.ZDATESTART AS date_start, t.ZDATETIME AS timestamp,
               t.ZSIMFITTREND AS trend, t.ZSIMFITTRENDPHASERAW AS phase,
               t.ZROLLROUNDS AS roll_rounds, t.ZROLLDAYS AS roll_days,
               t.ZSIMDAYS AS sim_days, t.ZSIMQTYINVENTORY AS inventory,
               t.ZROLLAMTROI AS roll_roi
        FROM ZTRADE t
        JOIN ZSTOCK s ON s.Z_PK = t.ZSTOCK
        ORDER BY s.ZSID, t.ZDATETIME
    """
    grouped: dict[str, list[Row | None]] = defaultdict(list)
    trade_count = 0
    for values in connection.execute(query):
        trade_count += 1
        timestamp = float(values["timestamp"])
        date_start = float(values["date_start"])
        phase = int(values["phase"] or 0)
        trend = values["trend"]
        if timestamp < date_start or trend is None or not math.isfinite(float(trend)):
            grouped[values["stock_id"]].append(None)
            continue
        direction = "improving" if phase in (8, 9) else "worsening" if phase in (10, 11) else None
        if direction is None:
            grouped[values["stock_id"]].append(None)
            continue
        grouped[values["stock_id"]].append(
            Row(
                sample=sample,
                stock_id=values["stock_id"],
                stock_name=values["stock_name"],
                timestamp=timestamp,
                trend=float(trend),
                phase=phase,
                grade=grade_for(values, date_start),
            )
        )
    connection.close()

    segments: list[Segment] = []
    for stock_id, rows in grouped.items():
        active: list[Row] = []
        active_direction: str | None = None
        sequence = 0

        def close_active() -> None:
            nonlocal active, active_direction, sequence
            if active and active_direction:
                sequence += 1
                segments.append(
                    Segment(
                        key=f"{sample}:{stock_id}:{active_direction}:{sequence}",
                        sample=sample,
                        stock_id=stock_id,
                        direction=active_direction,
                        rows=tuple(active),
                    )
                )
            active = []
            active_direction = None

        for row in rows:
            if row is None:
                close_active()
                continue
            direction = "improving" if row.phase in (8, 9) else "worsening"
            if active_direction is not None and direction != active_direction:
                close_active()
            active_direction = direction
            active.append(row)
        close_active()
    return segments, trade_count


def simulate(segment: Segment, turn: float, reset: float | None) -> dict:
    rows = segment.rows
    improving = segment.direction == "improving"
    extreme = rows[0].trend
    state = "seeking"
    turn_start: int | None = None
    turn_grade: str | None = None
    spells: list[dict] = []
    reset_events: list[dict] = []
    adverse_moves: list[dict] = []
    first_turn_index: int | None = None

    for index in range(1, len(rows)):
        row = rows[index]
        previous = rows[index - 1]
        if state == "seeking":
            extreme = max(extreme, row.trend) if improving else min(extreme, row.trend)
            crossed = row.trend < extreme - turn if improving else row.trend > extreme + turn
            if crossed:
                state = "turned"
                turn_start = index
                turn_grade = row.grade
                if first_turn_index is None:
                    first_turn_index = index
            continue

        adverse = row.trend - previous.trend if improving else previous.trend - row.trend
        if adverse > 0:
            adverse_moves.append({"magnitude": adverse, "grade": row.grade})
        crossed_extreme = row.trend > extreme if improving else row.trend < extreme
        daily_reset = reset is not None and adverse > reset
        if crossed_extreme or daily_reset:
            duration = index - (turn_start if turn_start is not None else index)
            spells.append(
                {
                    "grade": turn_grade or "unknown",
                    "duration": duration,
                    "reason": "reset",
                }
            )
            reset_events.append(
                {
                    "grade": row.grade,
                    "magnitude": max(adverse, 0.0),
                    "threshold_only": daily_reset and not crossed_extreme,
                }
            )
            state = "seeking"
            extreme = row.trend
            turn_start = None
            turn_grade = None

    if state == "turned" and turn_start is not None:
        spells.append(
            {
                "grade": turn_grade or "unknown",
                "duration": len(rows) - turn_start,
                "reason": "phase_end",
            }
        )
    return {
        "spells": spells,
        "resets": reset_events,
        "adverse_moves": adverse_moves,
        "first_turn_index": first_turn_index,
    }


def summarize(results: list[dict], segment_count: int, confirmed_days: int) -> dict:
    spells = [spell for result in results for spell in result["spells"]]
    resets = [event for result in results for event in result["resets"]]
    durations = [spell["duration"] for spell in spells]
    return {
        "segments": segment_count,
        "confirmed_days": confirmed_days,
        "turns": len(spells),
        "turns_per_1000_days": len(spells) * 1000 / confirmed_days if confirmed_days else 0,
        "resets": len(resets),
        "threshold_only_resets": sum(event["threshold_only"] for event in resets),
        "short_reset_5d": sum(
            spell["reason"] == "reset" and spell["duration"] <= 5 for spell in spells
        ),
        "short_reset_5d_rate": (
            sum(spell["reason"] == "reset" and spell["duration"] <= 5 for spell in spells)
            / len(spells)
            if spells
            else 0
        ),
        "phase_end_rate": (
            sum(spell["reason"] == "phase_end" for spell in spells) / len(spells)
            if spells
            else 0
        ),
        "median_duration": median(durations) if durations else None,
    }


def analyze(segments: list[Segment]) -> dict:
    report: dict = {"configs": [], "by_grade": [], "daily_scale": []}
    configurations = [
        ("worsening", 0.1, None, "no-daily-reset"),
        ("worsening", 0.1, 0.3, "current"),
        ("worsening", 0.2, 0.3, "turn-0.2"),
        ("worsening", 0.3, 0.3, "turn-0.3"),
        ("improving", 0.1, None, "current"),
        ("improving", 0.1, 0.3, "symmetric-reset-0.3"),
        ("improving", 0.2, None, "turn-0.2"),
        ("improving", 0.3, None, "turn-0.3"),
    ]
    for sample in ("A", "C", "ALL"):
        for direction, turn, reset, label in configurations:
            chosen = [
                segment
                for segment in segments
                if segment.direction == direction and (sample == "ALL" or segment.sample == sample)
            ]
            results = [simulate(segment, turn, reset) for segment in chosen]
            summary = summarize(results, len(chosen), sum(len(segment.rows) for segment in chosen))
            current_first = {
                segment.key: simulate(segment, 0.1, 0.3 if direction == "worsening" else None)[
                    "first_turn_index"
                ]
                for segment in chosen
            }
            delays: list[int] = []
            missed = 0
            for segment, result in zip(chosen, results):
                base = current_first[segment.key]
                candidate = result["first_turn_index"]
                if base is None:
                    continue
                if candidate is None:
                    missed += 1
                else:
                    delays.append(candidate - base)
            summary.update(
                {
                    "sample": sample,
                    "direction": direction,
                    "turn_threshold": turn,
                    "reset_threshold": reset,
                    "label": label,
                    "median_first_turn_delay": median(delays) if delays else None,
                    "segments_missing_later_turn": missed,
                }
            )
            report["configs"].append(summary)

    for sample in ("A", "C", "ALL"):
        for direction in ("worsening", "improving"):
            chosen = [
                segment
                for segment in segments
                if segment.direction == direction and (sample == "ALL" or segment.sample == sample)
            ]
            reset = 0.3 if direction == "worsening" else None
            results = [simulate(segment, 0.1, reset) for segment in chosen]
            spells = [spell for result in results for spell in result["spells"]]
            moves = [move for result in results for move in result["adverse_moves"]]
            for grade in GRADE_ORDER:
                grade_spells = [spell for spell in spells if spell["grade"] == grade]
                reset_spells = [spell for spell in grade_spells if spell["reason"] == "reset"]
                grade_moves = [move["magnitude"] for move in moves if move["grade"] == grade]
                report["by_grade"].append(
                    {
                        "sample": sample,
                        "direction": direction,
                        "grade": grade,
                        "turns": len(grade_spells),
                        "resets": len(reset_spells),
                        "short_reset_5d": sum(spell["duration"] <= 5 for spell in reset_spells),
                        "short_reset_5d_rate": (
                            sum(spell["duration"] <= 5 for spell in reset_spells) / len(grade_spells)
                            if grade_spells
                            else None
                        ),
                        "median_duration": (
                            median([spell["duration"] for spell in grade_spells])
                            if grade_spells
                            else None
                        ),
                    }
                )
                report["daily_scale"].append(
                    {
                        "sample": sample,
                        "direction": direction,
                        "grade": grade,
                        "count": len(grade_moves),
                        "p50": percentile(grade_moves, 0.50),
                        "p75": percentile(grade_moves, 0.75),
                        "p90": percentile(grade_moves, 0.90),
                        "p95": percentile(grade_moves, 0.95),
                    }
                )
    return report


def write_report(output: Path, report: dict, segments: list[Segment], trade_counts: dict[str, int]) -> str:
    output.mkdir(parents=True, exist_ok=False)
    with (output / "summary.json").open("w", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2, sort_keys=True)
    for name in ("configs", "by_grade", "daily_scale"):
        rows = report[name]
        with (output / f"{name}.csv").open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)

    lines = [
        "# GT-P05-TURN-CAL",
        "",
        f"Stores: A={trade_counts['A']} trades, C={trade_counts['C']} trades; segments={len(segments)}.",
        "",
        "## Threshold comparison (combined A+C)",
        "",
        "| Direction | Variant | Turns | /1000d | Resets | New resets | <=5d reset | End rate | Median days | Delay | Missing |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in report["configs"]:
        if row["sample"] != "ALL":
            continue
        lines.append(
            "| {direction} | {label} | {turns} | {rate} | {resets} | {new} | {short} | {end} | {duration} | {delay} | {missing} |".format(
                direction=row["direction"],
                label=row["label"],
                turns=row["turns"],
                rate=fmt(row["turns_per_1000_days"], 1),
                resets=row["resets"],
                new=row["threshold_only_resets"],
                short=f"{row['short_reset_5d_rate']:.1%}",
                end=f"{row['phase_end_rate']:.1%}",
                duration=fmt(row["median_duration"], 1),
                delay=fmt(row["median_first_turn_delay"], 1),
                missing=row["segments_missing_later_turn"],
            )
        )
    lines += [
        "",
        "## Current 0.1 turn by Grade (A and C shown separately)",
        "",
        "| Sample | Direction | Grade | Turns | Resets | <=5d rate | Median days |",
        "|---|---|---|---:|---:|---:|---:|",
    ]
    for row in report["by_grade"]:
        if row["sample"] == "ALL" or row["turns"] < 5:
            continue
        lines.append(
            "| {sample} | {direction} | {grade} | {turns} | {resets} | {short} | {duration} |".format(
                sample=row["sample"],
                direction=row["direction"],
                grade=row["grade"],
                turns=row["turns"],
                resets=row["resets"],
                short=fmt(row["short_reset_5d_rate"] * 100 if row["short_reset_5d_rate"] is not None else None, 1),
                duration=fmt(row["median_duration"], 1),
            )
        )
    lines += [
        "",
        "## Adverse daily movement scale while turned (combined A+C)",
        "",
        "| Direction | Grade | N | P50 | P75 | P90 | P95 |",
        "|---|---|---:|---:|---:|---:|---:|",
    ]
    for row in report["daily_scale"]:
        if row["sample"] != "ALL" or row["count"] < 10:
            continue
        lines.append(
            f"| {row['direction']} | {row['grade']} | {row['count']} | {fmt(row['p50'])} | {fmt(row['p75'])} | {fmt(row['p90'])} | {fmt(row['p95'])} |"
        )
    text = "\n".join(lines) + "\n"
    (output / "report.md").write_text(text, encoding="utf-8")
    return text


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--store", action="append", required=True, metavar="SAMPLE=PATH")
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    stores: dict[str, Path] = {}
    for item in arguments.store:
        sample, path = item.split("=", 1)
        stores[sample.upper()] = Path(path)
    if set(stores) != {"A", "C"}:
        raise SystemExit("Exactly A and C stores are required")

    all_segments: list[Segment] = []
    trade_counts: dict[str, int] = {}
    for sample in ("A", "C"):
        segments, trade_count = load_segments(sample, stores[sample])
        all_segments.extend(segments)
        trade_counts[sample] = trade_count
    report = analyze(all_segments)
    print(write_report(arguments.output, report, all_segments, trade_counts), end="")


if __name__ == "__main__":
    main()
