#!/usr/bin/env python3
"""Run the rule-aligned M02-L01 exhaustive two-feature screen."""

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
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence

import joblib
import numpy as np
import pandas as pd
import sklearn
from sklearn.model_selection import GroupKFold

import fwd_v20_path_discovery as study


STAGE = "M02-L01"
TARGET_LABEL = "bottom-then-rebound"
ADVERSE_LABEL = "continuation-down"
FOLDS = 3
NULL_RUNS = 3
QUANTILES = (0.2, 0.4, 0.6, 0.8)
MIN_TRAIN_EPISODES = 20
MIN_TRAIN_GROUPS = 8
MIN_TEST_EPISODES = 5
MIN_FULL_EPISODES = 30
MIN_FULL_GROUPS = 10
RANDOM_STATE = 20260902
POSITIVE_CONTROL_PAIRS = {
    ("kd_k_z125", "kd_k_z250"): "L-P03",
    ("kd_d_z125", "kd_d_z250"): "L-P04",
}
KNOWN_OR_NEAR_FORMAL_PAIRS = {
    tuple(sorted(pair))
    for pair in (
        ("kd_k_z125", "kd_k_z250"),
        ("kd_d_z125", "kd_d_z250"),
        ("kd_k_z125", "kd_d_z125"),
        ("osc_z125", "osc_z250"),
        ("kd_j_z125", "kd_j_z250"),
        ("osc_z125", "kd_j_z125"),
        ("ma20_diff", "ma60_diff"),
        ("ma20_diff", "ma20_days"),
        ("ma20_diff_is_min9", "ma60_diff_is_min9"),
        ("t_high_diff_z125", "t_low_diff_z125"),
        ("kd_k_cross_d_up", "kd_k_cross_d_down"),
    )
}


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


def group_codes(values: np.ndarray) -> np.ndarray:
    mapping = {value: index for index, value in enumerate(sorted(set(values.tolist())))}
    return np.array([mapping[value] for value in values], dtype=np.int16)


def episode_stats(
    cells: np.ndarray,
    signal: np.ndarray,
    mask: np.ndarray,
    groups: np.ndarray,
    ordinals: np.ndarray,
    cell_count: int,
) -> dict[str, np.ndarray]:
    indexes = np.flatnonzero(mask)
    require(len(indexes) > 0, "empty episode subset")
    subset_cells = cells[indexes]
    subset_signal = signal[indexes]
    subset_groups = groups[indexes]
    subset_ordinals = ordinals[indexes]
    boundaries = np.ones(len(indexes), dtype=bool)
    if len(indexes) > 1:
        boundaries[1:] = (
            (subset_groups[1:] != subset_groups[:-1])
            | (subset_ordinals[1:] != subset_ordinals[:-1] + 1)
        )
    changed = np.zeros(len(indexes), dtype=bool)
    if len(indexes) > 1:
        changed[1:] = ~boundaries[1:] & (subset_cells[1:] != subset_cells[:-1])
    entries = boundaries | changed
    trigger_count = np.bincount(subset_cells[entries], minlength=cell_count).astype(np.int32)
    trigger_sum = np.bincount(
        subset_cells[entries], weights=subset_signal[entries], minlength=cell_count
    )

    boundary_cells = subset_cells[boundaries]
    boundary_signal = subset_signal[boundaries]
    boundary_count = np.bincount(boundary_cells, minlength=cell_count)
    boundary_sum = np.bincount(boundary_cells, weights=boundary_signal, minlength=cell_count)
    previous_cells = subset_cells[:-1][changed[1:]] if len(indexes) > 1 else np.array([], dtype=int)
    leaving_signal = subset_signal[1:][changed[1:]] if len(indexes) > 1 else np.array([], dtype=float)
    leaving_count = np.bincount(previous_cells, minlength=cell_count)
    leaving_sum = np.bincount(previous_cells, weights=leaving_signal, minlength=cell_count)
    nontrigger_count = boundaries.sum() - boundary_count + leaving_count
    nontrigger_sum = boundary_signal.sum() - boundary_sum + leaving_sum

    trigger_groups = np.zeros(cell_count, dtype=np.int16)
    entry_cells = subset_cells[entries]
    entry_groups = subset_groups[entries]
    for cell in range(cell_count):
        trigger_groups[cell] = len(set(entry_groups[entry_cells == cell].tolist()))
    return {
        "trigger_count": trigger_count,
        "trigger_sum": trigger_sum,
        "nontrigger_count": nontrigger_count.astype(np.int32),
        "nontrigger_sum": nontrigger_sum,
        "trigger_groups": trigger_groups,
    }


