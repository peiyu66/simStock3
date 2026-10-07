#!/usr/bin/env python3
"""Read-only F05 origin refresh on v36; no candidate future S or strategy replay."""
import ast, collections as C, datetime as dt, hashlib, json, math, sqlite3, subprocess
from pathlib import Path
R=Path(__file__).resolve().parents[1]
O=R/'exports/sell-delay-f05-refresh-20261001'
HASH={}
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def source(p):
 p=Path(p);p=p if p.is_absolute() else R/p;HASH[str(p.relative_to(R))]=sha(p);return p
def read(p):return json.loads(source(p).read_text())
def save(n,v):(O/n).write_text(json.dumps(v,ensure_ascii=False,indent=2,allow_nan=False)+'\n')
def db(p):
 p=source(p);assert not Path(str(p)+'-wal').exists() or Path(str(p)+'-wal').stat().st_size==0
 c=sqlite3.connect(p.as_uri()+'?mode=ro',uri=True);c.row_factory=sqlite3.Row;c.execute('pragma query_only=on');assert c.execute('pragma quick_check').fetchone()[0]=='ok';return c
def day(t):return int((dt.datetime(2001,1,1)+dt.timedelta(seconds=t,hours=8)).strftime('%Y%m%d'))
def years(d,s):return max(1,(dt.datetime.strptime(str(d),'%Y%m%d')-dt.datetime.strptime(str(s),'%Y%m%d')).days/365)
def equal(a,b):return a==b or (a is not None and b is not None and math.isclose(a,b,rel_tol=1e-12,abs_tol=1e-9))
# Reuse the previously validated pure phase-transition implementation without its NumPy extraction dependencies.
fpath=source('tools/h_entry_composite_p02.py');tree=ast.parse(fpath.read_text())
names={'finite','phase_next','fit_update','avdays','ownstate','level_of'}
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in names],type_ignores=[]),str(fpath),'exec'))
def scan(version,identities,rule,strategy):
 hits=[];summary=C.Counter();holding_hits=[]
 for sample in 'AB':
  rp=R/identities[sample]['report'];bp=R/identities[sample]['decisionBase']
  for folder in (rp,bp):
   m=read(folder/'manifest.json')
   assert m['ruleCommit']==rule and m['dataRuleVersion']==f'T3/S{59 if version==35 else 60}' and m['ruleVersion']==strategy
   assert m['through']=='2026/07/22' and m['moneyBaseWan']==600 and m['automaticInvestments']==2 and m['stockCount']==10
   assert source(folder/'.complete').read_text().strip()==m.get('runID',m.get('decisionBaseID'))
  with db(bp/'decisions.sqlite') as c:
   meta=dict(c.execute('select key,value from metadata'));assert meta['ruleCommit']==rule and meta['dataRuleVersion']==m['dataRuleVersion']
   events=[dict(x) for x in c.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=3')]
   fit={x['event_id']:dict(x) for x in c.execute('select e.event_id,o.* from decision_events e join event_strategy_fit_observations l using(event_id) join strategy_fit_observations o using(observation_id) where e.phase=3')}
   gates=C.defaultdict(list);votes=C.defaultdict(list)
   for e,r in c.execute('select g.event_id,r.rule_id from event_gates g join rules r using(rule_key)'):gates[e].append(r)
   for e,r,v in c.execute('select g.event_id,r.rule_id,g.contribution from event_votes g join rules r using(rule_key)'):votes[e].append([r,v])
   windows=[dict(x) for x in c.execute('select * from windows')]
  for w in windows:
   wi=w['window_id']
   with db(rp/['browse.store','period-20200722.store','period-20230722.store'][wi-1]) as c:
    stocks=[dict(x) for x in c.execute('select * from ZSTOCK')]
    for st in stocks:
     assert st['ZTECHNICALSTATEVERSION']==3 and st['ZSIMULATIONSTATEVERSION']==(59 if version==35 else 60)
     rows=[dict(x) for x in c.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(st['Z_PK'],))]
     dates=[day(r['ZDATETIME']) for r in rows];index={d:i for i,d in enumerate(dates)}
     for e in events:
      if e['window_id']!=wi or e['stock_id']!=st['ZSID']:continue
      n=index[e['trade_date']];r=rows[n];prev=rows[n-1];f=fit.get(e['event_id']);summary['holdingEvents']+=1
      if not(f and e['grade']!=0 and f['grade_activation_passed'] and f['is_finite']):continue
      dd=avdays(e['roll_rounds_before'],e['roll_days_before'],e['inventory_before'],e['holding_days_before'])
      roi=e['roll_roi_before']/years(e['trade_date'],w['start_date']);level=level_of(roi,dd)
      assert equal(level,f['fit_level'])
      for col,v in zip(('fit_fast','fit_slow','fit_observation_count','fit_trend_phase','fit_trend_phase_extreme','fit_trend'),ownstate(prev)):assert equal(f[col],v)
      pp,pe,pc,*_=fit_update(ownstate(prev),level,roi,dd)
      postroi=r['ZROLLAMTROI']/years(e['trade_date'],w['start_date'])
      postdays=avdays(r['ZROLLROUNDS'],r['ZROLLDAYS'],r['ZSIMQTYINVENTORY'],r['ZSIMDAYS'])
      post=fit_update(ownstate(prev),level_of(postroi,postdays),postroi,postdays)
      if postdays>0:
       expect=[r[k] for k in ('ZSIMFITTRENDPHASERAW','ZSIMFITTRENDPHASEEXTREME','ZSIMFITOBSERVATIONCOUNT','ZSIMFITFAST','ZSIMFITSLOW','ZSIMFITTREND')]
       assert all(equal(a,b) for a,b in zip(post,expect));summary['postTransitionsVerified']+=1
      if not(n+1>=250 and pc>=125 and pp==9 and finite(r['ZTKDKZ250']) and r['ZTKDKZ250']<1):continue
      automatic=e['executed_action']=='SELL' and e['planned_action']=='SELL' and not r['ZSIMREVERSED']
      item=dict(sample=sample,window=wi,stock=st['ZSID'],date=e['trade_date'],kZ250=r['ZTKDKZ250'],phase=pp,grade=e['grade'],gates=gates[e['event_id']],votes=votes[e['event_id']],automatic=automatic,close=r['ZPRICECLOSE'],holdingDays=e['holding_days_before'],roi=e['unit_roi_before'],investTimes=e['invest_times_before'])
      holding_hits.append(item)
      if not automatic:continue
      assert e['inventory_before']==r['ZSIMQTYSELL'] and r['ZSIMQTYINVENTORY']==0
      future=[(d,x['ZPRICECLOSE']) for d,x in zip(dates[n+1:n+11],rows[n+1:n+11]) if d<=w['end_date']]
      changes=[100*(p/r['ZPRICECLOSE']-1) for d,p in future];mx=max((p for d,p in future),default=None)
      item=dict(item,future=[dict(date=d,close=p,gainPct=g) for (d,p),g in zip(future,changes)],completeTen=len(future)==10,observedHigher=any(g>0 for g in changes),highestDates=[d for d,p in future if p==mx],maxGainPct=max(changes,default=None),minGainPct=min(changes,default=None),futureCandidateState='unknown')
      hits.append(item)
   print(f'v{version} {sample}{wi} complete',flush=True)
 return dict(counts=dict(summary),origins=hits,holdingMatches=holding_hits)
