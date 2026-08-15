#!/usr/bin/env python3
"""Build a disposable FT5 event-response diagnostic.

This tool does not change a trading rule or a DecisionBase.  It joins frozen
decision-time observations to later TWSE closes solely to generate a hypothesis
inside the discovery window.  Formal evidence still requires full simUpdate
replay after a candidate is frozen.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sqlite3
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from statistics import mean, median
from typing import Any, Iterable


APPLE_REFERENCE_UNIX_SECONDS = 978_307_200


def rounded(value: float | None, digits: int = 6) -> float | None:
    return None if value is None else round(value, digits)


def state_for(value: float, band: float) -> str:
    if value < -band:
        return "worsening"
    if value > band:
        return "improving"
    return "stable"


def finite(values: Iterable[float | None]) -> list[float]:
    return [value for value in values if value is not None and math.isfinite(value)]


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def integrity(connection: sqlite3.Connection, label: str) -> None:
    result = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if result != "ok":
        raise RuntimeError(f"{label} integrity_check failed: {result}")


def load_events(
    database: Path,
    window_start: int,
    window_end: int,
    band: float,
    minimum_count: int,
    rule_id: str,
) -> tuple[list[dict[str, Any]], dict[int, set[str]], dict[str, str]]:
    connection = sqlite3.connect(database)
    connection.row_factory = sqlite3.Row
    try:
        integrity(connection, "DecisionBase")
        metadata = dict(connection.execute("SELECT key, value FROM metadata"))
        rows = connection.execute(
            """
            SELECT l.event_id, l.stock_id, l.stock_name, l.group_name,
                   l.trade_date, l.decision_score, l.decision_threshold,
                   l.planned_action, l.executed_action,
                   f.fit_trend, f.fit_observation_count, f.has_inventory,
                   l.volume_z125, l.kd_k_z125, l.kd_k_z250
            FROM l_buy_boundary_observation_lookup l
            JOIN strategy_fit_event_lookup f USING(event_id)
            JOIN windows w ON w.window_id = l.window_id
            WHERE w.start_date = ? AND w.end_date = ?
              AND f.grade_name = 'wow'
              AND f.fit_observation_count >= ?
              AND f.is_valid = 1 AND f.is_finite = 1
              AND EXISTS (
                  SELECT 1 FROM event_votes v
                  JOIN rules r ON r.rule_key = v.rule_key
                  WHERE v.event_id = l.event_id AND r.rule_id = ?
              )
            ORDER BY l.stock_id, l.trade_date
            """,
            (window_start, window_end, minimum_count, rule_id),
        ).fetchall()
        event_ids = [row["event_id"] for row in rows]
        votes: dict[int, set[str]] = defaultdict(set)
        if event_ids:
            placeholders = ",".join("?" for _ in event_ids)
            for vote in connection.execute(
                f"""
                SELECT v.event_id, r.rule_id
                FROM event_votes v JOIN rules r USING(rule_key)
                WHERE v.event_id IN ({placeholders})
                """,
                event_ids,
            ):
                votes[vote["event_id"]].add(vote["rule_id"])
    finally:
        connection.close()

    events: list[dict[str, Any]] = []
    for row in rows:
        item = dict(row)
        item["state"] = state_for(item["fit_trend"], band)
        if item["state"] != "stable":
            events.append(item)
    return events, votes, metadata


def apple_timestamp_to_yyyymmdd(value: float) -> int:
    date = datetime.fromtimestamp(
        value + APPLE_REFERENCE_UNIX_SECONDS,
        timezone.utc,
    ).astimezone(timezone(timedelta(hours=8)))
    return date.year * 10_000 + date.month * 100 + date.day


def load_prices(store: Path, through: int) -> dict[str, list[tuple[int, float]]]:
    connection = sqlite3.connect(store)
    connection.row_factory = sqlite3.Row
    try:
        integrity(connection, "browse.store")
        rows = connection.execute(
            """
            SELECT s.ZSID AS stock_id, t.ZDATETIME AS timestamp,
                   t.ZPRICECLOSE AS close
            FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK = t.ZSTOCK
            WHERE t.ZDATASOURCE = 'TWSE'
              AND t.ZPRICECLOSE IS NOT NULL AND t.ZPRICECLOSE > 0
            ORDER BY s.ZSID, t.ZDATETIME
            """
        ).fetchall()
    finally:
        connection.close()

    prices: dict[str, list[tuple[int, float]]] = defaultdict(list)
    for row in rows:
        date = apple_timestamp_to_yyyymmdd(row["timestamp"])
        if date <= through:
            prices[row["stock_id"]].append((date, row["close"]))
    return prices


def add_responses(
    events: list[dict[str, Any]], prices: dict[str, list[tuple[int, float]]]
) -> list[dict[str, Any]]:
    indexed = {
        stock_id: ({date: index for index, (date, _) in enumerate(rows)}, rows)
        for stock_id, rows in prices.items()
    }
    output: list[dict[str, Any]] = []
    for event in events:
        stock = indexed.get(event["stock_id"])
        if stock is None or event["trade_date"] not in stock[0]:
            raise RuntimeError(
                f"missing TWSE close for {event['stock_id']} {event['trade_date']}"
            )
        date_index, rows = stock
        index = date_index[event["trade_date"]]
        current = rows[index][1]
        if index + 20 >= len(rows):
            continue
        future = [close for _, close in rows[index + 1 : index + 21]]
        item = dict(event)
        item["price_index"] = index
        item["forward_return_5"] = (rows[index + 5][1] / current - 1) * 100
        item["forward_return_20"] = (rows[index + 20][1] / current - 1) * 100
        item["max_drawdown_20"] = (min(future) / current - 1) * 100
        item["max_gain_20"] = (max(future) / current - 1) * 100
        output.append(item)
    return output


def non_overlapping(events: list[dict[str, Any]], horizon: int) -> list[dict[str, Any]]:
    kept: list[dict[str, Any]] = []
    last_index: dict[str, int] = {}
    for event in sorted(events, key=lambda row: (row["stock_id"], row["trade_date"])):
        key = event["stock_id"]
        previous = last_index.get(key)
        if previous is None or event["price_index"] - previous > horizon:
            kept.append(event)
            last_index[key] = event["price_index"]
    return kept


def state_summary(events: list[dict[str, Any]], state: str) -> dict[str, Any]:
    rows = [event for event in events if event["state"] == state]
    stock_counts = Counter(event["stock_id"] for event in rows)
    metrics = ("forward_return_5", "forward_return_20", "max_drawdown_20", "max_gain_20")
    summary: dict[str, Any] = {
        "events": len(rows),
        "stocks": len(stock_counts),
        "maxStockShare": rounded(max(stock_counts.values()) / len(rows)) if rows else None,
        "inventoryShare": rounded(mean(event["has_inventory"] for event in rows)) if rows else None,
    }
    for metric in metrics:
        values = finite(event[metric] for event in rows)
        summary[metric] = {
            "mean": rounded(mean(values)) if values else None,
            "median": rounded(median(values)) if values else None,
        }
    return summary


def per_stock_rows(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str, str], list[dict[str, Any]]] = defaultdict(list)
    for event in events:
        grouped[(event["state"], event["stock_id"], event["stock_name"])].append(event)
    output = []
    for (state, stock_id, stock_name), rows in sorted(grouped.items()):
        output.append(
            {
                "state": state,
                "stockID": stock_id,
                "stockName": stock_name,
                "events": len(rows),
                "medianReturn5": rounded(median(row["forward_return_5"] for row in rows)),
                "medianReturn20": rounded(median(row["forward_return_20"] for row in rows)),
                "medianMaxDrawdown20": rounded(median(row["max_drawdown_20"] for row in rows)),
                "medianMaxGain20": rounded(median(row["max_gain_20"] for row in rows)),
            }
        )
    return output


def equal_stock_summary(rows: list[dict[str, Any]], state: str) -> dict[str, float | None]:
    selected = [row for row in rows if row["state"] == state]
    return {
        "medianReturn5": rounded(median(row["medianReturn5"] for row in selected)) if selected else None,
        "medianReturn20": rounded(median(row["medianReturn20"] for row in selected)) if selected else None,
        "medianMaxDrawdown20": rounded(
            median(row["medianMaxDrawdown20"] for row in selected)
        ) if selected else None,
        "medianMaxGain20": rounded(median(row["medianMaxGain20"] for row in selected)) if selected else None,
    }


def paired_stock_differences(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_stock: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)
    for row in rows:
        by_stock[row["stockID"]][row["state"]] = row
    output = []
    for stock_id, states in sorted(by_stock.items()):
        if "improving" not in states or "worsening" not in states:
            continue
        improving = states["improving"]
        worsening = states["worsening"]
        output.append(
            {
                "stockID": stock_id,
                "stockName": improving["stockName"],
                "improvingEvents": improving["events"],
                "worseningEvents": worsening["events"],
                "return5Difference": rounded(improving["medianReturn5"] - worsening["medianReturn5"]),
                "return20Difference": rounded(improving["medianReturn20"] - worsening["medianReturn20"]),
                "maxDrawdown20Difference": rounded(
                    improving["medianMaxDrawdown20"] - worsening["medianMaxDrawdown20"]
                ),
                "maxGain20Difference": rounded(
                    improving["medianMaxGain20"] - worsening["medianMaxGain20"]
                ),
            }
        )
    return output


def overlap_rows(
    events: list[dict[str, Any]], votes: dict[int, set[str]], source_rule_id: str
) -> list[dict[str, Any]]:
    universe = {event["event_id"] for event in events}
    target = {
        event["event_id"] for event in events
        if event["state"] == "worsening"
    }
    rule_events: dict[str, set[int]] = defaultdict(set)
    for event_id in universe:
        for rule_id in votes[event_id]:
            if rule_id != source_rule_id:
                rule_events[rule_id].add(event_id)
    output = []
    for rule_id, other in rule_events.items():
        intersection = target & other
        union = target | other
        output.append(
            {
                "ruleID": rule_id,
                "targetEvents": len(target),
                "ruleEvents": len(other),
                "intersection": len(intersection),
                "targetCoveredByRule": rounded(len(intersection) / len(target)) if target else None,
                "ruleCoveredByTarget": rounded(len(intersection) / len(other)) if other else None,
                "jaccard": rounded(len(intersection) / len(union)) if union else None,
            }
        )
    return sorted(output, key=lambda row: (-row["jaccard"], row["ruleID"]))


def decision(summary: dict[str, Any]) -> tuple[str, list[str]]:
    raw_i = summary["raw"]["improving"]
    raw_w = summary["raw"]["worsening"]
    non_i = summary["nonOverlapping20"]["improving"]
    non_w = summary["nonOverlapping20"]["worsening"]
    paired = summary["pairedStocks"]
    reasons: list[str] = []
    if min(raw_i["events"], raw_w["events"]) < 30:
        reasons.append("raw event count below 30")
    if min(raw_i["stocks"], raw_w["stocks"]) < 5:
        reasons.append("stock count below 5")
    if max(raw_i["maxStockShare"], raw_w["maxStockShare"]) > 0.35:
        reasons.append("single-stock share above 35%")
    if min(non_i["events"], non_w["events"]) < 20:
        reasons.append("non-overlapping 20-day sensitivity below 20 events")
    raw_ordered = (
        raw_i["forward_return_20"]["median"] > raw_w["forward_return_20"]["median"]
        and raw_i["forward_return_5"]["median"] >= raw_w["forward_return_5"]["median"]
        and raw_i["max_drawdown_20"]["median"] >= raw_w["max_drawdown_20"]["median"]
    )
    non_ordered = (
        non_i["forward_return_20"]["median"] > non_w["forward_return_20"]["median"]
        and non_i["forward_return_5"]["median"] >= non_w["forward_return_5"]["median"]
        and non_i["max_drawdown_20"]["median"] >= non_w["max_drawdown_20"]["median"]
    )
    if not raw_ordered:
        reasons.append("raw 5/20-day return and drawdown are not ordered")
    if not non_ordered:
        reasons.append("non-overlapping sensitivity is not ordered")
    if paired["commonStocks"] < 5:
        reasons.append("fewer than 5 paired stocks")
    if paired["positiveReturn20Stocks"] <= paired["commonStocks"] / 2:
        reasons.append("paired stock majority does not support 20-day ordering")
    if any(
        row["jaccard"] >= 0.8 or row["targetCoveredByRule"] >= 0.9
        for row in summary["highOverlapSignals"]
    ):
        reasons.append("target has >=90% directional coverage by an existing rule")
    return (
        "proceedToCandidate"
        if not reasons
        else f"stop{summary['ruleID']}"
    ), reasons


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--price-store", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--window-start", type=int, default=20190102)
    parser.add_argument("--window-end", type=int, default=20220102)
    parser.add_argument("--minimum-count", type=int, default=125)
    parser.add_argument("--noise-band", type=float, default=0.611888)
    parser.add_argument("--rule-id", default="L-P06")
    parser.add_argument("--analysis-id", default="ft5-1-a-earliest-wow-lp06-fit-response-20260815")
    parser.add_argument("--label", default="L-P06 量縮")
    args = parser.parse_args()

    events, votes, metadata = load_events(
        args.database,
        args.window_start,
        args.window_end,
        args.noise_band,
        args.minimum_count,
        args.rule_id,
    )
    prices = load_prices(args.price_store, args.window_end)
    events = add_responses(events, prices)
    non_overlap = non_overlapping(events, 20)
    stock_rows = per_stock_rows(events)
    paired_rows = paired_stock_differences(stock_rows)
    overlaps = overlap_rows(events, votes, args.rule_id)

    paired_summary = {
        "commonStocks": len(paired_rows),
        "positiveReturn5Stocks": sum(row["return5Difference"] > 0 for row in paired_rows),
        "positiveReturn20Stocks": sum(row["return20Difference"] > 0 for row in paired_rows),
        "betterDrawdownStocks": sum(row["maxDrawdown20Difference"] > 0 for row in paired_rows),
        "medianReturn5Difference": rounded(median(row["return5Difference"] for row in paired_rows)) if paired_rows else None,
        "medianReturn20Difference": rounded(median(row["return20Difference"] for row in paired_rows)) if paired_rows else None,
        "medianMaxDrawdown20Difference": rounded(
            median(row["maxDrawdown20Difference"] for row in paired_rows)
        ) if paired_rows else None,
    }
    summary: dict[str, Any] = {
        "analysisID": args.analysis_id,
        "ruleID": args.rule_id,
        "sourceDecisionBase": metadata.get("decisionBaseID"),
        "sourcePriceStore": args.price_store.name,
        "dataRuleVersion": metadata.get("dataRuleVersion"),
        "ruleVersion": metadata.get("ruleVersion"),
        "ruleCommit": metadata.get("ruleCommit"),
        "window": {"start": args.window_start, "end": args.window_end},
        "scope": f"wow Grade, warmed fitTrend, L-buy wantL 4...6, {args.rule_id} vote present",
        "noiseBand": args.noise_band,
        "minimumObservationCount": args.minimum_count,
        "primaryProxy": "20th later TWSE close return",
        "secondaryProxies": ["5th later TWSE close return", "20-observation maximum drawdown", "20-observation maximum gain"],
        "raw": {
            state: state_summary(events, state)
            for state in ("improving", "worsening")
        },
        "nonOverlapping20": {
            state: state_summary(non_overlap, state)
            for state in ("improving", "worsening")
        },
        "equalStock": {
            state: equal_stock_summary(stock_rows, state)
            for state in ("improving", "worsening")
        },
        "pairedStocks": paired_summary,
        "maximumOverlap": overlaps[0] if overlaps else None,
        "highOverlapSignals": [
            row for row in overlaps
            if row["jaccard"] >= 0.8
            or row["targetCoveredByRule"] >= 0.9
            or row["ruleCoveredByTarget"] >= 0.9
        ],
        "guardrails": {
            "changesRule": False,
            "runsCandidateBacktest": False,
            "usesSampleB": False,
            "usesSampleC": False,
            "futurePriceIsDisposableHypothesisProxy": True,
        },
    }
    scope_decision, reasons = decision(summary)
    summary["scopeDecision"] = scope_decision
    summary["stopReasons"] = reasons

    args.output.mkdir(parents=True, exist_ok=True)
    event_rows = []
    for event in events:
        event_rows.append(
            {
                "eventID": event["event_id"],
                "stockID": event["stock_id"],
                "stockName": event["stock_name"],
                "tradeDate": event["trade_date"],
                "state": event["state"],
                "fitTrend": rounded(event["fit_trend"]),
                "fitObservationCount": event["fit_observation_count"],
                "hasInventory": event["has_inventory"],
                "wantL": event["decision_score"],
                "volumeZ125": rounded(event["volume_z125"]),
                "kdKZ125": rounded(event["kd_k_z125"]),
                "kdKZ250": rounded(event["kd_k_z250"]),
                "return5": rounded(event["forward_return_5"]),
                "return20": rounded(event["forward_return_20"]),
                "maxDrawdown20": rounded(event["max_drawdown_20"]),
                "maxGain20": rounded(event["max_gain_20"]),
            }
        )
    write_csv(args.output / "events.csv", event_rows)
    write_csv(args.output / "by-stock.csv", stock_rows)
    write_csv(args.output / "paired-stocks.csv", paired_rows)
    write_csv(args.output / "rule-overlap.csv", overlaps)
    (args.output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    raw_i = summary["raw"]["improving"]
    raw_w = summary["raw"]["worsening"]
    non_i = summary["nonOverlapping20"]["improving"]
    non_w = summary["nonOverlapping20"]["worsening"]
    report = f"""# {args.analysis_id} `wow × {args.label} × 適配趨勢`事件反應

