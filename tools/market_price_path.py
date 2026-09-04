#!/usr/bin/env python3
"""Build the offline MKT-PP-P1 TAIEX nine-phase price-path artifact."""

from __future__ import annotations

import argparse
import csv
import io
import json
import math
import statistics
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import market_data_pool as pool
import market_snapshot_reuse as reuse
import market_technical as mt


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SNAPSHOT = (
    ROOT
    / "exports/market-data/taiex/snapshots"
    / "taiex-market-mt1-20260722-a00beac8d4af"
)
DEFAULT_OUTPUT_ROOT = ROOT / "exports/market-data/taiex/research"
SWIFT_CLASSIFIER = ROOT / "simStock3/RollingPricePath.swift"
TOOL_VERSION = "market-price-path-t3-v1"

HORIZON = 20
VOLATILITY_LOOKBACK = 60
MINIMUM_RETURN_COUNT = 40
MINIMUM_BARRIER = 0.05
MAXIMUM_BARRIER = 0.15

PHASES = {
    0: ("unavailable", "資料不足"),
    1: ("sideways", "盤整"),
    2: ("seeking_peak_early", "探頂前期"),
    3: ("seeking_peak_late", "探頂後期"),
    4: ("pulling_back_early", "拉回前期"),
    5: ("pulling_back_late", "拉回後期"),
    6: ("seeking_bottom_early", "探底前期"),
    7: ("seeking_bottom_late", "探底後期"),
    8: ("rebounding_early", "反彈前期"),
    9: ("rebounding_late", "反彈後期"),
}

WINDOWS = (
    ("W1", "2017-07-22", "2020-07-22", False),
    ("W2", "2020-07-22", "2023-07-22", False),
    ("W3", "2023-07-22", "2026-07-22", True),
)

LABEL_FIELDS = [
    "date",
    "close",
    "phase_raw",
    "phase_id",
    "phase_name",
    "available_barrier",
    "frozen_barrier",
    "anchor_close",
    "extreme_close",
    "days_since_extreme",
]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise pool.MarketDataError(message)


def ordered_sum(values: Iterable[float]) -> float:
    total = 0.0
    for value in values:
        total += value
    return total


def volatility_barrier(log_returns: list[float]) -> float | None:
    values = [value for value in log_returns if math.isfinite(value)]
    if len(values) < MINIMUM_RETURN_COUNT:
        return None
    mean = ordered_sum(values) / float(len(values))
    squared_deviation = ordered_sum(
        math.pow(value - mean, 2) for value in values
    )
    sigma = math.sqrt(squared_deviation / float(len(values) - 1))
    require(math.isfinite(sigma), "price-path volatility is not finite")
    return min(max(sigma * math.sqrt(float(HORIZON)), MINIMUM_BARRIER), MAXIMUM_BARRIER)


@dataclass(frozen=True)
class PricePathState:
    phase_raw: int
    barrier: float
    anchor_close: float
    extreme_close: float
    days_since_extreme: int


def sideways_state(close: float, barrier: float) -> PricePathState:
    return PricePathState(1, barrier, close, close, 0)


def seeking_peak_phase(anchor_close: float, extreme_close: float, barrier: float) -> int:
    progress = (extreme_close / anchor_close - 1.0) / barrier
    return 3 if progress >= 1.5 else 2


def seeking_bottom_phase(anchor_close: float, extreme_close: float, barrier: float) -> int:
    progress = ((anchor_close - extreme_close) / anchor_close) / barrier
    return 7 if progress >= 1.5 else 6


def pulling_back_phase(pullback: float, barrier: float) -> int:
    return 5 if pullback / barrier >= 0.75 else 4


def rebounding_phase(rebound: float, barrier: float) -> int:
    return 9 if rebound / barrier >= 0.75 else 8


