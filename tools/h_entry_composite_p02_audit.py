#!/usr/bin/env python3
"""Input/formula/missingness audit and outcome-free atom budget for HC-P02."""
import json,math,collections,itertools,hashlib,csv
from pathlib import Path
import numpy as np
import h_entry_composite_p02 as p
import h_entry_composite_search as search
import market_technical as mt
R=p.R;O=p.O;h=p.h

def audit():
 assert not (O/"completion.json").exists(),"Frozen P02; do not overwrite audit"
 cat=p.read(O/'feature-catalog.json');names=[c['name'] for c in cat];lookup={n:j for j,n in enumerate(names)}
 matrices={label:np.load(O/f'{label}.npz')['X'] for label in ('discovery','later')};mapping={}
 for label,X in matrices.items():
  kk=p.read(p.OLD/f'{label}-keys.json');assert len(kk)==len(X)
  for i,k in enumerate(kk):mapping[k['sample'],k['window'],k['stock'],k['date']]=X[i]
 checks=collections.Counter();maxerrors=collections.defaultdict(float)
 def same(a,b,label,tol=1e-9):
  assert math.isclose(a,b,abs_tol=tol,rel_tol=1e-11),(label,a,b)
  checks[label]+=1;maxerrors[label]=max(maxerrors[label],abs(a-b))
 # Independent direct source read; all finite added persisted values plus formula families.
 new=p.read(p.P01/'proposed-features.json');direct=[c for c in new if c['group']=='T' and 'Trade' not in c['name']]
 for sample in 'AB':
  for w,(filename,start,end) in h.WINDOWS.items():
   with h.db(h.reportdir(sample)/filename) as db:
    for stock in db.execute('select * from ZSTOCK'):
     raw=[dict(r) for r in db.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(stock['Z_PK'],))]
     for i,r in enumerate(raw):
      X=mapping.get((sample,w,stock['ZSID'],h.dateof(r['ZDATETIME'])))
      if X is None:continue
      rec=json.loads(r['ZSIMANNUALWARNINGDATA']);snap=rec['snapshot'];floor=rec.get('continuationFloor');high=rec.get('continuationPriceHigh')
      if floor is not None:assert math.isfinite(floor) and high is not None and math.isfinite(high) and high>0
      else:assert high is None and not rec['locallyReleased']
      assert rec['locallyReleased']==(snap.get('localReleaseReason') is not None)
      fail=snap.get('prewarningFailureDays')
      if fail is not None:assert fail in (0,1,2) and snap['status'] in ('normal','released') and snap.get('prewarningReason') is not None
      else:assert snap.get('prewarningReason') is None
      checks['warningDecoderInvariantChecks']+=1
      for c in direct:
       n=c['name'];column='Z'+n.upper()
       if column in r and np.isfinite(X[lookup[n]]):same(X[lookup[n]],r[column],'persistedTExact',0)
      for n in ['tMa20DiffMax9','tMa20DiffMin9','tMa60DiffMax9','tMa60DiffMin9','tKdKMax9','tKdKMin9','tOscMax9','tOscMin9']:
       actual=X[lookup[n]]
       if not np.isfinite(actual):continue
       base=n[:-4];vals=[v['Z'+base.upper()] for v in raw[max(0,i-8):i+1]];expected=max(vals) if 'Max9' in n else min(vals)
       same(actual,expected,'T9ExtremaRecomputed',0)
      for n in ['tMa20','tMa60']:
       if np.isfinite(X[lookup[n]]):same(X[lookup[n]],sum(v['ZPRICECLOSE'] for v in raw[max(0,i-int(n[3:])+1):i+1])/min(i+1,int(n[3:])),'priceMARecomputed')
      if i and np.isfinite(X[lookup['close_change_percent']]):same(X[lookup['close_change_percent']],100*(r['ZPRICECLOSE']-raw[i-1]['ZPRICECLOSE'])/raw[i-1]['ZPRICECLOSE'],'closeChangeRecomputed')
      for prefix,ph,b,anchor,ext,close in [('t',r['ZTPRICEPATHPHASERAW'],r['ZTPRICEPATHBARRIER'],r['ZTPRICEPATHANCHORCLOSE'],r['ZTPRICEPATHEXTREMECLOSE'],r['ZPRICECLOSE'])]:
       for phase,codes in [('peak',(2,3)),('pullback',(4,5)),('bottom',(6,7)),('rebound',(8,9))]:
        value=X[lookup[f'{prefix}_path_{phase}_progress']]
        if ph not in codes:assert np.isnan(value);checks['inactivePhaseProgressMissing']+=1
        else:
         expected={'peak':lambda:(ext/anchor-1)/b,'pullback':lambda:(ext-close)/ext/b,'bottom':lambda:(anchor-ext)/anchor/b,'rebound':lambda:(close-ext)/ext/b}[phase]()
         same(value,expected,'phaseProgressRecomputed')
 # Recompute market numerical series from exact frozen OHLC and activity inputs, no downloads.
 raw=list(csv.DictReader((h.MARKET/'market-daily.csv').open()));frozen=list(csv.DictReader((h.MARKET/'market-technical.csv').open()));calc=mt.calculate_market(raw)
 assert len(calc)==len(frozen)
 for actual,expected in zip(calc,frozen):
  assert actual['date']==expected['date']
  for name,value in actual.items():
   if name=='date':continue
   if isinstance(value,bool):assert ('true' if value else 'false')==expected[name];checks['marketMaturityFlags']+=1
   else:same(float(value),float(expected[name]),'marketNumericsRecomputed')
 # Atom counts derive from W1/W2 only; no labels, no pair scoring, no structure ranking.
 atoms=search.make_atoms(matrices['discovery'],cat);parent_counts=collections.defaultdict(collections.Counter)
 for a in atoms:parent_counts[a.group][a.parent]+=1
 n=collections.Counter(a.group for a in atoms);pairs={}
 for g,k in [('T','T'),('S','S'),('M','M'),('T','S'),('T','M'),('S','M')]:pairs[g+k]=n[g]*n[k] if g!=k else (n[g]**2-sum(v*v for v in parent_counts[g].values()))//2
 eligible=[c['name'] for c in cat if c['name']!='tradingDaysSinceLastInvestment']
 # For H new positions, add-on distance is structurally inapplicable at all 1597 entries: exclude from P03.
 atoms=[a for a in atoms if a.name in eligible];n=collections.Counter(a.group for a in atoms);parent_counts=collections.defaultdict(collections.Counter)
 for a in atoms:parent_counts[a.group][a.parent]+=1
 for g,k in [('T','T'),('S','S'),('M','M'),('T','S'),('T','M'),('S','M')]:pairs[g+k]=n[g]*n[k] if g!=k else (n[g]**2-sum(v*v for v in parent_counts[g].values()))//2
 atoms=[search.Atom(i,a.name,a.parent,a.group,a.op,a.value,a.mask,a.valid) for i,a in enumerate(atoms)]
 serial=[dict(id=a.id,name=a.name,parent=a.parent,group=a.group,op=a.op,value=a.value) for a in atoms]
 p.save('atoms-no-outcome-ranking.json',serial)
 totalpairs=sum(pairs.values());other=400*len(atoms)+19900
 p.save('search-budget.json',dict(features=len(cat),eligibleFeatures=len(eligible),excludedFeatures={'tradingDaysSinceLastInvestment':'all H entry rows structurally have no previous investment in current round'},atomCount=len(atoms),atomsBySource=dict(n),pairCounts=pairs,pairs=totalpairs,and3Upper=200*len(atoms),and4Upper=200*len(atoms),orUpper=19900,completeUpper=totalpairs+other,sourceStrata=list(search.STRATA),thresholdSource='A/B W1,W2 numeric values only; no outcome rank or expression scoring',searchesPerformed=0))
 p.save('numerical-audit.json',dict(passed=True,checks=dict(checks),maxAbsoluteErrors=dict(maxerrors),marketRows=len(calc)))
 print('AUDIT',dict(checks));print('BUDGET',totalpairs+other,len(atoms),pairs)
if __name__=='__main__':audit()
