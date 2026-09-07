"""Read retained adoption DecisionDeltas; never run a strategy or mutate an input.

Predeclared groups: prior market high == inclusive high9 (S-P08),
prior market low == inclusive low9 (S-P09), including ties. A-E fixed3y.
Window outcome associations are not isolated event treatment effects.
"""
from __future__ import annotations

import argparse
import bisect
import csv
import hashlib
import json
import sqlite3
import statistics
from collections import Counter, defaultdict
from contextlib import closing
from decimal import Decimal
from pathlib import Path

import market_snapshot_reuse as reuse

ROOT = Path(__file__).resolve().parents[1]
MARKET_ID = 'mkt-index-extrema9-v2-20260722-6d5519a63bba'
FIELDS = [('state_fingerprint','state_fingerprint',0), ('grade','grade',1),
          ('decision_score','score',2), ('decision_threshold','threshold',3),
          ('planned_action','planned_action',4), ('executed_action','executed_action',5)]
FIELDS += [(name,name,bit) for bit,name in enumerate([
    'inventory_before','unit_cost_before','unit_roi_before','holding_days_before',
    'invest_times_before','balance_before','roll_roi_before','roll_days_before',
    'roll_rounds_before','buy_rule_before'],6)]
STATES = [name for name,_,_ in FIELDS if name not in (
    'decision_score','decision_threshold','planned_action','executed_action')]

def read(path):
    return json.loads(path.read_text())

def connect(path):
    con = sqlite3.connect(f'{path.resolve().as_uri()}?mode=ro', uri=True)
    con.row_factory = sqlite3.Row
    assert con.execute('PRAGMA integrity_check').fetchone()[0] == 'ok', path
    return con

def one(paths):
    result = list(paths)
    assert len(result) == 1, result
    return result[0]

def efficiency(roi, days):
    assert days > 0
    return roi*100/days if roi >= 0 else roi*days/100

def market_inputs():
    directory = ROOT/'exports/market-data/taiex/research'/MARKET_ID
    manifest = reuse.verify_hashed_bundle(directory,id_key='artifact_id',file_hashes_key='files')
    source = ROOT/'exports/market-data/taiex/snapshots'/manifest['source_snapshot_id']
    sm = reuse.verify_mt_snapshot(source)
    assert sm['files']['market-daily.csv'] == manifest['source_market_daily_sha256']
    with (source/'market-daily.csv').open() as f:
        raw = list(csv.DictReader(f))
    with (directory/'market-index-extrema9.csv').open() as f:
        extrema = list(csv.DictReader(f))
    assert len(raw) == len(extrema) == 2569
    dates, values = [], []
    for i,(r,e) in enumerate(zip(raw,extrema)):
        assert r['date'] == e['date']
        window = raw[max(0,i-8):i+1]
        assert Decimal(e['index_high_max9']) == max(Decimal(x['high']) for x in window)
        assert Decimal(e['index_low_min9']) == min(Decimal(x['low']) for x in window)
        assert Decimal(e['index_close']) == Decimal(r['close'])
        dates.append(int(r['date'].replace('-','')))
        values.append(dict(date=dates[-1],high=float(r['high']),low=float(r['low']),
                           close=float(r['close']),high9=float(e['index_high_max9']),
                           low9=float(e['index_low_min9']),count=int(e['observation_count'])))
    assert dates == sorted(set(dates))
    return dates, values, manifest

