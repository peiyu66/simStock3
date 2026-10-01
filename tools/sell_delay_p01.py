#!/usr/bin/env python3
"""SD-P01 read-only inventory. No future-price effects, search, or replay."""
import collections as C, csv, hashlib, json, math, re, sqlite3, subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
R=Path(__file__).resolve().parents[1]
O=R/'exports/sell-delay-p01-20260930'
RULE='6097cc26fe839dd8878082ac8f11bdaf08cf0306'
P=R/'exports/h-entry-composite-p02-20260929'
P1=R/'exports/h-entry-composite-p01-20260929'
M=R/'exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af'
PATH=R/'exports/market-data/taiex/research/mkt-pp-p1-taiex-price-path-f712b360c322/market-price-path.csv'
HASH={}
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
def source(p):
 p=R/p if isinstance(p,str) else p;HASH[str(p.relative_to(R))]=sha(p);return p

def read(p):return json.loads(source(p).read_text())
def save(n,x):
 p=O/n;p.parent.mkdir(parents=True,exist_ok=True);t=p.with_suffix(p.suffix+'.tmp');t.write_text(json.dumps(x,ensure_ascii=False,indent=2,allow_nan=False)+'\n');t.replace(p)
def db(p):
 source(p);w=Path(str(p)+'-wal');assert not w.exists() or w.stat().st_size==0
 c=sqlite3.connect(p.as_uri()+'?mode=ro',uri=True);c.row_factory=sqlite3.Row;c.execute('pragma query_only=on');assert c.execute('pragma quick_check').fetchone()[0]=='ok';return c

def day(n):return int((datetime(2001,1,1,tzinfo=timezone.utc)+timedelta(seconds=n,hours=8)).strftime('%Y%m%d'))
def finite(v):return isinstance(v,(int,float)) and math.isfinite(v)
def properties(path,start,end='    init('):
 text=source(path).read_text();i=text.index(start);j=text.index(end,i)
 return {m[1]:dict(type=m[2].strip(),line=text[:i+m.start()].count('\n')+1) for m in re.finditer(r'^    (?:@\w+(?:\([^\n]*\))? )?(?:private\(set\) )?(?:var|let) (\w+)\s*:\s*([^\n]+)',text[i:j],re.M)}
def classify(gates,no60):
 profit=any(g.startswith('S-T01') for g in gates)
 cut=(no60 and bool(set(gates)&{'S-T02','S-T02e'})) or bool(set(gates)&{'S-T02g','S-T02h'})
 return 'both' if profit and cut else 'profit' if profit else 'recovery' if cut else 'unclassified'
