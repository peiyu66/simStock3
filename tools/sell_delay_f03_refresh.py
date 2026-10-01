#!/usr/bin/env python3
"""Frozen F03/R1 causal input refresh; no hypothetical strategy replay."""
from pathlib import Path
import csv,json,collections as C,math,subprocess
import sell_delay_f05_refresh as h
R=h.R;O=R/'exports/sell-delay-f03-refresh-20261001';h.O=O
read=h.read;db=h.db;source=h.source;save=h.save
M=R/'exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af/market-technical.csv'
P=R/'exports/market-data/taiex/research/mkt-pp-p1-taiex-price-path-f712b360c322/market-price-path.csv'
def csvmap(p):return {int(x['date'].replace('-','')):x for x in csv.DictReader(source(p).open())}
def scan(version,ids,rule,strategy,market,paths):
 out=[];counts=C.Counter()
 for s in 'AB':
  rp=R/ids[s]['report'];bp=R/ids[s]['decisionBase']
  for p in [rp,bp]:
   m=read(p/'manifest.json');assert m['ruleCommit']==rule and m['ruleVersion']==strategy and m['dataRuleVersion']==f'T3/S{59 if version==35 else 60}'
   assert m['through']=='2026/07/22'and m['moneyBaseWan']==600 and m['automaticInvestments']==2 and m['stockCount']==10
   assert source(p/'.complete').read_text().strip()==m.get('runID',m.get('decisionBaseID'))
  with db(bp/'decisions.sqlite')as c:
   meta=dict(c.execute('select key,value from metadata'));assert meta['ruleCommit']==rule
   ev=[dict(x)for x in c.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=3')]
   gates=C.defaultdict(list)
   for eid,r in c.execute('select g.event_id,r.rule_id from event_gates g join rules r using(rule_key)'):gates[eid].append(r)
   wins=[dict(x)for x in c.execute('select * from windows')]
  for w in wins:
   wi=w['window_id']
   with db(rp/['browse.store','period-20200722.store','period-20230722.store'][wi-1])as c:
    for st in c.execute('select * from ZSTOCK').fetchall():
     assert st['ZTECHNICALSTATEVERSION']==3 and st['ZSIMULATIONSTATEVERSION']==(59 if version==35 else 60)
     rows=[dict(x)for x in c.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(st['Z_PK'],))];dates=[h.day(x['ZDATETIME'])for x in rows];ix={d:i for i,d in enumerate(dates)}
     def values(i):
      r=rows[i];m=market.get(dates[i]);p=paths.get(dates[i]);valid=i>=249 and m is not None and p is not None and m['price_mature_250']=='true'and int(p['phase_raw'])!=0
      if not valid:return None
      v=dict(market_ma_20_diff_max_9=float(m['market_ma_20_diff_max_9']),market_path_peak=int(int(p['phase_raw'])in(2,3)),price_high_is_max9=int(r['ZPRICEHIGH']==r['ZTHIGHMAX9']),market_low_diff_z_125=float(m['market_low_diff_z_125']))
      return v if all(math.isfinite(x)for x in v.values())else None
     def hit(v,rev):return v is not None and v['market_ma_20_diff_max_9']<1.2 and v['market_path_peak']==1 and(not rev or v['price_high_is_max9']==0 or v['market_low_diff_z_125']<0)
     stockevents=[e for e in ev if e['window_id']==wi and e['stock_id']==st['ZSID']]
     sell_dates={e['trade_date']for e in stockevents if e['planned_action']=='SELL'}
     for e in stockevents:
      counts['holdingEvents']+=1;i=ix[e['trade_date']];r=rows[i];v=values(i)
      if hit(v,True) and 'S-E01'in gates[e['event_id']]:counts['R1SE01HoldingOverlap']+=1
      if not(e['executed_action']=='SELL'and e['planned_action']=='SELL'and not r['ZSIMREVERSED']):continue
      counts['automaticSales']+=1
      assert e['inventory_before']==r['ZSIMQTYSELL'] and r['ZSIMQTYINVENTORY']==0
      assert math.isclose(e['unit_roi_before'],100*(r['ZPRICECLOSE']/e['unit_cost_before']-1),abs_tol=1e-8)
      for rev in [False,True]:
       if not hit(v,rev):continue
       future=[]
       for j in range(i+1,min(i+11,len(rows))):
        if dates[j]>w['end_date']:break
        vv=values(j);future.append(dict(date=dates[j],close=rows[j]['ZPRICECLOSE'],gainPct=100*(rows[j]['ZPRICECLOSE']/r['ZPRICECLOSE']-1),values=vv,condition=hit(vv,rev),baselineNormalSell=dates[j] in sell_dates))
       off=next((x for x in future if x['values']is None or not x['condition']),None)
       result=('unknownInputs'if off['values']is None else 'higherRelease'if off['gainPct']>0 else 'lowerRelease'if off['gainPct']<0 else 'equalRelease')if off else 'stillTrue10'if len(future)==10 else 'windowTruncated'
       mx=max(x['close']for x in future)if future else None
       out.append(dict(candidate='SD-F03-R1'if rev else'SD-F03-original',sample=s,window=wi,stock=st['ZSID'],anchor=e['trade_date'],grade=e['grade'],gates=gates[e['event_id']],close=r['ZPRICECLOSE'],values=v,future=future,result=result,firstOffDate=off['date']if off else None,releasePriceDeltaPct=off['gainPct']if off else None,highestDates=[x['date']for x in future if x['close']==mx],maxGainPct=max((x['gainPct']for x in future),default=None),minGainPct=min((x['gainPct']for x in future),default=None),completeTen=len(future)==10,observedHigher=any(x['gainPct']>0 for x in future),futureCandidateSellEligibility='unknown'))
   print('completed',version,s,wi,flush=True)
 return dict(counts=dict(counts),origins=out)