def analyze(rule, sample, dates, market):
    cid, version = ('MKT-PP-S02','T3/S39') if rule == 'S-P08' else ('RP-S03','T3/S40')
    directory = one((ROOT/'exports/backtest-decision-deltas').glob(f'{sample.lower()}-*/{cid}'))
    summary, dm = read(directory/'decision-summary.json'), read(directory/'manifest.json')
    bid = summary['baselineDecisionBaseID']
    base_dir = ROOT/'exports/backtest-decision-bases'/bid
    bm = read(base_dir/'manifest.json')
    run = ROOT/'exports/backtest-candidate-runs'/summary['candidateRunID']
    rm = read(run/'manifest.json')
    for m in (summary,dm):
        assert m['candidateID'] == cid and m['sampleID'] == sample
        assert m['baselineDecisionBaseID'] == bid
        assert m['candidateRunID'] == run.name
    assert (directory/'.complete').read_text().strip() == cid
    assert (directory/'.analysis-complete').read_text().strip() == cid
    assert (run/'.complete').read_text().strip() == run.name
    assert (base_dir/'.complete').read_text().strip() == bid
    assert (base_dir/'.p4b-complete').exists()
    assert bm['decisionBaseID'] == bid and bm['sampleID'] == sample
    assert rm['sampleID'] == sample and rm['dataRuleVersion'] == bm['dataRuleVersion'] == version
    assert rm['ruleCommit'] == bm['ruleCommit'] == dm['baselineRuleCommit']
    assert rm['moneyBaseWan'] == bm['moneyBaseWan'] == dm['moneyBaseWan'] == 600
    assert rm['automaticInvestments'] == bm['automaticInvestments'] == dm['automaticInvestments'] == 2
    assert rm['through'] == bm['through'] == dm['through'] == '2026/07/22'
    assert summary['prestateMismatchCount'] == 0
    with closing(connect(base_dir/'decisions.sqlite')) as base, closing(connect(directory/'decision-delta.sqlite')) as delta:
        events = {r['event_id']:dict(r) for r in base.execute(
            'SELECT e.*,w.start_date,w.end_date,s.stock_id,s.name,s.group_name '
            'FROM decision_events e JOIN windows w USING(window_id) JOIN stocks s USING(stock_key)')}
        assert len(events) == summary['baselineEventCount'] == bm['eventCount']
        by_delta, first_action = {}, {}
        deltas = list(delta.execute('SELECT * FROM event_deltas ORDER BY window_start,window_end,stock_id,trade_date,phase'))
        kinds = Counter(r['kind'] for r in deltas)
        assert len(events)+kinds[2]-kinds[3] == summary['candidateEventCount']
        for d in deltas:
            key = tuple(d[n] for n in ('window_start','window_end','stock_id','trade_date','phase'))
            old = events.get(d['baseline_event_id'])
            if old is not None:
                assert key == tuple(old[n] for n in ('start_date','end_date','stock_id','trade_date','phase'))
            new = dict(old) if old else {}
            for field,suffix,bit in FIELDS:
                if d['changed_fields'] & (1 << bit):
                    new[field] = d['candidate_'+suffix]
            before = old['executed_action'] if old else 'NONE'
            after = new.get('executed_action','NONE') if d['kind'] != 3 else 'NONE'
            if before != after:
                first_action.setdefault(key[:3],key)
            if d['kind'] != 3:
                by_delta[d['delta_id']] = (key,old,new)
        votes = defaultdict(dict)
        for v in delta.execute('SELECT * FROM vote_deltas'):
            votes[v['delta_id']][v['rule_id']] = (v['baseline_contribution'],v['candidate_contribution'])
        outcomes = {tuple(r[n] for n in ('window_start','window_end','stock_id')):dict(r)
                    for r in delta.execute('SELECT * FROM period_outcome_deltas')}
        controls, cases = [], []
        audit = Counter()
        for did,changed in votes.items():
            contribution = changed.get(cid,(None,None))[1]
            if contribution is None or contribution == 0:
                continue
            key, old, new = by_delta[did]
            assert contribution == 1 and key[4] == 3
            audit['candidate_vote_events'] += 1
            if old is None or any(old[f] != new[f] for f in STATES):
                audit['different_prestate_or_added'] += 1
                continue
            assert all(a == b for rid,(a,b) in changed.items() if rid != cid), (rule,sample,key)
            assert abs(new['decision_score']-old['decision_score']-1) < 1e-9
            idx = bisect.bisect_left(dates,key[3])-1
            assert idx >= 8 and dates[idx] < key[3] and market[idx]['count'] == 9
            m = market[idx]
            touch = m['high'] == m['high9'] if rule == 'S-P08' else m['low'] == m['low9']
            distance = 100*(m['high9']-m['close'])/m['high9'] if rule == 'S-P08' else 100*(m['close']-m['low9'])/m['low9']
            changed_action = old['executed_action'] != new['executed_action']
            row = dict(rule=rule,sample=sample,window=key[0],window_end=key[1],stock=key[2],name=old['name'],group=old['group_name'],
                       decision_date=key[3],market_date=m['date'],touch=touch,market=m,close_distance_percent=distance,
                       grade=old['grade'],holding_days=old['holding_days_before'],unit_roi=old['unit_roi_before'],
                       score_before=old['decision_score'],score_after=new['decision_score'],
                       action_before=old['executed_action'],action_after=new['executed_action'],
                       action_changed=changed_action,first_action=first_action.get(key[:3]) == key)
            controls.append(row)
            audit['same_prestate'] += 1
            audit['action_changed' if changed_action else 'action_unchanged'] += 1
            if changed_action:
                outcome = outcomes.get(key[:3])
                if outcome:
                    row.update(roi_delta=outcome['candidate_roi']-outcome['baseline_roi'],
                               days_delta=outcome['candidate_average_days']-outcome['baseline_average_days'],
                               efficiency_delta=efficiency(outcome['candidate_roi'],outcome['candidate_average_days'])-efficiency(outcome['baseline_roi'],outcome['baseline_average_days']))
                else:
                    row.update(roi_delta=0,days_delta=0,efficiency_delta=0)
                row['outcome_sign'] = 'positive' if row['efficiency_delta'] > 1e-9 else ('negative' if row['efficiency_delta'] < -1e-9 else 'zero')
                cases.append(row)
        # Positive control recovers the earlier published S-P09 Sample A analysis.
        if rule == 'S-P09' and sample == 'A':
            assert audit['same_prestate'] == 1809 and audit['action_changed'] == 4
        return dict(rule=rule,sample=sample,candidate_id=cid,baseline_id=bid,candidate_run_id=run.name,
                    data_rule_version=version,rule_commit=bm['ruleCommit'],unfiltered_score_delta=summary['combinedMainScoreDelta'],
                    audit=dict(audit),controls=controls,cases=cases,
                    first_action_window_count=len(first_action),
                    input_manifests=dict(base=bm,delta=dm,run=rm),
                    evidence_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                                     for p in (base_dir/'manifest.json',directory/'manifest.json',directory/'decision-summary.json',directory/'decision-delta.sqlite')})

