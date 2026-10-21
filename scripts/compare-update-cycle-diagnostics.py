#!/usr/bin/env python3
"""Read-only P5 versus v40 comparison; differences are descriptive, not attribution."""
import argparse
from collections import Counter
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
TAIPEI = timezone(timedelta(hours=8))
EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
ORDINARY = re.findall(r'\("([tv]\w+)", \\Trade\.',
                     (ROOT / 'simStock3Tests/TechnicalReplayIntegrationTests.swift').read_text())
assert len(ORDINARY) == len(set(ORDINARY)) == 65
PATH = ['tPricePathPhaseRaw', 'tPricePathBarrier', 'tPricePathAnchorClose',
        'tPricePathExtremeClose', 'tPricePathDaysSinceExtreme']
TRANSACTIONS = ['ZSIMQTYBUY', 'ZSIMQTYSELL', 'ZSIMQTYINVENTORY', 'ZSIMRULE', 'ZSIMRULEBUY', 'ZSIMRULEINVEST']
TREND = ['ZSIMFITTREND', 'ZSIMFITTRENDPHASERAW', 'ZSIMFITTRENDPHASEEXTREME']
ACCOUNTS = ['ZSIMAMTBALANCE', 'ZSIMAMTCOST', 'ZSIMAMTPROFIT', 'ZSIMINVESTADDED',
            'ZROLLAMTPROFIT', 'ZROLLAMTROI', 'ZROLLROUNDS', 'ZROLLDAYS']
RAW = ['ZPRICEOPEN', 'ZPRICEHIGH', 'ZPRICELOW', 'ZPRICECLOSE', 'ZVOLUMECLOSE', 'ZDATASOURCE']
spec = importlib.util.spec_from_file_location('existing_grade', ROOT / 'tools/grade_trend_turn_threshold_study.py')
grade_module = importlib.util.module_from_spec(spec)
# dataclasses in the reused module need their defining module registered.
import sys
sys.modules[spec.name] = grade_module
spec.loader.exec_module(grade_module)


def day(timestamp):
    return (EPOCH + timedelta(seconds=timestamp)).astimezone(TAIPEI).replace(hour=0, minute=0, second=0, microsecond=0)


def date(value):
    return datetime.strptime(value, '%Y/%m/%d').replace(tzinfo=TAIPEI)


def shifted_year(value, offset):
    try:
        return value.replace(year=value.year + offset)
    except ValueError:
        return value.replace(year=value.year + offset, day=28)


def grade(row, start):
    values = dict(roll_rounds=row['ZROLLROUNDS'], roll_days=row['ZROLLDAYS'],
                  sim_days=row['ZSIMDAYS'], inventory=row['ZSIMQTYINVENTORY'],
                  timestamp=(day(row['ZDATETIME']) - EPOCH).total_seconds(), roll_roi=row['ZROLLAMTROI'])
    return grade_module.grade_for(values, (start - EPOCH).total_seconds())


def snapshot(row):
    value = row['ZSIMANNUALWARNINGDATA']
    return json.loads(value)['snapshot'] if value else None


def sources(directory):
    files = [p for p in directory.iterdir() if p.suffix == '.store' or p.name.endswith('.store-wal')
             or p.name in ['baseline.json', 'manifest.json']]
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}


def rows(path, start, end):
    columns = list(dict.fromkeys(['Z' + x.upper() for x in ORDINARY + PATH]
                                + TRANSACTIONS + TREND + ACCOUNTS + RAW
                                + ['ZSIMDAYS', 'ZSIMANNUALWARNINGDATA']))
    with sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True) as db:
        db.row_factory = sqlite3.Row
        query = 'SELECT s.ZSID, t.ZDATETIME, ' + ', '.join('t.' + x for x in columns)
        query += ' FROM ZTRADE t JOIN ZSTOCK s ON t.ZSTOCK=s.Z_PK WHERE t.ZDATETIME>=? AND t.ZDATETIME<=? ORDER BY s.ZSID,t.ZDATETIME'
        values = db.execute(query, ((shifted_year(start, -1) - EPOCH).total_seconds(),
                                    (end - EPOCH).total_seconds()))
        result = {}
        for row in values:
            key = (row['ZSID'], row['ZDATETIME'])
            assert key not in result, 'Duplicate stock/date input'
            result[key] = dict(row)
        return result


