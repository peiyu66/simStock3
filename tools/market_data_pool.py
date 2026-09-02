#!/usr/bin/env python3
"""Build the reusable, non-App TAIEX market-data research pool."""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
import re
import sqlite3
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import date, datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Callable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_POOL_ROOT = ROOT / "exports/market-data/taiex"
NORMALIZER_VERSION = "market-daily-v1"
TAIPEI_OFFSET = "+08:00"
APPLE_REFERENCE_UNIX_OFFSET = 978_307_200


class MarketDataError(RuntimeError):
    pass


@dataclass(frozen=True)
class SourceSpec:
    key: str
    cache_slug: str
    endpoint: str
    fields: tuple[str, ...]

    def url(self, month: str, response: str = "json") -> str:
        compact = month.replace("-", "") + "01"
        return f"{self.endpoint}?response={response}&date={compact}"


PRICE = SourceSpec(
    key="price",
    cache_slug="mi-5mins-hist",
    endpoint="https://www.twse.com.tw/indicesReport/MI_5MINS_HIST",
    fields=("日期", "開盤指數", "最高指數", "最低指數", "收盤指數"),
)
ACTIVITY = SourceSpec(
    key="activity",
    cache_slug="fmtqik",
    endpoint="https://www.twse.com.tw/exchangeReport/FMTQIK",
    fields=("日期", "成交股數", "成交金額", "成交筆數", "發行量加權股價指數", "漲跌點數"),
)
SOURCES = (PRICE, ACTIVITY)


@dataclass(frozen=True)
class CacheRevision:
    source: SourceSpec
    month: str
    sha256: str
    acquired_at: str
    raw_path: Path
    metadata_path: Path


