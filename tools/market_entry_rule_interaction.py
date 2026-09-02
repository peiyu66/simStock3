#!/usr/bin/env python3
"""MKT-R02-D1: market phenomenon x pivotal entry-rule interaction study."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import random
import statistics
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable

from eentry01_pivotal_buy_vote_study import entry_rows, expanded_pivotal_rows
from market_vote_phenomenon_inventory import build_atoms, load_market


ROOT = Path(__file__).resolve().parents[1]
STUDY_ID = "MKT-R02-D1"
EXPECTED_SAMPLES = {"A", "B", "C", "D"}
EXPECTED_COMMON = {
    "dataRuleVersion": "T2/S39",
    "ruleVersion": "s32-an03-wow-nonbottom-no-ap02-add-penalty-20260901",
    "ruleCommit": "48d42e50ada5dcc0ed2e22dffff6871323daf8b7",
    "through": "2026/07/22",
    "moneyBaseWan": 600,
    "automaticInvestments": 2,
}
EXPECTED_MARKET_TECHNICAL_SHA256 = (
    "a00beac8d4af55668f977a4aca74b3e6c71e60bee6e456544a5a833d4ee95084"
)
EXPECTED_ATOM_CSV_SHA256 = (
    "3790814f5e56c898ce2c3a4ff1b29e13bcd2207ff6f37cfdc4a67c7ff9cd859b"
)
MIN_DATES_PER_SIDE = 30
MIN_STOCKS_PER_SIDE = 10
MIN_CONFIRM_STOCKS = 5
MIN_CONFIRM_SAMPLES = 2
INTERACTION_FIELDS = [
    "window_id", "rule_id", "atom_id", "source_field", "kind", "condition",
    "on_dates", "off_dates", "on_stocks", "off_stocks", "on_samples", "off_samples",
    "raw_effect", "standardized_effect", "direction", "event_rows", "max_date_share",
    "max_stock_share", "global_null_p", "global_null_p95", "exceeds_global_null_p95",
    "closed_only_standardized_effect", "w1_standardized_effect", "same_direction_as_w1",
    "confirmed", "bootstrap_ci_low", "bootstrap_ci_high", "same_direction_as_w1_w2",
    "ci_excludes_zero", "passed",
]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[dict[str, Any]], fields: list[str] | None = None) -> None:
    if fields is None:
        fields = list(rows[0]) if rows else []
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        if fields:
            writer.writeheader()
            writer.writerows(rows)


def percentile(values: list[float], probability: float) -> float:
    require(values, "percentile requires values")
    ordered = sorted(values)
    position = (len(ordered) - 1) * probability
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1 - fraction) + ordered[upper] * fraction


def parse_decision_bases(values: list[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        require("=" in value, f"invalid --decision-base {value!r}")
        sample, raw = value.split("=", 1)
        sample = sample.upper()
        require(sample in EXPECTED_SAMPLES and sample not in result, f"invalid sample {sample}")
        result[sample] = Path(raw)
    require(set(result) == EXPECTED_SAMPLES, f"expected A-D, got {sorted(result)}")
    return result


def verify_decision_bases(specs: dict[str, Path]) -> dict[str, dict[str, Any]]:
    import sqlite3

    identities: dict[str, dict[str, Any]] = {}
    catalog_hashes: set[str] = set()
    for sample, directory in sorted(specs.items()):
        manifest = read_json(directory / "manifest.json")
        base_id = manifest.get("decisionBaseID")
        require(manifest.get("sampleID") == sample, f"{sample} sample mismatch")
        for key, expected in EXPECTED_COMMON.items():
            require(manifest.get(key) == expected, f"{sample} {key} mismatch: {manifest.get(key)!r}")
        require((directory / ".complete").read_text().strip() == base_id, f"{sample} complete mismatch")
        require((directory / ".p4b-complete").read_text().strip() == base_id, f"{sample} P4b mismatch")
        database = directory / "decisions.sqlite"
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        windows = connection.execute("SELECT COUNT(*) FROM windows").fetchone()[0]
        stocks = connection.execute("SELECT COUNT(*) FROM stocks").fetchone()[0]
        connection.close()
        require(integrity == "ok" and windows == 3 and stocks == 10,
                f"{sample} integrity/coverage mismatch: {integrity}/{windows}/{stocks}")
        catalog_hashes.add(sha256(directory / "rule-catalog.json"))
        identities[sample] = {
            "decisionBaseID": base_id,
            "manifestSha256": sha256(directory / "manifest.json"),
            "databaseSha256": sha256(database),
            "ruleCatalogSha256": sha256(directory / "rule-catalog.json"),
            "database": str(database),
        }
    require(len(catalog_hashes) == 1, "A-D rule catalogs differ")
    return identities


def verify_atoms(atom_dir: Path, generated: list[dict[str, Any]]) -> list[dict[str, Any]]:
    atom_path = atom_dir / "phenomenon-atoms.csv"
    require(sha256(atom_path) == EXPECTED_ATOM_CSV_SHA256, "I01 phenomenon-atoms.csv hash mismatch")
    recorded = read_csv(atom_path)
    selected = [
        row for row in recorded
        if row["category"] == "price"
        and row["market_coverage_passed"] == "True"
        and row["is_canonical"] == "True"
    ]
    generated_by_id = {row["atom_id"]: row for row in generated}
    require(len(selected) == 467, f"expected 467 canonical price atoms, got {len(selected)}")
    require(set(row["atom_id"] for row in selected) <= set(generated_by_id), "I01 atom IDs changed")
    output = []
    for row in selected:
        generated_row = generated_by_id[row["atom_id"]]
        require(str(generated_row["condition"]) == row["condition"], f"atom changed: {row['atom_id']}")
        output.append({**row, "mask": int(generated_row["mask"])})
    return output


def build_entries(identities: dict[str, dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    entries: list[dict[str, Any]] = []
    exclusions: list[dict[str, Any]] = []
    for sample in sorted(EXPECTED_SAMPLES):
        sample_rows, sample_exclusions = entry_rows(sample, Path(identities[sample]["database"]))
        entries.extend(sample_rows)
        exclusions.extend(sample_exclusions)
    return entries, exclusions


def residualized_rows(expanded: list[dict[str, Any]], window_id: int,
                      closed_only: bool = False) -> dict[str, list[dict[str, Any]]]:
    by_rule: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in expanded:
        if row["window_id"] != window_id or (closed_only and not row["actual_exit"]):
            continue
        by_rule[row["rule_id"]].append(row)
    output: dict[str, list[dict[str, Any]]] = {}
    for rule, rows in by_rule.items():
        strata: dict[tuple[Any, ...], list[dict[str, Any]]] = defaultdict(list)
        for row in rows:
            strata[(
                row["sample"], row["buy_type"], row["buy_grade"],
                row["buy_grade_score_band"], round(float(row["buy_decision_margin"]), 9),
            )].append(row)
        usable: list[dict[str, Any]] = []
        for items in strata.values():
            if len(items) < 2:
                continue
            center = statistics.fmean(float(item["outcome_score"]) for item in items)
            for item in items:
                usable.append({**item, "residual_score": float(item["outcome_score"]) - center})
        if usable:
            output[rule] = usable
    return output


def collapse_dates(rows: list[dict[str, Any]]) -> dict[int, dict[str, Any]]:
    grouped: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[int(row["buy_date"])].append(row)
    return {
        date: {
            "score": statistics.fmean(float(row["residual_score"]) for row in items),
            "stocks": {(row["sample"], row["stock_id"]) for row in items},
            "samples": {row["sample"] for row in items},
            "rows": items,
        }
        for date, items in grouped.items()
    }


def candidate_stat(rule: str, atom_id: str, date_rows: dict[int, dict[str, Any]],
                   true_dates: set[int], enforce_capacity: bool = True) -> dict[str, Any] | None:
    on_dates = sorted(set(date_rows) & true_dates)
    off_dates = sorted(set(date_rows) - true_dates)
    on_stocks = set().union(*(date_rows[date]["stocks"] for date in on_dates)) if on_dates else set()
    off_stocks = set().union(*(date_rows[date]["stocks"] for date in off_dates)) if off_dates else set()
    if enforce_capacity and (
        len(on_dates) < MIN_DATES_PER_SIDE or len(off_dates) < MIN_DATES_PER_SIDE
        or len(on_stocks) < MIN_STOCKS_PER_SIDE or len(off_stocks) < MIN_STOCKS_PER_SIDE
    ):
        return None
    if not on_dates or not off_dates:
        return None
    on_values = [float(date_rows[date]["score"]) for date in on_dates]
    off_values = [float(date_rows[date]["score"]) for date in off_dates]
    all_values = on_values + off_values
    spread = statistics.pstdev(all_values)
    raw_effect = statistics.fmean(on_values) - statistics.fmean(off_values)
    standardized = raw_effect / spread if spread > 1e-12 else 0.0
    on_samples = set().union(*(date_rows[date]["samples"] for date in on_dates))
    off_samples = set().union(*(date_rows[date]["samples"] for date in off_dates))
    all_event_rows = [row for date in date_rows for row in date_rows[date]["rows"]]
    date_counts = Counter(int(row["buy_date"]) for row in all_event_rows)
    stock_counts = Counter((row["sample"], row["stock_id"]) for row in all_event_rows)
    return {
        "rule_id": rule,
        "atom_id": atom_id,
        "on_dates": len(on_dates),
        "off_dates": len(off_dates),
        "on_stocks": len(on_stocks),
        "off_stocks": len(off_stocks),
        "on_samples": len(on_samples),
        "off_samples": len(off_samples),
        "raw_effect": raw_effect,
        "standardized_effect": standardized,
        "direction": "support" if standardized > 0 else "oppose" if standardized < 0 else "zero",
        "event_rows": len(all_event_rows),
        "max_date_share": max(date_counts.values()) / len(all_event_rows),
        "max_stock_share": max(stock_counts.values()) / len(all_event_rows),
    }


def date_sets(atoms: list[dict[str, Any]], market_rows: list[dict[str, Any]]) -> dict[str, set[int]]:
    output: dict[str, set[int]] = {}
    for atom in atoms:
        mask = int(atom["mask"])
        output[atom["atom_id"]] = {
            int(row["date"]) for index, row in enumerate(market_rows) if mask & (1 << index)
        }
    return output


def shifted_date_sets(atom_sets: dict[str, set[int]], window_dates: list[int], offset: int) -> dict[str, set[int]]:
    index = {date: position for position, date in enumerate(window_dates)}
    shifted: dict[str, set[int]] = {}
    length = len(window_dates)
    for atom_id, dates in atom_sets.items():
        shifted[atom_id] = {
            window_dates[(index[date] + offset) % length] for date in dates if date in index
        }
    return shifted


def screen(window_id: int, rule_rows: dict[str, list[dict[str, Any]]],
           atoms: list[dict[str, Any]], atom_sets: dict[str, set[int]]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    atom_by_id = {row["atom_id"]: row for row in atoms}
    for rule, rows in sorted(rule_rows.items()):
        collapsed = collapse_dates(rows)
        for atom_id, dates in atom_sets.items():
            result = candidate_stat(rule, atom_id, collapsed, dates)
            if result is not None:
                atom = atom_by_id[atom_id]
                output.append({
                    "window_id": window_id,
                    **result,
                    "source_field": atom["source_field"],
                    "kind": atom["kind"],
                    "condition": atom["condition"],
                })
    return output


def null_maxima(rule_rows: dict[str, list[dict[str, Any]]], candidates: list[dict[str, Any]],
                atom_sets: dict[str, set[int]], window_dates: list[int], permutations: int,
                seed: int) -> list[dict[str, Any]]:
    if not candidates:
        return []
    rng = random.Random(seed)
    collapsed = {rule: collapse_dates(rows) for rule, rows in rule_rows.items()}
    family = sorted({(row["rule_id"], row["atom_id"]) for row in candidates})
    used_atom_ids = {atom_id for _, atom_id in family}
    used_atom_sets = {atom_id: atom_sets[atom_id] for atom_id in used_atom_ids}
    spreads = {
        rule: statistics.pstdev(float(row["score"]) for row in dates.values())
        for rule, dates in collapsed.items()
    }
    output = []
    print(f"null start: {len(family)} interactions x {permutations} shifts", flush=True)
    for permutation in range(1, permutations + 1):
        offset = rng.randrange(1, len(window_dates))
        shifted = shifted_date_sets(used_atom_sets, window_dates, offset)
        maximum = 0.0
        evaluated = 0
        for rule, atom_id in family:
            date_values = collapsed[rule]
            on_dates = set(date_values) & shifted[atom_id]
            off_dates = set(date_values) - shifted[atom_id]
            if len(on_dates) < MIN_DATES_PER_SIDE or len(off_dates) < MIN_DATES_PER_SIDE:
                continue
            on_stocks = set().union(*(date_values[date]["stocks"] for date in on_dates))
            off_stocks = set().union(*(date_values[date]["stocks"] for date in off_dates))
            if len(on_stocks) < MIN_STOCKS_PER_SIDE or len(off_stocks) < MIN_STOCKS_PER_SIDE:
                continue
            on_mean = statistics.fmean(float(date_values[date]["score"]) for date in on_dates)
            off_mean = statistics.fmean(float(date_values[date]["score"]) for date in off_dates)
            spread = spreads[rule]
            standardized = (on_mean - off_mean) / spread if spread > 1e-12 else 0.0
            maximum = max(maximum, abs(standardized))
            evaluated += 1
        output.append({"permutation": permutation, "offset": offset,
                       "global_max_abs_effect": maximum, "evaluated_interactions": evaluated})
        if permutation % 50 == 0 or permutation == permutations:
            print(f"null progress: {permutation}/{permutations}", flush=True)
    return output


def attach_null(rows: list[dict[str, Any]], null_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not rows or not null_rows:
        return []
    maxima = [float(row["global_max_abs_effect"]) for row in null_rows]
    threshold = percentile(maxima, 0.95)
    output = []
    for row in rows:
        observed = abs(float(row["standardized_effect"]))
        p = (1 + sum(value >= observed for value in maxima)) / (len(maxima) + 1)
        output.append({**row, "global_null_p": p, "global_null_p95": threshold,
                       "exceeds_global_null_p95": int(observed > threshold)})
    return output


def attach_closed_sensitivity(rows: list[dict[str, Any]], closed_rule_rows: dict[str, list[dict[str, Any]]],
                              atom_sets: dict[str, set[int]]) -> list[dict[str, Any]]:
    collapsed = {rule: collapse_dates(items) for rule, items in closed_rule_rows.items()}
    output = []
    for row in rows:
        closed = candidate_stat(row["rule_id"], row["atom_id"], collapsed.get(row["rule_id"], {}),
                                atom_sets[row["atom_id"]], False)
        output.append({**row, "closed_only_standardized_effect": (
            closed["standardized_effect"] if closed else None
        )})
    return output


def bootstrap_ci(date_rows: dict[int, dict[str, Any]], true_dates: set[int], draws: int,
                 seed: int) -> tuple[float, float]:
    rng = random.Random(seed)
    on = [float(date_rows[date]["score"]) for date in sorted(set(date_rows) & true_dates)]
    off = [float(date_rows[date]["score"]) for date in sorted(set(date_rows) - true_dates)]
    require(on and off, "bootstrap groups are empty")
    values = []
    for _ in range(draws):
        on_mean = statistics.fmean(on[rng.randrange(len(on))] for _ in range(len(on)))
        off_mean = statistics.fmean(off[rng.randrange(len(off))] for _ in range(len(off)))
        values.append(on_mean - off_mean)
    return percentile(values, 0.025), percentile(values, 0.975)


def synthetic_control() -> dict[str, Any]:
    rows = []
    atom_true = set(range(1, 121, 2))
    decoy_true = set(range(1, 121, 3))
    for date in range(1, 121):
        planted = 8.0 if date in atom_true else 0.0
        noise = ((date * 17) % 11 - 5) / 10
        rows.append({
            "buy_date": date, "sample": "S1" if date <= 60 else "S2",
            "stock_id": str(date % 12), "residual_score": planted + noise,
        })
    collapsed: dict[int, dict[str, Any]] = {}
    for row in rows:
        collapsed[row["buy_date"]] = {
            "score": row["residual_score"],
            "stocks": {(row["sample"], row["stock_id"])},
            "samples": {row["sample"]}, "rows": [row],
        }
    planted = candidate_stat("SYN-RULE", "SYN-ATOM", collapsed, atom_true, False)
    decoy = candidate_stat("SYN-RULE", "DECOY", collapsed, decoy_true, False)
    removed_rows = [{**row, "residual_score": row["residual_score"] - (8.0 if row["buy_date"] in atom_true else 0.0)} for row in rows]
    removed = {
        row["buy_date"]: {"score": row["residual_score"],
                          "stocks": {(row["sample"], row["stock_id"])},
                          "samples": {row["sample"]}, "rows": [row]}
        for row in removed_rows
    }
    removed_stat = candidate_stat("SYN-RULE", "SYN-ATOM", removed, atom_true, False)
    passed = (
        planted is not None and decoy is not None and removed_stat is not None
        and planted["standardized_effect"] > 0
        and abs(planted["standardized_effect"]) > abs(decoy["standardized_effect"])
        and abs(removed_stat["standardized_effect"]) < 0.25
    )
    return {
        "passed": passed,
        "expectedInteraction": "SYN-RULE x SYN-ATOM",
        "expectedDirection": "support",
        "plantedStandardizedEffect": planted["standardized_effect"] if planted else None,
        "decoyStandardizedEffect": decoy["standardized_effect"] if decoy else None,
        "removedStandardizedEffect": removed_stat["standardized_effect"] if removed_stat else None,
    }


def report(summary: dict[str, Any], final_row: dict[str, Any] | None) -> str:
    lines = [
        f"# {STUDY_ID} 大盤×進場規則效率交互實驗",
        "",
        f"結論：{summary['conclusion']}。",
        "",
        "## 固定範圍",
        "",
        "- Baseline v20、T2/S39、S32，Sample A～D 三個固定三年窗口；未執行 simUpdate。",
        "- 只分析買入前庫存為 0 的正式 H買／L買，並展開當日剛好使決策跨線的正向規則票。",
        "- 市場條件只用 I01 事前凍結的 467 個單一價格現象；W1 形成、W2 確認、W3 最終確認。",
        "- 同一市場日先合併股票結果；虛無分布以整個窗口的市場日期共同循環位移，不把同日不同股票當獨立市場樣本。",
        "",
        "## 結果",
        "",
        f"- 正式新持股輪：{summary['entries']:,}；含關鍵票：{summary['entriesWithPivotalVote']:,}；展開關鍵票列：{summary['expandedPivotalRows']:,}；規則：{summary['pivotalRules']} 條。",
        f"- W1 容量合格交互：{summary['w1CapacityEligible']:,}；超過全家族虛無門檻：{summary['w1FrozenCandidates']:,}。",
        f"- W2 同方向且再超過凍結家族虛無門檻：{summary['w2ConfirmedCandidates']:,}。",
        f"- W3 通過同日區塊 bootstrap 與集中度門檻：{summary['w3PassedCandidates']:,}。",
        f"- 合成植入控制：{'通過' if summary['syntheticControlPassed'] else '失敗'}。",
    ]
    if final_row:
        lines.extend([
            "",
            "## 唯一最終交互",
            "",
            f"- `{final_row['rule_id']} × {final_row['atom_id']}`：{final_row['condition']}。",
            f"- W3 標準化效果 {final_row['standardized_effect']:.4f}，原始效果 95% CI [{final_row['bootstrap_ci_low']:.4f}, {final_row['bootstrap_ci_high']:.4f}]。",
            "- 這只允許提出一個 ±1 分完整候選，尚不是正式規則，也不代表 Baseline 改善。",
        ])
    else:
        lines.extend([
            "",
            "沒有交互同時通過 W1 形成、W2 確認與 W3 最終確認，因此本次不提出大盤加減分候選。這是預先允許的零結果。",
        ])
    lines.extend([
        "",
        "## 界線",
        "",
        "- 關聯結果不等於加入市場票後的反事實路徑；只有後續完整候選重播才能判斷策略效率是否改善。",
        "- 窗口末仍持股輪納入主要結果且保留標記；W1／W2 候選另列只看實際結案輪的敏感度，但不作候選閘門。",
        "- Sample E 保留給已形成候選的弱勢壓力測試，未參與發現。",
        "",
    ])
    return "\n".join(lines)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--decision-base", action="append", required=True)
    parser.add_argument("--market-snapshot", type=Path, required=True)
    parser.add_argument("--atom-inventory", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--permutations", type=int, default=500)
    parser.add_argument("--bootstrap", type=int, default=2000)
    parser.add_argument("--seed", type=int, default=20260903)
    return parser.parse_args()


def main() -> int:
    args = arguments()
    require(args.permutations >= 500, "D1 requires at least 500 null permutations")
    require(args.bootstrap >= 1000, "D1 requires at least 1000 bootstrap draws")
    specs = parse_decision_bases(args.decision_base)
    identities = verify_decision_bases(specs)
    market_technical = args.market_snapshot / "market-technical.csv"
    require(sha256(market_technical) == EXPECTED_MARKET_TECHNICAL_SHA256, "MT1 technical hash mismatch")
    market_rows, catalog, market_manifest = load_market(args.market_snapshot)
    generated_atoms, _ = build_atoms(market_rows, catalog)
    atoms = verify_atoms(args.atom_inventory, generated_atoms)
    atom_sets_all = date_sets(atoms, market_rows)
    window_dates = {
        window: [int(row["date"]) for row in market_rows if int(row["window_id"]) == window]
        for window in (1, 2, 3)
    }
    atom_sets = {
        window: {atom_id: dates & set(window_dates[window]) for atom_id, dates in atom_sets_all.items()}
        for window in (1, 2, 3)
    }

    entries, exclusions = build_entries(identities)
    expanded = expanded_pivotal_rows(entries)
    require(len(entries) == 3024, f"unexpected v20 entry count {len(entries)}")
    require(len({(row['sample'], row['window_id'], row['stock_id'], row['buy_date']) for row in expanded}) == 978,
            "unexpected pivotal-entry count")
    primary_rows = {window: residualized_rows(expanded, window) for window in (1, 2, 3)}
    closed_rows = {window: residualized_rows(expanded, window, True) for window in (1, 2, 3)}

    w1_capacity = screen(1, primary_rows[1], atoms, atom_sets[1])
    print(f"W1 capacity eligible: {len(w1_capacity)}", flush=True)
    w1_null = null_maxima(primary_rows[1], w1_capacity, atom_sets[1], window_dates[1],
                          args.permutations, args.seed + 1)
    w1_scored = attach_null(w1_capacity, w1_null)
    w1_scored = attach_closed_sensitivity(w1_scored, closed_rows[1], atom_sets[1])
    frozen = [row for row in w1_scored if row["exceeds_global_null_p95"]]
    print(f"W1 frozen candidates: {len(frozen)}", flush=True)

    w2_all = screen(2, primary_rows[2], atoms, atom_sets[2])
    frozen_keys = {(row["rule_id"], row["atom_id"]): row for row in frozen}
    w2_family = [row for row in w2_all if (row["rule_id"], row["atom_id"]) in frozen_keys]
    print(f"W2 capacity-eligible frozen family: {len(w2_family)}", flush=True)
    w2_null = null_maxima(primary_rows[2], w2_family, atom_sets[2], window_dates[2],
                          args.permutations, args.seed + 2)
    w2_scored = attach_null(w2_family, w2_null)
    w2_scored = attach_closed_sensitivity(w2_scored, closed_rows[2], atom_sets[2])
    w2_evaluated = []
    w2_confirmed = []
    for row in w2_scored:
        prior = frozen_keys[(row["rule_id"], row["atom_id"])]
        same_direction = float(row["standardized_effect"]) * float(prior["standardized_effect"]) > 0
        confirmed = (
            same_direction and bool(row["exceeds_global_null_p95"])
            and min(row["on_stocks"], row["off_stocks"]) >= MIN_CONFIRM_STOCKS
            and min(row["on_samples"], row["off_samples"]) >= MIN_CONFIRM_SAMPLES
        )
        value = {**row, "w1_standardized_effect": prior["standardized_effect"],
                 "same_direction_as_w1": int(same_direction), "confirmed": int(confirmed)}
        w2_evaluated.append(value)
        if confirmed:
            w2_confirmed.append(value)

    selected: dict[str, Any] | None = None
    if w2_confirmed:
        selected = max(
            w2_confirmed,
            key=lambda row: (min(abs(float(row["w1_standardized_effect"])),
                                abs(float(row["standardized_effect"]))),
                             row["rule_id"], row["atom_id"]),
        )

    w3_rows: list[dict[str, Any]] = []
    final_row: dict[str, Any] | None = None
    if selected:
        key = (selected["rule_id"], selected["atom_id"])
        actual = next((row for row in screen(3, primary_rows[3], atoms, atom_sets[3])
                       if (row["rule_id"], row["atom_id"]) == key), None)
        if actual:
            collapsed = collapse_dates(primary_rows[3][selected["rule_id"]])
            low, high = bootstrap_ci(collapsed, atom_sets[3][selected["atom_id"]],
                                     args.bootstrap, args.seed + 3)
            expected_sign = 1 if float(selected["standardized_effect"]) > 0 else -1
            same_direction = float(actual["standardized_effect"]) * expected_sign > 0
            ci_excludes_zero = low > 0 if expected_sign > 0 else high < 0
            passed = (
                same_direction and ci_excludes_zero
                and min(actual["on_stocks"], actual["off_stocks"]) >= MIN_CONFIRM_STOCKS
                and min(actual["on_samples"], actual["off_samples"]) >= MIN_CONFIRM_SAMPLES
                and actual["max_date_share"] <= 0.5 and actual["max_stock_share"] <= 0.5
            )
            closed = candidate_stat(selected["rule_id"], selected["atom_id"],
                                    collapse_dates(closed_rows[3].get(selected["rule_id"], [])),
                                    atom_sets[3][selected["atom_id"]], False)
            value = {**actual, "bootstrap_ci_low": low, "bootstrap_ci_high": high,
                     "same_direction_as_w1_w2": int(same_direction),
                     "ci_excludes_zero": int(ci_excludes_zero), "passed": int(passed),
                     "closed_only_standardized_effect": closed["standardized_effect"] if closed else None,
                     "condition": selected["condition"]}
            w3_rows.append(value)
            if passed:
                final_row = value

    synthetic = synthetic_control()
    require(synthetic["passed"], "synthetic planted interaction control failed")
    run_material = json.dumps({
        "study": STUDY_ID,
        "decisionBases": {key: value["databaseSha256"] for key, value in identities.items()},
        "market": EXPECTED_MARKET_TECHNICAL_SHA256,
        "atoms": EXPECTED_ATOM_CSV_SHA256,
        "methodVersion": 4,
        "permutations": args.permutations, "bootstrap": args.bootstrap, "seed": args.seed,
    }, sort_keys=True).encode()
    run_id = f"mkt-r02-d1-entry-interaction-{hashlib.sha256(run_material).hexdigest()[:12]}"
    output = args.output_root / run_id
    require(not output.exists(), f"output already exists: {output}")
    output.mkdir(parents=True)

    summary = {
        "studyID": STUDY_ID,
        "runID": run_id,
        "conclusion": "發現一個可送完整回測的市場交互候選" if final_row else "未發現可送完整回測的穩定市場交互",
        "entries": len(entries),
        "excludedEntries": len(exclusions),
        "actualExitEntries": sum(int(row["actual_exit"]) for row in entries),
        "markedToMarketEntries": sum(not int(row["actual_exit"]) for row in entries),
        "entriesWithPivotalVote": len({(row["sample"], row["window_id"], row["stock_id"], row["buy_date"]) for row in expanded}),
        "expandedPivotalRows": len(expanded),
        "pivotalRules": len({row["rule_id"] for row in expanded}),
        "canonicalPriceAtoms": len(atoms),
        "w1CapacityEligible": len(w1_capacity),
        "w1FrozenCandidates": len(frozen),
        "w2ConfirmedCandidates": len(w2_confirmed),
        "w3PassedCandidates": int(final_row is not None),
        "syntheticControlPassed": synthetic["passed"],
        "selectedInteraction": ({"ruleID": final_row["rule_id"], "atomID": final_row["atom_id"],
                                  "direction": final_row["direction"]} if final_row else None),
    }
    manifest = {
        "studyID": STUDY_ID, "runID": run_id,
        **EXPECTED_COMMON,
        "samples": sorted(EXPECTED_SAMPLES),
        "decisionBases": identities,
        "marketSnapshotID": market_manifest.get("snapshotID"),
        "marketTechnicalSha256": EXPECTED_MARKET_TECHNICAL_SHA256,
        "atomInventory": str(args.atom_inventory),
        "atomCsvSha256": EXPECTED_ATOM_CSV_SHA256,
        "method": {
            "outcome": "formal cycle score; open-at-window-end marked to market; closed-only sensitivity",
            "matching": "Sample, H/L buy, formal Grade, continuous Grade score band, exact decision margin",
            "marketUnit": "same market date collapsed before inference",
            "null": "common circular shift of the full market-date series within each window",
            "capacity": {"datesPerSide": MIN_DATES_PER_SIDE, "stocksPerSide": MIN_STOCKS_PER_SIDE},
            "windows": "W1 formation, W2 frozen-family confirmation, W3 one-candidate bootstrap confirmation",
            "permutations": args.permutations, "bootstrapDraws": args.bootstrap, "seed": args.seed,
        },
        "artifacts": ["entries.csv", "excluded-entries.csv", "expanded-pivotal-entries.csv",
                      "w1-capacity.csv", "w1-null-max.csv", "w1-frozen.csv",
                      "w2-family.csv", "w2-null-max.csv", "w2-confirmed.csv", "w3-final.csv",
                      "synthetic-control.json", "quality-report.json", "summary.json", "report.md"],
    }
    write_csv(output / "entries.csv", entries)
    write_csv(output / "excluded-entries.csv", exclusions,
              ["sample", "window_id", "stock_id", "stock_name", "buy_date", "buy_type", "reason"])
    write_csv(output / "expanded-pivotal-entries.csv", expanded)
    write_csv(output / "w1-capacity.csv", w1_scored)
    write_csv(output / "w1-null-max.csv", w1_null)
    write_csv(output / "w1-frozen.csv", frozen, INTERACTION_FIELDS)
    write_csv(output / "w2-family.csv", w2_evaluated, INTERACTION_FIELDS)
    write_csv(output / "w2-null-max.csv", w2_null)
    write_csv(output / "w2-confirmed.csv", w2_confirmed, INTERACTION_FIELDS)
    write_csv(output / "w3-final.csv", w3_rows, INTERACTION_FIELDS)
    (output / "synthetic-control.json").write_text(json.dumps(synthetic, indent=2) + "\n")
    quality = {
        "decisionBaseIdentityPassed": True,
        "marketSnapshotHashPassed": True,
        "atomInventoryHashPassed": True,
        "sameMarketDateCollapsed": True,
        "actualAndNullCapacitySymmetric": True,
        "w2FailureReasonRecorded": True,
        "syntheticControlPassed": synthetic["passed"],
        "completionEligible": synthetic["passed"],
    }
    (output / "quality-report.json").write_text(json.dumps(quality, indent=2) + "\n")
    (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    (output / "report.md").write_text(report(summary, final_row), encoding="utf-8")
    (output / ".complete").write_text(run_id + "\n")
    print(output)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