class PricePathRollingContext:
    """Python port of the T3 PricePathRollingContext used by tUpdate."""

    def __init__(self) -> None:
        self.recent_log_returns: list[float] = []
        self.previous_date: str | None = None
        self.previous_close: float | None = None
        self.state: PricePathState | None = None
        self.available_barrier: float | None = None

    def reset(self) -> None:
        self.recent_log_returns.clear()
        self.previous_date = None
        self.previous_close = None
        self.state = None
        self.available_barrier = None

    def update(self, date: str, close: float) -> PricePathState | None:
        if not math.isfinite(close) or close <= 0:
            self.reset()
            return None
        if self.previous_date is None or self.previous_close is None:
            self.previous_date = date
            self.previous_close = close
            self.state = None
            self.available_barrier = None
            return None
        if date <= self.previous_date:
            self.reset()
            self.previous_date = date
            self.previous_close = close
            return None

        self.recent_log_returns.append(math.log(close / self.previous_close))
        if len(self.recent_log_returns) > VOLATILITY_LOOKBACK:
            self.recent_log_returns = self.recent_log_returns[-VOLATILITY_LOOKBACK:]
        self.previous_date = date
        self.previous_close = close
        self.available_barrier = volatility_barrier(self.recent_log_returns)
        if self.available_barrier is None:
            self.state = None
            return None
        if self.state is None:
            self.state = sideways_state(close, self.available_barrier)
        else:
            self.state = self._next(self.state, close, self.available_barrier)
        return self.state

    def _next(
        self,
        previous: PricePathState,
        close: float,
        available_barrier: float,
    ) -> PricePathState:
        phase = previous.phase_raw
        if phase == 0:
            return sideways_state(close, available_barrier)

        if phase == 1:
            change = close / previous.anchor_close - 1.0
            if change >= previous.barrier:
                return PricePathState(
                    seeking_peak_phase(previous.anchor_close, close, previous.barrier),
                    previous.barrier,
                    previous.anchor_close,
                    close,
                    0,
                )
            if change <= -previous.barrier:
                return PricePathState(
                    seeking_bottom_phase(previous.anchor_close, close, previous.barrier),
                    previous.barrier,
                    previous.anchor_close,
                    close,
                    0,
                )
            return previous

        if phase in (2, 3):
            if close > previous.extreme_close:
                return PricePathState(
                    seeking_peak_phase(previous.anchor_close, close, previous.barrier),
                    previous.barrier,
                    previous.anchor_close,
                    close,
                    0,
                )
            days = previous.days_since_extreme + 1
            pullback = (previous.extreme_close - close) / previous.extreme_close
            if pullback >= previous.barrier / 2.0:
                return PricePathState(
                    pulling_back_phase(pullback, previous.barrier),
                    previous.barrier,
                    previous.anchor_close,
                    previous.extreme_close,
                    days,
                )
            return self._sideways_if_stale(previous, close, available_barrier, days)

        if phase in (4, 5):
            if close > previous.extreme_close:
                return PricePathState(
                    seeking_peak_phase(previous.anchor_close, close, previous.barrier),
                    previous.barrier,
                    previous.anchor_close,
                    close,
                    0,
                )
            days = previous.days_since_extreme + 1
            pullback = (previous.extreme_close - close) / previous.extreme_close
            if pullback >= previous.barrier:
                return PricePathState(
                    seeking_bottom_phase(previous.extreme_close, close, available_barrier),
                    available_barrier,
                    previous.extreme_close,
                    close,
                    0,
                )
            candidate = PricePathState(
                pulling_back_phase(pullback, previous.barrier),
                previous.barrier,
                previous.anchor_close,
                previous.extreme_close,
                days,
            )
            return self._sideways_if_stale(candidate, close, available_barrier, days)

        if phase in (6, 7):
            if close < previous.extreme_close:
                return PricePathState(
                    seeking_bottom_phase(previous.anchor_close, close, previous.barrier),
                    previous.barrier,
                    previous.anchor_close,
                    close,
                    0,
                )
            days = previous.days_since_extreme + 1
            rebound = (close - previous.extreme_close) / previous.extreme_close
            if rebound >= previous.barrier / 2.0:
                return PricePathState(
                    rebounding_phase(rebound, previous.barrier),
                    previous.barrier,
                    previous.anchor_close,
                    previous.extreme_close,
                    days,
                )
            return self._sideways_if_stale(previous, close, available_barrier, days)

        require(phase in (8, 9), f"unknown T3 price-path phase: {phase}")
        if close < previous.extreme_close:
            return PricePathState(
                seeking_bottom_phase(previous.anchor_close, close, previous.barrier),
                previous.barrier,
                previous.anchor_close,
                close,
                0,
            )
        days = previous.days_since_extreme + 1
        rebound = (close - previous.extreme_close) / previous.extreme_close
        if rebound >= previous.barrier:
            return PricePathState(
                seeking_peak_phase(previous.extreme_close, close, available_barrier),
                available_barrier,
                previous.extreme_close,
                close,
                0,
            )
        candidate = PricePathState(
            rebounding_phase(rebound, previous.barrier),
            previous.barrier,
            previous.anchor_close,
            previous.extreme_close,
            days,
        )
        return self._sideways_if_stale(candidate, close, available_barrier, days)

    @staticmethod
    def _sideways_if_stale(
        state: PricePathState,
        close: float,
        available_barrier: float,
        days_since_extreme: int,
    ) -> PricePathState:
        if days_since_extreme >= HORIZON:
            return sideways_state(close, available_barrier)
        if state.days_since_extreme == days_since_extreme:
            return state
        return PricePathState(
            state.phase_raw,
            state.barrier,
            state.anchor_close,
            state.extreme_close,
            days_since_extreme,
        )