def score_cells(stats: dict[str, np.ndarray]) -> np.ndarray:
    trigger_count = stats["trigger_count"]
    nontrigger_count = stats["nontrigger_count"]
    scores = np.full(len(trigger_count), -np.inf, dtype=float)
    valid = (
        (trigger_count >= MIN_TRAIN_EPISODES)
        & (nontrigger_count >= MIN_TRAIN_EPISODES)
        & (stats["trigger_groups"] >= MIN_TRAIN_GROUPS)
    )
    scores[valid] = (
        stats["trigger_sum"][valid] / trigger_count[valid]
        - stats["nontrigger_sum"][valid] / nontrigger_count[valid]
    )
    return scores


def choose_cell(stats: dict[str, np.ndarray]) -> int | None:
    scores = score_cells(stats)
    if not bool(np.isfinite(scores).any()):
        return None
    return int(np.argmax(scores))


def evaluate_cell(stats: dict[str, np.ndarray], cell: int | None) -> dict[str, Any]:
    if cell is None:
        return {
            "cell": None,
            "trigger_count": 0,
            "nontrigger_count": 0,
            "trigger_sum": 0.0,
            "nontrigger_sum": 0.0,
            "trigger_groups": 0,
            "score": math.nan,
        }
    trigger_count = int(stats["trigger_count"][cell])
    nontrigger_count = int(stats["nontrigger_count"][cell])
    score = (
        float(stats["trigger_sum"][cell] / trigger_count - stats["nontrigger_sum"][cell] / nontrigger_count)
        if trigger_count and nontrigger_count
        else math.nan
    )
    return {
        "cell": cell,
        "trigger_count": trigger_count,
        "nontrigger_count": nontrigger_count,
        "trigger_sum": float(stats["trigger_sum"][cell]),
        "nontrigger_sum": float(stats["nontrigger_sum"][cell]),
        "trigger_groups": int(stats["trigger_groups"][cell]),
        "score": score,
    }


def pair_cv(
    left_bins: np.ndarray,
    right_bins: np.ndarray,
    right_count: int,
    signal: np.ndarray,
    fold_ids: np.ndarray,
    groups: np.ndarray,
    ordinals: np.ndarray,
) -> dict[str, Any]:
    cells = left_bins.astype(np.int16) * right_count + right_bins.astype(np.int16)
    cell_count = int((left_bins.max() + 1) * right_count)
    fold_results: list[dict[str, Any]] = []
    total_trigger_count = total_nontrigger_count = 0
    total_trigger_sum = total_nontrigger_sum = 0.0
    for fold in range(1, FOLDS + 1):
        train_mask = fold_ids != fold
        test_mask = fold_ids == fold
        train_stats = episode_stats(cells, signal, train_mask, groups, ordinals, cell_count)
        cell = choose_cell(train_stats)
        test_stats = episode_stats(cells, signal, test_mask, groups, ordinals, cell_count)
        evaluated = evaluate_cell(test_stats, cell)
        if (
            evaluated["trigger_count"] < MIN_TEST_EPISODES
            or evaluated["nontrigger_count"] < MIN_TEST_EPISODES
        ):
            evaluated["score"] = math.nan
        fold_results.append(evaluated)
        if math.isfinite(evaluated["score"]):
            total_trigger_count += evaluated["trigger_count"]
            total_nontrigger_count += evaluated["nontrigger_count"]
            total_trigger_sum += evaluated["trigger_sum"]
            total_nontrigger_sum += evaluated["nontrigger_sum"]
    oof_score = (
        total_trigger_sum / total_trigger_count - total_nontrigger_sum / total_nontrigger_count
        if total_trigger_count and total_nontrigger_count
        else math.nan
    )
    full_stats = episode_stats(
        cells,
        signal,
        np.ones(len(signal), dtype=bool),
        groups,
        ordinals,
        cell_count,
    )
    full_cell = choose_cell(full_stats)
    full = evaluate_cell(full_stats, full_cell)
    return {
        "oof_score": oof_score,
        "folds_positive": sum(
            1 for result in fold_results if math.isfinite(result["score"]) and result["score"] > 0
        ),
        "valid_folds": sum(1 for result in fold_results if math.isfinite(result["score"])),
        "fold_cells": [result["cell"] for result in fold_results],
        "fold_scores": [result["score"] for result in fold_results],
        "full": full,
        "same_as_full": sum(1 for result in fold_results if result["cell"] == full_cell),
    }