def aggregate(runs):
    result = []
    for rule in ('S-P08','S-P09'):
        for sample in ('A','B','C','D','E','ALL'):
            selected = [r for r in runs if r['rule'] == rule and (sample == 'ALL' or r['sample'] == sample)]
            for touch in (True,False):
                rows = [x for r in selected for x in r['controls'] if x['touch'] == touch]
                cases = [x for x in rows if x['action_changed']]
                first = [x for x in cases if x['first_action']]
                result.append(dict(rule=rule,sample=sample,touch=touch,events=len(rows),direct=len(cases),
                                   first=len(first),first_positive=sum(x['outcome_sign']=='positive' for x in first),
                                   first_negative=sum(x['outcome_sign']=='negative' for x in first),
                                   first_zero=sum(x['outcome_sign']=='zero' for x in first),
                                   median_efficiency_delta=statistics.median(x['efficiency_delta'] for x in first) if first else None,
                                   median_roi_delta=statistics.median(x['roi_delta'] for x in first) if first else None,
                                   efficiency_delta_range=[min(x['efficiency_delta'] for x in first),max(x['efficiency_delta'] for x in first)] if first else [],
                                   first_market_dates=len({x['market_date'] for x in first}),
                                   market_dates=len({x['market_date'] for x in rows}),
                                   stocks=len({x['stock'] for x in first}),windows=sorted({x['window'] for x in first})))
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    assert not args.output.exists(), 'Use a new directory; do not overwrite retained results.'
    dates, market, mm = market_inputs()
    runs = []
    for rule in ('S-P08','S-P09'):
        for sample in 'ABCDE':
            run = analyze(rule,sample,dates,market)
            runs.append(run)
            print(json.dumps({k:run[k] for k in ('rule','sample','audit')},ensure_ascii=False),flush=True)
    groups = aggregate(runs)
    args.output.mkdir(parents=True)
    result = dict(scope='A-E fixed3y retained adoption deltas; no new replay',
                  caveat='S-P08 is its original T3/S39 adoption context, not an ablation inside current S41. S-P09 is its T3/S40 adoption context. Outcome signs belong to stock-windows, not event returns; do not sum or treat repeated market dates as independent.',
                  market_manifest=mm,groups=groups,runs=runs)
    output = json.dumps(result,ensure_ascii=False,indent=2,allow_nan=False)+'\n'
    (args.output/'analysis.json').write_text(output)
    lines = ['# S-P08／S-P09 大盤九日極值分組分析','',
             '只讀既有 A～E 固定三年採用實驗；S-P08 對照 MKT-PP-S02（T3/S39），S-P09 對照 RP-S03（T3/S40）。不是現行 S41 下移除規則的反事實重播。',
             '', '事前固定：S-P08 以前一市場日 high == high9 分組；S-P09 以 low == low9 分組，平高／平低納入觸及。使用市場版本 2 衍生檔，不使用決策當日大盤。收盤距極值百分比只列個案，不尋找門檻。',
             '', '## 同前態對照', '',
             '| 規則代號 | 樣本 | 觸及極值 | 分數改變事件 | 行動改變 | 首次行動差異窗口 | 正／負／零窗口 | 效率差中位數 | 首次事件市場日期數 |',
             '|---|---|---|---:|---:|---:|---|---:|---:|']
    for g in groups:
        median = f"{g['median_efficiency_delta']:+.3f}" if g['median_efficiency_delta'] is not None else '無案例'
        lines.append(f"| {g['rule']} | {g['sample']} | {'是' if g['touch'] else '否'} | {g['events']} | {g['direct']} | {g['first']} | {g['first_positive']}/{g['first_negative']}/{g['first_zero']} | {median} | {g['first_market_dates']} |")
    lines += ['', '正負依完整股票窗口效率差分類，不是該事件單獨報酬。只把首次行動差異列入正負窗口統計；分數有變但行動未變者保留為對照，不當成獨立有效案例。ALL 市場日期去重；A～D 與 E 的分數尺度不同，不合計為策略分數。',
              '', '## 直接改變行動的案例', '',
              '| 規則代號 | 樣本 | 窗口 | 股票 | 決策日 | 市場日 | 觸及 | 首次 | ROI差 | 週期差 | 效率差 |',
              '|---|---|---|---|---|---|---|---|---:|---:|---:|']
    for r in runs:
        for c in sorted(r['cases'],key=lambda x:(x['window'],x['stock'],x['decision_date'])):
            lines.append(f"| {c['rule']} | {c['sample']} | {c['window']} | {c['stock']} {c['name']} | {c['decision_date']} | {c['market_date']} | {'是' if c['touch'] else '否'} | {'是' if c['first_action'] else '否'} | {c['roi_delta']:+.3f} | {c['days_delta']:+.3f} | {c['efficiency_delta']:+.3f} |")
    lines += ['', '完整分數、Grade、持股前態、原始市場值、同前態對照事件及來源 manifest／雜湊見 analysis.json。無修改規則、Baseline、DecisionBase 或 App 資料。']
    (args.output/'report.md').write_text('\n'.join(lines)+'\n')
    files = {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in args.output.iterdir()}
    manifest = dict(analysis_id=args.output.name,tool=str(Path(__file__).relative_to(ROOT)),
                    tool_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                    market_artifact_id=MARKET_ID,files=files)
    (args.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    reuse.verify_hashed_bundle(ROOT/'exports/market-data/taiex/research'/MARKET_ID,id_key='artifact_id',file_hashes_key='files')
    (args.output/'.complete').write_text(args.output.name+'\n')
    print(json.dumps(groups,ensure_ascii=False,indent=2))

if __name__ == '__main__':
    main()