def calculate_labels(source_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    context = PricePathRollingContext()
    output: list[dict[str, Any]] = []
    for source in source_rows:
        close = float(source["close"])
        state = context.update(str(source["date"]), close)
        phase_raw = state.phase_raw if state is not None else 0
        phase_id, phase_name = PHASES[phase_raw]
        output.append({
            "date": source["date"],
            "close": close,
            "phase_raw": phase_raw,
            "phase_id": phase_id,
            "phase_name": phase_name,
            "available_barrier": context.available_barrier,
            "frozen_barrier": state.barrier if state is not None else None,
            "anchor_close": state.anchor_close if state is not None else None,
            "extreme_close": state.extreme_close if state is not None else None,
            "days_since_extreme": state.days_since_extreme if state is not None else None,
        })
    return output


def encode_csv(rows: list[dict[str, Any]], fields: list[str]) -> bytes:
    buffer = io.StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=fields, lineterminator="\n")
    writer.writeheader()
    for row in rows:
        encoded: dict[str, Any] = {}
        for field in fields:
            value = row[field]
            if value is None:
                encoded[field] = ""
            elif isinstance(value, float):
                require(math.isfinite(value), f"non-finite output: {field}")
                encoded[field] = repr(value)
            else:
                encoded[field] = value
        writer.writerow(encoded)
    return buffer.getvalue().encode("utf-8")


def rows_for_scope(labels: list[dict[str, Any]], scope: str) -> list[dict[str, Any]]:
    if scope == "ALL":
        return labels
    spec = next(item for item in WINDOWS if item[0] == scope)
    _, start, end, inclusive_end = spec
    return [
        row for row in labels
        if row["date"] >= start and (row["date"] <= end if inclusive_end else row["date"] < end)
    ]