def main():
 assert not (O/'completion.json').exists();O.mkdir(parents=True,exist_ok=True)
 save('protocol.json',dict(authorization='User: 那就繼續F05。',task='SD-F05-v36-refresh',scope='Frozen F05 refresh, A/B fixed windows only; no C/D/E effects, tuning, strategy replay, build, Simulator, adoption or Git delivery.',condition='kd_k_z250 < 1 AND decision_fit_phase == 9',baseline=36,cutoff='2026/07/22'))
 co=read('exports/sell-delay-p09-adoption-20261001/completion.json');assert co['baseline']==36 and co['decisionBase']==22
 rule=co['ruleCommit'];assert subprocess.check_output(['git','rev-parse',rule],cwd=R,text=True).strip()==rule
 for f in ['simStock3/StrategyFit.swift','simStock3/technical.swift','simStock3/RollingContext.swift']:
  assert source(f).read_bytes()==subprocess.check_output(['git','show',rule+':'+f],cwd=R)
 old=read('exports/sell-delay-p01-20260930/identities.json')
 new={s:dict(report=next(p for p in co['reports'] if f'baseline-{s.lower()}-' in p and 'fixed3y' in p),decisionBase=next(p for p in co['decisionBases'] if Path(p).name.startswith(s.lower()+'-'))) for s in 'AB'}
 a=scan(35,old,'6097cc26fe839dd8878082ac8f11bdaf08cf0306','s47-h-entry-i01-f1-20260930');assert len(a['origins'])==54
 b=scan(36,new,rule,co['strategy'])
 key=lambda x:(x['sample'],x['window'],x['stock'],x['date'])
 ak={key(x) for x in a['origins']};bk={key(x) for x in b['origins']}
 cells=[]
 for s in 'AB':
  for w in (1,2,3):
   xs=[x for x in b['origins'] if x['sample']==s and x['window']==w]
   cells.append(dict(sample=s,window=w,origins=len(xs),completeHigher=sum(x['completeTen'] and x['observedHigher'] for x in xs),completeNoHigher=sum(x['completeTen'] and not x['observedHigher'] for x in xs),censored=sum(not x['completeTen'] for x in xs),sT01c=sum('S-T01c' in x['gates'] for x in xs)))
 summary=dict(baseline=36,ruleCommit=rule,cells=cells,origins=len(bk),retained=len(ak&bk),removed=[list(k) for k in sorted(ak-bk)],added=[list(k) for k in sorted(bk-ak)],sameDaySE01Overlap=sum('S-E01' in x['gates'] for x in b['holdingMatches']),stocks=len({x['stock'] for x in b['origins']}),stockConcentration=dict(C.Counter(x['stock'] for x in b['origins'])),dateConcentration=dict(C.Counter(str(x['date']) for x in b['origins'])),checks=b['counts'],unknownFutureS=len(bk),strategyReplays=0)
 save('v35-control.json',a);save('v36-analysis.json',b);save('summary.json',summary)
 source(__file__)
 assert all(sha(R/p)==h for p,h in HASH.items())
 save('source-hashes.json',HASH);save('completion.json',dict(status='complete',task='SD-F05-v36-refresh',sourceCount=len(HASH),oldOriginsReproduced=54,summary=summary))
 print(json.dumps(summary,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
