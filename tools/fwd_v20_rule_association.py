#!/usr/bin/env python3
"""Run RB01-A01 exact formal-rule/path association qualification."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import platform
import sqlite3
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Sequence

import numpy as np
import pandas as pd
import sklearn
from sklearn.model_selection import GroupKFold


STUDY_ID = "FWD-V20-RB01"
RUN_ID = "fwd-v20-rb01-t2s39-20260902"
STAGE = "RB01-A01"
SAMPLES = ("A", "B", "C")
WINDOWS = (1, 2)
FOLDS = 3
NULL_RUNS = 100
MIN_TRIGGER_EPISODES = 30
MIN_NONTRIGGER_EPISODES = 30
MIN_TRIGGER_GROUPS = 10

PHASE_CODES = {"H": 1, "L": 2, "S": 3, "A": 4}
PHASE_LABEL_SIGNAL = {
    "H": {
        "continuation-up": 1.0,
        "top-then-fall": -1.0,
        "continuation-down": -1.0,
    },
    "L": {"bottom-then-rebound": 1.0, "continuation-down": -1.0},
    "S": {
        "top-then-fall": 1.0,
        "continuation-down": 1.0,
        "continuation-up": -1.0,
    },
    "A": {"bottom-then-rebound": 1.0, "continuation-down": -1.0},
}

Predicate = Callable[[pd.DataFrame], pd.Series]


def _lt(column: str, threshold: float) -> Predicate:
    return lambda frame: frame[column] < threshold


def _gt(column: str, threshold: float) -> Predicate:
    return lambda frame: frame[column] > threshold


def _and(left: Predicate, right: Predicate) -> Predicate:
    return lambda frame: left(frame) & right(frame)


G1_PREDICATES: dict[str, tuple[tuple[str, ...], Predicate]] = {
    "A-P06": (
        ("ma20_diff_z125", "ma60_diff_z125"),
        _and(_lt("ma20_diff_z125", -2.5), _lt("ma60_diff_z125", -2.8)),
    ),
    "A-P07": (
        ("ma20_diff", "ma60_diff"),
        _and(_lt("ma20_diff", -8.0), _lt("ma60_diff", -8.0)),
    ),
    "H-N02a": (("kd_k_z125",), _lt("kd_k_z125", -0.8)),
    "H-N03": (("osc_z125",), _lt("osc_z125", -0.5)),
    "H-N10": (("volume_is_min9",), lambda frame: frame["volume_is_min9"] == 1.0),
    "L-N01": (("ma20_days",), _lt("ma20_days", -20.0)),
    "L-P02": (("kd_j",), _lt("kd_j", -7.0)),
    "L-P03": (
        ("kd_k_z125", "kd_k_z250"),
        _and(_lt("kd_k_z125", -0.9), _lt("kd_k_z250", -0.9)),
    ),
    "L-P04": (
        ("kd_d_z125", "kd_d_z250"),
        _and(_lt("kd_d_z125", -0.9), _lt("kd_d_z250", -0.9)),
    ),
    "L-P05": (
        ("osc_z125", "osc_z250"),
        _and(_lt("osc_z125", -0.9), _lt("osc_z250", -0.9)),
    ),
    "S-P01": (("kd_j",), _gt("kd_j", 101.0)),
    "S-P02": (
        ("kd_j_z125", "kd_j_z250"),
        _and(_gt("kd_j_z125", 1.0), _gt("kd_j_z250", 1.0)),
    ),
    "S-P03": (("kd_k_z125",), _gt("kd_k_z125", 0.9)),
    "S-P04": (("kd_d_z125",), _gt("kd_d_z125", 0.9)),
    "S-P05": (
        ("osc_z125", "osc_z250"),
        _and(_gt("osc_z125", 0.9), _gt("osc_z250", 0.9)),
    ),
}


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-root", type=Path, default=Path(__file__).resolve().parents[1]
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path: Path) -> dict[str, Any]:
    return {"sha256": file_hash(path), "bytes": path.stat().st_size}


def atomic_json(path: Path, value: Any) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    os.replace(temporary, path)


def write_csv(path: Path, fieldnames: Sequence[str], rows: Sequence[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def verify_record(path: Path, record: dict[str, Any], label: str) -> None:
    require(path.is_file(), f"missing {label}: {path}")
    if "bytes" in record:
        require(path.stat().st_size == int(record["bytes"]), f"size drift: {label}")
    require(file_hash(path) == record["sha256"], f"hash drift: {label}")


def update_progress(path: Path, phase: str, detail: str) -> None:
    atomic_json(
        path,
        {
            "studyID": STUDY_ID,
            "runID": RUN_ID,
            "stage": STAGE,
            "phase": phase,
            "detail": detail,
            "updatedAt": now(),
        },
    )


def load_control_map(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    controls = [row for row in rows if row["classification"] in {"G1", "G2"}]
    require(len(controls) == 66, f"expected 66 controls, found {len(controls)}")
    g1 = {row["rule_id"] for row in controls if row["classification"] == "G1"}
    require(g1 == set(G1_PREDICATES), f"G1 predicate inventory drift: {sorted(g1 ^ set(G1_PREDICATES))}")
    require(all(row["vote_direction"] in {"positive", "negative"} for row in controls), "missing vote direction")
    return controls


def load_eligible_keys(path: Path) -> pd.DataFrame:
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    with path.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            if (
                row["role"] != "discovery"
                or row["sample"] not in SAMPLES
                or int(row["window_id"]) not in WINDOWS
            ):
                continue
            require(row["row_id"] not in seen, f"duplicate eligible row_id {row['row_id']}")
            seen.add(row["row_id"])
            rows.append(
                {
                    "row_id": row["row_id"],
                    "sample": row["sample"],
                    "window_id": int(row["window_id"]),
                    "stock_id": str(row["stock_id"]),
                    "stock_name": row["stock_name"],
                    "group_name": row["group_name"],
                    "trade_date": int(row["trade_date"]),
                    "future_20_date": int(row["future_20_date"]),
                }
            )
    require(rows, "no eligible A-C window 1-2 discovery keys")
    frame = pd.DataFrame(rows)
    frame["group"] = (
        frame["sample"] + ":" + frame["stock_id"] + ":W" + frame["window_id"].astype(str)
    )
    frame = frame.sort_values(["group", "trade_date"], kind="stable").reset_index(drop=True)
    frame["ordinal"] = frame.groupby("group", sort=False).cumcount().astype(np.int32)
    require(
        not frame.duplicated(["sample", "window_id", "stock_id", "trade_date"]).any(),
        "duplicate eligible date key",
    )
    return frame


def load_sealed_labels(path: Path, eligible_keys: set[tuple[str, int, str, int]]) -> dict[tuple[str, int, str, int], str]:
    labels: dict[tuple[str, int, str, int], str] = {}
    with path.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            sample = row["sample"]
            window = int(row["window_id"])
            if sample not in SAMPLES or window not in WINDOWS or row["role"] != "discovery":
                continue
            key = (sample, window, str(row["stock_id"]), int(row["trade_date"]))
            if key not in eligible_keys:
                continue
            require(key not in labels, f"duplicate eligible label key {key}")
            # The label field is intentionally accessed only after the sealed
            # Sample/window/role/key filters above have passed.
            labels[key] = row["label"]
    return labels


def load_features(path: Path, eligible: pd.DataFrame) -> pd.DataFrame:
    columns = sorted({column for columns, _ in G1_PREDICATES.values() for column in columns})
    features = pd.read_csv(path, usecols=["row_id", *columns])
    features = features[features["row_id"].isin(set(eligible["row_id"]))]
    require(len(features) == len(eligible), "eligible feature rows are missing or duplicated")
    require(not features["row_id"].duplicated().any(), "duplicate feature row_id")
    require(not features[columns].isna().any().any(), "G1 feature contains missing value")
    return eligible.merge(features, on="row_id", how="left", validate="one_to_one")


def load_decision_events(
    sample: str,
    database: Path,
    control_ids: set[str],
) -> tuple[pd.DataFrame, pd.DataFrame]:
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    try:
        events = pd.read_sql_query(
            """
            SELECT e.event_id, e.window_id, s.stock_id, e.trade_date, e.phase,
                   e.grade, e.decision_score, e.inventory_before
            FROM decision_events e
            JOIN stocks s ON s.stock_key = e.stock_key
            WHERE e.window_id IN (1, 2) AND e.phase IN (1, 2, 3, 4)
            """,
            connection,
        )
        votes = pd.read_sql_query(
            """
            SELECT v.event_id, r.rule_id, v.contribution
            FROM event_votes v
            JOIN rules r ON r.rule_key = v.rule_key
            JOIN decision_events e ON e.event_id = v.event_id
            WHERE e.window_id IN (1, 2) AND e.phase IN (1, 2, 3, 4)
            """,
            connection,
        )
    finally:
        connection.close()
    events.insert(0, "sample", sample)
    events["stock_id"] = events["stock_id"].astype(str)
    events["window_id"] = events["window_id"].astype(int)
    events["trade_date"] = events["trade_date"].astype(int)
    votes = votes[votes["rule_id"].isin(control_ids)].copy()
    votes.insert(0, "sample", sample)
    require(not votes.duplicated(["event_id", "rule_id"]).any(), f"duplicate event vote in Sample {sample}")
    return events, votes


def phase_context(frame: pd.DataFrame, phase: str) -> pd.Series:
    phase_match = frame["phase"] == PHASE_CODES[phase]
    if phase in {"H", "L"}:
        return phase_match & (frame["inventory_before"] == 0.0)
    return phase_match & (frame["inventory_before"] > 0.0)


def fold_map(groups: pd.Series) -> dict[str, int]:
    values = groups.astype(str).to_numpy()
    require(len(set(values)) >= FOLDS, "fewer groups than folds")
    result: dict[str, int] = {}
    splitter = GroupKFold(n_splits=FOLDS)
    for fold, (_, test) in enumerate(splitter.split(np.zeros(len(values)), groups=values)):
        for group in set(values[test]):
            require(group not in result, f"group assigned twice: {group}")
            result[group] = fold
    require(set(result) == set(values), "not all groups assigned to folds")
    return result


def episode_entries(frame: pd.DataFrame, trigger: np.ndarray) -> pd.DataFrame:
    require(len(frame) == len(trigger), "trigger length mismatch")
    groups = frame["group"].astype(str).to_numpy()
    ordinals = frame["ordinal"].to_numpy(dtype=np.int64)
    boundary = np.ones(len(frame), dtype=bool)
    if len(frame) > 1:
        boundary[1:] = (groups[1:] != groups[:-1]) | (ordinals[1:] != ordinals[:-1] + 1)
    changed = np.zeros(len(frame), dtype=bool)
    if len(frame) > 1:
        changed[1:] = (~boundary[1:]) & (trigger[1:] != trigger[:-1])
    entries = boundary | changed
    episodes = frame.loc[entries].copy()
    episodes["trigger"] = trigger[entries].astype(np.int8)
    return episodes


def effect(episodes: pd.DataFrame, signal_column: str = "signal") -> float:
    triggered = episodes.loc[episodes["trigger"] == 1, signal_column]
    nontriggered = episodes.loc[episodes["trigger"] == 0, signal_column]
    if triggered.empty or nontriggered.empty:
        return math.nan
    return float(triggered.mean() - nontriggered.mean())


def deterministic_shift(rule_id: str, run: int, group: str, length: int) -> int:
    digest = hashlib.sha256(f"{STUDY_ID}|{RUN_ID}|{rule_id}|{run}|{group}".encode()).digest()
    return int.from_bytes(digest[:8], "big") % length


def null_effects(frame: pd.DataFrame, episodes: pd.DataFrame, rule_id: str) -> list[float]:
    by_group: dict[str, tuple[np.ndarray, np.ndarray, np.ndarray]] = {}
    for group, subset in frame.groupby("group", sort=True):
        indexes = subset.index.to_numpy()
        require(np.all(indexes == np.arange(indexes[0], indexes[0] + len(indexes))), "group rows are not contiguous")
        group_episodes = episodes.loc[episodes["group"] == group]
        positions = group_episodes.index.to_numpy() - indexes[0]
        by_group[str(group)] = (
            subset["signal"].to_numpy(dtype=float),
            positions,
            group_episodes["trigger"].to_numpy(dtype=bool),
        )
    results: list[float] = []
    for run in range(NULL_RUNS):
        trigger_sum = nontrigger_sum = 0.0
        trigger_count = nontrigger_count = 0
        for group, (values, positions, trigger) in by_group.items():
            amount = deterministic_shift(rule_id, run, group, len(values))
            shifted_entries = values[(positions - amount) % len(values)]
            trigger_sum += float(shifted_entries[trigger].sum())
            nontrigger_sum += float(shifted_entries[~trigger].sum())
            trigger_count += int(trigger.sum())
            nontrigger_count += int((~trigger).sum())
        results.append(
            trigger_sum / trigger_count - nontrigger_sum / nontrigger_count
            if trigger_count and nontrigger_count
            else math.nan
        )
    return results


def matched_summary(episodes: pd.DataFrame) -> dict[str, Any]:
    matched: list[tuple[int, float]] = []
    trigger_count = nontrigger_count = 0
    strata = 0
    columns = ["sample", "window_id", "grade", "inventory_state", "pre_rule_score"]
    for _, subset in episodes.groupby(columns, dropna=False, sort=False):
        trigger = subset.loc[subset["trigger"] == 1, "signal"]
        nontrigger = subset.loc[subset["trigger"] == 0, "signal"]
        if trigger.empty or nontrigger.empty:
            continue
        weight = min(len(trigger), len(nontrigger))
        matched.append((weight, float(trigger.mean() - nontrigger.mean())))
        trigger_count += len(trigger)
        nontrigger_count += len(nontrigger)
        strata += 1
    weight_sum = sum(weight for weight, _ in matched)
    matched_effect = (
        sum(weight * value for weight, value in matched) / weight_sum if weight_sum else math.nan
    )
    return {
        "matched_strata": strata,
        "matched_trigger_episodes": trigger_count,
        "matched_nontrigger_episodes": nontrigger_count,
        "matched_weight": weight_sum,
        "matched_effect": matched_effect,
    }


def clean_number(value: Any) -> Any:
    if isinstance(value, (float, np.floating)) and (math.isnan(float(value)) or math.isinf(float(value))):
        return ""
    if isinstance(value, np.generic):
        return value.item()
    return value


def self_test() -> None:
    frame = pd.DataFrame(
        {
            "kd_k_z125": [-1.0, 0.0, -1.0, -1.0],
            "osc_z125": [0.0] * 4,
            "volume_is_min9": [0.0] * 4,
            "ma20_diff_z125": [0.0] * 4,
            "ma60_diff_z125": [0.0] * 4,
            "ma20_diff": [0.0] * 4,
            "ma60_diff": [0.0] * 4,
            "ma20_days": [0.0] * 4,
            "kd_j": [0.0] * 4,
            "kd_k_z250": [0.0] * 4,
            "kd_d_z125": [0.0] * 4,
            "kd_d_z250": [0.0] * 4,
            "osc_z250": [0.0] * 4,
            "kd_j_z125": [0.0] * 4,
            "kd_j_z250": [0.0] * 4,
            "group": ["a", "a", "a", "b"],
            "ordinal": [0, 1, 2, 0],
            "signal": [1.0, 0.0, -1.0, 1.0],
        }
    )
    trigger = G1_PREDICATES["H-N02a"][1](frame).to_numpy(dtype=bool)
    require(trigger.tolist() == [True, False, True, True], "predicate self-test failed")
    episodes = episode_entries(frame, trigger)
    require(episodes["trigger"].tolist() == [1, 0, 1, 1], "episode self-test failed")
    require(PHASE_LABEL_SIGNAL["H"]["continuation-up"] == 1.0, "signal self-test failed")
    print("self-test passed")


def main() -> None:
    args = arguments()
    if args.self_test:
        self_test()
        return

    project_root = args.project_root.resolve()
    output = (args.output or project_root / "exports/future-path-study" / RUN_ID).resolve()
    output.mkdir(parents=True, exist_ok=True)
    progress_path = output / "rb01-a01-progress.json"
    complete_path = output / ".rb01-a01-complete"
    if complete_path.exists():
        complete_path.unlink()
    update_progress(progress_path, "verify-inputs", "verifying frozen I01, M01, and A-C DecisionBase inputs")

    i01_manifest_path = output / "manifest.json"
    i01_manifest = read_json(i01_manifest_path)
    require(i01_manifest["stage"] == "RB01-I01" and i01_manifest["status"] == "complete", "I01 is not complete")
    for relative, record in i01_manifest["outputs"].items():
        verify_record(output / relative, record, f"I01 output {relative}")
    verify_record(project_root / i01_manifest["tool"]["path"], i01_manifest["tool"], "I01 tool")

    m01 = project_root / "exports/future-path-study/fwd-v20-m01-abcde-t2s39-20260902"
    m01_manifest_path = m01 / "manifest.json"
    m01_manifest = read_json(m01_manifest_path)
    frozen_names = ("feature-keys.csv", "features.csv", "path-labels.csv")
    for name in frozen_names:
        verify_record(m01 / name, m01_manifest["outputs"][name], f"M01 {name}")

    controls = load_control_map(output / "control-map.csv")
    control_ids = {row["rule_id"] for row in controls}
    database_records: dict[str, dict[str, Any]] = {}
    for sample in SAMPLES:
        record = i01_manifest["inputs"]["decisionBases"]["samples"][sample]["database"]
        database = Path(record["path"])
        verify_record(database, record, f"Sample {sample} DecisionBase")
        database_records[sample] = record

    update_progress(progress_path, "load-frozen-data", "loading only A-C window 1-2 discovery rows")
    eligible = load_eligible_keys(m01 / "feature-keys.csv")
    eligible_key_set = {
        (row.sample, int(row.window_id), str(row.stock_id), int(row.trade_date))
        for row in eligible.itertuples()
    }
    labels = load_sealed_labels(m01 / "path-labels.csv", eligible_key_set)
    require(len(labels) == len(eligible), f"eligible label count mismatch: {len(labels)} vs {len(eligible)}")
    eligible["label"] = [
        labels[(row.sample, int(row.window_id), str(row.stock_id), int(row.trade_date))]
        for row in eligible.itertuples()
    ]
    eligible = load_features(m01 / "features.csv", eligible)

    update_progress(progress_path, "load-events", "joining A-C formal decision events and votes")
    event_frames: list[pd.DataFrame] = []
    vote_frames: list[pd.DataFrame] = []
    for sample in SAMPLES:
        events, votes = load_decision_events(sample, Path(database_records[sample]["path"]), control_ids)
        event_frames.append(events)
        vote_frames.append(votes)
    all_events = pd.concat(event_frames, ignore_index=True)
    all_votes = pd.concat(vote_frames, ignore_index=True)
    vote_lookup = {
        (row.sample, int(row.event_id), row.rule_id): float(row.contribution)
        for row in all_votes.itertuples()
    }

    join_columns = ["sample", "window_id", "stock_id", "trade_date"]
    merged = all_events.merge(eligible, on=join_columns, how="inner", validate="many_to_one")
    require(
        not merged.duplicated(["sample", "event_id"]).any(),
        "DecisionBase event_id duplicated after frozen-row join",
    )

    phase_frames: dict[str, pd.DataFrame] = {}
    for phase in PHASE_CODES:
        frame = merged.loc[phase_context(merged, phase)].copy()
        require(len(frame) > 0, f"no eligible {phase} events")
        require(
            not frame.duplicated(["sample", "window_id", "stock_id", "trade_date"]).any(),
            f"duplicate eligible {phase} event date",
        )
        frame["group"] = frame["group"].astype(str)
        frame = frame.sort_values(["group", "ordinal"], kind="stable").reset_index(drop=True)
        mapping = fold_map(frame["group"])
        frame["fold"] = frame["group"].map(mapping).astype(np.int8)
        frame["base_signal"] = frame["label"].map(PHASE_LABEL_SIGNAL[phase]).fillna(0.0)
        phase_frames[phase] = frame

    update_progress(progress_path, "reconstruct", "checking all 15 G1 predicates against formal event votes")
    reconstruction_rows: list[dict[str, Any]] = []
    triggers: dict[str, np.ndarray] = {}
    contributions: dict[str, np.ndarray] = {}
    g1_mismatches = 0
    for control in controls:
        rule_id = control["rule_id"]
        phase = control["phase"]
        frame = phase_frames[phase]
        official = np.array(
            [(row.sample, int(row.event_id), rule_id) in vote_lookup for row in frame.itertuples()],
            dtype=bool,
        )
        contribution = np.array(
            [vote_lookup.get((row.sample, int(row.event_id), rule_id), 0.0) for row in frame.itertuples()],
            dtype=float,
        )
        contributions[rule_id] = contribution
        if control["classification"] == "G1":
            reconstructed = G1_PREDICATES[rule_id][1](frame).fillna(False).to_numpy(dtype=bool)
            false_positive = int(np.sum(reconstructed & ~official))
            false_negative = int(np.sum(~reconstructed & official))
            mismatch = false_positive + false_negative
            g1_mismatches += mismatch
            triggers[rule_id] = reconstructed
            reconstruction_rows.append(
                {
                    "rule_id": rule_id,
                    "classification": "G1",
                    "phase": phase,
                    "mode": "frozen-feature-reconstruction",
                    "eligible_events": len(frame),
                    "official_trigger_events": int(official.sum()),
                    "reconstructed_trigger_events": int(reconstructed.sum()),
                    "false_positive": false_positive,
                    "false_negative": false_negative,
                    "mismatches": mismatch,
                    "status": "aligned" if mismatch == 0 else "mismatch",
                }
            )
        else:
            triggers[rule_id] = official
            reconstruction_rows.append(
                {
                    "rule_id": rule_id,
                    "classification": "G2",
                    "phase": phase,
                    "mode": "formal-event-vote-authority",
                    "eligible_events": len(frame),
                    "official_trigger_events": int(official.sum()),
                    "reconstructed_trigger_events": "",
                    "false_positive": "",
                    "false_negative": "",
                    "mismatches": "",
                    "status": "authority-used",
                }
            )

    write_csv(
        output / "rule-event-reconstruction.csv",
        list(reconstruction_rows[0]),
        reconstruction_rows,
    )
    require(g1_mismatches == 0, f"G1 reconstruction mismatch count is {g1_mismatches}; statistical analysis stopped")

    update_progress(progress_path, "associate", "running 3-fold effects and 100 within-group circular-shift nulls")
    association_rows: list[dict[str, Any]] = []
    fold_rows: list[dict[str, Any]] = []
    null_rows: list[dict[str, Any]] = []
    matched_rows: list[dict[str, Any]] = []
    for number, control in enumerate(controls, start=1):
        rule_id = control["rule_id"]
        phase = control["phase"]
        frame = phase_frames[phase].copy()
        direction = 1.0 if control["vote_direction"] == "positive" else -1.0
        frame["signal"] = frame["base_signal"] * direction
        frame["contribution"] = contributions[rule_id]
        frame["pre_rule_score"] = (frame["decision_score"] - frame["contribution"]).round(8)
        frame["inventory_state"] = np.where(frame["inventory_before"] > 0.0, "held", "flat")
        episodes = episode_entries(frame, triggers[rule_id])
        trigger_episodes = int((episodes["trigger"] == 1).sum())
        nontrigger_episodes = int((episodes["trigger"] == 0).sum())
        trigger_groups = int(episodes.loc[episodes["trigger"] == 1, "group"].nunique())
        capacity = (
            trigger_episodes >= MIN_TRIGGER_EPISODES
            and nontrigger_episodes >= MIN_NONTRIGGER_EPISODES
            and trigger_groups >= MIN_TRIGGER_GROUPS
        )
        fold_effects: list[float] = []
        for fold in range(FOLDS):
            subset = episodes.loc[episodes["fold"] == fold]
            fold_effect = effect(subset)
            fold_effects.append(fold_effect)
            fold_rows.append(
                {
                    "rule_id": rule_id,
                    "classification": control["classification"],
                    "phase": phase,
                    "fold": fold,
                    "test_groups": subset["group"].nunique(),
                    "trigger_episodes": int((subset["trigger"] == 1).sum()),
                    "nontrigger_episodes": int((subset["trigger"] == 0).sum()),
                    "effect": clean_number(fold_effect),
                    "expected_direction": int(math.isfinite(fold_effect) and fold_effect > 0.0),
                }
            )
        pooled_effect = effect(episodes)
        null_values = null_effects(frame, episodes, rule_id)
        finite_null = np.array([value for value in null_values if math.isfinite(value)])
        null_p95 = float(np.quantile(finite_null, 0.95)) if len(finite_null) else math.nan
        for run, value in enumerate(null_values):
            null_rows.append(
                {
                    "rule_id": rule_id,
                    "classification": control["classification"],
                    "phase": phase,
                    "null_run": run,
                    "effect": clean_number(value),
                }
            )
        same_direction_folds = sum(math.isfinite(value) and value > 0.0 for value in fold_effects)
        recognized = bool(
            capacity
            and same_direction_folds >= 2
            and math.isfinite(pooled_effect)
            and pooled_effect > 0.0
            and math.isfinite(null_p95)
            and pooled_effect > null_p95
        )
        matched = matched_summary(episodes)
        matched_rows.append(
            {
                "rule_id": rule_id,
                "classification": control["classification"],
                "phase": phase,
                **{key: clean_number(value) for key, value in matched.items()},
                "weighting": "minimum trigger/nontrigger episode count per exact stratum",
            }
        )
        association_rows.append(
            {
                "rule_id": rule_id,
                "classification": control["classification"],
                "phase": phase,
                "vote_direction": control["vote_direction"],
                "condition_shape": control["condition_shape"],
                "trigger_source": (
                    "frozen-feature-reconstruction"
                    if control["classification"] == "G1"
                    else "formal-event-vote-authority"
                ),
                "eligible_events": len(frame),
                "trigger_episodes": trigger_episodes,
                "nontrigger_episodes": nontrigger_episodes,
                "trigger_groups": trigger_groups,
                "capacity": int(capacity),
                "same_direction_folds": same_direction_folds,
                "pooled_effect": clean_number(pooled_effect),
                "null_p95": clean_number(null_p95),
                "recognized": int(recognized),
            }
        )
        update_progress(progress_path, "associate", f"completed {number}/{len(controls)} rules ({rule_id})")

    write_csv(output / "exact-control-association.csv", list(association_rows[0]), association_rows)
    write_csv(output / "exact-control-folds.csv", list(fold_rows[0]), fold_rows)
    write_csv(output / "exact-control-null.csv", list(null_rows[0]), null_rows)
    write_csv(output / "exact-control-matched.csv", list(matched_rows[0]), matched_rows)

    g1_rows = [row for row in association_rows if row["classification"] == "G1"]
    g1_total = len(g1_rows)
    g1_recognized = sum(int(row["recognized"]) for row in g1_rows)
    overall_required = math.ceil(g1_total * 2 / 3)
    phase_gates: list[dict[str, Any]] = []
    for phase in PHASE_CODES:
        rows = [row for row in g1_rows if row["phase"] == phase]
        if len(rows) < 3:
            continue
        recognized = sum(int(row["recognized"]) for row in rows)
        required = max(2, math.ceil(len(rows) / 2))
        phase_gates.append(
            {"phase": phase, "total": len(rows), "recognized": recognized, "required": required, "passed": recognized >= required}
        )
    pair_rows = [row for row in g1_rows if row["condition_shape"].startswith("pair-")]
    pair_required = math.ceil(len(pair_rows) * 2 / 3) if len(pair_rows) >= 3 else 0
    pair_recognized = sum(int(row["recognized"]) for row in pair_rows)
    passed = bool(
        g1_recognized >= overall_required
        and all(row["passed"] for row in phase_gates)
        and (len(pair_rows) < 3 or pair_recognized >= pair_required)
    )

    quality = {
        "studyID": STUDY_ID,
        "runID": RUN_ID,
        "stage": STAGE,
        "status": "passed" if passed else "failed",
        "scope": {"samples": list(SAMPLES), "windows": list(WINDOWS), "role": "discovery"},
        "sealedHoldouts": {"sampleABCWindow3": "not used", "samplesDE": "not used", "holdoutLabelsUsed": False},
        "eligibleRows": len(eligible),
        "eligibleGroups": eligible["group"].nunique(),
        "labelCounts": dict(Counter(eligible["label"])),
        "phaseEventCounts": {phase: len(frame) for phase, frame in phase_frames.items()},
        "phaseGroupCounts": {phase: frame["group"].nunique() for phase, frame in phase_frames.items()},
        "g1ReconstructionMismatches": g1_mismatches,
        "g1": {"total": g1_total, "recognized": g1_recognized, "required": overall_required},
        "phaseGates": phase_gates,
        "pairGate": {"total": len(pair_rows), "recognized": pair_recognized, "required": pair_required, "passed": pair_recognized >= pair_required},
        "g2": {
            "total": sum(row["classification"] == "G2" for row in association_rows),
            "capacity": sum(row["classification"] == "G2" and int(row["capacity"]) for row in association_rows),
            "recognized": sum(row["classification"] == "G2" and int(row["recognized"]) for row in association_rows),
            "role": "descriptive inventory; excluded from qualification gate",
        },
        "recognitionRule": {
            "capacity": {"triggerEpisodes": MIN_TRIGGER_EPISODES, "nontriggerEpisodes": MIN_NONTRIGGER_EPISODES, "triggerGroups": MIN_TRIGGER_GROUPS},
            "folds": FOLDS,
            "sameDirectionFoldsRequired": 2,
            "nullRuns": NULL_RUNS,
            "nullThreshold": "within-group circular-shift 95th percentile",
            "pooledEffectMustBePositive": True,
        },
    }
    atomic_json(output / "a01-data-quality.json", quality)

    recognized_ids = [row["rule_id"] for row in g1_rows if int(row["recognized"])]
    insufficient_ids = [row["rule_id"] for row in g1_rows if not int(row["capacity"])]
    failed_ids = [row["rule_id"] for row in g1_rows if int(row["capacity"]) and not int(row["recognized"])]
    report = f"""# FWD-V20-RB01 A01 正式條件關聯資格考

