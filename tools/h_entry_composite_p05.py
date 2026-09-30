#!/usr/bin/env python3
"""Five frozen P03 cards: historical diagnostics and v35 trigger compatibility.
Read-only on all inputs. No strategy simulator, search or candidate selection.
"""
import json, math, sys
from pathlib import Path
from collections import Counter,defaultdict
import numpy as np
import h_entry_composite_p04_review as v
from h_entry_composite_p04_supplement import neighbors
q,p,e,r=v.q,v.p,v.e,v.r
import h_entry_composite as h
R=q.R;O=R/'exports/h-entry-composite-p05-20260930';read=q.read

def save(name,x):q.save(O/name,x)
def key(k):return k['sample'],k['window'],k['stock'],k['date']
def eventkey(sample,d):return sample,d['window_id'],d['stock_id'],d['trade_date']
def sources():
 co=read(R/'exports/hc-i01-f1-adoption-20260930/completion.json');paths={};events={};gates={};summary={};reports={};bases={}
 for sample in 'AB':
  report=next(R/x for x in co['runs'] if f'baseline-{sample.lower()}-'in x and 'fixed3y'in x);base=next(R/x for x in co['decisionBases']if Path(x).name.startswith(sample.lower()+'-'));reports[sample]=report;bases[sample]=base
  for folder in (report,base):
   m=read(folder/'manifest.json');assert m['ruleCommit']==co['ruleCommit'] and m['dataRuleVersion']=='T3/S59' and m['ruleVersion']==co['strategy'] and m['moneyBaseWan']==600 and m['automaticInvestments']==2 and m['through']=='2026/07/22'
   assert (folder/'.complete').read_text().strip()==m.get('runID',m.get('decisionBaseID'))
   for name in ('manifest.json','.complete'):paths[str((folder/name).relative_to(R))]=p.sha(folder/name)
  b=read(report/'baseline.json');assert b['ruleCommit']==co['ruleCommit'];summary[sample]=dict(runID=read(report/'manifest.json')['runID'],combinedScore=b['combinedScore'],groups=b['groups'])
  paths[str((report/'baseline.json').relative_to(R))]=p.sha(report/'baseline.json');paths[str((base/'decisions.sqlite').relative_to(R))]=p.sha(base/'decisions.sqlite')
  with h.db(base/'decisions.sqlite')as db:
   assert db.execute('pragma quick_check').fetchone()[0]=='ok';meta=dict(db.execute('select key,value from metadata'));assert meta['dataRuleVersion']=='T3/S59'and meta['ruleCommit']==co['ruleCommit']
   for row in db.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=1'):
    d=dict(row);k=eventkey(sample,d);assert k not in events;events[k]=d
   for row in db.execute('select e.window_id,e.trade_date,s.stock_id,r.rule_id from event_gates g join decision_events e using(event_id) join stocks s using(stock_key) join rules r using(rule_key) where r.rule_id in ("H-E01","H-E02")'):
    d=dict(row);gates[eventkey(sample,d)]=d['rule_id']
 return co,reports,bases,events,gates,paths,summary