def distribution_rows(labels: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for scope in ("ALL", "W1", "W2", "W3"):
        selected = rows_for_scope(labels, scope)
        labeled_count = sum(row["phase_raw"] != 0 for row in selected)
        for phase_raw, (phase_id, phase_name) in PHASES.items():
            count = sum(row["phase_raw"] == phase_raw for row in selected)
            denominator = len(selected) if phase_raw == 0 else labeled_count
            output.append({
                "scope": scope,
                "market_day_count": len(selected),
                "labeled_day_count": labeled_count,
                "phase_raw": phase_raw,
                "phase_id": phase_id,
                "phase_name": phase_name,
                "count": count,
                "share": count / denominator if denominator else 0.0,
            })
    return output


def phase_runs(labels: list[dict[str, Any]]) -> list[dict[str, Any]]:
    labeled = [row for row in labels if row["phase_raw"] != 0]
    require(bool(labeled), "price-path output has no labeled rows")
    output: list[dict[str, Any]] = []
    start = 0
    for index in range(1, len(labeled) + 1):
        if index < len(labeled) and labeled[index]["phase_raw"] == labeled[start]["phase_raw"]:
            continue
        phase_raw = labeled[start]["phase_raw"]
        phase_id, phase_name = PHASES[phase_raw]
        output.append({
            "run_id": len(output) + 1,
            "phase_raw": phase_raw,
            "phase_id": phase_id,
            "phase_name": phase_name,
            "start_date": labeled[start]["date"],
            "end_date": labeled[index - 1]["date"],
            "market_day_count": index - start,
        })
        start = index
    return output


ALLOWED_TRANSITIONS = {
    1: {1, 2, 3, 6, 7},
    2: {1, 2, 3, 4, 5},
    3: {1, 3, 4, 5},
    4: {1, 2, 3, 4, 5, 6, 7},
    5: {1, 2, 3, 4, 5, 6, 7},
    6: {1, 6, 7, 8, 9},
    7: {1, 7, 8, 9},
    8: {1, 2, 3, 6, 7, 8, 9},
    9: {1, 2, 3, 6, 7, 8, 9},
}


def transition_mismatches(labels: list[dict[str, Any]]) -> list[tuple[int, int, str]]:
    phases = [row for row in labels if row["phase_raw"] != 0]
    return [
        (previous["phase_raw"], current["phase_raw"], current["date"])
        for previous, current in zip(phases, phases[1:])
        if current["phase_raw"] not in ALLOWED_TRANSITIONS[previous["phase_raw"]]
    ]


def build_quality(
    source_rows: list[dict[str, Any]],
    labels: list[dict[str, Any]],
    prefix_rows: list[dict[str, Any]],
    runs: list[dict[str, Any]],
) -> dict[str, Any]:
    prefix_labels = calculate_labels(prefix_rows)
    prefix_mismatch_count = sum(
        left != right for left, right in zip(prefix_labels, labels[: len(prefix_labels)])
    ) + abs(len(prefix_labels) - len(labels[: len(prefix_labels)]))
    second_labels = calculate_labels(source_rows)
    deterministic = encode_csv(labels, LABEL_FIELDS) == encode_csv(second_labels, LABEL_FIELDS)
    labeled = [row for row in labels if row["phase_raw"] != 0]
    available = [row["available_barrier"] for row in labeled]
    frozen = [row["frozen_barrier"] for row in labeled]
    transitions = transition_mismatches(labels)
    phase_presence = {
        scope: sorted({row["phase_raw"] for row in rows_for_scope(labels, scope) if row["phase_raw"]})
        for scope in ("ALL", "W1", "W2", "W3")
    }
    run_lengths: dict[str, dict[str, float | int]] = {}
    for phase_raw in range(1, 10):
        values = [row["market_day_count"] for row in runs if row["phase_raw"] == phase_raw]
        run_lengths[PHASES[phase_raw][0]] = {
            "run_count": len(values),
            "minimum": min(values) if values else 0,
            "median": statistics.median(values) if values else 0,
            "mean": ordered_sum(float(value) for value in values) / len(values) if values else 0,
            "maximum": max(values) if values else 0,
        }
    quality = {
        "task_id": "MKT-PP-P1",
        "tool_version": TOOL_VERSION,
        "source_row_count": len(source_rows),
        "output_row_count": len(labels),
        "unavailable_row_count": len(labels) - len(labeled),
        "labeled_row_count": len(labeled),
        "first_labeled_date": labeled[0]["date"],
        "last_labeled_date": labeled[-1]["date"],
        "invalid_phase_count": sum(row["phase_raw"] not in PHASES for row in labels),
        "invalid_state_value_count": sum(
            row["phase_raw"] != 0 and (
                row["frozen_barrier"] is None
                or row["anchor_close"] is None
                or row["extreme_close"] is None
                or row["days_since_extreme"] is None
                or row["frozen_barrier"] < MINIMUM_BARRIER
                or row["frozen_barrier"] > MAXIMUM_BARRIER
                or row["anchor_close"] <= 0
                or row["extreme_close"] <= 0
                or row["days_since_extreme"] < 0
            )
            for row in labels
        ),
        "illegal_transition_count": len(transitions),
        "illegal_transition_examples": transitions[:5],
        "prefix_cutoff": prefix_rows[-1]["date"],
        "prefix_row_count": len(prefix_rows),
        "prefix_mismatch_count": prefix_mismatch_count,
        "deterministic_rebuild_verified": deterministic,
        "phase_presence_by_scope": phase_presence,
        "all_nine_phases_present_by_scope": {
            scope: phases == list(range(1, 10)) for scope, phases in phase_presence.items()
        },
        "available_barrier": {
            "minimum_clamp_count": sum(value == MINIMUM_BARRIER for value in available),
            "maximum_clamp_count": sum(value == MAXIMUM_BARRIER for value in available),
            "interior_count": sum(MINIMUM_BARRIER < value < MAXIMUM_BARRIER for value in available),
            "minimum": min(available),
            "median": statistics.median(available),
            "maximum": max(available),
        },
        "frozen_barrier": {
            "minimum_clamp_day_count": sum(value == MINIMUM_BARRIER for value in frozen),
            "maximum_clamp_day_count": sum(value == MAXIMUM_BARRIER for value in frozen),
            "interior_day_count": sum(MINIMUM_BARRIER < value < MAXIMUM_BARRIER for value in frozen),
            "minimum": min(frozen),
            "median": statistics.median(frozen),
            "maximum": max(frozen),
        },
        "phase_run_lengths": run_lengths,
    }
    quality["passed"] = (
        quality["source_row_count"] == quality["output_row_count"]
        and quality["unavailable_row_count"] == MINIMUM_RETURN_COUNT
        and quality["invalid_phase_count"] == 0
        and quality["invalid_state_value_count"] == 0
        and quality["illegal_transition_count"] == 0
        and quality["prefix_mismatch_count"] == 0
        and quality["deterministic_rebuild_verified"]
    )
    require(bool(quality["passed"]), "MKT-PP-P1 quality gate failed")
    return quality


def report_text(
    artifact_id: str,
    quality: dict[str, Any],
    distribution: list[dict[str, Any]],
) -> str:
    lookup = {
        (row["scope"], row["phase_raw"]): row for row in distribution
        if row["phase_raw"] != 0
    }
    lines = [
        "# MKT-PP-P1 大盤九階段價格路徑",
        "",
        f"- 產物：`{artifact_id}`",
        "- 唯一變因：將 App T3 的 `PricePathRollingContext` 原公式套用於 TAIEX 收盤價；未調整任何門檻。",
        f"- 資料：2016/01/04～2026/07/22，共 {quality['source_row_count']:,} 個市場日。",
        f"- 暖機：前 {quality['unavailable_row_count']} 日無標籤；首個有效標籤為 {quality['first_labeled_date'].replace('-', '/')}。",
        "- 邊界：本產物不修改 MT1、App schema、T/S、Baseline 或任何買賣規則。",
        "",
        "## 三窗口分布",
        "",
        "| 階段 | W1 | W2 | W3 |",
        "|---|---:|---:|---:|",
    ]
    for phase_raw in range(1, 10):
        values = [lookup[(scope, phase_raw)] for scope in ("W1", "W2", "W3")]
        lines.append(
            f"| {PHASES[phase_raw][1]} | "
            + " | ".join(f"{row['count']}（{row['share']:.1%}）" for row in values)
            + " |"
        )
    barrier = quality["available_barrier"]
    labeled = quality["labeled_row_count"]
    lines += [
        "",
        "## 驗證",
        "",
        f"- 九階段在全部與 W1～W3 是否都有出現：`{all(quality['all_nine_phases_present_by_scope'].values())}`。",
        f"- 前綴重算差異：{quality['prefix_mismatch_count']}；非法轉換：{quality['illegal_transition_count']}；無效狀態：{quality['invalid_state_value_count']}。",
        f"- 可用門檻落在 5% 下限：{barrier['minimum_clamp_count']:,}/{labeled:,}（{barrier['minimum_clamp_count'] / labeled:.1%}）；落在 15% 上限：{barrier['maximum_clamp_count']:,}/{labeled:,}（{barrier['maximum_clamp_count'] / labeled:.1%}）。",
        "- 產物可決定性重建，且 2026/06/30 獨立前綴與完整重播相同日期逐列一致。",
        "",
        "## 判讀界線",
        "",
        "這證明 T3 九階段能以決策當日及以前的大盤收盤價穩定產生，並不證明任何階段能改善策略。若後續研究大盤階段與個股階段或既有動作的交互，仍須另立候選及完整 `simUpdate` 驗證。",
        "",
    ]
    return "\n".join(lines)


def build(snapshot: Path, output_root: Path) -> Path:
    manifest = reuse.verify_mt_snapshot(snapshot)
    source_rows, source_bytes = mt.read_market_daily(snapshot / "market-daily.csv")
    labels = calculate_labels(source_rows)
    prefix_rows = [row for row in source_rows if row["date"] <= "2026-06-30"]
    require(prefix_rows[-1]["date"] == "2026-06-30", "prefix cutoff is missing")
    runs = phase_runs(labels)
    distribution = distribution_rows(labels)
    label_data = encode_csv(labels, LABEL_FIELDS)
    distribution_fields = [
        "scope", "market_day_count", "labeled_day_count", "phase_raw",
        "phase_id", "phase_name", "count", "share",
    ]
    distribution_data = encode_csv(distribution, distribution_fields)
    run_fields = [
        "run_id", "phase_raw", "phase_id", "phase_name",
        "start_date", "end_date", "market_day_count",
    ]
    run_data = encode_csv(runs, run_fields)
    quality = build_quality(source_rows, labels, prefix_rows, runs)
    identity = pool.sha256(
        (manifest["snapshot_id"] + "\n" + TOOL_VERSION + "\n").encode("utf-8")
        + label_data
    )
    artifact_id = f"mkt-pp-p1-taiex-price-path-{identity[:12]}"
    quality["artifact_id"] = artifact_id
    quality["source_snapshot_id"] = manifest["snapshot_id"]
    quality_data = pool.json_bytes(quality)
    report_data = report_text(artifact_id, quality, distribution).encode("utf-8")
    file_data = {
        "market-price-path.csv": label_data,
        "phase-distribution.csv": distribution_data,
        "phase-runs.csv": run_data,
        "quality-report.json": quality_data,
        "report.md": report_data,
    }
    output_manifest = {
        "artifact_id": artifact_id,
        "task_id": "MKT-PP-P1",
        "tool": "tools/market_price_path.py",
        "tool_version": TOOL_VERSION,
        "source_snapshot_id": manifest["snapshot_id"],
        "source_market_daily_sha256": pool.sha256(source_bytes),
        "swift_classifier": "simStock3/RollingPricePath.swift",
        "swift_classifier_sha256": pool.sha256(SWIFT_CLASSIFIER.read_bytes()),
        "classifier_contract": {
            "horizon": HORIZON,
            "volatility_lookback": VOLATILITY_LOOKBACK,
            "minimum_return_count": MINIMUM_RETURN_COUNT,
            "minimum_barrier": MINIMUM_BARRIER,
            "maximum_barrier": MAXIMUM_BARRIER,
            "phase_raw_values": {str(key): value[0] for key, value in PHASES.items()},
        },
        "row_count": len(labels),
        "labeled_row_count": quality["labeled_row_count"],
        "files": {name: pool.sha256(data) for name, data in file_data.items()},
        "qualification_passed": True,
        "formal_effect": "none",
    }
    files = {
        **file_data,
        "manifest.json": pool.json_bytes(output_manifest),
        ".complete": (artifact_id + "\n").encode("utf-8"),
    }
    output = output_root / artifact_id
    reuse.publish_tree(output, files)
    reuse.verify_hashed_bundle(output, id_key="artifact_id", file_hashes_key="files")
    return output


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, default=DEFAULT_SNAPSHOT)
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    return parser.parse_args()


def main() -> int:
    args = arguments()
    try:
        print(build(args.snapshot.resolve(), args.output_root.resolve()))
        return 0
    except (OSError, ValueError, json.JSONDecodeError, pool.MarketDataError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
