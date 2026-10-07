#!/usr/bin/env python3
"""LD-P01: read-only C/D inventory, descriptive prices, no rule search/replay."""
import collections as C
import csv
import hashlib
import json
import math
import re
import sqlite3
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

R = Path(__file__).resolve().parents[1]
O = R / 'exports/l-entry-delay-p01-20261001'
RULE = '7ba8447fbf207484ab305cad0c6beca216da8c93'
STRATEGY = 's49-sell-delay-f03-r1-20261001'
OLD = R / 'exports/sell-delay-p01-20260930'
M = R / 'exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af'
MP = R / 'exports/market-data/taiex/research/mkt-pp-p1-taiex-price-path-f712b360c322/market-price-path.csv'
HASH = {}

def sha(p):
    h = hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda: f.read(1024 * 1024), b''):
            h.update(b)
    return h.hexdigest()

def source(p):
    p = R / p if isinstance(p, str) else p
    assert p.is_file(), p
    HASH.setdefault(str(p.relative_to(R)), sha(p))
    return p

def read(p):
    return json.loads(source(p).read_text())

def save(name, value):
    p = O / name
    tmp = p.with_suffix(p.suffix + '.tmp')
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n')
    tmp.replace(p)

def db(p):
    source(p)
    for suffix in ['-wal', '-shm']:
        q = Path(str(p) + suffix)
        if q.exists():
            source(q)
            if suffix == '-wal':
                assert q.stat().st_size == 0, ('nonempty WAL: use coherent copy', p)
    c = sqlite3.connect(p.as_uri() + '?mode=ro&immutable=1', uri=True)
    c.row_factory = sqlite3.Row
    assert c.execute('pragma quick_check').fetchone()[0] == 'ok'
    return c

def day(n):
    return int((datetime(2001, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=n, hours=8)).strftime('%Y%m%d'))

def finite(v):
    return isinstance(v, (int, float)) and math.isfinite(v)

def schema(c):
    return {r[0]: [x[1] for x in c.execute('pragma table_info(' + r[0] + ')')]
            for r in c.execute("select name from sqlite_master where type='table'")}

def properties(path, cls):
    s = source(path).read_text().split('final class ' + cls, 1)[1].split('    init(', 1)[0]
    return re.findall(r'^    (?:@\w+(?:\([^\n]*\))? )?(?:private\(set\) )?(?:var|let) (\w+)\s*:', s, re.M)

def summarize(events):
    complete = [e for e in events if e['futureAvailableDays'] == 10]
    return dict(entries=len(events), completeTen=len(complete), censoredTen=len(events)-len(complete),
                opportunity=sum(e['hasLowerPrice'] for e in complete),
                noOpportunity=sum(not e['hasLowerPrice'] for e in complete),
                lowerObservedCensored=sum(e['hasLowerPrice'] for e in events if e['futureAvailableDays'] < 10),
                hDelayTakeover=sum(bool(e['hDelayGates']) for e in events),
                stocks=len({e['stock'] for e in events}), dates=len({e['date'] for e in events}),
                futureRows=sum(e['futureAvailableDays'] for e in events),
                opportunityAcrossOriginalExit=sum(e['firstLowerAfterOriginalExit'] for e in complete))

