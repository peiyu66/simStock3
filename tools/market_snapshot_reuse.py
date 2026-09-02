#!/usr/bin/env python3
"""Qualify offline MT1 snapshot reuse and build fixed-window market fragments."""

from __future__ import annotations

import argparse
import csv
import io
import json
import shutil
import sqlite3
import tempfile
from contextlib import contextmanager
from datetime import date
from pathlib import Path
from typing import Any, Iterator
from unittest import mock

import market_data_pool as pool
import market_technical as mt


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_POOL_ROOT = ROOT / "exports/market-data/taiex"
DEFAULT_FULL_SNAPSHOT = (
    DEFAULT_POOL_ROOT / "snapshots/taiex-market-mt1-20260722-a00beac8d4af"
)
DEFAULT_NORMALIZED_INPUT = (
    DEFAULT_POOL_ROOT / "normalized/market-daily-v1-20260722-f7316dd6c522"
)
BASELINE_NAMES = {
    sample: (
        f"baseline-{sample.lower()}-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-"
        "t2s39-9y-fixed3y-600w-20260901"
    )
    for sample in "ABCDE"
}
DEFAULT_REPORT_ROOT = ROOT / "exports/backtest-reports"
TOOL_VERSION = "market-snapshot-reuse-v1"
PREFIX_CUTOFF = "2026-06-30"
APPLE_REFERENCE_UNIX_OFFSET = 978_307_200


def require(condition: bool, message: str) -> None:
    if not condition:
        raise pool.MarketDataError(message)


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text())
    require(isinstance(value, dict), f"JSON root is not an object: {path}")
    return value


def verify_hashed_bundle(
    directory: Path,
    *,
    id_key: str,
    file_hashes_key: str,
    expected_id: str | None = None,
) -> dict[str, Any]:
    require(directory.is_dir(), f"bundle directory missing: {directory}")
    manifest_path = directory / "manifest.json"
    complete_path = directory / ".complete"
    require(manifest_path.is_file(), f"manifest missing: {manifest_path}")
    require(complete_path.is_file(), f"completion marker missing: {complete_path}")
    manifest = read_json(manifest_path)
    bundle_id = str(manifest.get(id_key, ""))
    require(bool(bundle_id), f"manifest {id_key} missing: {manifest_path}")
    if expected_id is not None:
        require(bundle_id == expected_id, f"bundle ID mismatch: {bundle_id} != {expected_id}")
    require(complete_path.read_text().strip() == bundle_id,
            f"completion marker mismatch: {directory}")
    hashes = manifest.get(file_hashes_key)
    require(isinstance(hashes, dict) and hashes, f"file hashes missing: {manifest_path}")
    for name, expected_hash in hashes.items():
        path = directory / name
        require(path.is_file(), f"hashed file missing: {path}")
        actual_hash = pool.sha256(path.read_bytes())
        require(actual_hash == expected_hash,
                f"hash mismatch: {path}: {actual_hash} != {expected_hash}")
    return manifest


def verify_mt_snapshot(directory: Path) -> dict[str, Any]:
    return verify_hashed_bundle(
        directory, id_key="snapshot_id", file_hashes_key="files"
    )


def verify_normalized(directory: Path) -> dict[str, Any]:
    return verify_hashed_bundle(
        directory, id_key="dataset_id", file_hashes_key="file_hashes"
    )


@contextmanager
def forbid_network() -> Iterator[dict[str, int]]:
    calls = {"count": 0}

    def reject(*args: Any, **kwargs: Any) -> Any:
        calls["count"] += 1
        raise pool.MarketDataError("network access is forbidden during MKT-D01-P3")

    with mock.patch.object(pool.urllib.request, "urlopen", side_effect=reject):
        yield calls


def csv_bytes(rows: list[dict[str, Any]], fields: list[str]) -> bytes:
    return mt.encode_csv(rows, fields)


def read_csv(path: Path) -> list[dict[str, str]]:
    return list(csv.DictReader(io.StringIO(path.read_text())))


def line_prefix(data: bytes, data_row_count: int) -> bytes:
    lines = data.splitlines(keepends=True)
    require(len(lines) >= data_row_count + 1, "CSV is shorter than requested prefix")
    return b"".join(lines[: data_row_count + 1])


