#!/usr/bin/env python3
"""Audit simStock3 Grade mechanics without changing simulation rules.

The audit reconstructs Trade.grade from a completed Core Data SQLite store,
summarizes exposure and transitions, measures same-day rule sensitivity to
Grade, and produces a focused timeline for 富邦媒. It is descriptive: the
selected H/L stock groups are intentionally extreme and are not treated as a
representative market sample.
"""

from __future__ import annotations

import argparse
import csv
import html
import json
import math
import sqlite3
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from statistics import mean, median
from typing import Any, Iterable


APPLE_EPOCH = datetime(2001, 1, 1)
GRADE_VALUES = (-3, -2, -1, 0, 1, 2, 3)
GRADE_NAMES = {
    -3: "damn",
    -2: "low",
    -1: "weak",
    0: "none",
    1: "fine",
    2: "high",
    3: "wow",
}


@dataclass
class Episode:
    sid: str
    name: str
    group: str
    grade: int
    start_index: int
    end_index: int
    start_date: datetime
    end_date: datetime
    start_price: float
    end_price: float
    start_roi: float
    end_roi: float
    start_days: float
    end_days: float

    @property
    def observations(self) -> int:
        return self.end_index - self.start_index + 1

    @property
    def price_change(self) -> float:
        if self.start_price == 0:
            return 0
        return 100 * (self.end_price - self.start_price) / self.start_price


def apple_instant(value: float) -> datetime:
    return APPLE_EPOCH + timedelta(seconds=float(value))


def apple_date(value: float) -> datetime:
    instant = apple_instant(value)
    taipei = instant + timedelta(hours=8)
    return taipei.replace(hour=0, minute=0, second=0, microsecond=0)


def trade_days(row: dict[str, Any]) -> float:
    rounds = float(row["roll_rounds"] or 0)
    roll_days = float(row["roll_days"] or 0)
    sim_days = float(row["sim_days"] or 0)
    if rounds <= 1:
        return roll_days
    has_inventory = float(row["qty_inventory"] or 0) > 0
    previous_rounds = rounds - (1 if has_inventory else 0)
    if previous_rounds <= 0:
        return roll_days
    previous_days = (roll_days - (sim_days if has_inventory else 0)) / previous_rounds
    return roll_days / rounds if sim_days > previous_days else previous_days


def grade_days(
    rounds: float, roll_days: float, sim_days: float, has_inventory: bool
) -> float:
    if rounds <= 1:
        return roll_days
    previous_rounds = rounds - (1 if has_inventory else 0)
    if previous_rounds <= 0:
        return roll_days
    previous_days = (roll_days - (sim_days if has_inventory else 0)) / previous_rounds
    return roll_days / rounds if sim_days > previous_days else previous_days


def trade_roi(row: dict[str, Any]) -> float:
    years = max((row["date"] - row["date_start"]).total_seconds() / 86400 / 365, 1)
    return float(row["roll_amt_roi"] or 0) / years


def grade_for(rounds: float, days: float, roi: float) -> int:
    if rounds > 2 or days > 360:
        if days < 65 and roi > 20:
            return 3
        if days < 65 and roi > 10:
            return 2
        if days < 70 and roi > 5:
            return 1
        if days > 180 or roi < -20:
            return -3
        if days > 120 or roi < -10:
            return -2
        if days > 60 or roi < -1:
            return -1
    return 0


def by_grade(
    values: list[float],
    grade: int,
    low_grade: int | None = None,
    high_grade: int | None = None,
) -> float:
    low = -1 if low_grade is None else low_grade
    high = 2 if high_grade is None else high_grade
    if grade <= low:
        return values[0]
    if grade >= high:
        return values[-1]
    if len(values) == 3:
        return values[1]
    if high_grade is not None and low_grade is None:
        return values[0]
    return values[-1]