## 結論

- 階段判定：`{scope_decision}`。
- 改善／惡化原始事件：{raw_i['events']}／{raw_w['events']}；股票：{raw_i['stocks']}／{raw_w['stocks']}；單股最高占比：{raw_i['maxStockShare']:.1%}／{raw_w['maxStockShare']:.1%}。
- 20 日報酬中位數：{raw_i['forward_return_20']['median']:.3f}%／{raw_w['forward_return_20']['median']:.3f}%；5 日：{raw_i['forward_return_5']['median']:.3f}%／{raw_w['forward_return_5']['median']:.3f}%。
- 20 日最大回撤中位數：{raw_i['max_drawdown_20']['median']:.3f}%／{raw_w['max_drawdown_20']['median']:.3f}%。
- 非重疊 20 日敏感度事件：{non_i['events']}／{non_w['events']}；20 日報酬中位數：{non_i['forward_return_20']['median']:.3f}%／{non_w['forward_return_20']['median']:.3f}%。
- 配對股票：{paired_summary['commonStocks']} 檔；20 日改善優於惡化者 {paired_summary['positiveReturn20Stocks']} 檔，中位差 {paired_summary['medianReturn20Difference']:.3f} 個百分點。

## 判讀邊界

這是 Sample A 最早窗口內的可丟棄假設代理，不是回測績效或因果證明。它只決定是否值得把單一候選送入 FT6；沒有修改正式規則、T2/S18、Baseline 或任何 Sample C 資料。

停止原因：{'; '.join(reasons) if reasons else '無；可提出一條固定候選供完整重播。'}
"""
    (args.output / "report.md").write_text(report, encoding="utf-8")


if __name__ == "__main__":
    main()
