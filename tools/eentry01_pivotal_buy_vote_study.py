#!/usr/bin/env python3
"""E-ENTRY01-D0-ABCDE: diagnose pivotal positive votes on formal new entries."""

from __future__ import annotations

import argparse
import csv
import json
import statistics
from collections import defaultdict
from pathlib import Path

from ecap03_long_negative_holding_study import (
    connect_readonly,
    fixed_data,
    hypothetical_realized_roi,
    read_json,
    round_score,
    split_cycles,
    write_csv,
)
from eprofit01_long_positive_holding_study import grade_score_band


STUDY_ID = "E-ENTRY01-D0-ABCDE"
EXPECTED_SAMPLES = {"A", "B", "C", "D", "E"}
EXPECTED_COMMON = {
    "dataRuleVersion": "T2/S38",
    "ruleVersion": "s31-st02h-efficiency-loss-cut-20260831",
    "ruleCommit": "e4e41e1f1dfecb2fd320d347023a2095366ee0ec",
    "through": "2026/07/22",
    "moneyBaseWan": 600,
    "automaticInvestments": 2,
}


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--decision-base",
        action="append",
        required=True,
        metavar="SAMPLE=DIR",
        help="Repeat once for each Sample A, B, C, D, and E.",
    )
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def decision_base_specs(values: list[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        if "=" not in value:
            raise ValueError(f"invalid --decision-base value: {value!r}")
        sample, raw_path = value.split("=", 1)
        sample = sample.upper()
        if sample not in EXPECTED_SAMPLES or sample in result:
            raise ValueError(f"invalid or duplicate sample: {sample!r}")
        result[sample] = Path(raw_path)
    if set(result) != EXPECTED_SAMPLES:
        raise ValueError(f"expected A/B/C/D/E, received {sorted(result)}")
    return result


def verify_identity(specs: dict[str, Path]) -> dict[str, dict]:
    identities: dict[str, dict] = {}
    for sample, directory in sorted(specs.items()):
        manifest = read_json(directory / "manifest.json")
        decision_base_id = manifest["decisionBaseID"]
        complete = (directory / ".complete").read_text(encoding="utf-8").strip()
        p4b_complete = (directory / ".p4b-complete").read_text(
            encoding="utf-8"
        ).strip()
        if complete != decision_base_id or p4b_complete != decision_base_id:
            raise ValueError(f"{sample} completion marker mismatch")
        if manifest.get("sampleID") != sample:
            raise ValueError(f"{sample} manifest sample mismatch")
        for key, expected in EXPECTED_COMMON.items():
            if manifest.get(key) != expected:
                raise ValueError(
                    f"{sample} manifest mismatch {key}: {manifest.get(key)!r}"
                )
        database_path = directory / "decisions.sqlite"
        connection = connect_readonly(database_path)
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        window_count = connection.execute("SELECT COUNT(*) FROM windows").fetchone()[0]
        stock_count = connection.execute("SELECT COUNT(*) FROM stocks").fetchone()[0]
        connection.close()
        if integrity != "ok" or window_count != 3 or stock_count != 10:
            raise ValueError(
                f"{sample} DecisionBase integrity/coverage mismatch: "
                f"integrity={integrity}, windows={window_count}, stocks={stock_count}"
            )
        identities[sample] = {
            "decisionBaseID": decision_base_id,
            "database": str(database_path),
            "windows": window_count,
            "stocks": stock_count,
        }
    return identities


def median(rows: list[dict], key: str) -> float | None:
    values = [float(row[key]) for row in rows if row.get(key) is not None]
    return statistics.median(values) if values else None


def rate(rows: list[dict], key: str) -> float | None:
    values = [float(row[key]) for row in rows if row.get(key) is not None]
    return sum(values) / len(values) if values else None


def buy_events(path: Path) -> tuple[list[dict], dict[int, list[tuple[str, float]]]]:
    connection = connect_readonly(path)
    events: list[dict] = []
    for row in connection.execute(
        """
        SELECT b.*,w.start_date,w.end_date,
               g.decision_score grade_efficiency_score
        FROM decision_event_lookup b
        JOIN windows w USING(window_id)
        LEFT JOIN decision_events g ON g.window_id=b.window_id
            AND g.stock_key=b.stock_key AND g.trade_date=b.trade_date AND g.phase=0
        WHERE b.phase IN (1,2) AND b.executed_action='BUY'
            AND b.inventory_before<=0 AND b.planned_action IN ('H','L')
        ORDER BY b.window_id,b.stock_key,b.trade_date,b.event_id
        """
    ):
        value = dict(row)
        if value["grade_efficiency_score"] is None:
            raise ValueError(f"buy event lacks same-day Grade score: {value}")
        value["path_key"] = (int(row["window_id"]), int(row["stock_key"]))
        events.append(value)
    votes: dict[int, list[tuple[str, float]]] = defaultdict(list)
    for row in connection.execute(
        """
        SELECT v.event_id,v.rule_id,v.contribution
        FROM event_vote_lookup v
        JOIN decision_events e USING(event_id)
        WHERE e.phase IN (1,2) AND e.executed_action='BUY'
            AND e.inventory_before<=0 AND e.planned_action IN ('H','L')
        ORDER BY v.event_id,v.rule_id
        """
    ):
        votes[int(row["event_id"])].append(
            (str(row["rule_id"]), float(row["contribution"]))
        )
    connection.close()
    return events, votes


def entry_rows(sample: str, path: Path) -> tuple[list[dict], list[dict]]:
    held_rows, _, _ = fixed_data(path)
    cycles = split_cycles(held_rows, "inventory", "sold")
    buys, vote_map = buy_events(path)
    grouped_buys: dict[tuple, list[dict]] = defaultdict(list)
    grouped_cycles: dict[tuple, list[list[dict]]] = defaultdict(list)
    for buy in buys:
        grouped_buys[buy["path_key"]].append(buy)
    for path_key, _, cycle in cycles:
        grouped_cycles[path_key].append(cycle)

    outputs: list[dict] = []
    exclusions: list[dict] = []
    for path_key in sorted(set(grouped_buys) | set(grouped_cycles)):
        path_buys = grouped_buys[path_key]
        path_cycles = grouped_cycles[path_key]
        if len(path_cycles) > len(path_buys):
            raise ValueError(
                f"{sample} has more holding cycles than new entries at {path_key}: "
                f"{len(path_cycles)} versus {len(path_buys)}"
            )
        for index, buy in enumerate(path_buys):
            if index >= len(path_cycles):
                exclusions.append(
                    {
                        "sample": sample,
                        "window_id": buy["window_id"],
                        "stock_id": buy["stock_id"],
                        "stock_name": buy["stock_name"],
                        "buy_date": buy["trade_date"],
                        "buy_type": buy["planned_action"],
                        "reason": "no_subsequent_held_row_before_window_end",
                    }
                )
                continue
            cycle = path_cycles[index]
            first = cycle[0]
            final = cycle[-1]
            if int(first["trade_date"]) < int(buy["trade_date"]):
                raise ValueError(
                    f"{sample} cycle precedes entry at {path_key}: "
                    f"{first['trade_date']} versus {buy['trade_date']}"
                )
            if index + 1 < len(path_buys) and int(first["trade_date"]) >= int(
                path_buys[index + 1]["trade_date"]
            ):
                raise ValueError(f"{sample} entry-cycle ordering mismatch at {path_key}")
            outcome_roi = hypothetical_realized_roi(
                float(final["unit_cost_before"]),
                float(final["unit_roi_before"]),
                float(final["inventory_before"]),
            )
            holding_days = float(final["holding_days_before"])
            outcome_score = round_score(outcome_roi, holding_days)
            decision_score = float(buy["decision_score"])
            threshold = float(buy["decision_threshold"])
            positive_votes = [
                (rule, contribution)
                for rule, contribution in vote_map[int(buy["event_id"])]
                if contribution > 0
            ]
            pivotal = [
                rule
                for rule, contribution in positive_votes
                if decision_score - contribution < threshold - 1e-9
            ]
            grade_score = float(buy["grade_efficiency_score"])
            outputs.append(
                {
                    "sample": sample,
                    "window_id": int(buy["window_id"]),
                    "window_start": int(buy["start_date"]),
                    "window_end": int(buy["end_date"]),
                    "stock_id": str(buy["stock_id"]),
                    "stock_name": str(buy["stock_name"]),
                    "group_name": str(buy["group_name"]),
                    "buy_date": int(buy["trade_date"]),
                    "buy_type": str(buy["planned_action"]),
                    "buy_grade": str(buy["grade_name"]),
                    "buy_grade_score": grade_score,
                    "buy_grade_score_band": grade_score_band(grade_score),
                    "buy_decision_score": decision_score,
                    "buy_threshold": threshold,
                    "buy_decision_margin": decision_score - threshold,
                    "positive_vote_count": len(positive_votes),
                    "pivotal_vote_count": len(pivotal),
                    "pivotal_rules": "|".join(sorted(pivotal)),
                    "outcome_date": int(final["trade_date"]),
                    "actual_exit": int(bool(final["sold"])),
                    "holding_days": holding_days,
                    "outcome_roi": outcome_roi,
                    "outcome_score": outcome_score,
                    "negative_outcome_score": int(outcome_score < 0),
                }
            )
    return outputs, exclusions


def buy_type_summary(rows: list[dict]) -> list[dict]:
    grouped: dict[tuple, list[dict]] = defaultdict(list)
    for row in rows:
        grouped[(row["sample"], row["buy_type"])].append(row)
    output = []
    for (sample, buy_type), items in sorted(grouped.items()):
        output.append(
            {
                "sample": sample,
                "buy_type": buy_type,
                "entries": len(items),
                "stocks": len({row["stock_id"] for row in items}),
                "windows": len({row["window_id"] for row in items}),
                "median_outcome_roi": median(items, "outcome_roi"),
                "median_holding_days": median(items, "holding_days"),
                "median_outcome_score": median(items, "outcome_score"),
                "negative_score_rate": rate(items, "negative_outcome_score"),
                "entries_with_pivotal_vote": sum(
                    row["pivotal_vote_count"] > 0 for row in items
                ),
            }
        )
    return output


def expanded_pivotal_rows(rows: list[dict]) -> list[dict]:
    output = []
    for row in rows:
        for rule_id in str(row["pivotal_rules"]).split("|"):
            if rule_id:
                value = dict(row)
                value["rule_id"] = rule_id
                output.append(value)
    return output


def matched_summaries(rows: list[dict]) -> tuple[list[dict], list[dict]]:
    expanded = expanded_pivotal_rows(rows)
    pivotal_groups: dict[tuple, list[dict]] = defaultdict(list)
    for row in expanded:
        pivotal_groups[
            (
                row["rule_id"],
                row["buy_grade"],
                row["buy_grade_score_band"],
                row["sample"],
                row["buy_type"],
            )
        ].append(row)
    reference_groups: dict[tuple, list[dict]] = defaultdict(list)
    for row in rows:
        reference_groups[
            (
                row["buy_grade_score_band"],
                row["buy_grade"],
                row["sample"],
                row["buy_type"],
                row["buy_decision_margin"],
            )
        ].append(row)

    matched = []
    for (rule, grade, band, sample, buy_type), pivotal in sorted(pivotal_groups.items()):
        # A pivotal vote can only occur at a marginal decision. Comparing it
        # with higher-score entries would confound the vote with total signal
        # strength, so the reference keeps the exact score-minus-threshold
        # margin as well as Sample, buy type, and Grade score band.
        margins = {row["buy_decision_margin"] for row in pivotal}
        if len(margins) != 1:
            raise ValueError(f"mixed pivotal margins for {rule}/{band}/{sample}")
        margin = next(iter(margins))
        reference = [
            row
            for row in reference_groups[(band, grade, sample, buy_type, margin)]
            if rule not in str(row["pivotal_rules"]).split("|")
        ]
        pivotal_score = median(pivotal, "outcome_score")
        reference_score = median(reference, "outcome_score")
        pivotal_negative = rate(pivotal, "negative_outcome_score")
        reference_negative = rate(reference, "negative_outcome_score")
        matched.append(
            {
                "rule_id": rule,
                "grade": grade,
                "grade_score_band": band,
                "sample": sample,
                "buy_type": buy_type,
                "decision_margin": margin,
                "pivotal_entries": len(pivotal),
                "reference_entries": len(reference),
                "stocks": len({row["stock_id"] for row in pivotal}),
                "windows": len({row["window_id"] for row in pivotal}),
                "pivotal_median_score": pivotal_score,
                "reference_median_score": reference_score,
                "median_score_delta": (
                    pivotal_score - reference_score
                    if pivotal_score is not None and reference_score is not None
                    else None
                ),
                "pivotal_negative_rate": pivotal_negative,
                "reference_negative_rate": reference_negative,
                "negative_rate_delta": (
                    pivotal_negative - reference_negative
                    if pivotal_negative is not None and reference_negative is not None
                    else None
                ),
            }
        )

    aggregate_groups: dict[tuple, list[dict]] = defaultdict(list)
    for row in expanded:
        aggregate_groups[
            (
                row["rule_id"],
                row["buy_grade"],
                row["buy_grade_score_band"],
                row["buy_type"],
            )
        ].append(row)
    aggregate = []
    for (rule, grade, band, buy_type), pivotal in sorted(aggregate_groups.items()):
        comparisons = [
            row
            for row in matched
            if row["rule_id"] == rule
            and row["grade"] == grade
            and row["grade_score_band"] == band
            and row["buy_type"] == buy_type
            and row["reference_entries"] > 0
        ]
        adverse = [
            row
            for row in comparisons
            if row["median_score_delta"] is not None
            and row["negative_rate_delta"] is not None
            and row["median_score_delta"] < 0
            and row["negative_rate_delta"] > 0
        ]
        favorable = [
            row
            for row in comparisons
            if row["median_score_delta"] is not None
            and row["negative_rate_delta"] is not None
            and row["median_score_delta"] > 0
            and row["negative_rate_delta"] < 0
        ]
        aggregate.append(
            {
                "rule_id": rule,
                "grade": grade,
                "grade_score_band": band,
                "buy_type": buy_type,
                "pivotal_entries": len(pivotal),
                "samples": len({row["sample"] for row in pivotal}),
                "stocks": len({(row["sample"], row["stock_id"]) for row in pivotal}),
                "windows": len({(row["sample"], row["window_id"]) for row in pivotal}),
                "median_outcome_score": median(pivotal, "outcome_score"),
                "negative_score_rate": rate(pivotal, "negative_outcome_score"),
                "matched_samples": len(comparisons),
                "adverse_samples": len(adverse),
                "favorable_samples": len(favorable),
                "mixed_or_neutral_samples": len(comparisons) - len(adverse) - len(favorable),
                "diagnostic_signal": int(
                    len(pivotal) >= 3
                    and len({row["sample"] for row in pivotal}) >= 2
                    and len({(row["sample"], row["stock_id"]) for row in pivotal}) >= 2
                    and len({(row["sample"], row["window_id"]) for row in pivotal}) >= 2
                    and len(adverse) >= 2
                    and len(adverse) > len(favorable)
                ),
                "sparse_negative_signal": int(
                    len(pivotal) >= 2
                    and len({row["sample"] for row in pivotal}) >= 2
                    and len({(row["sample"], row["stock_id"]) for row in pivotal}) >= 2
                    and len({(row["sample"], row["window_id"]) for row in pivotal}) >= 2
                    and median(pivotal, "outcome_score") is not None
                    and median(pivotal, "outcome_score") < 0
                    and rate(pivotal, "negative_outcome_score") == 1.0
                    and len(adverse) >= 2
                    and len(favorable) == 0
                ),
            }
        )
    return matched, aggregate


def rule_summary(rows: list[dict]) -> list[dict]:
    expanded = expanded_pivotal_rows(rows)
    grouped: dict[tuple, list[dict]] = defaultdict(list)
    for row in expanded:
        grouped[(row["rule_id"], row["buy_type"])].append(row)
    output = []
    for (rule, buy_type), items in sorted(grouped.items()):
        output.append(
            {
                "rule_id": rule,
                "buy_type": buy_type,
                "pivotal_entries": len(items),
                "samples": len({row["sample"] for row in items}),
                "stocks": len({(row["sample"], row["stock_id"]) for row in items}),
                "windows": len({(row["sample"], row["window_id"]) for row in items}),
                "median_outcome_roi": median(items, "outcome_roi"),
                "median_holding_days": median(items, "holding_days"),
                "median_outcome_score": median(items, "outcome_score"),
                "negative_score_rate": rate(items, "negative_outcome_score"),
            }
        )
    return output


def fmt(value: object, digits: int = 3) -> str:
    if value is None:
        return "—"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def render_report(
    summary: dict,
    buy_summary: list[dict],
    signals: list[dict],
    sparse_signals: list[dict],
) -> str:
    lines = [
        f"# {STUDY_ID}",
        "",
        "只讀 Baseline v19 A～E DecisionBase v6；正式新持股限定為 H買／L買且買入前庫存為 0。",
        "只有移除單張正向票就會使決策分數跌破當日正式門檻，才標為關鍵票。結果使用該輪正式結案；窗口末仍持股者按期末價格假設結算。",
        "",
        "## 完整性",
        "",
        f"- 可配對正式新持股輪：{summary['pairedEntries']}",
        f"- 因窗口末買入後沒有下一筆持股列而排除：{summary['excludedEntries']}",
        f"- 含至少一張關鍵正向票：{summary['entriesWithPivotalVote']}",
        f"- 沒有任何單張移除即跌破門檻（總分高於邊界）：{summary['entriesWithoutPivotalVote']}",
        "",
        "## H買／L買結果",
        "",
        "| Sample | 買入型態 | 輪數 | 中位 ROI | 中位期間 | 中位效率分數 | 負分率 | 有關鍵票 |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in buy_summary:
        lines.append(
            f"| {row['sample']} | {row['buy_type']}買 | {row['entries']} | "
            f"{fmt(row['median_outcome_roi'])}% | {fmt(row['median_holding_days'], 1)} | "
            f"{fmt(row['median_outcome_score'])} | {fmt(100 * row['negative_score_rate'], 1)}% | "
            f"{row['entries_with_pivotal_vote']} |"
        )
    lines.extend(
        [
            "",
            "## Grade 連續分數區間診斷訊號",
            "",
            "訊號只表示關聯：同買入型態、同 Sample、同正式 Grade、同 Grade 分數區間且同為剛好跨線的決策內，關鍵票組至少兩個樣本同時呈現較低中位效率分數及較高負分率；仍須完整候選重播才能證明拿掉該票有效。",
            "",
        ]
    )
    if signals:
        lines.extend(
            [
                "| 規則代號 | 買入型態 | Grade | Grade 分數區間 | 關鍵輪數 | 樣本 | 股票 | 窗口 | 不利／有利樣本 | 中位效率分數 | 負分率 |",
                "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
            ]
        )
        for row in signals:
            lines.append(
                f"| {row['rule_id']} | {row['buy_type']}買 | {row['grade']} | {row['grade_score_band']} | "
                f"{row['pivotal_entries']} | {row['samples']} | {row['stocks']} | {row['windows']} | "
                f"{row['adverse_samples']}／{row['favorable_samples']} | "
                f"{fmt(row['median_outcome_score'])} | {fmt(100 * row['negative_score_rate'], 1)}% |"
            )
    else:
        lines.append("沒有符合預先限定覆蓋與跨樣本方向條件的 Grade 分數區間訊號。")
    lines.extend(["", "## 少量但跨樣本的負分線索", ""])
    if sparse_signals:
        lines.extend(
            [
                "下列線索未達三輪的一般診斷覆蓋門檻，但已跨兩個樣本、股票與窗口，且全部為負分；只適合提出一個受限候選，不視為採用證據。",
                "",
                "| 規則代號 | 買入型態 | Grade | Grade 分數區間 | 關鍵輪數 | 樣本 | 中位效率分數 | 負分率 |",
                "| --- | --- | --- | --- | ---: | ---: | ---: | ---: |",
            ]
        )
        for row in sparse_signals:
            lines.append(
                f"| {row['rule_id']} | {row['buy_type']}買 | {row['grade']} | "
                f"{row['grade_score_band']} | {row['pivotal_entries']} | {row['samples']} | "
                f"{fmt(row['median_outcome_score'])} | {fmt(100 * row['negative_score_rate'], 1)}% |"
            )
    else:
        lines.append("沒有跨樣本且全部為負分的少量線索。")
    lines.extend(
        [
            "",
            "## 界線",
            "",
            "- 這是既有正式路徑的關鍵票歸因，不等於移除規則後的反事實路徑；候選可能延後到其他日期買入。",
            "- 同一輪可能有多張各自關鍵的正向票，因此規則輪數可以重疊，不可相加成總輪數。",
            "- Grade 分數只使用既定正式級距，另保留已討論的 wow 內 100／200 分界；未做門檻網格。",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    args = arguments()
    specs = decision_base_specs(args.decision_base)
    identities = verify_identity(specs)
    rows: list[dict] = []
    exclusions: list[dict] = []
    for sample in sorted(EXPECTED_SAMPLES):
        sample_rows, sample_exclusions = entry_rows(
            sample, Path(identities[sample]["database"])
        )
        rows.extend(sample_rows)
        exclusions.extend(sample_exclusions)
    buy_summary = buy_type_summary(rows)
    rules = rule_summary(rows)
    matched, grade_summaries = matched_summaries(rows)
    signals = [row for row in grade_summaries if row["diagnostic_signal"]]
    sparse_signals = [
        row for row in grade_summaries if row["sparse_negative_signal"]
    ]
    summary = {
        "studyID": STUDY_ID,
        "pairedEntries": len(rows),
        "excludedEntries": len(exclusions),
        "entriesWithPivotalVote": sum(row["pivotal_vote_count"] > 0 for row in rows),
        "entriesWithoutPivotalVote": sum(row["pivotal_vote_count"] == 0 for row in rows),
        "pivotalRuleGradeGroups": len(grade_summaries),
        "diagnosticSignals": len(signals),
        "sparseNegativeSignals": len(sparse_signals),
        "identities": identities,
    }
    args.output.mkdir(parents=True, exist_ok=False)
    write_csv(args.output / "entries.csv", rows)
    write_csv(args.output / "excluded-entries.csv", exclusions)
    write_csv(args.output / "buy-type-summary.csv", buy_summary)
    write_csv(args.output / "pivotal-rule-summary.csv", rules)
    write_csv(args.output / "matched-sample-comparisons.csv", matched)
    write_csv(args.output / "pivotal-rule-grade-summary.csv", grade_summaries)
    write_csv(args.output / "diagnostic-signals.csv", signals)
    write_csv(args.output / "sparse-negative-signals.csv", sparse_signals)
    (args.output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    manifest = {
        "studyID": STUDY_ID,
        "dataRuleVersion": EXPECTED_COMMON["dataRuleVersion"],
        "ruleVersion": EXPECTED_COMMON["ruleVersion"],
        "ruleCommit": EXPECTED_COMMON["ruleCommit"],
        "through": EXPECTED_COMMON["through"],
        "samples": sorted(EXPECTED_SAMPLES),
        "decisionBases": {
            sample: identities[sample]["decisionBaseID"]
            for sample in sorted(EXPECTED_SAMPLES)
        },
        "method": {
            "newEntry": "phase 1 or 2 BUY, inventory_before <= 0, planned H or L",
            "pivotalVote": "positive contribution and decision_score - contribution < decision_threshold",
            "matchedReference": "same Sample, buy type, formal Grade, Grade score band, and exact decision score minus threshold margin",
            "outcome": "formal exit or hypothetical liquidation at final held row before window end",
            "gradeBands": "formal S31 boundaries plus 100 and 200 subdivisions within wow",
        },
        "artifacts": [
            "entries.csv",
            "excluded-entries.csv",
            "buy-type-summary.csv",
            "pivotal-rule-summary.csv",
            "matched-sample-comparisons.csv",
            "pivotal-rule-grade-summary.csv",
            "diagnostic-signals.csv",
            "sparse-negative-signals.csv",
            "summary.json",
            "report.md",
        ],
    }
    (args.output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (args.output / "report.md").write_text(
        render_report(summary, buy_summary, signals, sparse_signals), encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