def finalize_rows(
    rows: list[dict[str, Any]],
    stocks_by_sid: dict[str, dict[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    by_stock: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        by_stock[row["sid"]].append(row)
    for stock_rows in by_stock.values():
        for index, row in enumerate(stock_rows):
            if index == 0 or row["date"] < row["date_start"]:
                row["grade"] = 0
                row["decision_days"] = 0.0
                row["decision_roi"] = 0.0
                row["decision_unit_roi"] = 0.0
                row["decision_invest_times"] = 0.0
                continue
            previous = stock_rows[index - 1]
            rounds = float(previous["roll_rounds"] or 0)
            roll_days = float(previous["roll_days"] or 0)
            has_inventory = float(previous["qty_inventory"] or 0) > 0
            sim_days = 0.0
            if has_inventory:
                interval = round((row["date"] - previous["date"]).total_seconds() / 86400)
                sim_days = float(previous["sim_days"] or 0) + interval
                roll_days += interval
            decision_days = grade_days(rounds, roll_days, sim_days, has_inventory)
            years = max(
                (row["date"] - row["date_start"]).total_seconds() / 86400 / 365,
                1,
            )
            decision_roi = float(previous["roll_amt_roi"] or 0) / years
            row["decision_days"] = decision_days
            row["decision_roi"] = decision_roi
            previous_unit_cost = float(previous["sim_unit_cost"] or 0)
            row["decision_unit_roi"] = (
                100
                * (float(row["price_close"] or 0) - previous_unit_cost)
                / previous_unit_cost
                if has_inventory and previous_unit_cost > 0
                else 0
            )
            row["decision_invest_times"] = float(previous["invest_times"] or 0)
            row["grade"] = grade_for(rounds, decision_days, decision_roi)
    return rows, stocks_by_sid


def read_rows(store: Path) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    connection = sqlite3.connect(f"file:{store}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    stocks_query = """
        SELECT Z_PK AS stock_pk, ZSID AS sid, ZSNAME AS name, ZGROUP AS stock_group,
               ZDATESTART AS date_start
        FROM ZSTOCK
        ORDER BY ZGROUP, ZSID
    """
    stocks: dict[int, dict[str, Any]] = {}
    stocks_by_sid: dict[str, dict[str, Any]] = {}
    for raw in connection.execute(stocks_query):
        item = dict(raw)
        item["sid"] = str(item["sid"])
        item["date_start"] = apple_date(item["date_start"])
        stocks[item["stock_pk"]] = item
        stocks_by_sid[item["sid"]] = item

    columns = {
        "Z_PK": "pk",
        "ZSTOCK": "stock_pk",
        "ZDATETIME": "date_value",
        "ZPRICECLOSE": "price_close",
        "ZPRICEHIGH": "price_high",
        "ZPRICELOW": "price_low",
        "ZPRICEOPEN": "price_open",
        "ZROLLAMTROI": "roll_amt_roi",
        "ZROLLDAYS": "roll_days",
        "ZROLLROUNDS": "roll_rounds",
        "ZSIMDAYS": "sim_days",
        "ZSIMINVESTADDED": "invest_added",
        "ZSIMINVESTBYUSER": "invest_user",
        "ZSIMINVESTTIMES": "invest_times",
        "ZSIMQTYBUY": "qty_buy",
        "ZSIMQTYINVENTORY": "qty_inventory",
        "ZSIMQTYSELL": "qty_sell",
        "ZSIMUNITCOST": "sim_unit_cost",
        "ZSIMUNITROI": "sim_unit_roi",
        "ZTHIGHDIFF": "t_high_diff",
        "ZTHIGHDIFF125": "t_high_diff125",
        "ZTHIGHDIFFZ125": "t_high_diff_z125",
        "ZTKDDZ125": "kd_d_z125",
        "ZTKDDZ250": "kd_d_z250",
        "ZTKDJ": "kd_j",
        "ZTKDJZ125": "kd_j_z125",
        "ZTKDJZ250": "kd_j_z250",
        "ZTKDK": "kd_k",
        "ZTKDKMIN9": "kd_k_min9",
        "ZTKDKZ125": "kd_k_z125",
        "ZTKDKZ250": "kd_k_z250",
        "ZTLOWDIFF": "t_low_diff",
        "ZTLOWDIFF125": "t_low_diff125",
        "ZTLOWDIFFZ125": "t_low_diff_z125",
        "ZTMA20DAYS": "ma20_days",
        "ZTMA20DIFF": "ma20_diff",
        "ZTMA20DIFFMIN9": "ma20_diff_min9",
        "ZTMA20DIFFMAX9": "ma20_diff_max9",
        "ZTMA20DIFFZ125": "ma20_diff_z125",
        "ZTMA60DIFF": "ma60_diff",
        "ZTMA60DIFFMIN9": "ma60_diff_min9",
        "ZTMA60DIFFMAX9": "ma60_diff_max9",
        "ZTMA60DIFFZ125": "ma60_diff_z125",
        "ZTOSC": "osc",
        "ZTOSCMIN9": "osc_min9",
        "ZTOSCZ125": "osc_z125",
        "ZTOSCZ250": "osc_z250",
        "ZTZ125": "t_z125",
        "ZVZ125": "v_z125",
        "ZVOLUMECLOSE": "volume_close",
        "ZVMIN9": "v_min9",
        "ZSIMRULE": "sim_rule",
        "ZSIMRULEBUY": "sim_rule_buy",
        "ZSIMRULEINVEST": "sim_rule_invest",
    }
    select = ", ".join(f"t.{source} AS {target}" for source, target in columns.items())
    query = f"SELECT {select} FROM ZTRADE t ORDER BY t.ZSTOCK, t.ZDATETIME"
    rows: list[dict[str, Any]] = []
    for raw in connection.execute(query):
        row = dict(raw)
        stock = stocks[row["stock_pk"]]
        row.update(stock)
        row["date_time"] = apple_instant(row["date_value"])
        row["date"] = apple_date(row["date_value"])
        row["days"] = trade_days(row)
        row["roi"] = trade_roi(row)
        row["end_grade"] = grade_for(
            float(row["roll_rounds"] or 0), row["days"], row["roi"]
        )
        rows.append(row)
    connection.close()
    return finalize_rows(rows, stocks_by_sid)


def read_csv_rows(path: Path) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    text_fields = {"sid", "name", "stock_group", "sim_rule", "sim_rule_buy", "sim_rule_invest"}
    rows: list[dict[str, Any]] = []
    stocks_by_sid: dict[str, dict[str, Any]] = {}
    with path.open(encoding="utf-8", newline="") as handle:
        for index, raw in enumerate(csv.DictReader(handle), start=1):
            row: dict[str, Any] = {}
            for key, value in raw.items():
                row[key] = value if key in text_fields else float(value or 0)
            row["pk"] = index
            row["date_time"] = apple_instant(row["date_value"])
            row["date"] = apple_date(row["date_value"])
            row["date_start"] = apple_date(row["date_start"])
            row["days"] = trade_days(row)
            row["roi"] = trade_roi(row)
            row["end_grade"] = grade_for(
                float(row["roll_rounds"] or 0), row["days"], row["roi"]
            )
            rows.append(row)
            stocks_by_sid.setdefault(
                row["sid"],
                {
                    "sid": row["sid"],
                    "name": row["name"],
                    "stock_group": row["stock_group"],
                    "date_start": row["date_start"],
                },
            )
    return finalize_rows(rows, stocks_by_sid)


def grouped_rows(rows: Iterable[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    result: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        result[row["sid"]].append(row)
    return result


def build_episodes(rows_by_sid: dict[str, list[dict[str, Any]]]) -> list[Episode]:
    episodes: list[Episode] = []
    for sid, all_rows in rows_by_sid.items():
        active = [row for row in all_rows if row["date"] >= row["date_start"]]
        if not active:
            continue
        start = 0
        for index in range(1, len(active) + 1):
            if index < len(active) and active[index]["grade"] == active[start]["grade"]:
                continue
            first = active[start]
            last = active[index - 1]
            episodes.append(
                Episode(
                    sid=sid,
                    name=first["name"],
                    group=first["stock_group"],
                    grade=first["grade"],
                    start_index=start,
                    end_index=index - 1,
                    start_date=first["date"],
                    end_date=last["date"],
                    start_price=float(first["price_close"] or 0),
                    end_price=float(last["price_close"] or 0),
                    start_roi=first["decision_roi"],
                    end_roi=last["decision_roi"],
                    start_days=first["decision_days"],
                    end_days=last["decision_days"],
                )
            )
            start = index
    return episodes


def write_csv(path: Path, rows: list[dict[str, Any]], fieldnames: list[str]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def exposure_rows(
    rows_by_sid: dict[str, list[dict[str, Any]]], episodes: list[Episode]
) -> list[dict[str, Any]]:
    episode_map: dict[tuple[str, int], list[int]] = defaultdict(list)
    for episode in episodes:
        episode_map[(episode.sid, episode.grade)].append(episode.observations)
    output: list[dict[str, Any]] = []
    for sid, all_rows in rows_by_sid.items():
        active = [row for row in all_rows if row["date"] >= row["date_start"]]
        counts = Counter(row["grade"] for row in active)
        total = len(active)
        for grade in GRADE_VALUES:
            lengths = episode_map[(sid, grade)]
            output.append(
                {
                    "股群": active[0]["stock_group"],
                    "代號": sid,
                    "簡稱": active[0]["name"],
                    "Grade": GRADE_NAMES[grade],
                    "交易日數": counts[grade],
                    "占比%": round(100 * counts[grade] / total, 2) if total else 0,
                    "區段數": len(lengths),
                    "區段中位交易日": round(median(lengths), 1) if lengths else 0,
                    "最長區段交易日": max(lengths) if lengths else 0,
                }
            )
    return output


def transition_rows(episodes: list[Episode]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    by_sid: dict[str, list[Episode]] = defaultdict(list)
    for episode in episodes:
        by_sid[episode.sid].append(episode)
    output: list[dict[str, Any]] = []
    short_reversions = 0
    long_jumps = 0
    for sid, items in by_sid.items():
        for index in range(1, len(items)):
            previous = items[index - 1]
            current = items[index]
            jump = current.grade - previous.grade
            is_long_jump = abs(jump) >= 2
            is_short_reversion = (
                index + 1 < len(items)
                and items[index + 1].grade == previous.grade
                and current.observations <= 20
            )
            long_jumps += int(is_long_jump)
            short_reversions += int(is_short_reversion)
            output.append(
                {
                    "股群": current.group,
                    "代號": sid,
                    "簡稱": current.name,
                    "日期": current.start_date.strftime("%Y-%m-%d"),
                    "原Grade": GRADE_NAMES[previous.grade],
                    "新Grade": GRADE_NAMES[current.grade],
                    "跨級數": jump,
                    "新區段交易日": current.observations,
                    "20日內回原級": "是" if is_short_reversion else "否",
                    "轉級時實年報酬率": round(current.start_roi, 3),
                    "轉級時平均週期": round(current.start_days, 2),
                    "轉級時收盤價": round(current.start_price, 2),
                }
            )
    summary = {
        "transitionCount": len(output),
        "longJumpCount": long_jumps,
        "shortReversionCount": short_reversions,
    }
    return output, summary


def grade_rule_outputs(
    row: dict[str, Any], previous: dict[str, Any], grade: int
) -> dict[str, float]:
    mmdd = row["date"].strftime("%m%d")
    ma20_range = float(row["ma20_diff_max9"] or 0) - float(
        row["ma20_diff_min9"] or 0
    )
    ma60_range = float(row["ma60_diff_max9"] or 0) - float(
        row["ma60_diff_min9"] or 0
    )
    min9_count = sum(
        (
            row["ma60_diff"] == row["ma60_diff_min9"],
            row["ma20_diff"] == row["ma20_diff_min9"],
            row["kd_k"] == row["kd_k_min9"],
            row["osc"] == row["osc_min9"],
        )
    )
    wave = ma20_range > 6 or ma60_range > 7
    close_gain = (
        100
        * (float(row["price_close"] or 0) - float(previous["price_close"] or 0))
        / float(previous["price_close"] or 1)
    )
    z125_count = sum(
        value < -1
        for value in (
            row["ma20_diff_z125"],
            row["ma60_diff_z125"],
            row["kd_k_z125"],
            row["kd_d_z125"],
            row["kd_j_z125"],
            row["osc_z125"],
        )
    )
    return {
        "H-P01": float(
            row["ma60_diff_z125"] > by_grade([0.85, 0.75], grade)
            and row["ma60_diff_z125"]
            < by_grade([2, 2.5], grade, low_grade=-2)
        ),
        "H-P03a/b": float(
            (
                row["ma60_diff"] > by_grade([-0.5, 0], grade)
                and row["ma20_diff"] > by_grade([-0.5, 0], grade)
            )
            or grade == -3
        ),
        "H-P04": float(previous["v_z125"] > (2 if grade <= -1 else 1.5)),
        "H-N01a/b": -float(
            (
                row["osc_z125"] > 1.8
                and row["kd_j_z125"] > 1.5
                and grade < 2
            )
            or row["kd_j_z125"] > 1.8
        ),
        "H-N02a/b": -float(
            row["kd_k_z125"] < -0.8
            or row["kd_k_z125"] > (2 if grade <= -1 else 1.8)
        ),
        "H-N05": -float(min9_count >= 1 and grade >= -2),
        "H-N06": -float(grade <= -1 and wave),
        "H-N07": -float(grade == -3 and wave),
        "H-N08": -float(grade == -3 and row["ma20_diff_z125"] > 1.6),
        "H-N09": -float(
            row["t_high_diff_z125"] > by_grade([0.4, 1.1, 1.3], grade)
            and row["t_low_diff_z125"] > by_grade([0.5, 1.2, 1.5], grade)
        ),
        "H-C01": -float(
            mmdd >= ("0726" if grade <= -1 else "0801") and mmdd <= "0810"
        ),
        "H-C02": -float(
            mmdd >= ("0221" if grade <= -1 else "0226") and mmdd <= "0305"
        ),
        "L-P06": float(row["v_z125"] < by_grade([-0.2, 0.3], grade)),
        "L-P07": float(
            min9_count >= 2 and row["ma60_diff_z125"] > -0.5 and grade >= 0
        ),
        "L-P08": float(
            row["t_high_diff_z125"]
            < by_grade([-1.5, -1.35, -1.2], grade)
        ),
        "L-N02": -float(
            row["ma60_diff"] == row["ma60_diff_min9"]
            and row["ma20_diff"] == row["ma20_diff_min9"]
            and row["osc"] == row["osc_min9"]
            and grade in (-3, 3)
        ),
        "L-C01": -float(
            mmdd >= ("0726" if grade <= -1 else "0801") and mmdd <= "0815"
        ),
        "L-C02": float(mmdd >= "0821" and mmdd <= "0831" and grade <= -1),
        "L-P09": float(
            grade >= -1 and (row["ma60_diff"] < -30 or row["ma20_diff"] < -30)
        ),
        "S-P06": float(
            (
                row["t_high_diff_z125"] > by_grade([-1, -0.5, 0], grade)
                and row["t_low_diff_z125"] > by_grade([-0.4, 0.1, 0.8], grade)
            )
            or row["t_z125"] > by_grade([1.2, 1.5], grade)
        ),
        "S-N05": -float(row["v_z125"] > 1 and grade >= 1),
        "S-N02": (
            by_grade([-2, -1], grade, high_grade=3)
            if grade > 1 and close_gain >= 7.5
            else 0
        ),
        "S-N03": -float(grade <= 1 and row["t_high_diff"] >= 9),
        "S-T01a門檻": by_grade([1, 0], grade, high_grade=2),
        "S-T01f天數": by_grade([40, 60], grade, high_grade=2),
        "S-T01g天數": by_grade([20, 30], grade, high_grade=2),
        "S-T01h天數": by_grade([45, 10], grade),
        "S-T01c ROI": by_grade([1.5, 2.5], grade),
        "S-T02a分數": 1 if grade >= 0 and row["sim_days"] < 400 else 2,
        "S-T02c ROI": -20 if grade <= -1 else -15,
        "A-P01a/b": float(z125_count >= 2 or grade <= -1),
        "A-P02": float(min9_count >= (3 if grade >= 3 else 2)),
        "A-P04": float(
            row["t_high_diff_z125"]
            < by_grade([-2, -2.5], grade, high_grade=2)
            and row["t_low_diff_z125"]
            > by_grade([-1, -2], grade, low_grade=-2)
        ),
        "A-N01": -2 * float(grade >= 0),
        "A-N02": -float(row["t_low_diff"] >= 8.5 and grade <= -2),
        "A-T02分數": 2 if grade <= -2 else 3,
        "A-E02資格": float(row["decision_unit_roi"] < -45 and grade >= 1),
    }


def minimum9_count(row: dict[str, Any]) -> int:
    return sum(
        (
            row["ma60_diff"] == row["ma60_diff_min9"],
            row["ma20_diff"] == row["ma20_diff_min9"],
            row["kd_k"] == row["kd_k_min9"],
            row["osc"] == row["osc_min9"],
        )
    )


def buy_signal(
    row: dict[str, Any], previous: dict[str, Any], grade: int
) -> str:
    outputs = grade_rule_outputs(row, previous, grade)
    mmdd = row["date"].strftime("%m%d")
    want_h = sum(
        outputs[key]
        for key in (
            "H-P01",
            "H-P03a/b",
            "H-P04",
            "H-N01a/b",
            "H-N02a/b",
            "H-N05",
            "H-N06",
            "H-N07",
            "H-N08",
            "H-N09",
            "H-C01",
            "H-C02",
        )
    )
    want_h += float(
        row["ma20_diff"] - row["ma60_diff"] > 1 and row["ma20_days"] > 0
    )
    want_h -= float(row["volume_close"] == row["v_min9"])
    want_h -= float(row["osc_z125"] < -0.5)
    want_h += float("0801" <= mmdd <= "0831")
    want_h += float("0301" <= mmdd <= "0331")
    if want_h >= 0:
        return "H"

    min9_count = minimum9_count(row)
    want_l = sum(
        outputs[key]
        for key in (
            "L-P06",
            "L-P07",
            "L-P08",
            "L-N02",
            "L-C01",
            "L-C02",
            "L-P09",
        )
    )
    want_l += float(row["kd_j"] < -1 or row["kd_k"] < 9)
    want_l += float(row["kd_j"] < -7)
    want_l += float(row["kd_k_z125"] < -0.9 and row["kd_k_z250"] < -0.9)
    want_l += float(row["kd_d_z125"] < -0.9 and row["kd_d_z250"] < -0.9)
    want_l += float(row["osc_z125"] < -0.9 and row["osc_z250"] < -0.9)
    want_l -= float(row["ma20_days"] < -20)
    want_l += float("0801" <= mmdd <= "0831")
    return "L" if want_l >= 5 else ""


def no_recent_investment(history: list[dict[str, Any]], days: int) -> bool:
    for index, row in enumerate(reversed(history[-60:])):
        invested = float(row["invest_user"] or 0) + float(row["invest_added"] or 0)
        if invested == 1:
            if index < days:
                return False
            if days >= 60:
                return False
        elif float(row["sim_days"] or 0) <= 1:
            break
    return True


def sell_signal(
    row: dict[str, Any],
    previous: dict[str, Any],
    history: list[dict[str, Any]],
    grade: int,
) -> bool:
    outputs = grade_rule_outputs(row, previous, grade)
    want_s = sum(
        (
            float(row["kd_j"] > 101),
            float(row["kd_j_z125"] > 1 and row["kd_j_z250"] > 1),
            float(row["kd_k_z125"] > 0.9),
            float(row["kd_d_z125"] > 0.9),
            float(row["osc_z125"] > 0.9 and row["osc_z250"] > 0.9),
            outputs["S-P06"],
            -float(
                row["ma60_diff"] == row["ma60_diff_min9"]
                or row["ma20_diff"] == row["ma20_diff_min9"]
            ),
            outputs["S-N05"],
            outputs["S-N02"],
            outputs["S-N03"],
            -float(row["decision_invest_times"] >= 4),
        )
    )
    roi = float(row["decision_unit_roi"] or 0)
    sim_days = float(row["sim_days"] or 0)
    roi22 = roi > 22.5 and want_s > outputs["S-T01a門檻"]
    roi18 = roi > 15.5 and sim_days < outputs["S-T01f天數"]
    roi13 = roi > 9.5 and sim_days < outputs["S-T01g天數"]
    roi09 = roi > 6.5 and sim_days < outputs["S-T01h天數"]
    roi03 = roi > 3.5 and (
        row["kd_k_z125"] > 1.5 or row["kd_d_z125"] > 1.5
    )
    roi02 = roi > outputs["S-T01c ROI"]
    roi00 = roi > 0.45 and sim_days > 1
    base = (
        (want_s >= 6 and roi00)
        or (want_s >= 5 and roi02)
        or (want_s >= 4 and (roi03 or (roi00 and sim_days > 75)))
        or (want_s >= 3 and (roi18 or roi13 or roi09))
        or roi22
    )
    cut1a = row["t_low_diff125"] - row["t_high_diff125"] < 30
    cut1b = roi > -15 and grade > -1
    cut1c = roi > -20 and (sim_days > 300 or grade <= -1)
    cut1 = cut1a and (cut1b or cut1c) and sim_days > 240
    cut2 = sim_days > 400 and roi > outputs["S-T02c ROI"]
    no_invested60 = no_recent_investment(history, 60)
    cut = (
        want_s >= outputs["S-T02a分數"]
        and (cut1 or cut2)
        and no_invested60
    )
    return base or cut


def add_candidate(
    row: dict[str, Any],
    previous: dict[str, Any],
    grade: int,
    current_buy_signal: str,
) -> bool:
    outputs = grade_rule_outputs(row, previous, grade)
    want_a = sum(
        (
            outputs["A-P01a/b"],
            outputs["A-P02"],
            float(row["decision_unit_roi"] < -35),
            outputs["A-P04"],
            float(row["ma20_diff"] < -20 or row["ma60_diff"] < -20),
            float(
                row["ma20_diff_z125"] < -2.5
                and row["ma60_diff_z125"] < -2.8
            ),
            float(row["ma20_diff"] < -8 and row["ma60_diff"] < -8),
            float(current_buy_signal == "L" and row["decision_unit_roi"] < -25),
            outputs["A-N01"],
            outputs["A-N02"],
        )
    )
    roi = float(row["decision_unit_roi"] or 0)
    sim_days = float(row["sim_days"] or 0)
    deep = (
        (roi < -30 or (roi < -25 and (sim_days < 180 or sim_days > 360)))
        and want_a >= 3
    )
    early = (
        -10 < roi < 1
        and current_buy_signal == "L"
        and want_a >= outputs["A-T02分數"]
        and sim_days < 60
    )
    return deep or early


def same_day_decision_leverage(
    rows_by_sid: dict[str, list[dict[str, Any]]]
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    changes: dict[tuple[str, str, str, str, str], int] = Counter()
    validation = Counter()
    for all_rows in rows_by_sid.values():
        for index, row in enumerate(all_rows):
            if index == 0 or row["date"] < row["date_start"]:
                continue
            previous = all_rows[index - 1]
            actual_buy = buy_signal(row, previous, row["grade"])
            neutral_buy = buy_signal(row, previous, 0)
            validation["buy_rows"] += 1
            validation["buy_mismatch"] += int(actual_buy != (row["sim_rule"] or ""))
            if actual_buy != neutral_buy:
                changes[
                    (
                        "買入訊號",
                        row["stock_group"],
                        GRADE_NAMES[row["grade"]],
                        actual_buy or "無",
                        neutral_buy or "無",
                    )
                ] += 1

            inventory_before = (
                float(previous["qty_inventory"] or 0) > 0
                or float(row["qty_sell"] or 0) > 0
            )
            if not inventory_before:
                continue
            history = all_rows[:index]
            actual_sell = sell_signal(row, previous, history, row["grade"])
            neutral_sell = sell_signal(row, previous, history, 0)
            actual_action = (
                "賣出"
                if actual_sell
                else (
                    "加碼候選"
                    if add_candidate(row, previous, row["grade"], actual_buy)
                    else "續抱"
                )
            )
            neutral_action = (
                "賣出"
                if neutral_sell
                else (
                    "加碼候選"
                    if add_candidate(row, previous, 0, neutral_buy)
                    else "續抱"
                )
            )
            stored_action = (
                "賣出"
                if float(row["qty_sell"] or 0) > 0
                else ("加碼候選" if row["sim_rule_invest"] == "A" else "續抱")
            )
            validation["inventory_rows"] += 1
            validation["inventory_mismatch"] += int(actual_action != stored_action)
            if actual_action != neutral_action:
                changes[
                    (
                        "持有決策",
                        row["stock_group"],
                        GRADE_NAMES[row["grade"]],
                        actual_action,
                        neutral_action,
                    )
                ] += 1
    output = [
        {
            "決策層": key[0],
            "股群": key[1],
            "現行Grade": key[2],
            "現行決策": key[3],
            "若Grade為none": key[4],
            "同日差異次數": count,
        }
        for key, count in sorted(changes.items())
    ]
    return output, dict(validation)


def rule_leverage_rows(
    rows_by_sid: dict[str, list[dict[str, Any]]]
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    counters: dict[str, Counter[str]] = defaultdict(Counter)
    by_grade_counts: dict[str, Counter[int]] = defaultdict(Counter)
    analyzed_rows = 0
    for all_rows in rows_by_sid.values():
        for index, row in enumerate(all_rows):
            if index == 0 or row["date"] < row["date_start"]:
                continue
            previous = all_rows[index - 1]
            actual = grade_rule_outputs(row, previous, row["grade"])
            neutral = grade_rule_outputs(row, previous, 0)
            variants = {
                grade: grade_rule_outputs(row, previous, grade)
                for grade in GRADE_VALUES
            }
            inventory_before = (
                float(previous["qty_inventory"] or 0) > 0
                or float(row["qty_sell"] or 0) > 0
            )
            for rule, actual_value in actual.items():
                prefix = rule[0]
                if prefix == "L" and row["sim_rule"] == "H":
                    continue
                if prefix in ("S", "A") and not inventory_before:
                    continue
                if prefix == "A" and float(row["qty_sell"] or 0) > 0:
                    continue
                values = [variants[grade][rule] for grade in GRADE_VALUES]
                counters[rule]["eligible"] += 1
                counters[rule]["observed_nonzero"] += int(actual_value != 0)
                counters[rule]["grade_sensitive"] += int(len(set(values)) > 1)
                counters[rule]["actual_vs_none"] += int(actual_value != neutral[rule])
                if actual_value != neutral[rule]:
                    by_grade_counts[rule][row["grade"]] += 1
            analyzed_rows += 1
    output: list[dict[str, Any]] = []
    for rule in sorted(counters):
        item = counters[rule]
        output.append(
            {
                "規則代號": rule,
                "可評估列": item["eligible"],
                "現行輸出非零": item["observed_nonzero"],
                "理論上受Grade影響": item["grade_sensitive"],
                "現行Grade相對none不同": item["actual_vs_none"],
                "差異Grade分布": "、".join(
                    f"{GRADE_NAMES[grade]}:{count}"
                    for grade, count in sorted(
                        by_grade_counts[rule].items(), reverse=True
                    )
                ),
            }
        )
    return output, {"analyzedRows": analyzed_rows}


def decision_event_rows(
    rows_by_sid: dict[str, list[dict[str, Any]]]
) -> list[dict[str, Any]]:
    counts: dict[tuple[str, str, str], Counter[str]] = defaultdict(Counter)
    for sid, all_rows in rows_by_sid.items():
        active = [row for row in all_rows if row["date"] >= row["date_start"]]
        for row in active:
            key = (row["stock_group"], sid, GRADE_NAMES[row["grade"]])
            item = counts[key]
            item["交易日"] += 1
            item["H訊號"] += int(row["sim_rule"] == "H")
            item["L訊號"] += int(row["sim_rule"] == "L")
            initial_buy = (
                float(row["qty_buy"] or 0) > 0
                and float(row["invest_added"] or 0) == 0
            )
            item["H買成交"] += int(initial_buy and row["sim_rule_buy"] == "H")
            item["L買成交"] += int(initial_buy and row["sim_rule_buy"] == "L")
            item["賣出"] += int(float(row["qty_sell"] or 0) > 0)
            item["加碼候選"] += int(row["sim_rule_invest"] == "A")
            item["實際加碼"] += int(float(row["invest_added"] or 0) > 0)
    output: list[dict[str, Any]] = []
    for (group, sid, grade), item in sorted(counts.items()):
        name = next(
            row["name"] for row in rows_by_sid[sid] if row["sid"] == sid
        )
        output.append(
            {
                "股群": group,
                "代號": sid,
                "簡稱": name,
                "Grade": grade,
                **item,
            }
        )
    return output


def completed_round_rows(
    rows_by_sid: dict[str, list[dict[str, Any]]]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    rounds: list[dict[str, Any]] = []
    for sid, all_rows in rows_by_sid.items():
        entry: dict[str, Any] | None = None
        previous_inventory = 0.0
        for row in all_rows:
            if row["date"] < row["date_start"]:
                previous_inventory = float(row["qty_inventory"] or 0)
                continue
            current_inventory = float(row["qty_inventory"] or 0)
            initial_buy = (
                float(row["qty_buy"] or 0) > 0
                and previous_inventory <= 0
                and float(row["invest_added"] or 0) == 0
            )
            if initial_buy:
                entry = row
            if float(row["qty_sell"] or 0) > 0 and entry is not None:
                rounds.append(
                    {
                        "股群": row["stock_group"],
                        "代號": sid,
                        "簡稱": row["name"],
                        "買入日": entry["date"].strftime("%Y-%m-%d"),
                        "買入Grade": GRADE_NAMES[entry["grade"]],
                        "買入規則": entry["sim_rule_buy"],
                        "賣出日": row["date"].strftime("%Y-%m-%d"),
                        "賣出Grade": GRADE_NAMES[row["grade"]],
                        "輪次ROI%": round(float(row["sim_unit_roi"] or 0), 3),
                        "持有日數": round(float(row["sim_days"] or 0), 1),
                    }
                )
                entry = None
            previous_inventory = current_inventory

    grouped: dict[tuple[str, str, str], list[dict[str, Any]]] = defaultdict(list)
    for item in rounds:
        grouped[(item["股群"], item["買入規則"], item["買入Grade"])].append(item)
    summary: list[dict[str, Any]] = []
    for (group, buy_rule, grade), items in sorted(grouped.items()):
        summary.append(
            {
                "股群": group,
                "買入規則": buy_rule,
                "買入Grade": grade,
                "完成輪次": len(items),
                "平均輪次ROI%": round(mean(item["輪次ROI%"] for item in items), 3),
                "ROI中位數%": round(median(item["輪次ROI%"] for item in items), 3),
                "平均持有日數": round(mean(item["持有日數"] for item in items), 2),
            }
        )
    return rounds, summary


def fubon_rows(
    rows_by_sid: dict[str, list[dict[str, Any]]], episodes: list[Episode]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    rows = [
        row
        for row in rows_by_sid["8454"]
        if row["date"] >= row["date_start"]
    ]
    peak = -math.inf
    peak_date: datetime | None = None
    milestones: list[dict[str, Any]] = []
    reached: set[int] = set()
    for row in rows:
        price = float(row["price_close"] or 0)
        if price > peak:
            peak = price
            peak_date = row["date"]
        drawdown = 100 * (price - peak) / peak if peak > 0 else 0
        for threshold in (-20, -30, -40, -50, -60, -70):
            if drawdown <= threshold and threshold not in reached:
                reached.add(threshold)
                milestones.append(
                    {
                        "里程碑": f"自高點回落 {abs(threshold)}%",
                        "日期": row["date"].strftime("%Y-%m-%d"),
                        "此前高點日": peak_date.strftime("%Y-%m-%d")
                        if peak_date
                        else "",
                        "收盤價": round(price, 2),
                        "回落%": round(drawdown, 2),
                        "Grade": GRADE_NAMES[row["grade"]],
                        "實年報酬率": round(row["decision_roi"], 3),
                        "平均週期": round(row["decision_days"], 2),
                        "完成輪次": int(row["roll_rounds"] or 0),
                    }
                )
    timeline: list[dict[str, Any]] = []
    fubon_episodes = [episode for episode in episodes if episode.sid == "8454"]
    for episode in fubon_episodes:
        episode_rows = [
            row
            for row in rows
            if episode.start_date <= row["date"] <= episode.end_date
        ]
        timeline.append(
            {
                "開始日": episode.start_date.strftime("%Y-%m-%d"),
                "結束日": episode.end_date.strftime("%Y-%m-%d"),
                "Grade": GRADE_NAMES[episode.grade],
                "交易日數": episode.observations,
                "起始價": round(episode.start_price, 2),
                "結束價": round(episode.end_price, 2),
                "區段漲跌%": round(episode.price_change, 2),
                "起始實年報酬率": round(episode.start_roi, 3),
                "結束實年報酬率": round(episode.end_roi, 3),
                "起始平均週期": round(episode.start_days, 2),
                "結束平均週期": round(episode.end_days, 2),
                "H訊號": sum(row["sim_rule"] == "H" for row in episode_rows),
                "L訊號": sum(row["sim_rule"] == "L" for row in episode_rows),
                "賣出": sum(float(row["qty_sell"] or 0) > 0 for row in episode_rows),
                "實際加碼": sum(
                    float(row["invest_added"] or 0) > 0 for row in episode_rows
                ),
            }
        )
    return timeline, milestones


def html_table(rows: list[dict[str, Any]], limit: int | None = None) -> str:
    if not rows:
        return "<p>無資料</p>"
    shown = rows if limit is None else rows[:limit]
    headers = list(shown[0].keys())
    head = "".join(f"<th>{html.escape(str(value))}</th>" for value in headers)
    body = []
    for row in shown:
        body.append(
            "<tr>"
            + "".join(
                f"<td>{html.escape(str(row.get(header, '')))}</td>"
                for header in headers
            )
            + "</tr>"
        )
    return f"<table><thead><tr>{head}</tr></thead><tbody>{''.join(body)}</tbody></table>"


def validate_final_periods(
    rows_by_sid: dict[str, list[dict[str, Any]]],
    periods_path: Path | None,
) -> dict[str, Any] | None:
    if periods_path is None:
        return None
    with periods_path.open(encoding="utf-8-sig", newline="") as handle:
        expected = {row["代號"]: row for row in csv.DictReader(handle)}
    mismatches: list[str] = []
    for sid, item in expected.items():
        actual = rows_by_sid[sid][-1]
        matches = (
            abs(actual["roi"] - float(item["實年報酬率"])) < 0.0001
            and abs(actual["days"] - float(item["平均週期"])) < 0.011
            and int(actual["roll_rounds"] or 0) == int(item["交易輪次"])
            and GRADE_NAMES[actual["end_grade"]] == item["評等"]
        )
        if not matches:
            mismatches.append(sid)
    return {
        "stockCount": len(expected),
        "mismatchCount": len(mismatches),
        "mismatchStocks": mismatches,
    }


def build_report(
    output: Path,
    manifest: dict[str, Any],
    exposure: list[dict[str, Any]],
    transitions: list[dict[str, Any]],
    transition_summary: dict[str, Any],
    events: list[dict[str, Any]],
    leverage: list[dict[str, Any]],
    rounds_summary: list[dict[str, Any]],
    fubon_timeline: list[dict[str, Any]],
    fubon_milestones: list[dict[str, Any]],
    decision_leverage: list[dict[str, Any]],
) -> None:
    overall_exposure: list[dict[str, Any]] = []
    grade_totals: Counter[str] = Counter()
    for item in exposure:
        grade_totals[item["Grade"]] += int(item["交易日數"])
    total_days = sum(grade_totals.values())
    for grade in reversed([GRADE_NAMES[value] for value in GRADE_VALUES]):
        overall_exposure.append(
            {
                "Grade": grade,
                "交易日數": grade_totals[grade],
                "占比%": round(100 * grade_totals[grade] / total_days, 2),
            }
        )

    leverage_ranked = sorted(
        leverage,
        key=lambda item: (
            int(item["現行Grade相對none不同"]),
            int(item["理論上受Grade影響"]),
        ),
        reverse=True,
    )
    group_totals: Counter[str] = Counter()
    group_grades: dict[str, Counter[str]] = defaultdict(Counter)
    for item in exposure:
        days = int(item["交易日數"])
        group_totals[item["股群"]] += days
        group_grades[item["股群"]][item["Grade"]] += days
    decision_totals: Counter[str] = Counter()
    for item in decision_leverage:
        decision_totals[item["決策層"]] += int(item["同日差異次數"])
    fubon_weak = next(
        (item for item in reversed(fubon_timeline) if item["Grade"] == "weak"),
        None,
    )
    h_wow_share = (
        100 * group_grades["H"]["wow"] / group_totals["H"] if group_totals["H"] else 0
    )
    l_weak_share = (
        100 * group_grades["L"]["weak"] / group_totals["L"] if group_totals["L"] else 0
    )
    css = """
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 28px; color: #222; }
        h1, h2 { color: #18324a; }
        .note { background: #fff5d6; border-left: 4px solid #d49a00; padding: 12px; }
        table { border-collapse: collapse; width: 100%; margin: 12px 0 28px; font-size: 13px; }
        th, td { border: 1px solid #ccd5dd; padding: 6px 8px; text-align: right; }
        th { background: #edf3f7; position: sticky; top: 0; }
        th:nth-child(-n+4), td:nth-child(-n+4) { text-align: left; }
        code { background: #f2f4f5; padding: 2px 4px; }
    """
    document = f"""<!doctype html>
<html lang="zh-Hant"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>S6 Grade 機制稽核</title><style>{css}</style></head><body>
<h1>S6 Grade 機制稽核</h1>
<p>資料：<code>{html.escape(manifest['sourceRunID'])}</code>；
T2/S6；連續期間 {manifest['period']}；10 股。</p>
<div class="note"><strong>解讀限制：</strong>目前股票刻意選自極端 H／L 股群，
不能用本報告推論七級 Grade 對全市場的公平排序。本報告只檢查 Grade 的實際分布、
轉移、規則控制力及富邦媒個案；不修改策略或 Baseline。</div>
<h2>分析摘要</h2>
<ul>
<li><strong>Grade 確實形成級距，但本樣本高度偏斜：</strong>
H 股群有 {h_wow_share:.2f}% 交易日為 wow，L 股群有 {l_weak_share:.2f}% 為 weak；
damn 僅 2 日、low 僅 207 日，不能用來判斷七級是否都需要保留或應合併。</li>
<li><strong>Grade 不是裝飾欄位：</strong>若只在同一天把 Grade 改為 none，
買入訊號有 {decision_totals['買入訊號']} 列不同，持有／賣出／加碼決策有
{decision_totals['持有決策']} 列不同。但這只是局部敏感度，不等於完整重跑後的績效差。</li>
<li><strong>邊界有明顯跳動：</strong>{transition_summary['transitionCount']} 次轉級中，
{transition_summary['longJumpCount']} 次跨兩級以上，
{transition_summary['shortReversionCount']} 次在 20 個交易日內回到原級。
這值得在新樣本檢查，但目前不足以直接合併 Grade。</li>
<li><strong>富邦媒證實 Grade 是長記憶績效評等，不是即時趨勢：</strong>
股價自高點回落 70% 時仍為 wow；之後才逐步降級。
{('自 ' + fubon_weak['開始日'] + ' 起維持 weak，至 ' + fubon_weak['結束日'] + '。') if fubon_weak else ''}</li>
<li><strong>本輪結論：</strong>沒有發現應立即修改 Grade 分級或現行規則的證據；
下一步應用未參與選樣的新股票，做完整反事實 simUpdate，而不是由本樣本直接調整門檻。</li>
</ul>
<p>資料品質：買入與持有決策重建皆為
{manifest['decisionReconstructionValidation']['buy_mismatch']}／
{manifest['decisionReconstructionValidation']['inventory_mismatch']} 筆不一致；
期末資料與正式 periods.csv 有
{manifest['finalPeriodValidation']['mismatchCount'] if manifest.get('finalPeriodValidation') else '未執行'}
檔不一致。</p>
<h2>全樣本 Grade 暴露</h2>{html_table(overall_exposure)}
<h2>轉移概況</h2>
<p>共 {transition_summary['transitionCount']} 次轉級；
跨越兩級以上 {transition_summary['longJumpCount']} 次；
20 個交易日內回到原級 {transition_summary['shortReversionCount']} 次。</p>
<h2>Grade 對規則的控制力（依現行 Grade 相對 none 的差異排序）</h2>
{html_table(leverage_ranked)}
<h2>現行 Grade 相對 none 的同日決策差異</h2>
{html_table(decision_leverage)}
<h2>股群 × 買入規則 × 買入 Grade 的完成輪次</h2>
{html_table(rounds_summary)}
<h2>富邦媒 Grade 時間軸</h2>{html_table(fubon_timeline)}
<h2>富邦媒自歷史高點回落里程碑</h2>{html_table(fubon_milestones)}
<h2>逐股 Grade 暴露</h2>{html_table(exposure)}
<h2>轉移明細（前 100 筆）</h2>{html_table(transitions, 100)}
<h2>決策事件分布</h2>{html_table(events)}
</body></html>"""
    (output / "report.html").write_text(document, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--store", required=True, type=Path)
    parser.add_argument("--source-manifest", required=True, type=Path)
    parser.add_argument("--source-periods", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    source_manifest = json.loads(args.source_manifest.read_text(encoding="utf-8"))
    rows, stocks = (
        read_csv_rows(args.store)
        if args.store.suffix.lower() == ".csv"
        else read_rows(args.store)
    )
    through = datetime.strptime(source_manifest["through"], "%Y/%m/%d") - timedelta(hours=8)
    rows = [row for row in rows if row["date_time"] <= through]
    rows_by_sid = grouped_rows(rows)
    final_period_validation = validate_final_periods(rows_by_sid, args.source_periods)
    episodes = build_episodes(rows_by_sid)
    exposure = exposure_rows(rows_by_sid, episodes)
    transitions, transition_summary = transition_rows(episodes)
    leverage, leverage_summary = rule_leverage_rows(rows_by_sid)
    events = decision_event_rows(rows_by_sid)
    rounds, rounds_summary = completed_round_rows(rows_by_sid)
    fubon_timeline, fubon_milestones = fubon_rows(rows_by_sid, episodes)
    decision_leverage, decision_validation = same_day_decision_leverage(rows_by_sid)

    write_csv(
        args.output / "grade-exposure.csv",
        exposure,
        list(exposure[0].keys()),
    )
    write_csv(
        args.output / "grade-transitions.csv",
        transitions,
        list(transitions[0].keys()),
    )
    write_csv(
        args.output / "grade-rule-leverage.csv",
        leverage,
        list(leverage[0].keys()),
    )
    write_csv(
        args.output / "decision-events-by-grade.csv",
        events,
        list(events[0].keys()),
    )
    write_csv(
        args.output / "completed-rounds.csv",
        rounds,
        list(rounds[0].keys()),
    )
    write_csv(
        args.output / "round-outcomes-by-entry-grade.csv",
        rounds_summary,
        list(rounds_summary[0].keys()),
    )
    write_csv(
        args.output / "fubon-grade-timeline.csv",
        fubon_timeline,
        list(fubon_timeline[0].keys()),
    )
    write_csv(
        args.output / "fubon-drawdown-milestones.csv",
        fubon_milestones,
        list(fubon_milestones[0].keys()),
    )
    write_csv(
        args.output / "same-day-decision-leverage.csv",
        decision_leverage,
        list(decision_leverage[0].keys()),
    )

    audit_manifest = {
        "runID": "grade-mechanics-audit-s6-20260730",
        "createdAt": datetime.now().astimezone().isoformat(),
        "sourceRunID": source_manifest["runID"],
        "input": args.store.name,
        "sourceRuleCommit": source_manifest.get("ruleCommit"),
        "dataRuleVersion": source_manifest["dataRuleVersion"],
        "ruleVersion": source_manifest["ruleVersion"],
        "period": f"{source_manifest['periodStarts'][0]}–{source_manifest['through']}",
        "stockCount": len(stocks),
        "tradeCount": len(rows),
        "transitionSummary": transition_summary,
        "ruleLeverageSummary": leverage_summary,
        "decisionReconstructionValidation": decision_validation,
        "finalPeriodValidation": final_period_validation,
        "limitations": [
            "Stocks were deliberately selected from extreme H/L stock groups.",
            "Results describe Grade mechanics in the selected sample, not market-wide calibration.",
            "Same-day rule sensitivity is descriptive and does not replace a full counterfactual simUpdate.",
        ],
    }
    (args.output / "manifest.json").write_text(
        json.dumps(audit_manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    build_report(
        args.output,
        audit_manifest,
        exposure,
        transitions,
        transition_summary,
        events,
        leverage,
        rounds_summary,
        fubon_timeline,
        fubon_milestones,
        decision_leverage,
    )
    print(json.dumps(audit_manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