## 結論

**{'通過' if passed else '未通過'}。** 15 條 G1 正式條件辨識 {g1_recognized} 條，門檻為至少 {overall_required} 條；G1 逐事件重建錯配為 {g1_mismatches}。

- 已辨識：{', '.join(recognized_ids) if recognized_ids else '無'}
- 容量不足（仍計入分母）：{', '.join(insufficient_ids) if insufficient_ids else '無'}
- 容量足夠但未辨識：{', '.join(failed_ids) if failed_ids else '無'}
- phase 門檻：{'；'.join(f"{row['phase']} {row['recognized']}/{row['total']}（需 {row['required']}）" for row in phase_gates)}
- 二數值門檻：{pair_recognized}/{len(pair_rows)}（需 {pair_required}）

## 方法界線

只使用 A～C 第 1、2 窗口的 discovery 標籤；A～C 第 3 窗口及 D、E 未使用。G1 由凍結特徵重建並與正式 `event_votes` 逐事件核對；G2 因包含 Grade、歷史狀態、共享票數上限等正式狀態機，直接以 `event_votes` 作觸發權威，只列描述性關聯，不進入 G1 資格門檻。

主判定將連續觸發／未觸發合併為 episode，以 Sample × 股票 × 窗口做三折 GroupKFold；需至少兩折同向，且合併效果為正並高於 100 次組內循環位移的第 95 百分位。Grade、持倉狀態與扣除本條貢獻後決策分數的精確分層配對另列摘要，不取代主判定。