def main():
 assert not (O/'completion.json').exists(),'Completed evidence is immutable'
 O.mkdir(parents=True,exist_ok=True)
 save('protocol.json',dict(stage='SD-P01',status='running',authorization='User: 好，那就起始第一個任務。',task='01a0ef6d-ef8b-7aa2-9790-ea4fa9c48f79',baseline=35,dataRules='T3/S59',ruleCommit=RULE,scope='A/B fixed windows: identity, actual sells, source coverage, horizon counts and cost estimates. No future price effects or condition evaluation.',searches=0,strategyReplays=0,builds=0,simulatorOperations=0,downloads=0,CDEEffectsRead=False))
 co=read('exports/hc-i01-f1-adoption-20260930/completion.json');assert co['ruleCommit']==RULE and co['baseline']==35 and co['decisionBase']==21
 assert subprocess.check_output(['git','rev-parse',RULE],cwd=R,text=True).strip()==RULE
 formal=['simStock3/technical.swift','simStock3/dataModel.swift','simStock3/MarketData.swift','simStock3/RollingContext.swift','simStock3/StrategyFit.swift','simStock3/InternalBacktestDecisionBase.swift','simStock3/AnnualWarningPersistence.swift','simStock3/TrueAnnualReturnWarning.swift']
 for f in formal:
  assert source(f).read_bytes()==subprocess.check_output(['git','show',RULE+':'+f],cwd=R),f
 cat=read(P/'feature-catalog.json');contracts=read(P/'field-contract.json');coverage=read(P1/'coverage.json');olduniverse=read(P1/'source-universe.json');pending=read(P/'pending-source-dispositions.json')
 csvs={}
 for path in [M/'market-daily.csv',M/'market-technical.csv',PATH]:
  with source(path).open() as f:csvs[path.name]={int(x['date'].replace('-','')):x for x in csv.DictReader(f)}
 source(M/'field-catalog.csv')
 all_events=[];cells=[];schemas={};storeschemas={};probe=C.Counter();unique_future=set();joins=C.Counter();identities={};directstats={}
 for sample in 'AB':
  report=R/next(x for x in co['runs'] if f'baseline-{sample.lower()}-' in x and 'fixed3y' in x)
  base=R/next(x for x in co['decisionBases'] if Path(x).name.startswith(sample.lower()+'-'))
  for folder in [report,base]:
   m=read(folder/'manifest.json');assert m['ruleCommit']==RULE and m['dataRuleVersion']=='T3/S59' and m['ruleVersion']==co['strategy'] and m['through']=='2026/07/22' and m['moneyBaseWan']==600 and m['automaticInvestments']==2 and m['stockCount']==10
   assert source(folder/'.complete').read_text().strip()==m.get('runID',m.get('decisionBaseID'))
  rm=read(report/'manifest.json');assert rm['marketInput']['dailySHA256']==sha(M/'market-daily.csv') and rm['marketInput']['pricePathSHA256']==sha(PATH)
  with db(base/'decisions.sqlite') as c:
   schemas[sample]={t[0]:[dict(x)for x in c.execute('pragma table_info('+t[0]+')')] for t in c.execute("select name from sqlite_master where type='table'")}
   meta=dict(c.execute('select key,value from metadata'));assert meta['ruleCommit']==RULE and meta['dataRuleVersion']=='T3/S59'
   identities[sample]=dict(report=str(report.relative_to(R)),decisionBase=str(base.relative_to(R)),metadata=meta)
   ev=[dict(x)for x in c.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=3')]
   gates=C.defaultdict(list)
   for x in c.execute('select g.event_id,r.rule_id from event_gates g join rules r using(rule_key) join decision_events e using(event_id) where e.phase=3'):gates[x[0]].append(x[1])
   fit={x['event_id']:dict(x)for x in c.execute('select e.event_id,o.* from decision_events e join event_strategy_fit_observations l using(event_id) join strategy_fit_observations o using(observation_id) where e.phase=3')}
   technical=set(x[0] for x in c.execute('select e.event_id from decision_events e join event_observations l using(event_id) where e.phase=3'))
   windows=[dict(x)for x in c.execute('select * from windows')]
  for win in windows:
   w=win['window_id'];filename=['browse.store','period-20200722.store','period-20230722.store'][w-1]
   with db(report/filename) as c:
    schema={t[0]:[dict(x)for x in c.execute('pragma table_info('+t[0]+')')] for t in c.execute("select name from sqlite_master where type='table'")};storeschemas[f'{sample}{w}']=schema
    stocks=[dict(x)for x in c.execute('select * from ZSTOCK')];assert len(stocks)==10
    ec=C.Counter();field_count=C.Counter();manual=C.Counter();stockstats=[]
    for stock in stocks:
     assert stock['ZTECHNICALSTATEVERSION']==3 and stock['ZSIMULATIONSTATEVERSION']==59
     sid=stock['ZSID'];rows=[dict(x)for x in c.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(stock['Z_PK'],))];dates=[day(x['ZDATETIME'])for x in rows];index={d:i for i,d in enumerate(dates)};assert len(index)==len(rows)
     active=[d for d in dates if win['start_date']<=d<=win['end_date']];window_ev=[e for e in ev if e['window_id']==w and e['stock_id']==sid];sell_ev=[e for e in window_ev if e['executed_action']=='SELL']
     stockstats.append(dict(stock=sid,rows=len(active),sellEvents=len(sell_ev)))
     # Exact RollingContext investment gap update, including reset on a new/closed round.
     distance=None;pre_gap={}
     for i,row in enumerate(rows):
      pre_gap[i]=distance
      invested=(row['ZSIMINVESTBYUSER']or 0)+(row['ZSIMINVESTADDED']or 0)
      if invested==1:distance=0
      elif row['ZSIMDAYS']<=1:distance=None
      elif distance is not None:distance+=1
     store_sell=[row for row,d in zip(rows,dates) if win['start_date']<=d<=win['end_date'] and row['ZSIMQTYSELL']>0]
     assert len(store_sell)==len(sell_ev),(sample,w,sid,'sale count')
     for e in window_ev:
      d=e['trade_date'];i=index[d];row=rows[i];manual['reversal_nonempty']+=bool(row['ZSIMREVERSED']);manual['manual_investment_nonzero']+=bool(row['ZSIMINVESTBYUSER'])
      assert e['planned_action'] in ('SELL','HOLD')
      if e['executed_action']!='SELL':continue
      assert i>0 and e['inventory_before']==row['ZSIMQTYSELL'] and row['ZSIMQTYINVENTORY']==0
      prev=rows[i-1];assert e['inventory_before']==prev['ZSIMQTYINVENTORY'] and e['unit_cost_before']==prev['ZSIMUNITCOST']
      assert math.isclose(e['unit_roi_before'],100*(row['ZPRICECLOSE']/e['unit_cost_before']-1),abs_tol=1e-8)
      assert e['holding_days_before']==prev['ZSIMDAYS']+round((row['ZDATETIME']-prev['ZDATETIME'])/86400)
      assert e['balance_before']==prev['ZSIMAMTBALANCE']
      gap=pre_gap[i];no60=gap is None or gap>=60;gs=gates[e['event_id']];route=classify(gs,no60)
      assert route!='unclassified',(sample,w,sid,d,gs,gap)
      automatic=e['planned_action']=='SELL' and not row['ZSIMREVERSED'];ec['sellEvents']+=1;ec['automatic' if automatic else 'manualOrAltered']+=1;ec[route]+=1
      ec['rawCutGateWithRecentInvestment']+=bool(set(gs)&{'S-T02','S-T02e'}) and not no60
      ec['negativeROI']+=e['unit_roi_before']<0;ec['zeroROI']+=e['unit_roi_before']==0;ec['positiveROI']+=e['unit_roi_before']>0
      future=[date for date in dates[i+1:i+11] if date<=win['end_date']];ec['completeTen']+=len(future)==10;ec['censoredTen']+=len(future)<10;ec['futureRows']+=len(future)
      unique_future.update((sample,w,sid,date)for date in [d]+future)
      ec['marketDayPresent']+=d in csvs['market-daily.csv'];ec['marketTenDatesPresent']+=all(date in csvs['market-daily.csv']for date in [d]+future)
      joins['sellFitLinked']+=e['event_id']in fit;joins['sellTechnicalLinked']+=e['event_id']in technical
      for field,value in e.items():
       if finite(value):field_count['event.'+field]+=1
      for field,value in fit.get(e['event_id'],{}).items():
       if finite(value):field_count['fit.'+field]+=1
      for field,value in row.items():
       if field.startswith(('ZT','ZV','ZPRICE')) and finite(value):field_count['store.'+field]+=1
      warning=prev['ZSIMANNUALWARNINGDATA'];valid=False
      if warning:
       decoded=json.loads(warning);valid=decoded.get('formatVersion')==5 and decoded.get('dataRules')=='T3/S59' and decoded.get('configuration')==dict(start=stock['ZDATESTART'],budget=stock['ZSIMMONEYBASE'],additions=stock['ZSIMINVESTAUTO'])
       if valid:
        field_count['priorWarning.recordIdentity']+=1
        for k,v in decoded['snapshot'].items():
         if v is not None:field_count['priorWarning.'+k]+=1
      for k,v in csvs['market-technical.csv'].get(d,{}).items():
       try:
        if math.isfinite(float(v)):field_count['market.'+k]+=1
       except (TypeError,ValueError):pass
      out={k:e[k]for k in ('event_id','stock_id','trade_date','grade','inventory_before','unit_cost_before','unit_roi_before','holding_days_before','invest_times_before','balance_before','buy_rule_before')}
      out.update(sample=sample,window=w,automatic=automatic,gates=gs,exitRoute=route,previousInvestmentGap=gap,noInvestment60=no60,futureAvailableDays=len(future),futureDates=future,priorWarningIdentityValid=valid,originalCostBefore=prev['ZSIMAMTCOST'])
      all_events.append(out)
    cells.append(dict(sample=sample,window=w,counts=dict(ec),manual=dict(manual),stocks=stockstats,sourceAvailability=dict(field_count)))
    print(json.dumps(dict(progress=sample+str(w),counts=dict(ec))),flush=True)
 assert schemas['A']==schemas['B'];assert len(all_events)==sum(x['counts']['sellEvents'] for x in cells)
 save('identities.json',identities);save('schemas.json',dict(decisionBase=schemas,stores=storeschemas));save('sell-events.json',all_events);save('event-inventory.json',dict(cells=cells,totals=dict(sum((C.Counter(x['counts'])for x in cells),C.Counter())),joins=dict(joins),uniqueAnchorAndFutureRows=len(unique_future),futurePriceEffectsAnalyzed=False))
 # Feature definitions only. Do not generate cutpoints or evaluate expressions.
 feature_rows=[]
 for c,contract in zip(cat,contracts):
  assert c['name']==contract['name'];f=dict(c);f['oldBuyResearchSource']=contract;f['status']='source-present-P02-extraction-required';f['searched']=False
  f['anchorRole']='same-day causal input' if c['group']!='S' else 'v35 SELL prestate; extract/reconstruct and verify in P02'
  f['futureRole']='same-input independent of candidate trading' if c['group']!='S' else 'Baseline only descriptive; candidate own state must be produced by SD-P05'
  f['missingPolicy']='Missing/unmature/nonfinite never zero-filled; none Grade invalid positive trigger; category codes unordered'
  if c['name'].startswith('prior_warning_'):f['source']='previous completed Trade warning record: format 5, T3/S59, matching configuration; full decode validation P02'
  if c['name']=='tradingDaysSinceLastInvestment':f['status']='reactivated-for-holding';f['source']='RollingContext previous investment distance; nil means no applicable investment, not zero days'
  if c['group']=='S' and c['name']not in ('s_grade','balance_before','roll_roi_before','fit_evidence_rounds','fit_evidence_days','prior_fit_fast','prior_fit_slow','prior_fit_trend_phase','prior_fit_trend_phase_extreme','s_fit_level','s_fit_trend','s_roi_trend','s_days_trend') and not c['name'].startswith('prior_warning_'):f['status']='P02-causal-reconstruction-required'
  if c['name']=='tradingDaysSinceLastInvestment':f['status']='reactivated-for-holding'
  feature_rows.append(f)
 extras=[('inventory_before','continuous','decision_events.inventory_before'),('unit_cost_before','continuous','decision_events.unit_cost_before'),('unit_roi_before','continuous','decision_events.unit_roi_before'),('holding_days_before','continuous','decision_events.holding_days_before'),('invest_times_before','continuous','decision_events.invest_times_before'),('buy_rule_before','category','decision_events.buy_rule_before'),('holding_cost_before','continuous','previous completed Trade.simAmtCost carried forward before SELL')]
 for n,k,src in extras:feature_rows.append(dict(name=n,parent=n,group='S',kind=k,values=['H','L'] if k=='category'else None,source=src,status='new-holding-feature-source-verified',searched=False,anchorRole='v35 SELL prestate',futureRole='candidate own state required',missingPolicy='No zero filling; cost/ROI require positive cost; inventory requires holding'))
 assert len({f['name']for f in feature_rows})==len(feature_rows)
 save('feature-catalog.json',feature_rows)
 # Reconcile every old source location against current schemas/declarations, then reclassify holding items.
 current=dict(olduniverse)
 for scope,path,start in [('Trade','simStock3/dataModel.swift','final class Trade'),('Stock','simStock3/dataModel.swift','final class Stock'),('MarketDay','simStock3/MarketData.swift','final class MarketDay')]:current[scope]=list(properties(path,start))
 for t,cols in schemas['A'].items():current['DB.'+t]=[x['name']for x in cols] if t!='metadata' else olduniverse['DB.metadata']
 for t,cols in storeschemas['A1'].items():current['Store.'+t]=[x['name']for x in cols]
 for scope,fn in [('Market.technical','market-technical.csv'),('Market.raw','market-daily.csv'),('Market.path','market-price-path.csv')]:current[scope]=list(next(iter(csvs[fn].values())).keys())
 # Price path and context definitions checked against current rule source; old rows remain explicit aliases.
 for scope in ('S.warning','S.context','S.preview'):
  path='simStock3/TrueAnnualReturnWarning.swift' if scope=='S.warning' else 'simStock3/RollingContext.swift' if scope=='S.context' else 'simStock3/StrategyFit.swift'
  source(path)
 dispositions={x['id']:x for x in pending};newrows=[];known_names={f['name']for f in feature_rows}
 holdingmap={'simAmtCost':'holding_cost_before','simDays':'holding_days_before','simInvestTimes':'invest_times_before','simQtyInventory':'inventory_before','simUnitCost':'unit_cost_before','simUnitRoi':'unit_roi_before','simRuleBuy':'buy_rule_before'}
 marketmap={'kdK':'market_kd_k','kdD':'market_kd_d','kdJZ250':'market_kd_j_z_250','indexHighDiff250':'market_high_diff_250'}
 for row in coverage:
  x=dict(row);x['historicalStatus']=x.pop('status');x['historicalReason']=x.pop('reason');x['presentInCurrentSource']=x['field']in current.get(x['scope'],[])
  n=x.get('canonical');disp=dispositions.get(x['id'])
  if not n and disp:n=disp.get('mappedFeature')
  if x['scope']=='Trade' and x['field']in holdingmap:n=holdingmap[x['field']]
  if x['scope']=='DB.decision_events' and x['field']in {f[0]for f in extras}:n=x['field']
  x['mappedFeature']=n;x['status']='alias-to-SD-feature' if n in known_names else 'excluded-or-guard';x['reason']='Map to new SELL catalog; no claim old H path applies' if n in known_names else x['historicalReason']
  if x['historicalStatus']=='來源或前態待補' and n not in known_names:x['reason']=disp['reason'] if disp else 'explicit source disposition required in P02';x['status']='postdecision-output-or-guard' if disp else 'P02-source-pending'
  if x['scope'].startswith('Store.'):
   x['status']='storage-alias-or-administration';x['reason']='Physical storage aliases the current model/DecisionBase; never adds an independent indicator'
  if not x['presentInCurrentSource']:x['status']='removed-source';x['reason']='Historical source absent from current schema'
  if n=='tradingDaysSinceLastInvestment':x['reason']='Holding context reactivated; no longer excluded as H empty-position invariant'
  newrows.append(x)
 for scope,fields in current.items():
  prior={x['field']for x in coverage if x['scope']==scope}
  for name in set(fields)-prior:
   mapped=marketmap.get(name)
   assert scope=='MarketDay' and (mapped in known_names or name=='priceObservationCount'),(scope,name,'unclassified new field')
   newrows.append(dict(id=scope+'.'+name,scope=scope,field=name,group='M',presentInCurrentSource=True,status='alias-to-SD-feature' if mapped else 'maturity-guard',mappedFeature=mapped,reason='New formal v3/v4 value maps to research formula or maturity guard; verify in P02'))
 assert len({x['id']for x in newrows})==len(newrows)
 assert not [x for x in newrows if x['status']=='P02-source-pending']
 save('source-coverage.json',newrows);save('source-universe.json',current)
 atoms=[]
 for f in feature_rows:
  # Conservative bound: quartiles plus zero (if crossed), two directions, one broad interval.
  cap=9 if f['kind']=='continuous'else 2 if f['kind']=='boolean'else 12 if f['kind']=='grade'else 2*len(f.get('values')or [])
  assert cap>0,(f['name'],f['kind']);atoms.append(dict(name=f['name'],parent=f['parent'],group=f['group'],upper=cap))
 pairs=C.Counter()
 for i,a in enumerate(atoms):
  for b in atoms[i+1:]:
   if a['parent']!=b['parent']:pairs[''.join(g for g in 'TSM'if g in (a['group'],b['group']))]+=a['upper']*b['upper']
 a=sum(x['upper']for x in atoms);and2=sum(pairs.values());higher=400*a;orcap=19900;discovery=and2+higher+orcap;repair=6*(a+2*math.comb(a,2));rows=sum(x['counts']['futureRows']+x['counts']['sellEvents']for x in cells)
 save('cost-estimate.json',dict(featureCount=len(feature_rows),groups=dict(C.Counter(f['group']for f in feature_rows)),atomUpper=a,atomCaps=atoms,pairUpperBySource=dict(pairs),AND2Upper=and2,AND3AND4Upper=higher,ORUpper=orcap,discoveryUpper=discovery,minTwoMillionBatches=math.ceil(discovery/2000000),repairSixFamiliesTwoAtomUpper=repair,repairMinTwoMillionBatches=math.ceil(repair/2000000),repairNote='Conservative two-atom single/AND/OR enumeration before parent/size/dedup pruning; not authorized, not default full sweep. Mechanism-selected bounded batch must be proposed after P03.',anchorAndTenDayRowsWithDuplicates=rows,uniqueRows=len(unique_future),float64MatrixMiB=rows*len(feature_rows)*8/1024**2,validityMiB=rows*len(feature_rows)/1024**2,note='P02 calculates maturity/constants and exact counts before P03. No cutpoints or conditions generated in P01. S after original sale is descriptive only.'))
 matched=0
 for path,digest in HASH.items():
  if path in co['artifacts']:assert co['artifacts'][path]==digest,path;matched+=1
 for path,digest in HASH.items():assert sha(R/path)==digest,path
 save('source-hashes.json',HASH)
 summary=dict(status='complete',stage='SD-P01',ruleCommit=RULE,baseline=35,decisionBase=21,dataRules='T3/S59',cells=len(cells),stockWindows=60,events=len(all_events),uniqueAnchorAndFutureRows=len(unique_future),featureCount=len(feature_rows),sourceEntries=len(newrows),sourceStatuses=dict(C.Counter(x['status']for x in newrows)),featureStatuses=dict(C.Counter(x['status']for x in feature_rows)),adoptionHashesMatched=matched,sourceHashesUnchanged=len(HASH),formalSourcesEqualRuleCommit=len(formal),searches=0,strategyReplays=0,builds=0,CDEEffectsRead=False,next='SD-P02: bounded data extraction and source/causal validation; no condition search or strategy replay')
 save('summary.json',summary);print(json.dumps(summary),flush=True)
if __name__=='__main__':main()