def bin_feature(values: np.ndarray) -> tuple[np.ndarray, list[float], str]:
    unique = np.unique(values)
    if len(unique) <= 2 and set(unique.tolist()).issubset({0.0, 1.0}):
        return values.astype(np.int8), [0.5], "binary"
    thresholds = sorted(set(float(value) for value in np.quantile(values, QUANTILES)))
    bins = np.searchsorted(np.array(thresholds), values, side="right").astype(np.int8)
    return bins, thresholds, "quantile"


def cell_bounds(thresholds: list[float], cell: int) -> tuple[str, str]:
    lower = "-inf" if cell == 0 else repr(thresholds[cell - 1])
    upper = "+inf" if cell == len(thresholds) else repr(thresholds[cell])
    return lower, upper


def shifted_signals(
    signal: np.ndarray,
    groups: np.ndarray,
    runs: int,
) -> list[np.ndarray]:
    output: list[np.ndarray] = []
    for run in range(1, runs + 1):
        shifted = signal.copy()
        for group in sorted(set(groups.tolist())):
            indexes = np.flatnonzero(groups == group)
            if len(indexes) <= 1:
                continue
            digest = hashlib.sha256(
                f"{study.STUDY_ID}|{STAGE}|null-{run}|{group}".encode("utf-8")
            ).digest()
            shift = 1 + int.from_bytes(digest[:4], "big") % (len(indexes) - 1)
            shifted[indexes] = np.roll(signal[indexes], shift)
        output.append(shifted)
    return output


def load_data(project_root: Path, output: Path, manifest: dict[str, Any]) -> dict[str, Any]:
    key_by_row: dict[str, tuple[str, int, str, int]] = {}
    meta: dict[tuple[str, int, str, int], dict[str, Any]] = {}
    all_group_keys: dict[str, list[tuple[str, int, str, int]]] = defaultdict(list)
    with (output / "feature-keys.csv").open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            if row["role"] != "discovery":
                continue
            key = (row["sample"], int(row["window_id"]), row["stock_id"], int(row["trade_date"]))
            group = f"{key[0]}-W{key[1]}-{key[2]}"
            key_by_row[row["row_id"]] = key
            meta[key] = {"row_id": row["row_id"], "group": group}
            all_group_keys[group].append(key)
    for group, keys in all_group_keys.items():
        for ordinal, key in enumerate(sorted(keys, key=lambda value: value[3])):
            meta[key]["ordinal"] = ordinal

    eligible: set[tuple[str, int, str, int]] = set()
    for sample in "ABC":
        database = Path(
            manifest["inputs"]["samples"][sample]["decisionBase"]["inputFiles"]["database"]["path"]
        )
        require(
            study.file_hash(database)
            == manifest["inputs"]["samples"][sample]["decisionBase"]["inputFiles"]["database"]["sha256"],
            f"DecisionBase changed: {sample}",
        )
        connection = sqlite3.connect(f"file:{database.resolve().as_posix()}?mode=ro&immutable=1", uri=True)
        connection.row_factory = sqlite3.Row
        try:
            for row in connection.execute(
                "SELECT e.window_id,s.stock_id,e.trade_date FROM decision_events e "
                "JOIN stocks s USING(stock_key) WHERE e.phase=2 AND e.window_id IN (1,2) "
                "AND e.inventory_before=0"
            ):
                key = (sample, int(row["window_id"]), str(row["stock_id"]), int(row["trade_date"]))
                if key in meta:
                    eligible.add(key)
        finally:
            connection.close()
    require(eligible, "no M02-L01 eligible rows")

    labels: dict[tuple[str, int, str, int], str] = {}
    with (output / "path-labels.csv").open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            key = (row["sample"], int(row["window_id"]), row["stock_id"], int(row["trade_date"]))
            if key in eligible:
                labels[key] = row["label"]
    require(set(labels) == eligible, "M02-L01 label join incomplete")

    wanted_rows = {meta[key]["row_id"]: key for key in eligible}
    feature_values: dict[tuple[str, int, str, int], list[float]] = {}
    with (output / "features.csv").open(encoding="utf-8", newline="") as handle:
        reader = csv.reader(handle)
        header = next(reader)
        require(header[0] == "row_id", "unexpected feature matrix header")
        feature_names = header[1:]
        for row in reader:
            key = wanted_rows.get(row[0])
            if key is not None:
                feature_values[key] = [float(value) for value in row[1:]]
    require(set(feature_values) == eligible, "M02-L01 feature join incomplete")

    ordered = sorted(eligible, key=lambda key: (meta[key]["group"], meta[key]["ordinal"]))
    matrix = np.array([feature_values[key] for key in ordered], dtype=np.float64)
    require(bool(np.isfinite(matrix).all()), "M02-L01 matrix contains non-finite values")
    label_values = np.array([labels[key] for key in ordered], dtype=str)
    signal = np.where(
        label_values == TARGET_LABEL,
        1.0,
        np.where(label_values == ADVERSE_LABEL, -1.0, 0.0),
    )
    group_values = np.array([meta[key]["group"] for key in ordered], dtype=str)
    ordinal_values = np.array([meta[key]["ordinal"] for key in ordered], dtype=np.int16)
    available_groups = set(group_values.tolist())
    all_groups = set(all_group_keys)
    require(len(available_groups) >= 50, "M02-L01 has fewer than 50 eligible discovery groups")
    require(Counter(label_values)[TARGET_LABEL] >= 100, "too few target labels")
    require(Counter(label_values)[ADVERSE_LABEL] >= 100, "too few adverse labels")
    return {
        "matrix": matrix,
        "feature_names": feature_names,
        "labels": label_values,
        "signal": signal,
        "groups_text": group_values,
        "groups": group_codes(group_values),
        "ordinals": ordinal_values,
        "keys": ordered,
        "missing_groups": sorted(all_groups - available_groups),
    }


