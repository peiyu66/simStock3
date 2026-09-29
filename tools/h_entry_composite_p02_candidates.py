#!/usr/bin/env python3
"""Read existing candidate stores/deltas for 151 known flat paths only; no new replay."""
from pathlib import Path
from collections import defaultdict,Counter
import math,json
import numpy as np
import h_entry_composite_p02 as p
from sp08_sp09_market_extrema_decision_study import FIELDS
R=p.R;O=p.O;h=p.h

def reconstruct(sample,rule,folder):
 base,_=p.baseline_events(sample);out={k:dict(v) for k,v in base.items()}
 delta=folder/'source/exports/backtest-decision-deltas'/h.basedir(sample).name/('HC-'+rule.upper())/'decision-delta.sqlite'
 with h.db(delta) as c:
  for row in c.execute('select * from event_deltas where phase=1'):
   d=dict(row);w={20170722:1,20200722:2,20230722:3}[d['window_start']];key=(w,d['stock_id'],d['trade_date'])
   if d['kind']==3:out.pop(key,None);continue
   new=dict(out.get(key,{}))
   for field,suffix,bit in FIELDS:
    if d['changed_fields'] & (1<<bit):new[field]=d['candidate_'+suffix]
   out[key]=new
 return out,delta

def extract():
 assert not (O/'completion.json').exists();p.CAT=p.catalog();p.NEW=p.read(p.P01/'proposed-features.json');cat=p.CAT;cols=[c['name'] for c in cat]
 completed=p.read(O/'extraction-complete.json');assert completed['columns']==cols
 for name,digest in completed['files'].items():assert h.sha(O/name)==digest,name
 ms=p.market_inputs();anchors=p.read(R/'exports/h-entry-composite-shortwait-20260929/unique-flat-paths.json');grouped=defaultdict(list)
 for a in anchors:grouped[a['source'],a['sample']].append(a)
 baseline={};first_checks=0;keys=[];matrix=[];audit=Counter();source_hashes={};predicted=[]
 for label in ('discovery','later'):
  X=np.load(O/f'{label}.npz')['X']
  for i,k in enumerate(p.read(p.OLD/f'{label}-keys.json')):baseline[k['sample'],k['window'],k['stock'],k['date']]=X[i]
 for (rule,sample),aa in sorted(grouped.items()):
  folder=R/'exports'/('h-entry-composite-r02-20260929' if rule=='r02' else 'h-entry-composite-ab-20260928')
  events,delta=reconstruct(sample,rule,folder);source_hashes[str(delta.relative_to(R))]=h.sha(delta)
  run=next((folder/'source/exports/backtest-candidate-runs').glob(f'hc-{rule}-{sample.lower()}-candidate-*'))
  for fn in ['manifest.json','hc-entry-diagnostics.json']:
   source_hashes[str((run/fn).relative_to(R))]=h.sha(run/fn)
  di=p.read(run/'hc-entry-diagnostics.json')['records'];feasible={(int(d['windowStart'].replace('-','')),d['stock'],int(d['date'].replace('-',''))):d for d in di}
  bystock={(a['window'],a['stock']):a for a in aa};assert len(bystock)==len(aa)
  recovered={}
  for w,(fn,start,end) in h.WINDOWS.items():
   src=run/fn;source_hashes[str(src.relative_to(R))]=h.sha(src)
   with h.db(src) as db:
    for st in db.execute('select * from ZSTOCK'):
     stock=dict(st);a=bystock.get((w,stock['ZSID']))
     if not a:continue
     raw=[dict(x) for x in db.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(stock['Z_PK'],))];context=p.ctx();emap={d['date']:d for d in a['days']};ema=[None]*4
     for n,r in enumerate(raw):
      day=h.dateof(r['ZDATETIME']);e=events.get((w,stock['ZSID'],day));prev=raw[n-1] if n else None;fit=None
      if day>max(emap):break
      if e and prev:
       roi=e['roll_roi_before']/p.years(day,start);dd=p.avdays(e['roll_rounds_before'],e['roll_days_before'],e['inventory_before'],e['holding_days_before'])
       fast,slow,count,phase,ext,trend=p.ownstate(prev)
       fit=dict(fit_level=p.level_of(roi,dd),fit_fast=fast,fit_slow=slow,fit_observation_count=count,fit_trend_phase=phase,fit_trend_phase_extreme=ext,fit_trend=trend,roi_trend=ema[0]-ema[1] if ema[0] is not None else None,days_trend=ema[2]-ema[3] if ema[2] is not None else None,grade_activation_passed=e['roll_rounds_before']>2 or dd>360,is_finite=True,fit_evidence_rounds=e['roll_rounds_before'],fit_evidence_days=e['roll_days_before'])
      f=p.values(raw,n,stock,start,e,fit,ms,context,audit)
      if day>=start and p.days_after(r)>0:
       for j,v in enumerate([p.annual(r,start)]*2+[p.days_after(r)]*2):ema[j]=v if ema[j] is None else ema[j]+2/(21 if j%2==0 else 126)*(v-ema[j])
      if day not in emap:continue
      d=emap[day];assert e and e['inventory_before']==0,(a['id'],day)
      actual=(start,stock['ZSID'],day) in feasible;assert actual==d['hFeasible']
      if actual:
       diag=feasible[start,stock['ZSID'],day]
       assert bool(diag['suppressed'])==d['oldSuppressed']
      row=np.array([f.get(c,NAN) if p.finite(f.get(c)) else NAN for c in cols])
      if day==a['entry']:
       old=baseline[sample,w,stock['ZSID'],day]
       assert np.all(np.isclose(row,old,rtol=1e-11,atol=1e-9,equal_nan=True)),(a['id'],[cols[j] for j in np.where(~np.isclose(row,old,equal_nan=True))[0]])
       first_checks+=1
      recovered[day]=row
      keys.append(dict(anchor=a['id'],source=rule,sample=sample,window=w,stock=stock['ZSID'],date=day,index=d['index'],hFeasible=d['hFeasible'],suppressed=d['oldSuppressed'],lFill=d['lFill'],stateRole='candidate-own-flat-predecision',lastObservedDate=max(emap),originalEntry=day==a['entry']))
      matrix.append(row)
     # Reproduce first fill using the observed original gate and L fallback, never hypothetical new rules.
     fill=next((d['date'] for d in a['days'] if d['lFill'] or (d['hFeasible'] and not d['oldSuppressed'])),None)
     assert fill==a['fillDate'],(a['id'],fill,a['fillDate']);predicted.append(dict(anchor=a['id'],fill=fill))
  print('CANDIDATE',rule,sample,len(aa),'anchors complete',flush=True)
 X=np.array(matrix);assert first_checks==151
 np.savez_compressed(O/'candidate-flat.npz',X=X);p.save('candidate-flat-keys.json',keys);p.save('candidate-source-hashes.json',source_hashes)
 p.save('candidate-audit.json',dict(anchors=151,rows=len(keys),firstPrestatesEqual=first_checks,firstFillsReproduced=len(predicted),noPostFillExtrapolation=True,checks=dict(audit),availability=[dict(name=c['name'],finite=int(np.isfinite(X[:,j]).sum())) for j,c in enumerate(cat)]))
 print('CANDIDATE COMPLETE',len(keys),'rows',flush=True)
NAN=float('nan')
if __name__=='__main__':extract()
