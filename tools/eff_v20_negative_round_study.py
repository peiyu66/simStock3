#!/usr/bin/env python3
"""EFF-V20-D0-DE: matched diagnosis of negative-efficiency holding rounds."""

from __future__ import annotations

import argparse
import csv
import json
import sqlite3
import statistics
from collections import Counter, defaultdict
from pathlib import Path

from ecap03_long_negative_holding_study import hypothetical_realized_roi, round_score
from eprofit01_long_positive_holding_study import grade_score_band


STUDY_ID = "EFF-V20-D0-DE"
EXPECTED = {
    "dataRuleVersion": "T2/S39",
    "ruleVersion": "s32-an03-wow-nonbottom-no-ap02-add-penalty-20260901",
    "ruleCommit": "48d42e50ada5dcc0ed2e22dffff6871323daf8b7",
    "through": "2026/07/22",
    "moneyBaseWan": 600,
    "automaticInvestments": 2,
}
PHASE_NAMES = {
    0: "unavailable",
    1: "neutral",
    2: "improving-warning",
    3: "worsening-warning",
    4: "improving-confirmed-legacy",
    5: "worsening-confirmed-legacy",
    6: "improving-cooldown",
    7: "worsening-cooldown",
    8: "improving-seeking-peak",
    9: "improving-pulling-back",
    10: "worsening-seeking-bottom",
    11: "worsening-rebounding",
}