def main():
 assert not(O/'completion.json').exists();O.mkdir(exist_ok=True,parents=True)
 save('protocol.json',dict(authorization='User 繼續F03。',scope='F03 frozen original/R1 refresh and bounded counterexample diagnosis on A/B v36; no strategy replay, build, Simulator, C/D/E, adoption, commit or push'))
 market=csvmap(M);paths=csvmap(P);co=read('exports/sell-delay-p09-adoption-20261001/completion.json');rule=co['ruleCommit'];assert subprocess.check_output(['git','rev-parse',rule],text=True).strip()==rule
 for f in ['simStock3/technical.swift','simStock3/StrategyFit.swift']:
  assert source(f).read_bytes()==subprocess.check_output(['git','show',rule+':'+f])
 old=read('exports/sell-delay-p01-20260930/identities.json');new={s:dict(report=next(p for p in co['reports']if f'baseline-{s.lower()}-'in p and 'fixed3y'in p),decisionBase=next(p for p in co['decisionBases']if Path(p).name.startswith(s.lower()+'-')))for s in 'AB'}
 a=scan(35,old,'6097cc26fe839dd8878082ac8f11bdaf08cf0306','s47-h-entry-i01-f1-20260930',market,paths);b=scan(36,new,rule,co['strategy'],market,paths)
 save('v35-control.json',a);save('v36-analysis.json',b)
 cards=next(x for x in read('exports/sell-delay-p04-20260930/candidate-cards.json')if x['family']=='SD-F03')
 key=lambda x:(x['sample'],x['window'],x['stock'],x['anchor'])
 for name in ['SD-F03-original','SD-F03-R1']:
  cases=[x for v in cards['variants']if v['id']==name for x in v['cases']];actual=[x for x in a['origins']if x['candidate']==name];assert {key(x)for x in cases}=={key(x)for x in actual},(name,len(cases),len(actual),{key(x)for x in cases}-{key(x)for x in actual},{key(x)for x in actual}-{key(x)for x in cases})
  for x in actual:
   y=next(y for y in cases if key(y)==key(x));assert x['result']==y['result']and x['firstOffDate']==y.get('firstOffDate')and h.equal(x['releasePriceDeltaPct'],y.get('releasePriceDeltaPct'))and x['highestDates']==y['highestDates']
 summaries={}
 for name in ['SD-F03-original','SD-F03-R1']:
  xs=[x for x in b['origins']if x['candidate']==name];ys=[x for x in a['origins']if x['candidate']==name];ak={key(x)for x in ys};bk={key(x)for x in xs}
  summaries[name]=dict(origins=len(xs),stocks=len({x['stock']for x in xs}),counts=dict(C.Counter(x['result']for x in xs)),cells=[dict(sample=s,window=w,counts=dict(C.Counter(x['result']for x in xs if x['sample']==s and x['window']==w)))for s in 'AB'for w in [1,2,3]],added=list(bk-ak),removed=list(ak-bk),dates=dict(C.Counter(str(x['anchor'])for x in xs)),completeHigher=sum(x['completeTen']and x['observedHigher']for x in xs),bothDirections=sum(x['minGainPct']<0 and x['maxGainPct']>0 for x in xs),negative=[x for x in xs if x['result']=='lowerRelease'])
 save('v35-control.json',a);save('v36-analysis.json',b);save('identities.json',new);save('summary.json',summaries);source(__file__);assert all(h.sha(R/p)==sha for p,sha in h.HASH.items());save('source-hashes.json',h.HASH);save('scan-verification.json',dict(passed=True,sourceCount=len(h.HASH),oldOriginalOrigins=35,oldR1Origins=22,oldReleaseAndPeakReproduced=True,checks=b['counts'],ruleCommit=rule))
 print(json.dumps({k:{n:v for n,v in x.items()if n!='negative'}for k,x in summaries.items()},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
