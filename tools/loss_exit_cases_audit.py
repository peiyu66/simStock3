#!/usr/bin/env python3
import json,math,collections as C
import numpy as np
import loss_exit_cases as c
cat,X,meta,units,events,names=c.init();cards=c.read('candidate-cards.json');checks=C.Counter();controls={}
for name,digest in json.loads((c.p.O/'source-hashes.json').read_text()).items():
 if name.endswith(('.store','.store-wal','.store-shm','.sqlite','.json','.csv','.swift')) and not name.startswith('exports/loss-exit-p01-'):
  assert c.p.sha(c.p.R/name)==digest,name;checks['sourceHashesUnchanged']+=1
for name,digest in c.read('protocol.json')['inputHashes'].items():assert c.p.sha(c.p.O/name)==digest;checks['P01ArtifactsUnchanged']+=1
for row in cards:
 h=row['hypothesis'];cols=[names.index(t[0]) for t in h['terms']];m=np.ones(len(X),dtype=bool);known=np.ones(len(X),dtype=bool)
 for t,j in zip(h['terms'],cols):
  v=X[:,j];known&=np.isfinite(v);m&=(v>t[2]) if t[1]=='gt' else (v<t[2])
 m&=known
 for i,xx in enumerate(X):
  a=[c.term(t,xx,names) for t in h['terms']];assert bool(m[i])==(a[0] is True and a[1] is True);checks['independentVectorScalarTermChecks']+=1
 for t in h['terms']:
  for v,expected in [(float('nan'),None),(0.,False),(-1e-12,t[1]=='lt'),(1e-12,t[1]=='gt')]:
   z=np.zeros(len(names));z[names.index(t[0])]=v;assert c.term(t,z,names)==expected;checks['zeroMissingBoundaryChecks']+=1
 control=C.Counter()
 for i,(_,w,s,r) in enumerate(meta):
  if not r['held'] or not r['qtySell']:continue
  if m[i]:
   control['allOriginalSellsMatched']+=1;control['netLossMatched']+=r['profit']<0;control['nonLossMatched']+=r['profit']>=0;control['cutNonLossMatched']+=r['profit']>=0 and r['gates']['cut'];control['baseMatched']+=r['gates']['base'];control['feeOnlyLossMatched']+=r['profit']<0 and r['unitROI']>=0
 controls[h['id']]=dict(control)
 if h['direction']=='late':
  for e,rec in zip(events,row['eventRecords']):
   i=e['index'];r=meta[i][3];assert rec['trigger']==bool(m[i] and r['gates']['lateEligible'] and not r['quality']);assert rec['candidateOwnS']=='unknown' and rec['actualSell']=='unknown';checks['lateOriginOwnSContract']+=1
   if rec['releaseDate'] is not None:
    index=next(i for i in e['sides']['late']['indices'] if meta[i][3]['date']==rec['releaseDate']);assert abs(rec['priceDeltaPct']-100*(meta[index][3]['price']/e['price']-1))<1e-10;checks['releasePriceRawJoin']+=1
 for partition,ws in [('discovery',(1,2)),('frozenW3',(3,))]:
  s=row['summary'][partition];assert s['higher']+s['lower']+s['same']+s['unknown']==s['hitEvents'];assert s['events']==sum(e['window'] in ws for e in events);checks['partitionCountConservation']+=1
# Recreate existing exclusions independently on all holding dates, ensuring new early gates preserve official blockers.
for i,(_,_,_,r) in enumerate(meta):
 if not r['held']:continue
 v={n:X[i,names.index(n)] for n in ['market_high_diff_z_250','tOscMax9','delta_osc_z125','delta_market_osc_z_125','intraday_low_diff','market_ma_20_diff_max_9','market_phase','priceHigh','tHighMax9','market_low_diff_z_125','osc_z125']};g=r['gates']
 e1=(not g['base'] and g['cut'] and all(math.isfinite(v[n]) for n in ['market_high_diff_z_250','tOscMax9','delta_osc_z125','delta_market_osc_z_125']) and -.97<v['market_high_diff_z_250']<.83 and v['tOscMax9']<0 and (v['delta_osc_z125']<.22 or v['delta_market_osc_z_125']>0) and (r['grade']>=1 or v['intraday_low_diff']>-.53))
 e2=((g['base'] or g['cut']) and not e1 and all(math.isfinite(v[n]) for n in ['market_ma_20_diff_max_9','market_low_diff_z_125','priceHigh','tHighMax9','market_phase','osc_z125']) and v['market_ma_20_diff_max_9']<1.2 and v['market_phase'] in (2,3) and (v['priceHigh']!=v['tHighMax9'] or v['market_low_diff_z_125']<0))
 assert e1==g['E01'] and e2==g['E02'],(i,r['date'],e1,e2,g);checks['existingExclusionsPreserved']+=1
c.save('audit.json',dict(status='passed',checks=dict(checks),nonLossAndOverlapControls=controls,frozenSHA256=c.p.sha(c.O/'hypotheses-frozen.json'),cardsSHA256=c.p.sha(c.O/'candidate-cards.json'),newPairsOutsideFrozen=0,strategyScoresCalculated=False));c.finish('audit',dict(checks=dict(checks),controls=controls))