def current_inputs(reports,events,defs,names):
 cat=read(p.P/'feature-catalog.json');cols={c['name']:i for i,c in enumerate(cat)};datasets={};keyidx={};rounds=defaultdict(list);check=Counter();hashes={}
 for label in ('discovery','later'):
  X,keys,rr=p.dataset(label);am=list(p.arrays(defs,X,cat));datasets[label]=(X,keys,am);keyidx.update({key(k):(label,i)for i,k in enumerate(keys)})
 market=h.csvmap(h.MARKET/'market-technical.csv');assert p.sha(h.MARKET/'market-daily.csv')==read(reports['A']/'manifest.json')['marketInput']['dailySHA256']
 rawmarket=h.csvmap(h.MARKET/'market-daily.csv');dates=sorted(rawmarket);k=d=50.;closes=[];highs=[];lows=[]
 for n,day in enumerate(dates):
  row=rawmarket[day];close=float(row['close']);closes.append(close);highs.append(max(float(row['high']),close));lows.append(min(float(row['low']),close))
  if n:
   hi=max(highs[-9:]);lo=min(lows[-9:]);rsv=50. if hi==lo else 100*(close-lo)/(hi-lo);k=2*k/3+rsv/3;d=2*d/3+k/3
  if n<249:continue
  z=(close-np.mean(closes[-125:]))/np.std(closes[-125:])if np.std(closes[-125:])else 0.
  for name,value in (('market_kd_d',d),('market_kd_j',3*k-2*d),('market_z_125',z)):
   assert math.isclose(value,float(market[day][name]),abs_tol=1e-8,rel_tol=1e-9),(day,name,value,market[day][name]);check['independentMarketComparisons']+=1
 for path in (h.MARKET/'market-daily.csv',h.MARKET/'market-technical.csv',h.PATHS):hashes[str(path.relative_to(R))]=p.sha(path)
 direct={'osc':'ZTOSC','ma20_diff_z125':'ZTMA20DIFFZ125','t_low_diff_125':'ZTLOWDIFF125','kd_k_z125':'ZTKDKZ125','osc_z250':'ZTOSCZ250','ma60_diff_z250':'ZTMA60DIFFZ250'}
 for sample,folder in reports.items():
  for w,(fn,start,end)in h.WINDOWS.items():
   path=folder/fn;hashes[str(path.relative_to(R))]=p.sha(path)
   with h.db(path)as db:
    assert db.execute('pragma quick_check').fetchone()[0]=='ok'
    for st in db.execute('select * from ZSTOCK'):
     st=dict(st);sid=st['ZSID'];assert st['ZTECHNICALSTATEVERSION']==3 and st['ZSIMULATIONSTATEVERSION']==59
     raw=[dict(x)for x in db.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(st['Z_PK'],))];local=[]
     for n,row in enumerate(raw):
      day=h.dateof(row['ZDATETIME']);k=(sample,w,sid,day)
      if not start<=day<=end or k not in events:continue
      assert k in keyidx,k;label,i=keyidx[k];X,keys,am=datasets[label];assert keys[i]['close']==row['ZPRICECLOSE'];check['currentDecisionRows']+=1
      vals={name:row[col]if n>=249 else np.nan for name,col in direct.items()}
      vals.update(osc_is_max9=float(row['ZTOSC']==row['ZTOSCMAX9'])if n>=249 else np.nan,ma20_diff_is_max9=float(row['ZTMA20DIFF']==row['ZTMA20DIFFMAX9'])if n>=249 else np.nan,ma20d=row['ZTMA20DIFFMAX9']-row['ZTMA20DIFFMIN9']if n>=249 else np.nan,ma60d=row['ZTMA60DIFFMAX9']-row['ZTMA60DIFFMIN9']if n>=249 else np.nan,delta_kd_k=row['ZTKDK']-raw[n-1]['ZTKDK']if n>=250 else np.nan)
      for name in names:
       if name.startswith('market_'):continue
       assert np.isclose(vals[name],X[i,cols[name]],rtol=1e-11,atol=1e-9,equal_nan=True),(k,name,vals[name],X[i,cols[name]])
       check['technicalValueComparisons']+=1
      local.append((i,row,day,events[k]))
     if not local:continue
     prices=[x[1]['ZPRICECLOSE']for x in local];inv=[x[1]['ZSIMQTYINVENTORY']for x in local]
     for j,(i,row,day,event)in enumerate(local):
      if not(event['planned_action']=='H'and event['executed_action']=='BUY'and event['inventory_before']==0):continue
      assert row['ZSIMQTYBUY']>0 and row['ZSIMRULEBUY']=='H'
      stop=next((t for t in range(j+1,len(local))if inv[t]==0),len(local)-1);closed=inv[stop]==0;info=h.cut_round(prices,inv,j,stop,closed);tr=info['trough'];de=info['decline']
      rounds[label].append(dict(id=f'{sample}-W{w}-{sid}-{day}',sample=sample,window=w,stock=sid,name=st['ZSNAME'],entry=i,end=local[stop][0],entry_date=day,end_date=local[stop][2],entry_price=prices[j],closed=closed,decline=None if de is None else local[de][0],trough=None if tr is None else local[tr][0],kind=info['kind'],censored=info['censored'],bottom_boundary=bool(info.get('bottom_boundary',False)),opportunity=bool(info.get('opportunity',False)),minimum=None if tr is None else prices[tr],min_date=None if tr is None else local[tr][2],grade=event['grade']))
     check['stockWindows']+=1
 expected=sum(x['planned_action']=='H'and x['executed_action']=='BUY'and x['inventory_before']==0 for x in events.values());assert sum(map(len,rounds.values()))==expected
 return datasets,rounds,check,hashes