def phase_family(raw: int) -> str:
    if raw in (2,):
        return "improving-warning"
    if raw in (3,):
        return "worsening-warning"
    if raw in (4, 8, 9):
        return "improving-confirmed"
    if raw in (5, 10, 11):
        return "worsening-confirmed"
    return "stable-or-unavailable"


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--decision-base", action="append", required=True, metavar="SAMPLE=DIR")
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def specs(values: list[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        sample, separator, raw_path = value.partition("=")
        sample = sample.upper()
        if not separator or sample not in {"D", "E"} or sample in result:
            raise ValueError(f"invalid --decision-base: {value!r}")
        result[sample] = Path(raw_path)
    if set(result) != {"D", "E"}:
        raise ValueError(f"expected D and E, received {sorted(result)}")
    return result


def connect(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def verify(inputs: dict[str, Path]) -> dict[str, dict]:
    identities: dict[str, dict] = {}
    for sample, directory in sorted(inputs.items()):
        manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
        decision_base_id = manifest["decisionBaseID"]
        if manifest.get("sampleID") != sample:
            raise ValueError(f"{sample} sample mismatch")
        for key, expected in EXPECTED.items():
            if manifest.get(key) != expected:
                raise ValueError(f"{sample} {key} mismatch: {manifest.get(key)!r}")
        for marker in (".complete", ".p4b-complete"):
            if (directory / marker).read_text(encoding="utf-8").strip() != decision_base_id:
                raise ValueError(f"{sample} {marker} mismatch")
        database = directory / "decisions.sqlite"
        connection = connect(database)
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        windows = connection.execute("SELECT COUNT(*) FROM windows").fetchone()[0]
        stocks = connection.execute("SELECT COUNT(*) FROM stocks").fetchone()[0]
        unsafe = connection.execute(
            "SELECT COUNT(*) FROM period_outcomes WHERE COALESCE(money_lacked,0) != 0"
        ).fetchone()[0]
        connection.close()
        if integrity != "ok" or windows != 3 or stocks != 10 or unsafe != 0:
            raise ValueError(
                f"{sample} coverage failure: integrity={integrity}, windows={windows}, "
                f"stocks={stocks}, money_lacked={unsafe}"
            )
        identities[sample] = {
            "decisionBaseID": decision_base_id,
            "database": str(database),
            "windows": windows,
            "stocks": stocks,
            "integrity": integrity,
        }
    return identities


def margin_band(value: float) -> str:
    if value < 0.5:
        return "0"
    if value < 1.5:
        return "1"
    return "2+"


def event_rows(connection: sqlite3.Connection) -> list[dict]:
    rows = []
    for raw in connection.execute(
        """
        SELECT e.*,w.start_date,w.end_date,s.stock_id,s.name stock_name,s.group_name,
               sf.fit_trend_phase,sf.fit_observation_count
        FROM decision_events e
        JOIN windows w USING(window_id)
        JOIN stocks s USING(stock_key)
        LEFT JOIN event_strategy_fit_observations esf USING(event_id)
        LEFT JOIN strategy_fit_observations sf USING(observation_id)
        WHERE e.phase IN (1,2,3,4)
        ORDER BY e.window_id,e.stock_key,e.trade_date,e.phase
        """
    ):
        rows.append(dict(raw))
    return rows


def grade_scores(connection: sqlite3.Connection) -> dict[tuple[int, int, int], float]:
    return {
        (int(row["window_id"]), int(row["stock_key"]), int(row["trade_date"])):
            float(row["decision_score"])
        for row in connection.execute(
            "SELECT window_id,stock_key,trade_date,decision_score FROM decision_events WHERE phase=0"
        )
    }


def gates(connection: sqlite3.Connection) -> dict[int, list[str]]:
    output: dict[int, list[str]] = defaultdict(list)
    for row in connection.execute(
        "SELECT event_id,rule_id FROM event_gate_lookup ORDER BY event_id,rule_id"
    ):
        output[int(row["event_id"])].append(str(row["rule_id"]))
    return output


def cycle_result(sample: str, buy: dict, final: dict, adds: list[dict], gate_map: dict[int, list[str]], score_map: dict[tuple[int, int, int], float]) -> dict:
    grade_score = score_map[(int(buy["window_id"]), int(buy["stock_key"]), int(buy["trade_date"]))]
    outcome_roi = hypothetical_realized_roi(
        float(final["unit_cost_before"]),
        float(final["unit_roi_before"]),
        float(final["inventory_before"]),
    )
    days = float(final["holding_days_before"])
    score = round_score(outcome_roi, days)
    raw_phase = int(buy["fit_trend_phase"] or 0)
    threshold = float(buy["decision_threshold"])
    margin = float(buy["decision_score"]) - threshold
    exit_gates = [gate for gate in gate_map[int(final["event_id"])] if gate.startswith("S-T")]
    return {
        "sample": sample,
        "window_id": int(buy["window_id"]),
        "window_start": int(buy["start_date"]),
        "window_end": int(buy["end_date"]),
        "stock_id": str(buy["stock_id"]),
        "stock_name": str(buy["stock_name"]),
        "group_name": str(buy["group_name"]),
        "buy_date": int(buy["trade_date"]),
        "buy_type": str(buy["planned_action"]),
        "buy_grade": PHASE_GRADE_NAMES[int(buy["grade"])],
        "buy_grade_score": grade_score,
        "buy_grade_score_band": grade_score_band(grade_score),
        "buy_trend_phase": PHASE_NAMES.get(raw_phase, f"unknown-{raw_phase}"),
        "buy_trend_family": phase_family(raw_phase),
        "buy_fit_observation_count": int(buy["fit_observation_count"] or 0),
        "buy_decision_score": float(buy["decision_score"]),
        "buy_threshold": threshold,
        "buy_margin": margin,
        "buy_margin_band": margin_band(margin),
        "add_count": len(adds),
        "first_add_date": int(adds[0]["trade_date"]) if adds else None,
        "last_add_date": int(adds[-1]["trade_date"]) if adds else None,
        "outcome_date": int(final["trade_date"]),
        "actual_exit": int(final["executed_action"] == "SELL"),
        "exit_gates": "|".join(exit_gates),
        "holding_days": days,
        "outcome_roi": outcome_roi,
        "outcome_score": score,
        "negative_score": int(score < 0),
    }


PHASE_GRADE_NAMES = {-3: "damn", -2: "low", -1: "weak", 0: "none", 1: "fine", 2: "high", 3: "wow"}


def cycles(sample: str, database: Path) -> tuple[list[dict], list[dict]]:
    connection = connect(database)
    try:
        rows = event_rows(connection)
        score_map = grade_scores(connection)
        gate_map = gates(connection)
    finally:
        connection.close()
    grouped: dict[tuple[int, int], list[dict]] = defaultdict(list)
    for row in rows:
        grouped[(int(row["window_id"]), int(row["stock_key"]))].append(row)
    output: list[dict] = []
    exclusions: list[dict] = []
    for path_rows in grouped.values():
        buy: dict | None = None
        adds: list[dict] = []
        last_sell_observation: dict | None = None
        for row in path_rows:
            if row["executed_action"] == "BUY" and float(row["inventory_before"]) <= 0:
                if buy is not None:
                    raise ValueError(f"{sample} overlapping holding cycles")
                buy = row
                adds = []
                last_sell_observation = None
                continue
            if buy is None:
                continue
            if int(row["phase"]) == 4 and row["executed_action"] == "ADD":
                adds.append(row)
                continue
            if int(row["phase"]) != 3:
                continue
            last_sell_observation = row
            if row["executed_action"] == "SELL":
                output.append(cycle_result(sample, buy, row, adds, gate_map, score_map))
                buy = None
                adds = []
                last_sell_observation = None
        if buy is not None:
            if last_sell_observation is None:
                exclusions.append({
                    "sample": sample,
                    "window_id": int(buy["window_id"]),
                    "stock_id": str(buy["stock_id"]),
                    "stock_name": str(buy["stock_name"]),
                    "buy_date": int(buy["trade_date"]),
                    "buy_type": str(buy["planned_action"]),
                    "reason": "no_subsequent_held_decision_before_window_end",
                })
            else:
                output.append(cycle_result(sample, buy, last_sell_observation, adds, gate_map, score_map))
    return output, exclusions


def choose_controls(case: dict, positives: list[dict], count: int = 3) -> list[dict]:
    exact = [
        row for row in positives
        if row["sample"] == case["sample"]
        and row["buy_type"] == case["buy_type"]
        and row["buy_grade"] == case["buy_grade"]
        and row["buy_margin_band"] == case["buy_margin_band"]
    ]
    if not exact:
        exact = [
            row for row in positives
            if row["sample"] == case["sample"]
            and row["buy_type"] == case["buy_type"]
            and row["buy_grade"] == case["buy_grade"]
        ]
    ranked = sorted(
        exact,
        key=lambda row: (
            row["stock_id"] == case["stock_id"],
            row["window_id"] == case["window_id"],
            abs(float(row["buy_grade_score"]) - float(case["buy_grade_score"])),
            abs(float(row["buy_margin"]) - float(case["buy_margin"])),
            row["buy_date"],
        ),
    )
    return ranked[:count]


def matched_rows(rows: list[dict]) -> tuple[list[dict], list[dict]]:
    negatives = [row for row in rows if row["negative_score"]]
    positives = [row for row in rows if not row["negative_score"]]
    matches: list[dict] = []
    unmatched: list[dict] = []
    for case_index, case in enumerate(negatives, start=1):
        controls = choose_controls(case, positives)
        if not controls:
            unmatched.append(case)
            continue
        for rank, control in enumerate(controls, start=1):
            matches.append({
                "case_id": case_index,
                "sample": case["sample"],
                "case_stock_id": case["stock_id"],
                "case_window_id": case["window_id"],
                "case_buy_date": case["buy_date"],
                "case_buy_type": case["buy_type"],
                "case_grade": case["buy_grade"],
                "case_grade_score": case["buy_grade_score"],
                "case_margin_band": case["buy_margin_band"],
                "case_phase": case["buy_trend_phase"],
                "case_phase_family": case["buy_trend_family"],
                "case_add_count": case["add_count"],
                "case_holding_days": case["holding_days"],
                "case_outcome_score": case["outcome_score"],
                "control_rank": rank,
                "control_stock_id": control["stock_id"],
                "control_window_id": control["window_id"],
                "control_buy_date": control["buy_date"],
                "control_buy_type": control["buy_type"],
                "control_grade": control["buy_grade"],
                "control_grade_score": control["buy_grade_score"],
                "control_grade_score_band": control["buy_grade_score_band"],
                "control_margin_band": control["buy_margin_band"],
                "control_phase": control["buy_trend_phase"],
                "control_phase_family": control["buy_trend_family"],
                "control_add_count": control["add_count"],
                "control_holding_days": control["holding_days"],
                "control_outcome_score": control["outcome_score"],
            })
    return matches, unmatched


def feature_enrichment(rows: list[dict], matches: list[dict], field: str) -> list[dict]:
    negative_rows = [row for row in rows if row["negative_score"]]
    negative_counts = Counter((row["sample"], row[field]) for row in negative_rows)
    negative_totals = Counter(row["sample"] for row in negative_rows)
    control_field = {
        "buy_trend_phase": "control_phase",
        "buy_trend_family": "control_phase_family",
    }[field]
    control_counts = Counter((row["sample"], row[control_field]) for row in matches)
    control_totals = Counter(row["sample"] for row in matches)
    values = sorted({row[field] for row in negative_rows})
    output: list[dict] = []
    for value in values:
        per_sample = []
        for sample in ("D", "E"):
            negative_count = negative_counts[(sample, value)]
            control_count = control_counts[(sample, value)]
            negative_share = negative_count / negative_totals[sample] if negative_totals[sample] else 0
            control_share = control_count / control_totals[sample] if control_totals[sample] else 0
            enrichment = negative_share / control_share if control_share else None
            per_sample.append((sample, negative_count, control_count, negative_share, control_share, enrichment))
        combined_cases = [row for row in negative_rows if row[field] == value]
        cross_signal = int(
            all(item[1] >= 3 and item[5] is not None and item[5] >= 1.5 for item in per_sample)
            and len({(row["sample"], row["stock_id"]) for row in combined_cases}) >= 4
            and len({(row["sample"], row["window_id"]) for row in combined_cases}) >= 3
        )
        for sample, negative_count, control_count, negative_share, control_share, enrichment in per_sample:
            output.append({
                "feature": field,
                "value": value,
                "sample": sample,
                "negative_cases": negative_count,
                "matched_controls": control_count,
                "negative_share": negative_share,
                "control_share": control_share,
                "enrichment": enrichment,
                "combined_stocks": len({(row["sample"], row["stock_id"]) for row in combined_cases}),
                "combined_windows": len({(row["sample"], row["window_id"]) for row in combined_cases}),
                "cross_sample_signal": cross_signal,
            })
    return output


def median(rows: list[dict], key: str) -> float | None:
    values = [float(row[key]) for row in rows if row.get(key) is not None]
    return statistics.median(values) if values else None


def mechanics(rows: list[dict]) -> list[dict]:
    output = []
    for sample in ("D", "E"):
        for result in ("negative", "nonnegative"):
            subset = [
                row for row in rows
                if row["sample"] == sample and bool(row["negative_score"]) == (result == "negative")
            ]
            output.append({
                "sample": sample,
                "result": result,
                "rounds": len(subset),
                "stocks": len({row["stock_id"] for row in subset}),
                "windows": len({row["window_id"] for row in subset}),
                "median_outcome_score": median(subset, "outcome_score"),
                "median_outcome_roi": median(subset, "outcome_roi"),
                "median_holding_days": median(subset, "holding_days"),
                "median_add_count": median(subset, "add_count"),
                "no_add_rate": sum(row["add_count"] == 0 for row in subset) / len(subset) if subset else None,
                "window_end_rate": sum(not row["actual_exit"] for row in subset) / len(subset) if subset else None,
            })
    return output


def entry_context(rows: list[dict]) -> list[dict]:
    grouped: dict[tuple, list[dict]] = defaultdict(list)
    for row in rows:
        grouped[(
            row["sample"], row["buy_type"], row["buy_grade"], row["buy_grade_score_band"]
        )].append(row)
    output = []
    for (sample, buy_type, grade, band), subset in sorted(grouped.items()):
        if len(subset) < 5:
            continue
        output.append({
            "sample": sample,
            "buy_type": buy_type,
            "grade": grade,
            "grade_score_band": band,
            "rounds": len(subset),
            "stocks": len({row["stock_id"] for row in subset}),
            "windows": len({row["window_id"] for row in subset}),
            "median_outcome_score": median(subset, "outcome_score"),
            "median_outcome_roi": median(subset, "outcome_roi"),
            "negative_rate": sum(row["negative_score"] for row in subset) / len(subset),
        })
    return output


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def fmt(value: object, digits: int = 3) -> str:
    if value is None:
        return "—"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def render(summary: dict, mechanics_rows: list[dict], context_rows: list[dict], enrichments: list[dict]) -> str:
    signals = [row for row in enrichments if row["cross_sample_signal"]]
    lines = [
        f"# {STUDY_ID}",
        "",
        "Baseline v20 Sample D／E DecisionBase v6 唯讀診斷；不修改規則、不重跑模擬。",
        "負效率輪以同 Sample、同 H買／L買、同 exact Grade、同買入門檻餘量配對最接近 Grade 連續分數的正效率輪。",
        "",
        "## 完整性",
        "",
        f"- 完整持股輪：{summary['rounds']}（D {summary['roundsBySample']['D']}／E {summary['roundsBySample']['E']}）",
        f"- 窗口末買入後沒有持股判斷列而排除：{summary['excludedEntries']}",
        f"- 負效率輪：{summary['negativeRounds']}；成功配對：{summary['matchedNegativeRounds']}；未配對：{summary['unmatchedNegativeRounds']}",
        f"- 配對控制列：{summary['matchedControlRows']}",
        f"- 負輪與配對控制的 Grade 連續分數距離中位：{fmt(summary['medianMatchedGradeScoreDistance'])}",
        "- 兩份 DecisionBase：3 窗口、10 檔、SQLite integrity ok、0 本金不足。",
        "",
        "## 結果與持股機制",
        "",
        "| Sample | 結果 | 輪數 | 中位 ROI | 中位期間 | 中位效率分數 | 中位加碼次數 | 未加碼率 | 窗口末未結案率 |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in mechanics_rows:
        lines.append(
            f"| {row['sample']} | {row['result']} | {row['rounds']} | {fmt(row['median_outcome_roi'])}% | "
            f"{fmt(row['median_holding_days'], 1)} | {fmt(row['median_outcome_score'])} | "
            f"{fmt(row['median_add_count'], 1)} | {fmt(100 * row['no_add_rate'], 1)}% | "
            f"{fmt(100 * row['window_end_rate'], 1)}% |"
        )
    lines.extend([
        "",
        "## Grade 與連續效率分數",
        "",
        "下表保留至少 5 輪的 Grade×連續分數區間；負分率只反映風險比例，必須和中位效率分數一起判讀。",
        "",
        "| Sample | 買入 | Grade | 連續分數區間 | 輪數 | 中位效率分數 | 負分率 |",
        "| --- | --- | --- | --- | ---: | ---: | ---: |",
    ])
    for row in context_rows:
        lines.append(
            f"| {row['sample']} | {row['buy_type']}買 | {row['grade']} | {row['grade_score_band']} | "
            f"{row['rounds']} | {fmt(row['median_outcome_score'])} | {fmt(100 * row['negative_rate'], 1)}% |"
        )
    lines.extend(["", "## 進場前可辨識趨勢特徵", ""])
    if signals:
        lines.extend([
            "| 特徵 | 值 | Sample | 負輪／配對控制 | 占比 | 控制占比 | 富集倍數 | 跨樣本股票／窗口 |",
            "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |",
        ])
        for row in signals:
            lines.append(
                f"| {row['feature']} | {row['value']} | {row['sample']} | "
                f"{row['negative_cases']}／{row['matched_controls']} | {fmt(100 * row['negative_share'], 1)}% | "
                f"{fmt(100 * row['control_share'], 1)}% | {fmt(row['enrichment'], 2)} | "
                f"{row['combined_stocks']}／{row['combined_windows']} |"
            )
    else:
        lines.append("沒有特徵同時在 D／E 各至少 3 輪、富集至少 1.5 倍，且跨足 4 個 Sample×股票與 3 個 Sample×窗口。")
    lines.extend([
        "",
        "此處只篩選交易當下已知的適配趨勢階段／階段家族；加碼次數、持股期與出口只用來解釋機制，不可倒用為買入條件。",
        "",
        "## 判讀",
        "",
        f"- 至少 5 輪的 H買 Grade×連續分數區間共有 {summary['hContextGroups']} 組，中位效率分數非正的組數為 {summary['hNonpositiveMedianGroups']}；100／200 分界沒有形成跨 D／E 的負向中位區間。",
        "- D 的 L買 exact low、分數 [-23,-5) 中位為負，但 E 同條件中位為正，屬跨樣本反轉，不能形成 L買減分。",
        "- 負效率輪較常曾經加碼、也較常在窗口末仍未結案；兩者都是進場後才出現的結果路徑。前者不能證明加碼造成虧損，後者也不能倒用為進場條件。",
        "- 配對後沒有適配趨勢階段跨 D／E 富集；因此本診斷不建立新候選。加碼時機與長期資金占用已分別由 A-BOT、E-CAP 系列檢驗，不因本次結果重開已停止的廣域方向。",
        "",
        "完整逐輪、配對與全部富集結果見同目錄 CSV。",
    ])
    return "\n".join(lines) + "\n"


def main() -> None:
    args = arguments()
    inputs = specs(args.decision_base)
    identities = verify(inputs)
    rows: list[dict] = []
    exclusions: list[dict] = []
    for sample, directory in sorted(inputs.items()):
        sample_rows, sample_exclusions = cycles(sample, directory / "decisions.sqlite")
        rows.extend(sample_rows)
        exclusions.extend(sample_exclusions)
    matches, unmatched = matched_rows(rows)
    enrichments = []
    for field in ("buy_trend_phase", "buy_trend_family"):
        enrichments.extend(feature_enrichment(rows, matches, field))
    mechanics_rows = mechanics(rows)
    context_rows = entry_context(rows)
    h_context_rows = [row for row in context_rows if row["buy_type"] == "H"]
    matched_case_ids = {row["case_id"] for row in matches}
    summary = {
        "studyID": STUDY_ID,
        "rounds": len(rows),
        "excludedEntries": len(exclusions),
        "roundsBySample": {sample: sum(row["sample"] == sample for row in rows) for sample in ("D", "E")},
        "negativeRounds": sum(row["negative_score"] for row in rows),
        "matchedNegativeRounds": len(matched_case_ids),
        "unmatchedNegativeRounds": len(unmatched),
        "matchedControlRows": len(matches),
        "medianMatchedGradeScoreDistance": statistics.median(
            abs(float(row["case_grade_score"]) - float(row["control_grade_score"]))
            for row in matches
        ),
        "crossSampleSignals": sum(row["cross_sample_signal"] for row in enrichments) // 2,
        "hContextGroups": len(h_context_rows),
        "hNonpositiveMedianGroups": sum(
            float(row["median_outcome_score"]) <= 0 for row in h_context_rows
        ),
        "identities": identities,
    }
    args.output.mkdir(parents=True, exist_ok=True)
    write_csv(args.output / "rounds.csv", rows)
    write_csv(args.output / "matched-controls.csv", matches)
    write_csv(args.output / "unmatched-negative-rounds.csv", unmatched)
    write_csv(args.output / "excluded-entries.csv", exclusions)
    write_csv(args.output / "feature-enrichment.csv", enrichments)
    write_csv(args.output / "mechanics-summary.csv", mechanics_rows)
    write_csv(args.output / "entry-context-summary.csv", context_rows)
    (args.output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (args.output / "report.md").write_text(
        render(summary, mechanics_rows, context_rows, enrichments), encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