## 後續

{'本層只證明現有標籤具有進入通用語法回收測試的最低資格；RB01-D01 仍須另行核准，尚未執行。' if passed else '依事前停止條件，現有 20 日路徑標籤／樣本容量不能充當正式規則的合格回收基準；RB01-D01 不應執行。'}
"""
    (output / "a01-report.md").write_text(report, encoding="utf-8")

    final_status = "passed" if passed else "failed"
    update_progress(progress_path, "complete", f"qualification {final_status}; G1 {g1_recognized}/{g1_total}")
    complete_path.write_text(f"{RUN_ID}:{STAGE}:{final_status}\n", encoding="utf-8")

    output_names = (
        ".rb01-a01-complete",
        "rule-event-reconstruction.csv",
        "exact-control-association.csv",
        "exact-control-folds.csv",
        "exact-control-null.csv",
        "exact-control-matched.csv",
        "a01-data-quality.json",
        "a01-report.md",
        "rb01-a01-progress.json",
    )
    manifest = {
        "studyID": STUDY_ID,
        "runID": RUN_ID,
        "stage": STAGE,
        "status": final_status,
        "createdAt": now(),
        "scope": {"samples": list(SAMPLES), "windows": list(WINDOWS), "role": "discovery", "holdoutLabelsUsed": False},
        "inputs": {
            "i01Manifest": {"path": str(i01_manifest_path), **file_record(i01_manifest_path)},
            "i01ControlMap": {"path": str(output / "control-map.csv"), **file_record(output / "control-map.csv")},
            "i01RuleUniverse": {"path": str(output / "rule-universe.csv"), **file_record(output / "rule-universe.csv")},
            "m01Manifest": {"path": str(m01_manifest_path), **file_record(m01_manifest_path)},
            "m01Frozen": {name: {"path": str(m01 / name), **file_record(m01 / name)} for name in frozen_names},
            "decisionBases": {sample: database_records[sample] for sample in SAMPLES},
        },
        "tool": {"path": "tools/fwd_v20_rule_association.py", **file_record(project_root / "tools/fwd_v20_rule_association.py")},
        "outputs": {name: file_record(output / name) for name in output_names},
        "qualification": quality,
    }
    atomic_json(output / "rb01-a01-manifest.json", manifest)
    print(json.dumps({"status": manifest["status"], "g1": f"{g1_recognized}/{g1_total}", "output": str(output)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
