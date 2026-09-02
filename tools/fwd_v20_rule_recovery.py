#!/usr/bin/env python3
"""Build the label-blind RB01-I01 formal-rule recovery universe."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import sqlite3
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence


STUDY_ID = "FWD-V20-RB01"
RUN_ID = "fwd-v20-rb01-t2s39-20260902"
STAGE = "RB01-I01"
SAMPLES = "ABCDE"
DECISION_BASE_SUFFIX = (
    "-s32-an03-wow-nonbottom-no-ap02-add-penalty-20260901-"
    "t2-s39-48d42e50ada5-fixed3y-20260722-v6"
)
EXPECTED = {
    "dataRuleVersion": "T2/S39",
    "ruleVersion": "s32-an03-wow-nonbottom-no-ap02-add-penalty-20260901",
    "ruleCommit": "48d42e50ada5dcc0ed2e22dffff6871323daf8b7",
    "through": "2026/07/22",
    "formatVersion": 6,
}
PHASE_NAMES = {
    "ADD": "A",
    "GRADE": "G",
    "H_BUY": "H",
    "L_BUY": "L",
    "SELL": "S",
}
PHASE_TARGETS = {
    "H": {
        "positive": "continuation-up > top-then-fall|continuation-down",
        "negative": "top-then-fall|continuation-down > continuation-up",
        "context": "H evaluated; inventory_before=0",
    },
    "L": {
        "positive": "bottom-then-rebound > continuation-down",
        "negative": "continuation-down > bottom-then-rebound",
        "context": "L evaluated after H did not form a buy",
    },
    "S": {
        "positive": "top-then-fall|continuation-down > continuation-up",
        "negative": "continuation-up > top-then-fall|continuation-down",
        "context": "S evaluated; inventory_before>0",
    },
    "A": {
        "positive": "bottom-then-rebound > continuation-down",
        "negative": "continuation-down > bottom-then-rebound",
        "context": "ADD evaluated; inventory_before>0 and no same-day sale",
    },
}

# G1 is deliberately small and mechanical.  These controls use only one frozen
# feature or a two-feature monotone conjunction, with no Grade, date, portfolio,
# prior-trade, shared-cap, OR, or three-feature dependency.
G1_SPECS: dict[str, dict[str, str]] = {
    "H-N02a": {
        "features": "kd_k_z125",
        "shape": "single-low",
        "orientation": "low",
    },
    "H-N03": {
        "features": "osc_z125",
        "shape": "single-low",
        "orientation": "low",
    },
    "H-N10": {
        "features": "volume_is_min9",
        "shape": "binary-true",
        "orientation": "true",
    },
    "L-P02": {
        "features": "kd_j",
        "shape": "single-low",
        "orientation": "low",
    },
    "L-P03": {
        "features": "kd_k_z125|kd_k_z250",
        "shape": "pair-low-low",
        "orientation": "low|low",
    },
    "L-P04": {
        "features": "kd_d_z125|kd_d_z250",
        "shape": "pair-low-low",
        "orientation": "low|low",
    },
    "L-P05": {
        "features": "osc_z125|osc_z250",
        "shape": "pair-low-low",
        "orientation": "low|low",
    },
    "L-N01": {
        "features": "ma20_days",
        "shape": "single-low",
        "orientation": "low",
    },
    "S-P01": {
        "features": "kd_j",
        "shape": "single-high",
        "orientation": "high",
    },
    "S-P02": {
        "features": "kd_j_z125|kd_j_z250",
        "shape": "pair-high-high",
        "orientation": "high|high",
    },
    "S-P03": {
        "features": "kd_k_z125",
        "shape": "single-high",
        "orientation": "high",
    },
    "S-P04": {
        "features": "kd_d_z125",
        "shape": "single-high",
        "orientation": "high",
    },
    "S-P05": {
        "features": "osc_z125|osc_z250",
        "shape": "pair-high-high",
        "orientation": "high|high",
    },
    "A-P06": {
        "features": "ma20_diff_z125|ma60_diff_z125",
        "shape": "pair-low-low",
        "orientation": "low|low",
    },
    "A-P07": {
        "features": "ma20_diff|ma60_diff",
        "shape": "pair-low-low",
        "orientation": "low|low",
    },
}

SHARED_CAP_RULES = {
    "H-N01b": "shares a capped contribution with H-N01a",
    "L-P01a": "shares a capped contribution with L-P01b",
    "L-P01b": "shares a capped contribution with L-P01a",
    "S-N01a": "shares a capped contribution with S-N01b",
    "S-N01b": "shares a capped contribution with S-N01a",
}

CONTEXT_TERMS: tuple[tuple[str, str], ...] = (
    ("Grade", "grade"),
    ("評等", "grade"),
    ("ROI", "unit_roi_before"),
    ("持股", "inventory_before|holding_days_before"),
    ("庫存", "inventory_before"),
    ("適配", "fit_trend_state"),
    ("惡化", "fit_trend_state"),
    ("前次", "prior_trade_state"),
    ("結案", "prior_trade_state"),
    ("投入次數", "invest_times_before"),
    ("simInvestTimes", "invest_times_before"),
    ("wantH", "decision_score"),
    ("wantL", "decision_score"),
    ("wantS", "decision_score"),
    ("aWant", "decision_score"),
    ("月", "trade_date"),
    ("資金", "balance_before"),
    ("冷卻", "days_since_investment"),
    ("tMa60DiffZ125", "ma60_diff_z125"),
    ("tMa20DiffZ125", "ma20_diff_z125"),
    ("tMa20Diff", "ma20_diff"),
    ("tMa60Diff", "ma60_diff"),
    ("tMa20Days", "ma20_days"),
    ("tOscZ125", "osc_z125"),
    ("tKdJZ125", "kd_j_z125"),
    ("tKdKZ125", "kd_k_z125"),
    ("tKdDZ125", "kd_d_z125"),
    ("tHighDiffZ125", "t_high_diff_z125"),
    ("tZ125", "t_z125"),
    ("vZ125", "v_z125"),
    ("九日低", "extreme_min9_flags"),
    ("九日高", "extreme_max9_flags"),
    ("價格位置", "price_position_features"),
    ("高價位置", "t_high_diff_z125"),
    ("低價位置", "t_low_diff_z125"),
    ("均線", "ma20_ma60_features"),
    ("OSC", "osc_features"),
    ("成交量", "volume_features"),
    ("效率分數", "grade_efficiency_score"),
    ("輪次", "roll_rounds_before"),
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, value: Any) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def write_csv(path: Path, fieldnames: Sequence[str], rows: Sequence[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def parse_rule_document(path: Path) -> dict[str, dict[str, Any]]:
    rows: dict[str, dict[str, Any]] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) < 4 or not re.fullmatch(r"[A-Z]-[A-Z][A-Za-z0-9-]*", cells[0]):
            continue
        rows[cells[0]] = {
            "rule_id": cells[0],
            "purpose": cells[1],
            "formal_condition": cells[2],
            "existing_evidence": cells[3],
            "source_line": line_number,
        }
    return rows


def locate_decision_bases(project_root: Path) -> dict[str, Path]:
    decisions_root = project_root / "exports" / "backtest-decision-bases"
    located: dict[str, Path] = {}
    for sample in SAMPLES:
        matches = sorted(decisions_root.glob(f"{sample.lower()}-*{DECISION_BASE_SUFFIX}"))
        require(len(matches) == 1, f"expected one Sample {sample} DecisionBase, found {len(matches)}")
        located[sample] = matches[0]
    return located


def sqlite_schema(connection: sqlite3.Connection, table: str) -> list[dict[str, Any]]:
    return [
        {
            "cid": int(row[0]),
            "name": str(row[1]),
            "type": str(row[2]),
            "notnull": int(row[3]),
            "default": row[4],
            "pk": int(row[5]),
        }
        for row in connection.execute(f"PRAGMA table_info({table})")
    ]


def verify_catalog_inputs(project_root: Path) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    located = locate_decision_bases(project_root)
    canonical: list[dict[str, Any]] | None = None
    canonical_hash: str | None = None
    inputs: dict[str, Any] = {}
    schemas: dict[str, Any] = {}
    for sample, directory in located.items():
        manifest_path = directory / "manifest.json"
        catalog_path = directory / "rule-catalog.json"
        database_path = directory / "decisions.sqlite"
        complete_path = directory / ".complete"
        for path in (manifest_path, catalog_path, database_path, complete_path):
            require(path.is_file(), f"Sample {sample} missing {path.name}")
        manifest = read_json(manifest_path)
        for key, expected in EXPECTED.items():
            require(manifest.get(key) == expected, f"Sample {sample} manifest {key} mismatch")
        require(manifest.get("sampleID") == sample, f"Sample {sample} manifest sample mismatch")
        decision_id = manifest.get("decisionBaseID")
        require(complete_path.read_text(encoding="utf-8").strip() == decision_id, f"Sample {sample} marker mismatch")
        catalog = read_json(catalog_path)
        require(isinstance(catalog, list) and len(catalog) == 91, f"Sample {sample} catalog count mismatch")
        require(len({row["ruleID"] for row in catalog}) == 91, f"Sample {sample} duplicate rule ID")
        catalog_hash = file_hash(catalog_path)
        if canonical is None:
            canonical = catalog
            canonical_hash = catalog_hash
        else:
            require(catalog == canonical, f"Sample {sample} catalog content differs")
            require(catalog_hash == canonical_hash, f"Sample {sample} catalog hash differs")

        connection = sqlite3.connect(f"file:{database_path.resolve().as_posix()}?mode=ro&immutable=1", uri=True)
        try:
            metadata = {str(row[0]): str(row[1]) for row in connection.execute("SELECT key,value FROM metadata")}
            require(metadata.get("decisionBaseID") == decision_id, f"Sample {sample} SQLite ID mismatch")
            require(metadata.get("ruleCommit") == EXPECTED["ruleCommit"], f"Sample {sample} SQLite rule commit mismatch")
            db_rules = [str(row[0]) for row in connection.execute("SELECT rule_id FROM rules ORDER BY rule_id")]
            require(db_rules == sorted(row["ruleID"] for row in catalog), f"Sample {sample} SQLite/catalog rules differ")
            sample_schemas = {
                table: sqlite_schema(connection, table)
                for table in ("rules", "decision_events", "event_votes", "strategy_fit_observations")
            }
        finally:
            connection.close()
        if not schemas:
            schemas = sample_schemas
        else:
            require(sample_schemas == schemas, f"Sample {sample} DecisionBase schema differs")
        inputs[sample] = {
            "decisionBaseID": decision_id,
            "manifest": {"path": str(manifest_path), "sha256": file_hash(manifest_path), "bytes": manifest_path.stat().st_size},
            "ruleCatalog": {"path": str(catalog_path), "sha256": catalog_hash, "bytes": catalog_path.stat().st_size},
            "database": {"path": str(database_path), "sha256": file_hash(database_path), "bytes": database_path.stat().st_size},
            "complete": {"path": str(complete_path), "sha256": file_hash(complete_path), "bytes": complete_path.stat().st_size},
        }
    require(canonical is not None, "no canonical catalog")
    return canonical, {"samples": inputs, "schema": schemas, "catalogSha256": canonical_hash}


def manual_document_entry(rule_id: str, document_rows: dict[str, dict[str, Any]]) -> dict[str, Any]:
    if rule_id == "A-E":
        parts = [document_rows[f"A-E0{index}"] for index in range(1, 5)]
        return {
            "rule_id": rule_id,
            "purpose": "加碼執行資格（A-E01～A-E04）",
            "formal_condition": "；".join(part["formal_condition"] for part in parts),
            "existing_evidence": "；".join(part["existing_evidence"] for part in parts),
            "source_line": min(part["source_line"] for part in parts),
        }
    if rule_id == "S-T02":
        parts = [document_rows[rule] for rule in ("S-T02a", "S-T02b", "S-T02c", "S-T02d")]
        return {
            "rule_id": rule_id,
            "purpose": "長期解套出口（S-T02a～d）",
            "formal_condition": "；".join(part["formal_condition"] for part in parts),
            "existing_evidence": "；".join(part["existing_evidence"] for part in parts),
            "source_line": min(part["source_line"] for part in parts),
        }
    raise KeyError(rule_id)


def vote_direction(rule_id: str, kind: str) -> str:
    if kind != "vote":
        return ""
    if "-P" in rule_id:
        return "positive"
    if "-N" in rule_id:
        return "negative"
    seasonal = {
        "H-C01": "negative",
        "H-C02": "negative",
        "H-C03": "positive",
        "H-C04": "positive",
        "L-C01": "negative",
        "L-C02": "positive",
        "L-C03": "positive",
    }
    require(rule_id in seasonal, f"missing vote direction: {rule_id}")
    return seasonal[rule_id]


def infer_required_fields(condition: str) -> str:
    fields: set[str] = set()
    for term, field_names in CONTEXT_TERMS:
        if term in condition:
            fields.update(field_names.split("|"))
    if re.search(r"\d{1,2}/\d{1,2}", condition):
        fields.add("trade_date")
    if any(token in condition for token in ("none", "weak", "low", "damn", "fine", "high", "wow")):
        fields.add("grade")
    if "MA20" in condition:
        fields.add("ma20_features")
    if "MA60" in condition:
        fields.add("ma60_features")
    for symbol, field_name in (("K", "kd_k_features"), ("D", "kd_d_features"), ("J", "kd_j_features")):
        if re.search(rf"(?<![A-Za-z]){symbol}(?![A-Za-z])", condition):
            fields.add(field_name)
    if "前一完整 TWSE 日" in condition:
        fields.add("previous_trading_day_values")
    if "盤中最高價" in condition:
        fields.add("intraday_high_diff")
    if "收盤相對昨收" in condition:
        fields.add("close_return_1d")
    if "九日波幅" in condition:
        fields.add("rolling_9d_range")
    if "離低點" in condition:
        fields.add("distance_from_low")
    for source_name, field_name in (("tKdK", "kd_k"), ("tKdD", "kd_d"), ("tKdJ", "kd_j")):
        if re.search(rf"{source_name}(?!Z)", condition):
            fields.add(field_name)
    return "|".join(sorted(fields)) or "formal-rule-specific fields"


def infer_complex_shape(rule_id: str, condition: str) -> str:
    if rule_id in SHARED_CAP_RULES:
        return "shared-capped-vote"
    if re.search(r"\d+/\d+|\d+/月|月", condition):
        return "seasonal-or-date-context"
    if "至少" in condition or "任一" in condition or "多項" in condition:
        return "count-or-multi-feature"
    if "或" in condition:
        return "disjunction-or-branched-condition"
    if "Grade" in condition or "評等" in condition or "適配" in condition or "惡化" in condition:
        return "state-conditioned-threshold"
    return "non-G1-context-or-expression"


def exclusion_reason(rule_id: str, kind: str, condition: str) -> str:
    if kind == "gate":
        return "gate or portfolio/execution rule; effectiveness requires simulation counterfactual"
    if rule_id in SHARED_CAP_RULES:
        return SHARED_CAP_RULES[rule_id]
    reasons: list[str] = []
    if "Grade" in condition or "評等" in condition:
        reasons.append("Grade-conditioned")
    if "ROI" in condition or "持股" in condition or "庫存" in condition:
        reasons.append("portfolio-state-conditioned")
    if "適配" in condition or "惡化" in condition or "前次" in condition or "結案" in condition:
        reasons.append("path-state-conditioned")
    if re.search(r"\d+/月|月", condition):
        reasons.append("calendar-conditioned")
    if "或" in condition or "至少" in condition or "多項" in condition:
        reasons.append("not a one-sided or two-feature monotone AND condition")
    return "; ".join(dict.fromkeys(reasons)) or "outside frozen G1 one/two-feature monotone grammar"


def build_universe(
    catalog: list[dict[str, Any]],
    document_rows: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    universe: list[dict[str, Any]] = []
    for catalog_row in sorted(catalog, key=lambda row: row["ruleID"]):
        rule_id = str(catalog_row["ruleID"])
        phase = PHASE_NAMES[str(catalog_row["phase"])]
        kind = str(catalog_row["kind"])
        entry = document_rows.get(rule_id)
        if entry is None:
            entry = manual_document_entry(rule_id, document_rows)
        direction = vote_direction(rule_id, kind)
        if kind == "gate":
            classification = "G3"
            features = infer_required_fields(entry["formal_condition"])
            if features == "formal-rule-specific fields":
                features = "simulation_gate_state"
            shape = "gate"
            orientation = ""
        elif rule_id in G1_SPECS:
            classification = "G1"
            features = G1_SPECS[rule_id]["features"]
            shape = G1_SPECS[rule_id]["shape"]
            orientation = G1_SPECS[rule_id]["orientation"]
        else:
            classification = "G2"
            features = infer_required_fields(entry["formal_condition"])
            shape = infer_complex_shape(rule_id, entry["formal_condition"])
            orientation = "formal-condition-specific"
        target = PHASE_TARGETS.get(phase, {}).get(direction, "")
        context = PHASE_TARGETS.get(phase, {}).get("context", "simulation-only")
        universe.append(
            {
                "rule_id": rule_id,
                "phase": phase,
                "catalog_phase": catalog_row["phase"],
                "kind": kind,
                "description": catalog_row["description"],
                "purpose": entry["purpose"],
                "vote_direction": direction,
                "formal_condition": entry["formal_condition"],
                "required_fields": features,
                "condition_shape": shape,
                "orientation": orientation,
                "required_context": context,
                "expected_path_contrast": target,
                "horizon": "20 formal trading days" if kind == "vote" else "simulation counterfactual",
                "classification": classification,
                "in_generic_recovery_denominator": int(classification == "G1"),
                "in_exact_association_inventory": int(classification in {"G1", "G2"}),
                "exclusion_reason": "" if classification == "G1" else exclusion_reason(rule_id, kind, entry["formal_condition"]),
                "existing_evidence": entry["existing_evidence"],
                "source": f"doc/現行回測規則.md:{entry['source_line']}",
            }
        )
    require(len(universe) == 91, "rule universe count mismatch")
    require(len({row["rule_id"] for row in universe}) == 91, "duplicate universe rule")
    return universe


def target_spec_markdown(universe: list[dict[str, Any]]) -> str:
    classes = Counter(row["classification"] for row in universe)
    g1_phase = Counter(row["phase"] for row in universe if row["classification"] == "G1")
    pair_count = sum(1 for row in universe if row["classification"] == "G1" and row["condition_shape"].startswith("pair-"))
    lines = [
        "# FWD-V20-RB01 phase 目標與控制母體",
        "",
        "## 事前邊界",
        "",
        "- 本檔只來自正式規則目錄、現行條件文件與 DecisionBase schema。",
        "- 本段未讀取路徑標籤、未來報酬、關聯結果、模型排名或虛無比較。",
        "- G1 是未來通用單／二數值搜尋器的固定回收分母；G2 只作正式條件關聯盤點；G3 只能由完整模擬反事實判斷。",
        "",
        "## 數量",
        "",
        f"- 正式規則：{len(universe)} 條。",
        f"- G1：{classes['G1']} 條；G2：{classes['G2']} 條；G3：{classes['G3']} 條。",
        f"- G1 phase：H {g1_phase['H']}、L {g1_phase['L']}、S {g1_phase['S']}、A {g1_phase['A']}。",
        f"- G1 二數值單調 AND 控制：{pair_count} 條。",
        "",
        "## phase 對比",
        "",
        "| phase | 正票預期方向 | 負票預期方向 | 固定情境 |",
        "|---|---|---|---|",
    ]
    for phase in "HLSA":
        spec = PHASE_TARGETS[phase]
        positive = spec["positive"].replace("|", "／")
        negative = spec["negative"].replace("|", "／")
        lines.append(f"| {phase} | {positive} | {negative} | {spec['context']} |")
    lines.extend(
        [
            "",
            "## RB01-I01 容量門檻",
            "",
            "- G1 至少 12 條。",
            "- G1 至少覆蓋 3 個 H／L／S／A phase。",
            "- G1 至少含 3 條二數值控制。",
            "- 本段只凍結分母與排除理由；不授權 RB01-A01。",
            "",
        ]
    )
    return "\n".join(lines)


def run(project_root: Path, output: Path) -> None:
    require(not (output / ".rb01-i01-complete").exists(), "RB01-I01 already complete")
    output.mkdir(parents=True, exist_ok=True)
    progress_path = output / "rb01-i01-progress.json"
    atomic_json(
        progress_path,
        {
            "studyID": STUDY_ID,
            "stage": STAGE,
            "status": "verifying-rule-catalogs",
            "startedAt": datetime.now(timezone.utc).isoformat(),
            "outcomeDataRead": False,
            "holdoutLabelsUsed": False,
        },
    )

    catalog, catalog_inputs = verify_catalog_inputs(project_root)
    document_path = project_root / "doc" / "現行回測規則.md"
    technical_path = project_root / "doc" / "技術數值與研究原則.md"
    decision_path = project_root / "doc" / "回測決策旁錄與差異資料設計.md"
    for path in (document_path, technical_path, decision_path):
        require(path.is_file(), f"missing authority document: {path}")
    document_rows = parse_rule_document(document_path)
    universe = build_universe(catalog, document_rows)

    rule_fields = [
        "rule_id", "phase", "catalog_phase", "kind", "description", "purpose",
        "vote_direction", "formal_condition", "required_fields", "condition_shape",
        "orientation", "required_context", "expected_path_contrast", "horizon",
        "classification", "in_generic_recovery_denominator",
        "in_exact_association_inventory", "exclusion_reason", "existing_evidence", "source",
    ]
    write_csv(output / "rule-universe.csv", rule_fields, universe)
    controls = [row for row in universe if row["classification"] in {"G1", "G2"}]
    write_csv(output / "control-map.csv", rule_fields, controls)

    exclusions: list[dict[str, Any]] = []
    grouped: Counter[tuple[str, str, str]] = Counter()
    for row in universe:
        grouped[(row["classification"], row["phase"], row["exclusion_reason"])] += 1
    for (classification, phase, reason), count in sorted(grouped.items()):
        exclusions.append(
            {
                "classification": classification,
                "phase": phase,
                "count": count,
                "reason": reason or "included in generic recovery denominator",
            }
        )
    write_csv(
        output / "exclusion-summary.csv",
        ["classification", "phase", "count", "reason"],
        exclusions,
    )
    (output / "target-spec.md").write_text(target_spec_markdown(universe), encoding="utf-8")

    classes = Counter(row["classification"] for row in universe)
    kinds = Counter(row["kind"] for row in universe)
    g1_phase = Counter(row["phase"] for row in universe if row["classification"] == "G1")
    g1_pairs = sum(
        1
        for row in universe
        if row["classification"] == "G1" and row["condition_shape"].startswith("pair-")
    )
    gates = {
        "minimumG1": 12,
        "minimumRepresentedPhases": 3,
        "minimumG1Pairs": 3,
    }
    represented_phases = sum(1 for phase in "HLSA" if g1_phase[phase] > 0)
    gate_passed = (
        classes["G1"] >= gates["minimumG1"]
        and represented_phases >= gates["minimumRepresentedPhases"]
        and g1_pairs >= gates["minimumG1Pairs"]
    )
    quality = {
        "studyID": STUDY_ID,
        "stage": STAGE,
        "status": "complete",
        "ruleCount": len(universe),
        "voteRules": kinds["vote"],
        "gateRules": kinds["gate"],
        "classificationCounts": dict(sorted(classes.items())),
        "g1ByPhase": {phase: g1_phase[phase] for phase in "HLSA"},
        "g1PairControls": g1_pairs,
        "representedPhases": represented_phases,
        "capacityGate": gates,
        "capacityGatePassed": gate_passed,
        "catalogsIdentical": True,
        "outcomeDataRead": False,
        "holdoutLabelsUsed": False,
    }
    atomic_json(output / "data-quality.json", quality)
    report = (
        "# FWD-V20-RB01 / RB01-I01 規則母體盤點\n\n"
        "## 結論\n\n"
        f"- 五份 DecisionBase v6 的 91 條正式目錄內容與雜湊一致。\n"
        f"- 66 條投票規則分為 G1 {classes['G1']} 條、G2 {classes['G2']} 條；25 條 gate 全部分為 G3。\n"
        f"- G1 依 phase 為 H {g1_phase['H']}、L {g1_phase['L']}、S {g1_phase['S']}、A {g1_phase['A']}；其中二數值單調 AND 控制 {g1_pairs} 條。\n"
        f"- RB01-I01 容量門檻：{'\u901a過' if gate_passed else '\u672a通過'}。\n"
        "- `L-P03／L-P04／L-P05` 已全數列入 G1，不再手動挑兩條。\n"
        "- 本段未讀取任何路徑標籤、未來報酬、關聯結果、模型排名或虛無比較。\n\n"
        "## 後續邊界\n\n"
        "通過容量門檻只代表正向控制母體足夠建立資格考，不代表這些規則已在 20 日路徑中被辨識，也不授權 `RB01-A01`。\n"
    )
    (output / "report.md").write_text(report, encoding="utf-8")
    (output / ".rb01-i01-complete").write_text(STUDY_ID + "\n", encoding="utf-8")
    atomic_json(
        progress_path,
        {
            "studyID": STUDY_ID,
            "stage": STAGE,
            "status": "complete",
            "completedAt": datetime.now(timezone.utc).isoformat(),
            "rules": len(universe),
            "g1": classes["G1"],
            "g2": classes["G2"],
            "g3": classes["G3"],
            "capacityGatePassed": gate_passed,
            "outcomeDataRead": False,
            "holdoutLabelsUsed": False,
        },
    )

    authority_inputs = {
        str(path.relative_to(project_root)): {
            "sha256": file_hash(path),
            "bytes": path.stat().st_size,
        }
        for path in (document_path, technical_path, decision_path)
    }
    tool_path = Path(__file__).resolve()
    manifest = {
        "studyID": STUDY_ID,
        "runID": RUN_ID,
        "stage": STAGE,
        "status": "complete",
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "expected": EXPECTED,
        "inputs": {
            "authorityDocuments": authority_inputs,
            "decisionBases": catalog_inputs,
        },
        "classification": quality,
        "tool": {
            "path": str(tool_path.relative_to(project_root)),
            "sha256": file_hash(tool_path),
        },
        "outputs": {
            path.name: {"sha256": file_hash(path), "bytes": path.stat().st_size}
            for path in sorted(output.iterdir())
            if path.is_file() and path.name != "manifest.json"
        },
    }
    atomic_json(output / "manifest.json", manifest)
    print(
        f"{STAGE} complete: rules={len(universe)}, G1={classes['G1']}, "
        f"G2={classes['G2']}, G3={classes['G3']}, pairs={g1_pairs}, "
        f"capacity_gate={'pass' if gate_passed else 'fail'}"
    )


def self_test() -> None:
    require(vote_direction("H-P01", "vote") == "positive", "positive direction test failed")
    require(vote_direction("S-N01a", "vote") == "negative", "negative direction test failed")
    require(vote_direction("H-C03", "vote") == "positive", "seasonal direction test failed")
    require(infer_complex_shape("L-P01a", "J 進低檔") == "shared-capped-vote", "shared cap test failed")
    require("grade" in infer_required_fields("Grade 為 low"), "field inference test failed")
    require(infer_required_fields("8/1～8/31 +1") == "trade_date", "date inference test failed")
    require(
        infer_required_fields("MA60、MA20 差都高於 0（fine／high）")
        == "grade|ma20_features|ma60_features",
        "MA/Grade inference test failed",
    )
    require(len(G1_SPECS) == 15, "unexpected G1 specification count")
    require(sum(1 for spec in G1_SPECS.values() if spec["shape"].startswith("pair-")) == 7, "pair count test failed")
    print("self-test: ok")


def main() -> None:
    args = arguments()
    if args.self_test:
        self_test()
        return
    project_root = args.project_root.resolve()
    output = args.output.resolve() if args.output else project_root / "exports" / "future-path-study" / RUN_ID
    run(project_root, output)


if __name__ == "__main__":
    main()