def refresh_manifest(output: Path, manifest: dict[str, Any]) -> None:
    manifest["outputs"] = {
        path.name: {"sha256": study.file_hash(path), "bytes": path.stat().st_size}
        for path in sorted(output.iterdir())
        if path.is_file() and path.name != "manifest.json"
    }
    atomic_json(output / "manifest.json", manifest)


def run(project_root: Path, output: Path) -> None:
    require(output.is_dir(), f"missing study output: {output}")
    require(not (output / ".m02-l01-complete").exists(), "M02-L01 is already complete")
    manifest = study.read_json(output / "manifest.json")
    quality = study.read_json(output / "data-quality.json")
    require(manifest.get("stages", {}).get("M01-PC01") == "complete", "M02-L01 requires PC01")
    require(
        manifest.get("positiveControl", {}).get("conclusion")
        == "unconditional-controls-exist-ebm-search-missed",
        "M02-L01 requires recovered positive controls",
    )
    input_metadata, _ = study.verify_inputs(project_root)
    require(input_metadata == manifest["inputs"], "M02-L01 inputs differ from frozen P0")
    for name in ("path-labels.csv", "feature-catalog.csv", "feature-keys.csv", "features.csv"):
        require(study.file_hash(output / name) == manifest["outputs"][name]["sha256"], f"changed frozen file: {name}")

    progress = {
        "studyID": study.STUDY_ID,
        "stage": STAGE,
        "status": "loading",
        "startedAt": datetime.now(timezone.utc).isoformat(),
    }
    atomic_json(output / "m02-l01-progress.json", progress)
    data = load_data(project_root, output, manifest)
    matrix = data["matrix"]
    feature_names = data["feature_names"]
    signal = data["signal"]
    groups = data["groups"]
    ordinals = data["ordinals"]
    splitter = GroupKFold(n_splits=FOLDS)
    fold_ids = np.zeros(len(signal), dtype=np.int8)
    for fold, (_, test_indexes) in enumerate(
        splitter.split(matrix, data["labels"], data["groups_text"]), start=1
    ):
        fold_ids[test_indexes] = fold
    require(bool((fold_ids > 0).all()), "incomplete M02-L01 folds")

    catalog = {
        row["feature"]: row
        for row in csv.DictReader((output / "feature-catalog.csv").open(encoding="utf-8", newline=""))
    }
    binned: list[np.ndarray] = []
    thresholds: list[list[float]] = []
    bin_kinds: list[str] = []
    bin_rows: list[dict[str, Any]] = []
    for index, name in enumerate(feature_names):
        bins, cuts, kind = bin_feature(matrix[:, index])
        binned.append(bins)
        thresholds.append(cuts)
        bin_kinds.append(kind)
        bin_rows.append(
            {
                "feature": name,
                "family": catalog[name]["family"],
                "kind": kind,
                "bin_count": int(bins.max() + 1),
                "thresholds": "|".join(repr(value) for value in cuts),
            }
        )
    write_csv(
        output / "m02-l01-bin-schema.csv",
        ["feature", "family", "kind", "bin_count", "thresholds"],
        bin_rows,
    )
    null_signals = shifted_signals(signal, data["groups_text"], NULL_RUNS)
    pairs_total = len(feature_names) * (len(feature_names) - 1) // 2
    progress.update(
        {
            "status": "screening",
            "eligibleRows": len(signal),
            "groups": len(set(data["groups_text"].tolist())),
            "featureColumns": len(feature_names),
            "pairsTotal": pairs_total,
            "pairsComplete": 0,
        }
    )
    atomic_json(output / "m02-l01-progress.json", progress)
    print(
        f"M02-L01 start: rows={len(signal):,}, groups={len(set(data['groups_text'].tolist()))}, "
        f"features={len(feature_names)}, pairs={pairs_total:,}",
        flush=True,
    )
    started = time.monotonic()
    ranking: list[dict[str, Any]] = []
    pair_index = 0
    for left_index, left_name in enumerate(feature_names[:-1]):
        for right_index in range(left_index + 1, len(feature_names)):
            right_name = feature_names[right_index]
            right_count = int(binned[right_index].max() + 1)
            observed = pair_cv(
                binned[left_index],
                binned[right_index],
                right_count,
                signal,
                fold_ids,
                groups,
                ordinals,
            )
            null_results = [
                pair_cv(
                    binned[left_index],
                    binned[right_index],
                    right_count,
                    null_signal,
                    fold_ids,
                    groups,
                    ordinals,
                )
                for null_signal in null_signals
            ]
            full_cell = observed["full"]["cell"]
            if full_cell is None:
                left_cell = right_cell = None
                left_lower = left_upper = right_lower = right_upper = ""
            else:
                left_cell, right_cell = divmod(int(full_cell), right_count)
                left_lower, left_upper = cell_bounds(thresholds[left_index], left_cell)
                right_lower, right_upper = cell_bounds(thresholds[right_index], right_cell)
            pair = tuple(sorted((left_name, right_name)))
            ranking.append(
                {
                    "feature_1": left_name,
                    "family_1": catalog[left_name]["family"],
                    "feature_2": right_name,
                    "family_2": catalog[right_name]["family"],
                    "oof_net_signal": observed["oof_score"],
                    "folds_positive": observed["folds_positive"],
                    "valid_folds": observed["valid_folds"],
                    "full_cell": full_cell if full_cell is not None else "",
                    "full_feature_1_bin": left_cell if left_cell is not None else "",
                    "full_feature_1_lower": left_lower,
                    "full_feature_1_upper": left_upper,
                    "full_feature_2_bin": right_cell if right_cell is not None else "",
                    "full_feature_2_lower": right_lower,
                    "full_feature_2_upper": right_upper,
                    "full_net_signal": observed["full"]["score"],
                    "full_trigger_episodes": observed["full"]["trigger_count"],
                    "full_nontrigger_episodes": observed["full"]["nontrigger_count"],
                    "full_trigger_groups": observed["full"]["trigger_groups"],
                    "fold_cells": "|".join("" if cell is None else str(cell) for cell in observed["fold_cells"]),
                    "fold_scores": "|".join(
                        "" if not math.isfinite(value) else repr(value) for value in observed["fold_scores"]
                    ),
                    "fold_cells_same_as_full": observed["same_as_full"],
                    "null_1_oof": null_results[0]["oof_score"],
                    "null_2_oof": null_results[1]["oof_score"],
                    "null_3_oof": null_results[2]["oof_score"],
                    "pair_null_max": max(
                        result["oof_score"]
                        for result in null_results
                        if math.isfinite(result["oof_score"])
                    ),
                    "positive_control": POSITIVE_CONTROL_PAIRS.get(pair, ""),
                    "known_or_near_formal": int(pair in KNOWN_OR_NEAR_FORMAL_PAIRS),
                }
            )
            pair_index += 1
            if pair_index % 250 == 0 or pair_index == pairs_total:
                elapsed = time.monotonic() - started
                progress["pairsComplete"] = pair_index
                progress["heartbeatAt"] = datetime.now(timezone.utc).isoformat()
                progress["elapsedSeconds"] = round(elapsed, 3)
                atomic_json(output / "m02-l01-progress.json", progress)
                print(f"M02-L01 progress: {pair_index:,}/{pairs_total:,} pairs, {elapsed:.1f}s", flush=True)

    null_global_maxima = []
    for field in ("null_1_oof", "null_2_oof", "null_3_oof"):
        null_global_maxima.append(
            max(row[field] for row in ranking if math.isfinite(row[field]))
        )
    global_null_gate = max(null_global_maxima)
    controls: list[dict[str, Any]] = []
    for row in ranking:
        if not row["positive_control"]:
            continue
        low_full = (
            isinstance(row["full_feature_1_bin"], int)
            and isinstance(row["full_feature_2_bin"], int)
            and row["full_feature_1_bin"] <= 1
            and row["full_feature_2_bin"] <= 1
        )
        fold_cells = [int(value) for value in row["fold_cells"].split("|") if value != ""]
        right_count = next(
            item["bin_count"] for item in bin_rows if item["feature"] == row["feature_2"]
        )
        low_folds = sum(
            1
            for cell in fold_cells
            if cell // int(right_count) <= 1 and cell % int(right_count) <= 1
        )
        recovered = bool(
            math.isfinite(row["oof_net_signal"])
            and row["oof_net_signal"] > 0
            and row["oof_net_signal"] > row["pair_null_max"]
            and row["folds_positive"] >= 2
            and row["full_trigger_episodes"] >= MIN_FULL_EPISODES
            and row["full_nontrigger_episodes"] >= MIN_FULL_EPISODES
            and row["full_trigger_groups"] >= MIN_FULL_GROUPS
            and low_full
            and low_folds >= 2
        )
        controls.append(
            {
                "rule_id": row["positive_control"],
                "feature_1": row["feature_1"],
                "feature_2": row["feature_2"],
                "oof_net_signal": row["oof_net_signal"],
                "pair_null_max": row["pair_null_max"],
                "folds_positive": row["folds_positive"],
                "full_low_low": int(low_full),
                "low_low_folds": low_folds,
                "recovered": int(recovered),
            }
        )
    require(len(controls) == len(POSITIVE_CONTROL_PAIRS), "missing M02-L01 positive control pair")
    controls_passed = all(row["recovered"] for row in controls)

    for row in ranking:
        row["passes_pair_null"] = int(
            math.isfinite(row["oof_net_signal"])
            and row["oof_net_signal"] > row["pair_null_max"]
        )
        row["passes_global_null"] = int(
            math.isfinite(row["oof_net_signal"])
            and row["oof_net_signal"] > global_null_gate
        )
        row["stable_novel"] = int(
            controls_passed
            and not row["known_or_near_formal"]
            and math.isfinite(row["oof_net_signal"])
            and row["oof_net_signal"] > 0
            and row["folds_positive"] >= 2
            and row["valid_folds"] == FOLDS
            and row["fold_cells_same_as_full"] >= 2
            and row["full_trigger_episodes"] >= MIN_FULL_EPISODES
            and row["full_nontrigger_episodes"] >= MIN_FULL_EPISODES
            and row["full_trigger_groups"] >= MIN_FULL_GROUPS
            and row["passes_pair_null"]
            and row["passes_global_null"]
        )
    ranking.sort(
        key=lambda row: (
            -row["stable_novel"],
            -(row["oof_net_signal"] if math.isfinite(row["oof_net_signal"]) else -math.inf),
            row["feature_1"],
            row["feature_2"],
        )
    )
    for rank, row in enumerate(ranking, start=1):
        row["rank"] = rank
    ranking_fields = [
        "rank", "feature_1", "family_1", "feature_2", "family_2", "oof_net_signal",
        "folds_positive", "valid_folds", "full_cell", "full_feature_1_bin",
        "full_feature_1_lower", "full_feature_1_upper", "full_feature_2_bin",
        "full_feature_2_lower", "full_feature_2_upper", "full_net_signal",
        "full_trigger_episodes", "full_nontrigger_episodes", "full_trigger_groups",
        "fold_cells", "fold_scores", "fold_cells_same_as_full", "null_1_oof",
        "null_2_oof", "null_3_oof", "pair_null_max", "passes_pair_null",
        "passes_global_null", "positive_control", "known_or_near_formal", "stable_novel",
    ]
    write_csv(output / "m02-l01-pair-ranking.csv", ranking_fields, ranking)
    write_csv(
        output / "m02-l01-positive-controls.csv",
        [
            "rule_id", "feature_1", "feature_2", "oof_net_signal", "pair_null_max",
            "folds_positive", "full_low_low", "low_low_folds", "recovered",
        ],
        controls,
    )
    null_rows = [
        {"null_run": index, "global_max_oof_net_signal": value}
        for index, value in enumerate(null_global_maxima, start=1)
    ]
    null_rows.append({"null_run": "gate", "global_max_oof_net_signal": global_null_gate})
    write_csv(
        output / "m02-l01-null-summary.csv",
        ["null_run", "global_max_oof_net_signal"],
        null_rows,
    )
    stable = [row for row in ranking if row["stable_novel"]]
    if not controls_passed:
        conclusion = "positive-control-gate-failed"
    elif stable:
        conclusion = "stable-novel-pairs-found-pending-overlap-audit"
    else:
        conclusion = "positive-controls-recovered-no-novel-pair-above-global-null"
    config = {
        "studyID": study.STUDY_ID,
        "stage": STAGE,
        "scope": "Samples A-C windows 1-2; L phase; inventory_before=0",
        "holdoutLabelsUsed": False,
        "eligibleRows": len(signal),
        "groups": len(set(data["groups_text"].tolist())),
        "missingGroups": data["missing_groups"],
        "labelCounts": dict(sorted(Counter(data["labels"]).items())),
        "signal": {
            TARGET_LABEL: 1,
            ADVERSE_LABEL: -1,
            "other three frozen labels": 0,
        },
        "features": len(feature_names),
        "pairs": pairs_total,
        "binning": {
            "continuous": "global discovery-context quintiles; label blind",
            "binary": "0/1",
            "schema": "m02-l01-bin-schema.csv",
        },
        "crossValidation": {
            "method": "three-fold GroupKFold",
            "group": "sample x stock x window",
            "trainSelectsOne2DCell": True,
            "testUsesFrozenTrainCell": True,
        },
        "episode": "first row after selected-cell membership changes or a date-ordinal gap",
        "positiveControls": controls,
        "positiveControlsPassed": controls_passed,
        "null": {
            "runs": NULL_RUNS,
            "method": "deterministic circular signal shift within stock x window",
            "globalMaxima": null_global_maxima,
            "globalGate": global_null_gate,
            "pValueClaimed": False,
        },
        "novelGate": {
            "positiveControlsMustPass": True,
            "minimumPositiveFolds": 2,
            "allFoldsValid": True,
            "minimumFoldCellsMatchingFull": 2,
            "minimumFullTriggerEpisodes": MIN_FULL_EPISODES,
            "minimumFullNontriggerEpisodes": MIN_FULL_EPISODES,
            "minimumFullTriggerGroups": MIN_FULL_GROUPS,
            "mustExceedPairSpecificNullMaximum": True,
            "mustExceedAllThreeGlobalNullMaxima": True,
            "knownOrNearFormalExcluded": True,
        },
        "environment": {
            "python": platform.python_version(),
            "numpy": np.__version__,
            "pandas": pd.__version__,
            "scikitLearn": sklearn.__version__,
            "joblib": joblib.__version__,
        },
        "conclusion": conclusion,
    }
    atomic_json(output / "m02-l01-config.json", config)
    quality["m02L01"] = {
        "status": "complete",
        "conclusion": conclusion,
        "eligibleRows": len(signal),
        "groups": len(set(data["groups_text"].tolist())),
        "features": len(feature_names),
        "pairs": pairs_total,
        "positiveControlsPassed": controls_passed,
        "stableNovelPairs": len(stable),
        "holdoutLabelsUsed": False,
    }
    atomic_json(output / "data-quality.json", quality)

    report_path = output / "report.md"
    report = report_path.read_text(encoding="utf-8")
    require("## M02-L01 規則對齊二數值掃描" not in report, "M02-L01 report exists")
    control_lines = "\n".join(
        f"- `{row['rule_id']}`：OOF 淨訊號 {row['oof_net_signal']:.6f}，"
        f"三次同組虛無最高 {row['pair_null_max']:.6f}，{'通過' if row['recovered'] else '未通過'}。"
        for row in controls
    )
    report += (
        "\n## M02-L01 規則對齊二數值掃描\n\n"
        f"- 只使用 A～C 前兩窗口 L 階段且空手的 {len(signal):,} 筆資料、{len(set(data['groups_text'].tolist()))} 個股票 × 窗口群組；沒有合格列的格為 {'、'.join(data['missing_groups']) or '無'}，第三窗口、D、E 未使用。\n"
        f"- 對 {len(feature_names)} 個特徵的 {pairs_total:,} 組二數值逐一做標籤盲分箱、三折群組外評估及三次組內區塊虛無比較。\n"
        f"- 正向控制整體：{'通過' if controls_passed else '未通過'}。\n"
        f"{control_lines}\n"
        f"- 超過全部三次全掃描虛無最大值且不屬已知／近義正式規則的新組合：{len(stable)} 組；結論 `{conclusion}`。\n"
        "- 本階段不讀保留集、不轉成交易門檻、不修改規則或重播 `simUpdate`。\n"
    )
    report_path.write_text(report, encoding="utf-8")
    progress["status"] = "complete"
    progress["completedAt"] = datetime.now(timezone.utc).isoformat()
    progress["conclusion"] = conclusion
    progress["stableNovelPairs"] = len(stable)
    atomic_json(output / "m02-l01-progress.json", progress)
    (output / ".m02-l01-complete").write_text(study.STUDY_ID + "\n", encoding="utf-8")
    manifest.setdefault("stages", {})[STAGE] = "complete"
    manifest["m02L01CompletedAt"] = datetime.now(timezone.utc).isoformat()
    manifest["m02L01"] = {
        "conclusion": conclusion,
        "config": "m02-l01-config.json",
        "ranking": "m02-l01-pair-ranking.csv",
        "positiveControls": "m02-l01-positive-controls.csv",
        "nullSummary": "m02-l01-null-summary.csv",
        "stableNovelPairs": len(stable),
        "holdoutLabelsUsed": False,
        "tool": {
            "path": "tools/fwd_v20_pair_screen.py",
            "sha256": study.file_hash(Path(__file__).resolve()),
        },
    }
    manifest.setdefault("qualitySummary", {})["m02L01"] = quality["m02L01"]
    refresh_manifest(output, manifest)
    print(
        f"M02-L01 {conclusion}: controls={int(controls_passed)}, stable_novel={len(stable)}",
        flush=True,
    )