class Downloader:
    def __init__(self, initial_delay: float = 1.5, fallback_delay: float = 5.0):
        self.delay = initial_delay
        self.fallback_delay = fallback_delay
        self.last_completed: float | None = None
        self.retry_delays = (15.0, 30.0, 60.0)

    def _wait_between_requests(self) -> None:
        if self.last_completed is None:
            return
        remaining = self.delay - (time.monotonic() - self.last_completed)
        if remaining > 0:
            time.sleep(remaining)

    def fetch(
        self,
        url: str,
        validator: Callable[[bytes], None] | None = None,
    ) -> tuple[bytes, dict[str, str]]:
        last_error: Exception | None = None
        for attempt in range(len(self.retry_delays) + 1):
            if attempt > 0:
                wait = self.retry_delays[attempt - 1]
                print(f"  retry {attempt}/{len(self.retry_delays)} after {wait:.0f}s", flush=True)
                time.sleep(wait)
            self._wait_between_requests()
            request = urllib.request.Request(
                url,
                headers={
                    "Accept": "application/json,text/csv;q=0.9,*/*;q=0.1",
                    "User-Agent": "simStock3-market-research/1.0",
                },
            )
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    status = getattr(response, "status", 200)
                    if status < 200 or status >= 300:
                        raise MarketDataError(f"HTTP {status}: {url}")
                    body = response.read()
                    headers = {key.lower(): value for key, value in response.headers.items()}
                    if not body:
                        raise MarketDataError(f"empty response: {url}")
                    if validator is not None:
                        validator(body)
                    self.last_completed = time.monotonic()
                    return body, headers
            except urllib.error.HTTPError as error:
                self.last_completed = time.monotonic()
                if error.code not in {429, 500, 502, 503, 504}:
                    raise MarketDataError(
                        f"HTTP {error.code} requires stopping this source: {url}"
                    ) from error
                self.delay = max(self.delay, self.fallback_delay)
                last_error = error
                print(f"  request failed: HTTP {error.code}", flush=True)
            except (urllib.error.URLError, TimeoutError, MarketDataError) as error:
                self.last_completed = time.monotonic()
                self.delay = max(self.delay, self.fallback_delay)
                last_error = error
                print(f"  request failed: {error}", flush=True)
        raise MarketDataError(f"request failed after limited retries: {url}: {last_error}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise MarketDataError(message)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        require(path.read_bytes() == data, f"refusing to overwrite different content: {path}")
        return
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def parse_month(value: str) -> str:
    require(bool(re.fullmatch(r"\d{4}-\d{2}", value)), f"invalid month: {value}")
    year, month = (int(part) for part in value.split("-"))
    require(1 <= month <= 12 and year >= 1912, f"invalid month: {value}")
    return value


def month_range(first: str, last: str) -> list[str]:
    first = parse_month(first)
    last = parse_month(last)
    year, month = (int(part) for part in first.split("-"))
    end_year, end_month = (int(part) for part in last.split("-"))
    require((year, month) <= (end_year, end_month), "from-month is after through-month")
    result: list[str] = []
    while (year, month) <= (end_year, end_month):
        result.append(f"{year:04d}-{month:02d}")
        month += 1
        if month == 13:
            year += 1
            month = 1
    return result


def roc_date_to_iso(value: str) -> str:
    match = re.fullmatch(r"(\d{2,3})/(\d{2})/(\d{2})", value.strip())
    require(match is not None, f"invalid ROC date: {value!r}")
    assert match is not None
    year = int(match.group(1)) + 1911
    month = int(match.group(2))
    day = int(match.group(3))
    try:
        return date(year, month, day).isoformat()
    except ValueError as error:
        raise MarketDataError(f"invalid ROC date: {value!r}: {error}") from error


def clean_number(value: Any) -> str:
    require(isinstance(value, str), f"numeric source value is not a string: {value!r}")
    cleaned = value.strip().replace(",", "").replace("＋", "+").replace("－", "-")
    require(cleaned not in {"", "--"}, f"missing numeric value: {value!r}")
    return cleaned


def canonical_decimal(value: Any, *, positive: bool = False, nonnegative: bool = False) -> str:
    cleaned = clean_number(value)
    try:
        number = Decimal(cleaned)
    except InvalidOperation as error:
        raise MarketDataError(f"invalid decimal: {value!r}") from error
    require(number.is_finite(), f"non-finite decimal: {value!r}")
    if positive:
        require(number > 0, f"expected positive decimal: {value!r}")
    if nonnegative:
        require(number >= 0, f"expected nonnegative decimal: {value!r}")
    return format(number, "f")


def canonical_int(value: Any) -> int:
    cleaned = clean_number(value)
    require(bool(re.fullmatch(r"[+-]?\d+", cleaned)), f"invalid integer: {value!r}")
    number = int(cleaned)
    require(number >= 0, f"expected nonnegative integer: {value!r}")
    require(number <= 9_223_372_036_854_775_807, f"integer exceeds Int64: {value!r}")
    return number


def parse_json_rows(spec: SourceSpec, raw: bytes, expected_month: str) -> list[dict[str, Any]]:
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise MarketDataError(f"{spec.key} {expected_month} is not valid JSON: {error}") from error
    require(isinstance(payload, dict), f"{spec.key} {expected_month} payload is not an object")
    require(payload.get("stat") == "OK", f"{spec.key} {expected_month} stat is not OK")
    require(tuple(payload.get("fields", [])) == spec.fields, f"{spec.key} {expected_month} fields changed")
    if spec is ACTIVITY:
        require("元" in str(payload.get("hints", "")) and "股" in str(payload.get("hints", "")),
                f"activity {expected_month} unit hints changed")
    data = payload.get("data")
    require(isinstance(data, list) and data, f"{spec.key} {expected_month} has no rows")
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, raw_row in enumerate(data):
        require(isinstance(raw_row, list) and len(raw_row) == len(spec.fields),
                f"{spec.key} {expected_month} row {index} has wrong width")
        iso_date = roc_date_to_iso(raw_row[0])
        require(iso_date.startswith(expected_month + "-"),
                f"{spec.key} {expected_month} contains outside date {iso_date}")
        require(iso_date not in seen, f"{spec.key} {expected_month} duplicate date {iso_date}")
        seen.add(iso_date)
        if spec is PRICE:
            open_value = canonical_decimal(raw_row[1], positive=True)
            high_value = canonical_decimal(raw_row[2], positive=True)
            low_value = canonical_decimal(raw_row[3], positive=True)
            close_value = canonical_decimal(raw_row[4], positive=True)
            require(Decimal(high_value) >= max(Decimal(open_value), Decimal(close_value)),
                    f"price {iso_date} high is below open/close")
            require(Decimal(low_value) <= min(Decimal(open_value), Decimal(close_value)),
                    f"price {iso_date} low is above open/close")
            require(Decimal(high_value) >= Decimal(low_value), f"price {iso_date} high is below low")
            row = {
                "date": iso_date,
                "open": open_value,
                "high": high_value,
                "low": low_value,
                "close": close_value,
            }
        else:
            row = {
                "date": iso_date,
                "volume_shares": canonical_int(raw_row[1]),
                "trade_value": canonical_int(raw_row[2]),
                "transaction_count": canonical_int(raw_row[3]),
                "fmtqik_index_close": canonical_decimal(raw_row[4], positive=True),
                "index_change": canonical_decimal(raw_row[5]),
            }
        rows.append(row)
    require([row["date"] for row in rows] == sorted(row["date"] for row in rows),
            f"{spec.key} {expected_month} dates are not strictly ascending")
    return rows


def parse_csv_rows(spec: SourceSpec, raw: bytes, expected_month: str) -> list[dict[str, Any]]:
    # TWSE historical CSV is Big5. Market data rows themselves are ASCII, so
    # Latin-1 preserves byte positions without relying on locale codecs.
    text = raw.decode("latin-1")
    source_rows: list[list[str]] = []
    for row in csv.reader(io.StringIO(text)):
        if row and re.fullmatch(r"\d{2,3}/\d{2}/\d{2}", row[0].strip()):
            while row and row[-1] == "":
                row.pop()
            source_rows.append(row)
    payload = {
        "stat": "OK",
        "fields": list(spec.fields),
        "hints": "單位：元、股" if spec is ACTIVITY else "",
        "data": source_rows,
    }
    return parse_json_rows(spec, json.dumps(payload).encode("utf-8"), expected_month)


def cache_directory(pool_root: Path, spec: SourceSpec, month: str) -> Path:
    return pool_root / "source-cache" / spec.cache_slug / month


def validation_cache_directory(pool_root: Path, spec: SourceSpec, month: str) -> Path:
    return pool_root / "validation-cache" / spec.cache_slug / month


def cached_revisions(pool_root: Path, spec: SourceSpec, month: str) -> list[CacheRevision]:
    directory = cache_directory(pool_root, spec, month)
    revisions: list[CacheRevision] = []
    for metadata_path in sorted(directory.glob("*.metadata.json")):
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        digest = metadata.get("sha256")
        raw_path = directory / f"{digest}.json"
        require(isinstance(digest, str) and len(digest) == 64, f"bad cache metadata: {metadata_path}")
        require(raw_path.exists(), f"cache raw file missing: {raw_path}")
        require(sha256(raw_path.read_bytes()) == digest, f"cache digest mismatch: {raw_path}")
        revisions.append(CacheRevision(
            source=spec,
            month=month,
            sha256=digest,
            acquired_at=str(metadata.get("acquired_at", "")),
            raw_path=raw_path,
            metadata_path=metadata_path,
        ))
    return revisions


def selected_revision(pool_root: Path, spec: SourceSpec, month: str) -> CacheRevision:
    revisions = cached_revisions(pool_root, spec, month)
    require(bool(revisions), f"no cached {spec.key} revision for {month}")
    return max(revisions, key=lambda item: (item.acquired_at, item.sha256))


def save_source_revision(
    pool_root: Path,
    spec: SourceSpec,
    month: str,
    url: str,
    raw: bytes,
    headers: dict[str, str],
) -> CacheRevision:
    rows = parse_json_rows(spec, raw, month)
    digest = sha256(raw)
    acquired_at = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    directory = cache_directory(pool_root, spec, month)
    raw_path = directory / f"{digest}.json"
    metadata_path = directory / f"{digest}.metadata.json"
    atomic_write(raw_path, raw)
    metadata = {
        "acquired_at": acquired_at,
        "byte_count": len(raw),
        "content_type": headers.get("content-type", ""),
        "fields": list(spec.fields),
        "month": month,
        "row_count": len(rows),
        "schema_version": 1,
        "sha256": digest,
        "source": spec.cache_slug,
        "url": url,
    }
    if metadata_path.exists():
        existing = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata["acquired_at"] = existing["acquired_at"]
    atomic_write(metadata_path, json_bytes(metadata))
    return CacheRevision(spec, month, digest, metadata["acquired_at"], raw_path, metadata_path)


def save_validation_csv(
    pool_root: Path,
    spec: SourceSpec,
    month: str,
    url: str,
    raw: bytes,
    headers: dict[str, str],
) -> Path:
    rows = parse_csv_rows(spec, raw, month)
    digest = sha256(raw)
    directory = validation_cache_directory(pool_root, spec, month)
    raw_path = directory / f"{digest}.csv"
    metadata_path = directory / f"{digest}.metadata.json"
    atomic_write(raw_path, raw)
    metadata = {
        "acquired_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "byte_count": len(raw),
        "content_type": headers.get("content-type", ""),
        "month": month,
        "row_count": len(rows),
        "schema_version": 1,
        "sha256": digest,
        "source": spec.cache_slug,
        "url": url,
    }
    if metadata_path.exists():
        existing = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata["acquired_at"] = existing["acquired_at"]
    atomic_write(metadata_path, json_bytes(metadata))
    return raw_path


def selected_validation_csv(pool_root: Path, spec: SourceSpec, month: str) -> Path:
    directory = validation_cache_directory(pool_root, spec, month)
    candidates: list[tuple[str, Path]] = []
    for metadata_path in directory.glob("*.metadata.json"):
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        raw_path = directory / f"{metadata['sha256']}.csv"
        require(raw_path.exists(), f"validation CSV missing: {raw_path}")
        require(sha256(raw_path.read_bytes()) == metadata["sha256"], f"validation digest mismatch: {raw_path}")
        candidates.append((str(metadata["acquired_at"]), raw_path))
    require(bool(candidates), f"no validation CSV for {spec.key} {month}")
    return max(candidates)[1]


def fetch_months(
    pool_root: Path,
    months: list[str],
    cross_check_months: set[str],
    refresh: bool,
) -> None:
    downloader = Downloader()
    total = len(months) * len(SOURCES)
    completed = 0
    for month in months:
        for spec in SOURCES:
            existing = cached_revisions(pool_root, spec, month)
            if existing and not refresh:
                revision = selected_revision(pool_root, spec, month)
                parse_json_rows(spec, revision.raw_path.read_bytes(), month)
                print(f"[{completed + 1}/{total}] {month} {spec.key}: cached {revision.sha256[:12]}", flush=True)
            else:
                url = spec.url(month)
                print(f"[{completed + 1}/{total}] {month} {spec.key}: request", flush=True)
                raw, headers = downloader.fetch(
                    url,
                    validator=lambda body, source=spec, target=month: parse_json_rows(
                        source, body, target
                    ),
                )
                revision = save_source_revision(pool_root, spec, month, url, raw, headers)
                print(f"  saved {revision.sha256[:12]}", flush=True)
            completed += 1

        if month in cross_check_months:
            for spec in SOURCES:
                try:
                    path = selected_validation_csv(pool_root, spec, month)
                    parse_csv_rows(spec, path.read_bytes(), month)
                    print(f"  {month} {spec.key} CSV: cached {path.stem[:12]}", flush=True)
                except MarketDataError:
                    url = spec.url(month, response="csv")
                    print(f"  {month} {spec.key} CSV: request", flush=True)
                    raw, headers = downloader.fetch(
                        url,
                        validator=lambda body, source=spec, target=month: parse_csv_rows(
                            source, body, target
                        ),
                    )
                    path = save_validation_csv(pool_root, spec, month, url, raw, headers)
                    print(f"  saved CSV {path.stem[:12]}", flush=True)


def row_signature(spec: SourceSpec, row: dict[str, Any]) -> tuple[Any, ...]:
    if spec is PRICE:
        return tuple(row[key] for key in ("date", "open", "high", "low", "close"))
    return tuple(row[key] for key in (
        "date", "volume_shares", "trade_value", "transaction_count",
        "fmtqik_index_close", "index_change",
    ))


def qualification_report(pool_root: Path, months: list[str]) -> dict[str, Any]:
    checks: list[dict[str, Any]] = []
    for month in months:
        parsed: dict[str, list[dict[str, Any]]] = {}
        for spec in SOURCES:
            revision = selected_revision(pool_root, spec, month)
            json_rows = parse_json_rows(spec, revision.raw_path.read_bytes(), month)
            csv_path = selected_validation_csv(pool_root, spec, month)
            csv_rows = parse_csv_rows(spec, csv_path.read_bytes(), month)
            require([row_signature(spec, row) for row in json_rows] ==
                    [row_signature(spec, row) for row in csv_rows],
                    f"{spec.key} {month} JSON/CSV mismatch")
            parsed[spec.key] = json_rows
        prices = parsed["price"]
        activities = parsed["activity"]
        require([row["date"] for row in prices] == [row["date"] for row in activities],
                f"{month} price/activity dates mismatch")
        for price, activity in zip(prices, activities, strict=True):
            require(price["close"] == activity["fmtqik_index_close"],
                    f"{price['date']} cross-source close mismatch")
        indices = sorted({0, len(prices) // 2, len(prices) - 1})
        for index in indices:
            checks.append({
                "close": prices[index]["close"],
                "date": prices[index]["date"],
                "month": month,
                "position": "first" if index == 0 else "last" if index == len(prices) - 1 else "middle",
                "volume_shares": activities[index]["volume_shares"],
            })
    report = {
        "cross_source_close_mismatch_count": 0,
        "json_csv_full_row_mismatch_count": 0,
        "months": months,
        "sample_checks": checks,
        "sample_count": len(checks),
        "status": "complete",
    }
    path = pool_root / "qualification" / "mkt-d01-p1-five-months.json"
    atomic_write(path, json_bytes(report))
    return report


CSV_FIELDS = (
    "date", "open", "high", "low", "close", "volume_shares", "volume_lots",
    "trade_value", "transaction_count", "fmtqik_index_close", "index_change",
    "price_source", "price_source_month", "price_source_revision",
    "activity_source", "activity_source_month", "activity_source_revision",
)


def volume_lots(shares: int) -> str:
    return format(Decimal(shares) / Decimal(1000), "f")


def baseline_dates(stores: list[Path], decision_start: str, through_date: str) -> set[str]:
    result: set[str] = set()
    for store in stores:
        require(store.exists(), f"baseline store missing: {store}")
        connection = sqlite3.connect(f"file:{store}?mode=ro", uri=True)
        try:
            rows = connection.execute(
                """
                SELECT DISTINCT date(ZDATETIME + ?, 'unixepoch')
                FROM ZTRADE
                WHERE ZDATASOURCE = 'TWSE'
                  AND date(ZDATETIME + ?, 'unixepoch') >= ?
                  AND date(ZDATETIME + ?, 'unixepoch') <= ?
                """,
                (APPLE_REFERENCE_UNIX_OFFSET, APPLE_REFERENCE_UNIX_OFFSET, decision_start,
                 APPLE_REFERENCE_UNIX_OFFSET, through_date),
            )
            result.update(str(row[0]) for row in rows if row[0])
        finally:
            connection.close()
    return result


def assemble_normalized(
    pool_root: Path,
    months: list[str],
    through_date: str,
    decision_start: str,
    baseline_stores: list[Path],
) -> tuple[bytes, bytes, dict[str, Any]]:
    require(bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}", through_date)), "invalid through-date")
    require(bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}", decision_start)), "invalid decision-start")
    merged: list[dict[str, Any]] = []
    revision_entries: list[dict[str, Any]] = []
    for month in months:
        price_revision = selected_revision(pool_root, PRICE, month)
        activity_revision = selected_revision(pool_root, ACTIVITY, month)
        prices = parse_json_rows(PRICE, price_revision.raw_path.read_bytes(), month)
        activities = parse_json_rows(ACTIVITY, activity_revision.raw_path.read_bytes(), month)
        require([row["date"] for row in prices] == [row["date"] for row in activities],
                f"{month} source date mismatch")
        revision_entries.extend((
            {"month": month, "sha256": price_revision.sha256, "source": PRICE.cache_slug},
            {"month": month, "sha256": activity_revision.sha256, "source": ACTIVITY.cache_slug},
        ))
        for price, activity in zip(prices, activities, strict=True):
            require(price["close"] == activity["fmtqik_index_close"],
                    f"{price['date']} cross-source close mismatch")
            if price["date"] > through_date:
                continue
            merged.append({
                **price,
                **activity,
                "volume_lots": volume_lots(activity["volume_shares"]),
                "price_source": PRICE.cache_slug,
                "price_source_month": month,
                "price_source_revision": price_revision.sha256,
                "activity_source": ACTIVITY.cache_slug,
                "activity_source_month": month,
                "activity_source_revision": activity_revision.sha256,
            })
    dates = [row["date"] for row in merged]
    require(bool(dates), "normalized dataset has no rows")
    require(dates == sorted(dates) and len(dates) == len(set(dates)),
            "normalized dates are not unique and strictly ascending")
    expected_first_prefix = months[0] + "-"
    require(dates[0].startswith(expected_first_prefix), f"first row is outside {months[0]}")
    require(dates[-1] <= through_date, "normalized data exceeds cutoff")

    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=CSV_FIELDS, lineterminator="\n")
    writer.writeheader()
    writer.writerows({key: row[key] for key in CSV_FIELDS} for row in merged)
    csv_data = output.getvalue().encode("utf-8")

    observed_baseline_dates = baseline_dates(baseline_stores, decision_start, through_date)
    missing_baseline_dates = sorted(observed_baseline_dates - set(dates))
    require(not missing_baseline_dates,
            f"market data misses {len(missing_baseline_dates)} Baseline dates: {missing_baseline_dates[:5]}")
    pre_decision_count = sum(row_date < decision_start for row_date in dates)
    require(pre_decision_count >= 250,
            f"only {pre_decision_count} market observations before first decision; need 250")

    quality = {
        "baseline_date_count": len(observed_baseline_dates),
        "baseline_store_count": len(baseline_stores),
        "close_mismatch_count": 0,
        "duplicate_date_count": 0,
        "first_date": dates[0],
        "invalid_activity_count": 0,
        "invalid_ohlc_count": 0,
        "last_date": dates[-1],
        "missing_baseline_dates": missing_baseline_dates,
        "missing_source_date_count": 0,
        "month_count": len(months),
        "pre_decision_observation_count": pre_decision_count,
        "row_count": len(merged),
        "status": "complete",
        "through": through_date,
    }
    quality_data = json_bytes(quality)
    dataset_hash = sha256(csv_data + quality_data + NORMALIZER_VERSION.encode("utf-8"))
    dataset_id = f"{NORMALIZER_VERSION}-{through_date.replace('-', '')}-{dataset_hash[:12]}"
    relative_stores: list[str] = []
    for store in baseline_stores:
        try:
            relative_stores.append(str(store.relative_to(ROOT)))
        except ValueError:
            relative_stores.append(str(store))
    manifest = {
        "complete_marker": dataset_id,
        "date_normalization": "ROC date to ISO YYYY-MM-DD in Asia/Taipei",
        "dataset_id": dataset_id,
        "file_hashes": {
            "market-daily.csv": sha256(csv_data),
            "quality-report.json": sha256(quality_data),
        },
        "normalizer_version": NORMALIZER_VERSION,
        "rebuild": {
            "arguments": {
                "baseline_stores": relative_stores,
                "decision_start": decision_start,
                "from_month": months[0],
                "through_date": through_date,
                "through_month": months[-1],
            },
            "command": "python3 tools/market_data_pool.py build",
        },
        "revision_count": len(revision_entries),
        "schema_version": 1,
        "source_revisions": revision_entries,
        "through": through_date,
        "timezone": f"Asia/Taipei ({TAIPEI_OFFSET})",
    }
    return csv_data, quality_data, manifest


def publish_normalized(
    pool_root: Path,
    months: list[str],
    through_date: str,
    decision_start: str,
    baseline_stores: list[Path],
) -> Path:
    first = assemble_normalized(pool_root, months, through_date, decision_start, baseline_stores)
    second = assemble_normalized(pool_root, months, through_date, decision_start, baseline_stores)
    require(first == second, "two offline normalizations were not deterministic")
    csv_data, quality_data, manifest = first
    manifest["deterministic_rebuild_verified"] = True
    manifest_data = json_bytes(manifest)
    output_dir = pool_root / "normalized" / manifest["dataset_id"]
    if output_dir.exists():
        expected = {
            "market-daily.csv": csv_data,
            "quality-report.json": quality_data,
            "manifest.json": manifest_data,
            ".complete": (manifest["dataset_id"] + "\n").encode("utf-8"),
        }
        for name, data in expected.items():
            require((output_dir / name).read_bytes() == data, f"existing normalized file differs: {name}")
        return output_dir
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".market-daily-v1-", dir=output_dir.parent))
    try:
        atomic_write(staging / "market-daily.csv", csv_data)
        atomic_write(staging / "quality-report.json", quality_data)
        atomic_write(staging / "manifest.json", manifest_data)
        atomic_write(staging / ".complete", (manifest["dataset_id"] + "\n").encode("utf-8"))
        os.replace(staging, output_dir)
    finally:
        if staging.exists():
            for child in staging.iterdir():
                child.unlink()
            staging.rmdir()
    return output_dir