def compare(before, after, start, end):
    a, b = rows(before, start, end), rows(after, start, end)
    assert a.keys() == b.keys(), 'Raw row sets differ; stop before comparing derived values'
    assert all([a[k][x] for x in RAW] == [b[k][x] for x in RAW] for k in a), 'Raw inputs differ'
    effective = {}
    for key, row in b.items():
        if row['ZPRICECLOSE'] > 0:
            first = effective.get(key[0])
            effective[key[0]] = min(first, day(key[1])) if first else day(key[1])
    effective = {sid: max(start, shifted_year(first, 1)) for sid, first in effective.items()}
    field_stats, counts, first = {}, Counter(), {}
    first_by_stock = {}
    for key in a:
        old, new = a[key], b[key]
        sid, timestamp = key
        label = dict(stock=sid, date=day(timestamp).strftime('%Y/%m/%d'))
        for field in ORDINARY + PATH:
            column = 'Z' + field.upper()
            if old[column] == new[column]:
                continue
            stats = field_stats.setdefault(field, dict(count=0, maximumAbsoluteDifference=0, first=label))
            stats['count'] += 1
            if isinstance(old[column], (int, float)) and isinstance(new[column], (int, float)):
                stats['maximumAbsoluteDifference'] = max(stats['maximumAbsoluteDifference'], abs(old[column] - new[column]))
        if day(timestamp) < start:
            continue
        if day(timestamp) < effective[sid]:
            counts['oldSimulationDatesNowPreparation'] += 1
            continue
        checks = {
            'transactions': [old[x] for x in TRANSACTIONS] != [new[x] for x in TRANSACTIONS],
            'grade': grade(old, start) != grade(new, effective[sid]),
            'gradeTrend': [old[x] for x in TREND] != [new[x] for x in TREND],
            'warningSnapshot': snapshot(old) != snapshot(new),
            'accounts': [old[x] for x in ACCOUNTS] != [new[x] for x in ACCOUNTS],
        }
        counts['simulationRowsCompared'] += 1
        for name, changed in checks.items():
            if changed:
                counts[name] += 1
                if name not in first or (label['date'], sid) < (first[name]['date'], first[name]['stock']):
                    first[name] = label
                first_by_stock.setdefault(sid, {}).setdefault(name, label['date'])
    return dict(periodStart=start.strftime('%Y/%m/%d'), periodEnd=end.strftime('%Y/%m/%d'),
                rawRowsCompared=len(a), effectiveStarts={sid: d.strftime('%Y/%m/%d') for sid, d in effective.items()},
                fieldDifferences=field_stats, counts=dict(counts), firstDifferences=first,
                firstDifferencesByStock=first_by_stock)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    old = json.loads((args.reference / 'baseline.json').read_text())
    new = json.loads((args.candidate / 'baseline.json').read_text())
    assert old['dataRuleVersion'] == 'T3/S64' and new['dataRuleVersion'] == 'T4/S65'
    assert new['diagnostic']['formalStrategy'] == 'false'
    assert all(old[x] == new[x] for x in ['sampleID', 'periodStarts', 'through', 'moneyBaseWan', 'automaticInvestments'])
    source_hashes = sources(args.reference) | sources(args.candidate)
    periods = []
    for index, start_text in enumerate(new['periodStarts']):
        end_texts = {x['periodEnd'] for x in new['stocks'] if x['periodStart'] == start_text}
        assert len(end_texts) == 1
        end_text = end_texts.pop()
        store = 'browse.store' if index == 0 else 'period-' + start_text.replace('/', '') + '.store'
        periods.append(compare(args.reference / store, args.candidate / store, date(start_text), date(end_text)))
    assert source_hashes == sources(args.reference) | sources(args.candidate), 'Source content changed'
    result = dict(status='compared', sample=new['sampleID'], referenceRun=old['runID'], candidateRun=new['runID'],
                  referenceCommit=old['ruleCommit'], candidateCommit=new['ruleCommit'], sources=source_hashes,
                  score=dict(reference=old['combinedScore'], candidate=new['combinedScore'],
                             difference=new['combinedScore'] - old['combinedScore']), periods=periods,
                  limitations=['All approved cycle/window/algorithm changes are combined; not a single-cause maturity study.',
                               'Exact values compared without tolerance; warning snapshots exclude payload version/config metadata.',
                               'Neither diagnostic score nor difference validates S-E01 thresholds or future investment results.'])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)
    print(json.dumps(dict(status='compared', score=result['score'], output=str(args.output)), ensure_ascii=False))


if __name__ == '__main__':
    main()