def main():
 assert not(O/'completion.json').exists()and not(O/'analysis.json').exists()
 defs=read(p.P/'atoms-no-outcome-ranking.json');selected=[x for x in read(p.O/'frozen.json')['candidates']if x['id']!='HC-P3-05'];cat=read(p.P/'feature-catalog.json');names=sorted({defs[i]['name']for node in selected for b in node['expr']for i in b});assert all(next(c for c in cat if c['name']==name)['group']!='S'for name in names)
 co,reports,bases,events,gates,hashes,baseSummary=sources();datasets,rounds,check,morehash=current_inputs(reports,events,defs,names);hashes.update(morehash)
 oldevents={}
 for sample in 'AB':
  with h.db(h.basedir(sample)/'decisions.sqlite')as db:
   for row in db.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=1'):
    d=dict(row);oldevents[eventkey(sample,d)]=d
 hist={label:v.inputs(defs,label)for label in ('discovery','later')};outputs=[];variantCount=0
 for node in selected:
  out=dict(id=node['id'],expression=node['expression'],expr=node['expr'],fields=sorted({defs[i]['name']for b in node['expr']for i in b}),historical={},current={},variants=[])
  for label in ('discovery','later'):
   data,X,C=hist[label];bb,oo=r.details(node['expr'],data);out['historical'][label]=dict(totals=v.totals(bb,oo),cells=r.summarize(bb,oo),knownFlatDetails=oo,baselineDetails=bb,branches=[])
   for branch in node['expr']:
    xb,xo=r.details([branch],data);out['historical'][label]['branches'].append(dict(expr=[branch],totals=v.totals(xb,xo),cells=r.summarize(xb,xo)))
   X,keys,am=datasets[label];currentData=(keys,rounds[label],am,[],data[4],data[5]);cb,_=r.details(node['expr'],currentData);m,valid=r.evaluate(node['expr'],am);oldIDs={x['id']for x in bb if x['hit']};newIDs={x['id']for x in cb if x['hit']};sharedState=0;activations=Counter();activationRows=[]
   for k,i in ((key(k),i)for i,k in enumerate(keys)):
    if k in gates and m[i]:activations[gates[k]]+=1;activationRows.append(dict(sample=k[0],window=k[1],stock=k[2],date=k[3],gate=gates[k]))
   for x in cb:
    if not x['hit']:continue
    k=(x['sample'],x['window'],x['stock'],x['entryDate']);new=events[k];old=oldevents.get(k);same=bool(old and all(new[f]==old[f]for f in ('grade','decision_score','decision_threshold','inventory_before','unit_cost_before','unit_roi_before','holding_days_before','invest_times_before','balance_before','roll_roi_before','roll_days_before','roll_rounds_before','buy_rule_before')));x['v33PrestateEqual']=same;sharedState+=same
   out['current'][label]=dict(totals=v.totals(cb,[]),cells=r.summarize(cb,[]),baselineDetails=cb,existingDelayOverlap=dict(activations),existingDelayOverlapRows=activationRows,oldMatched=len(oldIDs),newMatched=len(newIDs),retainedOldEntryIDs=len(oldIDs&newIDs),lostOldEntryIDs=sorted(oldIDs-newIDs),addedEntryIDs=sorted(newIDs-oldIDs),prestateEqualAmongCurrentHits=sharedState)
  specs=list(neighbors(node['expr'],defs))
  for aid in sorted({i for b in node['expr']for i in b}):specs.append(dict(kind='drop',atom=aid,expr=[[i for i in b if i!=aid]for b in node['expr']]))
  for spec in specs:
   rec=dict(**spec,field=defs[spec['atom']]['name'],domains={})
   for label in ('discovery','later'):
    data,X,C=hist[label];changed=v.changed_data(data,X,C,defs,cat,spec);bb,oo=r.details(spec['expr'],changed);rec['domains'][label]=dict(totals=v.totals(bb,oo),cells=r.summarize(bb,oo),hitIds=[x['id']for x in bb if x['hit']])
   out['variants'].append(rec)
  variantCount+=len(specs);assert variantCount<=100;outputs.append(out);print('CARD',node['id'],'diagnostics',len(specs),flush=True)
 save('analysis.json',dict(baseline=35,decisionBase=21,baseScores=baseSummary,currentHEntries=sum(map(len,rounds.values())),checks=dict(check),formulaFamilies=5,diagnosticVariants=variantCount,currentEffectsAreOriginalPathOnly=True,oldKnownPathsNotV35Counterfactual=True,candidates=outputs));save('source-hashes.json',hashes)
 for name,digest in hashes.items():assert p.sha(R/name)==digest,name
 print('COMPLETE',sum(map(len,rounds.values())),'current H entries',variantCount,'variants',dict(check),flush=True)
if __name__=='__main__':main()