def main():
    assert not (O / 'completion.json').exists(), 'Never overwrite completed evidence'
    assert (O / 'protocol.json').exists()
    assert subprocess.check_output(['git', 'rev-parse', RULE + '^{commit}'], cwd=R, text=True).strip() == RULE
    formal = ['technical.swift', 'dataModel.swift', 'MarketData.swift', 'RollingContext.swift',
              'StrategyFit.swift', 'InternalBacktestDecisionBase.swift', 'AnnualWarningPersistence.swift',
              'TrueAnnualReturnWarning.swift']
    for name in formal:
        p = source('simStock3/' + name)
        assert p.read_bytes() == subprocess.check_output(['git', 'show', RULE + ':simStock3/' + name], cwd=R)
    market = {}
    for p in [M/'market-daily.csv', M/'market-technical.csv', MP]:
        with source(p).open() as f:
            market[p.name] = {int(r['date'].replace('-', '')): r for r in csv.DictReader(f)}
    source(M/'field-catalog.csv')
    events, cells, identities, schemas, rawstats = [], [], {}, {}, []
    source_counts = C.Counter()
    all_stock_windows, manual = 0, C.Counter()
    unique_rows = set()
    for sample in 'CD':
        report = R/'exports/backtest-reports'/f'baseline-{sample.lower()}-v37-s49-sell-delay-f03-r1-t3s61-9y-fixed3y-600w-20261001'
        base = R/'exports/backtest-decision-bases'/f'{sample.lower()}-abcd9-v3-{STRATEGY}-t3-s61-7ba8447fbf20-fixed3y-20260722-v23'
        manifests = []
        for folder in [report, base]:
            m = read(folder/'manifest.json')
            for key, value in dict(ruleCommit=RULE, ruleVersion=STRATEGY, dataRuleVersion='T3/S61',
                                   sampleID=sample, through='2026/07/22', moneyBaseWan=600, automaticInvestments=2, stockCount=10).items():
                assert m[key] == value, (folder, key)
            assert source(folder/'.complete').read_text().strip() == m.get('runID', m.get('decisionBaseID'))
            manifests.append(m)
        rm, bm = manifests
        assert bm['formatVersion'] == 6
        baseline = read(report/'baseline.json')
        for k in ['ruleCommit', 'ruleVersion', 'dataRuleVersion', 'sampleID', 'runID', 'through']:
            assert baseline[k] == rm[k]
        source(report/'periods.csv')
        assert rm['marketInput']['dailySHA256'] == sha(M/'market-daily.csv')
        assert rm['marketInput']['pricePathSHA256'] == sha(MP)
        assert rm['marketInput']['marketTechnicalVersion'] == '6'
        with db(base/'decisions.sqlite') as c:
            schemas[sample+'.DB'] = schema(c)
            meta = dict(c.execute('select key,value from metadata'))
            for k in ['ruleCommit', 'ruleVersion', 'dataRuleVersion', 'sampleID', 'through', 'decisionBaseID']:
                assert meta[k] == bm[k]
            assert meta['formatVersion'] == '6'
            for table, key in [('decision_events','eventCount'),('event_gates','gateCount'),('event_votes','voteCount'),('strategy_fit_observations','strategyFitObservationCount')]:
                assert c.execute('select count(*) from '+table).fetchone()[0] == bm[key]
            ev = [dict(x) for x in c.execute('select e.*,s.stock_id,s.name,s.group_name from decision_events e join stocks s using(stock_key) where phase in (1,2)')]
            h = {(e['window_id'],e['stock_id'],e['trade_date']): e for e in ev if e['phase']==1}
            le = [e for e in ev if e['phase']==2]
            gates = C.defaultdict(list)
            for x in c.execute('select g.event_id,r.rule_id from event_gates g join rules r using(rule_key)'):
                gates[x[0]].append(x[1])
            fit = {x['event_id']: dict(x) for x in c.execute('select l.event_id,o.* from event_strategy_fit_observations l join strategy_fit_observations o using(observation_id)')}
            tech = {x['event_id']: dict(x) for x in c.execute('select l.event_id,o.* from event_observations l join technical_observations o using(observation_id)')}
            windows = [dict(x) for x in c.execute('select * from windows order by window_id')]
        identities[sample] = dict(report=str(report.relative_to(R)), decisionBase=str(base.relative_to(R)), metadata=meta, score=baseline['combinedScore'])
        for win in windows:
            w = win['window_id']
            filename = ['browse.store','period-20200722.store','period-20230722.store'][w-1]
            cell_events, raw = [], C.Counter()
            with db(report/filename) as c:
                schemas[sample+str(w)+'.Store'] = schema(c)
                stocks = [dict(x) for x in c.execute('select * from ZSTOCK')]
                assert len(stocks)==10
                for stock in stocks:
                    all_stock_windows += 1
                    assert stock['ZTECHNICALSTATEVERSION']==3 and stock['ZSIMULATIONSTATEVERSION']==61
                    rows = [dict(x) for x in c.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(stock['Z_PK'],))]
                    dates = [day(r['ZDATETIME']) for r in rows]
                    idx = {d:i for i,d in enumerate(dates)}
                    assert len(idx)==len(rows)
                    sid = stock['ZSID']
                    el = [e for e in le if e['window_id']==w and e['stock_id']==sid]
                    raw['lPhaseRows'] += len(el)
                    raw['qualifiedLRows'] += sum(e['planned_action']=='L' for e in el)
                    raw['executedLBuyIncludingHeld'] += sum(e['executed_action']=='BUY' for e in el)
                    eligible = [e for e in el if e['executed_action']=='BUY' and e['inventory_before']==0]
                    store_starts = [i for i,r in enumerate(rows) if win['start_date']<=dates[i]<=win['end_date']
                                    and r['ZSIMQTYBUY']>0 and r['ZSIMRULEBUY']=='L'
                                    and i>0 and rows[i-1]['ZSIMQTYINVENTORY']==0]
                    assert {dates[i] for i in store_starts} == {e['trade_date'] for e in eligible}, (sample,w,sid)
                    for e in eligible:
                        i=idx[e['trade_date']]; row=rows[i]; prev=rows[i-1]
                        assert row['ZSIMRULE']=='L' and e['planned_action']=='L' and e['decision_score']>=e['decision_threshold']
                        assert row['ZSIMQTYSELL']==0 and row['ZSIMQTYINVENTORY']==row['ZSIMQTYBUY']>0
                        manual['entryReversal'] += bool(row['ZSIMREVERSED'])
                        manual['entryManualInvestment'] += bool(row['ZSIMINVESTBYUSER'])
                        if row['ZSIMREVERSED'] or row['ZSIMINVESTBYUSER']:
                            raw['excludedManualEntries'] += 1
                            continue
                        he=h[(w,sid,e['trade_date'])]
                        assert he['planned_action']=='NONE'
                        assert not (prev['ZSIMQTYSELL']>0 and not prev['ZSIMREVERSED'])
                        one_fee=max(20,math.floor(row['ZPRICECLOSE']*1.425+0.5))
                        assert e['balance_before']+(row['ZSIMINVESTADDED']or 0)*stock['ZSIMMONEYBASE'] >= row['ZPRICECLOSE']*1000+one_fee
                        assert e['event_id'] in fit
                        assert (e['event_id'] in tech) == (4 <= e['decision_score'] <= 6), 'L technical recorder deliberately covers scores 4..6 only'
                        if e['event_id'] in tech:
                            assert math.isclose(tech[e['event_id']]['close_change_percent'],100*(row['ZPRICECLOSE']/prev['ZPRICECLOSE']-1),abs_tol=1e-8)
                        future=[(j,rows[j]) for j in range(i+1,min(i+11,len(rows))) if dates[j]<=win['end_date']]
                        assert row['ZPRICECLOSE']>0 and all(r['ZPRICECLOSE']>0 for _,r in future)
                        assert row['ZDATASOURCE']=='TWSE' and all(r['ZDATASOURCE']=='TWSE' for _,r in future)
                        lower=[(j,r) for j,r in future if r['ZPRICECLOSE']<row['ZPRICECLOSE']]
                        minimum=min((r['ZPRICECLOSE'] for _,r in future),default=None)
                        exit_dates=[dates[j] for j in range(i+1,len(rows)) if dates[j]<=win['end_date'] and rows[j]['ZSIMQTYSELL']>0]
                        exit_date=exit_dates[0] if exit_dates else None
                        warning=json.loads(prev['ZSIMANNUALWARNINGDATA']) if prev['ZSIMANNUALWARNINGDATA'] else None
                        valid_warning=bool(warning and warning.get('formatVersion')==5 and warning.get('dataRules')=='T3/S61'
                                           and warning.get('configuration')==dict(start=stock['ZDATESTART'],budget=stock['ZSIMMONEYBASE'],additions=stock['ZSIMINVESTAUTO']))
                        for prefix, values in [('event',e),('fit',fit[e['event_id']]),('technicalObservation',tech.get(e['event_id'],{})),('priorTrade',prev),('currentTrade',row)]:
                            for key,v in values.items():
                                if finite(v): source_counts[prefix+'.'+key]+=1
                        source_counts['priorWarning.validIdentity']+=valid_warning
                        if valid_warning:
                            for key,v in warning['snapshot'].items():
                                if v is not None:source_counts['priorWarning.'+key]+=1
                        for table in market:
                            source_counts[table+'.entryDatePresent']+=e['trade_date'] in market[table]
                            for key,v in market[table].get(e['trade_date'],{}).items():
                                try:
                                    if math.isfinite(float(v)):source_counts[table+'.'+key]+=1
                                except (TypeError,ValueError):pass
                        out=dict(sample=sample,window=w,stock=sid,name=stock['ZSNAME'],group=e['group_name'],date=e['trade_date'],
                                 eventID=e['event_id'],price=row['ZPRICECLOSE'],quantity=row['ZSIMQTYBUY'],grade=e['grade'],
                                 lScore=e['decision_score'],lThreshold=e['decision_threshold'],lGates=gates[e['event_id']],
                                 hDelayGates=[g for g in gates[he['event_id']] if g in ['H-E01','H-E02']],
                                 futureAvailableDays=len(future),hasLowerPrice=bool(lower),
                                 firstLowerDay=lower[0][0]-i if lower else None,
                                 minimumClose=minimum,minimumDates=[dates[j] for j,r in future if r['ZPRICECLOSE']==minimum],
                                 minimumChangePct=100*(minimum/row['ZPRICECLOSE']-1) if minimum is not None else None,
                                 lowerDays=len(lower),originalExitDate=exit_date,
                                 firstLowerAfterOriginalExit=bool(lower and exit_date and dates[lower[0][0]]>=exit_date),
                                 futureDates=[dates[j]for j,_ in future],
                                 marketMissingDates=[dates[j]for j in [i]+[j for j,_ in future] if dates[j]not in market['market-daily.csv']],
                                 priorWarningValid=valid_warning,technicalObservationLinked=e['event_id'] in tech,priceObservationCount=i+1,
                                 fitObservationCount=fit[e['event_id']]['fit_observation_count'],fitValid=fit[e['event_id']]['is_valid'])
                        events.append(out);cell_events.append(out)
                        unique_rows.update((sample,w,sid,dates[j])for j in [i]+[j for j,_ in future])
                    rawstats.append(dict(sample=sample,window=w,stock=sid,entries=len(eligible)))
            cell=dict(sample=sample,window=w,counts=summarize(cell_events),rawCounts=dict(raw))
            cells.append(cell);print(json.dumps(cell,ensure_ascii=False),flush=True)
    assert schemas['C.DB']==schemas['D.DB']
    save('identities.json',identities);save('schemas.json',schemas);save('entry-events.json',events)
    save('event-inventory.json',dict(cells=cells,totals=summarize(events),stockWindows=all_stock_windows,
         perStockWindow=rawstats,manual=dict(manual),sourceNonmissingCounts=dict(source_counts),uniqueAnchorAndFutureRows=len(unique_rows),
         sourceAvailabilityCaveat='Counts are finite/present only, not mature or candidate-valid. Complete extraction and formula checks belong to P02.'))

    # Reconcile the prior exhaustive source register with current model/schema declarations.
    universe=read(OLD/'source-universe.json')
    coverage=read(OLD/'source-coverage.json')
    oldcat=read(OLD/'feature-catalog.json')
    contracts={x['name']:x for x in read('exports/h-entry-composite-p02-20260929/field-contract.json')}
    for cls,filename in [('Trade','dataModel.swift'),('Stock','dataModel.swift'),('MarketDay','MarketData.swift')]:
        universe[cls]=properties('simStock3/'+filename,cls)
    for prefix,ss in [('DB',schemas['C.DB']),('Store',schemas['C1.Store'])]:
        for table,cols in ss.items():
            if table!='metadata':universe[prefix+'.'+table]=cols
    for scope,table in [('Market.raw','market-daily.csv'),('Market.technical','market-technical.csv'),('Market.path','market-price-path.csv')]:
        universe[scope]=list(next(iter(market[table].values())))
    held={'tradingDaysSinceLastInvestment','inventory_before','unit_cost_before','unit_roi_before','holding_days_before','invest_times_before','buy_rule_before','holding_cost_before'}
    catalog=[]
    for f in oldcat:
        n=f['name']; contract=contracts.get(n,{})
        out={k:f[k]for k in ['name','parent','group','kind','values','source','description','family'] if k in f}
        out.update(source=contract.get('source', f.get('source','see historical field contract')),
                   formulaReference=contract.get('formula',f.get('source','see historical field contract')),
                   timing='same-day official price/market; no future input' if f['group']!='S' else 'original L decision prestate; prior/preview/current levels separated',
                   maturity='P02 verifies current formula and per-source warmup; none Grade not positive input',
                   missingPolicy='No zero fill; structural missing stays missing; OR validity fixed per branch',
                   status='excluded-empty-position' if n in held else 'P02-extraction-and-validation-required',
                   futureRole='fixed causal input' if f['group']!='S' else 'candidate own state required after deferred entry',
                   historicalReference=str((OLD/'feature-catalog.json').relative_to(R)),searched=False)
        if n.startswith('prior_warning_'):
            out['source']='previous completed Trade.simAnnualWarningData, format5/T3/S61/configuration verified at entry; candidate warning unavailable after deferral'
        if n in held:out['reason']='Holding/add-on field not a new-entry signal; inventory and initial investment are guards, not independent search features'
        catalog.append(out)
    names={x['name']for x in catalog}
    marketmap={'indexLowDiffZ125':'market_low_diff_z_125','ma20DiffMax9':'market_ma_20_diff_max_9',
               'indexHighDiffZ250':'market_high_diff_z_250','oscZ125':'market_osc_z_125',
               'oscEMA12':'market_osc_ema_12','oscEMA26':'market_osc_ema_26','oscMACD9':'market_osc_macd_9'}
    known={(x['scope'],x['field'])for x in coverage}
    result=[]
    for x in coverage:
        n=x.get('mappedFeature');present=x['field']in universe.get(x['scope'],[])
        out=dict(id=x['id'],scope=x['scope'],field=x['field'],mappedFeature=n,
                 presentInCurrentSource=present,historicalReason=x['reason'])
        if not present:out.update(status='removed',reason='Absent from current source')
        elif n in held:out.update(status='excluded-empty-position',reason='Holding/add-on state excluded; execution guards retained')
        elif n in names:out.update(status='mapped-P02-validation',reason='Definition reused, original L prestate and current maturity to verify; no old effect inherited')
        else:out.update(status=x['status'],reason=x['reason'])
        result.append(out)
    for scope,fields in universe.items():
        for name in fields:
            if (scope,name)in known:continue
            mapped=marketmap.get(name) if scope=='MarketDay' else None
            assert mapped in names,(scope,name,'unclassified current source addition')
            result.append(dict(id=scope+'.'+name,scope=scope,field=name,mappedFeature=mapped,
                               presentInCurrentSource=True,status='new-formal-alias-P02-validation',
                               reason='Formal market v5/v6 persistence aliases existing research value; formula/equivalence verified in P02'))
    save('feature-catalog.json',catalog);save('source-coverage.json',result);save('source-universe.json',universe)
    active=[f for f in catalog if f['name']not in held]
    atoms=[]
    for f in active:
        cap=9 if f['kind']=='continuous' else 2 if f['kind']=='boolean' else 12 if f['kind']=='grade' else 2*len(f.get('values')or [])
        assert cap>0,f['name']
        atoms.append(dict(name=f['name'],parent=f['parent'],group=f['group'],upper=cap))
    pairs=C.Counter()
    for i,a in enumerate(atoms):
        for b in atoms[i+1:]:
            if a['parent']!=b['parent']:pairs[''.join(g for g in 'TSM' if g in (a['group'],b['group']))]+=a['upper']*b['upper']
    atom_count=sum(a['upper']for a in atoms); upper=sum(pairs.values())+400*atom_count+19900
    rows=len(events)+sum(e['futureAvailableDays']for e in events)
    save('cost-estimate.json',dict(catalogCount=len(catalog),excluded=len(held),potentialFeatures=len(active),
         groups=dict(C.Counter(f['group']for f in active)),atomUpper=atom_count,atomCaps=atoms,AND2UpperBySource=dict(pairs),
         AND2Upper=sum(pairs.values()),AND3AND4Upper=400*atom_count,ORUpper=19900,discoveryUpper=upper,
         twoMillionBatches=math.ceil(upper/2000000),entryAndFutureRows=rows,
         numericMatrixMiB=rows*len(active)*8/1024**2,
         repairSixFamiliesTwoAtomUpper=6*(atom_count+2*math.comb(atom_count,2)),
         note='Definition-based conservative caps only; no actual atoms, cutpoints or formulas generated. P02 must prune aliases, maturity, constants and fix exact total. No full repair sweep authorized.'))
    for path,digest in HASH.items():assert sha(R/path)==digest,path
    save('source-hashes.json',HASH)
    summary=dict(stage='LD-P01',status='complete',baseline=37,decisionBase=23,dataRules='T3/S61',ruleCommit=RULE,
                 totals=summarize(events),catalogCount=len(catalog),potentialFeatures=len(active),sourceEntries=len(result),
                 sourceHashesUnchanged=len(HASH),formalSourcesEqualRuleCommit=len(formal),manual=dict(manual),
                 searches=0,strategyReplays=0,builds=0,downloads=0,simulatorOperations=0,ABEEffectsRead=False,
                 candidateEligibleBuysUnknown=True,next='LD-P02 proposal pending user approval')
    save('summary.json',summary)
    print(json.dumps(summary,ensure_ascii=False),flush=True)

if __name__=='__main__':
    main()