def offline_rebuild_qualification(
    full_snapshot: Path,
    normalized_input: Path,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    snapshot_manifest = verify_mt_snapshot(full_snapshot)
    normalized_manifest = verify_normalized(normalized_input)
    source_rows, normalized_daily = mt.read_market_daily(normalized_input / "market-daily.csv")
    snapshot_daily = (full_snapshot / "market-daily.csv").read_bytes()
    require(normalized_daily == snapshot_daily,
            "full MT1 snapshot market-daily.csv differs from normalized P1 input")
    require(snapshot_manifest["source_dataset_id"] == normalized_manifest["dataset_id"],
            "MT1 source dataset ID mismatch")
    rebuilt_rows = mt.calculate_market(source_rows)
    rebuilt_technical = mt.encode_csv(rebuilt_rows, mt.OUTPUT_FIELDS)
    existing_technical = (full_snapshot / "market-technical.csv").read_bytes()
    require(rebuilt_technical == existing_technical,
            "offline MT1 rebuild differs from immutable full snapshot")
    return source_rows, rebuilt_rows, {
        "source_dataset_id": normalized_manifest["dataset_id"],
        "full_snapshot_id": snapshot_manifest["snapshot_id"],
        "row_count": len(source_rows),
        "market_daily_sha256": pool.sha256(snapshot_daily),
        "market_technical_sha256": pool.sha256(existing_technical),
        "daily_byte_mismatch_count": 0,
        "technical_byte_mismatch_count": 0,
        "network_request_count": 0,
        "passed": True,
    }


def build_prefix_snapshot(
    pool_root: Path,
    full_snapshot: Path,
    source_rows: list[dict[str, Any]],
    full_technical_rows: list[dict[str, Any]],
) -> tuple[Path, dict[str, Any]]:
    prefix_source = [row for row in source_rows if row["date"] <= PREFIX_CUTOFF]
    require(bool(prefix_source) and prefix_source[-1]["date"] == PREFIX_CUTOFF,
            f"prefix cutoff is not a market date: {PREFIX_CUTOFF}")
    prefix_technical = mt.calculate_market(prefix_source)
    daily_fields = list(source_rows[0].keys())
    daily_data = csv_bytes(prefix_source, daily_fields)
    technical_data = mt.encode_csv(prefix_technical, mt.OUTPUT_FIELDS)
    catalog_data = (full_snapshot / "field-catalog.csv").read_bytes()
    full_daily_data = (full_snapshot / "market-daily.csv").read_bytes()
    full_technical_data = (full_snapshot / "market-technical.csv").read_bytes()
    require(daily_data == line_prefix(full_daily_data, len(prefix_source)),
            "2026-06-30 raw prefix differs from 2026-07-22 snapshot")
    require(technical_data == line_prefix(full_technical_data, len(prefix_source)),
            "2026-06-30 technical prefix differs from 2026-07-22 snapshot")
    require(prefix_technical == full_technical_rows[: len(prefix_technical)],
            "independent prefix values differ from full-history values")

    technical_hash = pool.sha256(technical_data)
    snapshot_id = f"taiex-market-mt1-20260630-{technical_hash[:12]}"
    quality = {
        "snapshot_id": snapshot_id,
        "market_technical_version": mt.VERSION,
        "parent_snapshot_id": full_snapshot.name,
        "cutoff_date": PREFIX_CUTOFF,
        "date_start": prefix_source[0]["date"],
        "date_end": prefix_source[-1]["date"],
        "row_count": len(prefix_source),
        "raw_prefix_byte_mismatch_count": 0,
        "technical_prefix_byte_mismatch_count": 0,
        "independent_recalculation_mismatch_count": 0,
        "passed": True,
    }
    quality_data = pool.json_bytes(quality)
    manifest = {
        "snapshot_id": snapshot_id,
        "market_technical_version": mt.VERSION,
        "tool": "tools/market_snapshot_reuse.py",
        "tool_version": TOOL_VERSION,
        "source_dataset_id": "market-daily-v1-20260722-f7316dd6c522",
        "parent_snapshot_id": full_snapshot.name,
        "cutoff_date": PREFIX_CUTOFF,
        "row_count": len(prefix_source),
        "technical_field_count": len(mt.TECHNICAL_FIELDS),
        "files": {
            "market-daily.csv": pool.sha256(daily_data),
            "market-technical.csv": technical_hash,
            "field-catalog.csv": pool.sha256(catalog_data),
            "quality-report.json": pool.sha256(quality_data),
        },
        "prefix_matches_parent": True,
        "qualification_passed": True,
    }
    files = {
        "market-daily.csv": daily_data,
        "market-technical.csv": technical_data,
        "field-catalog.csv": catalog_data,
        "quality-report.json": quality_data,
        "manifest.json": pool.json_bytes(manifest),
        ".complete": (snapshot_id + "\n").encode(),
    }
    output = pool_root / "snapshots" / snapshot_id
    publish_tree(output, files)
    verify_mt_snapshot(output)
    return output, quality


def add_years(value: str, years: int) -> str:
    parsed = date.fromisoformat(value)
    return parsed.replace(year=parsed.year + years).isoformat()


def baseline_directories(report_root: Path) -> dict[str, Path]:
    return {sample: report_root / name for sample, name in BASELINE_NAMES.items()}


def verify_baselines(report_root: Path) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for sample, directory in baseline_directories(report_root).items():
        manifest_path = directory / "manifest.json"
        complete_path = directory / ".complete"
        store_path = directory / "browse.store"
        require(manifest_path.is_file() and complete_path.is_file() and store_path.is_file(),
                f"Baseline {sample} is incomplete: {directory}")
        manifest = read_json(manifest_path)
        require(manifest.get("sampleID") == sample, f"Baseline {sample} sample ID mismatch")
        require(manifest.get("periodStarts") == ["2017/07/22", "2020/07/22", "2023/07/22"],
                f"Baseline {sample} fixed windows mismatch")
        require(manifest.get("through") == "2026/07/22", f"Baseline {sample} cutoff mismatch")
        require(complete_path.read_text().strip() == manifest.get("runID"),
                f"Baseline {sample} completion marker mismatch")
        connection = sqlite3.connect(f"file:{store_path.resolve()}?mode=ro", uri=True)
        try:
            integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
            dates = [
                row[0]
                for row in connection.execute(
                    f"""
                    SELECT DISTINCT date(t.ZDATETIME + {APPLE_REFERENCE_UNIX_OFFSET}, 'unixepoch')
                      FROM ZTRADE t
                     WHERE t.ZDATASOURCE = 'TWSE'
                     ORDER BY t.ZDATETIME
                    """
                )
            ]
        finally:
            connection.close()
        require(integrity == "ok", f"Baseline {sample} browse.store integrity={integrity}")
        result[sample] = {
            "directory": directory,
            "manifest": manifest,
            "manifest_sha256": pool.sha256(manifest_path.read_bytes()),
            "dates": dates,
            "integrity": integrity,
        }
    return result


def window_specs(baselines: dict[str, dict[str, Any]]) -> list[dict[str, str]]:
    first = baselines["A"]["manifest"]
    starts = [value.replace("/", "-") for value in first["periodStarts"]]
    through = first["through"].replace("/", "-")
    result = []
    for index, start in enumerate(starts, start=1):
        end = min(add_years(start, 3), through)
        result.append({"window_id": f"W{index}", "declared_start": start, "declared_end": end})
    return result


def build_fragment_files(
    spec: dict[str, str],
    source_rows: list[dict[str, Any]],
    technical_rows: list[dict[str, Any]],
    parent_snapshot_id: str,
) -> tuple[str, dict[str, bytes], dict[str, Any], set[str]]:
    selected_indices = [
        index for index, row in enumerate(source_rows)
        if spec["declared_start"] <= row["date"] <= spec["declared_end"]
    ]
    require(bool(selected_indices), f"market fragment {spec['window_id']} is empty")
    selected_source = [source_rows[index] for index in selected_indices]
    selected_technical = [technical_rows[index] for index in selected_indices]
    daily_data = csv_bytes(selected_source, list(source_rows[0].keys()))
    technical_data = mt.encode_csv(selected_technical, mt.OUTPUT_FIELDS)
    fragment_id = (
        f"fixed-{spec['window_id'].lower()}-{spec['declared_start'].replace('-', '')}-"
        f"{spec['declared_end'].replace('-', '')}-{pool.sha256(technical_data)[:12]}"
    )
    manifest = {
        "fragment_id": fragment_id,
        "window_id": spec["window_id"],
        "declared_start": spec["declared_start"],
        "declared_end": spec["declared_end"],
        "actual_first_market_date": selected_source[0]["date"],
        "actual_last_market_date": selected_source[-1]["date"],
        "row_count": len(selected_source),
        "boundary_semantics": "declared start and end are inclusive, matching Baseline period labels",
        "parent_snapshot_id": parent_snapshot_id,
        "files": {
            "market-daily.csv": pool.sha256(daily_data),
            "market-technical.csv": pool.sha256(technical_data),
        },
    }
    files = {
        "market-daily.csv": daily_data,
        "market-technical.csv": technical_data,
        "manifest.json": pool.json_bytes(manifest),
        ".complete": (fragment_id + "\n").encode(),
    }
    return fragment_id, files, manifest, {row["date"] for row in selected_source}


def encode_mapping(rows: list[dict[str, Any]]) -> bytes:
    fields = [
        "sample_id", "baseline_run_id", "baseline_manifest_sha256", "window_id",
        "declared_start", "declared_end", "fragment_id", "fragment_manifest_sha256",
        "market_row_count", "baseline_distinct_twse_date_count", "missing_baseline_date_count",
    ]
    return mt.encode_csv(rows, fields)


def build_reuse_package(
    pool_root: Path,
    source_rows: list[dict[str, Any]],
    technical_rows: list[dict[str, Any]],
    full_snapshot_id: str,
    baselines: dict[str, dict[str, Any]],
    prefix_quality: dict[str, Any],
    offline_quality: dict[str, Any],
    tamper_quality: dict[str, Any],
) -> Path:
    tree: dict[str, bytes] = {}
    fragment_records: dict[str, dict[str, Any]] = {}
    fragment_dates: dict[str, set[str]] = {}
    for spec in window_specs(baselines):
        fragment_id, files, manifest, dates = build_fragment_files(
            spec, source_rows, technical_rows, full_snapshot_id
        )
        fragment_records[spec["window_id"]] = manifest
        fragment_dates[spec["window_id"]] = dates
        for name, data in files.items():
            tree[f"fragments/{fragment_id}/{name}"] = data

    mappings: list[dict[str, Any]] = []
    for sample in "ABCDE":
        baseline = baselines[sample]
        for spec in window_specs(baselines):
            fragment = fragment_records[spec["window_id"]]
            baseline_dates = {
                value for value in baseline["dates"]
                if spec["declared_start"] <= value <= spec["declared_end"]
            }
            missing = baseline_dates - fragment_dates[spec["window_id"]]
            require(not missing,
                    f"Baseline {sample} {spec['window_id']} dates missing from market fragment: {sorted(missing)[:3]}")
            fragment_manifest_path = f"fragments/{fragment['fragment_id']}/manifest.json"
            mappings.append({
                "sample_id": sample,
                "baseline_run_id": baseline["manifest"]["runID"],
                "baseline_manifest_sha256": baseline["manifest_sha256"],
                "window_id": spec["window_id"],
                "declared_start": spec["declared_start"],
                "declared_end": spec["declared_end"],
                "fragment_id": fragment["fragment_id"],
                "fragment_manifest_sha256": pool.sha256(tree[fragment_manifest_path]),
                "market_row_count": fragment["row_count"],
                "baseline_distinct_twse_date_count": len(baseline_dates),
                "missing_baseline_date_count": 0,
            })
    require(len(mappings) == 15, f"expected 15 sample-window mappings, got {len(mappings)}")
    mapping_data = encode_mapping(mappings)
    tree["sample-window-map.csv"] = mapping_data
    identity = pool.sha256(
        TOOL_VERSION.encode()
        + full_snapshot_id.encode()
        + mapping_data
        + b"".join(tree[name] for name in sorted(tree) if name.endswith("manifest.json"))
    )
    package_id = f"mkt-d01-p3-reuse-20260722-{identity[:12]}"
    quality = {
        "package_id": package_id,
        "full_snapshot_id": full_snapshot_id,
        "prefix_snapshot_id": prefix_quality["snapshot_id"],
        "offline_rebuild": offline_quality,
        "prefix_snapshot": prefix_quality,
        "tamper_rejection": tamper_quality,
        "physical_fragment_count": len(fragment_records),
        "logical_sample_window_mapping_count": len(mappings),
        "per_sample_duplicate_physical_copy_count": 0,
        "shared_boundary_market_dates": [
            {
                "windows": ["W1", "W2"],
                "dates": sorted(fragment_dates["W1"] & fragment_dates["W2"]),
            },
            {
                "windows": ["W2", "W3"],
                "dates": sorted(fragment_dates["W2"] & fragment_dates["W3"]),
            },
        ],
        "missing_baseline_date_count": sum(row["missing_baseline_date_count"] for row in mappings),
        "fragments": [fragment_records[key] for key in sorted(fragment_records)],
        "baselines": {
            sample: {
                "run_id": baselines[sample]["manifest"]["runID"],
                "manifest_sha256": baselines[sample]["manifest_sha256"],
                "sqlite_integrity": baselines[sample]["integrity"],
            }
            for sample in "ABCDE"
        },
        "network_request_count": 0,
        "simupdate_run_count": 0,
        "passed": True,
    }
    quality_data = pool.json_bytes(quality)
    tree["quality-report.json"] = quality_data
    manifest = {
        "package_id": package_id,
        "tool": "tools/market_snapshot_reuse.py",
        "tool_version": TOOL_VERSION,
        "full_snapshot_id": full_snapshot_id,
        "prefix_snapshot_id": prefix_quality["snapshot_id"],
        "physical_fragment_count": len(fragment_records),
        "logical_mapping_count": len(mappings),
        "files": {name: pool.sha256(data) for name, data in sorted(tree.items())},
        "qualification_passed": True,
    }
    tree["manifest.json"] = pool.json_bytes(manifest)
    tree[".complete"] = (package_id + "\n").encode()
    output = pool_root / "reuse" / package_id
    publish_tree(output, tree)
    verify_hashed_bundle(output, id_key="package_id", file_hashes_key="files")
    for fragment in fragment_records.values():
        verify_hashed_bundle(
            output / "fragments" / fragment["fragment_id"],
            id_key="fragment_id",
            file_hashes_key="files",
            expected_id=fragment["fragment_id"],
        )
    return output


def publish_tree(output: Path, files: dict[str, bytes]) -> None:
    if output.exists():
        existing = {
            str(path.relative_to(output)): path.read_bytes()
            for path in output.rglob("*") if path.is_file()
        }
        require(existing == files, f"existing immutable output differs: {output}")
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temporary:
        staging = Path(temporary) / output.name
        staging.mkdir()
        for name, data in files.items():
            pool.atomic_write(staging / name, data)
        staging.rename(output)


def tamper_rejection_qualification(snapshot: Path) -> dict[str, Any]:
    outcomes: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        changed = root / "changed"
        shutil.copytree(snapshot, changed)
        target = changed / "market-technical.csv"
        data = target.read_bytes()
        target.write_bytes(data[:-1] + (b"0" if data[-1:] != b"0" else b"1"))
        try:
            verify_mt_snapshot(changed)
        except pool.MarketDataError as error:
            outcomes.append({"case": "content_changed", "rejected": True,
                             "reason_contains": "hash mismatch" in str(error)})
        else:
            raise pool.MarketDataError("tampered snapshot content was accepted")

        missing = root / "missing"
        shutil.copytree(snapshot, missing)
        (missing / "market-technical.csv").rename(missing / "market-technical.renamed.csv")
        try:
            verify_mt_snapshot(missing)
        except pool.MarketDataError as error:
            outcomes.append({"case": "file_renamed", "rejected": True,
                             "reason_contains": "missing" in str(error)})
        else:
            raise pool.MarketDataError("snapshot with renamed hashed file was accepted")
    require(len(outcomes) == 2 and all(row["rejected"] and row["reason_contains"] for row in outcomes),
            "tamper rejection diagnostics were incomplete")
    return {"cases": outcomes, "rejected_count": 2, "fallback_fetch_count": 0, "passed": True}


def build(args: argparse.Namespace) -> Path:
    pool_root = args.pool_root.resolve()
    full_snapshot = args.full_snapshot.resolve()
    normalized_input = args.normalized_input.resolve()
    report_root = args.report_root.resolve()
    with forbid_network() as network:
        source_rows, technical_rows, offline_quality = offline_rebuild_qualification(
            full_snapshot, normalized_input
        )
        prefix_snapshot, prefix_quality = build_prefix_snapshot(
            pool_root, full_snapshot, source_rows, technical_rows
        )
        require(verify_mt_snapshot(prefix_snapshot)["cutoff_date"] == PREFIX_CUTOFF,
                "prefix snapshot verification failed")
        baselines = verify_baselines(report_root)
        tamper_quality = tamper_rejection_qualification(full_snapshot)
        output = build_reuse_package(
            pool_root,
            source_rows,
            technical_rows,
            full_snapshot.name,
            baselines,
            prefix_quality,
            offline_quality,
            tamper_quality,
        )
        require(network["count"] == 0, f"P3 attempted {network['count']} network requests")
    return output


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    command = subparsers.add_parser("build", help="run MKT-D01-P3 entirely offline")
    command.add_argument("--pool-root", type=Path, default=DEFAULT_POOL_ROOT)
    command.add_argument("--full-snapshot", type=Path, default=DEFAULT_FULL_SNAPSHOT)
    command.add_argument("--normalized-input", type=Path, default=DEFAULT_NORMALIZED_INPUT)
    command.add_argument("--report-root", type=Path, default=DEFAULT_REPORT_ROOT)
    return parser.parse_args()


def main() -> int:
    args = arguments()
    try:
        if args.command == "build":
            print(build(args))
            return 0
    except (OSError, ValueError, json.JSONDecodeError, sqlite3.Error, pool.MarketDataError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