def self_test() -> None:
    cells = np.array([0, 0, 1, 1, 0, 1], dtype=np.int8)
    signal = np.array([1, 0, -1, 1, 1, -1], dtype=float)
    groups = np.array([0, 0, 0, 0, 1, 1], dtype=np.int8)
    ordinals = np.array([0, 1, 2, 3, 0, 1], dtype=np.int8)
    stats = episode_stats(cells, signal, np.ones(6, dtype=bool), groups, ordinals, 2)
    assert stats["trigger_count"].tolist() == [2, 2]
    assert stats["nontrigger_count"].tolist() == [2, 2]
    assert stats["trigger_sum"].tolist() == [2.0, -2.0]
    assert stats["nontrigger_sum"].tolist() == [-2.0, 2.0]
    bins, cuts, kind = bin_feature(np.array([0.0, 0.0, 1.0, 1.0]))
    assert kind == "binary" and cuts == [0.5] and bins.tolist() == [0, 0, 1, 1]
    print("self-test: ok")


def main() -> None:
    args = arguments()
    if args.self_test:
        self_test()
        return
    project_root = args.project_root.resolve()
    output = (
        args.output
        or project_root / "exports" / "future-path-study" / study.RUN_ID
    ).resolve()
    run(project_root, output)


if __name__ == "__main__":
    main()