def comma_values(value: str | None) -> list[str]:
    if not value:
        return []
    return [item.strip() for item in value.split(",") if item.strip()]


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pool-root", type=Path, default=DEFAULT_POOL_ROOT)
    subparsers = parser.add_subparsers(dest="command", required=True)

    fetch = subparsers.add_parser("fetch", help="fetch or reuse immutable monthly source responses")
    fetch.add_argument("--from-month")
    fetch.add_argument("--through-month")
    fetch.add_argument("--months", help="comma-separated YYYY-MM list")
    fetch.add_argument("--cross-check-months", help="also preserve official CSV for these months")
    fetch.add_argument("--refresh", action="store_true")

    qualify = subparsers.add_parser("qualify", help="compare cached JSON, CSV, and both sources")
    qualify.add_argument("--months", required=True)

    build = subparsers.add_parser("build", help="build deterministic normalized market-daily-v1")
    build.add_argument("--from-month", required=True)
    build.add_argument("--through-month", required=True)
    build.add_argument("--through-date", required=True)
    build.add_argument("--decision-start", required=True)
    build.add_argument("--baseline-store", type=Path, action="append", default=[])
    return parser.parse_args()


def main() -> int:
    args = arguments()
    pool_root = args.pool_root.resolve()
    if args.command == "fetch":
        explicit = comma_values(args.months)
        if explicit:
            months = [parse_month(item) for item in explicit]
        else:
            require(args.from_month and args.through_month,
                    "fetch requires --months or both --from-month and --through-month")
            months = month_range(args.from_month, args.through_month)
        cross_checks = {parse_month(item) for item in comma_values(args.cross_check_months)}
        require(cross_checks.issubset(set(months)), "cross-check months must be fetched in this run")
        fetch_months(pool_root, months, cross_checks, args.refresh)
        print(f"fetch complete: {len(months)} months", flush=True)
        return 0
    if args.command == "qualify":
        months = [parse_month(item) for item in comma_values(args.months)]
        report = qualification_report(pool_root, months)
        print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    if args.command == "build":
        months = month_range(args.from_month, args.through_month)
        output_dir = publish_normalized(
            pool_root,
            months,
            args.through_date,
            args.decision_start,
            [path.resolve() for path in args.baseline_store],
        )
        print(f"normalized dataset: {output_dir}")
        print((output_dir / "quality-report.json").read_text(encoding="utf-8"), end="")
        return 0
    raise AssertionError(args.command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MarketDataError as error:
        print(f"market-data error: {error}", file=sys.stderr)
        raise SystemExit(1)
